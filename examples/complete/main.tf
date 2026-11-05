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

data "aws_caller_identity" "current" {}

# The default VPC only has public subnets: fine for trying the module out.
# For production, run the instances in private subnets (see the commented-out settings below).
data "aws_vpc" "default" {
  default = true
}

# Not every AZ offers every instance type (Graviton in particular): keep only the AZs that do.
data "aws_ec2_instance_type_offerings" "available" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [local.instance_types[0]]
  }
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "availability-zone"
    values = data.aws_ec2_instance_type_offerings.available.locations
  }
}

data "aws_secretsmanager_secret" "keys" {
  name = "imgproxy-keys"
}

data "aws_secretsmanager_secret" "salts" {
  name = "imgproxy-salts"
}

data "aws_secretsmanager_secret" "pro_license" {
  name = "imgproxy-pro-license"
}

data "aws_secretsmanager_secret" "pro_registry" {
  name = "imgproxy-pro-registry"
}

# Optional secrets, used by the commented-out options below
# data "aws_secretsmanager_secret" "secret" {
#   name = "imgproxy-secret"
# }
# data "aws_secretsmanager_secret" "source_url_key" {
#   name = "imgproxy-source-url-key"
# }

locals {
  instance_types = ["c6g.medium", "c7g.medium", "m6g.medium"] # the first one is the primary
  source_bucket  = "${data.aws_caller_identity.current.account_id}-imgproxy-complete-source"
  cache_bucket   = "${data.aws_caller_identity.current.account_id}-imgproxy-complete-cache"
}

module "imgproxy" {
  source  = "imgproxy/ecs-ec2-imgproxy/aws"
  version = "~> 0.1"

  service_name = "imgproxy"
  tag          = "v4"

  # Security: request signing
  keys_secret = {
    arn = data.aws_secretsmanager_secret.keys.arn
  }
  salts_secret = {
    arn = data.aws_secretsmanager_secret.salts.arn
  }
  signature_size = 32

  # Optional: Bearer token auth (cannot be used with enable_cloudfront = true)
  # secret_secret = {
  #   arn = data.aws_secretsmanager_secret.secret.arn
  # }

  # Optional: source URL encryption
  # source_url_encryption_key_secret = {
  #   arn = data.aws_secretsmanager_secret.source_url_key.arn
  # }

  # imgproxy Pro. The registry credentials are a JSON secret with "username" and "password" keys.
  pro = true
  repo_credentials_secret = {
    arn = data.aws_secretsmanager_secret.pro_registry.arn
  }
  pro_license_key_secret = {
    arn = data.aws_secretsmanager_secret.pro_license.arn
  }

  # Optional: pull from your own registry instead (pro then no longer affects the image).
  # An ECR repository in this account needs no credentials; other registries need repo_credentials_secret.
  # repo = "123456789012.dkr.ecr.us-east-1.amazonaws.com/imgproxy-custom"

  # Optional: trusted signatures (Pro only)
  # trusted_signatures_secret = {
  #   arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy-trusted-sigs-AbCdEf"
  # }

  # Optional: additional secrets for third-party integrations
  # secrets = {
  #   IMGPROXY_NEW_RELIC_KEY = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:newrelic-license-AbCdEf" }
  #   IMGPROXY_SENTRY_DSN    = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sentry-dsn-AbCdEf", version = "3" }
  # }

  # Existing buckets (see README): source images and result cache (Pro)
  source_buckets = [local.source_bucket]
  cache_bucket   = local.cache_bucket

  # Monitoring (ADOT collector sidecar: X-Ray traces, CloudWatch metrics and logs)
  enable_monitoring = true

  # Compute resources
  cpu     = 0.5
  memory  = "1Gi"
  workers = 2
  timeout = 60

  # Spot instances: up to 90% cheaper than On-Demand. imgproxy is stateless, so tasks on a
  # reclaimed instance are simply replaced. More instance types improve Spot availability.
  spot                = true
  spot_instance_types = slice(local.instance_types, 1, length(local.instance_types))

  # Scaling
  # The instance must fit the container (cpu, memory) plus the OTEL sidecar.
  instance_type  = local.instance_types[0]
  min_instances  = 2
  max_instances  = 20
  task_min_count = 2
  task_max_count = 20

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
  # images from the internet); see "Production setup" in the signed example.
  # vpc_id               = "vpc-0123456789abcdef0"
  # subnet_ids           = ["subnet-0aaa...", "subnet-0bbb..."] # private: the instances
  # alb_subnet_ids       = ["subnet-0ccc...", "subnet-0ddd..."] # public: the internet-facing ALB
  # alb_certificate_arns = ["arn:aws:acm:us-east-1:123456789012:certificate/..."]

  # Optional: CloudFront CDN (requires a domain name). CloudFront reaches the ALB over HTTPS, so it
  # also needs the ALB certificate above and an origin name that certificate covers:
  #   - create a DNS record for cloudfront_origin_domain pointing at the ALB (outputs alb_dns_name, alb_zone_id)
  #   - cloudfront_certificate_arn must be issued in us-east-1
  enable_cloudfront = true
  # cloudfront_origin_domain        = "origin.example.com"
  # cloudfront_domains              = ["cdn.example.com"]
  # cloudfront_certificate_arn      = "arn:aws:acm:us-east-1:123456789012:certificate/..."
  # cloudfront_origin_shield_region = "us-east-1"
  # cdn_default_ttl                 = 3600
  # cdn_max_ttl                     = 86400
  # allow_insecure_http = true

  # Logs
  log_retention_days = 90

  # Tags
  tags = {
    app  = "imgproxy"
    team = "platform"
  }

  # Additional imgproxy configuration
  environment = {
    IMGPROXY_MAX_SRC_RESOLUTION = "50.0"
    IMGPROXY_JPEG_PROGRESSIVE   = "true"
    IMGPROXY_S3_REGION          = var.region
    IMGPROXY_CACHE_USE          = "s3"
    IMGPROXY_CACHE_BUCKET       = local.cache_bucket
  }
}

output "url" {
  description = "The URL of the deployed imgproxy service"
  value       = module.imgproxy.url
}

output "alb_dns_name" {
  description = "ALB DNS name. Point a DNS record for the load balancer at it"
  value       = module.imgproxy.alb_dns_name
}

output "cloudfront_domain_name" {
  description = "CloudFront domain (when CloudFront is enabled). Point a CNAME (or a Route 53 alias) for your own domain at it"
  value       = module.imgproxy.cloudfront_domain_name
}

output "log_group_name" {
  description = "CloudWatch Logs group of imgproxy and the collector sidecar"
  value       = module.imgproxy.log_group_name
}
