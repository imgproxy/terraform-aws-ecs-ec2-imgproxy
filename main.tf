data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "bottlerocket_ami" {
  count = var.ami_id == null ? 1 : 0
  name  = "/aws/service/bottlerocket/aws-ecs-2/${var.cpu_architecture == "ARM64" ? "arm64" : "x86_64"}/latest/image_id"
}

locals {
  # Image repository: `repo` when set, otherwise the default selected by `pro`
  image_repo = var.repo != null ? var.repo : (var.pro ? "docker.imgproxy.pro/imgproxy" : "ghcr.io/imgproxy/imgproxy")
}

module "imgproxy_common" {
  source = "./modules/imgproxy-common"

  tag  = var.tag
  repo = local.image_repo

  cpu            = var.cpu
  workers        = var.workers
  timeout        = var.timeout
  signature_size = var.signature_size

  secret_key_name   = "arn"
  storage_env_key   = "IMGPROXY_USE_S3"
  storage_enabled   = length(var.source_buckets) > 0
  enable_monitoring = var.enable_monitoring
  otel_service_name = var.service_name
  # Bridge networking: containers do not share localhost, so reach the sidecar by its linked name.
  otel_exporter_endpoint = "http://otel-collector:4318"

  insecure    = var.insecure
  environment = var.environment
  secrets     = { for k, v in var.secrets : k => { id = v.arn, version = v.version } }

  keys_secret                      = var.keys_secret != null ? { id = var.keys_secret.arn, version = var.keys_secret.version } : null
  salts_secret                     = var.salts_secret != null ? { id = var.salts_secret.arn, version = var.salts_secret.version } : null
  secret_secret                    = var.secret_secret != null ? { id = var.secret_secret.arn, version = var.secret_secret.version } : null
  trusted_signatures_secret        = var.trusted_signatures_secret != null ? { id = var.trusted_signatures_secret.arn, version = var.trusted_signatures_secret.version } : null
  source_url_encryption_key_secret = var.source_url_encryption_key_secret != null ? { id = var.source_url_encryption_key_secret.arn, version = var.source_url_encryption_key_secret.version } : null
  pro_license_key_secret           = var.pro_license_key_secret != null ? { id = var.pro_license_key_secret.arn, version = var.pro_license_key_secret.version } : null
}

locals {
  image           = module.imgproxy_common.image
  env_vars        = module.imgproxy_common.env_vars
  env_secret_vars = module.imgproxy_common.env_secret_vars

  ami_id = var.ami_id != null ? var.ami_id : data.aws_ssm_parameter.bottlerocket_ami[0].value

  cloudwatch_env_vars = {
    IMGPROXY_CLOUD_WATCH_SERVICE_NAME = var.service_name
    IMGPROXY_CLOUD_WATCH_NAMESPACE    = "imgproxy"
    IMGPROXY_CLOUD_WATCH_REGION       = data.aws_region.current.name
  }

  memory_mb     = endswith(var.memory, "Gi") ? tonumber(trimsuffix(var.memory, "Gi")) * 1024 : tonumber(trimsuffix(var.memory, "Mi"))
  cpu_units     = var.cpu * 1024
  desired_count = coalesce(var.desired_count, var.task_min_count)

  secret_arns = distinct(compact(concat(
    [for k, v in local.env_secret_vars : v["arn"]],
    var.repo_credentials_secret != null ? [var.repo_credentials_secret.arn] : []
  )))

  ecs_secrets = [for k, v in local.env_secret_vars : {
    name      = k
    valueFrom = v["version"] != "" ? "${v["arn"]}:::${v["version"]}" : v["arn"]
  }]
}

module "aws_common" {
  source = "./modules/aws-common"

  service_name = var.service_name
  tags         = var.tags

  execution_role_arn = var.execution_role_arn
  task_role_arn      = var.task_role_arn
  source_buckets     = var.source_buckets
  cache_bucket       = var.cache_bucket
  enable_monitoring  = var.enable_monitoring
  secret_arns        = local.secret_arns
  log_retention_days = var.log_retention_days

  vpc_id         = var.vpc_id
  subnet_ids     = var.subnet_ids
  alb_subnet_ids = var.alb_subnet_ids

  create_alb                 = var.create_alb
  alb_target_type            = "instance"
  internal_alb               = var.internal_alb
  allow_public_access        = var.allow_public_access
  alb_certificate_arns       = var.alb_certificate_arns
  allow_insecure_http        = var.allow_insecure_http
  alb_redirect_http_to_https = var.alb_redirect_http_to_https
  alb_idle_timeout           = var.alb_idle_timeout
  alb_deregistration_delay   = var.alb_deregistration_delay
  alb_deletion_protection    = var.alb_deletion_protection

  enable_cloudfront               = var.enable_cloudfront
  cloudfront_certificate_arn      = var.cloudfront_certificate_arn
  cloudfront_origin_domain        = var.cloudfront_origin_domain
  cloudfront_domains              = var.cloudfront_domains
  cloudfront_origin_shield_region = var.cloudfront_origin_shield_region
  cdn_default_ttl                 = var.cdn_default_ttl
  cdn_min_ttl                     = var.cdn_min_ttl
  cdn_max_ttl                     = var.cdn_max_ttl
  cdn_redirect_http_to_https      = var.cdn_redirect_http_to_https
  cdn_waf_web_acl_id              = var.cdn_waf_web_acl_id
  cdn_cache_headers               = module.imgproxy_common.cdn_cache_headers
  cdn_cache_cookies               = module.imgproxy_common.cdn_cache_cookies
}

# ── IAM: EC2 instance role ────────────────────────────────────────────────────
# Allows ECS agent on EC2 instances to register with the cluster and pull images.

resource "aws_iam_role" "instance" {
  name_prefix = "${var.service_name}-instance-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "instance_ecs" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# Session Manager access replaces SSH: the instances need no inbound port.
resource "aws_iam_role_policy_attachment" "instance_ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "main" {
  name_prefix = "${var.service_name}-"
  role        = aws_iam_role.instance.name
}

# ── ECS Cluster ───────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = var.service_name

  setting {
    name  = "containerInsights"
    value = var.enable_monitoring ? "enabled" : "disabled"
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = !var.pro || var.repo != null || var.repo_credentials_secret != null
      error_message = "repo_credentials_secret is required when pro = true and repo is not set."
    }
    precondition {
      condition     = var.insecure || (var.keys_secret != null && var.salts_secret != null)
      error_message = "keys_secret and salts_secret are required when insecure = false."
    }
    precondition {
      condition     = !var.enable_monitoring || local.memory_mb > 256
      error_message = "memory must be greater than 256Mi when enable_monitoring = true (256Mi is reserved for the OTEL sidecar)."
    }
    precondition {
      condition     = !var.enable_cloudfront || var.create_alb
      error_message = "create_alb must be true when enable_cloudfront = true."
    }
    precondition {
      condition     = !var.enable_cloudfront || var.secret_secret == null
      error_message = "secret_secret cannot be used with enable_cloudfront = true. CloudFront does not forward the Authorization header."
    }
    precondition {
      condition     = length(var.cloudfront_domains) == 0 || var.cloudfront_certificate_arn != null
      error_message = "cloudfront_certificate_arn is required when cloudfront_domains is set."
    }
    precondition {
      condition     = !var.warm_pool || !var.spot
      error_message = "warm_pool cannot be used with spot = true."
    }
    precondition {
      condition     = var.task_max_count <= var.max_instances
      error_message = "task_max_count (${var.task_max_count}) must not exceed max_instances (${var.max_instances}). With default single-task-per-instance resources, ECS cannot place more tasks than instances. Increase max_instances or reduce task_max_count."
    }
    precondition {
      condition     = var.min_instances <= var.max_instances
      error_message = "min_instances must not exceed max_instances."
    }
    precondition {
      condition     = var.task_min_count <= var.task_max_count
      error_message = "task_min_count must not exceed task_max_count."
    }
    precondition {
      condition     = var.desired_count == null ? true : (var.desired_count >= var.task_min_count && var.desired_count <= var.task_max_count)
      error_message = "desired_count must be between task_min_count and task_max_count."
    }
    precondition {
      condition     = var.alb_deregistration_delay >= var.alb_idle_timeout
      error_message = "alb_deregistration_delay must be >= alb_idle_timeout to avoid resetting in-flight connections."
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = [aws_ecs_capacity_provider.main.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    weight            = 1
    base              = 1
  }
}

# ── Launch Template & Auto Scaling Group ─────────────────────────────────────

resource "aws_launch_template" "main" {
  name_prefix   = "${var.service_name}-"
  image_id      = local.ami_id
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.main.name
  }

  # Instances get a public IP only on request (assign_public_ip); the subnet's
  # auto-assign setting is overridden either way.
  network_interfaces {
    associate_public_ip_address = var.assign_public_ip
    delete_on_termination       = true
    security_groups = concat(
      [aws_security_group.instances.id],
      var.additional_security_group_ids
    )
  }

  user_data = base64encode(<<-TOML
    [settings.ecs]
    cluster = "${aws_ecs_cluster.main.name}"
    enable-spot-instance-draining = ${var.spot}
    TOML
  )

  # Bottlerocket root (xvda, OS) and data (xvdb, images and container volumes) disks.
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      encrypted             = true
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  block_device_mappings {
    device_name = "/dev/xvdb"
    ebs {
      encrypted             = true
      volume_type           = "gp3"
      volume_size           = var.data_volume_size
      delete_on_termination = true
    }
  }

  # IMDSv2 only, with a hop limit of 1: containers (bridge network, one extra hop)
  # cannot reach the instance role credentials. Task roles are served by the ECS agent.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.service_name}-ecs" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${var.service_name}-ecs" })
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "main" {
  name_prefix           = "${var.service_name}-"
  vpc_zone_identifier   = var.subnet_ids
  min_size              = var.min_instances
  max_size              = var.max_instances
  desired_capacity      = var.min_instances
  protect_from_scale_in = var.managed_termination_protection

  dynamic "launch_template" {
    for_each = var.spot ? [] : [1]
    content {
      id      = aws_launch_template.main.id
      version = aws_launch_template.main.latest_version
    }
  }

  dynamic "mixed_instances_policy" {
    for_each = var.spot ? [1] : []
    content {
      instances_distribution {
        on_demand_base_capacity                  = var.spot_on_demand_base
        on_demand_percentage_above_base_capacity = var.spot_on_demand_percentage
        spot_allocation_strategy                 = "price-capacity-optimized"
      }

      launch_template {
        launch_template_specification {
          launch_template_id = aws_launch_template.main.id
          version            = aws_launch_template.main.latest_version
        }

        dynamic "override" {
          for_each = concat([var.instance_type], var.spot_instance_types)
          content {
            instance_type = override.value
          }
        }
      }
    }
  }

  # A new launch template version (AMI, instance type, user data...) rolls the instances: new
  # ones start first, then old ones go. Protected instances are replaced too, otherwise ECS
  # managed termination protection would block the refresh forever.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage       = 100
      max_healthy_percentage       = 200
      instance_warmup              = 120
      scale_in_protected_instances = "Refresh"
    }
  }

  health_check_type         = var.create_alb ? "ELB" : "EC2"
  health_check_grace_period = 150
  force_delete              = true

  dynamic "warm_pool" {
    for_each = var.warm_pool ? [1] : []
    content {
      instance_reuse_policy {
        reuse_on_scale_in = false
      }
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.service_name}-ecs"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = var.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity]
  }
}

# ── ECS Capacity Provider ─────────────────────────────────────────────────────

resource "aws_ecs_capacity_provider" "main" {
  name = var.service_name

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.main.arn
    managed_termination_protection = var.managed_termination_protection ? "ENABLED" : "DISABLED"

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = var.target_capacity
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 100
      instance_warmup_period    = 300
    }
  }

  tags = var.tags

  depends_on = [aws_ecs_cluster.main]
}

# ── ECS Task Definition ───────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "main" {
  family                   = var.service_name
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  task_role_arn            = module.aws_common.task_role_arn
  execution_role_arn       = module.aws_common.execution_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode(concat(
    [merge(
      {
        name        = "imgproxy"
        image       = local.image
        essential   = true
        stopTimeout = 120
        cpu         = local.cpu_units
        memory      = local.memory_mb

        portMappings = [{
          containerPort = 8080
          hostPort      = 0
          protocol      = "tcp"
        }]

        environment = [for k, v in merge(local.env_vars, local.cloudwatch_env_vars) : { name = k, value = v }]
        secrets     = local.ecs_secrets

        # Makes the sidecar resolvable as "otel-collector" in bridge mode.
        links = var.enable_monitoring ? ["otel-collector"] : []

        healthCheck = {
          command     = ["CMD-SHELL", "imgproxy health"]
          interval    = 10
          timeout     = 2
          retries     = 3
          startPeriod = 5
        }

        logConfiguration = {
          logDriver = "awslogs"
          options = {
            "awslogs-group"         = module.aws_common.log_group_name
            "awslogs-region"        = data.aws_region.current.name
            "awslogs-stream-prefix" = "imgproxy"
          }
        }
      },
      var.repo_credentials_secret != null ? {
        repositoryCredentials = {
          credentialsParameter = var.repo_credentials_secret.arn
        }
      } : {}
    )],
    var.enable_monitoring ? [{
      name      = "otel-collector"
      image     = "public.ecr.aws/aws-observability/aws-otel-collector:v0.44.0"
      essential = false
      cpu       = 256
      memory    = 256

      environment = var.otel_collector_config != null ? [{
        name  = "AOT_CONFIG_CONTENT"
        value = var.otel_collector_config
      }] : []

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = module.aws_common.log_group_name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "otel"
        }
      }
    }] : []
  ))

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# ── Security Groups ───────────────────────────────────────────────────────────

# Bridge-mode ECS publishes containers on dynamic host ports; only the ALB may reach
# the Docker ephemeral range (the range ECS allocates host ports from).
resource "aws_security_group" "instances" {
  name_prefix = "${var.service_name}-instances-"
  vpc_id      = var.vpc_id
  description = "${var.service_name} ECS instances"

  dynamic "ingress" {
    for_each = var.create_alb ? [1] : []
    content {
      from_port       = 32768
      to_port         = 65535
      protocol        = "tcp"
      security_groups = [module.aws_common.alb_sg_id]
      description     = "ALB to ECS dynamic ports"
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.service_name}-instances" })

  lifecycle {
    create_before_destroy = true
  }
}

# ── ECS Service ───────────────────────────────────────────────────────────────

resource "aws_ecs_service" "main" {
  name                              = var.service_name
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.main.arn
  desired_count                     = local.desired_count
  health_check_grace_period_seconds = var.create_alb ? 60 : 0

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    weight            = 1
    base              = 1
  }

  dynamic "load_balancer" {
    for_each = var.create_alb ? [1] : []
    content {
      target_group_arn = module.aws_common.target_group_arn
      container_name   = "imgproxy"
      container_port   = 8080
    }
  }

  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  # The capacity providers must be associated with the cluster before the service
  # references them (and the service must go first on destroy).
  depends_on = [module.aws_common, aws_ecs_cluster_capacity_providers.main]
}

# ── ECS Task Auto Scaling ─────────────────────────────────────────────────────
# Scales ECS task count based on imgproxy's WorkersUtilization CloudWatch metric.
# imgproxy publishes this metric via IMGPROXY_CLOUD_WATCH_* env vars (always set above).
# Cooldowns are long because a scale-out may first have to launch an EC2 instance (~3–5 min).

resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.task_max_count
  min_capacity       = var.task_min_count
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.main.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  depends_on = [aws_ecs_service.main]
}

resource "aws_appautoscaling_policy" "scale_out" {
  name               = "${var.service_name}-scale-out"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  step_scaling_policy_configuration {
    adjustment_type          = "PercentChangeInCapacity"
    cooldown                 = 120
    metric_aggregation_type  = "Average"
    min_adjustment_magnitude = 1

    step_adjustment {
      metric_interval_lower_bound = 0
      metric_interval_upper_bound = 25
      scaling_adjustment          = 20
    }
    step_adjustment {
      metric_interval_lower_bound = 25
      metric_interval_upper_bound = 50
      scaling_adjustment          = 40
    }
    step_adjustment {
      metric_interval_lower_bound = 50
      metric_interval_upper_bound = 75
      scaling_adjustment          = 60
    }
    step_adjustment {
      metric_interval_lower_bound = 75
      metric_interval_upper_bound = 100
      scaling_adjustment          = 80
    }
    step_adjustment {
      metric_interval_lower_bound = 100
      scaling_adjustment          = 100
    }
  }
}

resource "aws_appautoscaling_policy" "scale_in" {
  name               = "${var.service_name}-scale-in"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  step_scaling_policy_configuration {
    adjustment_type          = "PercentChangeInCapacity"
    cooldown                 = 600
    metric_aggregation_type  = "Average"
    min_adjustment_magnitude = 1

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -50
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "concurrency_high" {
  alarm_name          = "${var.service_name}-high-concurrency"
  alarm_description   = "Scale out ${var.service_name}: WorkersUtilization > 80%"
  metric_name         = "WorkersUtilization"
  namespace           = "imgproxy"
  statistic           = "Average"
  period              = 30
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ServiceName = var.service_name
  }

  alarm_actions = [aws_appautoscaling_policy.scale_out.arn]
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "concurrency_low" {
  alarm_name          = "${var.service_name}-low-concurrency"
  alarm_description   = "Scale in ${var.service_name}: WorkersUtilization < 50%"
  metric_name         = "WorkersUtilization"
  namespace           = "imgproxy"
  statistic           = "Average"
  period              = 30
  evaluation_periods  = 20
  threshold           = 50
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ServiceName = var.service_name
  }

  alarm_actions = [aws_appautoscaling_policy.scale_in.arn]
  tags          = var.tags
}
