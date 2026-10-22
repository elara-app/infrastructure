#!/usr/bin/env bash
#
# Smoke-test the published Elara demo stack.
#
# COMPOSE_REF is required and may point at a local Compose file or an oci://
# reference. The stack is brought up and waited on by default; set
# SMOKE_SKIP_UP=1 to test an already-running stack instead.
#
#   COMPOSE_REF=./compose.published.yml bash ./scripts/smoke-test.sh
#   COMPOSE_REF=oci://ghcr.io/elara-app/elara-demo:latest bash ./scripts/smoke-test.sh
#
# Host prerequisites: bash, docker (with the Compose v2 plugin), curl, and jq.
# jq must be installed on the host, not in a container: every JSON assertion
# below runs here against curl and docker compose output.
#
# URLs follow the same environment knobs as compose.published.yml:
# ELARA_BIND (default 127.0.0.1), ELARA_PORT_GATEWAY (default 8080), and
# ELARA_PORT_DISCOVERY (default 8761). SMOKE_HOST overrides the host used in
# the URLs; it defaults to ELARA_BIND, maps wildcard binds to loopback, and
# brackets a bare IPv6 address.

# Re-exec under bash when invoked as `sh script`; dash has no `pipefail`.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

RETRIES=40
RETRY_DELAY=3

die() {
  printf 'smoke-test: %s\n' "$*" >&2
  exit 1
}

for cmd in bash docker curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || die "required host command not found: $cmd"
done
docker compose version >/dev/null 2>&1 || die "docker compose v2 plugin is not available"

[ -n "${COMPOSE_REF:-}" ] || die "COMPOSE_REF is required (a local compose file path or an oci:// reference)"
case "$COMPOSE_REF" in
  oci://*) ;;
  *) [ -r "$COMPOSE_REF" ] || die "COMPOSE_REF is not a readable file: $COMPOSE_REF" ;;
esac

compose() {
  docker compose -p elara-demo -f "$COMPOSE_REF" "$@"
}

# On a failed `compose up`, print the container state and recent Vault logs so
# startup failures (for example an OOM kill) are diagnosable from CI output.
# Vault dev-mode logs include the root token and unseal key, so any such line
# is filtered out before printing.
compose_diagnostics() {
  printf 'smoke-test: compose up failed; container state follows\n' >&2
  compose ps -a >&2 || true

  vault_id=$(compose ps -q vault 2>/dev/null || true)
  if [ -n "$vault_id" ]; then
    docker inspect --format \
      'smoke-test: vault state={{.State.Status}} running={{.State.Running}} exitCode={{.State.ExitCode}} oomKilled={{.State.OOMKilled}} error={{.State.Error}}' \
      "$vault_id" >&2 || true
    printf 'smoke-test: vault logs, last 30 lines, secrets filtered\n' >&2
    compose logs --no-log-prefix --tail 30 vault 2>&1 \
      | grep -viE 'root token|unseal key' >&2 || true
  fi
}

ELARA_BIND=${ELARA_BIND:-127.0.0.1}
ELARA_PORT_GATEWAY=${ELARA_PORT_GATEWAY:-8080}
ELARA_PORT_DISCOVERY=${ELARA_PORT_DISCOVERY:-8761}

# ELARA_BIND is a listen address, so wildcard binds are not client-connectable.
# SMOKE_HOST defaults to it, maps wildcard binds to loopback, and brackets a
# bare IPv6 address so it can be embedded in a URL.
SMOKE_HOST=${SMOKE_HOST:-$ELARA_BIND}
case "$SMOKE_HOST" in
  0.0.0.0|::|'[::]') SMOKE_HOST=127.0.0.1 ;;
esac
case "$SMOKE_HOST" in
  *:*)
    case "$SMOKE_HOST" in
      \[*\]) ;;
      *) SMOKE_HOST="[$SMOKE_HOST]" ;;
    esac
    ;;
esac

GATEWAY_URL="http://${SMOKE_HOST}:${ELARA_PORT_GATEWAY}"
EUREKA_URL="http://${SMOKE_HOST}:${ELARA_PORT_DISCOVERY}"
EUREKA_APPS="${EUREKA_URL}/eureka/apps"

printf 'smoke-test: host        %s\n' "$SMOKE_HOST"
printf 'smoke-test: gateway URL %s\n' "$GATEWAY_URL"
printf 'smoke-test: eureka URL  %s\n' "$EUREKA_URL"

if [ "${SMOKE_SKIP_UP:-0}" = "1" ]; then
  printf 'smoke-test: SMOKE_SKIP_UP=1, using the running stack\n'
else
  printf 'smoke-test: bringing the stack up\n'
  if ! compose up -d --wait -y --pull always --wait-timeout 900; then
    compose_diagnostics
    die "compose up failed"
  fi
fi

# wait_for_json <label> <url> <jq filter>
wait_for_json() {
  label=$1
  url=$2
  filter=$3
  attempt=1
  response=''

  while [ "$attempt" -le "$RETRIES" ]; do
    if response=$(curl -fsS --connect-timeout 3 --max-time 10 \
      -H 'Accept: application/json' "$url" 2>/dev/null); then
      if printf '%s' "$response" | jq -e "$filter" >/dev/null 2>&1; then
        printf 'smoke-test: OK %s\n' "$label"
        return 0
      fi
    fi
    if [ "$attempt" -lt "$RETRIES" ]; then
      sleep "$RETRY_DELAY"
    fi
    attempt=$((attempt + 1))
  done

  die "$label failed after $RETRIES attempts; last response: ${response:-<none>}"
}

wait_for_json "Eureka registrations" "$EUREKA_APPS" '
  ([.applications.application // []
    | if type == "array" then .[] else . end
    | .name] | sort)
  == ["API-GATEWAY", "INVENTORY-SERVICE", "UNIT-OF-MEASURE-SERVICE"]
'

wait_for_json "inventory seed count" \
  "$GATEWAY_URL/api/v1/inventory/item/?page=0&size=20&sort=id,asc" \
  '.page.totalElements == 10'
wait_for_json "unit-of-measure seed count" \
  "$GATEWAY_URL/api/v1/uom/?page=0&size=20&sort=id,asc" \
  '.page.totalElements == 5'
wait_for_json "unit-of-measure status seed count" \
  "$GATEWAY_URL/api/v1/uom/status/?page=0&size=20" \
  '.page.totalElements == 3'

# Compose 2.40.3 emits JSON Lines; the array branch is defensive.
ps_raw=$(compose ps -a --format json) || die "compose ps failed"
ps_norm=$(printf '%s' "$ps_raw" | jq -c 'if type=="array" then .[] else . end' | jq -s) \
  || die "could not normalize compose ps output: $ps_raw"

printf '%s' "$ps_norm" | jq -e '
  length == 10
  and ([.[] | select(.Service == "vault-loader")] as $loader
       | [.[] | select(.Service != "vault-loader")] as $others
       | ($loader | length) == 1
         and ($loader[0].State == "exited")
         and (($loader[0].ExitCode | tostring) == "0")
         and ($others | length) == 9
         and (($others | map(.Service) | sort) ==
              ["api-gateway", "config-service", "discovery-service",
               "inventory-service", "postgres-inventory", "postgres-uom",
               "rabbitmq", "unit-of-measure-service", "vault"])
         and ($others | all(.State == "running" and .Health == "healthy")))
' >/dev/null || die "compose ps assertion failed (expected the nine known services healthy and running, plus an exited vault-loader): $ps_norm"
printf 'smoke-test: OK compose ps\n'

# The variable is expanded by the shell inside the Vault container, not here.
# shellcheck disable=SC2016
vault_token=$(compose exec -T vault sh -c 'printf %s "$VAULT_DEV_ROOT_TOKEN_ID"') \
  || die "could not read the Vault dev root token"
[ -n "$vault_token" ] || die "the Vault dev root token is empty"

for path in secret/inventory-service/dev secret/unit-of-measure-service/dev; do
  secret=$(compose exec -T -e VAULT_TOKEN="$vault_token" vault vault kv get -format=json "$path") \
    || die "vault kv get failed for $path"
  [ -n "$secret" ] \
    || die "vault kv get returned empty output for $path"
  missing_keys=$(printf '%s' "$secret" | jq -r '
    (.data.data // {}) as $data
    | (["spring.datasource.username",
        "spring.datasource.password",
        "spring.rabbitmq.username",
        "spring.rabbitmq.password"]
       - ($data | keys))
    | join(", ")
  ') || die "could not parse vault secret JSON for $path"
  [ -z "$missing_keys" ] \
    || die "vault secret $path is missing required keys: $missing_keys"
  printf 'smoke-test: OK vault secret %s\n' "$path"
done

printf 'SMOKE OK\n'
