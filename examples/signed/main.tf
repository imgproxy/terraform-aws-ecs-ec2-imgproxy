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

# The default VPC only has public subnets, so this example runs in it to stay self-contained.
# For production, use your own VPC with private subnets and HTTPS: see "Production setup" in the
# README and the commented-out settings in the module block below.
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

  # Request signing (required for production)
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

  # Networking: instances in public subnets of the default VPC
  vpc_id     = data.aws_vpc.default.id
  subnet_ids = data.aws_subnets.default.ids

  # Testing opt-ins: the module is private and encrypted by default. The default VPC has only public
  # subnets and this example has no domain, so both defaults are waived here. For production, drop
  # them and use the settings below.
  assign_public_ip    = true # instances in public subnets need a public IP to pull the image
  allow_insecure_http = true # plain HTTP on the ALB: requests and signed URLs are unencrypted

  # Production: instances in private subnets, only the load balancer public, HTTPS on the load balancer.
  # The private subnets need a route to a NAT gateway (the instances pull the image and fetch source
  # images from the internet); see "Production setup" in the README.
  # vpc_id               = "vpc-0123456789abcdef0"
  # subnet_ids           = ["subnet-0aaa...", "subnet-0bbb..."] # private: the instances
  # alb_subnet_ids       = ["subnet-0ccc...", "subnet-0ddd..."] # public: the internet-facing ALB
  # alb_certificate_arns = ["arn:aws:acm:us-east-1:123456789012:certificate/..."]
}

output "url" {
  value = module.imgproxy.url
}

output "alb_dns_name" {
  value       = module.imgproxy.alb_dns_name
  description = "ALB DNS name. Point your domain at it when you attach a certificate"
}

output "alb_zone_id" {
  value       = module.imgproxy.alb_zone_id
  description = "ALB hosted zone ID, for Route 53 alias records"
}
