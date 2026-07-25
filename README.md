# **Agentic AI on GKE — Governed Multi-Agent Security Platform**

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.10.0-623CE4?style=for-the-badge&logo=terraform&logoColor=white)
![GKE](https://img.shields.io/badge/GKE-Workload_Identity-4285F4?style=for-the-badge&logo=googlekubernetesengine&logoColor=white)
![Vertex AI](https://img.shields.io/badge/Vertex_AI-Gemini_2.5-4285F4?style=for-the-badge&logo=googlecloud&logoColor=white)
![OPA](https://img.shields.io/badge/OPA-Deterministic_Governance-7D64FF?style=for-the-badge&logo=openpolicyagent&logoColor=white)
![Cloud KMS](https://img.shields.io/badge/Cloud_KMS-Signed_Approvals-4285F4?style=for-the-badge&logo=googlecloud&logoColor=white)
![mTLS](https://img.shields.io/badge/mTLS-MCP_Gateway-003459?style=for-the-badge&logo=nginx&logoColor=white)
![GitHub Actions](https://img.shields.io/badge/GitHub_Actions-Keyless_Release-2088FF?style=for-the-badge&logo=githubactions&logoColor=white)

> **Status: configuration-ready for Phase 5 deployment.**  
> This repository is a student portfolio lab that demonstrates a production-minded,
> governed security-response workflow on Google Kubernetes Engine. Automated remediation,
> Slack delivery, and Jira delivery are disabled by default.

## **Table of contents**

- [Project summary](#project-summary)
- [Business value](#business-value)
- [Architecture](#architecture)
- [Security model](#security-model)
- [Technology stack](#technology-stack)
- [Repository structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [CI/CD and software supply chain](#cicd-and-software-supply-chain)
- [Validation](#validation)
- [Human approval workflow](#human-approval-workflow)
- [Controlled remediation](#controlled-remediation)
- [Observability and evidence](#observability-and-evidence)
- [Windows and VS Code notes](#windows-and-vs-code-notes)
- [Cleanup](#cleanup)
- [Scope and limitations](#scope-and-limitations)
- [Author](#author)

## **Project summary**

The platform receives security telemetry, correlates related signals, uses Gemini to assist
with incident analysis, applies deterministic Open Policy Agent policy, obtains a
Cloud KMS-signed human approval when required, and permits a tightly scoped Kubernetes
action only after every governance control passes.

The system deliberately separates:

- **Analysis** — Gemini helps explain an incident and recommend a response.
- **Authorization** — OPA and deterministic application logic decide whether the action
  is denied, permitted, or requires approval.
- **Approval** — Cloud KMS binds an authorized reviewer to an exact request.
- **Execution** — the Remediation Agent and MCP security boundary independently verify
  the authorization before any Kubernetes action occurs.
- **Evidence** — Pub/Sub, Firestore, Cloud Logging, Cloud Monitoring, and BigQuery retain
  operational and governance evidence.

This is not an unrestricted autonomous agent. It is a controlled security automation lab.

## **Business value**

The project models a common enterprise problem: security teams receive more alerts than
analysts can investigate manually, but organizations cannot safely allow an AI model to
make unrestricted infrastructure changes.

This architecture shows how an organization can:

- reduce alert-triage time with AI-assisted analysis;
- preserve deterministic authorization and least privilege;
- require cryptographically signed human approval for sensitive actions;
- prevent duplicate execution and approval replay;
- keep a durable audit trail for incident review and compliance;
- deliver signed, scanned, and attestable container images without long-lived CI keys.

## **Architecture**

```text
Falco / Trivy / Prowler / Cloud Logging / Security Command Center
  |
  v
raw-security-events
  |
  v
Event Aggregator
  |
  v
security-findings
  |
  v
Observer Agent
  |
  v
observed-findings
  |
  v
Correlation Agent + Firestore
  |
  v
correlated-incidents
  |
  v
IR Analyst Agent + Vertex AI / Gemini
  |
  v
analyzed-incidents
  |
  v
Governance Agent + OPA
  |
  +--> DENY / NO_ACTION
  |
  +--> PERMIT
  |
  +--> REQUIRE_APPROVAL
          |
          v
      approval-requests
          |
          v
      Human reviewer + Cloud KMS signature
          |
          v
      approval-decisions
          |
          v
      Approval Agent
          |
          v
governance-decisions
  |
  v
Remediation Agent
  |
  v
MCP Gateway over mTLS
  |
  v
MCP Server with namespace-scoped Kubernetes RBAC
  |
  v
approved Kubernetes action in app01
  |
  v
remediation-results
  |
  v
Reporting Agent
  |
  +--> incident-reports
  +--> optional Slack / Jira
  +--> BigQuery governance evidence
```

### **Runtime namespaces**

| **Namespace**     | **Purpose**                                                          |
|-------------------|----------------------------------------------------------------------|
| `app01`           | Demo application, PostgreSQL, and the only remediation target        |
| `security`        | Trivy and Prowler scanner identities and scheduled workloads         |
| `shared-services` | Event Aggregator and telemetry normalization                         |
| `ai-agents`       | Observer, Correlation, IR Analyst, Remediation, and Reporting Agents |
| `ai-governance`   | Governance Agent, Approval Agent, and OPA policy evaluation          |
| `mcp`             | MCP Server and its namespace-scoped Kubernetes permissions           |
| `mcp-gateway`     | Isolated nginx mTLS gateway and client-certificate trust boundary    |

## **Security model**

### **Fail-closed defaults**

```yaml
Governance Agent:
  AUTOMATION_MODE: disabled

Remediation Agent:
  EXECUTION_MODE: disabled

Reporting Agent:
  ENABLE_SLACK: "false"
  ENABLE_JIRA: "false"
```

### **Enforcement controls**

The platform applies the following controls before execution:

1. The requested action must be supported.
2. The namespace and deployment must be explicitly allowlisted.
3. The governance policy identifier and policy SHA-256 must match.
4. Severity, confidence, evidence count, and operational-risk controls must pass.
5. A human approval must be present when policy requires it.
6. The approval must be signed by the configured Cloud KMS key version.
7. The approval must match the request hash and governance decision.
8. The approval must not be expired or replayed.
9. Firestore must show that the request has not already been executed.
10. The MCP gateway must accept the Remediation Agent client certificate.
11. The MCP Server must independently accept the governance source and target.
12. Kubernetes RBAC must authorize only the required operation in `app01`.

Critical incidents require signed human approval by default.

### **Identity and access**

- GKE Workload Identity maps each Kubernetes service account to a dedicated Google
  service account.
- Agents receive only the Pub/Sub, Firestore, KMS, Secret Manager, BigQuery, or Vertex AI
  permissions required by their role.
- The MCP Server holds the Kubernetes permissions used by the remediation broker.
- Only the Remediation Agent receives an MCP client certificate.
- GitHub Actions uses Workload Identity Federation instead of a stored Google service
  account key.
- GitHub release RBAC is namespace-scoped and permits only the required Deployment and
  scanner CronJob updates.

## **Technology stack**

| **Layer**                       | **Technology**                                         |
|---------------------------------|--------------------------------------------------------|
| **Cloud**                       | Google Cloud                                           |
| **Kubernetes**                  | GKE, Workload Identity, Calico NetworkPolicy           |
| **Infrastructure as code**      | Terraform                                              |
| **Event transport**             | Pub/Sub with retries and dead-letter topics            |
| **AI analysis**                 | Vertex AI, Gemini 2.5 Flash                            |
| **Deterministic governance**    | OPA/Rego plus Python enforcement                       |
| **State and replay prevention** | Firestore                                              |
| **Approval signing**            | Cloud KMS asymmetric signing                           |
| **Remediation boundary**        | MCP Server behind nginx mTLS gateway                   |
| **Audit evidence**              | Cloud Logging and BigQuery                             |
| **Metrics**                     | Managed Service for Prometheus and Cloud Monitoring    |
| **Scanning**                    | Falco, Trivy, Prowler                                  |
| **CI/CD**                       | GitHub Actions and Google Workload Identity Federation |
| **Supply-chain controls**       | Trivy, Syft, Cosign, immutable image digests           |
| **Language**                    | Python 3.11                                            |

## **Repository structure**

```text
agentic/
├── .github/
│   ├── dependabot.yml
│   └── workflows/
│       ├── phase5-ci.yml
│       └── phase5-release.yml
│
├── docker/
│   ├── aggregator
│   ├── app
│   ├── approval_agent
│   ├── cert_guardian_agent
│   ├── correlation_agent
│   ├── governance_agent
│   ├── ir_analyst_agent
│   ├── mcp_docker.txt
│   ├── observer_agent
│   ├── remediation_agent
│   ├── reporting_agent
│   └── scanner_publisher
│
├── docs/
│   ├── architecture/
│   │   ├── api_gateway_comparison.md
│   │   ├── architecture.md
│   │   ├── high-level-architecture.md
│   │   ├── mcp-architecture.md
│   │   ├── namespace-architecture.md
│   │   └── pod-architecture.md
│   │
│   ├── concepts/
│   │   ├── deterministic-governance.md
│   │   ├── introduction.md
│   │   └── mcp-security.md
│   │
│   └── RUNBOOK.md
│
├── examples/
│   ├── gatekeeper/
│   │   ├── kubernetescommunication.yaml
│   │   ├── namespace-communication.yaml
│   │   └── rbac.yaml
│   │
│   ├── logging/
│   │   └── structured-logging-demo.yaml
│   │
│   ├── secrets/
│   │   ├── db-secret.yaml
│   │   ├── external-secret-annotations.yaml
│   │   ├── logging-demo.yaml
│   │   ├── secret-pod.yaml
│   │   └── secret-store.yaml
│   │
│   └── vulnerable-workloads/
│       └── [contents not expanded in screenshot]
│
├── helm/
│   └── falco/
│       └── values.yaml
│
├── manifests/
│   ├── network-policies/
│   │   ├── ai-agents-egress.yaml
│   │   ├── ai-governance.yaml
│   │   ├── app01.yaml
│   │   ├── event-aggregator.yaml
│   │   ├── managed-prometheus-ingress.yaml
│   │   ├── mcp-gateway-egress.yaml
│   │   ├── mcp-gateway-ingress.yaml
│   │   ├── mcp-server-ingress.yaml
│   │   └── security-scanners.yaml
│   │
│   ├── observability/
│   │   ├── phase5-agent-podmonitoring.yaml
│   │   └── phase5-governance-podmonitoring.yaml
│   │
│   ├── rbac/
│   │   └── github-release-deployer.yaml
│   │
│   ├── reliability/
│   │   ├── phase5-governance-hpa.yaml
│   │   ├── phase5-governance-pdb.yaml
│   │   ├── phase5-hpa.yaml
│   │   └── phase5-pdb.yaml
│   │
│   ├── approval-agent.yaml
│   ├── broken-app.yaml
│   ├── correlation-agent.yaml
│   ├── event-aggregator.yaml
│   ├── governance-agent.yaml
│   ├── ir-analyst-agent.yaml
│   ├── limitrange-app01.yaml
│   ├── mcp-deployment.yaml
│   ├── mcp-gateway-deployment.yaml
│   ├── mcp-gateway-sa.yaml
│   ├── mcp-gateway-service.yaml
│   ├── mcp-nginx-config.yaml
│   ├── mcp-server-config.yaml
│   ├── mcp-server-rbac.yaml
│   ├── mcp-server-sa.yaml
│   ├── namespaces.yaml
│   ├── observer-agent.yaml
│   ├── postgres-secret.yaml
│   ├── postgres.yaml
│   ├── prowler-cronjob.yaml
│   ├── prowler-ksa.yaml
│   ├── remediation-agent.yaml
│   ├── reporting-agent.yaml
│   ├── resourcequota-app01.yaml
│   ├── trivy-cronjob.yaml
│   └── trivy-ksa.yaml
│
├── policy/
│   ├── conftest/
│   │   └── kubernetes-security.rego
│   │
│   └── governance/
│       ├── remediation.rego
│       └── remediation_test.rego
│
├── python/
│   ├── tests/
│   │   ├── conftest.py
│   │   ├── test_approval_signature.py
│   │   ├── test_governance_common.py
│   │   ├── test_governance_input.py
│   │   ├── test_metrics_support.py
│   │   ├── test_observer_agent.py
│   │   └── test_remediation_policy.py
│   │
│   ├── .dockerignore
│   ├── agent_runtime.py
│   ├── aggregator.py
│   ├── app.py
│   ├── approval_agent.py
│   ├── correlation_agent.py
│   ├── governance_agent.py
│   ├── governance_common.py
│   ├── governance_models.py
│   ├── ir_analyst_agent.py
│   ├── mcp_server.py
│   ├── metrics_support.py
│   ├── observer_agent.py
│   ├── remediation_agent.py
│   ├── reporting_agent.py
│   ├── scanner_publisher.py
│   ├── requirements-aggregator.txt
│   ├── requirements-app.txt
│   ├── requirements-approval-agent.txt
│   ├── requirements-correlation-agent.txt
│   ├── requirements-governance-agent.txt
│   ├── requirements-ir-analyst-agent.txt
│   ├── requirements-mcp-server.txt
│   ├── requirements-observer-agent.txt
│   ├── requirements-remediation-agent.txt
│   ├── requirements-reporting-agent.txt
│   ├── requirements-scanner-publisher.txt
│   └── requirements-test.txt
│
├── scripts/
│   ├── build-phase5-images.sh
│   ├── create-demo-secret.sh
│   ├── deploy-phase5-images.sh
│   ├── deploy-phase5.sh
│   ├── generate-mcp-mtls.sh
│   ├── install-falco.sh
│   ├── phase5-release-images.sh
│   ├── phase5-validate.sh
│   ├── review-phase5-approval.sh
│   ├── smoke-test-metrics.sh
│   ├── test-phase5-governance.sh
│   └── test-pipeline.sh
│
├── terraform/
│   ├── terraform/
│   │   └── [nested directory not expanded in screenshot]
│   │
│   ├── .terraform.lock.hcl
│   ├── 0-variables.tf
│   ├── 1-provider.tf
│   ├── 2-network.tf
│   ├── 3-artifact-registry.tf
│   ├── 4-gke.tf
│   ├── 5-node-pool.tf
│   ├── 6-runtime.tf
│   ├── 7-pubsub.tf
│   ├── 8-ir-analyst-agent-iam.tf
│   ├── 9-mcp-server-iam.tf
│   ├── 10-telemetry-agent-iam.tf
│   ├── 11-multi-agent-iam.tf
│   ├── 12-observer-agent-iam.tf
│   ├── 13-agent-pubsub.tf
│   ├── 14-logging-sink.tf
│   ├── 15-security-command-center.tf
│   ├── 16-firestore.tf
│   ├── 17-reporting-secrets.tf
│   ├── 18-github-actions-wif.tf
│   ├── 19-phase4-observability.tf
│   ├── 20-phase5-governance-iam.tf
│   ├── 21-phase5-kms.tf
│   ├── 22-phase5-state.tf
│   ├── 23-phase5-evidence.tf
│   ├── 24-outputs.tf
│   └── terraform.tfvars
│
├── .gitignore
└── README.md
```

## **Prerequisites**

| **Tool**              | **Purpose**                                                     |
|-----------------------|-----------------------------------------------------------------|
| Terraform `>= 1.10.0` | Provision Google Cloud infrastructure                           |
| Google Cloud CLI      | Authentication, GKE access, Pub/Sub, KMS, and Artifact Registry |
| `kubectl`             | Kubernetes deployment and verification                          |
| Docker with Buildx    | Build Phase 5 images locally                                    |
| Python 3.11           | Tests, validation, secret generation, and helper scripts        |
| OpenSSL               | Generate the MCP server and client certificate authorities      |
| OPA                   | Run governance policy tests                                     |
| Conftest              | Validate Kubernetes objects against repository policy           |
| Helm                  | Install Falco                                                   |
| Trivy                 | Repository and image security scanning                          |
| Syft                  | Generate SPDX SBOMs during release                              |
| Cosign                | Keyless image signing and SBOM attestation                      |
| Bash                  | Run repository automation scripts                               |

The Terraform backend uses:

```hcl
bucket = "tiqs-kubernetes"
prefix = "agentic/terraform/state"
```

The GCS backend bucket must exist before `terraform init`, or the backend configuration must be changed to a bucket you control.

## **Quick start**

### 1. Authenticate

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project class-6-5-tiqs
```

### 2. Create local Terraform variables

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Replace the documentation values in `terraform/terraform.tfvars`:

```text
203.0.113.10/32
user:replace-with-reviewer@example.com
```

`terraform.tfvars` is ignored and must not be committed.

### 3. Validate the repository

```bash
chmod +x scripts/*.sh
./scripts/phase5-validate.sh
```

### 4. Provision the infrastructure

```bash
terraform -chdir=terraform init
terraform -chdir=terraform fmt -recursive
terraform -chdir=terraform validate
terraform -chdir=terraform plan -out=phase5.tfplan
terraform -chdir=terraform apply phase5.tfplan
```

### 5. Obtain cluster credentials

```bash
gcloud container clusters get-credentials vertex-agent-lab \
  --zone us-central1-a \
  --project class-6-5-tiqs
```

### 6. Build and push images

```bash
PROJECT_ID=class-6-5-tiqs \
REGION=us-central1 \
REPOSITORY=vertex-agent-lab \
TAG=phase5-v1 \
./scripts/build-phase5-images.sh
```

The image inventory is:

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

### 7. Install Falco

```bash
./scripts/install-falco.sh
```

### 8. Deploy Phase 5

```bash
./scripts/deploy-phase5.sh
```

The deploy script:

- creates the namespaces;
- mounts the governance policy as ConfigMaps;
- creates the demo PostgreSQL Secret without committing its password;
- generates and rotates MCP mTLS material;
- applies service accounts and RBAC;
- deploys the MCP gateway, MCP Server, demo application, and all agents;
- waits for the Deployments to become ready;
- applies NetworkPolicies, PodMonitoring, HPAs, PDBs, and scanner CronJobs.

Automated remediation remains disabled after deployment.

Full commands, validation checks, approval handling, and teardown steps are documented in [`docs/RUNBOOK.md`](docs/RUNBOOK.md).

## **CI/CD and software supply chain**

Only these workflows are active:

```text
.github/workflows/phase5-ci.yml
.github/workflows/phase5-release.yml
```

### **Phase 5 CI**

The CI workflow performs:

- Python dependency installation;
- Python compilation and unit testing;
- Kubernetes and workflow YAML parsing;
- Bash syntax checks;
- Terraform formatting and validation;
- OPA policy tests;
- Conftest Kubernetes policy checks;
- Trivy filesystem vulnerability, secret, and misconfiguration scanning;
- SARIF upload when GitHub permits security-event publication.

### **Governed release**

The release workflow:

1. authenticates to Google Cloud through GitHub OIDC and Workload Identity Federation;
2. builds the Phase 5 images;
3. scans images for qualifying HIGH and CRITICAL vulnerabilities;
4. generates SPDX SBOMs with Syft;
5. signs immutable image digests with Cosign;
6. attaches SBOM attestations;
7. verifies signature identity and OIDC issuer;
8. writes `release-evidence/image-lock.json`;
9. uploads release evidence;
10. optionally updates GKE workloads by immutable digest.

Required GitHub repository variables:

```text
GCP_PROJECT_ID
GCP_WIF_PROVIDER
GCP_RELEASE_SERVICE_ACCOUNT
GKE_CLUSTER_NAME
GKE_CLUSTER_LOCATION
```

The `production` GitHub environment should require reviewer approval before deployment.

## **Validation**

### **Local static validation**

```bash
./scripts/phase5-validate.sh
```

This requires Python, pytest, Terraform, OPA, and Conftest.

### **Governance smoke test**

```bash
./scripts/test-phase5-governance.sh
```

Expected result:

```text
REQUIRE_APPROVAL
policy.approved = false
no remediation authorized
```

### **Metrics smoke test**

```bash
./scripts/smoke-test-metrics.sh
```

### **End-to-end governed pipeline test**

```bash
./scripts/test-pipeline.sh
```

This publishes two correlated synthetic findings and waits for the final incident report.

### **Core status checks**

```bash
kubectl get deployments -A
kubectl get pods -A -o wide
kubectl get networkpolicy -A
kubectl get podmonitoring -A
kubectl get hpa -A
kubectl get pdb -A
kubectl get cronjob -n security
```

## **Human approval workflow**

List pending approval requests:

```bash
gcloud pubsub subscriptions pull approval-requests-review-sub \
  --project=class-6-5-tiqs \
  --limit=5 \
  --format=json
```

Review and sign the next request:

```bash
./scripts/review-phase5-approval.sh \
  approve \
  "analyst@example.com" \
  "Approved after reviewing the correlated evidence and proposed target."
```

Deny a request:

```bash
./scripts/review-phase5-approval.sh \
  deny \
  "analyst@example.com" \
  "Denied because the proposed action requires additional investigation."
```

The script:

- pulls one pending approval request;
- displays its incident and binding data;
- requires interactive confirmation;
- creates a short-lived decision envelope;
- signs it with the configured Cloud KMS key version;
- publishes the signed decision;
- acknowledges the original request only after publication succeeds.

## **Controlled remediation**

Keep the platform in dry-run mode until policy, approval, and evidence validation pass.

To permit controlled execution, update:

```yaml
# manifests/governance-agent.yaml
AUTOMATION_MODE: controlled
```

```yaml
# manifests/remediation-agent.yaml
EXECUTION_MODE: controlled
```

Then apply and restart:

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

Enabling these flags does not bypass the policy, approval, replay, allowlist, mTLS, MCP, or
RBAC controls.

## **Observability and evidence**

Each long-running agent exposes health and Prometheus metrics, including:

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

Phase 5 also provisions:

- Managed Service for Prometheus;
- PodMonitoring objects;
- Cloud Monitoring dashboards;
- Pub/Sub backlog and oldest-message alerts;
- approval-request backlog alerts;
- dead-letter monitoring;
- BigQuery governance evidence storage;
- Firestore correlation, approval, and execution state.

Optional Slack and Jira integrations use Secret Manager containers. Terraform does not
store the secret values.

## **Windows and VS Code notes**

### **GitHub Actions editor diagnostics**

The repository uses:

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

If VS Code reports that every action is unresolved, the problem is normally the local GitHub Actions extension, authentication, API rate limit, proxy, VPN, DNS, TLS inspection, or access to `api.github.com`. Repeatedly changing valid action versions does not repair a resolver that cannot access GitHub.

Use the GitHub Actions output channel, `actionlint`, or an actual GitHub workflow run as the authoritative validation.

### **Git Bash path conversion**

When a command contains Linux paths beginning with `/`, Git Bash may rewrite them into Windows paths. Use:

```bash
MSYS_NO_PATHCONV=1 command ...
```

where required.

### **Public GKE endpoint**

If the workstation public IP changes, update the ignored `terraform/terraform.tfvars` entry under `authorized_networks`, then reapply Terraform.

## **Cleanup**

Delete Kubernetes workloads and namespaces:

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

Delete Artifact Registry image packages before destroying the repository resource:

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

Destroy Terraform-managed infrastructure:

```bash
terraform -chdir=terraform plan -destroy -out=destroy.tfplan
terraform -chdir=terraform apply destroy.tfplan
rm -f terraform/destroy.tfplan terraform/phase5.tfplan
```

## **Scope and limitations**

This is a student lab and portfolio project. It demonstrates professional architecture
patterns but is not presented as a production-ready managed security product.

Before enterprise use, the platform would require additional work such as:

- organization-specific threat models and policies;
- private GKE control-plane design;
- managed certificate lifecycle and rotation;
- formal key custody and reviewer separation;
- policy and application performance testing;
- disaster recovery and state-backup procedures;
- service-level objectives and on-call integration;
- independent penetration testing;
- cost controls and retention governance;
- production change-management approval.

## **Author**

| **Role** | **Name** |
|----------|----------|
| Author   | T.I.Q.S. |
