output "instance_public_ip" {
  description = "Public IPv4 of the lab instance."
  value       = module.compute.public_ip
}

output "instance_id" {
  description = "Instance ID. Use with: aws ssm start-session --target <id>"
  value       = module.compute.instance_id
}

output "app_url" {
  description = "Flask app base URL."
  value       = "http://${module.compute.public_ip}:${var.app_port}"
}

output "grafana_url" {
  description = "Grafana UI. Log in with the credentials from monitoring/.env."
  value       = "http://${module.compute.public_ip}:3000"
}

output "prometheus_url" {
  description = "Prometheus UI and HTTP API. rca.py queries this."
  value       = "http://${module.compute.public_ip}:9090"
}

output "alertmanager_url" {
  description = "Alertmanager UI."
  value       = "http://${module.compute.public_ip}:9093"
}

output "ssm_document_name" {
  description = "Custom SSM document the Lambda invokes."
  value       = module.remediation.ssm_document_name
}

output "lambda_function_url" {
  description = "Base Function URL. Pass to: make configure URL=<this>"
  value       = module.remediation.lambda_function_url
}

output "lambda_function_name" {
  description = "Lambda name, for: aws logs tail /aws/lambda/<name> --follow"
  value       = module.remediation.lambda_function_name
}

output "lambda_log_group" {
  description = "Log group holding the SSM command IDs."
  value       = module.remediation.lambda_log_group
}

output "app_dir" {
  description = "Where to sync the repo on the instance."
  value       = local.app_dir
}

output "configure_command" {
  description = "Run this on the instance to point Alertmanager at the Lambda."
  value       = "make configure URL='${module.remediation.lambda_function_url}'"
}
