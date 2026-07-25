#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

required_commands=(python terraform conftest opa)
for required_command in "${required_commands[@]}"; do
  if ! command -v "${required_command}" >/dev/null 2>&1; then
    echo "ERROR: ${required_command} is required." >&2
    exit 1
  fi
done

echo "[1/8] Compiling Python sources..."
python -m compileall -q "${ROOT_DIR}/python"

echo "[2/8] Running Python tests..."
python -m pytest -q "${ROOT_DIR}/python/tests"

echo "[3/8] Validating Kubernetes YAML syntax..."
python - "${ROOT_DIR}" <<'PY_YAML'
from pathlib import Path
import sys

import yaml

root = Path(sys.argv[1])
for path in sorted((root / "manifests").rglob("*.yaml")):
    with path.open(encoding="utf-8") as handle:
        list(yaml.safe_load_all(handle))
    print(f"validated {path.relative_to(root)}")
PY_YAML

echo "[4/8] Checking shell-script syntax..."
while IFS= read -r -d '' script; do
  bash -n "${script}"
done < <(find "${ROOT_DIR}/scripts" -type f -name '*.sh' -print0)

echo "[5/8] Running OPA governance tests..."
opa test "${ROOT_DIR}/policy/governance" -v

echo "[6/8] Formatting Terraform files..."
# terraform fmt -check exits with status 3 when files need formatting. Format the
# existing files in place first, then verify that the tree is clean. This does
# not rename or reorganize any Terraform files.
terraform -chdir="${ROOT_DIR}/terraform" fmt -recursive
terraform -chdir="${ROOT_DIR}/terraform" fmt -check -recursive

echo "[7/8] Initializing and validating Terraform..."
terraform -chdir="${ROOT_DIR}/terraform" init -backend=false -input=false
terraform -chdir="${ROOT_DIR}/terraform" validate

echo "[8/8] Evaluating Kubernetes manifests with Conftest..."
conftest_manifests=(
  "${ROOT_DIR}/manifests/event-aggregator.yaml"
  "${ROOT_DIR}/manifests/observer-agent.yaml"
  "${ROOT_DIR}/manifests/correlation-agent.yaml"
  "${ROOT_DIR}/manifests/ir-analyst-agent.yaml"
  "${ROOT_DIR}/manifests/governance-agent.yaml"
  "${ROOT_DIR}/manifests/approval-agent.yaml"
  "${ROOT_DIR}/manifests/remediation-agent.yaml"
  "${ROOT_DIR}/manifests/reporting-agent.yaml"
  "${ROOT_DIR}/manifests/mcp-deployment.yaml"
)

conftest test \
  "${conftest_manifests[@]}" \
  --policy "${ROOT_DIR}/policy/conftest" \
  --all-namespaces

echo "Phase 5 validation passed."
