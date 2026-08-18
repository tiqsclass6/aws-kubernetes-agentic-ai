#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_ui.sh
source "${SCRIPT_DIR}/_ui.sh"

NAMESPACE="${NAMESPACE:-ai-agents}"
DEPLOYMENT="${DEPLOYMENT:-observer-agent}"
LOCAL_PORT="${LOCAL_PORT:-18080}"

require_command kubectl
require_command curl

section "12  Metrics smoke test"
log "Target: ${NAMESPACE}/${DEPLOYMENT}"
log "Local port: ${LOCAL_PORT}"

section "Port-forward to metrics"
kubectl port-forward -n "${NAMESPACE}" "deployment/${DEPLOYMENT}" \
  "${LOCAL_PORT}:8080" >/tmp/agent-port-forward.log 2>&1 &
PF_PID=$!
trap 'kill "${PF_PID}" >/dev/null 2>&1 || true' EXIT

READY=false
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${LOCAL_PORT}/healthz" >/dev/null; then
    READY=true
    break
  fi
  sleep 1
done

if [[ "${READY}" != "true" ]]; then
  die "Health check did not succeed on 127.0.0.1:${LOCAL_PORT}/healthz"
fi
success "Health endpoint responded."

section "Scrape Prometheus metrics"
curl -fsS "http://127.0.0.1:${LOCAL_PORT}/metrics" \
  | grep -E 'agent_(ready|messages_received_total|message_processing_seconds)'

success_section "Metrics smoke test passed"
log "${NAMESPACE}/${DEPLOYMENT} is exporting expected agent metrics."
