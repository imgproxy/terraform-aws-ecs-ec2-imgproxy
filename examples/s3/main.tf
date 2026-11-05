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
  # reclaimed instance are simply replaced. Extra instance types improve Spot availability.
  spot                = true
  spot_instance_types = ["c7g.medium", "m6g.medium"]

  vpc_id     = data.aws_vpc.default.id
  subnet_ids = data.aws_subnets.default.ids

  # Testing opt-ins: the module is private and encrypted by default. The default VPC has only public
  # subnets and this example has no domain, so both defaults are waived here. For production see
  # "Production setup" in the signed example.
  assign_public_ip    = true # instances in public subnets need a public IP to pull the image
  allow_insecure_http = true # plain HTTP on the ALB: requests and signed URLs are unencrypted

  # Existing bucket (see README): grants read access and enables the s3:// URL scheme
  source_buckets = ["${data.aws_caller_identity.current.account_id}-imgproxy-images"]

  environment = {
    # The region the bucket lives in
    IMGPROXY_S3_REGION = var.region
  }
}

output "url" {
  value = module.imgproxy.url
}
