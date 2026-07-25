# Namespace Architecture

      ┌─────────────────────────────────────────────┐
      │                 GKE Cluster                 │
      └─────────────────────────────────────────────┘

         ┌─────────────────────────────┐
         │ app01                       │
         │-----------------------------│
         │ vulnerable apps             │
         │ demo APIs                   │
         │ attack simulations          │
         └─────────────────────────────┘

         ┌─────────────────────────────┐
         │ security                    │
         │-----------------------------│
         │ Falco                       │
         │ Trivy Jobs                  │
         │ Prowler                     │
         │ Kyverno / OPA               │
         │ event aggregation           │
         └─────────────────────────────┘

         ┌─────────────────────────────┐
         │ monitoring                  │
         │-----------------------------│
         │ Datadog                     │
         │ Prometheus                  │
         │ Grafana                     │
         │ Loki                        │
         └─────────────────────────────┘

         ┌─────────────────────────────┐
         │ ai-agents                   │
         │-----------------------------│
         │ Observer Agent              │
         │ Correlation Agent           │
         │ Analyst Agent               │
         │ Reporting Agent             │
         │ Redis Memory                │
         └─────────────────────────────┘

         ┌─────────────────────────────┐
         │ mcp                         │
         │-----------------------------│
         │ MCP Server                  │
         │ Tool Gateway                │
         │ Approval Service            │
         └─────────────────────────────┘

         ┌─────────────────────────────┐
         │ incident-response           │
         │-----------------------------│
         │ evidence collector          │
         │ IR timeline generator       │
         │ markdown report builder     │
         └─────────────────────────────┘

         ┌─────────────────────────────┐
         │ shared-services             │
         │-----------------------------│
         │ Redis                       │
         │ Pub/Sub bridge              │
         │ internal APIs               │
         └─────────────────────────────┘

         ┌─────────────────────────────┐
         │ ingress                     │
         │-----------------------------│
         │ NGINX ingress               │
         │ gateway APIs                │
         └─────────────────────────────┘
