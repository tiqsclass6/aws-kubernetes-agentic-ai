#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl is required." >&2; exit 1; }

echo "[1/13] Applying namespaces..."
kubectl apply -f "${ROOT_DIR}/manifests/namespaces.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/resourcequota-app01.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/limitrange-app01.yaml"

echo "[2/13] Creating OPA governance-policy ConfigMaps..."
for namespace in ai-governance ai-agents; do
  kubectl -n "${namespace}" create configmap governance-policy \
    --from-file=remediation.rego="${ROOT_DIR}/policy/governance/remediation.rego" \
    --dry-run=client -o yaml | kubectl apply -f -
done

echo "[3/13] Creating the PostgreSQL demo Secret..."
"${ROOT_DIR}/scripts/create-demo-secret.sh"

echo "[4/13] Generating or rotating MCP mTLS material..."
"${ROOT_DIR}/scripts/generate-mcp-mtls.sh"

echo "[5/13] Applying Kubernetes identities and RBAC..."
kubectl apply -f "${ROOT_DIR}/manifests/mcp-gateway-sa.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/mcp-server-sa.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/mcp-server-rbac.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/trivy-ksa.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/prowler-ksa.yaml"

echo "[6/13] Deploying the MCP gateway and MCP Server..."
kubectl apply -f "${ROOT_DIR}/manifests/mcp-nginx-config.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/mcp-gateway-deployment.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/mcp-gateway-service.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/mcp-server-config.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/mcp-deployment.yaml"

echo "[7/13] Deploying PostgreSQL and the demo application..."
kubectl apply -f "${ROOT_DIR}/manifests/postgres.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/broken-app.yaml"

echo "[8/13] Deploying pipeline and governance agents..."
kubectl apply -f "${ROOT_DIR}/manifests/event-aggregator.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/observer-agent.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/correlation-agent.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/ir-analyst-agent.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/governance-agent.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/approval-agent.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/remediation-agent.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/reporting-agent.yaml"

echo "[9/13] Waiting for every Deployment to become ready..."
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

echo "[10/13] Applying NetworkPolicies..."
kubectl apply -f "${ROOT_DIR}/manifests/network-policies/"

echo "[11/13] Applying PodMonitoring objects..."
kubectl apply -f "${ROOT_DIR}/manifests/observability/"

echo "[12/13] Applying HPAs and PDBs..."
kubectl apply -f "${ROOT_DIR}/manifests/reliability/"

echo "[13/13] Applying Trivy and Prowler CronJobs..."
kubectl apply -f "${ROOT_DIR}/manifests/trivy-cronjob.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/prowler-cronjob.yaml"

echo "Phase 5 platform deployed. Automated remediation remains disabled by default."
