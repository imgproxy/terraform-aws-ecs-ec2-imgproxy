# imgproxy Terraform Module for AWS ECS (EC2)

Terraform module to deploy [imgproxy](https://imgproxy.net/) on AWS ECS with EC2 instances (Bottlerocket), behind an Application Load Balancer, with optional CloudFront, OpenTelemetry monitoring and S3 integration.

## Features

The module creates the required resources:

- ECS cluster, service and task definition on an EC2 Auto Scaling Group with an ECS capacity provider, On-Demand or Spot (`spot`)
- Launch template with Bottlerocket, encrypted volumes and IMDSv2 only
- Application Load Balancer with ACM certificates and HTTP to HTTPS redirect
- Security groups
- Autoscaling rules on imgproxy's own metrics
- IAM execution and task roles (or use your own)
- CloudFront distribution (optional), with the load balancer locked to it
- OpenTelemetry (ADOT) sidecar for X-Ray and CloudWatch (optional)

Also supported: request signing, imgproxy Pro and private registries through Secrets Manager, S3 as image source and result cache (Pro). Secure by default ([details](#secure-defaults)).

## Usage

```hcl
module "imgproxy" {
  source  = "imgproxy/ecs-ec2-imgproxy/aws"
  version = "~> 0.1"

  service_name = "imgproxy"

  # Instances in private subnets, internet-facing ALB in public subnets
  vpc_id         = "vpc-0123456789abcdef0"
  subnet_ids     = ["subnet-0aaa...", "subnet-0bbb..."] # private: the instances
  alb_subnet_ids = ["subnet-0ccc...", "subnet-0ddd..."] # public: the ALB

  # HTTPS on the ALB (point a DNS record for the domain at it)
  alb_certificate_arns = ["arn:aws:acm:us-east-1:123456789012:certificate/..."]

  keys_secret  = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy-keys-AbCdEf" }
  salts_secret = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy-salts-AbCdEf" }

  spot                = true # run the instances on EC2 Spot to save cost
  spot_instance_types = ["c7g.medium", "m6g.medium"]
}
```

Requires Terraform >= 1.5, an authenticated AWS CLI with [sufficient permissions](#permissions), and an existing VPC with subnets: the module creates no networking (see [Networking](#networking)).

## Examples

Start with [insecure](examples/insecure/) and follow the "Next" link at the end of each README; every step adds one feature.

- [insecure](examples/insecure/) - Minimal deployment without request signing (development only)
- [signed](examples/signed/) - URL signing, plus the [production setup](examples/signed/#production-setup)
- [s3](examples/s3/) - Private S3 bucket as the image source
- [cdn](examples/cdn/) - CloudFront in front of the load balancer
- [pro](examples/pro/) - imgproxy Pro with license key and S3 result cache
- [complete](examples/complete/) - Pro, monitoring and S3 together

The examples run in the default VPC over plain HTTP, so they set `assign_public_ip = true` and `allow_insecure_http = true`. Testing only.

## Notes

### Secure defaults

Each insecure choice is an explicit, named opt-in:

| Default | Opt-in | Acceptable for |
|---------|--------|----------------|
| Instances have no public IP | `assign_public_ip = true` | Public subnets such as the default VPC. Each instance is then addressable by IP (the security group still admits only the ALB on the ECS dynamic port range) |
| The ALB requires HTTPS (`alb_certificate_arns`) | `allow_insecure_http = true` | Testing: traffic, signed URLs and tokens are unencrypted (with CloudFront, the origin secret header too) |
| Requests must be signed | `insecure = true` | Development: anyone can use your imgproxy and, with `source_buckets`, read those buckets |

Without a certificate and without `allow_insecure_http = true`, the module refuses to plan.

### Permissions

The deployer needs permissions for ECS, EC2 (launch templates, security groups), Auto Scaling, the load balancer, Application Auto Scaling, CloudWatch alarms and log groups, and CloudFront. Two example policies are provided; before using either, replace `123456789012` with your AWS account ID and the `imgproxy` role-name prefix with your `service_name` (the module names its roles `<service_name>-execution-*`, `<service_name>-task-*` and `<service_name>-instance-*`).

- [example-permission-set.json](example-permission-set.json): the module creates the task and instance roles, so the deployer needs IAM access, limited to roles named `imgproxy-*`. Treat this identity as privileged.
- [example-permission-set-existing-roles.json](example-permission-set-existing-roles.json): you create the task roles and pass them as `execution_role_arn` and `task_role_arn`; the deployer then needs only `iam:PassRole` on them. The EC2 instance role and profile are always created by the module (`<service_name>-instance-*`).

Neither policy reads secret values or covers the Terraform state backend. They were not applied end to end against AWS, so adjust them if an apply fails with `AccessDenied`.

### Networking

Run the instances in private subnets and keep only the ALB public, as in Usage.

- `alb_subnet_ids` must be public subnets. When unset, the ALB goes into `subnet_ids` and is unreachable from the internet. `internal_alb = true` makes it reachable only from the VPC and connected networks.
- Private instances need an outbound route to pull from `ghcr.io` (or `docker.imgproxy.pro`), reach the ECS control plane and fetch images: use a **NAT gateway**, or tasks fail with `CannotPullContainerError` and instances never join the cluster. With S3 sources and an ECR image, VPC endpoints can replace it: S3 gateway plus interface endpoints for `ecr.api`, `ecr.dkr`, `secretsmanager` and `logs`.
- The instance security group admits only the ALB, on the ECS dynamic port range (32768-65535). Instances have no SSH key; use AWS Systems Manager Session Manager. Add VPN or bastion rules through `instances_security_group_id` or `additional_security_group_ids`.

### Additional secrets

`secrets` maps extra environment variables (named as in [imgproxy's configuration](https://docs.imgproxy.net/configuration)) to Secrets Manager secrets. `version` is optional (the current version is used by default). A module-created execution role can read every secret you pass.

```hcl
secrets = {
  IMGPROXY_SENTRY_DSN = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sentry-dsn-AbCdEf" }
}
```

### Image delivery

The instances pull `ghcr.io/imgproxy/imgproxy`, or `docker.imgproxy.pro/imgproxy` with `pro = true`. For your own image, set `repo` (without tag) and `tag` (a version, or a `sha256:` digest):

```hcl
repo                    = "registry.example.com/imgproxy-custom"
repo_credentials_secret = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:registry-AbCdEf" }
tag                     = "my-tag"
```

- Public images and **ECR** in your account need no credentials. Other private registries need `repo_credentials_secret`, a JSON secret with `username` and `password` keys (for docker.imgproxy.pro the username is `imgproxy`). A custom `execution_role_arn` must be granted ECR pull or `secretsmanager:GetSecretValue` yourself.
- `pro = true` only selects the default `repo`; it has no effect when `repo` is set.

Instances and tasks run on ARM64 (Graviton, `c6g.medium`) by default; for images without `linux/arm64`, set `cpu_architecture = "X86_64"` and an x86 `instance_type` (e.g. `c6i.large`).

### Scaling, monitoring and logs

- `spot = true` runs the Auto Scaling Group on EC2 Spot capacity (up to 90% cheaper); `spot_instance_types` widens the pool and `spot_on_demand_base` / `spot_on_demand_percentage` keep part of it On-Demand. ECS drains instances about to be reclaimed.
- Instances scale between `min_instances` and `max_instances` through the ECS capacity provider (`target_capacity`, `managed_termination_protection`, optional `warm_pool`); keep `task_max_count <= max_instances`, since each instance runs one task by default.
- Tasks scale between `task_min_count` and `task_max_count` on imgproxy's `WorkersUtilization` metric (out above 80%, in below 50%). Terraform ignores later changes to the task count.
- `enable_monitoring = true` adds an ADOT sidecar (OTLP on `localhost:4318`) exporting traces to X-Ray and metrics and logs to CloudWatch. It reserves 256Mi of task memory; replace its configuration with `otel_collector_config`.
- `source_buckets` and `cache_bucket` (Pro) grant IAM permissions on existing buckets; the module does not create them. Set `IMGPROXY_S3_REGION` in `environment` when a bucket is outside the default region.
- `/health` is served on port 8080. Logs go to the CloudWatch group `/aws/ecs/<service_name>`, kept for `log_retention_days` (365 by default).

### CloudFront

`enable_cloudfront = true` puts CloudFront in front of the ALB (`create_alb` must stay `true`), on its `*.cloudfront.net` domain or on yours through `cloudfront_domains` and `cloudfront_certificate_arn` (issued in **us-east-1**).

The ALB is locked to CloudFront: its security group admits only CloudFront's IPs, and the listener returns `403` without the module-generated `X-Origin-Verify` header. That only holds if the hop is encrypted, so HTTPS is required:

```hcl
enable_cloudfront        = true
alb_certificate_arns     = ["arn:aws:acm:us-east-1:123456789012:certificate/..."] # covers origin.example.com
cloudfront_origin_domain = "origin.example.com"
```

CloudFront validates the ALB certificate against the origin's name, so `cloudfront_origin_domain` must be a dedicated name covered by the ALB certificate, pointing at the ALB (`alb_dns_name` and `alb_zone_id` outputs), and different from `cloudfront_domains`. For testing, `allow_insecure_http = true` makes the hop plain HTTP, which lets anyone who captures the header bypass the lock.

Cache keys follow your imgproxy configuration (`Accept` with format detection, client hints, `IMGPROXY_CACHE_KEY_HEADERS` and `IMGPROXY_CACHE_KEY_COOKIES`). `secret_secret` cannot be combined with CloudFront, which does not forward `Authorization`. Query strings are not forwarded either, so percent-encode any `?` in plain source URLs.

### Vendored modules

`modules/aws-common` and `modules/imgproxy-common` are generated copies from `imgproxy/terraform-common`. Do not edit them here: change them upstream and run its `sync.sh`.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.5 |
| aws | ~> 5.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 5.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| aws\_common | ./modules/aws-common | n/a |
| imgproxy\_common | ./modules/imgproxy-common | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_appautoscaling_policy.scale_in](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_policy) | resource |
| [aws_appautoscaling_policy.scale_out](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_policy) | resource |
| [aws_appautoscaling_target.ecs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_target) | resource |
| [aws_autoscaling_group.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/autoscaling_group) | resource |
| [aws_cloudwatch_metric_alarm.concurrency_high](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.concurrency_low](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_ecs_capacity_provider.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_capacity_provider) | resource |
| [aws_ecs_cluster.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_cluster) | resource |
| [aws_ecs_cluster_capacity_providers.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_cluster_capacity_providers) | resource |
| [aws_ecs_service.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_service) | resource |
| [aws_ecs_task_definition.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_task_definition) | resource |
| [aws_iam_instance_profile.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_role.instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.instance_ecs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.instance_ssm](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_launch_template.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_template) | resource |
| [aws_security_group.instances](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_ssm_parameter.bottlerocket_ami](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |

## Inputs

| Name | Description | Type | Required |
| ---- | ----------- | ---- | :------: |
| subnet\_ids | Subnet IDs for EC2 instances. Use private subnets with a NAT gateway (recommended), or public subnets with assign\_public\_ip = true. | `list(string)` | yes |
| vpc\_id | VPC ID to deploy the ECS cluster and ALB into. | `string` | yes |
| additional\_security\_group\_ids | Additional security group IDs to attach to EC2 instances. | `list(string)` | no |
| alb\_certificate\_arns | ACM certificate ARNs for the HTTPS listener. Required unless allow\_insecure\_http = true. Creates a port 443 HTTPS listener; the first ARN is the primary certificate and additional ARNs are attached as SNI extras. | `list(string)` | no |
| alb\_deletion\_protection | Enable deletion protection on the ALB. | `bool` | no |
| alb\_deregistration\_delay | Seconds the ALB waits before deregistering a target during deployments and scale-in. Must be >= alb\_idle\_timeout to avoid in-flight connection resets. | `number` | no |
| alb\_idle\_timeout | ALB connection idle timeout in seconds. | `number` | no |
| alb\_redirect\_http\_to\_https | Redirect HTTP to HTTPS on the ALB. Requires alb\_certificate\_arns to be set. | `bool` | no |
| alb\_subnet\_ids | Subnet IDs for the Application Load Balancer. When null, uses subnet\_ids. Set to public subnets when instances are in private subnets. | `list(string)` | no |
| allow\_insecure\_http | Allow the ALB to serve plain HTTP only, that is, without alb\_certificate\_arns. For testing only: requests, signed URLs and tokens travel unencrypted. With CloudFront it also makes CloudFront reach the ALB over plain HTTP, so the origin secret header and all traffic cross the network in clear text. | `bool` | no |
| allow\_public\_access | Allow public internet access to the ALB (0.0.0.0/0 on port 80/443). | `bool` | no |
| ami\_id | Bottlerocket ECS-optimized AMI ID. When null, the latest Bottlerocket AMI is resolved from SSM automatically. | `string` | no |
| assign\_public\_ip | Assign a public IP to EC2 instances. Off by default: run the instances in private subnets with a NAT gateway (or VPC endpoints). Set to true only when the subnets are public, such as those of the default VPC: instances then need it to pull the image, and every instance is directly addressable by IP (the instance security group still only accepts the ALB on the ECS dynamic port range). | `bool` | no |
| cache\_bucket | S3 bucket name for imgproxy result cache (imgproxy Pro only). The task role is granted full object access. | `string` | no |
| cdn\_default\_ttl | Default CloudFront TTL in seconds. Set to 0 to let CloudFront respect origin Cache-Control headers. | `number` | no |
| cdn\_max\_ttl | Maximum CloudFront TTL in seconds, regardless of origin headers. | `number` | no |
| cdn\_min\_ttl | Minimum CloudFront TTL in seconds. Set to a positive value to force a floor TTL regardless of origin headers. | `number` | no |
| cdn\_redirect\_http\_to\_https | Redirect HTTP to HTTPS at the CloudFront level. | `bool` | no |
| cdn\_waf\_web\_acl\_id | WAF Web ACL ARN to associate with the CloudFront distribution. | `string` | no |
| cloudfront\_certificate\_arn | ACM certificate ARN for CloudFront (must be in us-east-1). Required when cloudfront\_domains is set. | `string` | no |
| cloudfront\_domains | Custom domain aliases for the CloudFront distribution. Requires cloudfront\_certificate\_arn. | `list(string)` | no |
| cloudfront\_origin\_domain | Domain name CloudFront uses to reach the ALB over HTTPS, for example 'origin.example.com'. Create a DNS record for it that points at the ALB (see the alb\_dns\_name and alb\_zone\_id outputs) and cover it with a certificate in alb\_certificate\_arns. Required when enable\_cloudfront = true and alb\_certificate\_arns is set, because CloudFront validates the ALB certificate against this name. Must differ from cloudfront\_domains. | `string` | no |
| cloudfront\_origin\_shield\_region | AWS region to enable CloudFront Origin Shield (e.g. "us-east-1"). Adds an extra caching tier between edge locations and the ALB, reducing origin load. When null, Origin Shield is disabled. | `string` | no |
| cpu | vCPUs allocated to the imgproxy container (cpu × 1024 CPU units). Sets IMGPROXY\_WORKERS default. | `number` | no |
| cpu\_architecture | CPU architecture for the container and EC2 instances. ARM64 (Graviton: c6g/c7g/c8g) is recommended: lower cost, better throughput. Must match the instance type family and the image platform. | `string` | no |
| create\_alb | Create an Application Load Balancer for the ECS service. | `bool` | no |
| data\_volume\_size | Size in GiB of the encrypted Bottlerocket data volume (container images and ephemeral storage). | `number` | no |
| deployment\_minimum\_healthy\_percent | Minimum percentage of healthy tasks during a rolling deployment. 100 = zero-downtime (new task starts before old stops). 0 = fastest deploy (brief outage). With task\_min\_count = 1, a value of 50 allows a zero-task gap. | `number` | no |
| desired\_count | Desired number of ECS tasks. Defaults to task\_min\_count. Changes after initial creation are ignored (managed by ECS auto-scaling). | `number` | no |
| enable\_cloudfront | Create a CloudFront distribution in front of the ALB for global edge caching. Requires create\_alb = true. | `bool` | no |
| enable\_monitoring | Enable the AWS Distro for OpenTelemetry (ADOT) sidecar container to export traces and metrics to X-Ray and CloudWatch. Automatically configures imgproxy OTEL environment variables. | `bool` | no |
| environment | Additional environment variables passed to imgproxy (e.g. IMGPROXY\_MAX\_SRC\_RESOLUTION). | `map(string)` | no |
| execution\_role\_arn | ARN of an existing IAM role to use as the ECS task execution role. When null, a role is created with ECR pull and Secrets Manager access. | `string` | no |
| insecure | Disable URL signature checks. When true, key and salt are not required. | `bool` | no |
| instance\_type | EC2 instance type for ECS cluster nodes. | `string` | no |
| internal\_alb | Create an internal (non-internet-facing) ALB. Use for private deployments accessed via VPC only. | `bool` | no |
| keys\_secret | Secrets Manager ARN for imgproxy signing keys (comma-separated hex-encoded values). Required when insecure = false. Generate: openssl rand -hex 64. Sets IMGPROXY\_KEY. | ```object({ arn = string version = optional(string, "") })``` | no |
| log\_retention\_days | CloudWatch log group retention in days. | `number` | no |
| managed\_termination\_protection | Enable ECS managed termination protection on ASG instances. When true, ECS prevents scale-in of instances that have running tasks. Disable for faster terraform destroy in dev/test environments. | `bool` | no |
| max\_instances | Maximum number of EC2 instances in the Auto Scaling Group. | `number` | no |
| memory | Memory limit for the imgproxy container. Accepts Mi or Gi suffix (e.g. '512Mi', '2Gi'). Must fit on the instance type together with the OTEL sidecar when enabled. | `string` | no |
| min\_instances | Minimum number of EC2 instances in the Auto Scaling Group. | `number` | no |
| otel\_collector\_config | OpenTelemetry Collector configuration YAML passed to the ADOT sidecar via AOT\_CONFIG\_CONTENT. When null, a default config exporting to X-Ray and CloudWatch is used. | `string` | no |
| pro | Use imgproxy Pro (docker.imgproxy.pro) instead of the community image (ghcr.io) as the default repo. Has no effect when repo is set. | `bool` | no |
| pro\_license\_key\_secret | Secrets Manager ARN for the imgproxy Pro license key. Sets IMGPROXY\_LICENSE\_KEY. | ```object({ arn = string version = optional(string, "") })``` | no |
| repo | Container repository to pull imgproxy from, without tag (e.g. 'registry.example.com/imgproxy' or '123456789012.dkr.ecr.us-east-1.amazonaws.com/imgproxy'). When null, 'pro' selects docker.imgproxy.pro/imgproxy or ghcr.io/imgproxy/imgproxy. ECR repositories in the same account are pulled with the execution role and need no credentials; for any other private registry set repo\_credentials\_secret. | `string` | no |
| repo\_credentials\_secret | Secrets Manager secret with the credentials for the registry in 'repo' (or docker.imgproxy.pro when 'repo' is not set). Must be a JSON secret with 'username' and 'password' keys (ECS repositoryCredentials). Required when pro = true and repo is not set; the execution role is granted read access to it. | ```object({ arn = string })``` | no |
| salts\_secret | Secrets Manager ARN for imgproxy signing salts (must match number of keys). Required when insecure = false. Sets IMGPROXY\_SALT. | ```object({ arn = string version = optional(string, "") })``` | no |
| secret\_secret | Secrets Manager ARN for the authorization token. When set, requests must include Authorization: Bearer <token>. Sets IMGPROXY\_SECRET. | ```object({ arn = string version = optional(string, "") })``` | no |
| secrets | Map of environment variable names to Secrets Manager ARNs. Example: {IMGPROXY\_NEW\_RELIC\_KEY = {arn = "arn:aws:secretsmanager:us-east-1:123:secret:newrelic-key"}}. | ```map(object({ arn = string version = optional(string, "") }))``` | no |
| service\_name | Prefix applied to every resource name. | `string` | no |
| signature\_size | Number of bytes from the key/salt used for signing. Sets IMGPROXY\_SIGNATURE\_SIZE. | `number` | no |
| source\_buckets | S3 bucket names for imgproxy source images. The task role is granted s3:GetObject, s3:GetObjectVersion and s3:ListBucket on each. Enables IMGPROXY\_USE\_S3. | `list(string)` | no |
| source\_url\_encryption\_key\_secret | Secrets Manager ARN for the source URL encryption key. Sets IMGPROXY\_SOURCE\_URL\_ENCRYPTION\_KEY. | ```object({ arn = string version = optional(string, "") })``` | no |
| spot | Use EC2 Spot instances with price-capacity-optimized allocation. Set spot\_instance\_types to provide multiple instance types for better availability. | `bool` | no |
| spot\_instance\_types | Additional EC2 instance types for the Spot pool alongside instance\_type. More types = better availability and fewer interruptions. Only used when spot = true. | `list(string)` | no |
| spot\_on\_demand\_base | Minimum number of On-Demand instances to maintain regardless of spot\_on\_demand\_percentage. Only used when spot = true. | `number` | no |
| spot\_on\_demand\_percentage | Percentage of instances above spot\_on\_demand\_base to run as On-Demand (0 = all Spot, 100 = all On-Demand). Only used when spot = true. | `number` | no |
| tag | imgproxy image tag (version). | `string` | no |
| tags | Tags applied to all created resources. | `map(string)` | no |
| target\_capacity | Target capacity utilization percentage for ECS managed scaling (1–100). Values below 100 keep spare EC2 capacity for faster task placement. | `number` | no |
| task\_max\_count | Maximum number of ECS tasks for Application Auto Scaling. | `number` | no |
| task\_min\_count | Minimum number of ECS tasks for Application Auto Scaling. | `number` | no |
| task\_role\_arn | ARN of an existing IAM role to use as the ECS task role. When null, a role is created with S3 and monitoring permissions as needed. | `string` | no |
| timeout | Request timeout in seconds. Sets IMGPROXY\_TIMEOUT. | `number` | no |
| trusted\_signatures\_secret | Secrets Manager ARN for trusted signature prefixes. imgproxy Pro only. Sets IMGPROXY\_TRUSTED\_SIGNATURES. | ```object({ arn = string version = optional(string, "") })``` | no |
| warm\_pool | Create an ASG warm pool of pre-initialized instances for faster scale-out. Incompatible with spot = true. | `bool` | no |
| workers | Number of concurrent requests per container. Sets IMGPROXY\_WORKERS. Defaults to cpu × 2. | `number` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| alb\_dns\_name | DNS name of the Application Load Balancer. |
| alb\_security\_group\_id | Security group ID of the Application Load Balancer (null without an ALB). Use it to add ingress rules, e.g. for an internal ALB. |
| alb\_zone\_id | Hosted zone ID of the ALB. Use with Route 53 alias records. |
| autoscaling\_group\_name | Name of the Auto Scaling Group running the ECS instances. |
| cloudfront\_domain\_name | CloudFront distribution domain name. |
| cloudfront\_hosted\_zone\_id | CloudFront hosted zone ID. Use with Route 53 alias records. |
| cluster\_arn | ECS cluster ARN. |
| cluster\_name | ECS cluster name. |
| execution\_role\_arn | ARN of the IAM role used by the ECS agent to start tasks. |
| instances\_security\_group\_id | Security group ID attached to the ECS EC2 instances. |
| log\_group\_name | CloudWatch Log Group name for imgproxy and OTEL sidecar logs. |
| service\_name | ECS service name. |
| task\_role\_arn | ARN of the IAM role used by the imgproxy task at runtime. |
| url | imgproxy endpoint URL. CloudFront domain when enable\_cloudfront = true, otherwise ALB DNS name. |
<!-- END_TF_DOCS -->

## License

MIT
