#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_ui.sh
source "${SCRIPT_DIR}/_ui.sh"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT_ID="${PROJECT_ID:-class-6-5-tiqs}"
REGION="${REGION:-us-central1}"
REPOSITORY="${REPOSITORY:-vertex-agent-lab}"
TAG="${TAG:-v1}"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}"

require_command docker
require_command gcloud

section "04  Build and push lab images"
log "Registry: ${REGISTRY}"
log "Tag:      ${TAG}"

gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
success "Docker authenticated to Artifact Registry."

build_and_push() {
  local image="$1"
  local dockerfile="$2"

  section "Build ${image}:${TAG}"
  docker build \
    --file "${ROOT_DIR}/${dockerfile}" \
    --tag "${REGISTRY}/${image}:${TAG}" \
    "${ROOT_DIR}/python"
  docker push "${REGISTRY}/${image}:${TAG}"
  success "Pushed ${REGISTRY}/${image}:${TAG}"
}

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
  build_and_push "${item%%:*}" "${item#*:}"
done

success_section "Images built and pushed with tag ${TAG}"
