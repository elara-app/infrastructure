# Elara Local Infrastructure

Local orchestration repo (no application code): Postgres multi-database bootstrap, the
idempotent Vault secret loader, and the environment contract that Etapa-03's
`docker-compose.yml` wires into the containers.

See `../docs/ETAPA-02-infra-secretos.md` for the plan and `../docs/ETAPA-03-contenerizacion.md`
for the containerisation stage that consumes these files (both live in the `docs` repo
next to this one, not inside it).

## Layout

| Path | Purpose |
| --- | --- |
| `postgres/init-multiple-dbs.sh` | Creates every database the services need, idempotently. |
| `scripts/setup-vault.sh` | Loads `service-secrets/*.json` into Vault (KV v2), idempotently. |
| `.env.example` | The full environment contract (local-host dev defaults). |

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

## Etapa-03 handover (intended container wiring)

| Container | Image | Healthcheck |
| --- | --- | --- |
| `postgres-inventory`, `postgres-uom` | `postgres:16-alpine` | `pg_isready -U $POSTGRES_USER -d $POSTGRES_DB` |
| `rabbitmq` | `rabbitmq:3-management-alpine` | `rabbitmq-diagnostics ping` |
| `vault` | `hashicorp/vault:1.16` (dev mode) | `vault status` |

- Mount `postgres/init-multiple-dbs.sh` into `/docker-entrypoint-initdb.d/` of both
  Postgres containers (the script creates the second database itself).
- Feed the containers the env names of `.env.example`: `POSTGRES_USER`,
  `POSTGRES_PASSWORD`, `POSTGRES_DB`, `POSTGRES_MULTIPLE_DATABASES`,
  `RABBITMQ_DEFAULT_USER`, `RABBITMQ_DEFAULT_PASS`, `VAULT_DEV_ROOT_TOKEN_ID`,
  `VAULT_ADDR`, `VAULT_URI`, `VAULT_TOKEN`, `SPRING_CLOUD_VAULT_TOKEN`,
  `CONFIG_GIT_URI`, `CONFIG_URI`, `EUREKA_URI`, `SERVER_PORT_*`,
  `SPRING_DATASOURCE_USERNAME`, `SPRING_DATASOURCE_PASSWORD`, `SPRING_RABBITMQ_HOST`,
  `SPRING_RABBITMQ_PORT`, `SPRING_RABBITMQ_USERNAME`, `SPRING_RABBITMQ_PASSWORD`,
  plus the per-service `SPRING_DATASOURCE_URL` and `SERVER_PORT`.
- The values annotated `container DNS in compose` in `.env.example` are loopback
  defaults and must be overridden inside the container network:
  `VAULT_ADDR`/`VAULT_URI` → `http://vault:8200`, `CONFIG_URI` → `http://config-service:8888`,
  `EUREKA_URI` → `http://discovery-service:8761/eureka/`, `SPRING_RABBITMQ_HOST` → `rabbitmq`.
- Run `scripts/setup-vault.sh` as a one-shot job against the `vault` service before the
  business services start (it is idempotent and skips paths that already exist). The job
  image must provide `bash`, `vault`, `jq` AND `base64` — the official `hashicorp/vault`
  images ship neither `jq`, `bash` nor `base64`, so build the job on an image that does
  (for example `alpine` with `apk add bash vault jq`) rather than on `hashicorp/vault`.

## Verification status

This stage verifies with deterministic local proofs only: `bash -n`, `jq empty`, git
mode checks, and mocked `vault`/`psql` CLIs that exercise the retry, idempotency and
failure paths. Live evidence (Vault healthy, `vault kv get secret/<app>/dev` 2/2,
`SELECT 1` against both databases) is **deferred to ETAPA-04 (E3/E6/E7)** because this
development machine has no Docker daemon.
