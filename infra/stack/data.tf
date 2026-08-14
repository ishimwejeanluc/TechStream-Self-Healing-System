data "aws_caller_identity" "current" {}

# Default VPC and its subnets, so this lab needs no networking build-out.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Latest Canonical Ubuntu 24.04 (noble) x86_64 image.
# 099720109477 is Canonical's published AWS account.
data "aws_ami" "ubuntu_2404" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

locals {
  name    = var.project
  app_dir = "/opt/techstream"

  # Sorted so a re-plan never proposes moving the instance to another subnet.
  subnet_id = sort(data.aws_subnets.default.ids)[0]
}
