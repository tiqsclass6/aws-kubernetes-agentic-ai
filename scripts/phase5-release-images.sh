#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?PROJECT_ID is required}"
REGION="${REGION:-us-central1}"
REPOSITORY="${REPOSITORY:-vertex-agent-lab}"
RELEASE_TAG="${RELEASE_TAG:-phase5-v1}"
TRIVY_VERSION="${TRIVY_VERSION:-0.70.0}"
SYFT_VERSION="${SYFT_VERSION:-1.44.0}"
COSIGN_OIDC_ISSUER="${COSIGN_OIDC_ISSUER:-https://token.actions.githubusercontent.com}"
COSIGN_CERTIFICATE_IDENTITY="${COSIGN_CERTIFICATE_IDENTITY:-}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}"
EVIDENCE_DIR="${ROOT_DIR}/release-evidence"

for command in docker gcloud cosign jq; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "ERROR: ${command} is required." >&2
    exit 1
  }
done

rm -rf "${EVIDENCE_DIR}"
mkdir -p \
  "${EVIDENCE_DIR}/sbom" \
  "${EVIDENCE_DIR}/trivy" \
  "${EVIDENCE_DIR}/cosign"
echo '{}' > "${EVIDENCE_DIR}/image-lock.json"

images=(
  "event-aggregator:docker/aggregator"
  "observer-agent:docker/observer_agent"
  "correlation-agent:docker/correlation_agent"
  "ir-analyst-agent:docker/ir_analyst_agent"
  "governance-agent:docker/governance_agent"
  "approval-agent:docker/approval_agent"
  "remediation-agent:docker/remediation_agent"
  "reporting-agent:docker/reporting_agent"
  "mcp-server:docker/mcp_docker.txt"
)

for item in "${images[@]}"; do
  image_name="${item%%:*}"
  dockerfile="${item#*:}"
  image_ref="${REGISTRY}/${image_name}:${RELEASE_TAG}"
  metadata_file="${EVIDENCE_DIR}/${image_name}-metadata.json"

  echo "Building and pushing ${image_ref}"
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
      echo "ERROR: Trivy rejected ${immutable_ref}. Results: ${trivy_output}" >&2
      exit 1
    }

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
  else
    echo "WARNING: COSIGN_CERTIFICATE_IDENTITY is empty; post-sign verification was skipped." >&2
  fi

  jq \
    --arg name "${image_name}" \
    --arg ref "${immutable_ref}" \
    '. + {($name): $ref}' \
    "${EVIDENCE_DIR}/image-lock.json" \
    > "${EVIDENCE_DIR}/image-lock.tmp"
  mv "${EVIDENCE_DIR}/image-lock.tmp" "${EVIDENCE_DIR}/image-lock.json"
done

jq -S . "${EVIDENCE_DIR}/image-lock.json" \
  > "${EVIDENCE_DIR}/image-lock.sorted.json"
mv "${EVIDENCE_DIR}/image-lock.sorted.json" "${EVIDENCE_DIR}/image-lock.json"

sha256sum "${EVIDENCE_DIR}/image-lock.json" \
  > "${EVIDENCE_DIR}/image-lock.sha256"

cat "${EVIDENCE_DIR}/image-lock.json"
echo "Phase 5 release evidence created in ${EVIDENCE_DIR}."
