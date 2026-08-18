from __future__ import annotations

import os
from typing import Any

import requests
from google.cloud import secretmanager
from pydantic import BaseModel, ConfigDict, Field

from agent_runtime import AgentRuntime, stable_id


class RemediationResult(BaseModel):
    model_config = ConfigDict(
        extra="allow"
    )

    schema_version: str = "1.0"
    remediation_id: str
    incident_id: str
    analysis_id: str
    governance_decision_id: str = ""
    processed_at: str
    status: str
    severity: str

    action: dict[str, Any] = Field(
        default_factory=dict
    )

    policy: dict[str, Any] = Field(
        default_factory=dict
    )

    approval: dict[str, Any] = Field(
        default_factory=dict
    )

    gateway_result: dict[
        str,
        Any,
    ] = Field(
        default_factory=dict
    )

    incident: dict[str, Any] = Field(
        default_factory=dict
    )

    analysis: dict[str, Any] = Field(
        default_factory=dict
    )


PROJECT_ID = os.environ["PROJECT_ID"]

ENABLE_SLACK = (
    os.environ.get(
        "ENABLE_SLACK",
        "false",
    ).lower()
    == "true"
)

ENABLE_JIRA = (
    os.environ.get(
        "ENABLE_JIRA",
        "false",
    ).lower()
    == "true"
)

SLACK_WEBHOOK_SECRET_ID = os.environ.get(
    "SLACK_WEBHOOK_SECRET_ID",
    "security-slack-webhook-url",
)

JIRA_API_TOKEN_SECRET_ID = os.environ.get(
    "JIRA_API_TOKEN_SECRET_ID",
    "security-jira-api-token",
)

JIRA_BASE_URL = os.environ.get(
    "JIRA_BASE_URL",
    "",
).rstrip("/")

JIRA_EMAIL = os.environ.get(
    "JIRA_EMAIL",
    "",
)

JIRA_PROJECT_KEY = os.environ.get(
    "JIRA_PROJECT_KEY",
    "",
)

JIRA_ISSUE_TYPE = os.environ.get(
    "JIRA_ISSUE_TYPE",
    "Task",
)

HTTP_TIMEOUT_SECONDS = int(
    os.environ.get(
        "HTTP_TIMEOUT_SECONDS",
        "20",
    )
)

secret_client = (
    secretmanager
    .SecretManagerServiceClient()
)

http = requests.Session()

http.headers.update(
    {
        "User-Agent": (
            "agentic-reporting-agent/1.0"
        )
    }
)


def access_secret(
    secret_id: str,
) -> str:
    name = (
        f"projects/{PROJECT_ID}/"
        f"secrets/{secret_id}/"
        "versions/latest"
    )

    response = (
        secret_client
        .access_secret_version(
            request={
                "name": name
            }
        )
    )

    return response.payload.data.decode(
        "utf-8"
    )


def report_markdown(
    event: RemediationResult,
) -> str:
    analysis = event.analysis
    incident = event.incident
    action = event.action
    policy = event.policy

    evidence = analysis.get(
        "key_evidence",
        [],
    )

    containment = analysis.get(
        "containment_steps",
        [],
    )

    investigation = analysis.get(
        "investigation_steps",
        [],
    )

    lines = [
        (
            f"# Security Incident "
            f"{event.incident_id}"
        ),
        "",
        (
            f"- **Severity:** "
            f"{event.severity}"
        ),
        (
            f"- **Risk score:** "
            f"{incident.get('risk_score', 'unknown')}"
        ),
        (
            f"- **Entity:** "
            f"{incident.get('entity_key', 'unknown')}"
        ),
        (
            f"- **Signals:** "
            f"{incident.get('signal_count', 0)}"
        ),
        (
            f"- **Remediation status:** "
            f"{event.status}"
        ),
        (
            f"- **Recommended action:** "
            f"{action.get('action', 'none')}"
        ),
        (
            f"- **Policy approved:** "
            f"{policy.get('approved', False)}"
        ),
        (
            f"- **Governance decision:** "
            f"{policy.get('decision', 'unknown')}"
        ),
        (
            f"- **Policy:** "
            f"{policy.get('policy_id', 'unknown')} "
            f"v{policy.get('policy_version', 'unknown')}"
        ),
        (
            f"- **Human reviewer:** "
            f"{event.approval.get('reviewer', 'not-required') or 'not-required'}"
        ),
        "",
        "## Executive summary",
        str(
            analysis.get(
                "executive_summary",
                (
                    "No executive summary "
                    "was produced."
                ),
            )
        ),
        "",
        "## Likely root cause",
        str(
            analysis.get(
                "likely_root_cause",
                "Unknown",
            )
        ),
        "",
        "## Key evidence",
    ]

    lines.extend(
        [
            f"- {item}"
            for item in evidence
        ]
        or [
            "- No evidence items supplied."
        ]
    )

    lines.extend(
        [
            "",
            "## Containment steps",
        ]
    )

    lines.extend(
        [
            f"- {item}"
            for item in containment
        ]
        or [
            "- No containment steps supplied."
        ]
    )

    lines.extend(
        [
            "",
            "## Investigation steps",
        ]
    )

    lines.extend(
        [
            f"- {item}"
            for item in investigation
        ]
        or [
            "- No investigation steps supplied."
        ]
    )

    lines.extend(
        [
            "",
            "## Remediation decision",
            (
                f"- Status: "
                f"{event.status}"
            ),
            (
                f"- Rationale: "
                f"{action.get('rationale', '')}"
            ),
            (
                f"- Expected outcome: "
                f"{action.get('expected_outcome', '')}"
            ),
            (
                f"- Policy reasons: "
                f"{', '.join(policy.get('reasons', [])) or 'none'}"
            ),
            (
                f"- Executor reasons: "
                f"{', '.join(policy.get('executor_reasons', [])) or 'none'}"
            ),
            (
                f"- Approval reason: "
                f"{event.approval.get('reason', 'not-required') or 'not-required'}"
            ),
            (
                f"- Policy SHA-256: "
                f"{policy.get('policy_sha256', 'unknown')}"
            ),
        ]
    )

    return "\n".join(lines)


def send_slack(
    event: RemediationResult,
    markdown: str,
) -> dict[str, Any]:
    if not ENABLE_SLACK:
        return {
            "enabled": False,
            "status": "disabled",
        }

    webhook_url = access_secret(
        SLACK_WEBHOOK_SECRET_ID
    )

    executive_summary = str(
        event.analysis.get(
            "executive_summary",
            "",
        )
    )[:2000]

    payload = {
        "text": (
            f"Security incident "
            f"{event.incident_id} "
            f"({event.severity})"
        ),
        "blocks": [
            {
                "type": "header",
                "text": {
                    "type": "plain_text",
                    "text": (
                        "Security Incident: "
                        f"{event.severity}"
                    ),
                },
            },
            {
                "type": "section",
                "fields": [
                    {
                        "type": "mrkdwn",
                        "text": (
                            "*Incident*\n"
                            f"`{event.incident_id}`"
                        ),
                    },
                    {
                        "type": "mrkdwn",
                        "text": (
                            "*Remediation*\n"
                            f"{event.status}"
                        ),
                    },
                    {
                        "type": "mrkdwn",
                        "text": (
                            "*Entity*\n"
                            f"{event.incident.get('entity_key', 'unknown')}"
                        ),
                    },
                    {
                        "type": "mrkdwn",
                        "text": (
                            "*Risk Score*\n"
                            f"{event.incident.get('risk_score', 'unknown')}"
                        ),
                    },
                ],
            },
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": executive_summary,
                },
            },
            {
                "type": "context",
                "elements": [
                    {
                        "type": "mrkdwn",
                        "text": (
                            "Report ID: "
                            f"`{stable_id('report', event.remediation_id)}`"
                        ),
                    }
                ],
            },
        ],
    }

    response = http.post(
        webhook_url,
        json=payload,
        timeout=HTTP_TIMEOUT_SECONDS,
    )

    response.raise_for_status()

    return {
        "enabled": True,
        "status": "sent",
        "status_code": (
            response.status_code
        ),
        "response": (
            response.text[:200]
        ),
        "report_length": len(markdown),
    }


def adf_document(
    markdown: str,
) -> dict[str, Any]:
    paragraphs = []

    for line in markdown.splitlines():
        if not line.strip():
            continue

        paragraphs.append(
            {
                "type": "paragraph",
                "content": [
                    {
                        "type": "text",
                        "text": line[:3000],
                    }
                ],
            }
        )

    return {
        "type": "doc",
        "version": 1,
        "content": paragraphs[:100],
    }


def send_jira(
    event: RemediationResult,
    markdown: str,
) -> dict[str, Any]:
    if not ENABLE_JIRA:
        return {
            "enabled": False,
            "status": "disabled",
        }

    missing = [
        name
        for name, value in {
            "JIRA_BASE_URL": (
                JIRA_BASE_URL
            ),
            "JIRA_EMAIL": (
                JIRA_EMAIL
            ),
            "JIRA_PROJECT_KEY": (
                JIRA_PROJECT_KEY
            ),
        }.items()
        if not value
    ]

    if missing:
        return {
            "enabled": True,
            "status": (
                "configuration-error"
            ),
            "missing": missing,
        }

    api_token = access_secret(
        JIRA_API_TOKEN_SECRET_ID
    )

    payload = {
        "fields": {
            "project": {
                "key": JIRA_PROJECT_KEY
            },
            "summary": (
                f"[{event.severity}] "
                "Security incident "
                f"{event.incident_id[-12:]} "
                f"- {event.status}"
            )[:255],
            "issuetype": {
                "name": JIRA_ISSUE_TYPE
            },
            "description": (
                adf_document(markdown)
            ),
            "labels": [
                "gke-security",
                "agentic-soc",
                event.severity.lower(),
            ],
        }
    }

    response = http.post(
        (
            f"{JIRA_BASE_URL}"
            "/rest/api/3/issue"
        ),
        json=payload,
        auth=(
            JIRA_EMAIL,
            api_token,
        ),
        headers={
            "Accept": "application/json",
            "Content-Type": (
                "application/json"
            ),
        },
        timeout=HTTP_TIMEOUT_SECONDS,
    )

    response.raise_for_status()

    body = response.json()

    return {
        "enabled": True,
        "status": "created",
        "status_code": (
            response.status_code
        ),
        "issue_id": body.get(
            "id",
            "",
        ),
        "issue_key": body.get(
            "key",
            "",
        ),
    }


def safe_integration_call(
    name: str,
    function: Any,
    *args: Any,
) -> dict[str, Any]:
    try:
        return function(*args)

    except Exception as exc:
        return {
            "enabled": True,
            "status": "failed",
            "integration": name,
            "error": str(exc),
        }


def process(
    payload: dict[str, Any],
    _attributes: dict[str, str],
    input_message_id: str,
) -> list[dict[str, Any]]:
    event = (
        RemediationResult
        .model_validate(payload)
    )

    markdown = report_markdown(event)

    slack = safe_integration_call(
        "slack",
        send_slack,
        event,
        markdown,
    )

    jira = safe_integration_call(
        "jira",
        send_jira,
        event,
        markdown,
    )

    report = {
        "schema_version": "1.0",
        "event_type": "incident-report",
        "source": "reporting-agent",
        "severity": event.severity,
        "report_id": stable_id(
            "report",
            event.remediation_id,
        ),
        "incident_id": (
            event.incident_id
        ),
        "analysis_id": (
            event.analysis_id
        ),
        "remediation_id": (
            event.remediation_id
        ),
        "governance_decision_id": (
            event.governance_decision_id
        ),
        "created_at": (
            AgentRuntime.utc_now()
        ),
        "input_message_id": (
            input_message_id
        ),
        "title": (
            f"Security Incident "
            f"{event.incident_id}"
        ),
        "summary": event.analysis.get(
            "executive_summary",
            "",
        ),
        "remediation_status": (
            event.status
        ),
        "markdown": markdown,
        "integrations": {
            "slack": slack,
            "jira": jira,
        },
        "incident": event.incident,
        "analysis": event.analysis,
        "remediation": {
            "status": event.status,
            "action": event.action,
            "policy": event.policy,
            "approval": event.approval,
            "gateway_result": (
                event.gateway_result
            ),
        },
    }

    return [report]


def main() -> None:
    AgentRuntime(
        agent_name="reporting-agent",
        processor=process,
        max_messages=int(
            os.environ.get(
                "MAX_CONCURRENT_MESSAGES",
                "4",
            )
        ),
    ).run()


if __name__ == "__main__":
    main()