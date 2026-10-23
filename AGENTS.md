# AGENTS — infrastructure

## Read first

- [`README.md`](README.md) — quickstart, stack overview, interfaces and verification targets. The canonical `$ELARA` command block lives there only.
- [`docs/operations.md`](docs/operations.md) — Vault bootstrap, Postgres/seed/restart semantics, scaling, published artifacts, scripts, gotchas.
- `compose.yml`, `compose.published.yml`, `compose.logs.yml` — the contracts this file summarizes; source wins over prose.
- `centralized-configuration` — profile matrix, property ownership, Vault paths (<https://github.com/elara-app/centralized-configuration>).

## Scope and boundaries

- This repo owns orchestration, the Vault/Postgres bootstrap, verification scripts and publish workflows. It contains no application code.
- Do not change service code, `centralized-configuration` files, or gateway routes from this repo.
- Compose files, scripts and workflows are contracts, not scratch space. Change them only when the task explicitly asks, and keep the docs that describe them in sync.
- One fact, one home: README owns quickstart and overview, `docs/operations.md` owns operational depth, this file owns rules and invariants. Never duplicate the full-stack command block outside `README.md`.

## Quick facts

- Artifact type: Compose files, shell scripts and a Dockerfile — no package or binary.
- Compose projects: `elara` (source) and `elara-demo` (published).
- Service IDs (Compose names = network DNS names): `config-service`, `discovery-service`, `api-gateway`, `inventory-service`, `unit-of-measure-service`, `postgres-inventory`, `postgres-uom`, `rabbitmq`, `vault`, `vault-loader`.
- Port source: source interpolates `SERVER_PORT_*` and keeps literal host publishes; published interpolates `ELARA_PORT_*` with loopback defaults.
- Runtime dependencies: Docker Engine + Compose v2; `bash`, `curl`, `jq` for the scripts.
- Published version: `VERSION` = `1.3.1`; artifact `ghcr.io/elara-app/elara-demo`.

## Commands

```bash
# Offline validation (no daemon)
docker compose -f compose.yml config --quiet
docker compose -f compose.published.yml config --quiet
docker compose -f compose.published.yml -f compose.logs.yml config --quiet
bash -n scripts/*.sh postgres/init-multiple-dbs.sh

# Runtime checks (daemon required; published stack only, project elara-demo)
COMPOSE_REF=./compose.published.yml bash scripts/smoke-test.sh
COMPOSE_REF=./compose.published.yml bash scripts/flow-check.sh   # stack must be running
COMPOSE_REF=oci://ghcr.io/elara-app/elara-demo:latest bash scripts/smoke-test.sh

# Manual release check (needs network)
bash scripts/check-release-version.sh

# Source Vault loader (one-shot)
sudo docker compose --profile bootstrap up vault-loader
```

Full-stack `up`/`logs`/`down` commands: `README.md` → "Run and verify".

## Repository map

| Path | Role |
|---|---|
| `compose.yml` | Source stack: 9 default services plus the profile-gated `vault-loader` |
| `compose.published.yml` | Published demo stack: 10 pull-only services |
| `compose.logs.yml` | Local Dozzle overlay for the published stack; never in the OCI artifact |
| `postgres/init-multiple-dbs.sh` | Source-only multi-database bootstrap |
| `scripts/setup-vault.sh` | Idempotent Vault KV v2 loader (host and loader image) |
| `scripts/smoke-test.sh` | Published-stack startup/seed/Vault smoke test |
| `scripts/flow-check.sh` | Gateway→inventory→UOM write-flow check; never starts the stack |
| `scripts/check-release-version.sh` | Manual `VERSION` ↔ pom agreement check |
| `vault-loader/Dockerfile` | Loader image: Vault 1.16.3 CLI plus bash/jq/coreutils |
| `VERSION` | Published artifact version |
| `.github/workflows/` | `compose-checks.yml` (PRs) and `publish-compose.yml` (main) |

## Contracts and invariants

- Service counts: the source default render is exactly 9 services; `vault-loader` stays behind `profiles: ["bootstrap"]`. The published render is exactly 10 services; its `vault-loader` must not gain a profile.
- Service IDs are lowercase Compose names and double as network DNS. Renaming one is a cross-repo change.
- Ports: source publishes 8888/8761/8080/5672/15672/8200 and loopback-only 8081/8082; published maps all 8 on `${ELARA_BIND:-127.0.0.1}`. Do not change a target port without the cross-repo protocol below.
- Healthchecks: every long-running service keeps its healthcheck (Java: `curl` on `/actuator/health`; Postgres: TCP `pg_isready`; RabbitMQ: `rabbitmq-diagnostics ping`; Vault: `vault status`). The loaders have none.
- Dependencies: business services and gateway use `condition: service_healthy`; published business services also require `vault-loader` `service_completed_successfully`; `config-service` and `discovery-service` have no `depends_on` and start in parallel — do not document an enforced discovery→config order.
- Restart: long-running services are `restart: unless-stopped`; loaders are `restart: "no"`. Source gateway/business dependencies carry `restart: true`; published carries none.
- Network and storage: exactly one bridge network `elara-net`; no top-level volumes, configs or secrets; Postgres PGDATA on a 128 MiB tmpfs; Vault dev mode with in-memory storage.
- Logging: bounded `json-file` (`max-size: 10m`, `max-file: 3`) on every service.
- Images: infrastructure images stay pinned (`postgres:16.15-alpine`, `rabbitmq:3.13.7-management-alpine`, `hashicorp/vault:1.16.3`). Published Elara images are `:latest` in the file; the `sha-<7>` and version artifacts pin all ten service images by digest and the config label to a commit SHA.

## Configuration and runtime

- No `.env`: every value has a `${VAR:-default}`, and the defaults are the supported configuration. A stray `.env` is auto-loaded by Compose and can break containers.
- Source overrides: `CONFIG_GIT_URI`, `CONFIG_GIT_DEFAULT_LABEL`, `VAULT_LOAD_PROFILES`, `POSTGRES_*`, `RABBITMQ_DEFAULT_*`, `TZ`, `VAULT_DEV_ROOT_TOKEN_ID`, `SERVER_PORT_*`, `CONFIG_URI`, `EUREKA_URI`, `VAULT_URI`, `SPRING_*`. Published overrides: `ELARA_BIND`, `ELARA_PORT_*`, `VAULT_DEV_ROOT_TOKEN_ID`.
- Source `VAULT_TOKEN`/`SPRING_CLOUD_VAULT_TOKEN` can be set independently from the host; published pins both to `VAULT_DEV_ROOT_TOKEN_ID`, and CI asserts host drift cannot reach them.
- Published `config-service` needs GitHub at startup (`clone-on-start: true`, image default URI); the source bind mount is the offline path.
- Vault paths `secret/inventory-service/dev` and `secret/unit-of-measure-service/dev` must hold 4 keys each (datasource username/password, RabbitMQ username/password). See `centralized-configuration` for the full matrix.

## Cross-repo change protocol

Changing a port, route path, service ID, database topology, Vault path or secret key requires coordinated changes, in this order: `centralized-configuration` (property/Vault/label files), the affected service (only its own config/README), `api-gateway` routing through the central config, `infrastructure` Compose files and their CI assertions, then the docs (`README.md`, `docs/operations.md`). Never land one side alone: CI asserts the published structure, and a half-migrated stack breaks the smoke and flow checks.

## Testing and quality gates

- PR gate (`compose-checks.yml`): renders source, published, a host-token-drift render, per-port overrides and the logs overlay; asserts the published service list, loopback ports, image pins, healthchecks, dependency conditions, loader command, one-DB-per-Postgres policy, logging and overlay invariants. Static only.
- Publish gate (`publish-compose.yml`): preflight, publish `sha-<7>` (digest-pinned images + config commit SHA label), verify structure, smoke sha, publish `latest` only when the run is current `infrastructure` main branch, smoke latest on amd64+arm64, start Dozzle, run `flow-check.sh`, tear down. The `VERSION` tag is published only if it matches the released sha artifact.
- `scripts/check-release-version.sh` is manual; no workflow checks pom/`VERSION` agreement.
- Gap to remember: `flow-check.sh` runs after `latest` is published, not against `sha-<7>` before promotion. Markdown-only pushes skip publishing entirely.

## Definition of done

- `docker compose ... config --quiet` passes for `compose.yml`, `compose.published.yml` and the logs overlay.
- `bash -n` passes for every script and the Postgres init script.
- No contract drift: service counts, IDs, ports, healthchecks, dependency conditions, restart policies, network, tmpfs and image pins unchanged — or the change was deliberate and the `compose-checks.yml` literal assertions were updated with it.
- Behavior changes are reflected in `README.md` and `docs/operations.md`.
- For a release, `VERSION` and all five service poms agree (`bash scripts/check-release-version.sh`).

## Stop and ask

- Changing the service count, service IDs, host ports, healthcheck semantics, dependency conditions or restart policies.
- Changing database topology (one vs both databases, init script), tmpfs size, Vault mode/token, or secret paths/keys.
- Changing loader behavior (skip vs overwrite, profiles, prod gate) or `compose.logs.yml` semantics.
- Changing published artifact tags, pinning policy, or the promotion order in `publish-compose.yml`.
- Adding anything to the published stack that is not pull-only: build contexts, bind mounts, env files, volumes, configs or secrets. The Docker socket stays confined to the local Dozzle overlay and never enters the artifact.

## Known traps

- Vault `mem_limit` is 512M in both stacks, not 128M.
- The source loader is get-or-put: existing paths are skipped, never repaired; `{}` files are skipped too.
- The script default `SECRETS_DIR` resolves under `infrastructure/` and does not exist in this layout; pass `SECRETS_DIR=../centralized-configuration/service-secrets` for host runs (the Compose loader mounts `/secrets`).
- Compose has no `--profiles` flag; the source loader knob is `VAULT_LOAD_PROFILES` (the host script takes `PROFILE`/`PROFILES`/`--profiles`).
- `docker compose restart` does not apply Compose-file changes; recreate with `up -d`. The tmpfs is discarded on restart.
- The Postgres init script accepts `-` and leading digits but interpolates names unquoted into `CREATE DATABASE`; keep plain identifiers.
- Published has no restart cascade: after a Postgres restart the services run against an empty database, and after a Vault restart the secrets are gone — recover manually.
- Published `:latest` floats; cached pulls can be stale. Use `--pull always` or a `sha-<7>`/`1.3.1` artifact.
- The source loader is not a dependency of the business services; run it before asserting secrets. The published loader is, via `service_completed_successfully`.
- Do not copy stage-4 runbook assertions onto the published stack (both-DB containers, restart cascade).

## Documentation maintenance

- Keep one fact in one home: README = quickstart/overview, `docs/operations.md` = depth, AGENTS = rules. Update all three when behavior changes.
- The canonical full-stack command block appears only in `README.md`.
- `docs/etapa-04-runbook.md` is a historical pointer; do not restate commands there.
- When Dependabot bumps a Compose image, update the literal pin assertions in `compose-checks.yml` in the same change.
