#!/usr/bin/env bash
# Evaluate kubernetes-security.rego against top-level workload manifests.
# Excludes broken-app.yaml (asserted to fail below) and postgres-secret.example.yaml
# (a Secret template). Subdirectories are NetworkPolicy/HPA/PDB/RBAC objects this
# policy does not inspect.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_ui.sh
source "${SCRIPT_DIR}/_ui.sh"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
POLICY="${ROOT_DIR}/policy/conftest"
BROKEN_APP="${ROOT_DIR}/manifests/broken-app.yaml"

section "02  Conftest Kubernetes policy"
log "Policy: ${POLICY}"

shopt -s nullglob
manifests=()
for path in "${ROOT_DIR}/manifests/"*.yaml; do
  case "${path##*/}" in
    broken-app.yaml|postgres-secret.example.yaml) continue ;;
  esac
  manifests+=("${path}")
done

log "Testing ${#manifests[@]} expected-pass manifests."
conftest test "${manifests[@]}" --policy "${POLICY}" --all-namespaces
success "Expected-pass manifests were accepted."

section "Assert broken-app.yaml is rejected"
if conftest test "${BROKEN_APP}" --policy "${POLICY}" --all-namespaces; then
  die "manifests/broken-app.yaml must fail Conftest"
fi
success "broken-app.yaml was rejected as expected."

success_section "Conftest checks passed"
