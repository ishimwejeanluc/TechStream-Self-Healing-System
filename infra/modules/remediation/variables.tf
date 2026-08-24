variable "name" {
  description = "Name prefix for the SSM document, Lambda and IAM role."
  type        = string
}

variable "region" {
  description = "AWS region, used to build ARNs."
  type        = string
}

variable "account_id" {
  description = "AWS account ID, used to build ARNs."
  type        = string
}

variable "instance_id" {
  description = "Instance the SSM command targets."
  type        = string
}

variable "instance_arn" {
  description = "Instance ARN, used to scope ssm:SendCommand."
  type        = string
}

variable "restart_dir" {
  description = <<-EOT
    Directory the SSM restart document cds into. Must be where
    docker-compose.yml actually lives on the instance.

    Deliberately NOT the same variable that user_data uses. user_data is baked
    at launch and changing it replaces the instance, so coupling the two meant
    that correcting the restart path destroyed the box. This one only feeds the
    SSM document, which updates in place.
  EOT
  type        = string
  default     = "/home/ubuntu/TechStream-Self-Healing-System"
}

variable "compose_service" {
  description = "Compose service name to restart."
  type        = string
  default     = "app"
}

variable "webhook_token" {
  description = "Shared secret Alertmanager appends as ?token=. Empty disables the check."
  type        = string
  default     = ""
  sensitive   = true
}

variable "expected_alertname" {
  description = "Only this Prometheus alertname triggers remediation."
  type        = string
  default     = "HighErrorRate"
}

variable "lambda_timeout" {
  description = "Lambda timeout in seconds. SendCommand returns quickly, so this is generous."
  type        = number
  default     = 30
}

variable "min_seconds_between_actions" {
  description = <<-EOT
    Best-effort throttle between remediation actions. Only holds while the
    execution environment stays warm, so Alertmanager repeat_interval is the
    real guard against restart storms.
  EOT
  type        = number
  default     = 120
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the Lambda."
  type        = number
  default     = 14
}

variable "enable_scale_out" {
  description = <<-EOT
    Alternative remediation path, off by default. When true the Lambda calls
    autoscaling:SetDesiredCapacity instead of restarting the container.
  EOT
  type        = bool
  default     = false
}

variable "asg_name" {
  description = "Auto Scaling group name, required when enable_scale_out is true."
  type        = string
  default     = ""
}

variable "scale_out_increment" {
  description = "Instances to add per scale-out event."
  type        = number
  default     = 1
}

variable "enable_eventbridge_audit" {
  description = "Publish a custom event after remediating, for audit only. Off the critical path."
  type        = bool
  default     = false
}

variable "event_bus_name" {
  description = "EventBridge bus for audit events."
  type        = string
  default     = "default"
}
