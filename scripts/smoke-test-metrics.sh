#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-ai-agents}"
DEPLOYMENT="${DEPLOYMENT:-observer-agent}"
LOCAL_PORT="${LOCAL_PORT:-18080}"

command -v kubectl >/dev/null 2>&1 || {
  echo "ERROR: kubectl is required." >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || {
  echo "ERROR: curl is required." >&2
  exit 1
}

kubectl port-forward -n "${NAMESPACE}" "deployment/${DEPLOYMENT}" \
  "${LOCAL_PORT}:8080" >/tmp/phase4-port-forward.log 2>&1 &
PF_PID=$!
trap 'kill "${PF_PID}" >/dev/null 2>&1 || true' EXIT

for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${LOCAL_PORT}/healthz" >/dev/null; then
    break
  fi
  sleep 1
done

curl -fsS "http://127.0.0.1:${LOCAL_PORT}/metrics" \
  | grep -E 'agent_(ready|messages_received_total|message_processing_seconds)'

echo "Metrics smoke test passed for ${NAMESPACE}/${DEPLOYMENT}."
