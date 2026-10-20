#!/usr/bin/env bash
#
# Verify one layered request through the running Elara demo stack.
#
# The check posts one uniquely named inventory item through the gateway,
# waits for the expected inventory and unit-of-measure log markers, deletes
# the item, and confirms the seed count is back to two. It never brings the
# stack up and never prints secrets.
#
#   COMPOSE_REF=./compose.published.yml bash ./scripts/flow-check.sh
#   COMPOSE_REF=oci://ghcr.io/elara-app/elara-demo:latest bash ./scripts/flow-check.sh
#
# COMPOSE_REF is required and may point at a local Compose file or an oci://
# reference. Host prerequisites: bash, docker (with the Compose v2 plugin),
# curl, and jq.
#
# URLs follow the same environment knobs as compose.published.yml:
# ELARA_BIND (default 127.0.0.1) and ELARA_PORT_GATEWAY (default 8080).
# SMOKE_HOST overrides the host used in the URL; it defaults to ELARA_BIND,
# maps wildcard binds to loopback, and brackets a bare IPv6 address.

# Re-exec under bash when invoked as `sh script`; dash has no `pipefail`.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

RETRIES=40
RETRY_DELAY=3
LOG_RETRIES=60
LOG_RETRY_DELAY=2

die() {
  printf 'flow-check: %s\n' "$*" >&2
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

ELARA_BIND=${ELARA_BIND:-127.0.0.1}
ELARA_PORT_GATEWAY=${ELARA_PORT_GATEWAY:-8080}

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
printf 'flow-check: gateway URL %s\n' "$GATEWAY_URL"

TMP_DIR=$(mktemp -d)
ITEM_ID=''
LOGS_FILE="$TMP_DIR/logs.txt"
POST_BODY="$TMP_DIR/post.json"
MATCHED_FILE="$TMP_DIR/matched.log"

cleanup() {
  if [ -n "${ITEM_ID:-}" ]; then
    curl -sS -o /dev/null --connect-timeout 3 --max-time 10 \
      -X DELETE "${GATEWAY_URL}/api/v1/inventory/item/${ITEM_ID}" \
      >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR" || true
}
trap cleanup EXIT

item_name="flow-check-$(date -u +%s)-$$"
payload=$(printf '{"name":"%s","description":"layered flow check","baseUnitOfMeasureId":1,"standardCost":1.00,"unitPerPurchaseUom":1.00,"reorderPointQuantity":1.00}' "$item_name")

post_item() {
  attempt=1
  while [ "$attempt" -le "$RETRIES" ]; do
    code=$(curl -sS --connect-timeout 3 --max-time 10 \
      -o "$POST_BODY" -w '%{http_code}' \
      -H 'Accept: application/json' \
      -H 'Content-Type: application/json' \
      -X POST --data "$payload" \
      "$GATEWAY_URL/api/v1/inventory/item/" 2>/dev/null) || code=000
    case "$code" in
      2[0-9][0-9])
        if jq -e '(.id | type) == "number"' "$POST_BODY" >/dev/null 2>&1; then
          ITEM_ID=$(jq -r '.id' "$POST_BODY")
          printf 'flow-check: created item %s (id %s) through the gateway\n' "$item_name" "$ITEM_ID"
          return 0
        fi
      ;;
    esac
    if [ "$attempt" -lt "$RETRIES" ]; then
      sleep "$RETRY_DELAY"
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

wait_for_log_markers() {
  attempt=1
  while [ "$attempt" -le "$LOG_RETRIES" ]; do
    compose logs --since "$SINCE" --no-log-prefix \
      inventory-service unit-of-measure-service > "$LOGS_FILE" 2>/dev/null || true
    missing=''
    for marker in \
      '[InventoryItem-controller-create]' \
      '[InventoryItem-service-save]' \
      '[Uom-service-existsById]' \
      '[Uom-controller-getById]' \
      'insert into inventory_item'
    do
      if ! grep -Fq -- "$marker" "$LOGS_FILE"; then
        missing="$missing $marker"
      fi
    done
    [ -z "$missing" ] && return 0
    if [ "$attempt" -lt "$LOG_RETRIES" ]; then
      sleep "$LOG_RETRY_DELAY"
    fi
    attempt=$((attempt + 1))
  done
  printf 'flow-check: missing log markers:%s\n' "$missing" >&2
  return 1
}

delete_item() {
  attempt=1
  while [ "$attempt" -le 10 ]; do
    code=$(curl -sS -o /dev/null --connect-timeout 3 --max-time 10 \
      -w '%{http_code}' -X DELETE \
      "$GATEWAY_URL/api/v1/inventory/item/${ITEM_ID}" 2>/dev/null) || code=000
    case "$code" in
      2[0-9][0-9]|404) return 0 ;;
    esac
    if [ "$attempt" -lt 10 ]; then
      sleep 2
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

wait_for_seed_count() {
  attempt=1
  while [ "$attempt" -le "$RETRIES" ]; do
    response=$(curl -fsS --connect-timeout 3 --max-time 10 \
      -H 'Accept: application/json' \
      "$GATEWAY_URL/api/v1/inventory/item/?page=0&size=20&sort=id,asc" 2>/dev/null) \
      || response=''
    if [ -n "$response" ] \
       && printf '%s' "$response" | jq -e '.page.totalElements == 2' >/dev/null 2>&1; then
      return 0
    fi
    if [ "$attempt" -lt "$RETRIES" ]; then
      sleep "$RETRY_DELAY"
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

# The timestamp is taken immediately before the POST so the log capture cannot
# include an earlier run that happens to use the same unique item name.
SINCE=$(date -u +%FT%TZ)
post_item || die "inventory item POST did not return a 2xx response with a numeric id after $RETRIES attempts"

wait_for_log_markers || die "the expected inventory and unit-of-measure log markers did not appear after $LOG_RETRIES attempts"

grep -F \
  -e '[InventoryItem-controller-create]' \
  -e '[InventoryItem-service-save]' \
  -e '[Uom-service-existsById]' \
  -e '[Uom-controller-getById]' \
  -e '[Uom-service-findById]' \
  -e 'insert into inventory_item' \
  "$LOGS_FILE" > "$MATCHED_FILE" || true
while IFS= read -r line; do
  printf 'flow-check: log: %s\n' "$line"
done < "$MATCHED_FILE"

delete_item || die "could not delete inventory item $ITEM_ID"
ITEM_ID=''

wait_for_seed_count || die "inventory count did not return to 2 after $RETRIES attempts"
printf 'flow-check: inventory seed count restored to 2\n'
printf 'FLOW OK\n'
