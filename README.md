# Elara Local Infrastructure

Local orchestration repo (no application code): Postgres multi-database bootstrap, the
idempotent Vault secret loader, and the environment contract that Etapa-03's
`docker-compose.yml` wires into the containers.

See `docs/ETAPA-02-infra-secretos.md` for the plan and `docs/ETAPA-03-contenerizacion.md`
for the containerisation stage that consumes these files.

## Layout

| Path | Purpose |
| --- | --- |
| `postgres/init-multiple-dbs.sh` | Creates every database the services need, idempotently. |
| `scripts/setup-vault.sh` | Loads `service-secrets/*.json` into Vault (KV v2), idempotently. |
| `.env.example` | The full environment contract (dev defaults). |

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
second pass. Values are comma separated and whitespace tolerant
(`POSTGRES_MULTIPLE_DATABASES="a , b"` creates `a` and `b`).

## Vault secrets (`scripts/setup-vault.sh`)

`centralized-configuration/service-secrets/` holds one JSON per service and profile,
named `<spring.application.name>-<profile>-secrets.json`. The script validates each
file with `jq`, derives the Vault path from that filename (`secret/<app>/<profile>`,
e.g. `secret/unit-of-measure-service/dev` — never a short prefix such as `uom`), and
writes the entries as one `key=value` argument per entry.

```bash
cp .env.example .env
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=00000000-0000-0000-0000-000000000000   # or $VAULT_DEV_ROOT_TOKEN_ID
SECRETS_DIR=../centralized-configuration/service-secrets \
PROFILES=dev ./scripts/setup-vault.sh
```

Behaviour:

- `vault` and `jq` must be in `PATH`; the missing binary is named in the error.
- `VAULT_TOKEN` is required; `vault login` fails fast on a wrong token.
- Vault is polled until it answers unsealed (`WAIT_TIMEOUT`, default 60s).
- Load is get-or-put: an existing path is reported as skipped, never overwritten, so
  re-running is safe in local dev and CI.
- A summary (`loaded=`, `skipped=`, `failed=`) is printed; any failure exits non-zero.
- `SECRETS_DIR` defaults to `<script_dir>/../centralized-configuration/service-secrets`,
  i.e. the config repo checked out next to `scripts/` (export it to point elsewhere, as in
  the example above). `PROFILES`, `PROFILE`, `WAIT_TIMEOUT`, `--all-profiles` and
  `--profiles dev,test` select what gets loaded.

## DEV-ONLY policy and prod gating

By default only `*-dev-secrets.json` files are loaded, against a local Vault dev server.
Loading the `prod` profile requires both a non-local `VAULT_ADDR` (anything other than
`127.0.0.1`/`localhost`/`[::1]`) and `CONFIRM_PROD=yes`. There is no interactive prompt,
so unattended runs can never hang, and a misconfigured local run is refused before any
network contact. The values in `centralized-configuration/service-secrets/` are dev-only
credentials (`postgres/postgres` + `elara/elara`) and are safe to version; real secrets
belong in Vault only.

## Etapa-03 handover (intended container wiring)

| Container | Image | Healthcheck |
| --- | --- | --- |
| `postgres-inventory`, `postgres-uom` | `postgres:16-alpine` | `pg_isready -U $POSTGRES_USER -d $POSTGRES_DB` |
| `rabbitmq` | `rabbitmq:3-management-alpine` | `rabbitmq-diagnostics ping` |
| `vault` | `hashicorp/vault` (dev mode) | `vault status` |

- Mount `postgres/init-multiple-dbs.sh` into `/docker-entrypoint-initdb.d/` of both
  Postgres containers (the script creates the second database itself).
- Feed the containers the env names of `.env.example`: `POSTGRES_USER`,
  `POSTGRES_PASSWORD`, `POSTGRES_DB`, `POSTGRES_MULTIPLE_DATABASES`,
  `RABBITMQ_DEFAULT_USER`, `RABBITMQ_DEFAULT_PASS`, `VAULT_DEV_ROOT_TOKEN_ID`,
  `VAULT_ADDR`, `VAULT_TOKEN`, `SPRING_CLOUD_VAULT_TOKEN`, `CONFIG_GIT_URI`,
  `CONFIG_URI`, `EUREKA_URI`, `SERVER_PORT_*`, `SPRING_DATASOURCE_USERNAME`,
  `SPRING_DATASOURCE_PASSWORD`, `SPRING_RABBITMQ_HOST`, `SPRING_RABBITMQ_PORT`,
  `SPRING_RABBITMQ_USERNAME`, `SPRING_RABBITMQ_PASSWORD`, plus the per-service
  `SPRING_DATASOURCE_URL` and `SERVER_PORT`.
- Run `scripts/setup-vault.sh` as a one-shot job against the `vault` service before the
  business services start (it is idempotent and skips paths that already exist).

## Verification status

This stage verifies with deterministic local proofs only: `bash -n`, `jq empty`, git
mode checks, and mocked `vault`/`psql` CLIs that exercise the retry, idempotency and
failure paths. Live evidence (Vault healthy, `vault kv get secret/<app>/dev` 2/2,
`SELECT 1` against both databases) is **deferred to ETAPA-04 (E3/E6/E7)** because this
development machine has no Docker daemon.
