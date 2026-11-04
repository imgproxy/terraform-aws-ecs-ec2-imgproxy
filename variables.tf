# ── Basic Configuration ───────────────────────────────────────────────────────

variable "service_name" {
  type        = string
  default     = "imgproxy"
  description = "Prefix applied to every resource name."
}

variable "tag" {
  type        = string
  default     = "v4"
  description = "imgproxy image tag (version)."
}

variable "repo" {
  type        = string
  default     = null
  description = "Container repository to pull imgproxy from, without tag (e.g. 'registry.example.com/imgproxy' or '123456789012.dkr.ecr.us-east-1.amazonaws.com/imgproxy'). When null, 'pro' selects docker.imgproxy.pro/imgproxy or ghcr.io/imgproxy/imgproxy. ECR repositories in the same account are pulled with the execution role and need no credentials; for any other private registry set repo_credentials_secret."
}

variable "repo_credentials_secret" {
  type = object({
    arn = string
  })
  default     = null
  description = "Secrets Manager secret with the credentials for the registry in 'repo' (or docker.imgproxy.pro when 'repo' is not set). Must be a JSON secret with 'username' and 'password' keys (ECS repositoryCredentials). Required when pro = true and repo is not set; the execution role is granted read access to it."
}

variable "environment" {
  type        = map(string)
  default     = {}
  description = "Additional environment variables passed to imgproxy (e.g. IMGPROXY_MAX_SRC_RESOLUTION)."
}

variable "secrets" {
  type = map(object({
    arn     = string
    version = optional(string, "")
  }))
  default     = {}
  description = "Map of environment variable names to Secrets Manager ARNs. Example: {IMGPROXY_NEW_RELIC_KEY = {arn = \"arn:aws:secretsmanager:us-east-1:123:secret:newrelic-key\"}}."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all created resources."
}

# ── Security & Signing ────────────────────────────────────────────────────────

variable "insecure" {
  type        = bool
  default     = false
  description = "Disable URL signature checks. When true, key and salt are not required."
}

variable "keys_secret" {
  type = object({
    arn     = string
    version = optional(string, "")
  })
  default     = null
  description = "Secrets Manager ARN for imgproxy signing keys (comma-separated hex-encoded values). Required when insecure = false. Generate: openssl rand -hex 64. Sets IMGPROXY_KEY."
}

variable "salts_secret" {
  type = object({
    arn     = string
    version = optional(string, "")
  })
  default     = null
  description = "Secrets Manager ARN for imgproxy signing salts (must match number of keys). Required when insecure = false. Sets IMGPROXY_SALT."
}

variable "secret_secret" {
  type = object({
    arn     = string
    version = optional(string, "")
  })
  default     = null
  description = "Secrets Manager ARN for the authorization token. When set, requests must include Authorization: Bearer <token>. Sets IMGPROXY_SECRET."
}

variable "signature_size" {
  type        = number
  default     = 32
  description = "Number of bytes from the key/salt used for signing. Sets IMGPROXY_SIGNATURE_SIZE."
}

variable "trusted_signatures_secret" {
  type = object({
    arn     = string
    version = optional(string, "")
  })
  default     = null
  description = "Secrets Manager ARN for trusted signature prefixes. imgproxy Pro only. Sets IMGPROXY_TRUSTED_SIGNATURES."
}

variable "source_url_encryption_key_secret" {
  type = object({
    arn     = string
    version = optional(string, "")
  })
  default     = null
  description = "Secrets Manager ARN for the source URL encryption key. Sets IMGPROXY_SOURCE_URL_ENCRYPTION_KEY."
}

# ── Compute Resources ─────────────────────────────────────────────────────────

variable "cpu_architecture" {
  type        = string
  default     = "ARM64"
  description = "CPU architecture for the container and EC2 instances. ARM64 (Graviton: c6g/c7g/c8g) is recommended: lower cost, better throughput. Must match the instance type family and the image platform."
  validation {
    condition     = contains(["ARM64", "X86_64"], var.cpu_architecture)
    error_message = "cpu_architecture must be ARM64 or X86_64."
  }
}

variable "spot" {
  type        = bool
  default     = false
  description = "Use EC2 Spot instances with price-capacity-optimized allocation. Set spot_instance_types to provide multiple instance types for better availability."
}

variable "instance_type" {
  type        = string
  default     = "c6g.medium"
  description = "EC2 instance type for ECS cluster nodes."
}

variable "spot_instance_types" {
  type        = list(string)
  default     = []
  description = "Additional EC2 instance types for the Spot pool alongside instance_type. More types = better availability and fewer interruptions. Only used when spot = true."
}

variable "spot_on_demand_base" {
  type        = number
  default     = 0
  description = "Minimum number of On-Demand instances to maintain regardless of spot_on_demand_percentage. Only used when spot = true."
}

variable "spot_on_demand_percentage" {
  type        = number
  default     = 0
  description = "Percentage of instances above spot_on_demand_base to run as On-Demand (0 = all Spot, 100 = all On-Demand). Only used when spot = true."
  validation {
    condition     = var.spot_on_demand_percentage >= 0 && var.spot_on_demand_percentage <= 100
    error_message = "spot_on_demand_percentage must be between 0 and 100."
  }
}

variable "ami_id" {
  type        = string
  default     = null
  description = "Bottlerocket ECS-optimized AMI ID. When null, the latest Bottlerocket AMI is resolved from SSM automatically."
}

variable "data_volume_size" {
  type        = number
  default     = 20
  description = "Size in GiB of the encrypted Bottlerocket data volume (container images and ephemeral storage)."
}

variable "cpu" {
  type        = number
  default     = 1
  description = "vCPUs allocated to the imgproxy container (cpu × 1024 CPU units). Sets IMGPROXY_WORKERS default."

  validation {
    condition     = var.cpu > 0
    error_message = "cpu must be greater than 0."
  }
}

variable "memory" {
  type        = string
  default     = "1024Mi"
  description = "Memory limit for the imgproxy container. Accepts Mi or Gi suffix (e.g. '512Mi', '2Gi'). Must fit on the instance type together with the OTEL sidecar when enabled."

  validation {
    condition     = can(regex("^[0-9]+(Mi|Gi)$", var.memory))
    error_message = "memory must be a whole number with an Mi or Gi suffix, e.g. '1024Mi' or '2Gi'."
  }
}

variable "workers" {
  type        = number
  default     = null
  description = "Number of concurrent requests per container. Sets IMGPROXY_WORKERS. Defaults to cpu × 2."
}

variable "timeout" {
  type        = number
  default     = null
  description = "Request timeout in seconds. Sets IMGPROXY_TIMEOUT."
}

# ── Storage Integration ───────────────────────────────────────────────────────

variable "source_buckets" {
  type        = list(string)
  default     = []
  description = "S3 bucket names for imgproxy source images. The task role is granted s3:GetObject, s3:GetObjectVersion and s3:ListBucket on each. Enables IMGPROXY_USE_S3."
}

variable "cache_bucket" {
  type        = string
  default     = null
  description = "S3 bucket name for imgproxy result cache (imgproxy Pro only). The task role is granted full object access."
}

# ── Scaling ───────────────────────────────────────────────────────────────────

variable "min_instances" {
  type        = number
  default     = 1
  description = "Minimum number of EC2 instances in the Auto Scaling Group."
}

variable "max_instances" {
  type        = number
  default     = 10
  description = "Maximum number of EC2 instances in the Auto Scaling Group."
}

variable "target_capacity" {
  type        = number
  default     = 100
  description = "Target capacity utilization percentage for ECS managed scaling (1–100). Values below 100 keep spare EC2 capacity for faster task placement."
  validation {
    condition     = var.target_capacity >= 1 && var.target_capacity <= 100
    error_message = "target_capacity must be between 1 and 100."
  }
}

variable "warm_pool" {
  type        = bool
  default     = false
  description = "Create an ASG warm pool of pre-initialized instances for faster scale-out. Incompatible with spot = true."
}

variable "managed_termination_protection" {
  type        = bool
  default     = true
  description = "Enable ECS managed termination protection on ASG instances. When true, ECS prevents scale-in of instances that have running tasks. Disable for faster terraform destroy in dev/test environments."
}

variable "desired_count" {
  type        = number
  default     = null
  description = "Desired number of ECS tasks. Defaults to task_min_count. Changes after initial creation are ignored (managed by ECS auto-scaling)."
}

variable "task_min_count" {
  type        = number
  default     = 1
  description = "Minimum number of ECS tasks for Application Auto Scaling."
}

variable "task_max_count" {
  type        = number
  default     = 10
  description = "Maximum number of ECS tasks for Application Auto Scaling."
}

variable "deployment_minimum_healthy_percent" {
  type        = number
  default     = 100
  description = "Minimum percentage of healthy tasks during a rolling deployment. 100 = zero-downtime (new task starts before old stops). 0 = fastest deploy (brief outage). With task_min_count = 1, a value of 50 allows a zero-task gap."
  validation {
    condition     = var.deployment_minimum_healthy_percent >= 0 && var.deployment_minimum_healthy_percent <= 100
    error_message = "deployment_minimum_healthy_percent must be between 0 and 100."
  }
}

# ── imgproxy Pro ──────────────────────────────────────────────────────────────

variable "pro" {
  type        = bool
  default     = false
  description = "Use imgproxy Pro (docker.imgproxy.pro) instead of the community image (ghcr.io) as the default repo. Has no effect when repo is set."
}

variable "pro_license_key_secret" {
  type = object({
    arn     = string
    version = optional(string, "")
  })
  default     = null
  description = "Secrets Manager ARN for the imgproxy Pro license key. Sets IMGPROXY_LICENSE_KEY."
}

# ── Observability & Monitoring ────────────────────────────────────────────────

variable "enable_monitoring" {
  type        = bool
  default     = false
  description = "Enable the AWS Distro for OpenTelemetry (ADOT) sidecar container to export traces and metrics to X-Ray and CloudWatch. Automatically configures imgproxy OTEL environment variables."
}

variable "otel_collector_config" {
  type        = string
  default     = null
  description = "OpenTelemetry Collector configuration YAML passed to the ADOT sidecar via AOT_CONFIG_CONTENT. When null, a default config exporting to X-Ray and CloudWatch is used."
}

variable "log_retention_days" {
  type        = number
  default     = 365
  description = "CloudWatch log group retention in days."
}

# ── Networking ────────────────────────────────────────────────────────────────

variable "vpc_id" {
  type        = string
  description = "VPC ID to deploy the ECS cluster and ALB into."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnet IDs for EC2 instances. Use private subnets with a NAT gateway (recommended), or public subnets with assign_public_ip = true."
}

variable "alb_subnet_ids" {
  type        = list(string)
  default     = null
  description = "Subnet IDs for the Application Load Balancer. When null, uses subnet_ids. Set to public subnets when instances are in private subnets."
}

variable "internal_alb" {
  type        = bool
  default     = false
  description = "Create an internal (non-internet-facing) ALB. Use for private deployments accessed via VPC only."
}

variable "assign_public_ip" {
  type        = bool
  default     = false
  description = "Assign a public IP to EC2 instances. Off by default: run the instances in private subnets with a NAT gateway (or VPC endpoints). Set to true only when the subnets are public, such as those of the default VPC: instances then need it to pull the image, and every instance is directly addressable by IP (the instance security group still only accepts the ALB on the ECS dynamic port range)."
}

variable "additional_security_group_ids" {
  type        = list(string)
  default     = []
  description = "Additional security group IDs to attach to EC2 instances."
}

# ── Load Balancer ─────────────────────────────────────────────────────────────

variable "create_alb" {
  type        = bool
  default     = true
  description = "Create an Application Load Balancer for the ECS service."
}

variable "alb_certificate_arns" {
  type        = list(string)
  default     = []
  description = "ACM certificate ARNs for the HTTPS listener. Required unless allow_insecure_http = true. Creates a port 443 HTTPS listener; the first ARN is the primary certificate and additional ARNs are attached as SNI extras."
}

variable "allow_insecure_http" {
  type        = bool
  default     = false
  description = "Allow the ALB to serve plain HTTP only, that is, without alb_certificate_arns. For testing only: requests, signed URLs and tokens travel unencrypted. With CloudFront it also makes CloudFront reach the ALB over plain HTTP, so the origin secret header and all traffic cross the network in clear text."
}

variable "alb_redirect_http_to_https" {
  type        = bool
  default     = true
  description = "Redirect HTTP to HTTPS on the ALB. Requires alb_certificate_arns to be set."
}

variable "alb_idle_timeout" {
  type        = number
  default     = 60
  description = "ALB connection idle timeout in seconds."
}

variable "alb_deregistration_delay" {
  type        = number
  default     = 60
  description = "Seconds the ALB waits before deregistering a target during deployments and scale-in. Must be >= alb_idle_timeout to avoid in-flight connection resets."
}

variable "alb_deletion_protection" {
  type        = bool
  default     = false
  description = "Enable deletion protection on the ALB."
}

variable "allow_public_access" {
  type        = bool
  default     = true
  description = "Allow public internet access to the ALB (0.0.0.0/0 on port 80/443)."
}

# ── CloudFront CDN ────────────────────────────────────────────────────────────

variable "enable_cloudfront" {
  type        = bool
  default     = false
  description = "Create a CloudFront distribution in front of the ALB for global edge caching. Requires create_alb = true."
}

variable "cloudfront_origin_domain" {
  type        = string
  default     = null
  description = "Domain name CloudFront uses to reach the ALB over HTTPS, for example 'origin.example.com'. Create a DNS record for it that points at the ALB (see the alb_dns_name and alb_zone_id outputs) and cover it with a certificate in alb_certificate_arns. Required when enable_cloudfront = true and alb_certificate_arns is set, because CloudFront validates the ALB certificate against this name. Must differ from cloudfront_domains."
}

variable "cloudfront_certificate_arn" {
  type        = string
  default     = null
  description = "ACM certificate ARN for CloudFront (must be in us-east-1). Required when cloudfront_domains is set."
}

variable "cloudfront_domains" {
  type        = list(string)
  default     = []
  description = "Custom domain aliases for the CloudFront distribution. Requires cloudfront_certificate_arn."
}

variable "cloudfront_origin_shield_region" {
  type        = string
  default     = null
  description = "AWS region to enable CloudFront Origin Shield (e.g. \"us-east-1\"). Adds an extra caching tier between edge locations and the ALB, reducing origin load. When null, Origin Shield is disabled."
}

variable "cdn_default_ttl" {
  type        = number
  default     = 31536000
  description = "Default CloudFront TTL in seconds. Set to 0 to let CloudFront respect origin Cache-Control headers."
}

variable "cdn_min_ttl" {
  type        = number
  default     = 0
  description = "Minimum CloudFront TTL in seconds. Set to a positive value to force a floor TTL regardless of origin headers."
}

variable "cdn_max_ttl" {
  type        = number
  default     = 31556926
  description = "Maximum CloudFront TTL in seconds, regardless of origin headers."
}

variable "cdn_redirect_http_to_https" {
  type        = bool
  default     = true
  description = "Redirect HTTP to HTTPS at the CloudFront level."
}

variable "cdn_waf_web_acl_id" {
  type        = string
  default     = null
  description = "WAF Web ACL ARN to associate with the CloudFront distribution."
}

# ── IAM ───────────────────────────────────────────────────────────────────────

variable "task_role_arn" {
  type        = string
  default     = null
  description = "ARN of an existing IAM role to use as the ECS task role. When null, a role is created with S3 and monitoring permissions as needed."
}

variable "execution_role_arn" {
  type        = string
  default     = null
  description = "ARN of an existing IAM role to use as the ECS task execution role. When null, a role is created with ECR pull and Secrets Manager access."
}
