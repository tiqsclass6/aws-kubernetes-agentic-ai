resource "google_project_service" "monitoring" {
  project            = var.project_id
  service            = "monitoring.googleapis.com"
  disable_on_destroy = false
}

locals {
  pipeline_subscription_regex = "(observer-agent-sub|correlation-agent-sub|ir-analyst-agent-sub|governance-agent-sub|approval-agent-sub|remediation-governance-sub|reporting-agent-sub)"
}

resource "google_monitoring_alert_policy" "pipeline_backlog" {
  project      = var.project_id
  display_name = "Phase 5 - security pipeline backlog"
  combiner     = "OR"
  enabled      = true

  documentation {
    content   = "One or more Phase 5 Pub/Sub subscriptions has a sustained message backlog. Inspect agent health, logs, and the dead-letter subscription."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Undelivered messages exceed threshold"

    condition_threshold {
      filter          = "resource.type = \"pubsub_subscription\" AND metric.type = \"pubsub.googleapis.com/subscription/num_undelivered_messages\" AND resource.label.subscription_id = monitoring.regex.full_match(\"${local.pipeline_subscription_regex}\")"
      comparison      = "COMPARISON_GT"
      threshold_value = var.pipeline_backlog_threshold
      duration        = "300s"

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_MAX"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.label.subscription_id"]
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = var.monitoring_notification_channel_ids
  depends_on            = [google_project_service.monitoring]
}

resource "google_monitoring_alert_policy" "oldest_unacked_message" {
  project      = var.project_id
  display_name = "Phase 5 - oldest pipeline message"
  combiner     = "OR"
  enabled      = true

  documentation {
    content   = "The oldest unacknowledged security-pipeline message exceeded the allowed processing latency. Check the affected subscription and agent Deployment."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Oldest message age exceeds threshold"

    condition_threshold {
      filter          = "resource.type = \"pubsub_subscription\" AND metric.type = \"pubsub.googleapis.com/subscription/oldest_unacked_message_age\" AND resource.label.subscription_id = monitoring.regex.full_match(\"${local.pipeline_subscription_regex}\")"
      comparison      = "COMPARISON_GT"
      threshold_value = var.pipeline_oldest_message_threshold_seconds
      duration        = "300s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = var.monitoring_notification_channel_ids
  depends_on            = [google_project_service.monitoring]
}

resource "google_monitoring_alert_policy" "dead_letter_messages" {
  project      = var.project_id
  display_name = "Phase 5 - dead-letter messages detected"
  combiner     = "OR"
  enabled      = true

  documentation {
    content   = "The Phase 5 dead-letter subscription contains one or more events. Pull and inspect agent-events-dlq-sub before replaying messages."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Dead-letter subscription is not empty"

    condition_threshold {
      filter          = "resource.type = \"pubsub_subscription\" AND metric.type = \"pubsub.googleapis.com/subscription/num_undelivered_messages\" AND resource.label.subscription_id = \"agent-events-dlq-sub\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "60s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = var.monitoring_notification_channel_ids
  depends_on            = [google_project_service.monitoring]
}

resource "google_monitoring_dashboard" "security_pipeline" {
  project = var.project_id

  dashboard_json = jsonencode({
    displayName = "Agentic Security - Phase 5 Operations"
    mosaicLayout = {
      columns = 12
      tiles = [
        {
          xPos   = 0
          yPos   = 0
          width  = 12
          height = 2
          widget = {
            title = "Operations guide"
            text = {
              format  = "MARKDOWN"
              content = "Use this dashboard with Managed Service for Prometheus. Primary SLO: no dead-letter events and oldest unacknowledged pipeline message below ${var.pipeline_oldest_message_threshold_seconds} seconds."
            }
          }
        },
        {
          xPos   = 0
          yPos   = 2
          width  = 6
          height = 4
          widget = {
            title = "Undelivered pipeline messages"
            xyChart = {
              dataSets = [{
                plotType   = "LINE"
                targetAxis = "Y1"
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "resource.type = \"pubsub_subscription\" AND metric.type = \"pubsub.googleapis.com/subscription/num_undelivered_messages\" AND resource.label.subscription_id = monitoring.regex.full_match(\"${local.pipeline_subscription_regex}\")"
                    aggregation = {
                      alignmentPeriod  = "60s"
                      perSeriesAligner = "ALIGN_MAX"
                    }
                  }
                }
              }]
              yAxis = {
                label = "messages"
                scale = "LINEAR"
              }
            }
          }
        },
        {
          xPos   = 6
          yPos   = 2
          width  = 6
          height = 4
          widget = {
            title = "Oldest unacknowledged message"
            xyChart = {
              dataSets = [{
                plotType   = "LINE"
                targetAxis = "Y1"
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "resource.type = \"pubsub_subscription\" AND metric.type = \"pubsub.googleapis.com/subscription/oldest_unacked_message_age\" AND resource.label.subscription_id = monitoring.regex.full_match(\"${local.pipeline_subscription_regex}\")"
                    aggregation = {
                      alignmentPeriod  = "60s"
                      perSeriesAligner = "ALIGN_MAX"
                    }
                  }
                }
              }]
              thresholds = [{
                value     = var.pipeline_oldest_message_threshold_seconds
                direction = "ABOVE"
              }]
              yAxis = {
                label = "seconds"
                scale = "LINEAR"
              }
            }
          }
        }
      ]
    }
  })

  depends_on = [google_project_service.monitoring]
}
