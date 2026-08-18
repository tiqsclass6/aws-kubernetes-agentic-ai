#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_ui.sh
source "${SCRIPT_DIR}/_ui.sh"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
INPUT_TOPIC="${INPUT_TOPIC:-analyzed-incidents}"
DECISION_SUBSCRIPTION="${DECISION_SUBSCRIPTION:-governance-decisions-debug-sub}"
WAIT_SECONDS="${WAIT_SECONDS:-180}"
POLL_SECONDS="${POLL_SECONDS:-10}"

require_command gcloud
require_command python

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
  die "Configure PROJECT_ID or set a gcloud project."
fi

RUN_ID="lab-$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

section "09  Governance smoke test"
log "Project:      ${PROJECT_ID}"
log "Topic:        ${INPUT_TOPIC}"
log "Subscription: ${DECISION_SUBSCRIPTION}"
log "Run ID:       ${RUN_ID}"

python - "${RUN_ID}" "${NOW}" > "${TMP_DIR}/event.json" <<'PY_EVENT'
import json,sys
run_id,now=sys.argv[1:]
print(json.dumps({"schema_version":"1.0","event_type":"ir-analyzed-incident","source":"governance-smoke-test","severity":"HIGH","analysis_id":f"analysis-{run_id}","analyzed_at":now,"incident":{"incident_id":f"incident-{run_id}","entity_key":"k8s:app01:deployment:broken-app","risk_score":82,"risk_level":"HIGH","signal_count":3,"sources":["falco","cloud-logging"],"signals":[{"test_run_id":run_id}]},"analysis":{"executive_summary":"Synthetic governance validation.","assessed_severity":"HIGH","confidence":0.97,"likely_root_cause":"Synthetic crash-loop fixture.","key_evidence":["runtime anomaly","crash-loop warning","correlated signals"],"containment_steps":["Review governance decision"],"investigation_steps":["Inspect synthetic fixture"],"recommended_action":{"action":"restart_deployment","target_namespace":"app01","target_deployment":"broken-app","rationale":"Validate governance without executing remediation.","expected_outcome":"A REQUIRE_APPROVAL decision while automation is disabled.","operational_risk":"low","requires_human_approval":False}}}))
PY_EVENT

section "Publish synthetic incident"
gcloud pubsub topics publish "${INPUT_TOPIC}" --project="${PROJECT_ID}" --message="$(cat "${TMP_DIR}/event.json")" --attribute="source=governance-smoke-test,test_run_id=${RUN_ID}" --quiet >/dev/null
success "Published ${RUN_ID}."
log "Waiting up to ${WAIT_SECONDS}s for a fail-closed governance decision."

section "Poll governance decisions"
DEADLINE=$((SECONDS + WAIT_SECONDS))
while (( SECONDS < DEADLINE )); do
  gcloud pubsub subscriptions pull "${DECISION_SUBSCRIPTION}" --project="${PROJECT_ID}" --limit=20 --auto-ack --format=json > "${TMP_DIR}/pull.json"
  if python - "${TMP_DIR}/pull.json" "${RUN_ID}" <<'PY_CHECK'
import base64,json,sys
from pathlib import Path
items=json.loads(Path(sys.argv[1]).read_text() or "[]")
for item in items:
 message=item.get("message",item); raw=message.get("data",""); candidates=[raw]
 try:candidates.append(base64.b64decode(raw).decode())
 except Exception:pass
 for candidate in candidates:
  try:payload=json.loads(candidate)
  except Exception:continue
  if sys.argv[2] in json.dumps(payload,sort_keys=True):
   assert payload["decision"]=="REQUIRE_APPROVAL",payload
   assert payload["policy"]["approved"] is False,payload
   print(json.dumps(payload,indent=2,sort_keys=True)); raise SystemExit(0)
raise SystemExit(1)
PY_CHECK
  then
    success_section "Governance smoke test passed"
    log "No remediation was authorized."
    exit 0
  fi
  log "No matching decision yet; retrying in ${POLL_SECONDS}s."
  sleep "${POLL_SECONDS}"
done

die "Matching governance decision was not received for ${RUN_ID}."
