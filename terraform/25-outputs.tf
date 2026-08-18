output "gke_cluster_info" {
  description = "GKE cluster information"
  value = {
    name     = google_container_cluster.primary.name
    endpoint = google_container_cluster.primary.endpoint
    location = google_container_cluster.primary.location
  }
}

output "workload_identity" {
  description = "GKE Workload Identity configuration"
  value = {
    workload_pool = local.workload_pool
    project_id    = var.project_id
  }
}

output "vertex_agent_service_account_email" {
  description = "Google service account used by the IR Analyst Agent"
  value       = google_service_account.vertex_agent.email
}

output "artifact_registry_docker_repo_url" {
  description = "Base Docker repository URL for project images"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_registry_repository_id}"
}

output "get_credentials_command" {
  description = "Command for obtaining kubectl credentials"
  value       = "gcloud container clusters get-credentials ${var.cluster_name} --zone ${var.zone} --project ${var.project_id}"
}

output "security_telemetry_pubsub" {
  description = "Pub/Sub resources used by the telemetry ingestion pipeline"
  value = {
    raw_topic                = google_pubsub_topic.raw_security_events.name
    raw_subscription         = google_pubsub_subscription.raw_security_events_sub.name
    dead_letter_topic        = google_pubsub_topic.raw_security_events_dlq.name
    dead_letter_subscription = google_pubsub_subscription.raw_security_events_dlq_sub.name
    findings_topic           = google_pubsub_topic.security_findings.name
    validation_subscription  = google_pubsub_subscription.security_findings_debug_sub.name
  }
}

output "agent_topics" {
  description = "Pub/Sub topics used by the multi-agent workflow"
  value = {
    observed_findings    = google_pubsub_topic.observed_findings.name
    correlated_incidents = google_pubsub_topic.correlated_incidents.name
    analyzed_incidents   = google_pubsub_topic.analyzed_incidents.name
    governance_decisions = google_pubsub_topic.governance_decisions.name
    approval_requests    = google_pubsub_topic.approval_requests.name
    approval_decisions   = google_pubsub_topic.approval_decisions.name
    governance_audit     = google_pubsub_topic.governance_audit.name
    remediation_results  = google_pubsub_topic.remediation_results.name
    incident_reports     = google_pubsub_topic.incident_reports.name
    dead_letter_topic    = google_pubsub_topic.agent_events_dlq.name
  }
}

output "agent_subscriptions" {
  description = "Pull subscriptions used by each workflow stage"
  value = {
    observer                  = google_pubsub_subscription.observer_agent.name
    correlation               = google_pubsub_subscription.correlation_agent.name
    ir_analyst                = google_pubsub_subscription.ir_analyst_agent.name
    governance                = google_pubsub_subscription.governance_agent.name
    approval                  = google_pubsub_subscription.approval_agent.name
    remediation               = google_pubsub_subscription.remediation_agent.name
    reporting                 = google_pubsub_subscription.reporting_agent.name
    approval_review           = google_pubsub_subscription.approval_requests_review.name
    governance_decision_debug = google_pubsub_subscription.governance_decisions_debug.name
    governance_audit_debug    = google_pubsub_subscription.governance_audit_debug.name
    report_debug              = google_pubsub_subscription.incident_reports_debug.name
    dead_letter               = google_pubsub_subscription.agent_events_dlq_sub.name
  }
}

output "agent_service_accounts" {
  description = "Google service accounts used by the live multi-agent workflow"
  value = {
    observer    = google_service_account.observer_agent.email
    correlation = google_service_account.correlation_agent.email
    ir_analyst  = google_service_account.vertex_agent.email
    governance  = google_service_account.governance_agent.email
    approval    = google_service_account.approval_agent.email
    remediation = google_service_account.remediation_agent.email
    reporting   = google_service_account.reporting_agent.email
    mcp_server  = google_service_account.mcp_server.email
  }
}

output "approval_key_version" {
  description = "Cloud KMS key version used to sign and verify human approval decisions"
  value       = local.approval_key_version_name
}

output "evidence_dataset" {
  description = "BigQuery dataset receiving governance evidence logs"
  value       = google_bigquery_dataset.governance_evidence.dataset_id
}

output "policy_id" {
  description = "Governance policy identifier expected by the executor"
  value       = var.policy_id
}

output "reporting_secret_ids" {
  description = "Secret Manager secret containers for optional reporting integrations"
  value = {
    slack_webhook = local.reporting_slack_secret_id
    jira_token    = local.reporting_jira_secret_id
  }
}

output "github_actions_workload_identity_provider" {
  description = "Provider resource name used by google-github-actions/auth"
  value       = google_iam_workload_identity_pool_provider.github_actions.name
}

output "github_release_service_account" {
  description = "Service account impersonated by the GitHub release workflow"
  value       = google_service_account.github_release.email
}

output "monitoring_dashboard_id" {
  description = "Cloud Monitoring dashboard ID for operations"
  value       = google_monitoring_dashboard.security_pipeline.id
}
