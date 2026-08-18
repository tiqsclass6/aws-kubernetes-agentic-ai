#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_ui.sh
source "${SCRIPT_DIR}/_ui.sh"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

section "01  Validate repository"
log "Repository root: ${ROOT_DIR}"

require_command python
require_command terraform
require_command conftest
require_command opa

section "1/8  Compile Python sources"
python -m compileall -q "${ROOT_DIR}/python"
success "Python sources compiled."

section "2/8  Run Python tests"
python -m pytest -q "${ROOT_DIR}/python/tests"
success "Python tests passed."

section "3/8  Validate Kubernetes YAML"
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
success "Kubernetes YAML parsed."

section "4/8  Check shell-script syntax"
while IFS= read -r -d '' script; do
  bash -n "${script}"
  log "syntax ok  ${script#"${ROOT_DIR}/"}"
done < <(find "${ROOT_DIR}/scripts" -type f -name '*.sh' -print0)
success "Shell scripts passed bash -n."

section "5/8  Run OPA governance tests"
opa test "${ROOT_DIR}/policy/governance" -v
success "OPA tests passed."

section "6/8  Format Terraform"
terraform -chdir="${ROOT_DIR}/terraform" fmt -recursive
terraform -chdir="${ROOT_DIR}/terraform" fmt -check -recursive
success "Terraform formatting is clean."

section "7/8  Initialize and validate Terraform"
terraform -chdir="${ROOT_DIR}/terraform" init -backend=false -input=false
terraform -chdir="${ROOT_DIR}/terraform" validate
success "Terraform validate passed."

section "8/8  Evaluate Kubernetes manifests with Conftest"
bash "${ROOT_DIR}/scripts/02-conftest-test.sh"

success_section "Validation passed"
