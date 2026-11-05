terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "profile" {
  description = "AWS CLI profile used by the provider (null = default credentials / AWS_PROFILE)"
  type        = string
  default     = null
}

provider "aws" {
  region  = var.region
  profile = var.profile
}

# The default VPC only has public subnets: fine for trying the module out.
# For production, run the instances in private subnets (see the signed example).
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_secretsmanager_secret" "keys" {
  name = "imgproxy-keys"
}

data "aws_secretsmanager_secret" "salts" {
  name = "imgproxy-salts"
}

module "imgproxy" {
  source  = "imgproxy/ecs-ec2-imgproxy/aws"
  version = "~> 0.1"

  service_name = "imgproxy"
  tag          = "v4"

  keys_secret = {
    arn = data.aws_secretsmanager_secret.keys.arn
  }
  salts_secret = {
    arn = data.aws_secretsmanager_secret.salts.arn
  }

  # Spot instances: up to 90% cheaper than On-Demand. imgproxy is stateless, so tasks on a
  # reclaimed instance are simply replaced. More instance types improve Spot availability.
  spot                = true
  spot_instance_types = ["c7g.medium", "m6g.medium"]

  vpc_id     = data.aws_vpc.default.id
  subnet_ids = data.aws_subnets.default.ids

  # Testing opt-ins: the module is private and encrypted by default. The default VPC has only public
  # subnets and this example has no domain, so both defaults are waived here. For production see
  # "Production setup" in the signed example.
  assign_public_ip    = true # instances in public subnets need a public IP to pull the image
  allow_insecure_http = true # plain HTTP on the ALB: requests and signed URLs are unencrypted

  enable_cloudfront = true

  # With allow_insecure_http, CloudFront reaches the ALB over plain HTTP, so the secret header that
  # locks the ALB to CloudFront and all traffic cross the network in clear text. Testing only.
  # Production: serve the ALB over HTTPS and let CloudFront validate it (remove allow_insecure_http):
  #   1. Request an ACM certificate in this region for an origin name such as origin.example.com.
  #   2. Create a DNS record for that name pointing at the ALB (outputs alb_dns_name, alb_zone_id).
  # alb_certificate_arns     = ["arn:aws:acm:us-east-1:123456789012:certificate/..."]
  # cloudfront_origin_domain = "origin.example.com"

  # With a domain, CloudFront serves it over HTTPS using an ACM certificate issued in us-east-1:
  # cloudfront_domains         = ["cdn.example.com"]
  # cloudfront_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/..."

  cdn_default_ttl = 3600
  cdn_max_ttl     = 86400
}

output "url" {
  value = module.imgproxy.url
}

output "alb_dns_name" {
  value       = module.imgproxy.alb_dns_name
  description = "ALB DNS name. Point the cloudfront_origin_domain record at it in production"
}

output "alb_zone_id" {
  value       = module.imgproxy.alb_zone_id
  description = "ALB hosted zone ID, for Route 53 alias records"
}

output "cloudfront_domain_name" {
  value       = module.imgproxy.cloudfront_domain_name
  description = "CloudFront domain. Point a CNAME (or a Route 53 alias) for your own domain at it"
}

output "cloudfront_hosted_zone_id" {
  value       = module.imgproxy.cloudfront_hosted_zone_id
  description = "CloudFront hosted zone ID, for Route 53 alias records"
}
