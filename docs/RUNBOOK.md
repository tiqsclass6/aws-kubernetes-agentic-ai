# **RUNBOOK — Phase 5 Agentic Security Platform on GKE**

This runbook provisions, validates, deploys, tests, operates, and removes the governed
Phase 5 multi-agent security platform.

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
Zone:                us-central1-a
GKE cluster:         vertex-agent-lab
Artifact Registry:   vertex-agent-lab
Image tag:           phase5-v1
Terraform backend:   gs://tiqs-kubernetes/agentic/terraform/state
```

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
available from the same shell used for the scripts.

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

phase5_approval_signer_members = [
  "user:YOUR_GOOGLE_ACCOUNT",
]
```

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

Make scripts executable:

```bash
chmod +x scripts/*.sh
```

Run the complete validation suite:

```bash
./scripts/phase5-validate.sh
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
terraform -chdir=terraform plan -out=phase5.tfplan
terraform -chdir=terraform show phase5.tfplan
```

Apply:

```bash
terraform -chdir=terraform apply phase5.tfplan
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
  --zone us-central1-a \
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

Create these GitHub repository variables:

```text
GCP_PROJECT_ID=class-6-5-tiqs
GCP_WIF_PROVIDER=<terraform output>
GCP_RELEASE_SERVICE_ACCOUNT=<terraform output>
GKE_CLUSTER_NAME=vertex-agent-lab
GKE_CLUSTER_LOCATION=us-central1-a
```

Create a GitHub environment named:

```text
production
```

Require a reviewer before environment deployment.

Active workflows:

```text
.github/workflows/phase5-ci.yml
.github/workflows/phase5-release.yml
```

The Phase 5 release workflow is manually dispatched and defaults to build-only.
Set `deploy=true` only when the release evidence and target environment have been
reviewed.

### VS Code resolver warning

The workflow files use the project compatibility references:

```yaml
actions/checkout@v4
actions/setup-python@v5
hashicorp/setup-terraform@v3
github/codeql-action/upload-sarif@v3
google-github-actions/auth@v2
google-github-actions/setup-gcloud@v2
docker/setup-buildx-action@v3
sigstore/cosign-installer@v3.10.1
actions/upload-artifact@v4
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

## **7. Build and push Phase 5 images**

The local build script requires Docker and `gcloud`.

```bash
PROJECT_ID=class-6-5-tiqs \
REGION=us-central1 \
REPOSITORY=vertex-agent-lab \
TAG=phase5-v1 \
./scripts/build-phase5-images.sh
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
demo-app
```

Verify:

```bash
gcloud artifacts docker images list \
  us-central1-docker.pkg.dev/class-6-5-tiqs/vertex-agent-lab \
  --include-tags
```

---

## **8. Install Falco**

```bash
./scripts/install-falco.sh
```

Verify:

```bash
helm list -A
kubectl get pods -A | grep -i falco
```

Falco is a runtime telemetry source. Trivy and Prowler run as scheduled scanner workloads
in the `security` namespace after Phase 5 deployment.

---

## **9. Deploy the platform**

Run the canonical deployment script:

```bash
./scripts/deploy-phase5.sh
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
Phase 5 platform deployed. Automated remediation remains disabled by default.
```

### Manual secret creation

The deployment script calls this automatically:

```bash
./scripts/create-demo-secret.sh
```

To supply a specific password without committing it:

```bash
POSTGRES_PASSWORD='replace-at-runtime' \
./scripts/create-demo-secret.sh
```

The repository contains only:

```text
manifests/postgres-secret.example.yaml
```

Do not apply the example with its placeholder value.

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

### NetworkPolicies

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
scanner workloads → required registry and Pub/Sub endpoints
```

### MCP certificate material

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
./scripts/generate-mcp-mtls.sh
```

Then restart affected workloads:

```bash
kubectl rollout restart deployment/mcp-gateway -n mcp-gateway
kubectl rollout restart deployment/mcp-server -n mcp
kubectl rollout restart deployment/remediation-agent -n ai-agents
```

### Kubernetes RBAC

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
./scripts/test-phase5-governance.sh
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
./scripts/test-pipeline.sh
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
./scripts/review-phase5-approval.sh \
  approve \
  "analyst@example.com" \
  "Approved after validating the incident evidence and proposed target."
```

Deny the next request:

```bash
./scripts/review-phase5-approval.sh \
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
Key version:    1
Decision TTL:   600 seconds
```

Override with environment variables when necessary:

```bash
PROJECT_ID=class-6-5-tiqs \
KMS_LOCATION=us-central1 \
KMS_KEYRING=agentic-governance \
KMS_KEY=approval-signing \
KMS_KEY_VERSION=1 \
APPROVAL_TTL_SECONDS=600 \
./scripts/review-phase5-approval.sh \
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
./scripts/smoke-test-metrics.sh
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
kubectl describe cronjob trivy -n security
kubectl describe cronjob prowler -n security
```

Create one-time Jobs from the schedules:

```bash
kubectl create job \
  --from=cronjob/trivy \
  trivy-manual-$(date +%s) \
  -n security

kubectl create job \
  --from=cronjob/prowler \
  prowler-manual-$(date +%s) \
  -n security
```

Inspect:

```bash
kubectl get jobs -n security
kubectl logs -n security job/JOB_NAME --all-containers=true
```

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

List the dataset:

```bash
bq ls --project_id=class-6-5-tiqs
```

Get the Terraform-configured dataset:

```bash
terraform -chdir=terraform output -raw phase5_evidence_dataset
```

Inspect recent evidence using the tables created by the deployed log sinks:

```bash
bq ls class-6-5-tiqs:agentic_governance_evidence
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

### Cloud KMS approval key

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
phase5_approval_key_version = "NEW_VERSION"
```

Apply Terraform, update the agent configuration if required, redeploy, and validate signed
approval verification before disabling the prior version.

### MCP certificates

```bash
./scripts/generate-mcp-mtls.sh

kubectl rollout restart deployment/mcp-gateway -n mcp-gateway
kubectl rollout restart deployment/mcp-server -n mcp
kubectl rollout restart deployment/remediation-agent -n ai-agents
```

---

## **23. Troubleshooting**

### `kubectl` cannot reach GKE

Check the current public IP and update `authorized_networks`:

```powershell
(Invoke-WebRequest -UseBasicParsing https://api.ipify.org).Content
```

Reapply Terraform:

```bash
terraform -chdir=terraform plan -out=phase5.tfplan
terraform -chdir=terraform apply phase5.tfplan
```

### Workload Identity authorization failure

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

### Pub/Sub messages stop moving

```bash
gcloud pubsub subscriptions pull agent-events-dlq-sub \
  --project=class-6-5-tiqs \
  --limit=20 \
  --auto-ack \
  --format=json
```

Check the consumer Deployment logs and its subscription IAM role.

### Governance Agent cannot evaluate policy

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

### Approval signature rejected

Confirm:

```text
exact KMS key version
request hash
governance decision ID
approval request ID
decision expiry
reviewer IAM access
canonical JSON serialization
```

Inspect:

```bash
kubectl logs -n ai-governance deployment/approval-agent --tail=200
```

### MCP gateway returns TLS errors

```bash
kubectl get secret -n mcp-gateway mcp-gateway-server-tls mcp-client-ca
kubectl get secret -n ai-agents remediation-agent-client-tls mcp-gateway-server-ca
kubectl logs -n mcp-gateway deployment/mcp-gateway --tail=200
```

Rotate certificates with `scripts/generate-mcp-mtls.sh`.

### ImagePullBackOff

```bash
kubectl describe pod POD_NAME -n NAMESPACE
gcloud artifacts docker images list \
  us-central1-docker.pkg.dev/class-6-5-tiqs/vertex-agent-lab \
  --include-tags
```

Confirm the image tag and Artifact Registry node-reader IAM binding.

### VS Code cannot resolve any GitHub action

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
  → Phase 5 Governed Release
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
RELEASE_TAG=phase5-v1 \
PROJECT_ID=class-6-5-tiqs \
REGION=us-central1 \
REPOSITORY=vertex-agent-lab \
./scripts/phase5-release-images.sh
```

Deploy verified digests:

```bash
./scripts/deploy-phase5-images.sh \
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
for package in $(gcloud artifacts packages list \
  --project=class-6-5-tiqs \
  --location=us-central1 \
  --repository=vertex-agent-lab \
  --format='value(name)'); do
  gcloud artifacts packages delete "${package##*/}" \
    --project=class-6-5-tiqs \
    --location=us-central1 \
    --repository=vertex-agent-lab \
    --quiet
done
```

### **25.4 Destroy infrastructure**

```bash
terraform -chdir=terraform plan -destroy -out=destroy.tfplan
terraform -chdir=terraform show destroy.tfplan
terraform -chdir=terraform apply destroy.tfplan
```

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

bq ls --project_id=class-6-5-tiqs
```

Some APIs and retained audit data may intentionally remain depending on Terraform
configuration and organizational retention requirements.

---

## **26. Completion checklist**

```text
[ ] Local tfvars created and ignored
[ ] Administrator CIDR updated
[ ] Approval reviewer IAM identity configured
[ ] Phase 5 validation passed
[ ] Terraform plan reviewed and applied
[ ] GKE credentials obtained
[ ] Eleven images built and pushed
[ ] Falco installed
[ ] Phase 5 deployment completed
[ ] All Deployments ready
[ ] NetworkPolicies present
[ ] PodMonitoring, HPAs, and PDBs present
[ ] Trivy and Prowler CronJobs present
[ ] Governance smoke test returned REQUIRE_APPROVAL
[ ] End-to-end pipeline test produced an incident report
[ ] Cloud KMS approval successfully signed and verified
[ ] BigQuery evidence verified
[ ] Automated execution remains disabled or was explicitly approved
[ ] GitHub CI passed
[ ] Release evidence generated and retained
[ ] Teardown verified when the lab is complete
```
