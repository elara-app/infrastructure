# Elara Local Infrastructure

Local orchestration repo (no application code): Postgres multi-database bootstrap, the
idempotent Vault secret loader, `compose.yml` for the whole 9-service stack, and the
environment contract that compose wires into the containers.

See `../docs/ETAPA-02-infra-secretos.md` for the plan and `../docs/ETAPA-03-contenerizacion.md`
for the containerisation stage that consumes these files (both live in the `docs` repo
next to this one, not inside it).

## Layout

| Path | Purpose |
| --- | --- |
| `postgres/init-multiple-dbs.sh` | Creates every database the services need, idempotently. |
| `scripts/setup-vault.sh` | Loads `service-secrets/*.json` into Vault (KV v2), idempotently. |
| `vault-loader/Dockerfile` | One-shot Vault bootstrap image (vault 1.16 CLI + bash/jq/base64). |
| `compose.yml` | The 9-service stack on `elara-net` (5 Java builds + infra images). |
| `.env.example` | The full environment contract. Compose-safe defaults: copying it verbatim keeps compose's container DNS.

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
second pass. Names are comma separated, whitespace tolerant
(`POSTGRES_MULTIPLE_DATABASES="a , b"` creates `a` and `b`), and only plain identifiers
are accepted — anything else aborts before the SQL is built. If `POSTGRES_DB` is unset the
official image creates a database named after `POSTGRES_USER` instead, so always set it.
`compose.yml` mounts the script into `/docker-entrypoint-initdb.d/` of **both** Postgres
containers, so each of them creates the second database itself.

## Vault secrets (`scripts/setup-vault.sh`)

`centralized-configuration/service-secrets/` holds one JSON per service and profile,
named `<spring.application.name>-<profile>-secrets.json`. The script validates each
file with `jq`, derives the Vault path from that filename (`secret/<app>/<profile>`,
e.g. `secret/unit-of-measure-service/dev` — never a short prefix such as `uom`), and
writes each entry as a separate `key=value` argument.

```bash
cp .env.example .env
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
docker compose up -d vault        # dev mode: unsealed, root token from .env or the compose default
sudo docker compose --profile bootstrap up vault-loader   # waits for `vault` healthy via depends_on, loads `dev` by default
```

Profile selection: `VAULT_LOAD_PROFILES=test` in `.env` or `--profiles dev,test` appended
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

`compose.yml` starts all nine services on the `elara-net` bridge network. Every
interpolated value is written `${VAR:-<container DNS default>}`, so the stack is correct
with **no `.env` at all** — the defaults already are the compose service names.

```bash
docker compose config            # validate the file offline: no daemon needed
docker compose up -d --build     # build the five images and start everything (needs the daemon)
docker compose ps                # per-service state and health
docker compose logs <service> --tail=100
docker compose down -v           # stop and drop the pgdata-* volumes
```

### `.env` is optional — and now safe to copy

`cp .env.example .env` is safe for compose: without it the compose defaults point at
`config-service:8888`, `discovery-service:8761`, `postgres-inventory`/`postgres-uom:5432`,
`rabbitmq:5672` and `vault:8200`, and with it you get exactly the same — the four keys that
are *host-loopback values* are **commented out** in `.env.example`, so the copy cannot
override compose's container DNS defaults.

Compose auto-loads `.env` from this directory, and `.env` beats the compose defaults. That
is precisely why those four keys (`CONFIG_URI`, `EUREKA_URI`, `VAULT_URI`,
`SPRING_RABBITMQ_HOST`) are commented out rather than active: if you uncomment them (or
copy them in from somewhere else), the loopbacks are injected into the containers, where
`localhost` is the container itself and not the sibling service — the business services
then cannot reach the config server, Eureka, the broker or Vault, their health endpoint
reports `DOWN` (HTTP 503), and `api-gateway` waits forever on its `depends_on`. Leave them
commented for `docker compose`; they are what you uncomment when you run the services
**directly on the host** (IDEs, scripts, published container ports).

You only need a `.env` at all when you want to change something compose reads, namely:

- `VAULT_DEV_ROOT_TOKEN_ID` (feeds the dev server plus `VAULT_TOKEN`/`SPRING_CLOUD_VAULT_TOKEN` on both business services),
- `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_MULTIPLE_DATABASES`,
- `RABBITMQ_DEFAULT_USER`, `RABBITMQ_DEFAULT_PASS`.

Editable-but-optional keys are the numeric `SERVER_PORT_*`, `SPRING_DATASOURCE_*` and
`SPRING_RABBITMQ_*` values, plus `CONFIG_GIT_URI`/`CONFIG_GIT_DEFAULT_LABEL` and `TZ`.

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

### Published ports

| host port | service | note |
| --- | --- | --- |
| `8888` | `config-service` | config endpoint `/<app>/<profile>` + `/actuator/health` |
| `8761` | `discovery-service` | Eureka dashboard + `/eureka/apps` |
| `8080` | `api-gateway` | the only public entry point (`/api/v1/...`, `/inventory-service/...`) |
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

### The nine services

| service | image / build | ports | healthcheck |
| --- | --- | --- | --- |
| `config-service` | `build: ../config-service` | `8888:8888` | `curl -f http://localhost:8888/actuator/health` (start_period 90s) |
| `discovery-service` | `build: ../discovery-service` | `8761:8761` | `curl -f http://localhost:8761/actuator/health` (60s) |
| `api-gateway` | `build: ../api-gateway` | `8080:8080` | `curl -f http://localhost:8080/actuator/health` (60s) |
| `inventory-service` | `build: ../inventory-service` | `127.0.0.1:8081:8081` | `curl -f http://localhost:8081/actuator/health` (90s) |
| `unit-of-measure-service` | `build: ../unit-of-measure-service` | `127.0.0.1:8082:8082` | `curl -f http://localhost:8082/actuator/health` (90s) |
| `postgres-inventory` | `postgres:16-alpine` | none (expose 5432) | `pg_isready -U $POSTGRES_USER -d $POSTGRES_DB` (30s) |
| `postgres-uom` | `postgres:16-alpine` | none (expose 5432) | `pg_isready -U $POSTGRES_USER -d $POSTGRES_DB` (30s) |
| `rabbitmq` | `rabbitmq:3-management-alpine` | `5672:5672`, `15672:15672` | `rabbitmq-diagnostics ping` (40s) |
| `vault` | `hashicorp/vault:1.16` (dev) | `8200:8200` | `vault status` (20s) |

The five Java images are built from the sibling repos (`build: ../<service>`), so all five
`Dockerfile`s and `.dockerignore`s from Etapa-03 must exist before `up --build`. Both
Postgres containers persist to the named volumes `pgdata-inventory` / `pgdata-uom`, and
both mount `./postgres/init-multiple-dbs.sh` into `/docker-entrypoint-initdb.d/`.

The env names each container reads are the ones documented in `.env.example`
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

### Memory and JVM sizing

`mem_limit` is `512M` for `api-gateway`, `inventory-service` and `unit-of-measure-service`,
`256M` for `config-service`, `discovery-service`, both Postgres containers and `rabbitmq`,
and `128M` for `vault`. Each of the five Java services gets exactly
`JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=75` and no other JVM flag, so the JVM sizes its
heap from the container limit at startup (75% of `mem_limit`) — tune `mem_limit`, never
`-Xmx`, and note that the Dockerfiles keep no hardcoded heap of their own. All nine
services run with `restart: unless-stopped`.

### Config source (`CONFIG_GIT_URI`)

`config-service` clones from `CONFIG_GIT_URI`, whose default is `/config-repo` — a
read-only bind mount of `../centralized-configuration`, relative to `compose.yml`. JGit
only reads that repo and clones it into the container's own basedir, so `:ro` is enough,
and the stack works offline with no GitHub credentials. To clone from GitHub or from
another branch instead, set in `.env`:

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
