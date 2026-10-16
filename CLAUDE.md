# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A student portfolio lab: a governed multi-agent security-response pipeline on GKE. Despite "AWS" in the repo and directory names, everything targets Google Cloud (project `class-6-5-tiqs`, cluster `vertex-agent-lab`, `us-central1`). The infrastructure is normally torn down; `docs/RUNBOOK.md` is the authoritative step-by-step for provisioning, operating, and removing it.

## Commands

Run scripts from Git Bash on Windows (`*.sh` is forced to LF by `.gitattributes`). Scripts call `python`, not `python3`.

```bash
# Everything CI checks except the Trivy scan (needs python, terraform, opa, conftest)
./scripts/01-validate.sh

# Python unit tests
python -m pytest -q python/tests
python -m pytest -q python/tests/test_remediation_policy.py::test_executor_fails_closed_when_disabled

# OPA governance policy tests
opa test policy/governance -v
opa test policy/governance -v --run test_low_risk_high_confidence_action_is_permitted

# Conftest manifest policy (also asserts manifests/broken-app.yaml is rejected)
bash scripts/02-conftest-test.sh

# Terraform (no backend needed to validate)
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate
```

- `01-validate.sh` runs `terraform fmt -recursive` (it rewrites files) and `terraform init -upgrade`.
- There is no Python linter or formatter configured. The CI "Lint" job only parses `manifests/**/*.yaml` and runs `bash -n` on `scripts/*.sh`. The CI "Python" job also runs `python -m compileall -q python` before pytest.
- CI and every image use Python 3.14 (`python:3.14-slim`, Debian 13). The default `python` here is 3.15, so test with `py -3.14`. 3.15 has no wheels yet for the pinned `psycopg2-binary` and `PyYAML`. Images uninstall pip after installing requirements because pip's vendored packages fail the release Trivy gate. `python/requirements-test.txt` holds only pytest and PyYAML. Tests import the agent modules, so install the per-agent requirement files too; CI concatenates every `python/requirements-*.txt` except `app` and `scanner-publisher`.
- Scripts `03`–`15` act on the live GCP project and cluster (build/push, deploy, publish test events, sign approvals, teardown). Do not run them unless asked. `15-teardown.sh` requires `CONFIRM_TEARDOWN=yes`.

## Architecture

### Pipeline

Each stage is one Python module, one Dockerfile, and one manifest, connected only by Pub/Sub topics (defined in `terraform/08-pubsub.tf` and `terraform/14-agent-pubsub.tf`; the subscription and topic for each agent are set in its ConfigMap in `manifests/<agent>.yaml`).

| Stage | Module | Namespace | Publishes to |
|---|---|---|---|
| Event Aggregator | `aggregator.py` | `shared-services` | `security-findings` |
| Observer | `observer_agent.py` | `ai-agents` | `observed-findings` |
| Correlation (Firestore windows) | `correlation_agent.py` | `ai-agents` | `correlated-incidents` |
| IR Analyst (Vertex AI Gemini) | `ir_analyst_agent.py` | `ai-agents` | `analyzed-incidents` |
| Governance (OPA sidecar) | `governance_agent.py` | `ai-governance` | `governance-decisions`, plus `approval-requests` and `governance-audit` |
| Approval (KMS signature check) | `approval_agent.py` | `ai-governance` | `governance-decisions` |
| Remediation | `remediation_agent.py` | `ai-agents` | `remediation-results` |
| Reporting | `reporting_agent.py` | `ai-agents` | `incident-reports` |

The Remediation Agent never touches Kubernetes. It calls the nginx mTLS gateway (`mcp-gateway` namespace), which forwards to `mcp_server.py` (`mcp` namespace), which shells out to `kubectl` with RBAC scoped to `app01`. `mcp_server.py` trusts the `X-Client-Verify` / `X-Client-DN` headers set by nginx, so the NetworkPolicy restricting who can reach it is part of the trust boundary.

`aggregator.py` and `mcp_server.py` are standalone Flask apps. `scanner_publisher.py` runs in the Trivy/Prowler CronJobs and POSTs scanner output to the aggregator's `/ingest/<source>`. `app.py` is the demo workload (`broken-app`), the only remediation target.

### Shared agent runtime

The seven agents from Observer to Reporting are all `AgentRuntime(agent_name=..., processor=process).run()` from `python/agent_runtime.py`. The runtime owns the Pub/Sub subscription, the health server (`/healthz`, `/readyz`, `/status`, `/metrics` on `HEALTH_PORT`), structured JSON logging, and Prometheus metrics (`metrics_support.py`).

The contract for `process(payload, attributes, message_id)`:

- Return a list of event dicts. Each is published to `OUTPUT_TOPIC`, then the input is acked.
- Raise to nack. Pub/Sub redelivers and eventually dead-letters, so raise only for retryable or invalid input, and return a result event for terminal outcomes (the Remediation Agent returns `execution-blocked` rather than raising).
- Delivery is at-least-once. IDs come from `stable_id(prefix, *values)` (a SHA-256 of the inputs) so reprocessing yields the same IDs, and Firestore transactions make the side effects idempotent (`approval_requests`, `remediation_executions`).

Agents read required env vars and construct GCP clients at import time. `python/tests/conftest.py` therefore sets env defaults and replaces `google.cloud.pubsub_v1`, `firestore`, and `kms_v1` in `sys.modules` before any agent module is imported. Tests change behavior by monkeypatching module-level constants (for example `remediation_agent.EXECUTION_MODE`).

### Governance and approval flow

- `policy/governance/remediation.rego` (`data.agentic.governance.decision`) returns `PERMIT`, `DENY`, `REQUIRE_APPROVAL`, or `NO_ACTION`. Thresholds and allowlists are not in the Rego: `governance_agent.build_policy_input` passes them in `input` from env vars, and `remediation_test.rego` mirrors that shape in `base_input`.
- `REQUIRE_APPROVAL` writes a request to Firestore and publishes it to `approval-requests`. A human signs a decision envelope with Cloud KMS (`scripts/11-review-approval.sh`). The Approval Agent verifies the ECDSA signature over `canonical_json_bytes(envelope.signed_payload())`, checks the request hash and expiry against Firestore, and emits a new `GovernanceDecision` with `decision_source="kms-human-approval"`.
- Signing and hashing depend on `governance_common.canonical_json_bytes` (sorted keys, compact separators). The signing script must produce the same bytes.
- The Remediation Agent re-validates everything in `validate_governance_decision` before calling MCP, and the MCP Server validates again. These layers are intentionally redundant; do not collapse them.
- Fail-closed defaults are `AUTOMATION_MODE: disabled` (governance) and `EXECUTION_MODE: disabled` (remediation), with Slack and Jira off. Leave them that way in committed manifests unless explicitly asked.

## Things that must change together

- **Policy hash.** Governance and Remediation each SHA-256 their mounted copy of `remediation.rego` at startup, and Remediation blocks any decision whose `policy_sha256` differs from its own. `08-deploy.sh` creates the `governance-policy` ConfigMap from the same file in both `ai-governance` and `ai-agents`. After editing the Rego, both ConfigMaps must be re-applied and both Deployments restarted. The OPA sidecar version in `manifests/governance-agent.yaml` should track `OPA_VERSION` in `.github/workflows/ci.yml`.
- **Allowlists.** Target namespace/deployment are enforced separately in `governance-agent-config`, `remediation-agent-config`, `mcp-server-config`, and the MCP Server's Kubernetes RBAC. The `approval_source` values Remediation sends (`dgc-policy`, `kms-human-approval`) must be in `ALLOWED_APPROVAL_SOURCES` in `manifests/mcp-server-config.yaml`; the code default would reject them.
- **Images.** Dockerfiles live in `docker/` with no extension (`docker/mcp_docker.txt` is the MCP Server's) and build with `python/` as the context. Each one `COPY`s specific modules, so a new shared import needs a matching `COPY` line. Each image has its own pinned `python/requirements-<name>.txt`. The image list is repeated in `scripts/04-build-images.sh`, `scripts/13-release-images.sh`, and `scripts/14-deploy-release-images.sh`. `04` is the dev path. It pushes the mutable tag `${TAG:-v1}` (the tag the manifests reference). `.github/workflows/release.yml` (manual `workflow_dispatch`, `production` environment) is the governed path. It runs `13` to build, scan, generate an SBOM with Syft, and sign with Cosign, writes `release-evidence/image-lock.json`, and then optionally runs `14` to pin the Deployments to those digests.
- **kubectl in the MCP image.** `KUBECTL_VERSION` in `docker/mcp_docker.txt` must stay within one minor version of the GKE REGULAR-channel control plane, and its Go build must pass the release Trivy gate. Release-gate exceptions go in `.trivyignore-images.yaml` (path-scoped, with `expired_at`), not in `.trivyignore.yaml`, which only covers the CI repository scan.
- **IR Analyst model.** `MODEL` and `LOCATION` in `manifests/ir-analyst-agent.yaml` change together: Gemini 3.x Flash is only served from `global` (or the `us`/`eu` multi-regions), not `us-central1`. Check Vertex AI model retirement dates when the pipeline stalls at the IR Analyst.
- **Schemas.** `governance_models.py` is shared by the governance, approval, and remediation images only. `ir_analyst_agent.py` and the other agents define their own Pydantic models for the same payloads, so a schema change has to be mirrored on both sides of a topic.
- **Manifest policy.** `policy/conftest/kubernetes-security.rego` hardcodes the Artifact Registry prefix and an exact-tag allowlist for vendor images (nginx, postgres, Trivy, Prowler). Bumping one of those image tags in a manifest requires updating the allowlist. Every workload must set `runAsNonRoot`, `readOnlyRootFilesystem`, no privilege escalation, and resource requests and limits.
- **Project ID.** `class-6-5-tiqs` is hardcoded in most manifests, the Conftest policy, and several scripts, not only in Terraform variables.

## Intentional oddities

- `manifests/broken-app.yaml` is deliberately non-compliant. `02-conftest-test.sh` asserts that it fails, and the Trivy scan skips it and `examples/`. Do not "fix" it.
- `.gitignore` excludes `*.json` (except `package.json`), `*.tfvars`, and `.terraform.lock.hcl`. JSON fixtures will not be committed without a gitignore change.
- Terraform is one root module of numbered files with a GCS backend (`tiqs-kubernetes`). KMS key rings and the WIF pool survive `terraform destroy`; `scripts/03-adopt-retained-gcp.sh` imports them before the next apply and prints the ENABLED KMS key version to pin as `approval_key_version`.

## Windows / Git Bash

- Prefix commands that pass Linux paths with `MSYS_NO_PATHCONV=1`.
- `gcloud ... --format=value(...)` output has CRLF line endings; pipe through `tr -d '\r'` before looping.
- Unset `CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT` before using `kubectl`.
- The Unix `bq` wrapper needs `CLOUDSDK_PYTHON` set to a real interpreter. Do not run `bq.cmd query` from Git Bash.
- Do not write `<placeholder>` in shell commands; Git Bash treats it as redirection.
