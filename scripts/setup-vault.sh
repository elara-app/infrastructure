#!/usr/bin/env bash
# setup-vault.sh — idempotent bootstrap of service-secrets into Vault (KV v2).
#
# DEV-ONLY POLICY (I-07): by default only <service>-dev-secrets.json files are
# loaded, against a local Vault dev server. Loading prod values requires an
# explicit non-local VAULT_ADDR and CONFIRM_PROD=yes; this script is therefore
# safe to re-run in local dev and CI without ever touching real secrets.
#
# Enforcement is non-interactive by design: nothing here prompts, so running the
# script unattended (CI, compose one-shot container, ssh without a tty) can never
# hang waiting for a human confirmation.
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_ADDR
WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="${SECRETS_DIR:-${SCRIPT_DIR}/../centralized-configuration/service-secrets}"

log() { printf '[setup-vault] %s\n' "$*"; }
die() { printf '[setup-vault] ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf '[setup-vault] WARN: %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: setup-vault.sh [--all-profiles] [--profiles <dev,test,...>]

Loads <app>-<profile>-secrets.json files into Vault KV v2 at secret/<app>/<profile>.
Re-runnable: an existing path is reported as skipped, never overwritten.

Environment:
  VAULT_ADDR      Vault base URL (default http://127.0.0.1:8200)
  VAULT_URI       Vault URI the services read (default http://127.0.0.1:8200)
  VAULT_TOKEN     Vault token, required. Compose maps it from VAULT_DEV_ROOT_TOKEN_ID
  SECRETS_DIR     Directory holding the *-secrets.json files
                  (default <script_dir>/../centralized-configuration/service-secrets,
                  i.e. the config repo checked out next to scripts/)
  PROFILES        Comma-separated profiles to load (default: PROFILE, or dev)
  PROFILE         Single profile to load (default dev)
  WAIT_TIMEOUT    Seconds to wait for Vault to answer (default 60)
  CONFIRM_PROD    Must be "yes" to load the prod profile, and VAULT_ADDR must be
                  non-local. The prod profile is never loaded otherwise.
EOF
}

# ---------------------------------------------------------------- arguments ---
ALL_PROFILES=0
PROFILES="${PROFILES:-}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --all-profiles) ALL_PROFILES=1 ;;
    --profiles)
      shift
      [ "$#" -gt 0 ] || die "--profiles requires a comma-separated list (e.g. --profiles dev,test)"
      PROFILES="$1"
      ;;
    --profiles=*) PROFILES="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
  shift
done

# ------------------------------------------------------------- preconditions ---
require_bin() {
  command -v "$1" >/dev/null 2>&1 || die "required binary '$1' was not found in PATH; install '$1' and retry"
}
require_bin vault
require_bin jq
require_bin base64

[ -n "${VAULT_TOKEN:-}" ] || die "VAULT_TOKEN is empty or unset; export it (compose maps it from VAULT_DEV_ROOT_TOKEN_ID, see .env.example)"

case "${WAIT_TIMEOUT}" in
  ''|*[!0-9]*) die "WAIT_TIMEOUT must be a non-negative integer of seconds, got '${WAIT_TIMEOUT}'" ;;
esac

[ -d "${SECRETS_DIR}" ] || die "secrets directory '${SECRETS_DIR}' does not exist or is not a directory (override with SECRETS_DIR)"

# ------------------------------------------------------------------ profiles ---
profiles=()
if [ "${ALL_PROFILES}" -eq 1 ]; then
  profiles_label='all (*-secrets.json)'
else
  _raw_profiles="${PROFILES:-${PROFILE:-dev}}"
  IFS=',' read -r -a _profiles <<< "${_raw_profiles}"
  for _p in ${_profiles[@]+"${_profiles[@]}"}; do
    _p="$(printf '%s' "${_p}" | tr -d '[:space:]')"
    [ -n "${_p}" ] || continue
    profiles+=("${_p}")
  done
  [ "${#profiles[@]}" -gt 0 ] || die "no usable profile in '${_raw_profiles}' (use PROFILE=<name> or PROFILES=<a,b>)"
  profiles_label="${_raw_profiles}"
fi

# ------------------------------------------------------------- prod gating ---
# Loading prod secrets requires an explicitly non-local VAULT_ADDR AND an explicit
# CONFIRM_PROD=yes. Checked before any network contact so a misconfigured local
# run never even authenticates against a dev server while claiming prod.
# The gate only ever applies to files whose profile is actually being loaded:
# prod files that are merely present on disk are skipped, never gated (see the
# selection below), because the DEV-ONLY policy keeps them on local disks.
is_local_addr() {
  case "${VAULT_ADDR}" in
    http://127.0.0.1|http://127.0.0.1:*|https://127.0.0.1|https://127.0.0.1:*|\
    http://localhost|http://localhost:*|https://localhost|https://localhost:*|\
    http://0.0.0.0|http://0.0.0.0:*|https://0.0.0.0|https://0.0.0.0:*|\
    http://\[::\]|http://\[::\]:*|https://\[::\]|https://\[::\]:*|\
    http://\[::1\]|http://\[::1\]:*|https://\[::1\]|https://\[::1\]:*)
      return 0
      ;;
    *) return 1 ;;
  esac
}

require_prod_gate() {
  if is_local_addr; then
    die "profile 'prod' refused: prod secrets may only be loaded from a non-local VAULT_ADDR, but VAULT_ADDR='${VAULT_ADDR}' is local. Point VAULT_ADDR at the production Vault and re-run."
  fi
  if [ "${CONFIRM_PROD:-}" != "yes" ]; then
    die "profile 'prod' refused: set CONFIRM_PROD=yes to confirm loading production secrets from '${VAULT_ADDR}'."
  fi
}

# An explicitly requested prod profile is gated here, before any network contact.
for _requested in ${profiles[@]+"${profiles[@]}"}; do
  if [ "${_requested}" = "prod" ]; then
    require_prod_gate
  fi
done

# --------------------------------------------------------- file discovery ---
# Filenames follow <spring.application.name>-<profile>-secrets.json; the Vault
# path is derived from that filename, never from a short prefix such as `uom`.
shopt -s nullglob
candidates=("${SECRETS_DIR}"/*-secrets.json)
shopt -u nullglob

_app=""
_profile=""
derive_app_profile() {
  local _base="$1"
  _app=""
  _profile=""
  if [[ "${_base}" =~ ^(.+)-([A-Za-z0-9_]+)-secrets\.json$ ]]; then
    _app="${BASH_REMATCH[1]}"
    _profile="${BASH_REMATCH[2]}"
  fi
}

selected=()
for _file in ${candidates[@]+"${candidates[@]}"}; do
  derive_app_profile "$(basename "${_file}")"
  if [ -z "${_app}" ] || [ -z "${_profile}" ]; then
    warn "ignoring '${_file}': filename does not match <app>-<profile>-secrets.json"
    continue
  fi

  # Selection first: a file whose profile is not being loaded is skipped before
  # any gate is evaluated, so a prod file sitting next to the dev ones never
  # affects a plain dev run.
  _selected=0
  if [ "${#profiles[@]}" -eq 0 ]; then
    _selected=1
  else
    for _p in ${profiles[@]+"${profiles[@]}"}; do
      if [ "${_p}" = "${_profile}" ]; then
        _selected=1
        break
      fi
    done
  fi
  [ "${_selected}" -eq 1 ] || continue

  if [ "${_profile}" = "prod" ]; then
    require_prod_gate
  fi
  selected+=("${_file}")
done

[ "${#selected[@]}" -gt 0 ] || die "no secret files matched profile(s) '${profiles_label}' in '${SECRETS_DIR}'"

# --------------------------------------------------------------- vault talk ---
wait_for_vault() {
  local _deadline=$(( SECONDS + WAIT_TIMEOUT ))
  local _rc=0 _out=""
  while :; do
    _out="$(vault status -format=json 2>&1)" && _rc=0 || _rc=$?
    if [ "${_rc}" -eq 0 ]; then
      _sealed="$(printf '%s' "${_out}" | jq -r 'if has("sealed") then .sealed else "unknown" end' 2>/dev/null || printf 'unknown')"
      if [ "${_sealed}" = "false" ]; then
        log "vault reachable and unsealed at ${VAULT_ADDR}"
      else
        log "vault reachable at ${VAULT_ADDR} (status.sealed=${_sealed})"
      fi
      return 0
    fi
    # exit 1 = not answering yet (dev server still booting), exit 2 = sealed:
    # both are transient, so keep polling until the deadline.
    if (( SECONDS >= _deadline )); then
      die "timed out after ${WAIT_TIMEOUT}s waiting for Vault at ${VAULT_ADDR} (last exit ${_rc}); last output: ${_out}"
    fi
    sleep 1
  done
}

wait_for_vault

if ! _login_out="$(vault login "${VAULT_TOKEN}" 2>&1)"; then
  die "vault login failed for the configured token (wrong or unauthorised token, or insufficient policy): ${_login_out}"
fi
log "authenticated with VAULT_TOKEN at ${VAULT_ADDR}"

# ------------------------------------------------------------------- loading ---
loaded=0
skipped=0
failed=0

for _file in ${selected[@]+"${selected[@]}"}; do
  _base="$(basename "${_file}")"
  derive_app_profile "${_base}"
  _vault_path="secret/${_app}/${_profile}"

  if ! _json_err="$(jq empty "${_file}" 2>&1)"; then
    die "invalid JSON in ${_file}: ${_json_err}"
  fi

  _json_type="$(jq -r 'type' "${_file}")"
  [ "${_json_type}" = "object" ] || die "${_file} must hold a JSON object of key/value pairs, got '${_json_type}'"

  # Controller ruling (binding): the Vault CLI's `@file` sugar parses K=V lines,
  # NOT JSON, so `vault kv put <path> @file.json` fails on `{"key": "value"}`
  # lines. Every entry of the validated JSON is therefore converted into a
  # single `key=value` argument. jq base64-encodes each pair and bash decodes it
  # again, so one pair stays ONE argv element even when the value contains '='
  # or a literal newline (a plain read over `jq -r` output would split such a
  # value into a second, '='-less argument that `vault kv put` rejects).
  if ! _b64="$(jq -r 'to_entries[] | ("\(.key)=\(.value|tostring)" | @base64)' "${_file}")"; then
    die "could not read key/value pairs from ${_file} with jq"
  fi
  _kv_pairs=()
  while IFS= read -r _line; do
    [ -n "${_line}" ] || continue
    _kv_pairs+=("$(printf '%s' "${_line}" | base64 -d)")
  done <<< "${_b64}"

  if [ "${#_kv_pairs[@]}" -eq 0 ]; then
    log "skip ${_vault_path}: ${_base} holds no key/value pairs (nothing to write)"
    skipped=$(( skipped + 1 ))
    continue
  fi

  # Idempotency: an existing path is left untouched and reported as skipped.
  # Inside the else branch `$?` is still the status of the condition command
  # (`vault kv get`), which is how the exit code is classified below.
  if vault kv get "${_vault_path}" >/dev/null 2>&1; then
    log "skip ${_vault_path} (already present)"
    skipped=$(( skipped + 1 ))
  else
    # exit 2 = path not found in KV v2 (the expected case); anything else is an
    # error (permissions, sealed, unreachable) and must not trigger a write.
    _get_rc=$?
    if [ "${_get_rc}" -ne 2 ]; then
      warn "kv get ${_vault_path} failed with exit ${_get_rc} (expected 2 = path not found); not writing"
      failed=$(( failed + 1 ))
      continue
    fi

    if _put_out="$(vault kv put "${_vault_path}" ${_kv_pairs[@]+"${_kv_pairs[@]}"} 2>&1)"; then
      log "loaded ${_vault_path} from ${_base} (${#_kv_pairs[@]} keys)"
      loaded=$(( loaded + 1 ))
    else
      warn "kv put ${_vault_path} failed: ${_put_out}"
      failed=$(( failed + 1 ))
    fi
  fi
done

log "summary: loaded=${loaded} skipped=${skipped} failed=${failed} profiles='${profiles_label}' secrets_dir='${SECRETS_DIR}'"

[ "${failed}" -eq 0 ] || die "${failed} file(s) could not be written to Vault; see the messages above"

log 'done'
