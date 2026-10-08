#!/usr/bin/env bash
# Idempotent multi-database bootstrap for the official postgres image.
# Intended mount: /docker-entrypoint-initdb.d/init-multiple-dbs.sh (runs once on
# an empty data directory). Safe to re-run: each DB is created only if absent.
set -euo pipefail

POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-inventory_db}"
POSTGRES_MULTIPLE_DATABASES="${POSTGRES_MULTIPLE_DATABASES:-inventory_db,unit_of_measure_db}"

log() { printf '[init-multiple-dbs] %s\n' "$*"; }

log "user=${POSTGRES_USER} primary=${POSTGRES_DB} databases=${POSTGRES_MULTIPLE_DATABASES}"

IFS=',' read -r -a _databases <<< "${POSTGRES_MULTIPLE_DATABASES}"
for _raw in "${_databases[@]}"; do
  _db="$(printf '%s' "${_raw}" | tr -d '[:space:]')"
  [ -n "${_db}" ] || continue
  log "ensuring database '${_db}'"
  psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<-EOSQL
	SELECT 'CREATE DATABASE ${_db}'
	WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${_db}');
	\gexec
EOSQL
done

log 'done'
