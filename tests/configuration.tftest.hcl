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

run "secure_mode_wires_signing_secrets" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_ecs_task_definition.main.container_definitions)[0].secrets : s
      if s.name == "IMGPROXY_KEY" && s.valueFrom == "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/keys"
    ]) == 1
    error_message = "IMGPROXY_KEY secret must be wired from keys_secret"
  }

  assert {
    condition = length([
      for s in jsondecode(aws_ecs_task_definition.main.container_definitions)[0].secrets : s
      if s.name == "IMGPROXY_SALT" && s.valueFrom == "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/salts"
    ]) == 1
    error_message = "IMGPROXY_SALT secret must be wired from salts_secret"
  }
}

run "insecure_mode_skips_signing_secrets" {
  command = plan

  variables {
    insecure     = true
    keys_secret  = null
    salts_secret = null
  }

  assert {
    condition = length([
      for s in jsondecode(aws_ecs_task_definition.main.container_definitions)[0].secrets : s
      if s.name == "IMGPROXY_KEY" || s.name == "IMGPROXY_SALT"
    ]) == 0
    error_message = "No signing secrets should be wired when insecure = true"
  }
}

run "source_buckets_enables_use_s3_env" {
  command = plan

  variables {
    source_buckets = ["my-imgproxy-source"]
  }

  assert {
    condition = length([
      for e in jsondecode(aws_ecs_task_definition.main.container_definitions)[0].environment : e
      if e.name == "IMGPROXY_USE_S3" && e.value == "true"
    ]) == 1
    error_message = "IMGPROXY_USE_S3 must be set when source_buckets is non-empty"
  }
}

run "default_image_is_community" {
  command = plan

  assert {
    condition     = jsondecode(aws_ecs_task_definition.main.container_definitions)[0].image == "ghcr.io/imgproxy/imgproxy:v4"
    error_message = "The default image must be the community edition on ghcr.io"
  }

  assert {
    condition     = !contains(keys(jsondecode(aws_ecs_task_definition.main.container_definitions)[0]), "repositoryCredentials")
    error_message = "No registry credentials must be injected by default"
  }
}

run "pro_selects_default_pro_repo_and_injects_credentials" {
  command = plan

  variables {
    pro = true
    repo_credentials_secret = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/pro-registry"
    }
    pro_license_key_secret = {
      arn     = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/pro-license"
      version = ""
    }
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.main.container_definitions)[0].image == "docker.imgproxy.pro/imgproxy:v4"
    error_message = "pro = true without repo must select docker.imgproxy.pro/imgproxy"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.main.container_definitions)[0].repositoryCredentials.credentialsParameter == "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/pro-registry"
    error_message = "Registry credentials must be injected into the imgproxy container definition"
  }
}

run "custom_repo_and_tag" {
  command = plan

  variables {
    repo = "123456789012.dkr.ecr.us-east-1.amazonaws.com/imgproxy-custom"
    tag  = "my-tag"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.main.container_definitions)[0].image == "123456789012.dkr.ecr.us-east-1.amazonaws.com/imgproxy-custom:my-tag"
    error_message = "repo and tag must form the image reference"
  }

  assert {
    condition     = !contains(keys(jsondecode(aws_ecs_task_definition.main.container_definitions)[0]), "repositoryCredentials")
    error_message = "A custom repo without repo_credentials_secret must not inject credentials (ECR is pulled with the execution role)"
  }
}

run "custom_repo_overrides_pro" {
  command = plan

  variables {
    pro  = true
    repo = "registry.example.com/imgproxy-custom"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.main.container_definitions)[0].image == "registry.example.com/imgproxy-custom:v4"
    error_message = "pro must have no effect on the image when repo is set"
  }
}

run "custom_private_repo_injects_credentials" {
  command = plan

  variables {
    repo = "registry.example.com/imgproxy-custom"
    repo_credentials_secret = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/registry"
    }
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.main.container_definitions)[0].repositoryCredentials.credentialsParameter == "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/registry"
    error_message = "repo_credentials_secret must be injected for a custom repo even when pro = false"
  }
}

run "tag_accepts_sha256_digest" {
  command = plan

  variables {
    tag = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.main.container_definitions)[0].image == "ghcr.io/imgproxy/imgproxy@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    error_message = "A sha256: tag must be referenced with @ instead of :"
  }
}

run "spot_uses_mixed_instances_policy" {
  command = plan

  variables {
    spot                      = true
    spot_instance_types       = ["c7g.medium", "m6g.medium"]
    spot_on_demand_percentage = 25
  }

  assert {
    condition     = length(aws_autoscaling_group.main.mixed_instances_policy) == 1
    error_message = "spot = true must use a mixed instances policy"
  }

  assert {
    condition     = aws_autoscaling_group.main.mixed_instances_policy[0].instances_distribution[0].on_demand_percentage_above_base_capacity == 25
    error_message = "spot_on_demand_percentage must propagate to the instances distribution"
  }
}
run "instances_have_no_public_ip_by_default" {
  command = plan

  assert {
    condition     = aws_launch_template.main.network_interfaces[0].associate_public_ip_address == "false"
    error_message = "Instances must not get public IPs by default"
  }
}
run "assign_public_ip_opt_in" {
  command = plan

  variables {
    assign_public_ip = true
  }

  assert {
    condition     = aws_launch_template.main.network_interfaces[0].associate_public_ip_address == "true"
    error_message = "assign_public_ip = true must propagate to the launch template"
  }
}

run "imds_is_hardened" {
  command = plan

  assert {
    condition     = aws_launch_template.main.metadata_options[0].http_tokens == "required" && aws_launch_template.main.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "IMDSv2 must be required with a hop limit of 1 so containers cannot reach the instance credentials"
  }
}

run "instance_volumes_are_encrypted" {
  command = plan

  assert {
    condition     = alltrue([for m in aws_launch_template.main.block_device_mappings : m.ebs[0].encrypted == "true"])
    error_message = "All instance volumes must be encrypted"
  }
}

run "instances_accept_only_alb_on_dynamic_ports" {
  command = plan

  assert {
    condition     = length(aws_security_group.instances.ingress) == 1 && one(aws_security_group.instances.ingress).from_port == 32768 && one(aws_security_group.instances.ingress).to_port == 65535
    error_message = "The instance security group must admit only the ALB on the ephemeral port range"
  }
}
run "custom_task_role_skips_creation" {
  command = plan

  variables {
    task_role_arn = "arn:aws:iam::123456789012:role/custom-task-role"
  }

  assert {
    condition     = module.aws_common.task_role_arn == "arn:aws:iam::123456789012:role/custom-task-role"
    error_message = "task_role_arn output must reflect the provided ARN when task_role_arn is set"
  }
}

run "custom_execution_role_skips_creation" {
  command = plan

  variables {
    execution_role_arn = "arn:aws:iam::123456789012:role/custom-execution-role"
  }

  assert {
    condition     = module.aws_common.execution_role_arn == "arn:aws:iam::123456789012:role/custom-execution-role"
    error_message = "execution_role_arn output must reflect the provided ARN when execution_role_arn is set"
  }
}
