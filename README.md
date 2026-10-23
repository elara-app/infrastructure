# Elara infrastructure

`infrastructure` owns the local orchestration of the Elara platform: the source stack in `compose.yml`, the pull-only published demo stack in `compose.published.yml`, the Vault bootstrap (loader image and `scripts/setup-vault.sh`), the multi-database Postgres init script, the verification scripts under `scripts/` and the GitHub Actions workflows that publish and smoke the demo artifact. It contains no application code: in the source stack the five Java services are built from their sibling repositories, and their shared non-secret configuration lives in `centralized-configuration`. The published stack is a demo, not a production deployment.

## At a glance

| Fact | Value |
|---|---|
| Compose projects | `elara` (source, 9 default services) and `elara-demo` (published, 10 services) |
| Services | `config-service` (8888), `discovery-service` (8761), `api-gateway` (8080), `inventory-service` (8081), `unit-of-measure-service` (8082), `postgres-inventory`, `postgres-uom`, `rabbitmq` (5672/15672), `vault` (8200), `vault-loader` (one-shot) |
| Pinned images | `postgres:16.15-alpine`, `rabbitmq:3.13.7-management-alpine`, `hashicorp/vault:1.16.3` |
| Network | one user-defined bridge `elara-net`; no top-level volumes, configs or secrets |
| State | ephemeral on purpose: Postgres PGDATA is a 128 MiB tmpfs; Vault runs in dev mode with in-memory storage |
| Seeded data | 10 inventory items, 5 units of measure, 3 UOM statuses |
| Published artifact | `oci://ghcr.io/elara-app/elara-demo:latest` (also `:sha-<7>` and `:1.3.1`) |

## Responsibilities and boundaries

`infrastructure` owns:

- Both Compose stacks: service inventory, host ports, healthchecks, dependency conditions, restart policies and memory limits.
- The Vault bootstrap: `vault-loader/Dockerfile`, `scripts/setup-vault.sh`, the source `vault-loader` service and the published inline loader.
- `postgres/init-multiple-dbs.sh`, the source-only multi-database bootstrap.
- The published demo artifact and the publish/smoke workflows in `.github/workflows/`.
- The verification scripts: `scripts/smoke-test.sh`, `scripts/flow-check.sh`, `scripts/check-release-version.sh`.

`infrastructure` does not own:

- Application code, API behavior, Spring profiles or seed SQL; each service repository owns them.
- Shared non-secret configuration, the profile matrix and the dev-only secret JSON files; `centralized-configuration` owns them.
- The gateway route table; `centralized-configuration/api-gateway-dev.yml` owns it.

## Runtime architecture

Two stacks describe the same platform for different consumers. `compose.yml` is the source-development stack; `compose.published.yml` is the consumer/demo stack behind the OCI artifact.

| Dimension | Source `compose.yml` | Published `compose.published.yml` |
|---|---|---|
| Services | 9 in the default render; `vault-loader` hidden behind the `bootstrap` profile | 10; `vault-loader` is a default one-shot service |
| Java images | built from sibling repos (`build: ../<service>`) | pulled from GHCR (`ghcr.io/elara-app/<service>:latest` in the file) |
| Config source | read-only bind mount `../centralized-configuration:/config-repo`; Config Server `clone-on-start: false`, first request pays the clone | Config Server clones `github.com/elara-app/centralized-configuration` at startup (`clone-on-start: true`), label `main` in the file |
| Vault loader | profile-gated: hidden behind `bootstrap`, run manually as a one-shot; the host script is an alternative | inline default service: runs automatically before the business services and verifies both dev paths |
| Postgres databases | both containers create `inventory_db` and `unit_of_measure_db` via the init script | one database each (`POSTGRES_DB`), no init script |
| Restart cascade | `depends_on` uses `restart: true` on gateway and business services: a Compose restart of a dependency cascades | no `restart: true`: restarting Postgres or Vault leaves the services running |
| Host bindings | 8888/8761/8080/5672/15672/8200 on all interfaces; 8081/8082 loopback-only | all 8 mappings loopback by default via `ELARA_BIND` |

Lifecycle: `config-service` and `discovery-service` start in parallel (neither declares `depends_on`); Postgres, RabbitMQ and Vault start in parallel; each business service waits for config, discovery, its Postgres, RabbitMQ and Vault to be healthy (published additionally waits for the loader to complete); `api-gateway` waits for all four. Both stacks discard state by design: the Postgres tmpfs and the in-memory Vault are emptied by `down`, `restart` or container recreation. Source restarts cascade; published restarts do not (see `docs/operations.md`).

## Interfaces

| Service | Role | Host port (source) | Key dependency |
|---|---|---|---|
| `config-service` | Spring Cloud Config Server | 8888 | none |
| `discovery-service` | Eureka registry | 8761 | none |
| `api-gateway` | Edge router and Swagger UI | 8080 | config, discovery, inventory, UOM healthy |
| `inventory-service` | Item master data API | `127.0.0.1:8081` | config, discovery, postgres-inventory, rabbitmq, vault |
| `unit-of-measure-service` | UOM catalog and status API | `127.0.0.1:8082` | config, discovery, postgres-uom, rabbitmq, vault |
| `postgres-inventory` / `postgres-uom` | Databases | none (expose 5432) | none |
| `rabbitmq` | Broker for Spring Cloud Bus refresh | 5672, 15672 | none |
| `vault` | Dev-mode Vault (in-memory) | 8200 | none |
| `vault-loader` | One-shot secret bootstrap | none | vault healthy |

Published replaces every host port with `${ELARA_BIND:-127.0.0.1}:${ELARA_PORT_<NAME>:-<default>}`. Endpoints once the stack is healthy: Swagger UI `http://127.0.0.1:8080/swagger-ui.html`; Config Server `http://127.0.0.1:8888/<application>/<profile>`; Eureka dashboard and registry `http://127.0.0.1:8761` and `/eureka/apps`; RabbitMQ management `http://127.0.0.1:15672`; Vault `http://127.0.0.1:8200`.

## Run and verify

Prerequisites: Docker Engine with the Compose v2 plugin (`docker compose version`), and either `sudo` or membership in the `docker` group. The source stack additionally needs the five sibling repositories checked out next to `infrastructure/` (build contexts), with their Dockerfiles and `.dockerignore` files.

Canonical full-stack commands:

```bash
# Source checkout: absolute path to infrastructure/compose.yml
export ELARA="/absolute/path/to/elara/infrastructure/compose.yml"

# Or the published demo artifact:
# export ELARA="oci://ghcr.io/elara-app/elara-demo:latest"

sudo docker compose -f "$ELARA" up -d --wait --wait-timeout 900
sudo docker compose -f "$ELARA" logs -f
sudo docker compose -f "$ELARA" down
```

`up -d --wait` blocks until every long-running service is healthy (up to 15 minutes). The source stack builds five images and the loader; the published stack only pulls images. `logs -f` follows until Ctrl+C. `down` removes the containers and, with them, the ephemeral Postgres data and Vault secrets.

### Verify the stack

- Swagger UI: `http://127.0.0.1:8080/swagger-ui.html`
- Inventory collection through the gateway: `http://127.0.0.1:8080/api/v1/inventory/item/`
- UOM root: `http://127.0.0.1:8080/api/v1/uom/`
- UOM status root: `http://127.0.0.1:8080/api/v1/uom/status/`

The gateway prefix `/api/v1/inventory` is not the inventory collection path; `StripPrefix=3` maps `/api/v1/inventory/item/` to the service's `/item/` controller mapping.

Expected seeded page counts (nested page shape):

```bash
curl -s http://127.0.0.1:8080/api/v1/inventory/item/ | jq '.page.totalElements'   # 10
curl -s http://127.0.0.1:8080/api/v1/uom/ | jq '.page.totalElements'            # 5
curl -s http://127.0.0.1:8080/api/v1/uom/status/ | jq '.page.totalElements'     # 3
```

Scripted checks (see `docs/operations.md` for what each one proves):

```bash
docker compose -f compose.yml config --quiet                      # offline render check
docker compose -f compose.published.yml config --quiet            # offline render check
COMPOSE_REF=./compose.published.yml bash scripts/smoke-test.sh    # starts the published stack
COMPOSE_REF=./compose.published.yml bash scripts/flow-check.sh    # needs the stack running
COMPOSE_REF=oci://ghcr.io/elara-app/elara-demo:latest bash scripts/smoke-test.sh
```

`smoke-test.sh` brings the published stack up, asserts 3 Eureka applications, seed counts 10/5/3 through the gateway, exactly 10 Compose services (9 healthy plus an exited `vault-loader`) and 4 keys in both Vault dev paths. `flow-check.sh` never starts the stack: it POSTs one inventory item through the gateway, waits for the inventory and UOM log markers, deletes the item and waits for the count to return to 10. Both scripts target the published stack (project `elara-demo`). Live `sudo docker compose up` was not run in this documentation workspace; validation here was static (`config --quiet` renders and `bash -n`), so run the manual acceptance above on a machine with a working daemon.

## Configuration

No `.env` file is checked in or supported: every interpolated value carries a `${VAR:-default}` and the defaults are the supported configuration. Compose still auto-loads a stray `.env`, which can inject host loopbacks into containers, so do not add one.

Source knobs: `CONFIG_GIT_URI` (default `/config-repo`), `CONFIG_GIT_DEFAULT_LABEL` (default `main`), `VAULT_LOAD_PROFILES` (default `dev`), `POSTGRES_USER`/`POSTGRES_PASSWORD`, `TZ`, `RABBITMQ_DEFAULT_USER`/`RABBITMQ_DEFAULT_PASS`, `VAULT_DEV_ROOT_TOKEN_ID`, `SERVER_PORT_*`, `CONFIG_URI`, `EUREKA_URI`, `VAULT_URI`, and the datasource/RabbitMQ variables. Published knobs: `ELARA_BIND` (default `127.0.0.1`), one `ELARA_PORT_<SERVICE>` per mapping (defaults 8888/8761/8080/8081/8082/5672/15672/8200) and `VAULT_DEV_ROOT_TOKEN_ID`.

Service-specific configuration, the profile matrix and Vault paths (`secret/inventory-service/dev`, `secret/unit-of-measure-service/dev`) live in `centralized-configuration`. The full environment contract is in `docs/operations.md`.

## Testing and quality gates

- `docker compose -f compose.yml config --quiet` and `docker compose -f compose.published.yml config --quiet` must pass; CI also renders the logs overlay and asserts the published contract (service list, ports, healthchecks, loader, image pins).
- `bash -n scripts/*.sh postgres/init-multiple-dbs.sh` must pass.
- `.github/workflows/compose-checks.yml` runs on pull requests to `develop`/`main`; it is static (no container start).
- `.github/workflows/publish-compose.yml` runs on push to `main`: publishes the `sha-<7>` artifact (digest-pinned images, config commit SHA label), verifies its structure, smokes it, then publishes `latest` only when the run is current `infrastructure` main branch, smokes latest on amd64 and arm64, and runs `flow-check.sh`. Markdown-only pushes skip publishing.
- `bash scripts/check-release-version.sh` checks that `VERSION` (currently `1.3.1`) matches all five service poms; it is manual and needs network access.

## Current limitations

- The published stack is a demo, not production: dev Vault with a known root token, dev database and RabbitMQ credentials, no persistence, no TLS, a public GitHub config clone and a single Eureka registry.
- All state is ephemeral by design; there is no backup or persistence path.
- `:latest` floats, and a cached pull can be stale; only the `sha-<7>` and `1.3.1` artifacts pin images by digest and the config by commit SHA.
- Published `config-service` needs GitHub access at startup; the source bind mount is the offline path.
- Scaling is a source-checkout capability only and is blocked by host publishes until you remove them with an override; `discovery-service` is a single registry, not a cluster.
- The published `vault-loader` runs before the business services only because of `depends_on`; restarting Vault alone does not re-run it.
- CI runs `flow-check.sh` only after `latest` is published, so a flow regression can leave `latest` published.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Published services return database errors after restarting Postgres | no `restart: true` in the published stack; the tmpfs database is empty | `docker compose restart inventory-service unit-of-measure-service` |
| `vault kv get` returns 403/404 after restarting Vault | Vault dev storage is in-memory | re-run the loader (source: `--profile bootstrap up vault-loader`; published: `up -d vault-loader`) |
| The published stack still runs old code after `up` | `:latest` pull policy keeps a cached image | use `:sha-<7>`/`:1.3.1`, or run `docker compose pull` first |
| The source loader reports `skip` for a path you want to change | get-or-put never overwrites an existing path | remove the Vault path or load a new profile, then re-run |
| The loader fails with "secrets directory does not exist" | the script default `SECRETS_DIR` resolves under `infrastructure/` and does not exist | pass `SECRETS_DIR=../centralized-configuration/service-secrets` |
| Published `config-service` stays unhealthy | no GitHub access for the startup clone | fix connectivity, or use the source stack |
| `up` fails with a port conflict | another stack or process uses the same host port | stop the other stack, or change `ELARA_PORT_*` (published) |

## Documentation

- [`AGENTS.md`](AGENTS.md) — agent rules, invariants, commands and traps for this repository.
- [`docs/operations.md`](docs/operations.md) — detailed operations: Vault bootstrap, Postgres/seed/restart semantics, scaling, published artifacts, scripts, gotchas.
- [`docs/etapa-04-runbook.md`](docs/etapa-04-runbook.md) — historical stage-4 runbook; superseded, kept as a pointer only.
- `centralized-configuration` — profile matrix, property ownership, Vault secret paths: <https://github.com/elara-app/centralized-configuration>.
- Service repositories: <https://github.com/elara-app/api-gateway>, <https://github.com/elara-app/discovery-service>, <https://github.com/elara-app/config-service>, <https://github.com/elara-app/inventory-service>, <https://github.com/elara-app/unit-of-measure-service>.
