#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_ui.sh
source "${SCRIPT_DIR}/_ui.sh"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT_ID="${PROJECT_ID:?PROJECT_ID is required}"
REGION="${REGION:-us-central1}"
REPOSITORY="${REPOSITORY:-vertex-agent-lab}"
RELEASE_TAG="${RELEASE_TAG:-v1}"
TRIVY_VERSION="${TRIVY_VERSION:-0.74.0}"
SYFT_VERSION="${SYFT_VERSION:-1.44.0}"
COSIGN_OIDC_ISSUER="${COSIGN_OIDC_ISSUER:-https://token.actions.githubusercontent.com}"
COSIGN_CERTIFICATE_IDENTITY="${COSIGN_CERTIFICATE_IDENTITY:-}"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}"
EVIDENCE_DIR="${ROOT_DIR}/release-evidence"

require_command docker
require_command gcloud
require_command cosign
require_command jq

section "13  Release images with SBOM, scan, and sign"
log "Registry: ${REGISTRY}"
log "Tag:      ${RELEASE_TAG}"
log "Evidence: ${EVIDENCE_DIR}"

rm -rf "${EVIDENCE_DIR}"
mkdir -p \
  "${EVIDENCE_DIR}/sbom" \
  "${EVIDENCE_DIR}/trivy" \
  "${EVIDENCE_DIR}/cosign"
echo '{}' > "${EVIDENCE_DIR}/image-lock.json"
success "Evidence directory prepared."

images=(
  "app:docker/app"
  "event-aggregator:docker/aggregator"
  "observer-agent:docker/observer_agent"
  "correlation-agent:docker/correlation_agent"
  "ir-analyst-agent:docker/ir_analyst_agent"
  "governance-agent:docker/governance_agent"
  "approval-agent:docker/approval_agent"
  "remediation-agent:docker/remediation_agent"
  "reporting-agent:docker/reporting_agent"
  "mcp-server:docker/mcp_docker.txt"
  "scanner-publisher:docker/scanner_publisher"
)

for item in "${images[@]}"; do
  image_name="${item%%:*}"
  dockerfile="${item#*:}"
  image_ref="${REGISTRY}/${image_name}:${RELEASE_TAG}"
  metadata_file="${EVIDENCE_DIR}/${image_name}-metadata.json"

  section "Build and push ${image_name}"
  log "${image_ref}"
  docker buildx build \
    --file "${ROOT_DIR}/${dockerfile}" \
    --tag "${image_ref}" \
    --push \
    --provenance=true \
    --sbom=true \
    --metadata-file "${metadata_file}" \
    "${ROOT_DIR}/python"

  digest="$(jq -r '."containerimage.digest"' "${metadata_file}")"
  immutable_ref="${REGISTRY}/${image_name}@${digest}"
  success "Pushed ${immutable_ref}"

  section "Scan ${image_name} with Trivy"
  trivy_output="${EVIDENCE_DIR}/trivy/${image_name}.json"
  docker pull "${immutable_ref}"

  docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${EVIDENCE_DIR}/trivy:/out" \
    "aquasec/trivy:${TRIVY_VERSION}" image \
    --severity HIGH,CRITICAL \
    --ignore-unfixed \
    --exit-code 1 \
    --format json \
    --output "/out/${image_name}.json" \
    "${immutable_ref}" || {
      die "Trivy rejected ${immutable_ref}. Results: ${trivy_output}"
    }
  success "Trivy accepted ${image_name}."

  section "SBOM and Cosign for ${image_name}"
  docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${EVIDENCE_DIR}/sbom:/out" \
    "anchore/syft:v${SYFT_VERSION}" \
    "${immutable_ref}" \
    -o "spdx-json=/out/${image_name}.spdx.json"

  cosign sign --yes "${immutable_ref}"
  cosign attest --yes \
    --type spdxjson \
    --predicate "${EVIDENCE_DIR}/sbom/${image_name}.spdx.json" \
    "${immutable_ref}"
  success "Signed and attested ${image_name}."

  if [[ -n "${COSIGN_CERTIFICATE_IDENTITY}" ]]; then
    cosign verify \
      --certificate-identity "${COSIGN_CERTIFICATE_IDENTITY}" \
      --certificate-oidc-issuer "${COSIGN_OIDC_ISSUER}" \
      --output json \
      "${immutable_ref}" \
      > "${EVIDENCE_DIR}/cosign/${image_name}-signature.json"

    cosign verify-attestation \
      --certificate-identity "${COSIGN_CERTIFICATE_IDENTITY}" \
      --certificate-oidc-issuer "${COSIGN_OIDC_ISSUER}" \
      --type spdxjson \
      --output json \
      "${immutable_ref}" \
      > "${EVIDENCE_DIR}/cosign/${image_name}-attestation.json"
    success "Verified Cosign signature and attestation."
  else
    warn "COSIGN_CERTIFICATE_IDENTITY is empty; post-sign verification was skipped."
  fi

  jq \
    --arg name "${image_name}" \
    --arg ref "${immutable_ref}" \
    '. + {($name): $ref}' \
    "${EVIDENCE_DIR}/image-lock.json" \
    > "${EVIDENCE_DIR}/image-lock.tmp"
  mv "${EVIDENCE_DIR}/image-lock.tmp" "${EVIDENCE_DIR}/image-lock.json"
done

section "Write image lock"
jq -S . "${EVIDENCE_DIR}/image-lock.json" \
  > "${EVIDENCE_DIR}/image-lock.sorted.json"
mv "${EVIDENCE_DIR}/image-lock.sorted.json" "${EVIDENCE_DIR}/image-lock.json"

sha256sum "${EVIDENCE_DIR}/image-lock.json" \
  > "${EVIDENCE_DIR}/image-lock.sha256"

cat "${EVIDENCE_DIR}/image-lock.json"

success_section "Release evidence created"
log "${EVIDENCE_DIR}"
