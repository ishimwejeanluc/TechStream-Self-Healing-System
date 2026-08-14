data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/build/remediator.zip"
}

# Created explicitly so retention is set and the IAM policy can be scoped to
# this exact group instead of all log groups.
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name}-remediator"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${var.name}-remediator-logs"
  }
}

resource "aws_lambda_function" "remediator" {
  function_name = "${var.name}-remediator"
  description   = "Restarts the TechStream app when Prometheus reports a high error rate."
  role          = aws_iam_role.lambda.arn

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  runtime = "python3.12"
  handler = "handler.lambda_handler"
  timeout = var.lambda_timeout

  # boto3 ships in the runtime, so there is no layer or dependency build.
  environment {
    variables = {
      INSTANCE_ID                 = var.instance_id
      SSM_DOCUMENT_NAME           = aws_ssm_document.restart_app.name
      WEBHOOK_TOKEN               = var.webhook_token
      EXPECTED_ALERTNAME          = var.expected_alertname
      MIN_SECONDS_BETWEEN_ACTIONS = tostring(var.min_seconds_between_actions)
      ENABLE_SCALE_OUT            = tostring(var.enable_scale_out)
      ASG_NAME                    = var.asg_name
      SCALE_OUT_INCREMENT         = tostring(var.scale_out_increment)
      ENABLE_EVENTBRIDGE_AUDIT    = tostring(var.enable_eventbridge_audit)
      EVENT_BUS_NAME              = var.event_bus_name
      LOG_LEVEL                   = "INFO"
    }
  }

  depends_on = [
    aws_iam_role_policy.lambda,
    aws_cloudwatch_log_group.lambda,
  ]

  tags = {
    Name = "${var.name}-remediator"
  }
}

# auth NONE because Alertmanager cannot sign SigV4 requests. The ?token= shared
# secret checked inside the handler is the only gate, so keep it secret and
# rotate it by changing remediation_webhook_token and re-applying.
resource "aws_lambda_function_url" "remediator" {
  function_name      = aws_lambda_function.remediator.function_name
  authorization_type = "NONE"
}
