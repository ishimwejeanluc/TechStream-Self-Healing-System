# The single command the Lambda is allowed to run. Using a custom document
# instead of AWS-RunShellScript is what makes least privilege possible: the
# Lambda can run this exact script and nothing else. Granting SendCommand on
# AWS-RunShellScript would be equivalent to arbitrary root on the instance.
resource "aws_ssm_document" "restart_app" {
  name            = "${var.name}-restart-app"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Restart the TechStream app container in response to HighErrorRate."
    parameters    = {}
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "restartApp"
        inputs = {
          timeoutSeconds = "300"
          runCommand = [
            "set -euxo pipefail",
            "cd ${var.app_dir}/monitoring",
            "docker compose restart ${var.compose_service}",
            "docker compose ps ${var.compose_service}",
          ]
        }
      }
    ]
  })

  tags = {
    Name = "${var.name}-restart-app"
  }
}
