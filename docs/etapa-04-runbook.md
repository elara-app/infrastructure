# ETAPA-04 — Corrected E2E runbook (executable protocol)

> This is the executable runbook for `../docs/ETAPA-04-verificacion-e2e.md`, corrected against
> the repos as actually built in Etapas 01–03. Where the plan doc and reality disagree, **this
> file wins** (the plan itself states: "Si un comando contradice un archivo real, manda el
> archivo"). Corrections are listed in the last section.

## Status of this runbook

| Step | Runnable here (no Docker daemon) | Needs daemon + `vault` CLI |
|---|---|---|
| E0 preconditions | DONE — see "Offline pre-flight results" below | daemon check only |
| E1 build + tests | **DONE — 5/5 BUILD SUCCESS, 349 tests green, JaCoCo gates pass** | – |
| E2–E10 | – | **all of them** (blocked on this machine: daemon unreachable, `vault` CLI absent) |

**Prerequisites to run E2–E10:** user in the `docker` group (daemon reachable), `vault` CLI in
PATH, plus `curl`, `jq`, `psql` (optional — PG checks go through `docker compose exec`).

**Offline pre-flight results (verified 2026-10-09, all six application repos on `develop`; this runbook itself lands on a feature branch in `infra`):**

- Java 21.0.12.1; Docker CLI 29.7.2; Docker Compose 5.5.1.
- `infra/compose.yml` present; `docker compose config` → exit 0, valid, 9 services.
- 5 `Dockerfile`s present (ports `EXPOSE 8080/8888/8761/8081/8082`).
- Effective ports: config `8888` (`config-service/src/main/resources/application.yml:2`),
  discovery `8761` (hardcoded, `application.yml:7`), gateway `8080`, inventory `8081`, uom
  `8082` (central `*-dev.yml:2/20`, env-overridable).
- E1: `sh ./mvnw clean verify -Dspring.profiles.active=test` in all 5 repos →
  BUILD SUCCESS ×5; totals `349 / 0 / 0 / 0`; jars: `config-service-1.0.jar` (42.6 MB),
  `discovery-service-1.0.jar` (55.6 MB), `api-gateway-0.0.1-SNAPSHOT.jar` (50.8 MB),
  `inventory-service-1.2.jar` (93.0 MB), `unit-of-measure-service-1.1.jar` (93.0 MB);
  JaCoCo check PASS (uom 1.0000/1.0000, inventory 0.9770/0.7778, 0 missed classes both).

## E1 (reproduce)

```bash
for s in config-service discovery-service api-gateway inventory-service unit-of-measure-service; do
  (cd "$s" && sh ./mvnw clean verify -Dspring.profiles.active=test)
done
```

OK: `BUILD SUCCESS` ×5 + `target/*.jar` per repo. Note: `mvnw` is mode 644 by design — invoke
via `sh ./mvnw`, never `chmod +x` in the repo.

## E2 — Up in order (the order is enforced by `depends_on: service_healthy`, so one command is safe)

```bash
cd infra
docker compose up -d --build postgres-inventory postgres-uom rabbitmq vault   # +~20s
docker compose up -d --build discovery-service                                 # wait :8761/ 200 (<=90s)
docker compose up -d --build config-service                                    # wait :8888/actuator/health (<=120s)
# Vault one-shot BEFORE the business services (they tolerate empty Vault, E4/E6 do not):
# Container path (primary — waits for `vault` healthy via depends_on, loads `dev` by default):
sudo docker compose --profile bootstrap up vault-loader
# Host alternative:
# export VAULT_ADDR=http://localhost:8200
# export VAULT_TOKEN="${VAULT_DEV_ROOT_TOKEN_ID:-00000000-0000-0000-0000-000000000000}"
# SECRETS_DIR=../centralized-configuration/service-secrets PROFILES=dev ./scripts/setup-vault.sh
docker compose up -d --build inventory-service unit-of-measure-service          # Eureka registration, <=180s
docker compose up -d --build api-gateway                                        # wait :8080/actuator/health
docker compose ps
```

OK: every service `running` → `healthy`. FAIL: `restarting`/`exited` → `docker compose logs
<svc> --tail=100`, R2 (stop only the failed layer). Do not stop or restart the Postgres
containers casually: their tmpfs data is discarded and the services must restart to
re-create the schema and reseed (see "Restart semantics" below).

Notes: service names are `postgres-inventory`/`postgres-uom` (there is no bare `postgres`);
vault has **no** compose init service in the default stack — the profile-gated `vault-loader`
one-shot above is the mechanism (hidden from the default 9-service render). It requires
`bash` + `vault` + `jq` + `base64` (coreutils) inside whatever executes it: either the host,
or the loader image, which COPYs `/bin/vault` from `hashicorp/vault:1.16` (Alpine has no
`vault` package) and runs `apk add bash jq coreutils` (`base64` ships in coreutils).

## E3 — Infra health + actuator

```bash
# Postgres (5432 is NOT published — use compose exec; each container owns BOTH databases)
docker compose exec postgres-inventory pg_isready -U postgres -d inventory_db
docker compose exec postgres-uom       pg_isready -U postgres -d unit_of_measure_db
docker compose exec postgres-inventory psql -U postgres -d inventory_db -c "SELECT 1"
docker compose exec postgres-uom       psql -U postgres -d unit_of_measure_db -c "SELECT 1"
# RabbitMQ (credentials are elara/elara, NOT guest)
timeout 2 bash -c '</dev/tcp/localhost/5672' && echo "5672 OPEN"
curl -s -u elara:elara http://localhost:15672/api/overview | jq '{rabbitmq_version: .rabbitmq_version}'
# Vault
VAULT_ADDR=http://localhost:8200 VAULT_TOKEN="${VAULT_DEV_ROOT_TOKEN_ID:-00000000-0000-0000-0000-000000000000}" vault status | grep -E "Sealed|Version"
# Actuator
for p in 8888 8761 8080; do curl -sf "http://localhost:$p/actuator/health" >/dev/null && echo "$p health 200"; done
curl -sf http://localhost:8081/actuator/health >/dev/null && echo "8081 health 200"   # debug binding
curl -sf http://localhost:8082/actuator/health >/dev/null && echo "8082 health 200"   # debug binding
# Startup seed (dev profile): tables + demo rows exist with no manual SQL
docker compose exec postgres-inventory psql -U postgres -d inventory_db -tAc "SELECT count(*) FROM inventory_item"    # 2
docker compose exec postgres-uom       psql -U postgres -d unit_of_measure_db -tAc "SELECT count(*) FROM uom"        # 2
docker compose exec postgres-uom       psql -U postgres -d unit_of_measure_db -tAc "SELECT count(*) FROM uom_status" # 3
```

OK: 2× `accepting connections` + 2× `SELECT 1` → `1` + seed counts `2/2/3`
(inventory item / uom / status); `5672 OPEN`;
overview 200 with a version; `Sealed: false`; five health 200s. FAIL → R3 per component.

## E4 — Config Server `:8888/{app}/{profile}`

```bash
for app in inventory-service unit-of-measure-service api-gateway; do
  curl -s "http://localhost:8888/$app/dev" | jq '{name, profiles, sources: [.propertySources[].name]}'
done
curl -s http://localhost:8888/inventory-service/dev | jq '.propertySources[0].source | {port: .["server.port"], db: .["spring.datasource.url"], rabbit: .["spring.rabbitmq.host"], eureka: .["eureka.client.service-url.defaultZone"]}'
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8888/noexiste/dev   # expect 200 with empty propertySources
```

OK: 3× 200 with the expected property sources and the negative returns 200 with
`propertySources == []` (`accept-empty: true` default).

`.propertySources[0].source` returns the git file's **raw placeholders** (verified by running
the config-service jar against the bind mount):

| property | inventory-service | unit-of-measure-service | api-gateway |
|---|---|---|---|
| `server.port` | `${SERVER_PORT:8081}` | `${SERVER_PORT:8082}` | `${SERVER_PORT:8080}` |
| `spring.datasource.url` | `${SPRING_DATASOURCE_URL:jdbc:postgresql://localhost:5432/inventory_db}` | `${SPRING_DATASOURCE_URL:jdbc:postgresql://localhost:5432/unit_of_measure_db}` | – |
| `spring.rabbitmq.host` | `${SPRING_RABBITMQ_HOST:localhost}` | same | – |
| `eureka.client.service-url.defaultZone` | `${EUREKA_URI:http://localhost:8761/eureka/}` | same | same |

Those `${...}` are **not** resolved by the server — the env overrides from the `compose.yml`
`environment:` blocks of `inventory-service`/`unit-of-measure-service`/`api-gateway`
(`8081`/`8082`/`8080`, `jdbc:postgresql://postgres-inventory:5432/inventory_db` and
`jdbc:postgresql://postgres-uom:5432/unit_of_measure_db`, `rabbitmq`,
`http://discovery-service:8761/eureka/`) resolve on the **client** containers. Assert the
resolved values on the business services — their effective config (`/actuator/env`,
`/actuator/configprops`) or the ports visible in E5's registry `homePageUrl` — never via
`:8888`.

Note: the Config Server does not serve the working tree — it JGit-**clones** `CONFIG_GIT_URI`
(default: the read-only bind mount `/config-repo` = local `centralized-configuration`) at
`CONFIG_GIT_DEFAULT_LABEL` (default `main`, `config-service/src/main/resources/
application.yml:11` — verified: response `version` = local `main` tip) lazily on the first
request (`clone-on-start:false`). To serve the `develop` branch instead, set
`CONFIG_GIT_DEFAULT_LABEL=develop` in the environment.

## E5 — Eureka: 3 applications UP

```bash
curl -s -H "Accept: application/json" http://localhost:8761/eureka/apps \
  | jq -r '.applications.application[] | "\(.name) \(.instance[0].status)"'
```

OK: exactly the three business applications, all `UP` — expected output lines:
`INVENTORY-SERVICE UP`, `UNIT-OF-MEASURE-SERVICE UP`, `API-GATEWAY UP` (the Eureka list items
are `{name, instance}` — there is **no** `.application` wrapper, so the old wrapper form
printed `null`). `config-service` and
`discovery-service` must NOT appear (`register-with-eureka: false` — verified: registry stays
empty for them). **Count application NAMES, not instances**: `instance-id` is the app name
plus `${random.uuid}`, so a restart adds a new registry entry.

## E6 — Vault `kv get` (4 keys per service)

```bash
export VAULT_ADDR=http://localhost:8200 VAULT_TOKEN="${VAULT_DEV_ROOT_TOKEN_ID:-00000000-0000-0000-0000-000000000000}"
for app in inventory-service unit-of-measure-service; do
  vault kv get -format=json "secret/$app/dev" | jq -e '.data.data | has("spring.datasource.username") and has("spring.datasource.password") and has("spring.rabbitmq.username") and has("spring.rabbitmq.password")'
done
```

OK: `true` twice (each secret holds **4** keys: datasource user/pass + rabbit user/pass).
FAIL 403/404 → re-run the loader (`sudo docker compose --profile bootstrap up vault-loader`,
or `infra/scripts/setup-vault.sh` on the host — idempotent), check `VAULT_TOKEN`, R6.

## E7 — RabbitMQ

```bash
curl -s -u elara:elara http://localhost:15672/api/overview | jq '{rabbitmq_version, listeners}'
curl -s -u elara:elara http://localhost:15672/api/connections | jq 'length'   # expect >= 2 with bus-amqp
curl -s -u elara:elara "http://localhost:15672/api/exchanges/%2F/springCloudBus" | jq -r '.name'   # springCloudBus
```

OK: overview 200 + version + `/` vhost + `connections >= 2` + exchange `springCloudBus`
asserted via the management API (do NOT assert it from the Java logs — the declaration only
appears at DEBUG). FAIL → `restart rabbitmq`, re-check credentials (elara/elara on both
sides), R7.

## E8 — Gateway routing: 200/404 yes, 503 never

```bash
# Direct (debug bindings published on 127.0.0.1)
curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:8081/item/?page"      # 200
curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:8081/item/999999"     # 404 (ErrorCode 1004)
curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:8082/?page"           # 200
curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:8082/status/?page"    # 200
# Locator (service-id prefix is rewritten away by the locator's RewritePath)
curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:8080/inventory-service/item/?page"   # 200
curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:8080/unit-of-measure-service/?page"  # 200
# Explicit routes: /api/v1/<segment>/** with StripPrefix=3 -> item/ , "" , status/
curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:8080/api/v1/inventory/item/?page"     # 200
curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:8080/api/v1/uom/?page"                # 200
curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:8080/api/v1/uom/status/?page"        # 200
curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:8080/noexiste/"                      # 404
curl -fsS http://localhost:8080/swagger-ui/index.html | grep -qi 'Swagger UI'                   # Swagger UI page served
docker compose logs api-gateway | grep -cE "503|No available LoadBalancer|Unable to find instance"   # must be 0
```

OK: 200/404 as marked, unknown → 404, zero 503 in curls AND logs. FAIL (any 503) → STOP, R7
(re-check E5 first). Note: `StripPrefix=3` (the plan doc says 2 — wrong; with 2 the forwarded
path keeps the service segment and 404s; ETAPA-01 ruling + verification).

## E9 — Acta (one FAIL = FAIL)

Build 5× (E1) + all `healthy` (`compose ps`) + PG 2× `SELECT 1` + seed counts `2/2/3` +
`5672 OPEN` + overview 200 + `Sealed: false` + 2× `kv get` (4 keys each) + config health 200 +
3× config `200` + Eureka 3 applications UP + health 200 on 8081/8082 (debug bindings) +
direct/locator/explicit gateway matrix above + seed API rows (2 inventory items referencing
uom 1/2, 2 uoms, 3 statuses) + zero 503 + `docker compose logs` clean of `ERROR` for the
five services.

## Restart semantics (ephemeral data)

Both Postgres data directories are tmpfs, so stopping or restarting those containers discards
both databases; only a restart of the business services re-creates the schema and re-runs the
startup seed (`db/dev/seed.sql`).

- Cascading: `docker compose restart postgres-inventory` (or `postgres-uom`) also restarts
  the dependent service and the gateway (`depends_on: restart: true`) — full recovery.
- Postgres-scoped, non-cascading: `restart --no-deps` on a Postgres service, a raw
  `docker restart` of it, an OOM kill of it, or `docker compose stop postgres-inventory
  postgres-uom` + `start` for those two, wipe the tmpfs and leave the business services
  running against a database with no tables. Recover with
  `docker compose restart inventory-service unit-of-measure-service` and re-wait for Eureka.
- Host reboot / daemon restart: every container restarts by its `restart: unless-stopped`
  policy, so the services rebuild schema + seed on their own; only Vault's in-memory store
  stays empty — re-run the loader one-shot (E6).
- Restarting only a business service re-runs the seed idempotently against the still-present
  tmpfs database (counts unchanged, no duplicates).

## E10 — full reset and re-up

The tmpfs data directory means a plain `docker compose down` already discards both databases,
so the reset no longer needs `-v`; the `down -v` variant remains equivalent (the stack declares
no named volumes to drop, and `down` does not stop the profile-gated one-shot, because
profiles are not enabled for that command).

```bash
docker compose down                     # variant A: enough to discard the tmpfs databases
# docker compose down -v                # variant B: equivalent here
docker compose --profile bootstrap rm -f vault-loader   # the one-shot does not stop with `down`
docker compose up -d --build --wait     # ordered start via depends_on; blocks until healthy
# Vault is IN-MEMORY dev mode: any down/up (and any vault restart) empties it, and
# depends_on: service_healthy does NOT wait for secret loading — re-run the one-shot
# (container path) and the E6 assertion BEFORE the minimum checks:
sudo docker compose --profile bootstrap up vault-loader
# Host alternative:
# export VAULT_ADDR=http://localhost:8200
# export VAULT_TOKEN="${VAULT_DEV_ROOT_TOKEN_ID:-00000000-0000-0000-0000-000000000000}"
# SECRETS_DIR=../centralized-configuration/service-secrets PROFILES=dev ./scripts/setup-vault.sh
for app in inventory-service unit-of-measure-service; do
  vault kv get -format=json "secret/$app/dev" | jq -e '.data.data | has("spring.datasource.username") and has("spring.datasource.password") and has("spring.rabbitmq.username") and has("spring.rabbitmq.password")'
done
# Minimum re-checks, now including the startup seed.
# up --wait returns when health is up, but Eureka registration and the gateway load
# balancer need ~30-60s more: wait for the three apps before gateway checks.
for i in $(seq 1 60); do
  curl -fsS -H "Accept: application/json" http://localhost:8761/eureka/apps 2>/dev/null | jq -e '[.applications.application[].name] | sort == ["API-GATEWAY","INVENTORY-SERVICE","UNIT-OF-MEASURE-SERVICE"]' >/dev/null 2>&1 && { echo "eureka 3 apps OK"; break; }
  sleep 3
done
curl -fsS http://localhost:8888/inventory-service/dev >/dev/null && echo "config OK"
curl -fsS -H "Accept: application/json" http://localhost:8761/eureka/apps | jq -e '[.applications.application[].name] | sort == ["API-GATEWAY","INVENTORY-SERVICE","UNIT-OF-MEASURE-SERVICE"]' >/dev/null && echo "eureka OK"
curl -fsS "http://localhost:8080/api/v1/inventory/item/?page=0&size=20&sort=id,asc" | jq -e '.page.totalElements == 2' >/dev/null && echo "seed inventory OK"
curl -fsS "http://localhost:8080/api/v1/uom/?page=0&size=20&sort=id,asc"            | jq -e '.page.totalElements == 2' >/dev/null && echo "seed uom OK"
curl -fsS "http://localhost:8080/api/v1/uom/status/?page=0&size=20"                 | jq -e '.page.totalElements == 3' >/dev/null && echo "seed statuses OK"
# Ephemerality proof: insert a probe row, restart the Postgres pair (cascades to the
# services and the gateway) and confirm the probe is gone while the seed is back.
probe_ok=0
curl -fsS -X POST http://localhost:8080/api/v1/inventory/item/ -H 'Content-Type: application/json' \
  -d '{"name":"E10 Ephemerality Probe","description":"temporary","baseUnitOfMeasureId":1,"standardCost":1.00,"unitPerPurchaseUom":1.00,"reorderPointQuantity":1.00}' >/dev/null
curl -fsS "http://localhost:8080/api/v1/inventory/item/?page=0&size=20&sort=id,asc" | jq -e '.page.totalElements == 3' >/dev/null \
  && probe_ok=1 && echo "probe inserted (3 items)" \
  || echo "FAIL: probe not inserted - ephemerality proof is void"
sudo docker compose restart postgres-inventory postgres-uom
for i in $(seq 1 24); do
  if [ "$probe_ok" = 1 ] \
    && curl -fsS --max-time 10 http://localhost:8080/actuator/health >/dev/null 2>&1 \
    && curl -fsS --max-time 10 "http://localhost:8080/api/v1/inventory/item/?page=0&size=20&sort=id,asc" | jq -e '.page.totalElements == 2 and ([.content[].name] | index("E10 Ephemerality Probe") == null)' >/dev/null 2>&1 \
    && curl -fsS --max-time 10 "http://localhost:8080/api/v1/uom/?page=0&size=20&sort=id,asc" | jq -e '.page.totalElements == 2' >/dev/null 2>&1 \
    && curl -fsS --max-time 10 "http://localhost:8080/api/v1/uom/status/?page=0&size=20" | jq -e '.page.totalElements == 3' >/dev/null 2>&1; then
    echo "probe gone, seed back to 2/2/3"; break
  fi
  if [ "$i" = 24 ]; then echo "FAIL: not recovered in time or probe survived"; fi
  sleep 5
done
# NOTE (observed live): right after down/up the loader can fail attaching to the
# freshly recreated network (`failed to set up container networking: network … not found`,
# transient daemon race, not a compose bug). Recover with:
#   sudo docker compose --profile bootstrap rm -f vault-loader
# and retry the `up vault-loader` above — the loader is idempotent.
```

OK: re-up reaches the same state — seed counts `2/2/3` with no manual SQL — but ONLY AFTER
the Vault one-shot: Vault dev mode is in-memory, so any down/up leaves it empty,
`depends_on` does not wait for the secrets, and without the re-run E6 fails (403/404) and
the business services boot with missing secrets (the re-up itself takes ~2–4 min: config
clone + JPA `ddl-auto: update` + seed + Eureka registration). FAIL → R8 (never destructive
`system prune`; `docker compose down` only).

## Rollback quick table (corrected)

| id | trigger | action |
|---|---|---|
| R1 | build/test failure | stay in code; inspect `target/surefire-reports`; do not touch containers |
| R2 | `restarting`/`exited` on up | `docker compose logs <svc> --tail=100`; stop only the failed layer; do not stop/restart Postgres casually (the tmpfs data is discarded) |
| R3 | infra health | `docker compose restart <infra>` (a compose Postgres restart cascades to the dependent services; a raw `docker restart` does not — restart the business services to reseed); re-export Vault token; check Java logs for ConfigClient/Vault/Eureka |
| R4 | config 404/500 | check `CONFIG_GIT_URI`/`CONFIG_GIT_DEFAULT_LABEL` + mounted repo branch; `restart config-service` |
| R5 | Eureka missing app | check `EUREKA_URI`; `restart` the client; wait 60s; re-poll |
| R6 | Vault 403/404 | re-run the loader (container one-shot, or `scripts/setup-vault.sh` on the host); `vault kv get secret/<app>/dev`; restart the business service |
| R7 | gateway 503/404 | verify E5 green first; routes/`StripPrefix=3`; `restart api-gateway` |
| R8 | re-up regression | `docker compose down` (discards the tmpfs data); strict up order; diff the changed yml/env |

## Corrections applied to the plan doc (ETAPA-04)

| plan doc says | reality (this runbook) |
|---|---|
| E2 `up -d postgres rabbitmq vault` | `postgres-inventory`, `postgres-uom` (9-service compose has no bare `postgres`) |
| E3 `pg_isready -h localhost -p 5432`, `psql -h localhost` | `docker compose exec postgres-*` (5432 is not published) |
| E3 `curl -u guest:guest :15672` | `elara:elara` (RABBITMQ_DEFAULT_USER/PASS; plan's own "post I-02" note) |
| E6 criterion "2/2 `OK`" (two `kv get`s — the plan already says "con las 4 keys") | each secret holds **4 keys** — datasource username/password + rabbit username/password (`jq 'keys|length' service-secrets/*-dev-secrets.json` → 4); E6 must assert all four per service, for the two services |
| E3 Vault token `00000000-…` | `$VAULT_DEV_ROOT_TOKEN_ID` (defaults to the same dummy; override it explicitly in the environment to change) |
| E5 asserts instance counts | count **application NAMES** (`instance-id` contains `${random.uuid}`) |
| E8 `StripPrefix=2` | `StripPrefix=3` (ETAPA-01 ruling, verified) |
| §puertos "inventory/uom `0` aleatorio" | fixed `8081/8082` via `SERVER_PORT` (ETAPA-01/C-11) |
| line 57 `clone-on-start:true` | `clone-on-start: false` (lazy clone; first request pays it) |

Watch items for the first live run: `vault` `mem_limit: 128M` is tight for dev mode; each
Postgres container creates BOTH databases (init script) — harmless, but don't assert one DB
per container; every Postgres start runs `initdb` + the init script (tmpfs), which costs a
few seconds; the 128 MiB tmpfs cap also holds WAL and temporary files, so a bulk load can
fail with `ENOSPC` (demo sizes only) and tmpfs pages count against the 512M `mem_limit`;
the business services reseed on every start (idempotent); after a non-cascading Postgres
restart, restart the business services to re-create schema + seed; the Config Server does
not serve the working tree — it JGit-**clones** from the bind mount at
`CONFIG_GIT_DEFAULT_LABEL` (default `main`, verified against the local `main` tip), so set
`CONFIG_GIT_DEFAULT_LABEL=develop` in the environment to serve the develop branch.
