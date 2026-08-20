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

output "key_pair_name" {
  description = "Name of the EC2 key pair attached to the instance, null if none."
  value       = var.create_key_pair ? aws_key_pair.instance[0].key_name : var.key_name
}

output "private_key_path" {
  description = "Where the generated private key was written. Mode 0600, gitignored."
  value       = var.create_key_pair ? abspath("${path.module}/../../${var.private_key_dir}/${var.private_key_filename}") : null
}

output "ssh_command" {
  description = "Ready-made SSH command."
  value       = var.create_key_pair ? "ssh -i ${var.private_key_dir}/${var.private_key_filename} ubuntu@${module.compute.public_ip}" : "no key pair, use: aws ssm start-session --target ${module.compute.instance_id}"
}
