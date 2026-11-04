output "url" {
  description = "imgproxy endpoint URL. CloudFront domain when enable_cloudfront = true, otherwise ALB DNS name."
  value       = module.aws_common.url
}

output "service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.main.name
}

output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.main.name
}

output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.main.arn
}

output "task_role_arn" {
  description = "ARN of the IAM role used by the imgproxy task at runtime."
  value       = module.aws_common.task_role_arn
}

output "execution_role_arn" {
  description = "ARN of the IAM role used by the ECS agent to start tasks."
  value       = module.aws_common.execution_role_arn
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer."
  value       = module.aws_common.alb_dns_name
}

output "alb_zone_id" {
  description = "Hosted zone ID of the ALB. Use with Route 53 alias records."
  value       = module.aws_common.alb_zone_id
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name."
  value       = module.aws_common.cloudfront_domain_name
}

output "cloudfront_hosted_zone_id" {
  description = "CloudFront hosted zone ID. Use with Route 53 alias records."
  value       = module.aws_common.cloudfront_hosted_zone_id
}

output "instances_security_group_id" {
  description = "Security group ID attached to the ECS EC2 instances."
  value       = aws_security_group.instances.id
}

output "autoscaling_group_name" {
  description = "Name of the Auto Scaling Group running the ECS instances."
  value       = aws_autoscaling_group.main.name
}

output "alb_security_group_id" {
  description = "Security group ID of the Application Load Balancer (null without an ALB). Use it to add ingress rules, e.g. for an internal ALB."
  value       = module.aws_common.alb_sg_id
}

output "log_group_name" {
  description = "CloudWatch Log Group name for imgproxy and OTEL sidecar logs."
  value       = module.aws_common.log_group_name
}
