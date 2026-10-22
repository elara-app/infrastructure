# Elara Local Infrastructure

Local orchestration repo (no application code): Postgres multi-database bootstrap, the
idempotent Vault secret loader, `compose.yml` for the whole default 9-service stack, and the
environment contract that compose wires into the containers.

See `../docs/ETAPA-02-infra-secretos.md` for the plan and `../docs/ETAPA-03-contenerizacion.md`
for the containerisation stage that consumes these files. Both are historical stage documents
kept in the untracked `../docs/` directory of the workspace (the workspace root is not a git
repository), so they are not versioned with this repo.

## Layout

| Path | Purpose |
| --- | --- |
| `postgres/init-multiple-dbs.sh` | Creates every database the services need, idempotently. |
| `scripts/setup-vault.sh` | Loads `service-secrets/*.json` into Vault (KV v2), idempotently. |
| `vault-loader/Dockerfile` | One-shot Vault bootstrap image (vault 1.16 CLI + bash/jq/base64). |
| `compose.yml` | The default 9-service stack on `elara-net` (5 Java builds + infra images). |

## Postgres bootstrap (`postgres/init-multiple-dbs.sh`)

The official `postgres` image only creates `POSTGRES_DB`. This script runs during the
image's init phase (mount it into `/docker-entrypoint-initdb.d/`, which keeps the `+x`
bit that is committed) and creates each database in `POSTGRES_MULTIPLE_DATABASES` that
does not exist yet, connecting to `POSTGRES_DB` as `POSTGRES_USER` with
`-v ON_ERROR_STOP=1` and a guarded `CREATE DATABASE ... WHERE NOT EXISTS`.

```bash
mount: ./postgres/init-multiple-dbs.sh:/docker-entrypoint-initdb.d/init-multiple-dbs.sh:ro
env:    POSTGRES_USER=postgres POSTGRES_PASSWORD=postgres POSTGRES_DB=inventory_db
        POSTGRES_MULTIPLE_DATABASES=inventory_db,unit_of_measure_db
```

Re-runs are safe: an existing database is never recreated, so the log is identical on a
second pass. The script now runs on **every** container start, because the Postgres data
directory is a tmpfs that begins empty (see "Ephemeral data directory" below).
Names are comma separated, whitespace tolerant
(`POSTGRES_MULTIPLE_DATABASES="a , b"` creates `a` and `b`), and only plain identifiers
are accepted — anything else aborts before the SQL is built. If `POSTGRES_DB` is unset the
official image creates a database named after `POSTGRES_USER` instead, so always set it.
`compose.yml` mounts the script into `/docker-entrypoint-initdb.d/` of **both** Postgres
containers, so each of them creates the second database itself.

### Ephemeral data directory

Both Postgres containers keep `/var/lib/postgresql/data` on a 128 MiB tmpfs instead of named
volumes, on purpose: data does not survive a container stop, restart, `down` or host reboot,
so every start re-runs `initdb` and the init script. The `size` is a hard cap — WAL and
temporary files live inside it, so a bulk load can hit `ENOSPC` — and tmpfs pages are RAM
charged to the container `mem_limit` (they may also be swapped).

The mount applies when the container is **recreated**: use `docker compose up -d` after this
file changes; `docker compose restart` does not pick up compose-file changes. Machines
upgrading from the previous persistent layout should drop the old volumes exactly once:

```bash
sudo docker compose down
sudo docker volume rm elara_pgdata-inventory elara_pgdata-uom 2>/dev/null || true
test -z "$(sudo docker volume ls -q --filter name=elara_pgdata)"
```

### Startup seed (dev)

`inventory-service` and `unit-of-measure-service` run `db/dev/seed.sql` on startup (dev
profile only). SQL initialization is deferred until after Hibernate creates/updates the
schema and completes during application startup before the HTTP port opens, so a healthy
container already carries the demo records:

| rows | contents |
| --- | --- |
| `inventory_item` | `Steel Bolt M10` (uom 1), `Aluminum Sheet 4x8` (uom 2), plus 8 warehouse items (uom 1) |
| `uom_status` | `Active`, `Inactive`, `Deprecated` |
| `uom` | `Kilogram` (factor 1.000), `Gram` (0.001), `Pound` (0.454), `Ounce` (0.028), `Tonne` (1000.000) |

The inserts are idempotent (`ON CONFLICT DO NOTHING` plus identity-sequence resync), so
restarting only the service never duplicates rows. The inventory `base_unit_of_measure_id`
values 1 and 2 are a deliberate id contract with the UoM seed. UoM ids 3-5 are additional
units for API tests; the inventory items keep referencing 1/2.

Restart semantics that go with ephemeral data:

- `docker compose restart postgres-inventory` / `postgres-uom` also restarts the dependent
  service and the gateway (`depends_on: restart: true`), which re-creates the schema and
  re-runs the seed.
- Postgres-scoped operations that bypass that cascade — `restart --no-deps` on a Postgres
  service, a raw `docker restart` of it, an OOM kill of it, or `docker compose stop
  postgres-inventory postgres-uom` + `start` for those two — discard the tmpfs and leave
  the business services running against a database with no tables until you run
  `docker compose restart inventory-service unit-of-measure-service` (or force-recreate
  them).
- Restarting `vault` empties its in-memory store: re-run the profile-gated loader.
- A host reboot or Docker daemon restart restarts every container by its
  `restart: unless-stopped` policy, so the services rebuild the schema and re-seed by
  themselves; only Vault's in-memory store stays empty, so re-run the loader as well.

## Vault secrets (`scripts/setup-vault.sh`)

`centralized-configuration/service-secrets/` holds one JSON per service and profile,
named `<spring.application.name>-<profile>-secrets.json`. The script validates each
file with `jq`, derives the Vault path from that filename (`secret/<app>/<profile>`,
e.g. `secret/unit-of-measure-service/dev` — never a short prefix such as `uom`), and
writes each entry as a separate `key=value` argument.

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=00000000-0000-0000-0000-000000000000   # or $VAULT_DEV_ROOT_TOKEN_ID
SECRETS_DIR=../centralized-configuration/service-secrets \
PROFILES=dev ./scripts/setup-vault.sh
```

Behaviour:

- `vault`, `jq` and `base64` must be in `PATH`; the missing binary is named in the error.
- `VAULT_TOKEN` is required; `vault login` fails fast on a wrong token.
- Vault is polled until it answers unsealed (`WAIT_TIMEOUT`, default 60s).
- Load is get-or-put: an existing path is reported as skipped, never overwritten, so
  re-running is safe in local dev and CI.
- Each JSON entry becomes exactly one `key=value` argument (base64-encoded by `jq`,
  decoded by the shell), so values containing `=` or newlines stay a single argument.
  A file that yields no pairs (for example `{}`) is skipped with an informational message.
- A summary (`loaded=`, `skipped=`, `failed=`) is printed; any failure exits non-zero.
- `SECRETS_DIR` defaults to `<script_dir>/../centralized-configuration/service-secrets`,
  i.e. the config repo checked out next to `scripts/` (export it to point elsewhere, as in
  the example above). `PROFILES`, `PROFILE`, `WAIT_TIMEOUT`, `--all-profiles` and
  `--profiles dev,test` select what gets loaded; files of other profiles (including prod
  files kept on disk by the DEV-ONLY policy) are simply not selected.

### Vault bootstrap under compose (one-shot)

The default stack renders nine services: a profile-gated `vault-loader` helper exists
but stays hidden from the default `config`/`up` render (default render is still exactly
9 services). Run it as a container one-shot against the `vault` service:

```bash
docker compose up -d vault        # dev mode: unsealed, root token from the compose default or an explicit environment override
sudo docker compose --profile bootstrap up vault-loader   # waits for `vault` healthy via depends_on, loads `dev` by default
```

Profile selection: `VAULT_LOAD_PROFILES=test` in the environment or `--profiles dev,test` appended
to the run command changes what gets loaded. Host one-shot kept as alternative:

```bash
export VAULT_ADDR=http://localhost:8200       # host side = the published port 8200
export VAULT_TOKEN=$VAULT_DEV_ROOT_TOKEN_ID   # or the literal dev root token
SECRETS_DIR=../centralized-configuration/service-secrets \
PROFILES=dev ./scripts/setup-vault.sh
```

It is a one-shot and idempotent (existing paths are reported as skipped), so re-running
never overwrites anything. Run it **before** `inventory-service` and
`unit-of-measure-service`: both import `optional:vault://secret/<app>/dev` with
`fail-fast: false`, so they tolerate an empty Vault and still come up — but ETAPA-04's E4
(`vault kv get secret/<app>/dev`) only passes once the loader has run, and it must assert
all 4 keys each service's dev secret carries (spring.datasource.username/password +
spring.rabbitmq.username/password).

The script needs `bash`, `vault`, `jq` AND `base64`. The official `hashicorp/vault` images
ship none of `bash`/`jq`/`base64`, and Alpine has no `vault` package, so the loader image
(`vault-loader/Dockerfile`) is multi-stage: it COPYs `/bin/vault` from
`hashicorp/vault:1.16` (CLI 1.16 == server 1.16) and runs `apk add bash jq coreutils`
(`base64` ships in coreutils) on `alpine:3.21` — running the script from the host, as
above, avoids that entirely.

## DEV-ONLY policy and prod gating

By default only `*-dev-secrets.json` files are loaded, against a local Vault dev server.
Loading the `prod` profile requires both a non-local `VAULT_ADDR` (anything other than
`127.0.0.1`/`localhost`/`0.0.0.0`/`[::]`/`[::1]`) and `CONFIRM_PROD=yes`. There is no
interactive prompt, so unattended runs can never hang, and a misconfigured local run is
refused before any network contact. The gate applies only to files actually being loaded:
a `*-prod-secrets.json` sitting next to the dev files does not break a plain dev run.
The values in `centralized-configuration/service-secrets/` are dev-only credentials
(`postgres/postgres` + `elara/elara`) and are safe to version; real secrets belong in
Vault only.

## Running the stack (compose)

`compose.yml` starts all nine services of the default stack on the `elara-net` bridge network. Every
interpolated value is written `${VAR:-<container DNS default>}`, so the stack is correct
with **no environment file** — the defaults already are the compose service names.

```bash
docker compose config            # validate the file offline: no daemon needed
docker compose up -d --build     # build the five images and start everything (needs the daemon)
docker compose ps                # per-service state and health
docker compose logs <service> --tail=100
docker compose down              # stop; the tmpfs databases are discarded with the containers
docker compose down -v           # equivalent here: the stack declares no volumes to drop
```

### Environment contract — no `.env` file

Every value compose interpolates carries a `${VAR:-default}`, and the defaults point at
container DNS: `config-service:8888`, `discovery-service:8761`, `vault:8200`,
`rabbitmq:5672`, `postgres-inventory`/`postgres-uom:5432`. The compose defaults are the
only supported configuration.

Do not add a `.env`: Compose auto-loads one from this directory and it beats the compose
defaults. A stray `.env` that carries host loopbacks (`localhost`/`127.0.0.1`) injects
them into the containers, where `localhost` is the container itself — the services then
cannot reach the config server, Eureka, the broker or Vault, health reports `DOWN`, and
`api-gateway` waits forever on `depends_on`.

Explicit shell or command overrides (`VAR=... docker compose up -d`) remain possible for
local experiments, but they are not a checked-in contract. Use the compose defaults.

Compose never sets `SPRING_PROFILES_ACTIVE`: the three profile-reading services
(`api-gateway`, `inventory-service`, `unit-of-measure-service`) already default to
`SPRING_PROFILES_ACTIVE=dev` in their own `application.yml`, so no env var is needed.

### Start order

`depends_on: {condition: service_healthy, restart: true}` already encodes the order —
infra (both Postgres, RabbitMQ, Vault) → `discovery-service` → `config-service` → the two
business services → `api-gateway` — so a single `docker compose up -d --build` is safe.
Step by step, if you prefer to read the logs service by service, use the same order:

```bash
docker compose up -d --build postgres-inventory postgres-uom rabbitmq vault
docker compose up -d --build discovery-service
docker compose up -d --build config-service
docker compose up -d --build inventory-service unit-of-measure-service
docker compose up -d --build api-gateway
```

The Vault secret loader is the one thing `depends_on` cannot do for the business
services: run the profile-gated one-shot (container or host) once between `vault` and
the business services (see "Vault bootstrap under compose" above).

The order above is enforced while starting or recreating containers. An explicit
`docker compose restart <service>` also restarts its dependents (`restart: true`), but
container-runtime restarts (daemon restart, host reboot, OOM) do not re-evaluate
`depends_on`; see "Startup seed" for how that interacts with the ephemeral databases.

### Published ports

| host port | service | note |
| --- | --- | --- |
| `8888` | `config-service` | config endpoint `/<app>/<profile>` + `/actuator/health` |
| `8761` | `discovery-service` | Eureka dashboard + `/eureka/apps` |
| `8080` | `api-gateway` | the only public entry point (`/api/v1/...`, `/inventory-service/...`, Swagger UI at `/swagger-ui/index.html`) |
| `5672` | `rabbitmq` | AMQP (dev) |
| `15672` | `rabbitmq` | management UI/API (dev) |
| `8200` | `vault` | dev-mode Vault (dev) |
| `127.0.0.1:8081` | `inventory-service` | debug only, loopback-bound |
| `127.0.0.1:8082` | `unit-of-measure-service` | debug only, loopback-bound |

`5432` is deliberately **not** published: Postgres is reachable on `elara-net` only, and
`docker compose exec postgres-inventory pg_isready -U postgres -d inventory_db` is the way
to check it. Every service also declares `expose`, documenting the in-network port for
parity with the image's EXPOSE; it is documentation only — on a user-defined bridge
containers reach each other regardless of EXPOSE.

### The nine default services

| service | image / build | ports | healthcheck |
| --- | --- | --- | --- |
| `config-service` | `build: ../config-service` | `8888:8888` | `curl -f http://localhost:8888/actuator/health` (start_period 90s) |
| `discovery-service` | `build: ../discovery-service` | `8761:8761` | `curl -f http://localhost:8761/actuator/health` (60s) |
| `api-gateway` | `build: ../api-gateway` | `8080:8080` | `curl -f http://localhost:8080/actuator/health` (60s) |
| `inventory-service` | `build: ../inventory-service` | `127.0.0.1:8081:8081` | `curl -f http://localhost:8081/actuator/health` (90s) |
| `unit-of-measure-service` | `build: ../unit-of-measure-service` | `127.0.0.1:8082:8082` | `curl -f http://localhost:8082/actuator/health` (90s) |
| `postgres-inventory` | `postgres:16-alpine` | none (expose 5432) | `pg_isready -h 127.0.0.1 -p 5432 -U $POSTGRES_USER -d $POSTGRES_DB` (30s) |
| `postgres-uom` | `postgres:16-alpine` | none (expose 5432) | `pg_isready -h 127.0.0.1 -p 5432 -U $POSTGRES_USER -d $POSTGRES_DB` (30s) |
| `rabbitmq` | `rabbitmq:3-management-alpine` | `5672:5672`, `15672:15672` | `rabbitmq-diagnostics ping` (40s) |
| `vault` | `hashicorp/vault:1.16` (dev) | `8200:8200` | `vault status` (20s) |

The five Java images are built from the sibling repos (`build: ../<service>`), so all five
`Dockerfile`s and `.dockerignore`s from Etapa-03 must exist before `up --build`. Both
Postgres containers keep their data on the ephemeral tmpfs described in "Ephemeral data
directory", and both mount `./postgres/init-multiple-dbs.sh` into
`/docker-entrypoint-initdb.d/`.

The env names each container reads are defined as defaults in `compose.yml`
(`POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `POSTGRES_MULTIPLE_DATABASES`,
`RABBITMQ_DEFAULT_USER`, `RABBITMQ_DEFAULT_PASS`, `VAULT_DEV_ROOT_TOKEN_ID`,
`CONFIG_GIT_URI`, `SERVER_PORT_*`, `CONFIG_URI`, `EUREKA_URI`, `VAULT_URI`, `VAULT_TOKEN`,
`SPRING_CLOUD_VAULT_TOKEN`, `SPRING_DATASOURCE_*`, `SPRING_RABBITMQ_*`), but with
container DNS values instead of loopback: `http://config-service:8888`,
`http://discovery-service:8761/eureka/`, `http://vault:8200`, `rabbitmq`,
`jdbc:postgresql://postgres-<inventory|uom>:5432/<inventory_db|unit_of_measure_db>`.
`VAULT_TOKEN` and `SPRING_CLOUD_VAULT_TOKEN` are the I-06 double mapping: both are fed
from `VAULT_DEV_ROOT_TOKEN_ID`, so the YAML placeholder and Boot's relaxed binding can
never drift into a 403. The vault container keeps its own literal
`VAULT_ADDR=http://127.0.0.1:8200`, because its healthcheck runs `vault status` inside the
container and the Vault CLI would otherwise default to `https`.

### Running multiple instances

The gateway and the two business services are stateless and register in Eureka; the gateway
resolves inventory and unit of measure with `lb://` (Spring Cloud LoadBalancer, round-robin).
Only those three are Eureka clients; `config-service` and `discovery-service` are outside
the `lb://` path. `discovery-service` is the single registry — scaling it as-is would create
an independent registry, not a replica — so it is out of scope here.

- Each replica registers as `${spring.application.name}:${random.uuid}` with
  `prefer-ip-address: true`, so instances do not overwrite each other in the registry.
- The gateway targets `lb://inventory-service` and `lb://unit-of-measure-service`; it
  neither knows nor needs the instance port.
- The dev seed is idempotent (`ON CONFLICT DO NOTHING`), so a second inventory or unit of
  measure instance can start against the same database without duplicating rows.
- No service sets `container_name`, so Compose can create more than one container per
  service.

**Bare metal / JVM.** `server.port` is `${SERVER_PORT:8081}` (inventory) and
`${SERVER_PORT:8082}` (unit of measure) in `centralized-configuration`. From `infra/`,
start a second copy with a different port, or let the OS pick one:

```bash
cd ../inventory-service && SERVER_PORT=0 java -jar target/inventory-service-*.jar
```

With `SERVER_PORT=0`, the bound port appears in the startup log and is what Eureka
registers, so the gateway reaches the new instance. Start the first instance and wait for
its health endpoint before starting the next: the `dev` profile uses `ddl-auto: update`, and
concurrent schema updates against the same database are not safe (see the limitation below).

**Docker Compose.** The in-container port is not the blocker: every container has its own
network namespace, so two replicas can both listen on `8081` (or `8082`). The **host**
publish is what prevents `--scale` (the `127.0.0.1:8081:8081` entry in "The nine default
services"), because both replicas would bind the same host port. Drop the publish for the
replicas with an override file and scale in two steps, waiting for the first replica to be
healthy before adding the second (see the limitation below):

```yaml
# scale.override.yml
services:
  inventory-service:
    ports: !reset []
  unit-of-measure-service:
    ports: !reset []
```

```bash
# 1. Start one replica and wait until it is healthy.
docker compose -f compose.yml -f scale.override.yml up -d

# 2. Add the second replica; the schema already exists.
docker compose -f compose.yml -f scale.override.yml up -d --scale inventory-service=2
```

`!reset` is supported by current Compose releases; the publish workflow pins Compose
2.40.3. The container healthchecks probe `localhost:8081` (inventory) and `localhost:8082`
(unit of measure) inside each replica, so they keep working; the gateway also exposes
`/api/v1/inventory/actuator/health` and `/api/v1/uom/actuator/health` for external checks.
The per-container probe stays local on purpose: if it depended on the gateway, while the
gateway waits for the service to be healthy, the startup would deadlock.

**Limitation.** The `dev` profile uses `ddl-auto: update` and runs the SQL seed on every
start. The seed is idempotent, but Hibernate's schema update is not safe under concurrent
startup: start one instance, wait for it to be healthy, then start the next. For a
production-grade multi-instance deployment, replace `ddl-auto: update` with a migration
tool (Flyway or Liquibase) that applies each schema version once.

The published artifact (`elara-demo:<version>`) ships `compose.published.yml`; the override
above is a source-checkout capability. The artifact keeps the debug port bindings for the
single-instance demo.

### Memory and JVM sizing

`mem_limit` is `512M` for `api-gateway`, `inventory-service`, `unit-of-measure-service` and
both Postgres containers (the limit also covers the tmpfs pages charged to the container),
`256M` for `config-service`, `discovery-service` and `rabbitmq`, and `128M` for `vault`.
Each of the five Java services gets exactly
`JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=75` and no other JVM flag, so the JVM sizes its
heap from the container limit at startup (75% of `mem_limit`) — tune `mem_limit`, never
`-Xmx`, and note that the Dockerfiles keep no hardcoded heap of their own. All nine
services run with `restart: unless-stopped`; the profile-gated `vault-loader` is a one-shot
with `restart: "no"`.

### Config source (`CONFIG_GIT_URI`)

`config-service` clones from `CONFIG_GIT_URI`, whose default is `/config-repo` — a
read-only bind mount of `../centralized-configuration`, relative to `compose.yml`. JGit
only reads that repo and clones it into the container's own basedir, so `:ro` is enough,
and the stack works offline with no GitHub credentials. To clone from GitHub or from
another branch instead, set in the environment:

```bash
CONFIG_GIT_URI=https://github.com/elara-app/centralized-configuration.git
CONFIG_GIT_DEFAULT_LABEL=main      # branch the Config Server clones
```

`CONFIG_GIT_DEFAULT_LABEL` maps to `SPRING_CLOUD_CONFIG_SERVER_GIT_DEFAULT_LABEL` and
matches `default-label: main` in `config-service/application.yml`. The port of
`discovery-service` is hardcoded (`server.port: 8761`, no placeholder in its
`application.yml`), so `SERVER_PORT_DISCOVERY` is belt-and-braces there.

## Verification status

This stage verifies with deterministic offline proofs only: `bash -n`, `jq empty`, git
mode checks, mocked `vault`/`psql` CLIs that exercise the retry, idempotency and failure
paths, plus `docker compose config` (which needs no daemon) over the whole `compose.yml`
and `python3 -c "yaml.safe_load(...)"` structural checks of the same file. Compose is never
allowed to reach the daemon here: image builds (`docker build`) and container runtime
verification are **deferred to ETAPA-04 (E0/E1)**, as is the live evidence (Vault healthy,
`vault kv get secret/<app>/dev` returning all 4 keys of each service's dev secret,
`SELECT 1` against both databases — E3/E6/E7), because
this development machine has no Docker daemon.
