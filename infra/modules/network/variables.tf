variable "name" {
  description = "Name prefix for the security group and its rules."
  type        = string
}

variable "vpc_id" {
  description = "VPC to create the security group in."
  type        = string
}

variable "allowed_cidr" {
  description = "CIDR allowed to reach SSH and the web UIs."
  type        = string
}

variable "app_port" {
  description = "Port the Flask app listens on."
  type        = number
  default     = 8080
}
