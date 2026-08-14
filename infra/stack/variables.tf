variable "region" {
  description = "AWS region. Must match the region in the backend block."
  type        = string
  default     = "eu-west-1"
}

variable "project" {
  description = "Name prefix for every resource."
  type        = string
  default     = "techstream"
}

variable "allowed_cidr" {
  description = <<-EOT
    CIDR allowed to reach SSH and the web UIs. Use your own IP as a /32.
    Find it with: curl -s https://checkip.amazonaws.com
    Do not use 0.0.0.0/0. Prometheus and Alertmanager have no authentication.
  EOT
  type        = string

  validation {
    condition     = can(cidrhost(var.allowed_cidr, 0))
    error_message = "allowed_cidr must be valid CIDR notation, for example 41.186.176.42/32."
  }

  validation {
    condition     = var.allowed_cidr != "0.0.0.0/0"
    error_message = "Refusing 0.0.0.0/0. These ports expose unauthenticated dashboards."
  }
}

variable "instance_type" {
  description = "t3.medium or larger, so the CPU chaos test has headroom."
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size" {
  description = "Root gp3 volume size in GB. Prometheus and Grafana data live here."
  type        = number
  default     = 30
}

variable "key_name" {
  description = <<-EOT
    Optional existing EC2 key pair name for SSH from Termius. Leave null to use
    SSM Session Manager instead: aws ssm start-session --target <instance-id>
  EOT
  type        = string
  default     = null
}

variable "app_port" {
  description = "Port the Flask app listens on."
  type        = number
  default     = 8080
}

variable "remediation_webhook_token" {
  description = <<-EOT
    Shared secret Alertmanager appends as ?token= when posting to the Lambda
    Function URL. The URL is auth NONE because Alertmanager cannot sign SigV4
    requests, so this token is the only thing gating remediation.
    Set it in terraform.tfvars, which is gitignored.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the Lambda."
  type        = number
  default     = 14
}

variable "enable_scale_out" {
  description = <<-EOT
    Alternative remediation path, off by default. When true the Lambda calls
    autoscaling:SetDesiredCapacity on var.asg_name instead of restarting the
    container. Restart is faster for a bad process, which is the failure this
    lab injects. Scale-out only helps when the cause is real saturation.
  EOT
  type        = bool
  default     = false
}

variable "asg_name" {
  description = "Auto Scaling group name, required only when enable_scale_out is true."
  type        = string
  default     = ""

  validation {
    condition     = !(var.enable_scale_out && var.asg_name == "")
    error_message = "asg_name is required when enable_scale_out is true."
  }
}

variable "scale_out_increment" {
  description = "Instances to add per scale-out event."
  type        = number
  default     = 1
}

variable "enable_eventbridge_audit" {
  description = <<-EOT
    When true the Lambda publishes a custom event after remediating, for audit
    only, off the critical path. The original brief reached the Lambda through a
    CloudWatch Alarm plus an EventBridge rule. Alerting now lives in Prometheus,
    so the Alertmanager webhook replaces that hop.
  EOT
  type        = bool
  default     = false
}

variable "event_bus_name" {
  description = "EventBridge bus for audit events."
  type        = string
  default     = "default"
}
