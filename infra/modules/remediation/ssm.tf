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
            # "set -eu", NOT "set -euxo pipefail".
            #
            # SSM's aws:runShellScript executes the script with /bin/sh, which is
            # dash on Ubuntu, and dash has no pipefail. The bash form fails on
            # line 1 with "Illegal option -o pipefail" and exit status 2, before
            # running anything. There are no pipes here, so pipefail adds nothing.
            # -x is kept because dash supports it and the trace lands in the SSM
            # command output, which is where you debug this from.
            "set -eux",
            # docker-compose.yml is at the repo root, not under monitoring/,
            # because it composes both the app and the monitoring stack.
            "cd ${var.restart_dir}",
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
