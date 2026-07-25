# Pod Architecture

┌──────────────────────────────────────────────┐
│                 GKE Cluster                  │
└──────────────────────────────────────────────┘

   ┌──────────────────────────────────────┐
   │ kube-system namespace                │
   │--------------------------------------│
   │ CoreDNS                              │
   │ metrics-server                       │
   │ ingress controller                   │
   └──────────────────────────────────────┘

   ┌──────────────────────────────────────┐
   │ security namespace                   │
   │--------------------------------------│
   │ Falco DaemonSet                      │
   │ Trivy Jobs                           │
   │ Prowler CronJobs                     │
   │ Kyverno / OPA                        │
   │ Event Aggregator                     │
   └──────────────────────────────────────┘

   ┌──────────────────────────────────────┐
   │ monitoring namespace                 │
   │--------------------------------------│
   │ Datadog Agents                       │
   │ Prometheus                           │
   │ Grafana                              │
   │ Loki (optional)                      │
   └──────────────────────────────────────┘

   ┌──────────────────────────────────────┐
   │ ai-agents namespace                  │
   │--------------------------------------│
   │ Observer Agent                       │
   │ Correlation Agent                    │
   │ IR Analyst Agent                     │
   │ Reporting Agent                      │
   │ Redis Memory                         │
   └──────────────────────────────────────┘

   ┌──────────────────────────────────────┐
   │ mcp namespace                        │
   │--------------------------------------│
   │ MCP Server                           │
   │ Tool Gateway                         │
   │ Approval Service                     │
   └──────────────────────────────────────┘

   ┌──────────────────────────────────────┐
   │ workloads namespace                  │
   │--------------------------------------│
   │ Demo Apps                            │
   │ Vulnerable Apps                      │
   │ Attack Simulations                   │
   └──────────────────────────────────────┘
