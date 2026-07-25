#!/usr/bin/env bash
set -euo pipefail

DECISION="${1:-}"
REVIEWER="${2:-}"
REASON="${3:-}"
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
SUBSCRIPTION="${SUBSCRIPTION:-approval-requests-review-sub}"
OUTPUT_TOPIC="${OUTPUT_TOPIC:-approval-decisions}"
KMS_LOCATION="${KMS_LOCATION:-us-central1}"
KMS_KEYRING="${KMS_KEYRING:-agentic-governance}"
KMS_KEY="${KMS_KEY:-approval-signing}"
KMS_KEY_VERSION="${KMS_KEY_VERSION:-1}"
APPROVAL_TTL_SECONDS="${APPROVAL_TTL_SECONDS:-600}"

usage() {
  echo "Usage: $0 approve|deny REVIEWER 'reason with at least 10 characters'" >&2
  exit 2
}
[[ "${DECISION}" == "approve" || "${DECISION}" == "deny" ]] || usage
[[ -n "${REVIEWER}" && ${#REASON} -ge 10 ]] || usage
for command in gcloud python; do command -v "${command}" >/dev/null 2>&1 || { echo "ERROR: ${command} is required." >&2; exit 1; }; done
[[ -n "${PROJECT_ID}" && "${PROJECT_ID}" != "(unset)" ]] || { echo "ERROR: PROJECT_ID is not configured." >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

gcloud pubsub subscriptions pull "${SUBSCRIPTION}" \
  --project="${PROJECT_ID}" --limit=1 --format=json > "${TMP_DIR}/pull.json"

python - "${TMP_DIR}/pull.json" "${TMP_DIR}/request.json" "${TMP_DIR}/ack-id.txt" <<'PY_REQUEST'
import base64, json, sys
from pathlib import Path
items=json.loads(Path(sys.argv[1]).read_text() or "[]")
if not items: raise SystemExit("ERROR: no pending approval request was available")
item=items[0]; message=item.get("message", item); raw=message.get("data", "")
try: payload=json.loads(base64.b64decode(raw).decode("utf-8"))
except Exception: payload=json.loads(raw)
ack_id=item.get("ackId") or item.get("ack_id")
if not ack_id: raise SystemExit("ERROR: Pub/Sub response did not include an acknowledgement ID")
Path(sys.argv[2]).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
Path(sys.argv[3]).write_text(ack_id, encoding="utf-8")
print(json.dumps({"approval_request_id":payload.get("approval_request_id"),"incident_id":payload.get("incident_id"),"severity":payload.get("severity"),"expires_at":payload.get("expires_at"),"binding":payload.get("binding")},indent=2,sort_keys=True))
PY_REQUEST

read -r -p "Publish signed ${DECISION^^} decision for this request? [y/N] " CONFIRM
[[ "${CONFIRM}" =~ ^[Yy]$ ]] || { echo "Review cancelled; request was not acknowledged."; exit 1; }

KEY_VERSION_NAME="projects/${PROJECT_ID}/locations/${KMS_LOCATION}/keyRings/${KMS_KEYRING}/cryptoKeys/${KMS_KEY}/cryptoKeyVersions/${KMS_KEY_VERSION}"
python - "${TMP_DIR}/request.json" "${TMP_DIR}/unsigned.json" "${DECISION}" "${REVIEWER}" "${REASON}" "${KEY_VERSION_NAME}" "${APPROVAL_TTL_SECONDS}" <<'PY_ENVELOPE'
import json, sys, uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
request=json.loads(Path(sys.argv[1]).read_text()); now=datetime.now(timezone.utc)
request_expiry=datetime.fromisoformat(request["expires_at"].replace("Z", "+00:00"))
expiry=min(request_expiry, now+timedelta(seconds=int(sys.argv[7])))
payload={"schema_version":"1.0","event_type":"approval-decision","approval_id":str(uuid.uuid4()),"approval_request_id":request["approval_request_id"],"governance_decision_id":request["governance_decision_id"],"decision":"APPROVE" if sys.argv[3]=="approve" else "DENY","reviewer":sys.argv[4],"reason":sys.argv[5],"issued_at":now.isoformat().replace("+00:00","Z"),"expires_at":expiry.isoformat().replace("+00:00","Z"),"request_hash":request["request_hash"],"key_version":sys.argv[6]}
Path(sys.argv[2]).write_text(json.dumps(payload,sort_keys=True,separators=(",",":"),ensure_ascii=False),encoding="utf-8")
PY_ENVELOPE

gcloud kms asymmetric-sign \
  --project="${PROJECT_ID}" --location="${KMS_LOCATION}" \
  --keyring="${KMS_KEYRING}" --key="${KMS_KEY}" --version="${KMS_KEY_VERSION}" \
  --digest-algorithm=sha256 --input-file="${TMP_DIR}/unsigned.json" \
  --signature-file="${TMP_DIR}/signature.bin"

python - "${TMP_DIR}/unsigned.json" "${TMP_DIR}/signature.bin" "${TMP_DIR}/signed.json" <<'PY_SIGNATURE'
import base64,json,sys
from pathlib import Path
payload=json.loads(Path(sys.argv[1]).read_text()); payload["signature"]=base64.b64encode(Path(sys.argv[2]).read_bytes()).decode("ascii")
Path(sys.argv[3]).write_text(json.dumps(payload,sort_keys=True,separators=(",",":")),encoding="utf-8")
PY_SIGNATURE

gcloud pubsub topics publish "${OUTPUT_TOPIC}" --project="${PROJECT_ID}" \
  --message="$(cat "${TMP_DIR}/signed.json")" \
  --attribute="source=human-review,event_type=approval-decision" --quiet >/dev/null

gcloud pubsub subscriptions ack "${SUBSCRIPTION}" --project="${PROJECT_ID}" \
  --ack-ids="$(cat "${TMP_DIR}/ack-id.txt")"

echo "Signed approval decision published and request acknowledged."
