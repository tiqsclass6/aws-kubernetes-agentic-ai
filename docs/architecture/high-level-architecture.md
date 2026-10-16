# **High Level Architecture**

Live lab stack. GitHub Actions and Workload Identity Federation feed Artifact Registry. GKE Dataplane V2 enforces NetworkPolicy. Gemini assists analysis only. OPA, Cloud KMS, mTLS, and MCP authorize and execute.

```text
                         ┌─────────────────────┐
                         │  Developers / CI    │
                         │ GitHub Actions + WIF│
                         └─────────┬───────────┘
                                   │
                                   ▼
                    ┌──────────────────────────┐
                    │ Artifact Registry        │
                    │ v1 tags / signed digests │
                    └─────────┬────────────────┘
                              │
                              ▼
                  ┌────────────────────────────┐
                  │  GKE vertex-agent-lab      │
                  │  Dataplane V2 / WI         │
                  │                            │
                  │ ┌────────────────────────┐ │
                  │ │ app01 workloads        │ │
                  │ │ broken-app + Postgres  │ │
                  │ └────────────────────────┘ │
                  │                            │
                  │ ┌────────────────────────┐ │
                  │ │ Falco (helm / falco)   │ │
                  │ └────────────────────────┘ │
                  │                            │
                  │ ┌────────────────────────┐ │
                  │ │ Trivy / Prowler Jobs   │ │
                  │ └────────────────────────┘ │
                  │                            │
                  │ ┌────────────────────────┐ │
                  │ │ OPA governance policy  │ │
                  │ └────────────────────────┘ │
                  │                            │
                  │ ┌────────────────────────┐ │
                  │ │ MCP mTLS Gateway       │ │
                  │ └────────────────────────┘ │
                  └────────────┬───────────────┘
                               │
                               ▼
              ┌────────────────────────────────┐
              │ Telemetry and evidence         │
              │                                │
              │ - Cloud Logging                │
              │ - Pub/Sub + DLQ                │
              │ - SCC notifications (optional) │
              │ - Managed Prometheus           │
              │ - BigQuery evidence dataset    │
              └───────────────┬────────────────┘
                              │
                              ▼
           ┌──────────────────────────────────────┐
           │ Multi-agent security workflow        │
           │                                      │
           │ ┌──────────────────────────────────┐ │
           │ │ Event Aggregator                 │ │
           │ │ Normalizes scanner findings      │ │
           │ └──────────────────────────────────┘ │
           │                                      │
           │ ┌──────────────────────────────────┐ │
           │ │ Observer Agent                   │ │
           │ │ Validates incoming findings      │ │
           │ └──────────────────────────────────┘ │
           │                                      │
           │ ┌──────────────────────────────────┐ │
           │ │ Correlation Agent                │ │
           │ │ Joins signals in Firestore       │ │
           │ └──────────────────────────────────┘ │
           │                                      │
           │ ┌──────────────────────────────────┐ │
           │ │ IR Analyst Agent                 │ │
           │ │ Vertex AI / Gemini 3.8 Flash     │ │
           │ └──────────────────────────────────┘ │
           │                                      │
           │ ┌──────────────────────────────────┐ │
           │ │ Governance Agent + OPA           │ │
           │ │ DENY / NO_ACTION / PERMIT /      │ │
           │ │ REQUIRE_APPROVAL                 │ │
           │ └──────────────────────────────────┘ │
           │                                      │
           │ ┌──────────────────────────────────┐ │
           │ │ Approval Agent + Cloud KMS       │ │
           │ │ Verifies signed human decisions  │ │
           │ └──────────────────────────────────┘ │
           │                                      │
           │ ┌──────────────────────────────────┐ │
           │ │ Remediation Agent                │ │
           │ │ Re-checks; MCP if mode allows    │ │
           │ └──────────────────────────────────┘ │
           │                                      │
           │ ┌──────────────────────────────────┐ │
           │ │ Reporting Agent                  │ │
           │ │ incident-reports; Slack/Jira off │ │
           │ └──────────────────────────────────┘ │
           └──────────────────┬───────────────────┘
                              │
                              ▼
                 ┌──────────────────────────┐
                 │ Vertex AI / Gemini       │
                 │ Reasoning only           │
                 │ Never authorizes         │
                 └──────────────────────────┘
```

Diagrams: [**network**](agentic-network.svg) · [**workflow**](agentic-ai-workflow.svg).
