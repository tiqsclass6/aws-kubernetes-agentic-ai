#!/usr/bin/env bash
# Evaluate kubernetes-security.rego against top-level workload manifests.
# Excludes broken-app.yaml (asserted to fail below) and postgres-secret.example.yaml
# (a Secret template). Subdirectories are NetworkPolicy/HPA/PDB/RBAC objects this
# policy does not inspect.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY="${ROOT_DIR}/policy/conftest"
BROKEN_APP="${ROOT_DIR}/manifests/broken-app.yaml"

shopt -s nullglob
manifests=()
for path in "${ROOT_DIR}/manifests/"*.yaml; do
  case "${path##*/}" in
    broken-app.yaml|postgres-secret.example.yaml) continue ;;
  esac
  manifests+=("${path}")
done

conftest test "${manifests[@]}" --policy "${POLICY}" --all-namespaces

if conftest test "${BROKEN_APP}" --policy "${POLICY}" --all-namespaces; then
  echo "ERROR: manifests/broken-app.yaml must fail Conftest" >&2
  exit 1
fi
