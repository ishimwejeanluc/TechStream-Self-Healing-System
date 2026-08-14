output "ssm_document_name" {
  description = "Name of the custom restart document."
  value       = aws_ssm_document.restart_app.name
}

output "ssm_document_arn" {
  description = "ARN of the custom restart document."
  value       = aws_ssm_document.restart_app.arn
}

output "lambda_function_name" {
  description = "Lambda function name, for reading logs."
  value       = aws_lambda_function.remediator.function_name
}

output "lambda_function_url" {
  description = "Base Function URL. Alertmanager posts here with ?token= appended."
  value       = aws_lambda_function_url.remediator.function_url
}

output "lambda_log_group" {
  description = "CloudWatch Logs group holding the command IDs."
  value       = aws_cloudwatch_log_group.lambda.name
}

output "lambda_role_arn" {
  description = "Lambda execution role ARN."
  value       = aws_iam_role.lambda.arn
}
