# **RUNBOOK — Agentic Security Platform on GKE**

This runbook provisions, validates, deploys, tests, operates, and removes the governed
multi-agent security platform.

The active architecture is:

```text
Telemetry
  → Event Aggregator
  → Observer Agent
  → Correlation Agent
  → IR Analyst Agent
  → Governance Agent + OPA
  → optional Cloud KMS-signed human approval
  → Remediation Agent
  → MCP Gateway over mTLS
  → MCP Server
  → app01
  → Reporting Agent
```

Automated remediation remains disabled unless both governance and execution modes are
explicitly changed to `controlled`.

---

## **1. Operating assumptions**

Default project configuration:

```text
Project:             class-6-5-tiqs
Region:              us-central1
Zone:                us-central1-c
GKE cluster:         vertex-agent-lab
GKE datapath:        Dataplane V2 (not Calico)
Node machine type:   e2-standard-4
Artifact Registry:   vertex-agent-lab
Image tag:           v1
Approval KMS version: 2
Terraform backend:   gs://tiqs-kubernetes/agentic/terraform/state
```

Google identities in this org:

```text
Cluster / Terraform admin:  a project Owner (may be a consumer Gmail account)
Approval signer / BQ:       a Workspace user in the org's allowed domain
                            (live: user:admin@tiqsapp.com)
Evidence dataset owner:     evidence-admin@class-6-5-tiqs.iam.gserviceaccount.com
```

`iam.allowedPolicyMemberDomains` blocks consumer Gmail accounts on the BigQuery dataset ACL and on the evidence-admin service account. Put a Workspace user in `approval_signer_members`. Use that Workspace user for BigQuery impersonation. Use the project Owner for `kubectl` cluster admin if the Workspace `gcloud` credential directory is locked.

Namespaces:

```text
app01
security
shared-services
ai-agents
ai-governance
mcp
mcp-gateway
```

The backend bucket must already exist before `terraform init`.

---

## **2. Prerequisites**

Required tools:

```text
Terraform >= 1.10.0
Google Cloud CLI
kubectl
Docker with Buildx
Python 3.11
Bash
OpenSSL
Helm
OPA
Conftest
Trivy
Syft
Cosign
```

Authenticate:

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project class-6-5-tiqs
gcloud auth list
gcloud config list project
```

Enable Docker authentication for Artifact Registry:

```bash
gcloud auth configure-docker us-central1-docker.pkg.dev --quiet
```

On Windows, verify that `gcloud`, `kubectl`, `docker`, `python`, and `openssl` are
available from the same shell used for the scripts. Git Bash plus the Cloud SDK has
several traps documented in [Windows Git Bash](#windows-git-bash). Pin
`CLOUDSDK_PYTHON` to a real interpreter such as `/c/Python312/python.exe` if the Unix
`bq` wrapper fails with `python3.14: command not found`.

---

## **3. Prepare local configuration**

Create the ignored local variables file:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Update:

```hcl
authorized_networks = [
  {
    cidr_block   = "YOUR_CURRENT_PUBLIC_IP/32"
    display_name = "administrator-workstation"
  }
]

zone = "us-central1-c"

approval_signer_members = [
  "user:YOUR_WORKSPACE_ACCOUNT",
]

approval_key_version = "2"
```

`approval_signer_members` must be an org-permitted Workspace identity, not a
consumer Gmail account. KMS key version `1` was destroyed on this project; the live
signing version is `2`.

Do not commit:

```text
terraform/terraform.tfvars
terraform/.terraform/
Terraform state
private keys
certificate files
gha-creds-*.json
release-evidence/
```

Confirm the repository does not contain generated Terraform data:

```bash
find . \
  \( -path '*/.terraform/*' -o -name 'terraform.tfvars' \) \
  -print
```

The local `terraform.tfvars` will appear after you create it; it must remain ignored.

---

## **4. Validate before provisioning**

Scripts are numbered in run order (`01` through `15`). `15-teardown.sh` is last.

```text
01-validate.sh
02-conftest-test.sh
03-adopt-retained-gcp.sh
04-build-images.sh
05-install-falco.sh
06-create-demo-secret.sh
07-generate-mcp-mtls.sh
08-deploy.sh
09-test-governance.sh
10-test-pipeline.sh
11-review-approval.sh
12-smoke-test-metrics.sh
13-release-images.sh
14-deploy-release-images.sh
15-teardown.sh
```

Make scripts executable:

```bash
chmod +x scripts/*.sh
```

Run the complete validation suite:

```bash
./scripts/01-validate.sh
```

The script performs:

```text
Python compilation
Python unit tests
Kubernetes and workflow YAML parsing
Bash syntax checks
OPA governance policy tests
Terraform formatting and validation
Conftest Kubernetes policy checks
generated-file checks
workflow compatibility-reference checks
```

Manual equivalents:

```bash
python -m compileall -q python
pytest -q python/tests

opa test policy/governance -v

terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate

conftest test \
  manifests/event-aggregator.yaml \
  manifests/observer-agent.yaml \
  manifests/correlation-agent.yaml \
  manifests/ir-analyst-agent.yaml \
  manifests/governance-agent.yaml \
  manifests/approval-agent.yaml \
  manifests/remediation-agent.yaml \
  manifests/reporting-agent.yaml \
  manifests/mcp-deployment.yaml \
  --policy policy/conftest \
  --all-namespaces
```

---

## **5. Provision Google Cloud infrastructure**

Initialize the real GCS backend:

```bash
terraform -chdir=terraform init
```

Format and validate:

```bash
terraform -chdir=terraform fmt -recursive
terraform -chdir=terraform validate
```

Create a reviewed plan:

```bash
terraform -chdir=terraform plan -out=agentic.tfplan
terraform -chdir=terraform show agentic.tfplan
```

If apply fails because a custom IAM role is deletion-pending, a Workload Identity pool or KMS key ring already exists, or the GKE node pool is in `ERROR`, adopt the leftovers and retry:

```bash
./scripts/03-adopt-retained-gcp.sh
terraform -chdir=terraform plan -out=agentic.tfplan
terraform -chdir=terraform apply agentic.tfplan
```

Terraform files are numbered in apply-oriented order (`01` through `25`). Destroy-sensitive leftovers (WIF, KMS, BigQuery evidence) sit at the end, then outputs:

```text
01-variables.tf
02-provider.tf
03-network.tf
04-artifact-registry.tf
05-gke.tf
06-node-pool.tf
07-runtime.tf
08-pubsub.tf
09-ir-analyst-agent-iam.tf
10-mcp-server-iam.tf
11-telemetry-agent-iam.tf
12-multi-agent-iam.tf
13-observer-agent-iam.tf
14-agent-pubsub.tf
15-logging-sink.tf
16-security-command-center.tf
17-firestore.tf
18-reporting-secrets.tf
19-github-actions-wif.tf
20-observability.tf
21-governance-iam.tf
22-kms.tf
23-firestore-ttl.tf
24-evidence.tf
25-outputs.tf
```

Important Terraform-managed components include:

```text
VPC and subnet
VPC-native zonal GKE cluster
dedicated GKE node pool
Workload Identity
Artifact Registry
Pub/Sub topics, subscriptions, retries, and dead-letter topics
agent Google service accounts and IAM
Cloud Logging telemetry sink
optional Security Command Center notification
Firestore correlation, approval, and execution state
Secret Manager containers for optional reporting
GitHub Actions Workload Identity Federation
Managed Service for Prometheus
Cloud Monitoring dashboard and alert policies
Cloud KMS approval-signing key
BigQuery governance evidence dataset
```

Review outputs:

```bash
terraform -chdir=terraform output
```

Obtain cluster credentials:

```bash
gcloud container clusters get-credentials vertex-agent-lab \
  --zone us-central1-c \
  --project class-6-5-tiqs
```

Verify:

```bash
kubectl cluster-info
kubectl get nodes -o wide
```

If the connection times out, update the workstation CIDR in
`terraform/terraform.tfvars` and reapply Terraform.

---

## **6. Configure GitHub Actions**

Obtain the Terraform-created identities:

```bash
terraform -chdir=terraform output -raw \
  github_actions_workload_identity_provider

terraform -chdir=terraform output -raw \
  github_release_service_account
```

Create these GitHub repository variables with `gh` (do not paste the YAML workflow files into the shell, and do not paste the `<terraform output>` placeholders as bash):

```bash
gh variable set GCP_PROJECT_ID --body class-6-5-tiqs
gh variable set GCP_WIF_PROVIDER --body "$(terraform -chdir=terraform output -raw github_actions_workload_identity_provider)"
gh variable set GCP_RELEASE_SERVICE_ACCOUNT --body "$(terraform -chdir=terraform output -raw github_release_service_account)"
gh variable set GKE_CLUSTER_NAME --body vertex-agent-lab
gh variable set GKE_CLUSTER_LOCATION --body us-central1-c
```

`GKE_CLUSTER_LOCATION` must match the live cluster zone (`terraform output gke_cluster_info`). This lab moved to `us-central1-c` after `n2-standard-2` was exhausted in `us-central1-b`.

Create a GitHub environment named `production`:

```bash
gh api --method PUT repos/tiqsclass6/aws-kubernetes-agentic-ai/environments/production
```

In the GitHub UI, require a reviewer before that environment can deploy.

CI runs on push and pull request. Dispatch the release workflow from GitHub; it is not a local script:

```bash
gh workflow run release.yml -f tag=v1 -f deploy=false
```

Active workflow files (GitHub-hosted only):

```text
.github/workflows/ci.yml
.github/workflows/release.yml
```

The release workflow is manually dispatched and defaults to build-only.
Set `deploy=true` only when the release evidence and target environment have been
reviewed.

### **VS Code resolver warning**

The workflow files use the project compatibility references:

```yaml
actions/checkout@v5
actions/setup-python@v6
hashicorp/setup-terraform@v4
github/codeql-action/upload-sarif@v4
actions/upload-artifact@v7
google-github-actions/auth@v3
google-github-actions/setup-gcloud@v3
docker/setup-buildx-action@v4
sigstore/cosign-installer@v4.1.2
```

If VS Code reports that all of them are unresolved, inspect:

```text
View → Output → GitHub Actions
```

Common causes:

```text
expired GitHub authentication
GitHub API rate limiting
proxy or VPN interference
DNS failure
TLS inspection
blocked api.github.com access
stale extension cache
```

Do not continue changing action versions when every repository fails resolution. Validate
with `actionlint` or an actual GitHub-hosted workflow run.

---

## **7. Build and push container images**

The local build script requires Docker and `gcloud`.

```bash
PROJECT_ID=class-6-5-tiqs \
REGION=us-central1 \
REPOSITORY=vertex-agent-lab \
TAG=v1 \
./scripts/04-build-images.sh
```

Images:

```text
event-aggregator
observer-agent
correlation-agent
ir-analyst-agent
governance-agent
approval-agent
remediation-agent
reporting-agent
mcp-server
scanner-publisher
app
```

There is no `vertex-agent` image in this lab. Scanner CronJobs and `broken-app` must
reference `v1` tags that actually exist in Artifact Registry.

Verify:

```bash
gcloud artifacts docker images list \
  us-central1-docker.pkg.dev/class-6-5-tiqs/vertex-agent-lab \
  --include-tags
```

---

## **8. Install Falco**

```bash
./scripts/05-install-falco.sh
```

Verify:

```bash
helm list -A
kubectl get pods -A | grep -i falco
```

Falco is a runtime telemetry source. Trivy and Prowler run as scheduled scanner workloads
in the `security` namespace after deployment.

---

## **9. Deploy the platform**

Run the canonical deployment script:

```bash
./scripts/08-deploy.sh
```

The script performs these operations in order:

1. Apply `manifests/namespaces.yaml`.
2. Create the OPA governance-policy ConfigMaps.
3. Generate the PostgreSQL demo Secret.
4. Generate or rotate MCP mTLS material.
5. Apply Kubernetes identities and RBAC.
6. Deploy the MCP gateway and MCP Server.
7. Deploy PostgreSQL and the demo application.
8. Deploy all pipeline and governance agents.
9. Wait for every Deployment to become ready.
10. Apply NetworkPolicies.
11. Apply PodMonitoring objects.
12. Apply HPAs and PDBs.
13. Apply Trivy and Prowler CronJobs.

Expected final message:

```text
Platform deployed. Automated remediation remains disabled by default.
```

### **Manual secret creation**

The deployment script calls this automatically:

```bash
./scripts/06-create-demo-secret.sh
```

To supply a specific password without committing it:

```bash
POSTGRES_PASSWORD='replace-at-runtime' \
./scripts/06-create-demo-secret.sh
```

The repository contains only:

```text
manifests/postgres-secret.example.yaml
```

Do not apply the example with its placeholder value.

`06-create-demo-secret.sh` leaves an existing `postgres-credentials` Secret unchanged.
Postgres reads that password only when it first initializes PGDATA. Rotating the Secret
on a running emptyDir volume does not change the database password; delete the postgres
pod so it re-inits, or keep the original Secret.

After NetworkPolicies are applied, pod DNS must reach both kube-dns and NodeLocal
DNSCache. Dataplane V2 policies therefore allow kube-dns and node-local-dns in
`kube-system`, ClusterIP `10.112.0.10/32`, and `169.254.20.10/32`. Allowing only the
kube-dns ClusterIP produces `Temporary failure in name resolution`.

---

## **10. Verify workloads**

Namespaces:

```bash
kubectl get namespace \
  app01 \
  security \
  shared-services \
  ai-agents \
  ai-governance \
  mcp \
  mcp-gateway
```

Deployments:

```bash
kubectl get deployments -A
kubectl get pods -A -o wide
```

Expected long-running Deployments:

```text
app01/postgres
app01/broken-app
shared-services/event-aggregator
ai-agents/observer-agent
ai-agents/correlation-agent
ai-agents/ir-analyst-agent
ai-agents/remediation-agent
ai-agents/reporting-agent
ai-governance/governance-agent
ai-governance/approval-agent
mcp/mcp-server
mcp-gateway/mcp-gateway
```

Verify rollout status:

```bash
kubectl rollout status deployment/postgres \
  -n app01 \
  --timeout=300s

kubectl rollout status deployment/broken-app \
  -n app01 \
  --timeout=300s

kubectl rollout status deployment/event-aggregator \
  -n shared-services \
  --timeout=300s

kubectl rollout status deployment/mcp-gateway \
  -n mcp-gateway \
  --timeout=300s

kubectl rollout status deployment/mcp-server \
  -n mcp \
  --timeout=300s
```

Agent logs:

```bash
kubectl logs -n shared-services deployment/event-aggregator --tail=100

kubectl logs -n ai-agents deployment/observer-agent --tail=100
kubectl logs -n ai-agents deployment/correlation-agent --tail=100
kubectl logs -n ai-agents deployment/ir-analyst-agent --tail=100
kubectl logs -n ai-agents deployment/remediation-agent --tail=100
kubectl logs -n ai-agents deployment/reporting-agent --tail=100

kubectl logs -n ai-governance deployment/governance-agent --tail=100
kubectl logs -n ai-governance deployment/approval-agent --tail=100

kubectl logs -n mcp deployment/mcp-server --tail=100
kubectl logs -n mcp-gateway deployment/mcp-gateway --tail=100
```

Demo application:

```bash
kubectl logs -n app01 deployment/broken-app --tail=100
kubectl get service -n app01
```

---

## **11. Verify security boundaries**

### **NetworkPolicies**

```bash
kubectl get networkpolicy -A
```

Important paths:

```text
broken-app → postgres:5432
agents → DNS and required Google APIs
Remediation Agent → MCP gateway:8443
MCP gateway → MCP Server
MCP Server → Kubernetes API
Managed Prometheus collectors → agent metric ports
scanner workloads → Artifact Registry, Trivy DB, Prowler APIs, and DNS
  (kube-dns, node-local-dns, 10.112.0.10/32, 169.254.20.10/32)
```

### **MCP certificate material**

```bash
kubectl get secret -n mcp-gateway \
  mcp-gateway-server-tls \
  mcp-client-ca

kubectl get secret -n ai-agents \
  remediation-agent-client-tls \
  mcp-gateway-server-ca
```

Only the Remediation Agent should have the MCP client identity.

Rotate certificates:

```bash
./scripts/07-generate-mcp-mtls.sh
```

Then restart affected workloads:

```bash
kubectl rollout restart deployment/mcp-gateway -n mcp-gateway
kubectl rollout restart deployment/mcp-server -n mcp
kubectl rollout restart deployment/remediation-agent -n ai-agents
```

### **Kubernetes RBAC**

```bash
kubectl auth can-i get pods \
  -n app01 \
  --as=system:serviceaccount:mcp:mcp-server-sa

kubectl auth can-i get pods/log \
  -n app01 \
  --as=system:serviceaccount:mcp:mcp-server-sa

kubectl auth can-i patch deployments \
  -n app01 \
  --as=system:serviceaccount:mcp:mcp-server-sa

kubectl auth can-i patch deployments \
  -n kube-system \
  --as=system:serviceaccount:mcp:mcp-server-sa
```

The final command should return `no`.

---

## **12. Verify Pub/Sub resources**

Topics:

```bash
gcloud pubsub topics list \
  --project=class-6-5-tiqs \
  --filter='name:(raw-security-events security-findings observed-findings correlated-incidents analyzed-incidents governance-decisions approval-requests approval-decisions governance-audit remediation-results incident-reports agent-events-dlq)'
```

Subscriptions:

```bash
gcloud pubsub subscriptions list \
  --project=class-6-5-tiqs \
  --filter='name:(observer-agent-sub correlation-agent-sub ir-analyst-agent-sub governance-agent-sub approval-agent-sub remediation-agent-sub reporting-agent-sub approval-requests-review-sub governance-decisions-debug-sub governance-audit-debug-sub incident-reports-debug-sub agent-events-dlq-sub)'
```

Inspect dead-letter messages:

```bash
gcloud pubsub subscriptions pull agent-events-dlq-sub \
  --project=class-6-5-tiqs \
  --limit=20 \
  --auto-ack \
  --format=json
```

---

## **13. Run governance validation**

Run the deterministic governance smoke test:

```bash
./scripts/09-test-governance.sh
```

The synthetic event recommends restarting `app01/broken-app`, but default automation is
disabled. Expected result:

```text
decision = REQUIRE_APPROVAL
policy.approved = false
no remediation authorized
```

Failure checks:

```bash
kubectl logs -n ai-governance deployment/governance-agent --tail=200
kubectl logs -n ai-governance deployment/approval-agent --tail=200

gcloud pubsub subscriptions pull governance-decisions-debug-sub \
  --project=class-6-5-tiqs \
  --limit=20 \
  --auto-ack \
  --format=json
```

---

## **14. Run the end-to-end governed pipeline test**

```bash
./scripts/10-test-pipeline.sh
```

The script publishes two correlated findings to `security-findings` and waits for a final
report on `incident-reports-debug-sub`.

Pipeline:

```text
security-findings
  → Observer
  → Correlation
  → IR Analyst
  → Governance
  → Remediation result
  → Reporting
```

Because automated execution is disabled, the test validates the complete event path
without requiring a Kubernetes restart.

Troubleshoot:

```bash
kubectl logs -n ai-agents deployment/observer-agent --tail=200
kubectl logs -n ai-agents deployment/correlation-agent --tail=200
kubectl logs -n ai-agents deployment/ir-analyst-agent --tail=200
kubectl logs -n ai-governance deployment/governance-agent --tail=200
kubectl logs -n ai-agents deployment/remediation-agent --tail=200
kubectl logs -n ai-agents deployment/reporting-agent --tail=200
```

---

## **15. Review and sign a human approval**

List pending requests without acknowledging them:

```bash
gcloud pubsub subscriptions pull approval-requests-review-sub \
  --project=class-6-5-tiqs \
  --limit=5 \
  --format=json
```

Approve the next request:

```bash
./scripts/11-review-approval.sh \
  approve \
  "analyst@example.com" \
  "Approved after validating the incident evidence and proposed target."
```

Deny the next request:

```bash
./scripts/11-review-approval.sh \
  deny \
  "analyst@example.com" \
  "Denied because the requested action needs additional investigation."
```

Required reason length is at least 10 characters.

The script:

1. pulls one request from `approval-requests-review-sub`;
2. parses and displays its binding;
3. asks for interactive confirmation;
4. creates a decision with a short expiration;
5. signs the canonical decision document with Cloud KMS;
6. publishes to `approval-decisions`;
7. acknowledges the original request after successful publication.

Default signing configuration:

```text
Location:       us-central1
Key ring:       agentic-governance
Key:            approval-signing
Key version:    2
Decision TTL:   600 seconds
```

`scripts/11-review-approval.sh` and `manifests/approval-agent.yaml` default to version
`2`. Version `1` is DESTROYED on this project and cannot sign.

Override with environment variables when necessary:

```bash
PROJECT_ID=class-6-5-tiqs \
KMS_LOCATION=us-central1 \
KMS_KEYRING=agentic-governance \
KMS_KEY=approval-signing \
KMS_KEY_VERSION=2 \
APPROVAL_TTL_SECONDS=600 \
./scripts/11-review-approval.sh \
  approve \
  "analyst@example.com" \
  "Approved after reviewing the correlated security evidence."
```

---

## **16. Enable controlled remediation**

Do not enable execution before:

```text
OPA tests pass
governance smoke test passes
approval signature validation passes
mTLS trust is verified
MCP RBAC is verified
allowlists are correct
BigQuery evidence is visible
rollback procedure is tested
```

Edit `manifests/governance-agent.yaml`:

```yaml
AUTOMATION_MODE: controlled
```

Edit `manifests/remediation-agent.yaml`:

```yaml
EXECUTION_MODE: controlled
```

Apply:

```bash
kubectl apply -f manifests/governance-agent.yaml
kubectl apply -f manifests/remediation-agent.yaml

kubectl rollout restart deployment/governance-agent -n ai-governance
kubectl rollout restart deployment/remediation-agent -n ai-agents

kubectl rollout status deployment/governance-agent \
  -n ai-governance \
  --timeout=300s

kubectl rollout status deployment/remediation-agent \
  -n ai-agents \
  --timeout=300s
```

Verify current values:

```bash
kubectl get configmap governance-agent-config \
  -n ai-governance \
  -o jsonpath='{.data.AUTOMATION_MODE}{"\n"}'

kubectl get configmap remediation-agent-config \
  -n ai-agents \
  -o jsonpath='{.data.EXECUTION_MODE}{"\n"}'
```

The control-plane still rejects requests that fail deterministic policy, approval,
allowlist, idempotency, MCP, mTLS, or RBAC checks.

---

## **17. Metrics and operational readiness**

PodMonitoring:

```bash
kubectl get podmonitoring -A
```

HPA and PDB:

```bash
kubectl get hpa -A
kubectl get pdb -A
```

Run the metrics smoke test:

```bash
./scripts/12-smoke-test-metrics.sh
```

Representative metrics:

```text
agent_ready
agent_inflight_messages
agent_last_success_unixtime
agent_messages_received_total
agent_messages_processed_total
agent_messages_failed_total
agent_events_published_total
agent_message_processing_seconds
agent_pubsub_publish_seconds
agent_processing_exceptions_total
```

Review Cloud Monitoring:

```bash
terraform -chdir=terraform output -raw monitoring_dashboard_id
```

Check Pub/Sub backlog:

```bash
gcloud pubsub subscriptions list \
  --project=class-6-5-tiqs \
  --format='table(name,ackDeadlineSeconds,messageRetentionDuration)'
```

---

## **18. Scanner operations**

CronJobs:

```bash
kubectl get cronjob -n security
kubectl describe cronjob trivy-image-scan -n security
kubectl describe cronjob prowler-gcp-scan -n security
```

Create one-time Jobs from the schedules:

```bash
kubectl create job \
  --from=cronjob/trivy-image-scan \
  trivy-manual-$(date +%s) \
  -n security

kubectl create job \
  --from=cronjob/prowler-gcp-scan \
  prowler-manual-$(date +%s) \
  -n security
```

Inspect. Copy the job name from `kubectl get jobs` — do not wrap it in angle brackets (`<id>`). Git Bash treats `<file>` as redirection and will look for a file named `id`.

```bash
kubectl get jobs -n security

TRIVY_JOB=$(kubectl get jobs -n security -o name | grep trivy-manual | tail -1)
PROWLER_JOB=$(kubectl get jobs -n security -o name | grep prowler-manual | tail -1)

kubectl logs -n security "${TRIVY_JOB}" --all-containers=true
kubectl logs -n security "${PROWLER_JOB}" --all-containers=true
```

Trivy `TARGET_IMAGES` are the live `v1` tags:

```text
app
mcp-server
event-aggregator
scanner-publisher
```

A `MANIFEST_UNKNOWN` error means the CronJob still points at a missing tag such as
`vertex-agent:phase1-v1`. Docker/containerd socket messages in Trivy logs are expected;
the Job has no local runtime and scans the remote registry.

Prowler `5.35.0` is not on `PATH` when the CronJob overrides the image entrypoint. The
Job calls `/home/prowler/.venv/bin/prowler`. `/bin/sh: prowler: not found` means the
manifest was not re-applied after that fix.

Re-apply CronJobs after changing either manifest, then create new one-off Jobs. Existing
Jobs keep the old spec.

---

## **19. Optional Slack reporting**

Terraform creates the Secret Manager container, not the secret version.

Add the webhook:

```bash
printf '%s' "${SLACK_WEBHOOK_URL}" \
  | gcloud secrets versions add security-slack-webhook-url \
      --project=class-6-5-tiqs \
      --data-file=-
```

Set in `manifests/reporting-agent.yaml`:

```yaml
ENABLE_SLACK: "true"
```

Apply and restart:

```bash
kubectl apply -f manifests/reporting-agent.yaml
kubectl rollout restart deployment/reporting-agent -n ai-agents
kubectl rollout status deployment/reporting-agent \
  -n ai-agents \
  --timeout=300s
```

---

## **20. Optional Jira reporting**

Add the API token:

```bash
printf '%s' "${JIRA_API_TOKEN}" \
  | gcloud secrets versions add security-jira-api-token \
      --project=class-6-5-tiqs \
      --data-file=-
```

Set in `manifests/reporting-agent.yaml`:

```yaml
ENABLE_JIRA: "true"
JIRA_BASE_URL: https://your-domain.atlassian.net
JIRA_EMAIL: analyst@example.com
JIRA_PROJECT_KEY: SEC
JIRA_ISSUE_TYPE: Task
```

Apply and restart the Reporting Agent.

---

## **21. BigQuery governance evidence**

The dataset `agentic_governance_evidence` exists, but its ACL is only
`evidence-admin`. Project Owner is not enough to list tables. A consumer Gmail
account cannot be added to that ACL or as Token Creator on the SA
(`iam.allowedPolicyMemberDomains`).

Grant Token Creator to the Workspace signer, then impersonate. Stay on the Workspace
account for this section:

```bash
gcloud iam service-accounts add-iam-policy-binding \
  evidence-admin@class-6-5-tiqs.iam.gserviceaccount.com \
  --project=class-6-5-tiqs \
  --member="user:YOUR_WORKSPACE_ACCOUNT" \
  --role="roles/iam.serviceAccountTokenCreator"

gcloud auth login YOUR_WORKSPACE_ACCOUNT
```

On Git Bash, pin Python and impersonate. Use the Unix `bq` wrapper for SQL. `bq.cmd ls`
is fine; `bq.cmd query` splits on `C:\Program Files`.

```bash
export CLOUDSDK_PYTHON="/c/Python312/python.exe"
export CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT=evidence-admin@class-6-5-tiqs.iam.gserviceaccount.com

bq ls --project_id=class-6-5-tiqs
terraform -chdir=terraform output -raw evidence_dataset
bq ls class-6-5-tiqs:agentic_governance_evidence
```

IAM Token Creator can take a minute to propagate. If impersonation is denied immediately
after the binding, wait and retry
`gcloud auth print-access-token --impersonate-service-account=evidence-admin@class-6-5-tiqs.iam.gserviceaccount.com >/dev/null`.

Logging sink tables are dated, for example `stdout_20260818` and `export_errors_20260818`.

```bash
bq query --nouse_legacy_sql --max_rows=20 \
'SELECT timestamp, jsonPayload.component, jsonPayload.incident_id, jsonPayload.governance_decision_id, jsonPayload.action, jsonPayload.result FROM `class-6-5-tiqs.agentic_governance_evidence.stdout_20260818` WHERE jsonPayload.component IS NOT NULL ORDER BY timestamp DESC LIMIT 20'
```

If `stdout_*` is empty, inspect `export_errors_*`. The same records are also in Cloud
Logging without impersonation:

```bash
gcloud logging read \
  'resource.type="k8s_container" AND (jsonPayload.component="governance-agent" OR jsonPayload.component="approval-agent" OR jsonPayload.component="remediation-agent" OR jsonPayload.component="mcp-server")' \
  --project=class-6-5-tiqs \
  --limit=20 \
  --format='table(timestamp, jsonPayload.component, jsonPayload.incident_id, jsonPayload.action, jsonPayload.result)'
```

Unset impersonation before `kubectl` or Terraform:

```bash
unset CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT
gcloud config unset auth/impersonate_service_account
```

Confirm that governance, approval, remediation, and MCP records contain consistent:

```text
incident_id
governance_decision_id
approval_request_id
request_hash
policy_id
policy_sha256
reviewer
key_version
action
target namespace
target deployment
result
timestamp
```

---

## **22. Key rotation and certificate rotation**

### **Cloud KMS approval key**

Create a new key version:

```bash
gcloud kms keys versions create \
  --project=class-6-5-tiqs \
  --location=us-central1 \
  --keyring=agentic-governance \
  --key=approval-signing
```

Update:

```hcl
approval_key_version = "NEW_VERSION"
```

Apply Terraform, update the agent configuration if required, redeploy, and validate signed
approval verification before disabling the prior version.

### **MCP certificates**

```bash
./scripts/07-generate-mcp-mtls.sh

kubectl rollout restart deployment/mcp-gateway -n mcp-gateway
kubectl rollout restart deployment/mcp-server -n mcp
kubectl rollout restart deployment/remediation-agent -n ai-agents
```

---

## **23. Troubleshooting**

### **Terraform apply: 409 already exists, custom role deletion-pending, or node pool ERROR**

These are leftovers from a previous destroy or a partial apply. They are not random GCP outages.

| Error | Why | Fix |
| --- | --- | --- |
| custom role `role_id` marked for deletion | Role IDs stay reserved ~7 days | Code uses `prowlerStorageIamViewerV2` |
| Workload Identity pool 409 | Pools are soft-deleted 30 days | `./scripts/03-adopt-retained-gcp.sh` imports `github-actions` |
| KMS key ring or crypto key 409 | Key rings/keys cannot be fully deleted | Same script imports `agentic-governance` / `approval-signing` |
| BigQuery `allowedPolicyMemberDomains` | Default dataset ACL includes consumer Google accounts | Dataset OWNER is only `evidence-admin`; impersonate that SA from a Workspace user |
| KMS key version DESTROYED | Destroyed versions cannot sign | Use version `2` in tfvars, the approval agent ConfigMap, and `11-review-approval.sh` |
| Node pool `ERROR` | Calico cannot be combined with current REGULAR-channel GKE | Cluster uses Dataplane V2; script deletes the ERROR pool |

```bash
./scripts/03-adopt-retained-gcp.sh
terraform -chdir=terraform plan -out=agentic.tfplan
terraform -chdir=terraform apply agentic.tfplan
```

Switching an existing cluster from Calico to Dataplane V2 recreates the cluster.

### **Node pool stuck in PROVISIONING (`ZONE_RESOURCE_POOL_EXHAUSTED`)**

The VM is not coming up. GCE has no capacity for that machine type in that zone (live: `n2-standard-2` in `us-central1-b`). Terraform will sit on `Still creating...` until the create timeout.

Let the current apply fail or cancel it, then recreate the pool on `e2-standard-4` (the Terraform default):

```bash
gcloud container node-pools delete vertex-agent-lab-nodes \
  --cluster=vertex-agent-lab \
  --zone=us-central1-b \
  --project=class-6-5-tiqs \
  --quiet

terraform -chdir=terraform state rm google_container_node_pool.primary || true
terraform -chdir=terraform plan -out=agentic.tfplan
terraform -chdir=terraform apply agentic.tfplan
```

If `e2-standard-4` is also exhausted, set `zone` to another `us-central1-*` zone in `terraform.tfvars` and replace the cluster. The live lab cluster is in `us-central1-c`.

### **Windows Git Bash**

Do not paste workflow YAML, `<terraform output>`, or `<id>` into Git Bash. Angle brackets are redirection (`bash: id: No such file or directory`). `.github/workflows/*.yml` files run on GitHub, not locally.

`gcloud artifacts packages list --format=value(name)` emits CRLF. Strip `\r` before `packages delete` or the API looks up `app\r`.

The Unix `bq` wrapper looks for `python3.14` on `PATH`. Windows has `python.exe`, not that name. Pin Python or use `bq.cmd` only for short commands such as `ls`:

```bash
export CLOUDSDK_PYTHON="/c/Python312/python.exe"
bq ls --project_id=class-6-5-tiqs
```

Do not run `bq.cmd query` from Git Bash. It breaks on `C:\Program Files`. Use `bq query` with `CLOUDSDK_PYTHON` set and keep the SQL on one line.

Leave `CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT` unset except for BigQuery. If `kubectl` still authenticates as `evidence-admin`:

```bash
unset CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT
gcloud config unset auth/impersonate_service_account
rm -f "$HOME/.kube/gke_gcloud_auth_plugin_cache"
```

If `gke-gcloud-auth-plugin` then fails with permission denied on
`%APPDATA%\gcloud\legacy_credentials\admin@tiqsapp.com\adc.json`, that folder has a
broken NTFS ACL. Switch `gcloud config set account` to the Gmail project Owner for
cluster admin, or take ownership of that directory in elevated PowerShell and
`gcloud auth login --force`.

Two Cloud SDK installs (`Program Files (x86)` and Chocolatey) can disagree on config.
`gcloud config list` from the same shell you use for `kubectl`.

### **`kubectl` cannot reach GKE**

Check the current public IP and update `authorized_networks`:

```powershell
(Invoke-WebRequest -UseBasicParsing https://api.ipify.org).Content
```

Reapply Terraform:

```bash
terraform -chdir=terraform plan -out=agentic.tfplan
terraform -chdir=terraform apply agentic.tfplan
```

### **Workload Identity authorization failure**

Inspect the Kubernetes service account annotation:

```bash
kubectl get serviceaccount SERVICE_ACCOUNT \
  -n NAMESPACE \
  -o yaml
```

Inspect the mapped Google service account and IAM binding:

```bash
gcloud iam service-accounts get-iam-policy \
  GOOGLE_SERVICE_ACCOUNT_EMAIL \
  --project=class-6-5-tiqs
```

### **Pub/Sub messages stop moving**

```bash
gcloud pubsub subscriptions pull agent-events-dlq-sub \
  --project=class-6-5-tiqs \
  --limit=20 \
  --auto-ack \
  --format=json
```

Check the consumer Deployment logs and its subscription IAM role.

### **Governance Agent cannot evaluate policy**

```bash
kubectl get configmap governance-policy \
  -n ai-governance \
  -o yaml

kubectl logs -n ai-governance deployment/governance-agent --tail=200
```

Recreate policy ConfigMaps:

```bash
for namespace in ai-governance ai-agents; do
  kubectl -n "${namespace}" create configmap governance-policy \
    --from-file=remediation.rego=policy/governance/remediation.rego \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -
done
```

### **Approval signature rejected**

Confirm:

```text
exact KMS key version
request hash
governance decision ID
approval request ID
decision expiry
reviewer IAM access
canonical JSON serialization
KMS key version is ENABLED (live lab uses version 2; version 1 is DESTROYED)
```

Inspect:

```bash
kubectl logs -n ai-governance deployment/approval-agent --tail=200
```

### **MCP gateway returns TLS errors**

```bash
kubectl get secret -n mcp-gateway mcp-gateway-server-tls mcp-client-ca
kubectl get secret -n ai-agents remediation-agent-client-tls mcp-gateway-server-ca
kubectl logs -n mcp-gateway deployment/mcp-gateway --tail=200
```

Rotate certificates with `scripts/07-generate-mcp-mtls.sh`.

### **ImagePullBackOff**

```bash
kubectl describe pod POD_NAME -n NAMESPACE
gcloud artifacts docker images list \
  us-central1-docker.pkg.dev/class-6-5-tiqs/vertex-agent-lab \
  --include-tags
```

container images are tagged `v1`. `broken-app` uses `app:v1`. Trivy and
Prowler publisher sidecars use `scanner-publisher:v1`. There is no
`vertex-agent:phase1-v1` image.

### **Postgres `password authentication failed` or empty DB password**

The Secret was rotated after Postgres already initialized PGDATA. Restore the original
Secret or delete the postgres pod so emptyDir re-inits.

### **`Temporary failure in name resolution` after NetworkPolicies**

Allow kube-dns, node-local-dns, `10.112.0.10/32`, and `169.254.20.10/32`. ClusterIP-only
DNS egress is not enough on Dataplane V2 with NodeLocal DNSCache.

### **VS Code cannot resolve any GitHub action**

Test connectivity:

```powershell
Test-NetConnection api.github.com -Port 443
```

Inspect the GitHub Actions extension output and reauthenticate. A warning against every
action repository is an editor resolver problem, not evidence that every tag is invalid.

---

## **24. Release workflow**

Run from GitHub:

```text
Actions
  → Governed Release
  → Run workflow
```

Inputs:

```text
tag: immutable release tag
deploy: false for evidence-only, true for digest deployment
```

Release evidence includes:

```text
Trivy scan results
SPDX SBOMs
Cosign signatures
SBOM attestations
signature verification
attestation verification
image-lock.json
```

Deployment uses immutable digests from `image-lock.json`, not mutable image tags.

Local equivalent:

```bash
RELEASE_TAG=v1 \
PROJECT_ID=class-6-5-tiqs \
REGION=us-central1 \
REPOSITORY=vertex-agent-lab \
./scripts/13-release-images.sh
```

Deploy verified digests:

```bash
./scripts/14-deploy-release-images.sh \
  release-evidence/image-lock.json
```

---

## **25. Teardown**

### **25.1 Disable controlled remediation**

Before teardown, set:

```yaml
AUTOMATION_MODE: disabled
EXECUTION_MODE: disabled
```

Apply and restart the Governance and Remediation Agents.

### **25.2 Delete Kubernetes namespaces**

Canonical teardown:

```bash
unset CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT
gcloud config unset auth/impersonate_service_account
CONFIRM_TEARDOWN=yes ./scripts/15-teardown.sh
```

The script clears impersonation, deletes lab namespaces, empties Artifact Registry
(stripping Git Bash `\r`), deletes the evidence dataset as `evidence-admin`,
removes those resources from Terraform state, and applies a destroy plan.

Skip a stage with `SKIP_KUBERNETES=yes`, `SKIP_ARTIFACT_REGISTRY=yes`,
`SKIP_BIGQUERY=yes`, or `SKIP_TERRAFORM=yes`.

Manual equivalent if you need to run the stages separately:

Clear BigQuery impersonation first. `kubectl` uses `gke-gcloud-auth-plugin`, which caches
the last token. If you still see `User "evidence-admin@..."` in Forbidden errors:

```bash
unset CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT
gcloud config unset auth/impersonate_service_account
rm -f "$HOME/.kube/gke_gcloud_auth_plugin_cache"
gcloud config get-value account
```

Use the Gmail project Owner for this step if the Workspace account cannot write
`legacy_credentials\...\adc.json`.

```bash
kubectl delete namespace \
  app01 \
  security \
  shared-services \
  ai-agents \
  ai-governance \
  mcp \
  mcp-gateway \
  --ignore-not-found
```

Confirm LoadBalancer and namespace removal:

```bash
kubectl get namespace
gcloud compute forwarding-rules list \
  --project=class-6-5-tiqs
```

### **25.3 Empty Artifact Registry**

Terraform may not be able to delete a non-empty repository.

```bash
gcloud artifacts packages list \
  --project=class-6-5-tiqs \
  --location=us-central1 \
  --repository=vertex-agent-lab \
  --format='value(name)' \
| tr -d '\r' \
| while IFS= read -r package; do
    [ -z "${package}" ] && continue
    gcloud artifacts packages delete "${package##*/}" \
      --project=class-6-5-tiqs \
      --location=us-central1 \
      --repository=vertex-agent-lab \
      --quiet
  done
```

### **25.4 Destroy infrastructure**

The evidence dataset ACL is only `evidence-admin`. Terraform running as a user cannot delete its tables (`bigquery.tables.delete` denied). Delete the dataset as that SA first, then destroy:

```bash
export CLOUDSDK_PYTHON="/c/Python312/python.exe"
export CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT=evidence-admin@class-6-5-tiqs.iam.gserviceaccount.com
bq rm -r -f class-6-5-tiqs:agentic_governance_evidence
unset CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT

terraform -chdir=terraform state rm google_bigquery_dataset_access.governance_sink_writer || true
terraform -chdir=terraform state rm google_bigquery_dataset.governance_evidence || true

terraform -chdir=terraform plan -destroy -out=destroy.tfplan
terraform -chdir=terraform show destroy.tfplan
terraform -chdir=terraform apply destroy.tfplan
```

KMS key rings cannot be deleted. Workload Identity pools and custom IAM role IDs stay reserved for days after destroy. The next apply should run `./scripts/03-adopt-retained-gcp.sh` first, or it will 409/400 on those names.

### **25.5 Remove local generated files**

```bash
rm -rf terraform/.terraform
rm -f terraform/terraform.tfvars
rm -f terraform/*.tfplan
rm -rf release-evidence
```

Keep:

```text
terraform/.terraform.lock.hcl
terraform/terraform.tfvars.example
```

### **25.6 Confirm resources are gone**

```bash
gcloud container clusters list \
  --project=class-6-5-tiqs

gcloud artifacts repositories list \
  --project=class-6-5-tiqs \
  --location=us-central1

gcloud pubsub topics list \
  --project=class-6-5-tiqs

gcloud kms keyrings list \
  --project=class-6-5-tiqs \
  --location=us-central1

export CLOUDSDK_PYTHON="/c/Python312/python.exe"
bq ls --project_id=class-6-5-tiqs
```

Some APIs and retained audit data may intentionally remain depending on Terraform
configuration and organizational retention requirements.

---

## **26. Completion checklist**

```text
[ ] Local tfvars created and ignored (zone us-central1-c, KMS version 2)
[ ] Administrator CIDR updated
[ ] Approval signer is a Workspace user in the allowed org domain
[ ] Validation passed (`./scripts/01-validate.sh`)
[ ] Terraform plan reviewed and applied (`./scripts/03-adopt-retained-gcp.sh` if 409/ERROR)
[ ] GKE credentials obtained for us-central1-c
[ ] Eleven v1 images built and pushed, including app and scanner-publisher
[ ] Falco installed
[ ] Platform deployed
[ ] All Deployments ready (broken-app uses app:v1; Postgres connected)
[ ] NetworkPolicies present (DNS includes node-local-dns and 169.254.20.10)
[ ] PodMonitoring, HPAs, and PDBs present
[ ] Trivy and Prowler CronJobs present and a manual Job succeeded
[ ] Governance smoke test returned REQUIRE_APPROVAL
[ ] End-to-end pipeline test produced an incident report
[ ] Cloud KMS approval signed with key version 2
[ ] BigQuery evidence listed via evidence-admin impersonation
[ ] Automated execution remains disabled or was explicitly approved
[ ] GitHub CI passed
[ ] Release evidence generated and retained
[ ] Teardown verified when the lab is complete (`CONFIRM_TEARDOWN=yes ./scripts/15-teardown.sh`)
```
