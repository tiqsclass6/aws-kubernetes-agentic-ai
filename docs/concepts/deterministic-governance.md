# **Deterministic Governance**

The security workflow separates AI-assisted incident analysis from authorization and execution.

Gemini may analyze an incident, summarize its context, and recommend an action. It does not authorize that action.

## **Governance flow**

```text
IR Analyst Agent
  → analyzed-incidents
  → Governance Agent
  → OPA remediation policy
  → governance decision
```

The Governance Agent evaluates normalized incident data against:

`policy/governance/remediation.rego`

The policy returns one of four outcomes:

**Decision Meaning**

- **DENY** The proposed action is prohibited.
- **NO_ACTION** The incident does not require remediation.
- **PERMIT** The action satisfies the deterministic policy controls.
- **REQUIRE_APPROVAL** A signed human approval is required before execution.

## **Separation of responsibility**

The components have deliberately separate responsibilities:

- The IR Analyst Agent supplies AI-assisted analysis.
- The Governance Agent evaluates deterministic policy.
- The Approval Agent validates signed human decisions.
- The Remediation Agent independently validates authorization.
- The MCP security gateway brokers the approved Kubernetes operation.
- The Reporting Agent records the final result.

## **Independent enforcement**

The Remediation Agent does not trust an AI recommendation by itself. Before execution, it verifies:

- Governance decision
- Policy identifier
- Policy SHA-256
- Approval requirement
- Approval signature status
- Approval expiration
- Incident and request identifiers
- Requested action
- Namespace allowlist
- Deployment allowlist
- Severity
- Confidence
- Operational risk
- Evidence count
- Previous execution state

## **Fail-closed behavior**

Missing, malformed, expired, unsigned, or inconsistent governance data causes the remediation request to be rejected.

Automated execution remains disabled until the Remediation Agent is explicitly configured with:

`EXECUTION_MODE: controlled`

The Governance Agent must also use an explicitly approved automation mode.

## **Human approval**

Incidents requiring approval are published to:

`approval-requests`

A reviewer signs the decision using Cloud KMS. The Approval Agent verifies the signature and publishes an authorized governance decision only when all approval controls pass.

Critical incidents require signed human approval by default.

## **Audit evidence**

Governance, approval, remediation, and MCP events are exported to the configured BigQuery evidence dataset. Firestore stores approval and execution state to prevent replay and duplicate remediation.
