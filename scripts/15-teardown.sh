#!/usr/bin/env bash
# Tear down lab Kubernetes objects (including Helm namespace falco), Artifact
# Registry packages, the BigQuery evidence dataset, and Terraform-managed GCP
# resources.
#
# Required:
#   CONFIRM_TEARDOWN=yes
#
# Optional:
#   SKIP_KUBERNETES=yes
#   SKIP_ARTIFACT_REGISTRY=yes
#   SKIP_BIGQUERY=yes
#   SKIP_TERRAFORM=yes
#   EVIDENCE_ADMIN_SA   default evidence-admin@PROJECT_ID.iam.gserviceaccount.com
#   CLOUDSDK_PYTHON     pin this on Git Bash, e.g. /c/Python312/python.exe
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_ui.sh
source "${SCRIPT_DIR}/_ui.sh"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
PROJECT_ID="${PROJECT_ID:-class-6-5-tiqs}"
REGION="${REGION:-us-central1}"
REPOSITORY="${REPOSITORY:-vertex-agent-lab}"
EVIDENCE_DATASET="${EVIDENCE_DATASET:-agentic_governance_evidence}"
EVIDENCE_ADMIN_SA="${EVIDENCE_ADMIN_SA:-evidence-admin@${PROJECT_ID}.iam.gserviceaccount.com}"

if [[ "${CONFIRM_TEARDOWN:-}" != "yes" ]]; then
  warn_section "Teardown blocked"
  error "Refusing to destroy the lab. Re-run with CONFIRM_TEARDOWN=yes"
  action "Example: CONFIRM_TEARDOWN=yes ./scripts/15-teardown.sh"
  exit 1
fi

section "15  Tear down the lab"
log "Project: ${PROJECT_ID}"
warn "This deletes Kubernetes objects, Artifact Registry packages, BigQuery evidence, and Terraform-managed infrastructure."

if [[ -z "${CLOUDSDK_PYTHON:-}" && -x /c/Python312/python.exe ]]; then
  export CLOUDSDK_PYTHON="/c/Python312/python.exe"
  log "Using CLOUDSDK_PYTHON=${CLOUDSDK_PYTHON}"
fi

unset CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT || true
gcloud config unset auth/impersonate_service_account >/dev/null 2>&1 || true
rm -f "${HOME}/.kube/gke_gcloud_auth_plugin_cache"

if [[ "${SKIP_KUBERNETES:-}" != "yes" ]]; then
  section "1/4  Delete lab namespaces"
  kubectl delete namespace \
    app01 \
    security \
    shared-services \
    ai-agents \
    ai-governance \
    mcp \
    mcp-gateway \
    falco \
    --ignore-not-found
  success "Lab namespaces deleted (or already absent)."
else
  log "Skipping Kubernetes teardown (SKIP_KUBERNETES=yes)."
fi

if [[ "${SKIP_ARTIFACT_REGISTRY:-}" != "yes" ]]; then
  section "2/4  Delete Artifact Registry packages"
  gcloud artifacts packages list \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --repository="${REPOSITORY}" \
    --format='value(name)' \
  | tr -d '\r' \
  | while IFS= read -r package; do
      [[ -z "${package}" ]] && continue
      action "Delete package ${package##*/}"
      gcloud artifacts packages delete "${package##*/}" \
        --project="${PROJECT_ID}" \
        --location="${REGION}" \
        --repository="${REPOSITORY}" \
        --quiet
    done
  success "Artifact Registry packages removed."
else
  log "Skipping Artifact Registry teardown (SKIP_ARTIFACT_REGISTRY=yes)."
fi

if [[ "${SKIP_BIGQUERY:-}" != "yes" ]]; then
  section "3/4  Delete BigQuery evidence dataset"
  log "Impersonating ${EVIDENCE_ADMIN_SA}"
  CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="${EVIDENCE_ADMIN_SA}" \
    bq rm -r -f "${PROJECT_ID}:${EVIDENCE_DATASET}" || true
  unset CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT || true
  gcloud config unset auth/impersonate_service_account >/dev/null 2>&1 || true
  terraform -chdir="${TF_DIR}" state rm google_bigquery_dataset_access.governance_sink_writer >/dev/null 2>&1 || true
  terraform -chdir="${TF_DIR}" state rm google_bigquery_dataset.governance_evidence >/dev/null 2>&1 || true
  success "Evidence dataset removed from GCP and Terraform state."
else
  log "Skipping BigQuery teardown (SKIP_BIGQUERY=yes)."
fi

if [[ "${SKIP_TERRAFORM:-}" != "yes" ]]; then
  section "4/4  Terraform destroy"
  terraform -chdir="${TF_DIR}" plan -destroy -out=destroy.tfplan
  terraform -chdir="${TF_DIR}" apply destroy.tfplan
  rm -f "${TF_DIR}/destroy.tfplan" "${TF_DIR}/agentic.tfplan"
  success "Terraform destroy applied."
else
  log "Skipping Terraform destroy (SKIP_TERRAFORM=yes)."
fi

success_section "Teardown finished"
warn "KMS key rings, WIF pools, and custom role IDs may remain."
action "Next apply should start with ./scripts/03-adopt-retained-gcp.sh"
