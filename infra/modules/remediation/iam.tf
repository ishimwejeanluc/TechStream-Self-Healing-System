data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name}-remediator-role"
  description        = "Least privilege role for the TechStream remediation Lambda."
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# Only needed when enable_scale_out is true. SetDesiredCapacity is scoped to
# this one group's ARN, which requires looking the group up by name.
data "aws_autoscaling_group" "target" {
  count = var.enable_scale_out ? 1 : 0
  name  = var.asg_name
}

data "aws_iam_policy_document" "lambda" {
  # SendCommand needs both the document and the target instance in Resource.
  # Naming both is what keeps this from being "restart anything in the account".
  statement {
    sid    = "SendRestartCommandToThisInstanceOnly"
    effect = "Allow"

    actions = ["ssm:SendCommand"]

    resources = [
      aws_ssm_document.restart_app.arn,
      var.instance_arn,
    ]
  }

  statement {
    sid    = "WriteOwnLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }

  dynamic "statement" {
    for_each = var.enable_scale_out ? [1] : []

    content {
      sid       = "ScaleOutThisGroupOnly"
      effect    = "Allow"
      actions   = ["autoscaling:SetDesiredCapacity"]
      resources = [data.aws_autoscaling_group.target[0].arn]
    }
  }

  dynamic "statement" {
    for_each = var.enable_scale_out ? [1] : []

    content {
      sid    = "DescribeAutoScalingGroups"
      effect = "Allow"
      # This action does not support resource-level permissions, so it has to
      # be "*". It is read-only.
      actions   = ["autoscaling:DescribeAutoScalingGroups"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = var.enable_eventbridge_audit ? [1] : []

    content {
      sid       = "PublishAuditEvent"
      effect    = "Allow"
      actions   = ["events:PutEvents"]
      resources = ["arn:aws:events:${var.region}:${var.account_id}:event-bus/${var.event_bus_name}"]
    }
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${var.name}-remediator-policy"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}
