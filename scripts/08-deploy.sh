#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_ui.sh
source "${SCRIPT_DIR}/_ui.sh"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

require_command kubectl

section "08  Deploy the agentic platform"
log "Repository root: ${ROOT_DIR}"

section "1/13  Namespaces and resource limits"
kubectl apply -f "${ROOT_DIR}/manifests/namespaces.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/resourcequota-app01.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/limitrange-app01.yaml"
success "Namespaces and quota objects applied."

section "2/13  OPA governance-policy ConfigMaps"
for namespace in ai-governance ai-agents; do
  kubectl -n "${namespace}" create configmap governance-policy \
    --from-file=remediation.rego="${ROOT_DIR}/policy/governance/remediation.rego" \
    --dry-run=client -o yaml | kubectl apply -f -
done
success "Governance policy ConfigMaps applied."

section "3/13  PostgreSQL demo Secret"
"${ROOT_DIR}/scripts/06-create-demo-secret.sh"

section "4/13  MCP mTLS material"
"${ROOT_DIR}/scripts/07-generate-mcp-mtls.sh"

section "5/13  Kubernetes identities and RBAC"
kubectl apply -f "${ROOT_DIR}/manifests/mcp-gateway-sa.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/mcp-server-sa.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/mcp-server-rbac.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/trivy-ksa.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/prowler-ksa.yaml"
success "Service accounts and RBAC applied."

section "6/13  MCP gateway and MCP Server"
kubectl apply -f "${ROOT_DIR}/manifests/mcp-nginx-config.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/mcp-gateway-deployment.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/mcp-gateway-service.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/mcp-server-config.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/mcp-deployment.yaml"
success "MCP gateway and server applied."

section "7/13  PostgreSQL and demo application"
kubectl apply -f "${ROOT_DIR}/manifests/postgres.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/broken-app.yaml"
success "Demo workloads applied."

section "8/13  Pipeline and governance agents"
kubectl apply -f "${ROOT_DIR}/manifests/event-aggregator.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/observer-agent.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/correlation-agent.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/ir-analyst-agent.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/governance-agent.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/approval-agent.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/remediation-agent.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/reporting-agent.yaml"
success "Agent deployments applied."

section "9/13  Wait for Deployments"
kubectl rollout status deployment/mcp-gateway -n mcp-gateway --timeout=300s
kubectl rollout status deployment/mcp-server -n mcp --timeout=300s
kubectl rollout status deployment/postgres -n app01 --timeout=300s
kubectl rollout status deployment/broken-app -n app01 --timeout=300s
kubectl rollout status deployment/event-aggregator -n shared-services --timeout=300s
for deployment in observer-agent correlation-agent ir-analyst-agent remediation-agent reporting-agent; do
  kubectl rollout status "deployment/${deployment}" -n ai-agents --timeout=300s
done
for deployment in governance-agent approval-agent; do
  kubectl rollout status "deployment/${deployment}" -n ai-governance --timeout=300s
done
success "All Deployments are ready."

section "10/13  NetworkPolicies"
kubectl apply -f "${ROOT_DIR}/manifests/network-policies/"
success "NetworkPolicies applied."

section "11/13  PodMonitoring"
kubectl apply -f "${ROOT_DIR}/manifests/observability/"
success "PodMonitoring applied."

section "12/13  HPAs and PDBs"
kubectl apply -f "${ROOT_DIR}/manifests/reliability/"
success "Reliability objects applied."

section "13/13  Trivy and Prowler CronJobs"
kubectl apply -f "${ROOT_DIR}/manifests/trivy-cronjob.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/prowler-cronjob.yaml"
success "Scanner CronJobs applied."

success_section "Platform deployed"
warn "Automated remediation remains disabled by default."
