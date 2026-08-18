#!/usr/bin/env bash
# Adopt GCP resources that survive terraform destroy (KMS key rings, WIF pools,
# custom IAM roles in the 7-day deletion window) and clear a node pool left in
# ERROR. Run from the repo root before re-applying after a failed or partial destroy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_ui.sh
source "${SCRIPT_DIR}/_ui.sh"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
PROJECT_ID="${PROJECT_ID:-class-6-5-tiqs}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-c}"
CLUSTER_NAME="${CLUSTER_NAME:-vertex-agent-lab}"
WIF_POOL_ID="${WIF_POOL_ID:-github-actions}"
WIF_PROVIDER_ID="${WIF_PROVIDER_ID:-github}"
KMS_KEYRING_ID="${KMS_KEYRING_ID:-agentic-governance}"
KMS_KEY_ID="${KMS_KEY_ID:-approval-signing}"

tf() {
  terraform -chdir="${TF_DIR}" "$@"
}

import_if_missing() {
  local address="$1"
  local import_id="$2"

  if tf state show "${address}" >/dev/null 2>&1; then
    log "Skip import ${address} (already in state)."
    return 0
  fi

  action "Import ${address}"
  if tf import "${address}" "${import_id}"; then
    success "Imported ${address}."
  else
    warn "Could not import ${address}."
  fi
}

require_command gcloud
require_command terraform

section "03  Adopt retained GCP resources"
log "Project: ${PROJECT_ID}"
log "Zone:    ${ZONE}"

if [[ ! -d "${TF_DIR}/.terraform" ]]; then
  die "Terraform is not initialized. Run: terraform -chdir=terraform init"
fi

section "Workload Identity Federation"
POOL_NAME="projects/${PROJECT_ID}/locations/global/workloadIdentityPools/${WIF_POOL_ID}"
POOL_STATE="$(gcloud iam workload-identity-pools describe "${WIF_POOL_ID}" \
  --location=global \
  --project="${PROJECT_ID}" \
  --format='value(state)' 2>/dev/null || true)"

if [[ "${POOL_STATE}" == "DELETED" ]]; then
  action "Undelete workload identity pool ${WIF_POOL_ID}"
  gcloud iam workload-identity-pools undelete "${WIF_POOL_ID}" \
    --location=global \
    --project="${PROJECT_ID}"
  POOL_STATE="ACTIVE"
  success "Pool ${WIF_POOL_ID} undeleted."
fi

if [[ "${POOL_STATE}" == "ACTIVE" ]]; then
  import_if_missing \
    google_iam_workload_identity_pool.github_actions \
    "${POOL_NAME}"
  PROVIDER_STATE="$(gcloud iam workload-identity-pools providers describe "${WIF_PROVIDER_ID}" \
    --location=global \
    --workload-identity-pool="${WIF_POOL_ID}" \
    --project="${PROJECT_ID}" \
    --format='value(state)' 2>/dev/null || true)"
  if [[ "${PROVIDER_STATE}" == "DELETED" ]]; then
    action "Undelete workload identity pool provider ${WIF_PROVIDER_ID}"
    gcloud iam workload-identity-pools providers undelete "${WIF_PROVIDER_ID}" \
      --location=global \
      --workload-identity-pool="${WIF_POOL_ID}" \
      --project="${PROJECT_ID}"
    PROVIDER_STATE="ACTIVE"
    success "Provider ${WIF_PROVIDER_ID} undeleted."
  fi
  if [[ "${PROVIDER_STATE}" == "ACTIVE" ]]; then
    import_if_missing \
      google_iam_workload_identity_pool_provider.github_actions \
      "${POOL_NAME}/providers/${WIF_PROVIDER_ID}"
  fi
else
  log "Workload Identity pool ${WIF_POOL_ID} is not ACTIVE (state=${POOL_STATE:-missing})."
fi

section "Cloud KMS"
if gcloud kms keyrings describe "${KMS_KEYRING_ID}" \
  --location="${REGION}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1; then
  import_if_missing \
    google_kms_key_ring.governance \
    "projects/${PROJECT_ID}/locations/${REGION}/keyRings/${KMS_KEYRING_ID}"
  if gcloud kms keys describe "${KMS_KEY_ID}" \
    --keyring="${KMS_KEYRING_ID}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}" >/dev/null 2>&1; then
    import_if_missing \
      google_kms_crypto_key.approval_signing \
      "projects/${PROJECT_ID}/locations/${REGION}/keyRings/${KMS_KEYRING_ID}/cryptoKeys/${KMS_KEY_ID}"
    ENABLED_VERSION="$(gcloud kms keys versions list \
      --key="${KMS_KEY_ID}" \
      --keyring="${KMS_KEYRING_ID}" \
      --location="${REGION}" \
      --project="${PROJECT_ID}" \
      --filter='state=ENABLED' \
      --format='value(name)' \
      --limit=1 2>/dev/null || true)"
    if [[ -z "${ENABLED_VERSION}" ]]; then
      action "Create an ENABLED version on ${KMS_KEY_ID}"
      gcloud kms keys versions create \
        --key="${KMS_KEY_ID}" \
        --keyring="${KMS_KEYRING_ID}" \
        --location="${REGION}" \
        --project="${PROJECT_ID}"
      success "Created a new KMS key version."
    else
      log "ENABLED KMS version already present."
    fi
  fi
else
  log "KMS key ring ${KMS_KEYRING_ID} was not found; nothing to import."
fi

section "GKE node pool"
NODE_POOL="${CLUSTER_NAME}-nodes"
if gcloud container node-pools describe "${NODE_POOL}" \
  --cluster="${CLUSTER_NAME}" \
  --zone="${ZONE}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1; then
  status="$(gcloud container node-pools describe "${NODE_POOL}" \
    --cluster="${CLUSTER_NAME}" \
    --zone="${ZONE}" \
    --project="${PROJECT_ID}" \
    --format='value(status)')"
  if [[ "${status}" == "ERROR" ]]; then
    warn "Node pool ${NODE_POOL} is in ERROR; deleting it."
    gcloud container node-pools delete "${NODE_POOL}" \
      --cluster="${CLUSTER_NAME}" \
      --zone="${ZONE}" \
      --project="${PROJECT_ID}" \
      --quiet
    tf state rm google_container_node_pool.primary >/dev/null 2>&1 || true
    success "Deleted ERROR node pool and removed it from state."
  else
    log "Node pool ${NODE_POOL} status: ${status}"
  fi
else
  log "Node pool ${NODE_POOL} was not found."
fi

success_section "Adopt complete"
action "Next: terraform -chdir=terraform plan -out=agentic.tfplan"
