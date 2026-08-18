# **Event Pipeline Architecture**

Canonical event flow. Gemini recommends. OPA decides. Cloud KMS binds a human reviewer. MCP is the only Kubernetes execution path.

```text
Falco / Trivy / Prowler / Cloud Logging / SCC
  |
  v
raw-security-events
  |
  v
Event Aggregator (shared-services)
  |
  v
security-findings
  |
  v
Observer Agent (ai-agents)
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
Governance Agent + OPA (ai-governance)
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
      Human reviewer + Cloud KMS v2
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
Remediation Agent (fail-closed unless EXECUTION_MODE=controlled)
  |
  v
MCP Gateway over mTLS
  |
  v
MCP Server (app01 RBAC)
  |
  v
allowlisted Kubernetes action in app01
  |
  v
remediation-results
  |
  v
Reporting Agent
  |
  +--> incident-reports
  +--> optional Slack / Jira (disabled by default)
  +--> BigQuery governance evidence
```

See [**network**](agentic-network.svg) and [**workflow**](agentic-ai-workflow.svg). The MCP hop is detailed in [**mcp-architecture.md**](mcp-architecture.md).
