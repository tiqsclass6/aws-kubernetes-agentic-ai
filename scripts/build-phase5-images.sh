#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-class-6-5-tiqs}"
REGION="${REGION:-us-central1}"
REPOSITORY="${REPOSITORY:-vertex-agent-lab}"
TAG="${TAG:-phase5-v1}"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for command in docker gcloud; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "ERROR: ${command} is required." >&2
    exit 1
  }
done

gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

build_and_push() {
  local image="$1"
  local dockerfile="$2"
  docker build \
    --file "${ROOT_DIR}/${dockerfile}" \
    --tag "${REGISTRY}/${image}:${TAG}" \
    "${ROOT_DIR}/python"
  docker push "${REGISTRY}/${image}:${TAG}"
}

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
  build_and_push "${item%%:*}" "${item#*:}"
done

echo "Phase 5 images built and pushed with tag ${TAG}."
