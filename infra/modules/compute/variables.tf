variable "name" {
  description = "Name prefix for the instance, role and profile."
  type        = string
}

variable "ami_id" {
  description = "Ubuntu 24.04 AMI ID."
  type        = string
}

variable "instance_type" {
  description = "t3.medium or larger, so the CPU chaos test has headroom."
  type        = string
  default     = "t3.medium"
}

variable "subnet_id" {
  description = "Subnet to launch into. Must be public for associate_public_ip to be useful."
  type        = string
}

variable "security_group_ids" {
  description = "Security groups to attach."
  type        = list(string)
}

variable "key_name" {
  description = "Optional EC2 key pair name for SSH. Null means SSM Session Manager only."
  type        = string
  default     = null
}

variable "root_volume_size" {
  description = "Root gp3 volume size in GB. Prometheus and Grafana data live here."
  type        = number
  default     = 30
}

variable "app_dir" {
  description = "Directory the repo is synced to. The SSM restart document cds into app_dir/monitoring."
  type        = string
  default     = "/opt/techstream"
}
