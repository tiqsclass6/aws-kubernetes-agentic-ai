#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_ui.sh
source "${SCRIPT_DIR}/_ui.sh"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
INPUT_TOPIC="${INPUT_TOPIC:-security-findings}"
REPORT_SUBSCRIPTION="${REPORT_SUBSCRIPTION:-incident-reports-debug-sub}"
WAIT_SECONDS="${WAIT_SECONDS:-720}"
POLL_SECONDS="${POLL_SECONDS:-15}"

require_command gcloud
require_command python

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
  die "Set PROJECT_ID or configure a gcloud project."
fi

TEST_RUN_ID="-$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}"
TARGET_DEPLOYMENT="smoke-${TEST_RUN_ID,,}"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TMP_DIR="$(mktemp -d)"

trap 'rm -rf "${TMP_DIR}"' EXIT

section "10  End-to-end pipeline test"
log "Project:      ${PROJECT_ID}"
log "Topic:        ${INPUT_TOPIC}"
log "Subscription: ${REPORT_SUBSCRIPTION}"
log "Test run ID:  ${TEST_RUN_ID}"

python \
  - \
  "${TEST_RUN_ID}" \
  "${TARGET_DEPLOYMENT}" \
  "${NOW}" \
  "${TMP_DIR}" \
  "${PROJECT_ID}" <<'PY'
import json
import sys
from pathlib import Path

run_id, deployment, now, directory, project_id = sys.argv[1:]

base = {
    "schema_version": "1.0",
    "event_time": now,
    "ingested_at": now,
    "status": "OPEN",
    "asset": {
        "namespace": "app01",
        "deployment": deployment,
        "project_id": project_id,
    },
    "labels": {
        "_test_run": run_id,
    },
}

events = [
    {
        **base,
        "finding_id": f"{run_id}-falco",
        "source": "falco",
        "category": "runtime-security",
        "severity": "HIGH",
        "title": "Repeated application process failure",
        "description": (
            "Synthetic runtime event for the "
            "pipeline test."
        ),
        "evidence": {
            "rule": "correlation smoke test",
            "test_run_id": run_id,
        },
    },
    {
        **base,
        "finding_id": f"{run_id}-logging",
        "source": "cloud-logging",
        "category": "gke-log-event",
        "severity": "HIGH",
        "title": "Deployment crash loop warning",
        "description": (
            "Synthetic GKE warning correlated "
            "to the same deployment."
        ),
        "evidence": {
            "message": "Back-off restarting failed container",
            "test_run_id": run_id,
        },
    },
]

path = Path(directory)

for index, event in enumerate(events, start=1):
    (path / f"event-{index}.json").write_text(
        json.dumps(
            event,
            separators=(",", ":"),
        ),
        encoding="utf-8",
    )
PY

section "Publish correlated findings"
for event_file in "${TMP_DIR}"/event-*.json; do
  gcloud pubsub topics publish \
    "${INPUT_TOPIC}" \
    --project="${PROJECT_ID}" \
    --message="$(cat "${event_file}")" \
    --attribute="source=-smoke-test,test_run_id=${TEST_RUN_ID}" \
    --quiet \
    >/dev/null
done
success "Published two correlated findings for ${TEST_RUN_ID}."
log "Waiting up to ${WAIT_SECONDS}s for an incident report."

section "Poll incident reports"
DEADLINE=$((SECONDS + WAIT_SECONDS))

while ((SECONDS < DEADLINE)); do
  OUTPUT_FILE="${TMP_DIR}/pull.json"

  gcloud pubsub subscriptions pull \
    "${REPORT_SUBSCRIPTION}" \
    --project="${PROJECT_ID}" \
    --limit=20 \
    --auto-ack \
    --format=json \
    >"${OUTPUT_FILE}"

  if python - "${OUTPUT_FILE}" "${TEST_RUN_ID}" <<'PY'
import base64
import json
import sys
from pathlib import Path

path, run_id = sys.argv[1:]

items = json.loads(
    Path(path).read_text(
        encoding="utf-8",
    )
    or "[]"
)

for item in items:
    message = item.get(
        "message",
        item,
    )

    raw = message.get(
        "data",
        "",
    )

    candidates = [raw]

    try:
        candidates.append(
            base64.b64decode(
                raw
            ).decode("utf-8")
        )
    except Exception:
        pass

    for candidate in candidates:
        try:
            payload = json.loads(
                candidate
            )
        except Exception:
            continue

        serialized = json.dumps(
            payload,
            sort_keys=True,
        )

        if run_id in serialized:
            print(
                json.dumps(
                    payload,
                    indent=2,
                    sort_keys=True,
                )
            )

            raise SystemExit(0)

raise SystemExit(1)
PY
  then
    success_section "End-to-end pipeline test passed"
    exit 0
  fi

  log "No matching report yet; retrying in ${POLL_SECONDS}s."
  sleep "${POLL_SECONDS}"
done

error "No report containing ${TEST_RUN_ID} was received."
action "Inspect the agent logs and the agent-events-dlq-sub subscription."
exit 1
