#!/usr/bin/env bash
#
# Verify that the five services and the published artifact agree on one version.
#
#   bash scripts/check-release-version.sh [REF]
#
# REF is the git ref the service poms are read from (default: main, the state
# that is published). The artifact version is read from the VERSION file in
# this repository.
#
# The five services are released as one batch, so a mismatch means the batch
# is half bumped and must not be published.

set -euo pipefail

REF="${1:-main}"
ORG="${ORG:-elara-app}"
SERVICES=(api-gateway config-service discovery-service inventory-service unit-of-measure-service)

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(tr -d '[:space:]' < "$repo_root/VERSION")"

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'check-release-version: VERSION is not a semantic version: %s\n' "$version" >&2
  exit 1
fi

printf 'artifact version: %s (services read from %s)\n' "$version" "$REF"

failed=0
for service in "${SERVICES[@]}"; do
  if ! pom="$(curl -fsSL --retry 3 "https://raw.githubusercontent.com/${ORG}/${service}/${REF}/pom.xml")"; then
    printf '  %-28s could not read the pom at %s\n' "$service" "$REF" >&2
    failed=1
    continue
  fi
  declared="$(printf '%s' "$pom" | tr -d '\n' \
    | sed -n "s|.*<artifactId>${service}</artifactId>[[:space:]]*<version>\([^<]*\)</version>.*|\1|p")"
  if [ "$declared" = "$version" ]; then
    printf '  %-28s %s\n' "$service" "$declared"
  else
    printf '  %-28s %s (expected %s)\n' "$service" "${declared:-<not found>}" "$version" >&2
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  printf 'check-release-version: the services do not agree on one version\n' >&2
  exit 1
fi

printf 'check-release-version: all five services and the artifact agree on %s\n' "$version"
