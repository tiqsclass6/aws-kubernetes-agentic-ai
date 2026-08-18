# **Pod Architecture**

Workloads that actually run in the live lab. Falco is installed by Helm into its own namespace. Scanners live in `security`. Analysis and execution agents share `ai-agents` but NetworkPolicies keep remediation on a tighter path.

```text
┌──────────────────────────────────────────────┐
│         GKE cluster vertex-agent-lab         │
│         zone us-central1-c / e2-standard-4   │
└──────────────────────────────────────────────┘

   ┌──────────────────────────────────────┐
   │ kube-system                          │
   │--------------------------------------│
   │ kube-dns                             │
   │ node-local-dns (169.254.20.10)       │
   │ metrics-server                       │
   └──────────────────────────────────────┘

   ┌──────────────────────────────────────┐
   │ falco                                │
   │--------------------------------------│
   │ Falco DaemonSet (Helm 9.1.0)         │
   └──────────────────────────────────────┘

   ┌──────────────────────────────────────┐
   │ security                             │
   │--------------------------------------│
   │ Trivy CronJob + publisher            │
   │ Prowler CronJob + publisher          │
   └──────────────────────────────────────┘

   ┌──────────────────────────────────────┐
   │ shared-services                      │
   │--------------------------------------│
   │ Event Aggregator Deployment          │
   └──────────────────────────────────────┘

   ┌──────────────────────────────────────┐
   │ ai-agents                            │
   │--------------------------------------│
   │ Observer Agent                       │
   │ Correlation Agent                    │
   │ IR Analyst Agent                     │
   │ Remediation Agent (mTLS client)      │
   │ Reporting Agent                      │
   └──────────────────────────────────────┘

   ┌──────────────────────────────────────┐
   │ ai-governance                        │
   │--------------------------------------│
   │ Governance Agent + OPA sidecar       │
   │ Approval Agent                       │
   └──────────────────────────────────────┘

   ┌──────────────────────────────────────┐
   │ mcp-gateway                          │
   │--------------------------------------│
   │ nginx mTLS gateway                   │
   └──────────────────────────────────────┘

   ┌──────────────────────────────────────┐
   │ mcp                                  │
   │--------------------------------------│
   │ MCP Server                           │
   └──────────────────────────────────────┘

   ┌──────────────────────────────────────┐
   │ app01                                │
   │--------------------------------------│
   │ broken-app (app:v1)                  │
   │ PostgreSQL                           │
   └──────────────────────────────────────┘
```

Reliability objects: HPAs and PDBs under `manifests/reliability/`. Metrics: PodMonitoring under `manifests/observability/`.
