output "security_group_id" {
  description = "ID of the lab security group."
  value       = aws_security_group.app.id
}

output "open_ports" {
  description = "Ports opened to var.allowed_cidr, for the verification step."
  value       = [for k, v in local.ingress_ports : v.port]
}
