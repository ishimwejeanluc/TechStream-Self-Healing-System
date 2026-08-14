locals {
  # One ingress rule per port, all scoped to var.allowed_cidr.
  ingress_ports = {
    ssh          = { port = 22, note = "SSH from Termius" }
    app          = { port = var.app_port, note = "Flask app and /metrics" }
    grafana      = { port = 3000, note = "Grafana UI" }
    prometheus   = { port = 9090, note = "Prometheus UI and HTTP API for rca.py" }
    alertmanager = { port = 9093, note = "Alertmanager UI" }
  }
}

resource "aws_security_group" "app" {
  name        = "${var.name}-sg"
  description = "TechStream lab: SSH plus app, Grafana, Prometheus and Alertmanager UIs"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "allowed" {
  for_each = local.ingress_ports

  security_group_id = aws_security_group.app.id
  description       = each.value.note
  cidr_ipv4         = var.allowed_cidr
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = "tcp"

  tags = {
    Name = "${var.name}-in-${each.key}"
  }
}

# Outbound is open so the instance can pull images from Docker Hub, install
# packages from the Ubuntu repos, reach the SSM endpoints and ship logs.
# Nothing inbound depends on this.
#
# Accepted exception, not an oversight. Restricting egress here would need
# interface VPC endpoints for ssm, ssmmessages and ec2messages, plus a NAT or
# proxy for Docker Hub and apt. That is more infrastructure than this lab
# needs. Revisit if this pattern moves toward production.
# trivy:ignore:AVD-AWS-0104
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.app.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  tags = {
    Name = "${var.name}-out-all"
  }
}
