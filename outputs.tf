output "project_id" {
  description = "The project ID"
  value       = var.project
}

output "region" {
  description = "The deployment region"
  value       = var.region
}

output "bfilter_url" {
  description = "URL of the BFilter service (publicly accessible)"
  value       = google_cloud_run_v2_service.bfilter-service.uri
}

output "sfilter_url" {
  description = "URL of the SFilter service (internal only)"
  value       = google_cloud_run_v2_service.sfilter-service.uri
  sensitive   = true
}

output "llmstub_url" {
  description = "URL of the LLM stub service (internal only)"
  value       = google_cloud_run_v2_service.llm-stub-service.uri
  sensitive   = true
}

output "bfilter_threshold" {
  description = "Current BFilter threshold setting"
  value       = var.bfilter_threshold
}

output "sfilter_confidence_threshold" {
  description = "Current SFilter confidence threshold setting"
  value       = var.sfilter_confidence_threshold
}

output "max_message_length" {
  description = "Maximum allowed message length"
  value       = var.max_message_length
}

output "model_storage_bucket" {
  description = "GCS bucket for model storage"
  value       = google_storage_bucket.model-store.name
}

output "secondary_spam_bucket" {
  description = "GCS bucket for storing secondary filter events"
  value       = google_storage_bucket.secondary-spam.name
}

output "vpc_network" {
  description = "VPC network name"
  value       = google_compute_network.llm-vpc.name
}

output "pubsub_topic" {
  description = "Pub/Sub topic for secondary filter events"
  value       = google_pubsub_topic.secondary_filter_topic.name
}

output "monitoring_dashboard_url" {
  description = "URL to access Cloud Monitoring dashboard"
  value       = "https://console.cloud.google.com/monitoring/dashboards?project=${var.project}"
}

output "cloud_run_logs_url" {
  description = "URL to access Cloud Run logs"
  value       = "https://console.cloud.google.com/run?project=${var.project}"
}