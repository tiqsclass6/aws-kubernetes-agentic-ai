locals {
  agent_topic_names = {
    observed_findings    = "observed-findings"
    correlated_incidents = "correlated-incidents"
    analyzed_incidents   = "analyzed-incidents"
    governance_decisions = "governance-decisions"
    approval_requests    = "approval-requests"
    approval_decisions   = "approval-decisions"
    governance_audit     = "governance-audit"
    remediation_results  = "remediation-results"
    incident_reports     = "incident-reports"
    agent_events_dlq     = "agent-events-dlq"
  }
}

resource "google_pubsub_topic" "observed_findings" {
  name                       = local.agent_topic_names.observed_findings
  message_retention_duration = "604800s"
  depends_on                 = [google_project_service.pubsub]
}

resource "google_pubsub_topic" "correlated_incidents" {
  name                       = local.agent_topic_names.correlated_incidents
  message_retention_duration = "604800s"
  depends_on                 = [google_project_service.pubsub]
}

resource "google_pubsub_topic" "analyzed_incidents" {
  name                       = local.agent_topic_names.analyzed_incidents
  message_retention_duration = "604800s"
  depends_on                 = [google_project_service.pubsub]
}

resource "google_pubsub_topic" "governance_decisions" {
  name                       = local.agent_topic_names.governance_decisions
  message_retention_duration = "1209600s"
  depends_on                 = [google_project_service.pubsub]
}

resource "google_pubsub_topic" "approval_requests" {
  name                       = local.agent_topic_names.approval_requests
  message_retention_duration = "1209600s"
  depends_on                 = [google_project_service.pubsub]
}

resource "google_pubsub_topic" "approval_decisions" {
  name                       = local.agent_topic_names.approval_decisions
  message_retention_duration = "1209600s"
  depends_on                 = [google_project_service.pubsub]
}

resource "google_pubsub_topic" "governance_audit" {
  name                       = local.agent_topic_names.governance_audit
  message_retention_duration = "2592000s"
  depends_on                 = [google_project_service.pubsub]
}

resource "google_pubsub_topic" "remediation_results" {
  name                       = local.agent_topic_names.remediation_results
  message_retention_duration = "604800s"
  depends_on                 = [google_project_service.pubsub]
}

resource "google_pubsub_topic" "incident_reports" {
  name                       = local.agent_topic_names.incident_reports
  message_retention_duration = "1209600s"
  depends_on                 = [google_project_service.pubsub]
}

resource "google_pubsub_topic" "agent_events_dlq" {
  name                       = local.agent_topic_names.agent_events_dlq
  message_retention_duration = "1209600s"
  depends_on                 = [google_project_service.pubsub]
}

resource "google_pubsub_subscription" "agent_events_dlq_sub" {
  name                       = "agent-events-dlq-sub"
  topic                      = google_pubsub_topic.agent_events_dlq.id
  ack_deadline_seconds       = 30
  message_retention_duration = "1209600s"

  expiration_policy {
    ttl = ""
  }
}

resource "google_pubsub_topic_iam_member" "pubsub_service_agent_agent_dlq_publisher" {
  topic  = google_pubsub_topic.agent_events_dlq.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${local.pubsub_service_agent}"
}

resource "google_pubsub_subscription" "observer_agent" {
  name                       = "observer-agent-sub"
  topic                      = google_pubsub_topic.security_findings.id
  ack_deadline_seconds       = 60
  message_retention_duration = "604800s"

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "300s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.agent_events_dlq.id
    max_delivery_attempts = 8
  }

  expiration_policy {
    ttl = ""
  }

  depends_on = [google_pubsub_topic_iam_member.pubsub_service_agent_agent_dlq_publisher]
}

resource "google_pubsub_subscription" "correlation_agent" {
  name                       = "correlation-agent-sub"
  topic                      = google_pubsub_topic.observed_findings.id
  ack_deadline_seconds       = 60
  message_retention_duration = "604800s"

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "300s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.agent_events_dlq.id
    max_delivery_attempts = 8
  }

  expiration_policy {
    ttl = ""
  }

  depends_on = [google_pubsub_topic_iam_member.pubsub_service_agent_agent_dlq_publisher]
}

resource "google_pubsub_subscription" "ir_analyst_agent" {
  name                       = "ir-analyst-agent-sub"
  topic                      = google_pubsub_topic.correlated_incidents.id
  ack_deadline_seconds       = 120
  message_retention_duration = "604800s"

  retry_policy {
    minimum_backoff = "20s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.agent_events_dlq.id
    max_delivery_attempts = 6
  }

  expiration_policy {
    ttl = ""
  }

  depends_on = [google_pubsub_topic_iam_member.pubsub_service_agent_agent_dlq_publisher]
}

resource "google_pubsub_subscription" "governance_agent" {
  name                       = "governance-agent-sub"
  topic                      = google_pubsub_topic.analyzed_incidents.id
  ack_deadline_seconds       = 90
  message_retention_duration = "604800s"

  retry_policy {
    minimum_backoff = "15s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.agent_events_dlq.id
    max_delivery_attempts = 6
  }

  expiration_policy {
    ttl = ""
  }

  depends_on = [google_pubsub_topic_iam_member.pubsub_service_agent_agent_dlq_publisher]
}

resource "google_pubsub_subscription" "approval_agent" {
  name                       = "approval-agent-sub"
  topic                      = google_pubsub_topic.approval_decisions.id
  ack_deadline_seconds       = 90
  message_retention_duration = "1209600s"

  retry_policy {
    minimum_backoff = "15s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.agent_events_dlq.id
    max_delivery_attempts = 6
  }

  expiration_policy {
    ttl = ""
  }

  depends_on = [google_pubsub_topic_iam_member.pubsub_service_agent_agent_dlq_publisher]
}

resource "google_pubsub_subscription" "remediation_agent" {
  name                       = "remediation-governance-sub"
  topic                      = google_pubsub_topic.governance_decisions.id
  ack_deadline_seconds       = 90
  message_retention_duration = "1209600s"

  retry_policy {
    minimum_backoff = "15s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.agent_events_dlq.id
    max_delivery_attempts = 6
  }

  expiration_policy {
    ttl = ""
  }

  depends_on = [google_pubsub_topic_iam_member.pubsub_service_agent_agent_dlq_publisher]
}

resource "google_pubsub_subscription" "reporting_agent" {
  name                       = "reporting-agent-sub"
  topic                      = google_pubsub_topic.remediation_results.id
  ack_deadline_seconds       = 90
  message_retention_duration = "604800s"

  retry_policy {
    minimum_backoff = "15s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.agent_events_dlq.id
    max_delivery_attempts = 6
  }

  expiration_policy {
    ttl = ""
  }

  depends_on = [google_pubsub_topic_iam_member.pubsub_service_agent_agent_dlq_publisher]
}

resource "google_pubsub_subscription" "approval_requests_review" {
  name                       = "approval-requests-review-sub"
  topic                      = google_pubsub_topic.approval_requests.id
  ack_deadline_seconds       = 600
  message_retention_duration = "1209600s"

  expiration_policy {
    ttl = ""
  }
}


resource "google_pubsub_subscription" "governance_decisions_debug" {
  name                       = "governance-decisions-debug-sub"
  topic                      = google_pubsub_topic.governance_decisions.id
  ack_deadline_seconds       = 30
  message_retention_duration = "1209600s"

  expiration_policy {
    ttl = ""
  }
}

resource "google_pubsub_subscription" "governance_audit_debug" {
  name                       = "governance-audit-debug-sub"
  topic                      = google_pubsub_topic.governance_audit.id
  ack_deadline_seconds       = 30
  message_retention_duration = "2592000s"

  expiration_policy {
    ttl = ""
  }
}

resource "google_pubsub_subscription" "incident_reports_debug" {
  name                       = "incident-reports-debug-sub"
  topic                      = google_pubsub_topic.incident_reports.id
  ack_deadline_seconds       = 30
  message_retention_duration = "1209600s"

  expiration_policy {
    ttl = ""
  }
}

locals {
  agent_dead_letter_subscriptions = {
    observer    = google_pubsub_subscription.observer_agent.name
    correlation = google_pubsub_subscription.correlation_agent.name
    ir_analyst  = google_pubsub_subscription.ir_analyst_agent.name
    governance  = google_pubsub_subscription.governance_agent.name
    approval    = google_pubsub_subscription.approval_agent.name
    remediation = google_pubsub_subscription.remediation_agent.name
    reporting   = google_pubsub_subscription.reporting_agent.name
  }
}

resource "google_pubsub_subscription_iam_member" "pubsub_service_agent_agent_subscriber" {
  for_each = local.agent_dead_letter_subscriptions

  subscription = each.value
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${local.pubsub_service_agent}"
}
