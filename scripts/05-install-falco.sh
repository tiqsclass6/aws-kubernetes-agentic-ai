#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_ui.sh
source "${SCRIPT_DIR}/_ui.sh"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

require_command helm
require_command kubectl

section "05  Install Falco"
log "Chart: falcosecurity/falco 9.1.0"
log "Namespace: falco"

helm repo add \
  falcosecurity \
  https://falcosecurity.github.io/charts \
  --force-update
helm repo update falcosecurity
success "Helm repository updated."

section "Install or upgrade the Falco release"
helm upgrade \
  --install \
  falco \
  falcosecurity/falco \
  --namespace falco \
  --create-namespace \
  --version 9.1.0 \
  --values "${ROOT_DIR}/helm/falco/values.yaml" \
  --wait \
  --timeout 10m
success "Helm release is installed."

section "Wait for the Falco DaemonSet"
kubectl rollout status \
  daemonset/falco \
  -n falco \
  --timeout=5m
kubectl get pods \
  -n falco \
  -o wide

success_section "Falco is ready"
