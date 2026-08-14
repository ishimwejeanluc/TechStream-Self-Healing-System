data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.name}-instance-role"
  description        = "TechStream lab instance role. SSM managed instance access only."
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# This is what registers the instance as an SSM managed instance, which is the
# precondition for the Lambda's SendCommand to reach it.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name}-instance-profile"
  role = aws_iam_role.instance.name
}

resource "aws_instance" "app" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  key_name               = var.key_name

  associate_public_ip_address = true

  user_data                   = templatefile("${path.module}/user_data.sh", { app_dir = var.app_dir })
  user_data_replace_on_change = true

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true

    tags = {
      Name = "${var.name}-root"
    }
  }

  # IMDSv2 only. Closes the SSRF-to-credentials path against the app, which
  # matters because the app deliberately accepts attacker-shaped input.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  monitoring = true

  tags = {
    Name = "${var.name}-app"
    Role = "monitoring-stack"
  }
}
