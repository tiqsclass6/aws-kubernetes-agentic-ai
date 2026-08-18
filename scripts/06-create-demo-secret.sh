#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_ui.sh
source "${SCRIPT_DIR}/_ui.sh"

NAMESPACE="${NAMESPACE:-app01}"
POSTGRES_USER="${POSTGRES_USER:-appuser}"
POSTGRES_DB="${POSTGRES_DB:-appdb}"
PYTHON_BIN="${PYTHON_BIN:-python}"

require_command kubectl
require_command "${PYTHON_BIN}"

section "06  PostgreSQL demo Secret"
log "Namespace: ${NAMESPACE}"

if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  die "Namespace '${NAMESPACE}' does not exist. Apply manifests/namespaces.yaml first."
fi

if kubectl get secret postgres-credentials --namespace "${NAMESPACE}" >/dev/null 2>&1; then
  warn "postgres-credentials already exists in ${NAMESPACE}; leaving it unchanged."
  log "Postgres only reads POSTGRES_PASSWORD on first init of empty PGDATA."
  action "To rotate: delete the Secret and the postgres pod, then re-run this script."
  success_section "Existing PostgreSQL Secret preserved"
  exit 0
fi

if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
  PASSWORD="${POSTGRES_PASSWORD}"
  log "Using POSTGRES_PASSWORD from the environment."
else
  PASSWORD="$(
    "${PYTHON_BIN}" - <<'PY'
import secrets

print(secrets.token_urlsafe(24))
PY
  )"
  log "Generated a new random password."
fi

kubectl \
  --namespace "${NAMESPACE}" \
  create secret generic postgres-credentials \
  --from-literal="POSTGRES_USER=${POSTGRES_USER}" \
  --from-literal="POSTGRES_PASSWORD=${PASSWORD}" \
  --from-literal="POSTGRES_DB=${POSTGRES_DB}" \
  --dry-run=client \
  --output=yaml \
  | kubectl apply -f -

success_section "PostgreSQL credentials created in namespace ${NAMESPACE}"
