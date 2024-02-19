
output "cloudwatch_log_group_arn" {
  description = "ARN"
  value       = aws_cloudwatch_log_group.cloudwatch.arn
}

output "cloudwatch_log_group_name" {
  description = "Name"
  value       = aws_cloudwatch_log_group.cloudwatch.name
}