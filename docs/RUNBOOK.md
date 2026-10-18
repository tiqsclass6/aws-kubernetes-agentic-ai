# **RUNBOOK — Agentic Security Platform on GKE**

This runbook provisions, validates, deploys, tests, operates, and removes the governed multi-agent security platform. Last verified live e2e: 16–17 Oct 2026, two full rebuilds including one controlled-remediation run (then torn down).
Re-apply from this runbook to run it again.

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

Automated remediation remains disabled unless both governance and execution modes are explicitly changed to `controlled`.

---

## **1. Operating Assumptions**

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
Approval KMS version: 12
Terraform backend:   gs://tiqs-kubernetes/agentic/terraform/state
```

Google identities in this org:

```text
Cluster / Terraform admin:  a project Owner (may be a consumer Gmail account)
Approval signer / BQ:       a Workspace user in the org's allowed domain
                            (export it as APPROVER_EMAIL)
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
falco          (Helm release from 05-install-falco.sh; not in manifests/namespaces.yaml)
```

The backend bucket must already exist before `terraform init`.

---

## **2. Prerequisites**

Required tools:

```text
Terraform >= 1.16.0 (CI pins 1.16.6)
Google Cloud CLI
kubectl
Docker with Buildx
Python 3.14 (CI and images; the pinned pydantic-core, PyYAML, and psycopg2-binary have no 3.15 wheels)
pytest and PyYAML (python/requirements-test.txt)
cryptography (python/requirements-approval-agent.txt; needed by unit tests)
Bash
OpenSSL
Helm
jq
curl
OPA 1.21.2
Conftest 0.71.1
Trivy 0.76.0
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

On Windows, verify that `gcloud`, `kubectl`, `docker`, `python`, and `openssl` are available from the same shell used for the scripts. Git Bash plus the Cloud SDK has
several traps documented in [Windows Git Bash](#windows-git-bash). Pin `CLOUDSDK_PYTHON` to a real interpreter such as `/c/Python314/python.exe` if the Unix
`bq` wrapper fails with `python3.14: command not found`.

---

## **3. Prepare Local Configuration**

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

approval_key_version = "12"
```

`approval_signer_members` must be an org-permitted Workspace identity, not a consumer Gmail account. Later sections refer to it as `APPROVER_EMAIL`; export it in your shell instead of writing the address into tracked files. Versions `1`–`11` are DESTROYED; the ENABLED version as of 16 Oct 2026 is `12`. `15-teardown.sh` now retains the KMS keys, so this version survives teardown. If a version is ever destroyed (an older teardown, or `DESTROY_KMS_KEYS=yes`), `03-adopt-retained-gcp.sh` creates a new one; trust the version it prints over this number. If `03-adopt-retained-gcp.sh` prints a different ENABLED version, pin tfvars, `manifests/approval-agent.yaml`, and `scripts/11-review-approval.sh` to that version before signing.

Copying `terraform/terraform.tfvars.example` already targets `us-central1-c` and KMS version `12`. Still replace the documentation CIDR and signer email.

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

## **4. Validate Before Provisioning**

Do not run `01` through `15` as a numbered loop. Several scripts are nested or conditional. Canonical path to complete the lab:

```text
1.  Copy terraform.tfvars and set zone, CIDR, Workspace signer, KMS version 12 (or what 03 prints)

2.  Create and activate the Python 3.14 virtual environment (below)

3.  bash scripts/01-validate.sh          (calls 02-conftest-test.sh)

4.  terraform -chdir=terraform init

5.  bash scripts/03-adopt-retained-gcp.sh
       only if WIF, KMS, or an ERROR node pool already exists
       (requires step 4 first; does not import the GKE cluster or VPC)

6.  terraform -chdir=terraform plan -out=agentic.tfplan

7.  terraform -chdir=terraform apply agentic.tfplan
8.  gcloud container clusters get-credentials ...

9.  GitHub variables + production environment (optional until release)

10. bash scripts/04-build-images.sh

11. bash scripts/05-install-falco.sh

12. bash scripts/08-deploy.sh            (calls 06 and 07)

13. bash scripts/09-test-governance.sh

14. bash scripts/10-test-pipeline.sh

15. bash scripts/11-review-approval.sh   (when a request is pending)

16. bash scripts/12-smoke-test-metrics.sh

17. bash scripts/13-release-images.sh and 14-deploy-release-images.sh
       or GitHub workflow release.yml

18. CONFIRM_TEARDOWN=yes bash scripts/15-teardown.sh
       when the lab is finished
```

Script catalog:

```text
01-validate.sh                 local static checks; invokes 02
02-conftest-test.sh            Conftest; invoked by 01, also runnable alone
03-adopt-retained-gcp.sh       import/undelete WIF and KMS; delete ERROR node pool
04-build-images.sh             eleven :v1 images to Artifact Registry
05-install-falco.sh            Helm falcosecurity/falco 9.1.0 in namespace falco
06-create-demo-secret.sh       invoked by 08; skip if Secret already exists
07-generate-mcp-mtls.sh        invoked by 08; also used to rotate certs
08-deploy.sh                   canonical platform apply
09-test-governance.sh          REQUIRE_APPROVAL smoke test
10-test-pipeline.sh            end-to-end findings → incident report
11-review-approval.sh          sign approve/deny with KMS version 12
12-smoke-test-metrics.sh       port-forward /metrics on observer-agent
13-release-images.sh           SBOM, Trivy, Cosign, image-lock.json
14-deploy-release-images.sh    set Deployments to lock-file digests
15-teardown.sh                 namespaces (including falco), AR, BQ, destroy
```

Make scripts executable:

```bash
chmod +x scripts/*.sh
```

The scripts call `python`, so it must resolve to Python 3.14. If your default `python` is newer (3.15), the pinned `pydantic-core` has no wheel for it and the install fails. Create a 3.14 virtual environment once, then activate it in every shell you run the scripts from:

```bash
py -3.14 -m venv .venv            # Windows; on Linux/macOS: python3.14 -m venv .venv
source .venv/Scripts/activate     # Git Bash; on Linux/macOS: source .venv/bin/activate
python --version                  # must print Python 3.14.x
```

Install the Python packages that `01-validate.sh` needs (pytest, PyYAML, cryptography, and the agent dependencies the tests import):

```bash
python -m pip install -r python/requirements-test.txt \
  -r python/requirements-approval-agent.txt
```

`.venv/` is gitignored.

Run the complete validation suite:

```bash
bash scripts/01-validate.sh
```

The script performs eight steps:

```text
1/8  Python compilation
2/8  Python unit tests
3/8  Kubernetes YAML parsing (manifests only; not GitHub workflows)
4/8  Bash syntax checks
5/8  OPA governance policy tests
6/8  Terraform fmt (writes, then fmt -check)
7/8  terraform init -backend=false and validate
8/8  bash scripts/02-conftest-test.sh
```

`01-validate.sh` does not parse workflow YAML, does not scan for generated Terraform files, and does not check GitHub action pins. Those checks are not part of the local script. CI parses Kubernetes YAML in the Lint job and runs Trivy separately.

Manual Conftest equivalent is the numbered script, not a hand-picked manifest list. `02-conftest-test.sh` tests every top-level `manifests/*.yaml` except `broken-app.yaml` and `postgres-secret.example.yaml`, then asserts that `broken-app.yaml` fails.

```bash
bash scripts/02-conftest-test.sh
```

Other manual equivalents:

```bash
python -m compileall -q python
python -m pytest -q python/tests

opa test policy/governance -v

terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate
```

---

## **5. Provision Google Cloud infrastructure**

Initialize the real GCS backend:

```bash
terraform -chdir=terraform init -upgrade
```

Format and validate:

```bash
terraform -chdir=terraform fmt -recursive
terraform -chdir=terraform validate
```

Check whether this project already has leftovers from a previous lab. `03-adopt-retained-gcp.sh` requires `.terraform/` from `init`. It imports or undeletes the GitHub WIF pool, the KMS key ring and keys, restores a `DESTROY_SCHEDULED` CMEK version only when none is ENABLED, sets that version primary, and deletes a node pool stuck in `ERROR`. It does **not** import the GKE cluster, VPC, Pub/Sub, or other stack resources. If `approval-signing` already has an ENABLED version, pin that (currently `12`). Do not create extra signing versions.

```bash
terraform -chdir=terraform state list
gcloud container clusters list --project=class-6-5-tiqs
```

- Empty state and no cluster: continue to plan and apply.
- Empty state and `vertex-agent-lab` already exists: do not apply a create plan. Import the live stack or destroy the leftover cluster first. Apply against empty state will 409 on the cluster name.
- WIF pool, KMS ring, or ERROR node pool already in GCP: run `bash scripts/03-adopt-retained-gcp.sh`, then plan.

Create a reviewed plan and apply it:

```bash
terraform -chdir=terraform plan -out=agentic.tfplan
terraform -chdir=terraform show agentic.tfplan
terraform -chdir=terraform apply agentic.tfplan
```

On Windows, if plan fails with `connectex` talking to `oauth2.googleapis.com` over
IPv6, export `GOOGLE_OAUTH_ACCESS_TOKEN` as documented in
[Terraform: connectex / IPv6 OAuth token refresh](#terraform-connectex--ipv6-oauth-token-refresh)
and retry. Do not treat that error as a broken GitHub Actions data source.

If apply fails because a custom IAM role is deletion-pending, a Workload Identity pool or KMS key ring already exists, or the GKE node pool is in `ERROR`, adopt the leftovers and retry:

```bash
bash scripts/03-adopt-retained-gcp.sh
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

If the connection times out, update the workstation CIDR in `terraform/terraform.tfvars` and reapply Terraform.

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

`GKE_CLUSTER_LOCATION` must match `var.zone` (`us-central1-c`).

Create a GitHub environment named `production`:

```bash
gh api --method PUT repos/tiqsclass6/aws-kubernetes-agentic-ai/environments/production
```

In the GitHub UI, require a reviewer before that environment can deploy.

CI runs on push and pull request. Dispatch the release workflow from GitHub; it is not a local script:

```bash
gh workflow run release.yml -f tag=v1 -f deploy=false
```

The workflow runs `bash scripts/13-release-images.sh` so Windows-committed scripts without the Unix execute bit still start. Exit `126` on `./scripts/13-release-images.sh` meant the runner could not execute the file.

Active workflow files (GitHub-hosted only):

```text
.github/workflows/ci.yml
.github/workflows/release.yml
```

The release workflow is manually dispatched and defaults to build-only. It has two jobs:

- `release` builds, scans, signs, and attests the images and uploads the `release-<tag>` evidence artifact. It has no environment, so build-only runs never wait for approval.
- `deploy` runs only with `deploy=true`, after `release` succeeds. It uses the `production` environment, so it pauses until a required reviewer approves it in the Actions UI. It then downloads the evidence, verifies `image-lock.json` against `image-lock.sha256`, and runs `14-deploy-release-images.sh`.

Set `deploy=true` only when the release evidence and target environment have been reviewed. GitHub-hosted runner IPs are not in `authorized_networks`, so the `deploy` job cannot reach the control plane unless that is changed; until then, download the artifact and run `14` from an authorized workstation (`gh run download RUN_ID -n release-v1 -D release-evidence`).

### **VS Code resolver warning**

The workflow files use these project compatibility references.

CI (`.github/workflows/ci.yml`):

```yaml
actions/checkout@v7
actions/setup-python@v7
hashicorp/setup-terraform@v4
github/codeql-action/upload-sarif@v4
```

CI pins Python `3.14`, Terraform `1.16.6`, OPA `1.21.2`, Conftest `0.71.1`, and Trivy `0.76.0` (the in-cluster Trivy CronJob uses the same version). Both workflows run on `ubuntu-24.04` rather than `ubuntu-latest`, which GitHub moves to Ubuntu 26.04 between 19 October and 19 November 2026 ([actions/runner-images#14748](https://github.com/actions/runner-images/issues/14748)).
Every CI job uses checkout `@v7`; the Lint and Python jobs use setup-python `@v7`.

Release (`.github/workflows/release.yml`):

```yaml
actions/checkout@v7
google-github-actions/auth@v3
google-github-actions/setup-gcloud@v3
docker/setup-buildx-action@v4
sigstore/cosign-installer@v4.1.2
actions/upload-artifact@v7
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

Do not continue changing action versions when every repository fails resolution. Validate with `actionlint` or an actual GitHub-hosted workflow run.

---

## **7. Build and Push Container Images**

The local build script requires Docker and `gcloud`.

```bash
PROJECT_ID=class-6-5-tiqs \
REGION=us-central1 \
REPOSITORY=vertex-agent-lab \
TAG=v1 \
bash scripts/04-build-images.sh
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

There is no `vertex-agent` image in this lab. Scanner CronJobs and `broken-app` must reference `v1` tags that actually exist in Artifact Registry.

Verify:

```bash
gcloud artifacts docker images list \
  us-central1-docker.pkg.dev/class-6-5-tiqs/vertex-agent-lab \
  --include-tags
```

---

## **8. Install Falco**

```bash
bash scripts/05-install-falco.sh
```

The script installs Helm chart `falcosecurity/falco` version `9.1.0` into namespace `falco` (created by Helm, not by `manifests/namespaces.yaml`). Falco posts runtime events to the Event Aggregator after that Deployment exists.

Verify:

```bash
helm list -A
kubectl get pods -n falco
kubectl get daemonset falco -n falco
```

Falco is a runtime telemetry source. Trivy and Prowler run as scheduled scanner workloads in the `security` namespace after deployment.

---

## **9. Deploy the Platform**

Run the canonical deployment script:

```bash
bash scripts/08-deploy.sh
```

The script performs these operations in order:

1. Apply `manifests/namespaces.yaml`, `resourcequota-app01.yaml`, and `limitrange-app01.yaml`.
2. Create the OPA governance-policy ConfigMaps.
3. Generate the PostgreSQL demo Secret (`06-create-demo-secret.sh`).
4. Generate or rotate MCP mTLS material (`07-generate-mcp-mtls.sh`).
5. Apply Kubernetes identities and RBAC.
6. Deploy the MCP gateway and MCP Server.
7. Deploy PostgreSQL and the demo application.
8. Deploy all pipeline and governance agents.
9. Wait for every Deployment to become ready.
10. Apply NetworkPolicies.
11. Apply PodMonitoring objects.
12. Apply HPAs and PDBs.
13. Apply Trivy and Prowler CronJobs.

Expected messages:

```text
Platform deployed
Automated remediation remains disabled by default.
```

### **Manual Secret Creation**

The deployment script calls this automatically:

```bash
bash scripts/06-create-demo-secret.sh
```

To supply a specific password without committing it:

```bash
POSTGRES_PASSWORD='replace-at-runtime' \
bash scripts/06-create-demo-secret.sh
```

The repository contains only:

```text
manifests/postgres-secret.example.yaml
```

Do not apply the example with its placeholder value.

`06-create-demo-secret.sh` leaves an existing `postgres-credentials` Secret unchanged. Postgres reads that password only when it first initializes PGDATA. Rotating the Secret on a running emptyDir volume does not change the database password; delete the postgres pod so it re-inits, or keep the original Secret.

After NetworkPolicies are applied, pod DNS must reach both kube-dns and NodeLocal DNSCache. Dataplane V2 policies therefore allow kube-dns and node-local-dns in `kube-system`, ClusterIP `10.112.0.10/32`, and `169.254.20.10/32`. Allowing only the kube-dns ClusterIP produces `Temporary failure in name resolution`.

---

## **10. Verify Workloads**

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

Falco is a DaemonSet, not a Deployment:

```bash
kubectl get daemonset falco -n falco
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

## **11. Verify Security Boundaries**

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

### **MCP Certificate Material**

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
bash scripts/07-generate-mcp-mtls.sh
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

## **12. Verify Pub/Sub Resources**

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
  --filter='name:(observer-agent-sub correlation-agent-sub ir-analyst-agent-sub governance-agent-sub approval-agent-sub remediation-governance-sub reporting-agent-sub approval-requests-review-sub governance-decisions-debug-sub governance-audit-debug-sub incident-reports-debug-sub agent-events-dlq-sub)'
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

## **13. Run Governance Validation**

Run the deterministic governance smoke test:

```bash
bash scripts/09-test-governance.sh
```

The synthetic event recommends restarting `app01/broken-app`, but default automation is disabled. Expected result:

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

## **14. Run the End-to-End Governed Pipeline Test**

```bash
bash scripts/10-test-pipeline.sh
```

The script publishes two correlated findings to `security-findings` and waits for a final report on `incident-reports-debug-sub`.

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

Because automated execution is disabled, the test validates the complete event path without requiring a Kubernetes restart.

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

## **15. Review and Sign a Human Approval**

Clear BigQuery impersonation first. Section 21 sets `CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT=evidence-admin@...`. That service account cannot pull `approval-requests-review-sub` or publish
`approval-decisions`, so `11-review-approval.sh` fails with Pub/Sub `PERMISSION_DENIED`.

Variables do not carry over between terminals. Export `APPROVER_EMAIL` first, replacing `YOUR_WORKSPACE_SIGNER` with the real address. The `if` only switches accounts when the value looks like an email: an empty value or the literal placeholder would otherwise become your active gcloud account, every later `gcloud` call would fail, and the placeholder would be recorded as the reviewer of any decision you sign.

```bash
export APPROVER_EMAIL=YOUR_WORKSPACE_SIGNER   # replace with your Workspace signer's address
if [[ "${APPROVER_EMAIL:-}" == *@* ]]; then
  unset CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT
  gcloud config unset auth/impersonate_service_account
  gcloud config set account "${APPROVER_EMAIL}"
  gcloud auth list
else
  echo "APPROVER_EMAIL must be your Workspace signer's address, not '${APPROVER_EMAIL:-}'"
fi
```

`11` refuses to sign unless the reviewer you pass matches the active gcloud account, because that is the identity that holds `signerVerifier` on the key.

The active account must be the Workspace signer in `approval_signer_members` (`user:$APPROVER_EMAIL`). Terraform grants that identity `roles/pubsub.subscriber` and `roles/pubsub.viewer` on
`approval-requests-review-sub`, `roles/pubsub.publisher` on `approval-decisions`, and `roles/cloudkms.signerVerifier` on `approval-signing`. A Gmail project Owner can often pull Pub/Sub, but it cannot sign unless it is also in `approval_signer_members`.

`11-review-approval.sh` only signs a message that is already on `approval-requests-review-sub`. That message is created when the Governance Agent emits `REQUIRE_APPROVAL`. Run the governance smoke test first, then sign:

```bash
bash scripts/09-test-governance.sh
```

Wait until that script prints `Governance smoke test passed`. Then sign immediately. Do **not** `gcloud pubsub subscriptions pull` first. A pull without `--auto-ack` still leases the message for 600 seconds, so `11-review-approval.sh` will report `no pending approval request was available`.

Check backlog without leasing:

```bash
gcloud pubsub subscriptions describe approval-requests-review-sub \
  --project=class-6-5-tiqs \
  --format='yaml(name,topic,ackDeadlineSeconds)'
```

If describe returns `PERMISSION_DENIED`, the active account is not the Terraform signer (or impersonation is still on). Re-run the account commands above, then `terraform apply` so `approval_reviewers_*` IAM exists for `user:$APPROVER_EMAIL`.

If `09` already passed and the review script is still empty, mint a new request by re-running `09`, then run `11` in the same shell.

`11` pulls whichever pending request Pub/Sub delivers. Pull order is not guaranteed: in the 17 Oct 2026 run, with two `09` requests pending, the first `11` got the newer one. Check `incident_id` (it contains the `09` run ID) and `expires_at` in the displayed binding before you type `y`; answering `N` leaves the request pending for the next `11`. In controlled mode (section 16), approving any pending request executes it.

Approve as the live Workspace signer (`$APPROVER_EMAIL`), not the documentation placeholder `YOUR_WORKSPACE_ACCOUNT` and not `analyst@example.com`:

```bash
bash scripts/11-review-approval.sh \
  approve \
  "${APPROVER_EMAIL}" \
  "Approved after validating the incident evidence and proposed target."
```

Deny:

```bash
bash scripts/11-review-approval.sh \
  deny \
  "${APPROVER_EMAIL}" \
  "Denied because the requested action needs additional investigation."
```

Required reason length is at least 10 characters.

The script:

1. refuses to run while `evidence-admin` impersonation is set;
2. pulls one request from `approval-requests-review-sub`;
3. parses and displays its binding;
4. asks for interactive confirmation;
5. creates a decision with a short expiration;
6. signs the canonical decision document with Cloud KMS;
7. publishes to `approval-decisions`;
8. acknowledges the original request after successful publication.

Default signing configuration:

```text
Location:       us-central1
Key ring:       agentic-governance
Key:            approval-signing
Key version:    12
Decision TTL:   600 seconds
```

`scripts/11-review-approval.sh` and `manifests/approval-agent.yaml` default to version `12`. Versions `1`–`11` are DESTROYED on this project and cannot sign. If `12` is `DESTROY_SCHEDULED`, restore and enable it before reviewing.

Override with environment variables when necessary:

```bash
PROJECT_ID=class-6-5-tiqs \
KMS_LOCATION=us-central1 \
KMS_KEYRING=agentic-governance \
KMS_KEY=approval-signing \
KMS_KEY_VERSION=12 \
APPROVAL_TTL_SECONDS=600 \
bash scripts/11-review-approval.sh \
  approve \
  "${APPROVER_EMAIL}" \
  "Approved after reviewing the correlated security evidence."
```

---

## **16. Enable Controlled Remediation**

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

The control-plane still rejects requests that fail deterministic policy, approval, allowlist, idempotency, MCP, mTLS, or RBAC checks.

While both modes are `controlled`, policy can PERMIT without a human. A HIGH incident with confidence ≥ 0.95, low operational risk, at least 3 signals, 2 sources, and 3 evidence items executes automatically. The `09` fixture meets every threshold, so `09` restarts `broken-app` and then fails its `REQUIRE_APPROVAL` assertion. Live scanner findings can also qualify. Keep the controlled window short.

Confirm the action (verified 16 Oct 2026: signed approval → `executed` → `POST /tool/restart_deployment` 200):

```bash
kubectl logs -n mcp deploy/mcp-server --since=1h | grep -i restart
kubectl get deploy broken-app -n app01 -o jsonpath='{.spec.template.metadata.annotations}{"\n"}'
```

Return to fail-closed as soon as the test is done, and keep the edited manifests out of commits:

```bash
git checkout -- manifests/governance-agent.yaml manifests/remediation-agent.yaml
kubectl apply -f manifests/governance-agent.yaml -f manifests/remediation-agent.yaml
kubectl rollout restart deployment/governance-agent -n ai-governance
kubectl rollout restart deployment/remediation-agent -n ai-agents
kubectl rollout status deployment/governance-agent -n ai-governance --timeout=300s
kubectl rollout status deployment/remediation-agent -n ai-agents --timeout=300s
kubectl exec -n ai-agents deploy/remediation-agent -- printenv EXECUTION_MODE
```

Wait for both rollouts before the `printenv` check; run it immediately after the restart and it reads the old pod, which still says `controlled`. The ConfigMaps are the source of truth:

```bash
kubectl get configmap governance-agent-config -n ai-governance -o jsonpath='{.data.AUTOMATION_MODE}{"\n"}'
kubectl get configmap remediation-agent-config -n ai-agents -o jsonpath='{.data.EXECUTION_MODE}{"\n"}'
```

---

## **17. Metrics and Operational Readiness**

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
bash scripts/12-smoke-test-metrics.sh
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

## **18. Scanner Operations**

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

Trivy finishing first is expected. Prowler stays `Running` much longer.

```text
trivy-manual-*                        first image pull + vuln DB download, then ~1–2 minutes
prowler-manual-*                      first pull of prowlercloud/prowler:5.35.0 is ~736 MiB (~3 minutes)
                                      then 100+ GCP checks against class-6-5-tiqs (~3 minutes on 16 Oct 2026; allow 30)
Job activeDeadlineSeconds is 7200
```

Wait for completion instead of polling by eye:

```bash
kubectl wait --for=condition=complete \
  job/trivy-manual-TIMESTAMP -n security --timeout=300s

kubectl wait --for=condition=complete \
  job/prowler-manual-TIMESTAMP -n security --timeout=1800s
```

Do not `kubectl logs` while the Prowler pod is `ContainerCreating`. That returns `container "prowler" ... is waiting to start`. Wait until both containers are Running:

```bash
kubectl get pods -n security -o wide
kubectl logs -n security -l job-name=prowler-manual-JOBID -c prowler --tail=200
```

Healthy Prowler output includes Workload Identity as `prowler-sa@class-6-5-tiqs.iam.gserviceaccount.com` and `Executing 109 checks, please wait...`. The publisher sidecar waits on `/reports/.done` until the scan finishes.

Inspect. Copy the job name from `kubectl get jobs` — do not wrap it in angle brackets (`<id>`). Git Bash treats `<file>` as redirection and will look for a file named `id`.

```bash
kubectl get jobs -n security

TRIVY_JOB=$(kubectl get jobs -n security -o name | grep trivy-manual | tail -1)
PROWLER_JOB=$(kubectl get jobs -n security -o name | grep prowler-manual | tail -1)

kubectl logs -n security "${TRIVY_JOB}" --all-containers=true
kubectl logs -n security "${PROWLER_JOB}" --all-containers=true
```

Trivy `TARGET_IMAGES` are the `v1` tags:

```text
app
mcp-server
event-aggregator
scanner-publisher
```

Docker/containerd socket messages in Trivy logs are expected; the Job has no local runtime and scans the remote registry.

Prowler `5.35.0` is not on `PATH` when the CronJob overrides the image entrypoint. The Job must call `/home/prowler/.venv/bin/prowler`. `/bin/sh: prowler: not found` means the live CronJob still uses a bare `prowler` command.

Prowler exits `3` when any check FAILs. That is a successful scan with findings, not a crash. Without `--ignore-exit-code-3`, `set -e` skips `touch /reports/.done`, the publisher sidecar waits, and the Job stays `Running` with the prowler container in `Error`.

Terraform hardens **this lab's** resources against the Prowler families from the scan (CIS log-metric alerts, all-logs sink, audit logs, OS Login/serial-port metadata, VPC Flow Logs, DNS query logging, private GKE nodes + Cloud NAT, Secret Manager rotation + CMEK, BigQuery CMEK, and a 90-day rotating symmetric KMS key).

Prowler still scans the **entire** `class-6-5-tiqs` project. `manifests/prowler-mutelist.yaml` mutes leftover class Cloud Storage, default-VPC Compute, non-lab secrets, and the asymmetric `approval-signing` rotation check. Those findings show as **MUTED**, not FAIL. Lab names stay in the score (`class-6-5-tiqs-agentic-audit-logs`, `vertex-agent-lab` / `gke-vertex-agent-lab-*`, Slack/Jira secrets). IAM findings are project-wide and are not muted.

Re-apply the mutelist ConfigMap and CronJob, then create a **new** Job (existing Jobs keep the old spec):

```bash
kubectl apply -f manifests/prowler-mutelist.yaml
kubectl apply -f manifests/prowler-cronjob.yaml

kubectl create job --from=cronjob/prowler-gcp-scan \
  prowler-manual-$(date +%s) -n security
```

The green Prowler Cloud footer in the Job log is advertising, not an error.

---

## **19. Optional Slack Reporting**

Terraform creates the Secret Manager container, not the secret version.

Add the webhook. Read it without echoing it or saving it to shell history; an unset `SLACK_WEBHOOK_URL` fails with `Secret Payload cannot be empty`. Do not paste the URL anywhere else: anyone with it can post to the channel.

```bash
read -rsp 'Slack webhook URL: ' SLACK_WEBHOOK_URL; echo
[[ "$SLACK_WEBHOOK_URL" == https://hooks.slack.com/services/* ]] && echo "looks like a Slack webhook" || echo "not a Slack webhook URL"

printf '%s' "${SLACK_WEBHOOK_URL}" \
  | gcloud secrets versions add security-slack-webhook-url \
      --project=class-6-5-tiqs \
      --data-file=-

gcloud secrets versions list security-slack-webhook-url \
  --project=class-6-5-tiqs \
  --format='table(name,state,createTime)'
unset SLACK_WEBHOOK_URL
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

Verify with `./scripts/10-test-pipeline.sh`. The report should contain `"slack": {"enabled": true, "status": "sent", "status_code": 200}` (verified 17 Oct 2026). Before committing, restore the fail-closed manifest with `git checkout -- manifests/reporting-agent.yaml`. Teardown deletes the secret container and its versions.

---

## **20. Optional Jira Reporting**

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
JIRA_EMAIL: YOUR_JIRA_EMAIL
JIRA_PROJECT_KEY: SEC
JIRA_ISSUE_TYPE: Task
```

Apply and restart the Reporting Agent for the Jira configuration.

---

## **21. BigQuery Governance Evidence**

The dataset `agentic_governance_evidence` exists, but its ACL is only `evidence-admin`. Project Owner is not enough to list tables. A consumer Gmail account cannot be added to that ACL or as Token Creator on the SA (`iam.allowedPolicyMemberDomains`).

Terraform grants Token Creator on `evidence-admin` to every `approval_signer_members` identity. Stay on the Workspace signer (`$APPROVER_EMAIL`) for this section:

```bash
gcloud auth login "${APPROVER_EMAIL}"
```

If the probe below fails after apply, wait a minute for IAM, then retry. If Terraform has not applied the Token Creator binding yet:

```bash
gcloud iam service-accounts add-iam-policy-binding \
  evidence-admin@class-6-5-tiqs.iam.gserviceaccount.com \
  --project=class-6-5-tiqs \
  --member="user:${APPROVER_EMAIL}" \
  --role="roles/iam.serviceAccountTokenCreator"
```

Token Creator can take a minute to propagate. Do not run `bq` until this probe succeeds. Leave `CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT` unset for the probe:

```bash
gcloud auth print-access-token \
  --impersonate-service-account=evidence-admin@class-6-5-tiqs.iam.gserviceaccount.com \
  >/dev/null
```

On Git Bash, pin Python and impersonate. Use the Unix `bq` wrapper for SQL. `bq.cmd ls` is fine; `bq.cmd query` splits on `C:\Program Files`.

```bash
export CLOUDSDK_PYTHON="/c/Python314/python.exe"
export CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT=evidence-admin@class-6-5-tiqs.iam.gserviceaccount.com

bq ls --project_id=class-6-5-tiqs
terraform -chdir=terraform output -raw evidence_dataset
bq ls class-6-5-tiqs:agentic_governance_evidence
```

Logging sink tables are dated (`stdout_YYYYMMDD`). Do not copy an old table name from this runbook. List tables first, then query today's `stdout_*`:

```bash
bq ls class-6-5-tiqs:agentic_governance_evidence
```

`bq ls` can list them as dataset OWNER. `bq query` also needs `bigquery.jobs.create` on the project. Terraform already grants `roles/bigquery.jobUser` to `evidence-admin`. If a query still fails with `jobs.create`, grant it once as the Gmail project Owner, then impersonate and query:

```bash
unset CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT
gcloud config unset auth/impersonate_service_account
gcloud auth login   # Gmail project Owner, not $APPROVER_EMAIL

gcloud projects add-iam-policy-binding class-6-5-tiqs \
  --member="serviceAccount:evidence-admin@class-6-5-tiqs.iam.gserviceaccount.com" \
  --role="roles/bigquery.jobUser"

gcloud config set account "${APPROVER_EMAIL}"
export CLOUDSDK_PYTHON="/c/Python314/python.exe"
export CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT=evidence-admin@class-6-5-tiqs.iam.gserviceaccount.com
```

```bash
TABLE="$(bq ls --format=prettyjson class-6-5-tiqs:agentic_governance_evidence | python -c "import json,sys; print(next(t['tableReference']['tableId'] for t in json.load(sys.stdin) if str(t['tableReference']['tableId']).startswith('stdout_')))")"
if [[ -n "${TABLE}" ]]; then
  echo "Table: ${TABLE}"
  bq query --nouse_legacy_sql --max_rows=20 \
  "SELECT timestamp, jsonPayload.component, jsonPayload.event, jsonPayload.event_type, jsonPayload.incident_id, jsonPayload.governance_decision_id, jsonPayload.decision, jsonPayload.status, jsonPayload.policy.decision AS policy_decision, jsonPayload.action.action AS recommended_action FROM \`class-6-5-tiqs.agentic_governance_evidence.${TABLE}\` WHERE jsonPayload.component IS NOT NULL ORDER BY timestamp DESC LIMIT 20"
else
  echo "bq ls failed, so TABLE is empty; run gcloud auth login and re-run this block"
fi
```

There is no `jsonPayload.result`. BigQuery typed `jsonPayload` from the sink schema. Useful columns are `event`, `event_type`, `decision`, `status`, `policy.decision`, and `action.action`.

If `stdout_*` is empty, inspect `export_errors_*`. The same records are also in Cloud Logging. Unset impersonation first; `evidence-admin` cannot read logs:

```bash
unset CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT
gcloud config unset auth/impersonate_service_account
gcloud logging read \
  'resource.type="k8s_container" AND (jsonPayload.component="governance-agent" OR jsonPayload.component="approval-agent" OR jsonPayload.component="remediation-agent" OR jsonPayload.component="mcp-server")' \
  --project=class-6-5-tiqs \
  --limit=20 \
  --format='table(timestamp, jsonPayload.component, jsonPayload.incident_id, jsonPayload.event_type, jsonPayload.status)'
```

Unset impersonation before `kubectl` or Terraform:

```bash
unset CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT
gcloud config unset auth/impersonate_service_account
```

Confirm that governance, approval, remediation, and MCP records contain consistent identifiers where the event type has them. Not every stdout row is a decision record; many are `event=message_processed` heartbeats.

```text
component
event / event_type
incident_id
governance_decision_id
decision / policy.decision / status
action.action, action.target_namespace, action.target_deployment
approval_request_id, reviewer, key_version (approval rows)
timestamp
```

---

## **22. Key Rotation and Certificate Rotation**

### **Cloud KMS Approval Key**

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

### **MCP Certificates**

```bash
bash scripts/07-generate-mcp-mtls.sh

kubectl rollout restart deployment/mcp-gateway -n mcp-gateway
kubectl rollout restart deployment/mcp-server -n mcp
kubectl rollout restart deployment/remediation-agent -n ai-agents
```

---

## **23. Troubleshooting**

### **Terraform apply: 409 already exists, custom role deletion-pending, or node pool ERROR**

These are leftovers from a previous destroy or a partial apply. They are not random GCP outages.

| **Error**                                                     | **Why**                                                                                     | **Fix**                                                                                                               |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| **custom role `role_id` marked for deletion**                 | Role IDs stay reserved ~7 days                                                              | Code uses `prowlerStorageIamViewerV2`                                                                                 |
| **Workload Identity pool 409**                                | Pools are soft-deleted 30 days                                                              | `./scripts/03-adopt-retained-gcp.sh` imports `github-actions`                                                         |
| **KMS key ring or crypto key 409**                            | Key rings/keys cannot be fully deleted                                                      | Same script imports `agentic-governance` / `approval-signing` / `lab-cmek`                                            |
| **Secret / BQ / GCS CMEK `DESTROY_SCHEDULED` or `DESTROYED`** | Teardown keeps KMS keys unless `DESTROY_KMS_KEYS=yes` (last e2e: `lab-cmek` v9 primary)     | `03` restores or creates an ENABLED version and makes it primary (CMEK encrypt uses the primary). DESTROYED is final  |
| **BigQuery `allowedPolicyMemberDomains`**                     | Default dataset ACL includes consumer Google accounts                                       | Dataset OWNER is only `evidence-admin`; impersonate that SA from a Workspace user                                     |
| **KMS key version DESTROYED**                                 | Destroyed versions cannot sign                                                              | Pin the ENABLED signing version (currently `12`) in tfvars, the approval agent ConfigMap, and `11-review-approval.sh` |
| **Node pool `ERROR`**                                         | Failed bootstrap or datapath mismatch                                                       | Cluster uses Dataplane V2; script deletes the ERROR pool                                                              |

```bash
bash scripts/03-adopt-retained-gcp.sh
terraform -chdir=terraform plan -out=agentic.tfplan
terraform -chdir=terraform apply agentic.tfplan
```

### **Node pool stuck in PROVISIONING (`ZONE_RESOURCE_POOL_EXHAUSTED`)**

The VM is not coming up. GCE has no capacity for that machine type in that zone.
Terraform will sit on `Still creating...` until the create timeout.

Let the current apply fail or cancel it, then recreate the pool on `e2-standard-4` (the Terraform default) in the tfvars zone (`us-central1-c`):

```bash
gcloud container node-pools delete vertex-agent-lab-nodes \
  --cluster=vertex-agent-lab \
  --zone=us-central1-c \
  --project=class-6-5-tiqs \
  --quiet

terraform -chdir=terraform state rm google_container_node_pool.primary || true
terraform -chdir=terraform plan -out=agentic.tfplan
terraform -chdir=terraform apply agentic.tfplan
```

If `e2-standard-4` is also exhausted, set `zone` to another `us-central1-*` zone in `terraform.tfvars` and replace the cluster.

### **Windows Git Bash**

Do not paste workflow YAML, `<terraform output>`, or `<id>` into Git Bash. Angle brackets are redirection (`bash: id: No such file or directory`). `.github/workflows/*.yml` files run on GitHub, not locally.

`gcloud artifacts packages list --format=value(name)` emits CRLF. Strip `\r` before `packages delete` or the API looks up `app\r`.

The Unix `bq` wrapper looks for `python3.14` on `PATH`. Windows has `python.exe`, not that name. Pin Python or use `bq.cmd` only for short commands such as `ls`:

```bash
export CLOUDSDK_PYTHON="/c/Python314/python.exe"
bq ls --project_id=class-6-5-tiqs
```

Do not run `bq.cmd query` from Git Bash. It breaks on `C:\Program Files`. Use `bq query` with `CLOUDSDK_PYTHON` set and keep the SQL on one line.

Leave `CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT` unset except for BigQuery. If `kubectl` still authenticates as `evidence-admin`:

```bash
unset CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT
gcloud config unset auth/impersonate_service_account
rm -f "$HOME/.kube/gke_gcloud_auth_plugin_cache"
```

If `gke-gcloud-auth-plugin` then fails with permission denied on `%APPDATA%\gcloud\legacy_credentials\SIGNER_EMAIL\adc.json`, that folder has a broken NTFS ACL. Switch `gcloud config set account` to the Gmail project Owner for cluster admin, or take ownership of that directory in elevated PowerShell and `gcloud auth login --force`.

Two Cloud SDK installs (`Program Files (x86)` and Chocolatey) can disagree on config. `gcloud config list` from the same shell you use for `kubectl`.

### **Terraform: `connectex` / IPv6 OAuth token refresh**

Windows sometimes prefers IPv6 for `oauth2.googleapis.com`. Terraform then fails on `data.google_project` (often `19-github-actions-wif.tf`) with:

```text
Post "https://oauth2.googleapis.com/token": dial tcp [2607:f8b0:...]:443:
connectex: An attempt was made to access a socket in a way forbidden by its access permissions.
```

That is a workstation IPv6/firewall problem, not a bad WIF resource. Skip Terraform's token refresh by handing it a short-lived ADC token. Strip `\r` on Git Bash:

```bash
gcloud auth application-default print-access-token >/dev/null

export GOOGLE_OAUTH_ACCESS_TOKEN="$(
  gcloud auth application-default print-access-token | tr -d '\r'
)"

terraform -chdir=terraform plan -out=agentic.tfplan
terraform -chdir=terraform apply agentic.tfplan
```

The token lasts about one hour. Re-export it before apply if plan took a long time.
If `gcloud` itself cannot print a token, refresh ADC (`gcloud auth application-default login`) or retry on a network that allows IPv4 to `oauth2.googleapis.com`.

If ADC login itself fails on IPv6, prefer IPv4 for that shell:

```bash
export GOOGLE_CLOUD_USE_MTLS_ENDPOINT=never
curl -4 -sS -o /dev/null -w '%{http_code}\n' https://oauth2.googleapis.com
```

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

### **Pub/Sub PERMISSION_DENIED on approval review**

`11-review-approval.sh` pull/publish/ack must run as `$APPROVER_EMAIL` with impersonation off. `evidence-admin` has BigQuery only.

```bash
unset CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT
gcloud config unset auth/impersonate_service_account
gcloud config set account "${APPROVER_EMAIL}"
gcloud pubsub subscriptions get-iam-policy approval-requests-review-sub \
  --project=class-6-5-tiqs
```

The policy should include `user:$APPROVER_EMAIL` with `roles/pubsub.subscriber` and `roles/pubsub.viewer`. If it does not, apply Terraform with that member in `approval_signer_members`.

### **Pub/Sub messages stop moving**

```bash
gcloud pubsub subscriptions pull agent-events-dlq-sub \
  --project=class-6-5-tiqs \
  --limit=20 \
  --auto-ack \
  --format=json
```

Check the consumer Deployment logs and its subscription IAM role.

### **Pipeline stalls at the IR Analyst**

`10-test-pipeline.sh` times out and `analyzed-incidents` stays empty. Check the agent's model configuration and logs:

```bash
kubectl get configmap ir-analyst-agent-config -n ai-agents \
  -o jsonpath='{.data.MODEL}{" @ "}{.data.LOCATION}{"\n"}'
kubectl logs -n ai-agents deployment/ir-analyst-agent --tail=200
```

- **`404` / model `NOT_FOUND`.** The model was retired or isn't served in that location. `gemini-2.5-flash` is retired on Vertex AI from 2026-10-20. `gemini-3.8-flash` is served only from `global` (or the `us`/`eu` multi-regions), not `us-central1`. Update `MODEL` and `LOCATION` together in `manifests/ir-analyst-agent.yaml`, apply it, then `kubectl rollout restart deployment/ir-analyst-agent -n ai-agents`.
- **`Vertex AI returned an empty response (finish_reason=FinishReason.MAX_TOKENS)`.** The output budget ran out before the JSON completed. Raise it by adding `MAX_OUTPUT_TOKENS` (default `8192`) to the Deployment's environment. Don't put it in the ConfigMap: Trivy KSV-0109 flags ConfigMap keys containing "TOKEN".
- **`PERMISSION_DENIED` on `aiplatform`.** `vertex-gke-agent@` needs `roles/aiplatform.user` (Terraform `09-ir-analyst-agent-iam.tf`).

Messages that keep failing land in `agent-events-dlq-sub` (above).

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
KMS key version is ENABLED (currently version 12; versions 1–11 are DESTROYED)
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

container images are tagged `v1`. `broken-app` uses `app:v1`. Trivy and Prowler publisher sidecars use `scanner-publisher:v1`.

### **Postgres `password authentication failed` or empty DB password**

The Secret was rotated after Postgres already initialized PGDATA. Restore the original Secret or delete the postgres pod so emptyDir re-inits.

### **`Temporary failure in name resolution` after NetworkPolicies**

Allow kube-dns, node-local-dns, `10.112.0.10/32`, and `169.254.20.10/32`. ClusterIP-only DNS egress is not enough on Dataplane V2 with NodeLocal DNSCache.

### **VS Code cannot resolve any GitHub action**

Test connectivity:

```powershell
Test-NetConnection api.github.com -Port 443
```

Inspect the GitHub Actions extension output and reauthenticate. A warning against every action repository is an editor resolver problem, not evidence that every tag is invalid.

### **`You do not currently have an active account selected`**

`gcloud config set account "${APPROVER_EMAIL}"` ran while the variable was empty, which clears the active account. Every later `gcloud` call (including `09`) then fails. Export the variable and select the account again:

```bash
export APPROVER_EMAIL=YOUR_WORKSPACE_SIGNER   # replace with your Workspace signer's address
if [[ "${APPROVER_EMAIL:-}" == *@* ]]; then
  unset CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT
  gcloud config unset auth/impersonate_service_account
  gcloud config set account "${APPROVER_EMAIL}"
  gcloud auth list
else
  echo "APPROVER_EMAIL must be your Workspace signer's address, not '${APPROVER_EMAIL:-}'"
fi
```

If the account shows but calls still fail, run `gcloud auth login` as that account.

### **`11-review-approval.sh`: `REVIEWER is empty` or `Reason must be at least 10 characters`**

`REVIEWER is empty` means `APPROVER_EMAIL` is not exported in this terminal. The reason check prints the length it received. A bare usage line means the first argument was not `approve` or `deny`. Fix the argument and re-run. The pending request is untouched, so retry before its `expires_at` (30 minutes after `09`).

### **`Secret Payload cannot be empty`**

`SLACK_WEBHOOK_URL` is not set in this terminal, so `printf` sent an empty string. Load it with `read -rsp` as in section 19, then add the version again.

### **`13-release-images.sh`: `Required command not found: cosign`**

Expected on a workstation. Releases run in GitHub (section 24): local keyless signing would publish your own email to the public Rekor log. Use `gh workflow run release.yml`, then `gh run download` and `14` to deploy the digests.

### **`12-smoke-test-metrics.sh` prints `curl: (7) Failed to connect` and then passes**

Harmless, and silenced since 17 Oct 2026. The first health probe runs before `kubectl port-forward` is listening; the loop retries a second later. If the script fails with `Health check did not succeed`, check the port-forward log in `/tmp/agent-port-forward.log`.

### **`kubectl wait`: `jobs.batch "...-manual-..." not found`**

The job name was mistyped. Manual job names end in the Unix timestamp from creation (for example `prowler-manual-1792195188`). Copy it instead of retyping:

```bash
kubectl get jobs -n security -o name
kubectl wait --for=condition=complete "$(kubectl get jobs -n security -o name | grep prowler-manual | tail -1)" -n security --timeout=1800s
```

### **`09` returns `PERMIT` or `broken-app` restarts without an approval**

Controlled mode is still on (section 16). The `09` fixture meets every automatic threshold. Return both modes to `disabled` and restart the Governance and Remediation Agents.

### **`printenv EXECUTION_MODE` still prints `controlled` after reverting**

`kubectl exec deploy/remediation-agent` picked a pod from before the restart. Wait for `kubectl rollout status deployment/remediation-agent -n ai-agents`, then check again, or read the ConfigMap (section 16). The ConfigMap is what the new pods load.

### **`03`: `Error acquiring the state lock` / `Could not import ...`, then apply fails with WIF pool or KeyRing `409`**

Another Terraform command held the GCS state lock while `03` ran. In the 17 Oct 2026 run, a `plan`/`apply` started a minute before `03`: every import failed, and the apply, planned against empty state (`193 to add` instead of about 188), built the cluster and then failed with `409 Requested entity already exists` on `google_iam_workload_identity_pool.github_actions` and `google_kms_key_ring.governance`. Retained resources cannot be recreated, so nothing was lost.

`03` now exits non-zero when any import fails. Run Terraform commands one at a time, in order: `03`, then `plan`, then `apply`. To recover, let the other command finish (or cancel it), confirm the lock is gone, then re-run:

```bash
bash scripts/03-adopt-retained-gcp.sh
terraform -chdir=terraform plan -out=agentic.tfplan   # expect the remaining creates plus small in-place KMS label changes
terraform -chdir=terraform apply agentic.tfplan
```

Use `terraform -chdir=terraform force-unlock LOCK_ID` only if no Terraform process is still running (a crashed or killed run).

### **`04`: `failed commit on ref "layer-sha256:..."`: `net/http: timeout awaiting response headers`**

A transient Artifact Registry upload timeout on a large layer. Re-run `04`; layers already pushed are reused, so the second run is fast.

### **BigQuery: `Access Denied: Table class-6-5-tiqs:class-6-5-tiqs.agentic_governance_evidence`**

The table name in the query is empty. `TABLE` comes from `bq ls`; if that call failed (for example `You do not currently have an active account selected`), `TABLE` is blank and the query targets the dataset itself, which reads as a permission error. Fix auth (`gcloud auth login`), re-run the `TABLE=` line, and check `echo "${TABLE}"` prints `stdout_YYYYMMDD` before querying. The `evidence-admin` token-creator and `bigquery.jobUser` bindings are created by Terraform; you do not need to add them by hand.


### **`YOUR_WORKSPACE_SIGNER` shows up as an account, a user, or a reviewer**

`APPROVER_EMAIL` was exported with the literal placeholder. In the 17 Oct 2026 run this caused, in order: `gcloud config set account` made a nonexistent account active, so `09` and `bq` failed with `Your current active account [YOUR_WORKSPACE_SIGNER] does not have any valid credentials`; `gcloud auth login "${APPROVER_EMAIL}"` was rejected because the browser returned a different account; IAM failed with `User YOUR_WORKSPACE_SIGNER does not exist`; and two KMS-signed decisions recorded `YOUR_WORKSPACE_SIGNER` as the reviewer in the audit trail. Export the real address and use the guarded block in section 15. `11` now refuses a reviewer that is not an email address or does not match the active gcloud account.

### **`14` times out and pods show `ImagePullBackOff`**

The lock file names digests that no longer exist. Teardown deletes every Artifact Registry package, so a `release-evidence/` left from an earlier release still passes its checksum but points at deleted images. This happens when `gh run download` fails (a job ID instead of a run ID, or a failed release run with no artifact) and the old folder is still there. The old pods keep serving because the rollout never completes. Roll the Deployments back:

```bash
for nd in shared-services/event-aggregator ai-agents/observer-agent ai-agents/correlation-agent ai-agents/ir-analyst-agent ai-governance/governance-agent ai-governance/approval-agent ai-agents/remediation-agent ai-agents/reporting-agent mcp/mcp-server app01/broken-app; do kubectl rollout undo "deployment/${nd#*/}" -n "${nd%/*}"; done
```

Then download the lock from a successful run with the chained command in section 24. `14` now checks every digest before it changes anything.

### **Governed Release fails at `Trivy rejected .../mcp-server@sha256:...`**

A new HIGH or CRITICAL CVE with a fix is in the image, usually in the upstream `kubectl` binary. The job log does not list the CVE, and the failed step uploads no evidence. Scan the `v1` image locally with the gate's own settings to see it:

```bash
MSYS_NO_PATHCONV=1 docker run --rm -v //var/run/docker.sock:/var/run/docker.sock -v "$(cygpath -w "$PWD/.trivyignore-images.yaml"):/policy/.trivyignore-images.yaml:ro" aquasec/trivy:0.76.0 image --quiet --severity HIGH,CRITICAL --ignore-unfixed --ignorefile /policy/.trivyignore-images.yaml us-central1-docker.pkg.dev/class-6-5-tiqs/vertex-agent-lab/mcp-server:v1
```

If the finding is in `usr/local/bin/kubectl`, first check for a newer kubectl patch (`https://dl.k8s.io/release/stable-1.36.txt`). If there is none, add a path-scoped entry with an `expired_at` to `.trivyignore-images.yaml`, as was done for `CVE-2026-56851` on 17 Oct 2026. Anything outside kubectl gets fixed in the image instead.
### **Governed Release exits 126**

Exit `126` means the runner found the script but could not execute it (missing `+x` or CRLF line endings from a Windows commit). The workflow invokes `bash scripts/13-release-images.sh` and `bash scripts/14-deploy-release-images.sh`. `.gitattributes` forces LF on `*.sh`. Re-dispatch after those files are on `main`:

```bash
gh workflow run release.yml -f tag=v1 -f deploy=false
```

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

The image scan fails on any fixable HIGH or CRITICAL finding. Exceptions live in `.trivyignore-images.yaml` (not the repository-scan `.trivyignore.yaml`). Each entry is scoped to a file path and has an `expired_at` date. The scan records suppressed findings as `ignored` in `release-evidence/trivy/*.json`.

Current exception: four CVEs in the upstream `kubectl` binary of the `mcp-server` image (three in the Go standard library and `x/net`, plus `CVE-2026-56851` in `golang.org/x/text`, added 17 Oct 2026), expiring `2026-11-15`. If `13` fails with `Trivy rejected .../mcp-server@...` after that date, check for a newer kubectl 1.36 patch release. Pin it in `docker/mcp_docker.txt` (`KUBECTL_VERSION`) and remove the entries. If none is out yet, review and extend the dates deliberately.

Do not run `13` locally. It needs `cosign` (`Required command not found: cosign` otherwise), and keyless signing on a workstation signs with your own Google identity and publishes that email to the public Rekor log. Run it through the workflow:

```bash
gh workflow run release.yml -f tag=v1 -f deploy=false
gh run watch $(gh run list -w release.yml -L 1 --json databaseId -q '.[0].databaseId')
```

Deploy the verified digests from your workstation. GitHub-hosted runners are not in `authorized_networks`, so the workflow's own `deploy` job cannot reach the control plane. Only use a run whose `release` job succeeded (a failed run uploads no artifact), and pass the run ID from `gh run list -w release.yml`, not a job ID. Clear the old evidence first and chain the steps, so a failed download cannot fall through to a stale lock file:

```bash
rm -rf release-evidence && gh run download RUN_ID -n release-v1 -D release-evidence && [[ "$(sha256sum release-evidence/image-lock.json | cut -c1-64)" == "$(cut -c1-64 release-evidence/image-lock.sha256)" ]] && bash scripts/14-deploy-release-images.sh release-evidence/image-lock.json
```

The checksum proves the lock file was not altered, not that it is current. `14` therefore checks that every digest exists in Artifact Registry before it changes any Deployment.

Running `04` after a release moves the mutable `v1` tag back to unsigned local builds. The signed release is only what `14` pins by digest. The in-cluster Trivy CronJob scans `:v1`.

`14` fails with `Image lock file not found` if you skip `13` (or skip downloading the GitHub Actions `release-*` artifact). Run `13` first, or copy `image-lock.json` from the workflow artifact into `release-evidence/`.

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
CONFIRM_TEARDOWN=yes bash scripts/15-teardown.sh
```

The script does the following:

- clears impersonation;
- deletes the lab namespaces, including Helm `falco`;
- empties Artifact Registry (stripping Git Bash `\r`);
- deletes the evidence dataset as `evidence-admin`, and removes it from Terraform state only if the delete succeeded;
- releases the KMS key ring and keys from Terraform state so they keep their versions;
- applies a destroy plan;
- removes the cluster's kubeconfig entry.

It finds an interpreter for the `bq` wrapper automatically (`C:\Python312`, `313`, or `314`).

The KMS keys are retained because destroying a `google_kms_crypto_key` cannot delete the key; it destroys every key version instead. That used to force a new approval-signing version, and new `approval_key_version` pins, on every rebuild. Now the ENABLED version survives, and `03-adopt-retained-gcp.sh` re-imports it unchanged. Their IAM bindings are still destroyed. To destroy all versions anyway, add `DESTROY_KMS_KEYS=yes`.

Skip a stage with `SKIP_KUBERNETES=yes`, `SKIP_ARTIFACT_REGISTRY=yes`,
`SKIP_BIGQUERY=yes`, or `SKIP_TERRAFORM=yes`.

Manual equivalent if you need to run the stages separately:

Clear BigQuery impersonation first. `kubectl` uses `gke-gcloud-auth-plugin`, which caches the last token. If you still see `User "evidence-admin@..."` in Forbidden errors:

```bash
unset CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT
gcloud config unset auth/impersonate_service_account
rm -f "$HOME/.kube/gke_gcloud_auth_plugin_cache"
gcloud config get-value account
```

Use the Gmail project Owner for this step if the Workspace account cannot write `legacy_credentials\...\adc.json`.

```bash
kubectl delete namespace \
  app01 \
  security \
  shared-services \
  ai-agents \
  ai-governance \
  mcp \
  mcp-gateway \
  falco \
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

### **25.4 Destroy Infrastructure**

The evidence dataset ACL is only `evidence-admin`. Terraform running as a user cannot delete its tables (`bigquery.tables.delete` denied). Delete the dataset as that SA first, then destroy:

```bash
export CLOUDSDK_PYTHON="/c/Python314/python.exe"   # any installed 3.12-3.14
export CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT=evidence-admin@class-6-5-tiqs.iam.gserviceaccount.com
bq rm -r -f class-6-5-tiqs:agentic_governance_evidence
unset CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT

# Only after bq rm succeeded:
terraform -chdir=terraform state rm google_bigquery_dataset_access.governance_sink_writer
terraform -chdir=terraform state rm google_bigquery_dataset.governance_evidence

# Retain KMS keys so their versions are not destroyed:
terraform -chdir=terraform state rm google_kms_crypto_key.approval_signing
terraform -chdir=terraform state rm google_kms_crypto_key.lab_cmek
terraform -chdir=terraform state rm google_kms_key_ring.governance

terraform -chdir=terraform plan -destroy -out=destroy.tfplan
terraform -chdir=terraform show destroy.tfplan
terraform -chdir=terraform apply destroy.tfplan
```

KMS key rings cannot be deleted, and the keys are retained as above. Workload Identity pools and custom IAM role IDs stay reserved for days after destroy. The next apply should run `./scripts/03-adopt-retained-gcp.sh` first, or it will 409/400 on those names.

### **25.5 Remove local generated files**

```bash
rm -rf terraform/.terraform
rm -f terraform/*.tfplan
rm -rf release-evidence
rm -f trivy-results.sarif
```

Keep:

```text
terraform/.terraform.lock.hcl
terraform/terraform.tfvars          gitignored; holds your real CIDR, signer, and KMS version
terraform/terraform.tfvars.example
```

Deleting `terraform.tfvars` means the next rebuild starts from the example's placeholders. Terraform now rejects the placeholder signer and the `203.0.113.x` CIDR at plan time, but keeping the file avoids re-entering them. Update its CIDR if your public IP changed.

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

export CLOUDSDK_PYTHON="/c/Python314/python.exe"
bq ls --project_id=class-6-5-tiqs

helm list -n falco
kubectl get namespace falco
```

Some APIs and retained audit data may intentionally remain depending on Terraform configuration and organizational retention requirements.

---

## **26. Completion Checklist**

```text
[ ] Local tfvars created and ignored (zone us-central1-c, KMS version 12)
[ ] Administrator CIDR updated
[ ] Approval signer is a Workspace user in the allowed org domain
[ ] Python test deps installed (`requirements-test.txt` + `requirements-approval-agent.txt`)
[ ] Validation passed (`bash scripts/01-validate.sh`)
[ ] Terraform initialized against gs://tiqs-kubernetes/agentic/terraform/state
[ ] State vs live GCP checked; `03-adopt-retained-gcp.sh` only for WIF/KMS/ERROR pool
[ ] Terraform plan reviewed and applied (`terraform apply agentic.tfplan`)
[ ] GKE credentials obtained for us-central1-c
[ ] Eleven v1 images built and pushed, including app and scanner-publisher
[ ] Falco installed in namespace falco (Helm chart 9.1.0)
[ ] Platform deployed (`08-deploy.sh`)
[ ] All Deployments ready (broken-app uses app:v1; Postgres connected)
[ ] NetworkPolicies present (DNS includes node-local-dns and 169.254.20.10)
[ ] PodMonitoring, HPAs, and PDBs present
[ ] Trivy and Prowler CronJobs present and a manual Job succeeded
[ ] Governance smoke test returned REQUIRE_APPROVAL
[ ] End-to-end pipeline test produced an incident report
[ ] Cloud KMS approval signed with key version 12 as the Workspace signer
[ ] BigQuery evidence listed via evidence-admin impersonation (table name from `bq ls`)
[ ] Automated execution remains disabled or was explicitly approved
[ ] If controlled mode was tested: action confirmed in MCP logs, both modes back to disabled
[ ] Optional Slack: report shows "status": "sent"; reporting-agent.yaml restored to ENABLE_SLACK "false"
[ ] GitHub CI passed
[ ] Release evidence generated and retained (build-only run from GitHub, not local 13)
[ ] Signed digests deployed with 14 from the downloaded artifact (lock checksum matched)
[ ] `git checkout -- manifests/` so no controlled or Slack edits are committed
[ ] Teardown verified when the lab is complete (`CONFIRM_TEARDOWN=yes bash scripts/15-teardown.sh`)
```
