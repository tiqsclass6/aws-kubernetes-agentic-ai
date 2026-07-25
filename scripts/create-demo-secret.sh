#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-app01}"
POSTGRES_USER="${POSTGRES_USER:-appuser}"
POSTGRES_DB="${POSTGRES_DB:-appdb}"
PYTHON_BIN="${PYTHON_BIN:-python}"

for command in kubectl "${PYTHON_BIN}"; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "ERROR: ${command} is required." >&2
    exit 1
  }
done

if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: namespace '${NAMESPACE}' does not exist." >&2
  echo "Apply manifests/namespaces.yaml before creating the Secret." >&2
  exit 1
fi

if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
  PASSWORD="${POSTGRES_PASSWORD}"
else
  PASSWORD="$(
    "${PYTHON_BIN}" - <<'PY'
import secrets

print(secrets.token_urlsafe(24))
PY
  )"
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

echo "PostgreSQL credentials created or updated in namespace ${NAMESPACE}."