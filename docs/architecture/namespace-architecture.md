# **Namespace Architecture**

Seven application namespaces plus Helm `falco`. There is no `monitoring`, `ingress`, `incident-response`, or `workloads` namespace in this lab.

```text
      ┌─────────────────────────────────────────────┐
      │         GKE cluster vertex-agent-lab        │
      │         Dataplane V2 NetworkPolicy          │
      └─────────────────────────────────────────────┘

         ┌─────────────────────────────┐
         │ app01                       │
         │-----------------------------│
         │ broken-app (app:v1)         │
         │ PostgreSQL                  │
         │ only remediation target     │
         └─────────────────────────────┘

         ┌─────────────────────────────┐
         │ security                    │
         │-----------------------------│
         │ Trivy CronJob               │
         │ Prowler CronJob             │
         │ scanner publisher sidecars  │
         └─────────────────────────────┘

         ┌─────────────────────────────┐
         │ falco (Helm release)        │
         │-----------------------------│
         │ Falco DaemonSet             │
         └─────────────────────────────┘

         ┌─────────────────────────────┐
         │ shared-services             │
         │-----------------------------│
         │ Event Aggregator            │
         └─────────────────────────────┘

         ┌─────────────────────────────┐
         │ ai-agents                   │
         │-----------------------------│
         │ Observer Agent              │
         │ Correlation Agent           │
         │ IR Analyst Agent            │
         │ Remediation Agent           │
         │ Reporting Agent             │
         └─────────────────────────────┘

         ┌─────────────────────────────┐
         │ ai-governance               │
         │-----------------------------│
         │ Governance Agent + OPA      │
         │ Approval Agent              │
         └─────────────────────────────┘

         ┌─────────────────────────────┐
         │ mcp-gateway                 │
         │-----------------------------│
         │ nginx mTLS gateway          │
         │ automountServiceAccount     │
         │ Token: false                │
         └─────────────────────────────┘

         ┌─────────────────────────────┐
         │ mcp                         │
         │-----------------------------│
         │ MCP Server                  │
         │ app01-scoped RBAC           │
         └─────────────────────────────┘
```

NetworkPolicies allow kube-dns and node-local-dns in `kube-system`, the kube-dns ClusterIP `10.112.0.10/32`, and NodeLocal DNSCache `169.254.20.10/32`. Workload Identity uses `169.254.169.254` on Dataplane V2.
