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
    CIDR allowed to reach SSH and the web UIs.

    A single IP as a /32 is the safe setting, found with:
      curl -s https://checkip.amazonaws.com

    0.0.0.0/0 is permitted because this is a throwaway lab and a changing home
    IP is a constant nuisance. Understand what it opens before using it:

      9093  Alertmanager, NO authentication. Anyone reaching this port can post
            an alert and cause the remediation Lambda to restart the instance.
      9090  Prometheus, NO authentication. Full read of every metric.
      3000  Grafana. Has a login, so only as strong as the admin password.
      8080  The app, including its /chaos endpoints.
      22    SSH.

    Internet-facing unauthenticated services get found by scanners quickly, so
    run `make down` when you are not using the lab, and destroy the stack when
    the exercise is over.
  EOT
  type        = string

  validation {
    condition     = can(cidrhost(var.allowed_cidr, 0))
    error_message = "allowed_cidr must be valid CIDR notation, for example 41.186.176.42/32 or 0.0.0.0/0."
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

variable "create_key_pair" {
  description = <<-EOT
    Generate an SSH key pair and attach it to the instance, writing the private
    key to the repo root. Set false to use an existing key via key_name, or to
    rely solely on SSM Session Manager.

    Note: changing this, or key_name, REPLACES the instance. A key pair cannot be
    attached to a running EC2 instance after launch.
  EOT
  type        = bool
  default     = true
}

variable "private_key_dir" {
  description = <<-EOT
    Directory under the repo root for the generated private key. Created by
    Terraform at 0700 if missing, and gitignored in full.
  EOT
  type        = string
  default     = "keys"
}

variable "private_key_filename" {
  description = "Filename for the generated private key. Written into private_key_dir at 0600."
  type        = string
  default     = "techstream-key.pem"
}

variable "app_dir" {
  description = <<-EOT
    Directory on the instance holding docker-compose.yml. The SSM restart
    document runs "cd <app_dir> && docker compose restart app", so this must be
    exactly where the repo actually lives.

    If you cloned to your home directory instead of /opt/techstream, either set
    this to that path, or move the repo. A mismatch makes remediation fail with
    "no configuration file provided" while everything upstream looks healthy.
  EOT
  type        = string
  default     = "/opt/techstream"
}
