mock_provider "aws" {}

variables {
  vpc_id     = "vpc-12345678"
  subnet_ids = ["subnet-aaa111", "subnet-bbb222"]

  # Most tests plan a plain HTTP ALB; the TLS requirement has its own runs in validation.tftest.hcl.
  allow_insecure_http = true

  keys_secret = {
    arn     = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/keys"
    version = ""
  }
  salts_secret = {
    arn     = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/salts"
    version = ""
  }
}

run "rejects_invalid_cpu_architecture" {
  command = plan

  variables {
    cpu_architecture = "INVALID"
  }

  expect_failures = [var.cpu_architecture]
}

run "rejects_pro_without_registry_credentials" {
  command = plan

  variables {
    pro = true
  }

  expect_failures = [aws_ecs_cluster.main]
}

run "accepts_pro_with_custom_repo_without_credentials" {
  command = plan

  variables {
    pro  = true
    repo = "123456789012.dkr.ecr.us-east-1.amazonaws.com/imgproxy-pro"
  }

  assert {
    condition     = aws_ecs_cluster.main.name == "imgproxy"
    error_message = "pro with a custom repo must not require repo_credentials_secret"
  }
}

run "rejects_secure_mode_without_keys" {
  command = plan

  variables {
    keys_secret = null
  }

  # The common module repeats this check; mock it so only the root precondition is evaluated.
  override_module {
    target = module.imgproxy_common
    outputs = {
      image             = "mock"
      workers           = 1
      env_vars          = {}
      env_secret_vars   = {}
      cdn_cache_headers = []
      cdn_cache_cookies = []
    }
  }

  expect_failures = [aws_ecs_cluster.main]
}

run "rejects_secure_mode_without_salts" {
  command = plan

  variables {
    salts_secret = null
  }

  # The common module repeats this check; mock it so only the root precondition is evaluated.
  override_module {
    target = module.imgproxy_common
    outputs = {
      image             = "mock"
      workers           = 1
      env_vars          = {}
      env_secret_vars   = {}
      cdn_cache_headers = []
      cdn_cache_cookies = []
    }
  }

  expect_failures = [aws_ecs_cluster.main]
}

run "rejects_cloudfront_without_alb" {
  command = plan

  variables {
    enable_cloudfront = true
    create_alb        = false
  }

  expect_failures = [aws_ecs_cluster.main]
}

run "rejects_cloudfront_domains_without_certificate" {
  command = plan

  variables {
    enable_cloudfront  = true
    cloudfront_domains = ["cdn.example.com"]
  }

  expect_failures = [aws_ecs_cluster.main]
}

run "rejects_monitoring_with_insufficient_memory" {
  command = plan

  variables {
    enable_monitoring = true
    memory            = "256Mi"
  }

  expect_failures = [aws_ecs_cluster.main]
}

run "rejects_authorization_token_with_cloudfront" {
  command = plan

  variables {
    enable_cloudfront = true
    secret_secret = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/secret"
    }
  }

  expect_failures = [aws_ecs_cluster.main]
}

# TLS is required unless explicitly waived. The checks live in the shared aws-common module, and
# Terraform cannot expect failures from a resource inside a module, so their rejection cases are
# tested in terraform-common/aws-common/tests. Here only the accepted configurations are covered.
run "accepts_https_without_insecure_flag" {
  command = plan

  variables {
    allow_insecure_http  = false
    alb_certificate_arns = ["arn:aws:acm:us-east-1:123456789012:certificate/abc"]
  }

  assert {
    condition     = aws_ecs_cluster.main.name == "imgproxy"
    error_message = "A certificate must satisfy the TLS requirement"
  }
}

run "accepts_cloudfront_with_https_origin" {
  command = plan

  variables {
    allow_insecure_http      = false
    enable_cloudfront        = true
    alb_certificate_arns     = ["arn:aws:acm:us-east-1:123456789012:certificate/abc"]
    cloudfront_origin_domain = "origin.example.com"
  }

  assert {
    condition     = module.aws_common.cloudfront_created == true
    error_message = "CloudFront with an origin domain and an ALB certificate must be accepted"
  }
}

run "rejects_non_positive_cpu" {
  command = plan

  variables {
    cpu = 0
  }

  expect_failures = [var.cpu]
}
run "rejects_malformed_memory" {
  command = plan

  variables {
    memory = "2G"
  }

  expect_failures = [var.memory]
}

run "rejects_warm_pool_with_spot" {
  command = plan

  variables {
    warm_pool = true
    spot      = true
  }

  expect_failures = [aws_ecs_cluster.main]
}

run "rejects_task_max_count_above_max_instances" {
  command = plan

  variables {
    task_max_count = 20
    max_instances  = 5
  }

  expect_failures = [aws_ecs_cluster.main]
}
run "rejects_min_count_above_max_count" {
  command = plan

  variables {
    task_min_count = 5
    task_max_count = 2
  }

  expect_failures = [aws_ecs_cluster.main]
}

run "rejects_desired_count_out_of_range" {
  command = plan

  variables {
    task_min_count = 2
    task_max_count = 4
    desired_count  = 9
  }

  expect_failures = [aws_ecs_cluster.main]
}

run "rejects_deregistration_delay_below_idle_timeout" {
  command = plan

  variables {
    alb_idle_timeout         = 120
    alb_deregistration_delay = 30
  }

  expect_failures = [aws_ecs_cluster.main]
}
