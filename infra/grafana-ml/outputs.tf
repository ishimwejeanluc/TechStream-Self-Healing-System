output "prometheus_datasource_uid" {
  description = "Resolved UID of the hosted Prometheus datasource the jobs query."
  value       = data.grafana_data_source.prometheus.uid
}

output "error_ratio_job_id" {
  description = "Forecast job ID. Useful for the Grafana ML API and for Sift."
  value       = grafana_machine_learning_job.error_ratio.id
}

output "error_ratio_metric" {
  description = "Metric name the forecast publishes."
  value       = grafana_machine_learning_job.error_ratio.metric
}

output "container_cpu_outlier_id" {
  description = "DBSCAN outlier detector ID."
  value       = grafana_machine_learning_outlier_detector.container_cpu.id
}

output "ml_alerts_enabled" {
  description = "Whether Grafana-managed ML alerts were created. These never trigger remediation."
  value       = var.enable_ml_alerts
}

output "next_steps" {
  description = "What to do after apply."
  value       = <<-EOT
    1. Run baseline traffic BEFORE any chaos, so the models learn normal:
         make traffic DURATION=600 RPS=20
    2. Check the jobs are trained and healthy:
         ${var.grafana_url}/a/grafana-ml-app/
    3. Only then inject a fault:
         make chaos-errors
    4. Run a Sift investigation over the incident window and export it.
  EOT
}
