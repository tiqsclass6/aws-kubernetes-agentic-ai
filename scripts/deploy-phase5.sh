#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl is required." >&2; exit 1; }

kubectl apply -f "${ROOT_DIR}/manifests/ai-governance-namespace.yaml"

for namespace in ai-governance ai-agents; do
  kubectl -n "${namespace}" create configmap governance-policy \
    --from-file=remediation.rego="${ROOT_DIR}/policy/governance/remediation.rego" \
    --dry-run=client -o yaml | kubectl apply -f -
done

kubectl apply -f "${ROOT_DIR}/manifests/governance-agent.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/approval-agent.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/remediation-agent.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/mcp-server-config.yaml"

kubectl apply -f "${ROOT_DIR}/manifests/namespaces.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/observability/phase5-governance-podmonitoring.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/reliability/phase5-governance-hpa.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/reliability/phase5-governance-pdb.yaml"

kubectl rollout restart deployment/mcp-server -n mcp
kubectl rollout status deployment/governance-agent -n ai-governance --timeout=300s
kubectl rollout status deployment/approval-agent -n ai-governance --timeout=300s
kubectl rollout status deployment/remediation-agent -n ai-agents --timeout=300s
kubectl rollout status deployment/mcp-server -n mcp --timeout=300s

kubectl get pods -n ai-governance -o wide
kubectl get podmonitoring -n ai-governance
kubectl get hpa,pdb -n ai-governance

echo "Phase 5 governance controls deployed. Execution remains disabled by default."
