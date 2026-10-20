#!/usr/bin/env bash
# Idempotent multi-database bootstrap for the official postgres image.
# Intended mount: /docker-entrypoint-initdb.d/init-multiple-dbs.sh (runs on
# every container start, because PGDATA is a tmpfs that begins empty).
# Safe to re-run: each DB is created only if absent.
#
# Edge case: if POSTGRES_DB is unset the official image creates a database named
# after POSTGRES_USER instead, so the default 'inventory_db' below would not
# exist and every psql call below would fail on a missing database. POSTGRES_DB
# must therefore always be set (the .env.example contract sets it, and Etapa-03
# passes it to both Postgres containers).
set -euo pipefail

POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-inventory_db}"
POSTGRES_MULTIPLE_DATABASES="${POSTGRES_MULTIPLE_DATABASES:-inventory_db,unit_of_measure_db}"

log() { printf '[init-multiple-dbs] %s\n' "$*"; }
die() { printf '[init-multiple-dbs] ERROR: %s\n' "$*" >&2; exit 1; }

log "user=${POSTGRES_USER} primary=${POSTGRES_DB} databases=${POSTGRES_MULTIPLE_DATABASES}"

IFS=',' read -r -a _databases <<< "${POSTGRES_MULTIPLE_DATABASES}"
for _raw in ${_databases[@]+"${_databases[@]}"}; do
  _db="$(printf '%s' "${_raw}" | tr -d '[:space:]')"
  [ -n "${_db}" ] || continue
  # Defense in depth: these names are interpolated into a CREATE DATABASE
  # statement, so only plain identifiers are accepted even from the environment.
  case "${_db}" in
    *[!A-Za-z0-9_-]*)
      die "invalid database name '${_db}' in POSTGRES_MULTIPLE_DATABASES (only letters, digits, '_' and '-' are allowed)"
      ;;
  esac
  log "ensuring database '${_db}'"
  psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<-EOSQL
	SELECT 'CREATE DATABASE ${_db}'
	WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${_db}');
	\gexec
EOSQL
done

log 'done'
