output "instance_id" {
  description = "EC2 instance ID. The Lambda's SendCommand targets this."
  value       = aws_instance.app.id
}

output "instance_arn" {
  description = "EC2 instance ARN, used to scope the Lambda's ssm:SendCommand policy."
  value       = aws_instance.app.arn
}

output "public_ip" {
  description = "Public IPv4 address."
  value       = aws_instance.app.public_ip
}

output "iam_role_name" {
  description = "Instance role name."
  value       = aws_iam_role.instance.name
}

output "app_dir" {
  description = "Directory the repo is synced to."
  value       = var.app_dir
}
