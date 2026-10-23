# Operations

Detailed current operations for the two Elara stacks. Quickstart commands live in
[`../README.md`](../README.md); agent rules live in [`../AGENTS.md`](../AGENTS.md). Source
files win over this prose.

## Stack inventory

### Shared facts

- Both projects use one bridge network, `elara-net`; no top-level volumes, configs or secrets.
- Logging is bounded `json-file` (`max-size: 10m`, `max-file: 3`) on every service.
- Long-running services use `restart: unless-stopped` and declare a healthcheck; both loaders use `restart: "no"` and have none.
- No service sets `container_name`; every long-running service declares `expose` for its in-network port (documentary on a user-defined bridge).
- The five Java images are multi-stage Maven builds on `eclipse-temurin:21.0.12.1_1-jre`, install `curl` and `tzdata`, run as uid `10001` and hardcode no heap. Each Java service gets exactly `JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=75`.
- Infrastructure images are pinned identically in both stacks: `postgres:16.15-alpine`, `rabbitmq:3.13.7-management-alpine`, `hashicorp/vault:1.16.3`.

### Source stack (`compose.yml`, project `elara`)

| Service | Image / build | Host publish → container | `depends_on` | `mem_limit` |
|---|---|---|---|---|
| `config-service` | build `../config-service` | `8888:8888` | none | 256M |
| `discovery-service` | build `../discovery-service` | `8761:8761` | none | 256M |
| `api-gateway` | build `../api-gateway` | `8080:8080` | config, discovery, inventory, UOM — healthy, `restart: true` | 512M |
| `inventory-service` | build `../inventory-service` | `127.0.0.1:8081:8081` | config, discovery, postgres-inventory, rabbitmq, vault — healthy, `restart: true` | 512M |
| `unit-of-measure-service` | build `../unit-of-measure-service` | `127.0.0.1:8082:8082` | config, discovery, postgres-uom, rabbitmq, vault — healthy, `restart: true` | 512M |
| `postgres-inventory` | `postgres:16.15-alpine` | none; expose 5432 | none | 512M |
| `postgres-uom` | `postgres:16.15-alpine` | none; expose 5432 | none | 512M |
| `rabbitmq` | `rabbitmq:3.13.7-management-alpine` | `5672:5672`, `15672:15672` | none | 256M |
| `vault` | `hashicorp/vault:1.16.3` | `8200:8200` | none | 512M |
| `vault-loader` | build `./vault-loader`, profile `bootstrap` | none | vault healthy | unset |

- `config-service` bind-mounts `../centralized-configuration:/config-repo:ro` and defaults `CONFIG_GIT_URI=/config-repo`; the app uses `clone-on-start: false`, so the first config request pays the clone. `CONFIG_GIT_URI`/`CONFIG_GIT_DEFAULT_LABEL` can point at GitHub or another branch.
- Both Postgres containers receive `POSTGRES_MULTIPLE_DATABASES=inventory_db,unit_of_measure_db` and mount `./postgres/init-multiple-dbs.sh`, so each creates both databases.
- `vault` runs `server -dev` with a root token from `VAULT_DEV_ROOT_TOKEN_ID` (default `00000000-0000-0000-0000-000000000000`), `cap_add: IPC_LOCK`, and a literal `VAULT_ADDR=http://127.0.0.1:8200` for its in-container CLI healthcheck.
- `api-gateway` carries the label `com.elara.demo.release: "2026-10-20"`.

### Published stack (`compose.published.yml`, project `elara-demo`)

| Service | Image | Published host mapping | `depends_on` | `mem_limit` |
|---|---|---|---|---|
| `config-service` | `ghcr.io/elara-app/config-service:latest` | `${ELARA_BIND:-127.0.0.1}:${ELARA_PORT_CONFIG:-8888}:8888` | none | 256M |
| `discovery-service` | `ghcr.io/elara-app/discovery-service:latest` | `${ELARA_BIND:-127.0.0.1}:${ELARA_PORT_DISCOVERY:-8761}:8761` | none | 256M |
| `api-gateway` | `ghcr.io/elara-app/api-gateway:latest` | `${ELARA_BIND:-127.0.0.1}:${ELARA_PORT_GATEWAY:-8080}:8080` | config, discovery, inventory, UOM — healthy | 512M |
| `inventory-service` | `ghcr.io/elara-app/inventory-service:latest` | `${ELARA_BIND:-127.0.0.1}:${ELARA_PORT_INVENTORY:-8081}:8081` | config, discovery, postgres-inventory, rabbitmq, vault healthy; vault-loader completed | 512M |
| `unit-of-measure-service` | `ghcr.io/elara-app/unit-of-measure-service:latest` | `${ELARA_BIND:-127.0.0.1}:${ELARA_PORT_UOM:-8082}:8082` | config, discovery, postgres-uom, rabbitmq, vault healthy; vault-loader completed | 512M |
| `postgres-inventory` | `postgres:16.15-alpine` | none; expose 5432 | none | 512M |
| `postgres-uom` | `postgres:16.15-alpine` | none; expose 5432 | none | 512M |
| `rabbitmq` | `rabbitmq:3.13.7-management-alpine` | loopback `${ELARA_PORT_RABBITMQ:-5672}`, `${ELARA_PORT_RABBITMQ_MGMT:-15672}` | none | 256M |
| `vault` | `hashicorp/vault:1.16.3` | loopback `${ELARA_PORT_VAULT:-8200}:8200` | none | 512M |
| `vault-loader` | `hashicorp/vault:1.16.3` | none | vault healthy | unset |

- The file is pull-only: no build contexts, bind mounts, env files, configs or secrets. `config-service` clones the public GitHub repository at startup (`SPRING_CLOUD_CONFIG_SERVER_GIT_CLONE_ON_START: "true"`, label `main`) and sets no `CONFIG_GIT_URI`, so the image default URI is used and startup needs GitHub access.
- Each Postgres has only `POSTGRES_DB` (`inventory_db` or `unit_of_measure_db`), a 128 MiB tmpfs and no init script: one database per container.
- The loader is a plain `hashicorp/vault:1.16.3` container with an `/bin/sh -c` entrypoint; it writes 4 keys to each `secret/<app>/dev` path, verifies both with `vault kv get`, and exits.
- All 8 host mappings are loopback by default; there are no profiles and no `container_name`.

## Startup and dependency order

1. Compose creates `elara-net` and starts the services without dependencies: `config-service` and `discovery-service` in parallel (neither declares `depends_on` — there is no enforced discovery→config order), and Postgres, RabbitMQ and Vault in parallel.
2. The published `vault-loader` starts once `vault` is healthy, writes and verifies the two dev secret paths, and exits 0.
3. Each business service starts once config, discovery, its Postgres, RabbitMQ and Vault are healthy — and, in the published stack, once `vault-loader` completed successfully. `api-gateway` starts once config, discovery and both business services are healthy.
4. `up -d --wait --wait-timeout 900` blocks until all long-running services are healthy. The source loader is not part of the default start.

A single `docker compose up -d` is safe because `depends_on` encodes the order. Vault is imported optionally by the two business services (`fail-fast: false`), so they tolerate an empty Vault and still come up; the source loader exists to assert the secrets, not to make startup succeed. The stage-4 runbook observed a source re-up taking roughly 2–4 minutes (config clone, `ddl-auto: update`, seed, Eureka registration) — a historical observation, not a budget.

## Vault bootstrap

Vault runs in dev mode in both stacks: in-memory storage, unsealed, root token from `VAULT_DEV_ROOT_TOKEN_ID`. Any restart, recreate or `down` empties it, and `depends_on` does not restore it.

### Source loader

`vault-loader` is hidden behind `profiles: ["bootstrap"]` and is not part of the default 9-service render. Run it manually:

```bash
sudo docker compose --profile bootstrap up vault-loader
```

The loader image (`vault-loader/Dockerfile`) copies the Vault 1.16.3 CLI from the server image into `alpine:3.21.8` with bash, jq and coreutils. The service waits for `vault` healthy, mounts `./scripts:/work/scripts:ro` and `../centralized-configuration/service-secrets:/secrets:ro`, and runs `setup-vault.sh` with `SECRETS_DIR=/secrets` and `PROFILES=${VAULT_LOAD_PROFILES:-dev}`. It exits 0 and stays exited (`restart: "no"`); it is not a dependency of the business services.

The same script runs on the host, which then needs `vault`, `jq` and `base64` in `PATH`:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=00000000-0000-0000-0000-000000000000
SECRETS_DIR=../centralized-configuration/service-secrets PROFILES=dev ./scripts/setup-vault.sh
```

### Script semantics

- Requires `vault`, `jq`, `base64`; `VAULT_TOKEN` must be non-empty; `WAIT_TIMEOUT` (default 60s) must be a non-negative integer.
- Polls `vault status` until the command exits 0; a sealed status is only logged (`status.sealed=...`), not rejected.
- Validates each selected file with `jq` and requires a top-level object; derives the path from the filename `<app>-<profile>-secrets.json` as `secret/<app>/<profile>` (short prefixes such as `uom` are never used).
- Converts every JSON entry into one base64-protected `key=value` argument, so values with `=` or newlines stay a single argument.
- Idempotency is get-or-put, skip-if-present: an existing path is reported `skip` and never overwritten; a `vault kv get` exit of 2 (not found) triggers `kv put`; any other get error counts as `failed`. A file with no pairs (for example `{}`) is skipped.
- Prints a `loaded/skipped/failed` summary; any failure exits non-zero. Prod loading requires a non-local `VAULT_ADDR` **and** `CONFIRM_PROD=yes`, checked before any network contact; prod files that are merely present on disk are not selected and not gated.
- Selection: the Compose loader reads `VAULT_LOAD_PROFILES` (default `dev`); the host script reads `PROFILES`, `PROFILE`, `--profiles dev,test` or `--all-profiles`.

### Idempotency, repair and the default-path trap

Existing paths are never repaired: wrong or missing keys inside an existing path stay as they are and a re-run reports `skip`. To apply changed values, remove the Vault path or load a different profile, then re-run the loader.

The script default `SECRETS_DIR` is wrong for this layout: it resolves to `infrastructure/centralized-configuration/service-secrets`, which does not exist, and the run fails with "secrets directory ... does not exist". Always pass `SECRETS_DIR=../centralized-configuration/service-secrets` for host runs. The Compose loader is unaffected because it mounts `/secrets` explicitly.

### Published inline loader

The published loader is a default service: it writes 4 keys to `secret/inventory-service/dev` and `secret/unit-of-measure-service/dev` (`spring.datasource.username/password=postgres`, `spring.rabbitmq.username/password=elara`), verifies both with `kv get`, and exits. It depends on `vault` healthy; the business services wait for `service_completed_successfully`. Re-running it overwrites the same dev values instead of skipping, and it is the documented recovery after a Vault restart (its container is a completed one-shot, so start it again):

```bash
docker compose up -d vault-loader
```

### Restart and data loss

Any Vault restart or recreate empties all secrets in both stacks. Re-run the source one-shot or the published loader, then re-check `vault kv get secret/<app>/dev`.

## Postgres, seed and restart semantics

### Databases and init

- Source: each Postgres container creates **both** `inventory_db` and `unit_of_measure_db` on every empty-PGDATA start, using the init script (`ON_ERROR_STOP=1`, guarded `CREATE DATABASE ... WHERE NOT EXISTS` through `\gexec`).
- Published: one database per container (`POSTGRES_DB`, literal), no init script; the official image creates only that database. Do not transfer source both-database assertions to published.
- The init script trims whitespace around comma-separated names and rejects characters outside letters, digits, `_` and `-`, but interpolates the name unquoted into `CREATE DATABASE`, so a name with `-` or a leading digit can fail at execution. Keep plain identifiers.

### Ephemeral tmpfs

Both stacks keep PGDATA (`/var/lib/postgresql/data`) on a 128 MiB tmpfs (`size: 134217728`). Data does not survive a stop, restart, `down`, host reboot or recreation, and `initdb` plus the init script run again on every start. The cap also holds WAL and temporary files, so bulk loads can hit `ENOSPC`; tmpfs pages count against the container `mem_limit`.

### Startup seed

Seeding is application-side and dev-profile only (`ddl-auto: update`, `sql.init.mode: always`, deferred datasource initialization, `classpath:db/dev/seed.sql`). Hibernate creates or updates the schema, then the seed runs before the HTTP port opens, so a healthy container already carries the rows.

- Inventory: 10 items; ids 1 and 2 are `Steel Bolt M10` (UOM 1) and `Aluminum Sheet 4x8` (UOM 2) — the id contract with the UOM seed.
- UOM: 3 statuses (Active, Inactive, Deprecated) and 5 units (Kilogram 1.0, Gram 0.001, Pound 0.454, Ounce 0.028, Tonne 1000.0).
- Inserts are idempotent (`ON CONFLICT DO NOTHING` plus identity-sequence resync); restarting only a service never duplicates rows.
- `ddl-auto: update` is not safe under concurrent startup; start replicas sequentially (see Scaling).

### Restart matrix

| Action | Source | Published |
|---|---|---|
| Compose restart of `postgres-inventory`/`postgres-uom` | Cascades to the dependent service and the gateway (`restart: true`); schema and seed are re-created | Restarts only Postgres: no `restart: true` anywhere. Services stay running against an empty database |
| `restart --no-deps`, raw `docker restart`, OOM kill of Postgres | No cascade; services run against an empty database until restarted by hand | Same |
| Restarting a business service | Re-runs the seed idempotently against the existing tmpfs database | Same |
| Restarting/recreating `vault` | Secrets lost; re-run the one-shot | Secrets lost; re-run the loader |
| Host reboot / daemon restart | Containers restart by `unless-stopped`; Postgres is empty and services rebuild + reseed; Vault needs the loader | Same, plus the published loader must be re-run manually |

Recovery after a non-cascading Postgres restart:

```bash
docker compose restart inventory-service unit-of-measure-service
```

### `down` and reset

`down` removes the containers and the tmpfs databases with them; `down -v` is equivalent because neither file declares named volumes. In the source stack, `down` does not stop the profile-gated loader (profiles are not enabled for that command); remove it with `docker compose --profile bootstrap rm -f vault-loader`. In the published stack the loader is a default service and `down` removes it.

## Scaling (source only)

The gateway and both business services are Eureka clients; the gateway resolves inventory and UOM through `lb://` (Spring Cloud LoadBalancer, round-robin). `config-service` and `discovery-service` are outside the `lb://` path, and `discovery-service` is a single registry — scaling it creates an independent registry, not a replica.

- Replicas register as `${spring.application.name}:${random.uuid}` with `prefer-ip-address: true`. Count application names, not instances.
- No service sets `container_name`, so Compose can create more than one container per service.
- Host publishes on `8081`/`8082` (and the gateway's `8080`) prevent `--scale`. Remove them with an override using `ports: !reset []` (supported by the Compose 2.40.3 pinned in the publish workflow, and by current releases):

```yaml
# scale.override.yml
services:
  inventory-service:
    ports: !reset []
  unit-of-measure-service:
    ports: !reset []
```

- Start one replica, wait until healthy, then add the next: `ddl-auto: update` is not safe under concurrent schema updates. The per-container healthchecks probe `localhost` inside each replica, so they keep working.
- Published is a fixed single-instance demo; do not scale it.

## Memory and JVM

| Limit | Services |
|---|---|
| 256M | `config-service`, `discovery-service`, `rabbitmq` |
| 512M | `api-gateway`, `inventory-service`, `unit-of-measure-service`, `postgres-inventory`, `postgres-uom`, `vault` |
| unset | both loaders |

The five Java services run with exactly `JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=75` and no other JVM flag, so the JVM sizes its heap from the container limit (about 75% of `mem_limit`). Tune `mem_limit`, never `-Xmx`; the Dockerfiles hardcode no heap. Postgres tmpfs pages count against its 512M limit.

## Healthchecks

All Java healthchecks run `curl -f http://localhost:<port>/actuator/health` with interval 15s, timeout 5s and 10 retries; `start_period` is 90s for `config-service`, `inventory-service` and `unit-of-measure-service`, and 60s for `discovery-service` and `api-gateway`.

| Service(s) | Test | Interval / timeout / retries / start |
|---|---|---|
| `postgres-inventory`, `postgres-uom` | `pg_isready -h 127.0.0.1 -p 5432 -U $${POSTGRES_USER} -d $${POSTGRES_DB}` (CMD-SHELL) | 5s / 5s / 10 / 30s |
| `rabbitmq` | `rabbitmq-diagnostics ping` | 10s / 10s / 10 / 40s |
| `vault` | `vault status` | 5s / 5s / 10 / 20s |
| `vault-loader` (both stacks) | none | — |

The Postgres probe uses TCP on purpose: while `initdb` and the init script run, the image serves a temporary socket-only instance, so a socket probe could report ready too early. The nine long-running healthchecks are identical between the stacks; neither loader has one.

## Logging

Every service in both stacks uses the `json-file` driver capped at `max-size: 10m`, `max-file: 3`. The local Dozzle overlay (`compose.logs.yml`) adds a log viewer for the published stack only and is never part of the OCI artifact (see below).

## Environment contract

### No `.env`

No `.env` is checked in, and none is supported: every interpolated value carries a `${VAR:-default}` and the defaults point at container DNS. Compose still auto-loads a stray `.env` from the working directory and it beats the defaults; a `.env` with host loopbacks injects them into containers, where they point at the container itself. `.gitignore` already ignores `.env`, `.env.*` and logs.

### Source variables

| Variable | Default | Notes |
|---|---|---|
| `SERVER_PORT_CONFIG` / `_DISCOVERY` / `_GATEWAY` / `_INVENTORY` / `_UOM` | 8888 / 8761 / 8080 / 8081 / 8082 | Container listen port. Host publishes and healthcheck URLs are literal, so overriding these without an override file breaks the mapping; the discovery app port is hardcoded to 8761 |
| `CONFIG_GIT_URI` | `/config-repo` | Read-only bind mount of `../centralized-configuration` |
| `CONFIG_GIT_DEFAULT_LABEL` | `main` | Maps to `SPRING_CLOUD_CONFIG_SERVER_GIT_DEFAULT_LABEL` |
| `CONFIG_URI` | `http://config-service:8888` | |
| `EUREKA_URI` | `http://discovery-service:8761/eureka/` | |
| `SPRING_DATASOURCE_URL` | `jdbc:postgresql://postgres-inventory:5432/inventory_db` (inventory) / `...postgres-uom:5432/unit_of_measure_db` (UOM) | One variable name: a shell override hits both business services |
| `SPRING_DATASOURCE_USERNAME` / `_PASSWORD` | `postgres` / `postgres` | Shared by both business services |
| `SPRING_RABBITMQ_HOST` / `_PORT` / `_USERNAME` / `_PASSWORD` | `rabbitmq` / `5672` / `elara` / `elara` | Shared by both business services |
| `VAULT_URI` | `http://vault:8200` | |
| `VAULT_TOKEN` | `${VAULT_TOKEN:-${VAULT_DEV_ROOT_TOKEN_ID:-00000000-...}}` | Host value can diverge from `SPRING_CLOUD_VAULT_TOKEN` |
| `SPRING_CLOUD_VAULT_TOKEN` | `${SPRING_CLOUD_VAULT_TOKEN:-${VAULT_DEV_ROOT_TOKEN_ID:-00000000-...}}` | Boot's relaxed binding for the same secret |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` | `postgres` / `postgres` | |
| `POSTGRES_DB` | literal `inventory_db` / `unit_of_measure_db` | Not overridable |
| `POSTGRES_MULTIPLE_DATABASES` | `inventory_db,unit_of_measure_db` | Applied to both Postgres containers |
| `TZ` | `America/Bogota` | Postgres only |
| `RABBITMQ_DEFAULT_USER` / `_PASS` | `elara` / `elara` | |
| `VAULT_DEV_ROOT_TOKEN_ID` | `00000000-0000-0000-0000-000000000000` | Dev root token |
| `VAULT_LOAD_PROFILES` | `dev` | Profiles loaded by the source Compose loader |

### Published variables

| Variable | Default | Notes |
|---|---|---|
| `ELARA_BIND` | `127.0.0.1` | Bind address for all 8 mappings; `0.0.0.0` exposes the demo |
| `ELARA_PORT_CONFIG`, `_DISCOVERY`, `_GATEWAY`, `_INVENTORY`, `_UOM`, `_RABBITMQ`, `_RABBITMQ_MGMT`, `_VAULT` | 8888, 8761, 8080, 8081, 8082, 5672, 15672, 8200 | Per-mapping host ports |
| `ELARA_PORT_DOZZLE` | `9999` | Logs overlay only |
| `VAULT_DEV_ROOT_TOKEN_ID` | Dev root token | The only token variable the published file interpolates |
| everything else | literal | `SERVER_PORT`, `CONFIG_URI`, `EUREKA_URI`, datasource/RabbitMQ credentials, `SPRING_CLOUD_CONFIG_SERVER_GIT_CLONE_ON_START=true`, label `main` |

### Bind addresses and token mapping

- Source publishes config, discovery, gateway, RabbitMQ and Vault on all interfaces; inventory and UOM only on `127.0.0.1`; Postgres is not published. Published publishes all 8 mappings on loopback by default; `ELARA_BIND` changes all of them, so avoid `0.0.0.0` outside a throwaway machine.
- Source feeds both `VAULT_TOKEN` and `SPRING_CLOUD_VAULT_TOKEN` from the host variables if set, falling back to `VAULT_DEV_ROOT_TOKEN_ID`; published pins both directly to `VAULT_DEV_ROOT_TOKEN_ID`, and CI asserts host `VAULT_TOKEN` drift cannot reach the loader or the services. Compose never sets `SPRING_PROFILES_ACTIVE`; the profile defaults live in the services' `application.yml`.

## Published artifacts

The OCI artifact — not the file — is the pinned distribution:

| Tag | Contents |
|---|---|
| `ghcr.io/elara-app/elara-demo:latest` | The file as-is: 10 services, five Elara images at `:latest`, config label `main`, no digest pins. Floating |
| `ghcr.io/elara-app/elara-demo:sha-<7>` | All 10 service images pinned by digest (`@sha256:...`) and the config label pinned to a 40-hex `centralized-configuration` `main` commit SHA |
| `ghcr.io/elara-app/elara-demo:1.3.1` | The `VERSION` tag; published only when it matches the released sha artifact (same config SHA and image digests). Current `VERSION` and all five service poms are `1.3.1` |

`publish-compose.yml` runs on push to `main` (markdown paths ignored) or manual dispatch: prepare (short SHA, config SHA, current-run flag), preflight (service count, no build/env file/configs/secrets, tmpfs-only mounts, Vault 512M, `${EUREKA_URI:` placeholder in the three dev config files, multi-arch Elara images), publish `sha-<7>` with the config pin, verify the sha structure, smoke the sha artifact, publish `latest` only when the run is current `infrastructure` main branch, smoke `latest` on amd64 and arm64, start Dozzle, run `flow-check.sh`, tear down.

Known gaps:

- `flow-check.sh` runs only after `latest` is published; a flow regression can leave `latest` published although the sha artifact was smoke-tested.
- Markdown-only pushes skip publishing, so docs updates do not rebuild artifacts.
- `VERSION` is used by the workflow only to publish the version tag; pom agreement is checked by the manual `bash scripts/check-release-version.sh` (default `REF=main`, `ORG=elara-app`), not by CI.
- A plain `docker compose up` on the published file uses Compose's default pull policy, so a cached `:latest` can be stale. Use the version/sha artifacts or `--pull always`.

## `compose.logs.yml` overlay

The overlay adds an 11th service, `amir20/dozzle:v11.3.3`, on top of the published stack: `${ELARA_BIND:-127.0.0.1}:${ELARA_PORT_DOZZLE:-9999}:8080`, the Docker socket mounted read-only, actions/shell/analytics disabled and a `/dozzle healthcheck` probe. It exists because Dozzle needs the Docker socket; it is never part of the OCI artifact and must not be added to the published stack. It targets the published stack only.

## Scripts

### `scripts/smoke-test.sh` (published stack)

```bash
COMPOSE_REF=./compose.published.yml bash ./scripts/smoke-test.sh
COMPOSE_REF=oci://ghcr.io/elara-app/elara-demo:latest bash ./scripts/smoke-test.sh
```

Requires `bash`, `docker` + Compose v2, `curl` and `jq` on the host. Brings the stack up with `--pull always --wait-timeout 900` (or reuses a running stack with `SMOKE_SKIP_UP=1`) and asserts: exactly 3 Eureka applications (`API-GATEWAY`, `INVENTORY-SERVICE`, `UNIT-OF-MEASURE-SERVICE`); inventory `totalElements == 10`, UOM `5` and statuses `3` through the gateway; exactly 10 `compose ps` entries (9 healthy/running plus `vault-loader` exited 0); and all 4 keys present in both Vault dev paths. It expects the 10-service published stack, so it cannot validate the source 9-service stack.

### `scripts/flow-check.sh` (published stack, never starts it)

```bash
COMPOSE_REF=./compose.published.yml bash ./scripts/flow-check.sh
```

POSTs one uniquely named inventory item through the gateway (base UOM 1), waits for the inventory controller/service markers tied to that name plus the UOM client/controller markers, deletes the item and waits for the inventory count to return to 10. It accepts any 2xx POST and recovers a lost POST by name search. It proves gateway→inventory→UOM routing and persistence; it does not exercise a broader write matrix.

### `scripts/setup-vault.sh` (host or loader image)

See Vault bootstrap above. It proves the selected JSON files are syntactically valid, the paths are reachable/authenticated, and missing paths are written; it does not prove values or schema, and it skips existing paths.

### `scripts/check-release-version.sh` (manual)

```bash
bash scripts/check-release-version.sh [REF]   # default REF=main, ORG=elara-app
```

Reads `VERSION` (must be `X.Y.Z`) and fetches the five service poms from raw GitHub at `REF`, requiring each `<version>` to equal it. No workflow invokes it.

## Add-service checklist

Adding a service or profile touches several repositories; this is the infra-side checklist (the full procedure lives in `centralized-configuration`):

1. Decide whether the service belongs in the published demo artifact. The published stack is a fixed 10-service demo; adding a service there changes the artifact, the `compose-checks.yml` assertions and the `smoke-test.sh` expectations.
2. Add the config files and Vault path in `centralized-configuration` first (profile files, `service-secrets/<app>-dev-secrets.json`, gateway route if it is externally exposed).
3. Add the service to `compose.yml` with `expose`, a healthcheck, `restart: unless-stopped`, a `mem_limit`, the shared `x-logging` anchor, `elara-net` and `depends_on` conditions matching its runtime dependencies. Add `restart: true` only if a Compose restart of a dependency should cascade.
4. If published: add the GHCR image, a loopback port mapping, literal environment (no host interpolation except `ELARA_*` and `VAULT_DEV_ROOT_TOKEN_ID`) and extend the loader if the service needs secrets before startup.
5. Update CI assertions: the `compose-checks.yml` service list/ports/dependencies/pins, `publish-compose.yml` preflight where applicable, and the `smoke-test.sh` expectations.
6. Update `README.md`, `docs/operations.md` and `AGENTS.md` in the same change. Never add the full-stack command block outside `README.md`.

## Operational gotchas

1. **Published has no restart cascade.** `restart: true` is absent from every published `depends_on`, so restarting `postgres-*` leaves services against an empty database and restarting `vault` empties the secrets. Recover by restarting the business services and re-running the loader.
2. **Vault is in-memory in both stacks.** Any Vault restart/recreate loses `secret/*`; the published loader is a completed one-shot and is not re-run by restarting Vault.
3. **The source loader preserves bad data.** Existing paths are skipped even if keys are missing or wrong; `{}` files are skipped; there is no schema or value validation. Delete the path or use a new profile to repair.
4. **The source loader default path is wrong.** `SECRETS_DIR` defaults under `infrastructure/`, not the sibling config repo; pass `SECRETS_DIR=../centralized-configuration/service-secrets` from `infrastructure/`.
5. **Postgres init accepts invalid-looking names.** It permits `-` and leading digits but interpolates names unquoted into `CREATE DATABASE`; a name like `my-db` fails. Keep plain identifiers.
6. **Source exposes infrastructure ports on all interfaces.** 8888/8761/8080/5672/15672/8200 are not loopback-bound; only 8081/8082 are. Published defaults all to loopback, but `ELARA_BIND=0.0.0.0` exposes them.
7. **Dozzle has the Docker socket.** It is an explicit local overlay only, mounts `/var/run/docker.sock:ro`, and is not in the OCI artifact. Do not add it to the published stack.
8. **Published is demo-only.** Dev Vault, known root token, dev DB/Rabbit credentials, no persistence, no TLS, public GitHub config clone, single registry. Do not call it production-ready.
9. **Published `:latest` floats.** Only `sha-<7>` and `1.3.1` are digest/config pinned. Use the version artifact or `--pull always`.
10. **Source and published database assumptions differ.** Source: both databases in each Postgres, init script mounted. Published: one database each, no init script. Stage-4 runbook assertions written for source are false for published.
11. **Start order is not fully linear.** Config and discovery have no `depends_on` and can start in parallel; only the business services and the gateway encode health dependencies.
12. **`docker compose restart` does not apply Compose-file changes.** Recreate with `up -d` after editing a Compose file. The tmpfs is discarded on restart either way.
13. **Scaling is source-only and blocked by host ports.** Remove the publishes with `!reset` and start replicas sequentially because `ddl-auto: update` is not concurrency-safe. Published is fixed single-instance.
14. **Published config needs GitHub.** `clone-on-start: true` plus no `CONFIG_GIT_URI` means startup depends on GitHub access; the source bind mount is the offline path.
15. **A source re-up can hit a transient network race.** The stage-4 runbook observed the loader failing to attach to a freshly recreated network (`network ... not found`); remove it (`docker compose --profile bootstrap rm -f vault-loader`) and retry the one-shot. It is a daemon race, not a Compose configuration bug.
