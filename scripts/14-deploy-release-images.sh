#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_ui.sh
source "${SCRIPT_DIR}/_ui.sh"

LOCK_FILE="${1:-release-evidence/image-lock.json}"

require_command kubectl
require_command jq

if [[ ! -f "${LOCK_FILE}" ]]; then
  die "Image lock file not found: ${LOCK_FILE}"
fi

image() { jq -er --arg key "$1" '.[$key]' "${LOCK_FILE}"; }

section "14  Deploy immutable image digests"
log "Lock file: ${LOCK_FILE}"

section "Set Deployment images"
kubectl set image deployment/event-aggregator -n shared-services event-aggregator="$(image event-aggregator)"
kubectl set image deployment/observer-agent -n ai-agents observer-agent="$(image observer-agent)"
kubectl set image deployment/correlation-agent -n ai-agents correlation-agent="$(image correlation-agent)"
kubectl set image deployment/ir-analyst-agent -n ai-agents ir-analyst-agent="$(image ir-analyst-agent)"
kubectl set image deployment/governance-agent -n ai-governance governance-agent="$(image governance-agent)"
kubectl set image deployment/approval-agent -n ai-governance approval-agent="$(image approval-agent)"
kubectl set image deployment/remediation-agent -n ai-agents remediation-agent="$(image remediation-agent)"
kubectl set image deployment/reporting-agent -n ai-agents reporting-agent="$(image reporting-agent)"
kubectl set image deployment/mcp-server -n mcp mcp-server="$(image mcp-server)"
kubectl set image deployment/broken-app -n app01 broken-app="$(image app)"
success "Image references updated."

section "Wait for rollouts"
kubectl rollout status deployment/event-aggregator -n shared-services --timeout=300s
kubectl rollout status deployment/mcp-server -n mcp --timeout=300s
kubectl rollout status deployment/broken-app -n app01 --timeout=300s
for deployment in observer-agent correlation-agent ir-analyst-agent remediation-agent reporting-agent; do
  kubectl rollout status "deployment/${deployment}" -n ai-agents --timeout=300s
done
for deployment in governance-agent approval-agent; do
  kubectl rollout status "deployment/${deployment}" -n ai-governance --timeout=300s
done

success_section "Immutable image digests deployed"
