# Insecure mode

Minimal imgproxy on ECS on EC2 with no request signing (`insecure = true`): community edition, default resource
limits, a public Application Load Balancer, Spot instances, no monitoring and no S3. It fetches public placeholder
images.

> [!WARNING]
> This example is intended for **development and testing only**. Without request signing anyone can use your
> imgproxy (unlimited bandwidth costs, no protection against abuse, no control over processed images). Never use
> this configuration in production.

## Testing opt-ins

The module is private and encrypted by default: instances get no public IPs and the load balancer requires HTTPS. This
example has no VPC of its own and no domain, so it waives both defaults explicitly:

```hcl
assign_public_ip    = true # the default VPC has only public subnets, so instances need a public IP to pull the image
allow_insecure_http = true # plain HTTP on the ALB (no domain and certificate here): requests are unencrypted
```

Every example in this repository does the same, for testing only. For a production setup, with the instances in private
subnets and HTTPS on the load balancer, see [signed](../signed/#production-setup).

## AWS setup

You need an AWS account and the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
authenticated (the [permissions](../../example-permission-set.json) the module needs are listed in the repository root):

```bash
aws configure
# or: aws sso login --profile my-profile && export AWS_PROFILE=my-profile
```

> The `aws` commands below use `--profile $PROFILE_NAME`, set at the start of Prerequisites: use your profile, or drop the flag if you use the default credentials.
> An `aws: [ERROR]: An error occurred (ForbiddenException) when calling the GetRoleCredentials operation: No access` error usually means the profile is missing or wrong.

## Prerequisites

```bash
PROFILE_NAME=my-profile # AWS CLI profile used by Terraform; see AWS setup
REGION=us-east-1
```

## Deploy

```bash
echo "region = \"$REGION\"" > terraform.tfvars
echo "profile = \"$PROFILE_NAME\"" >> terraform.tfvars # AWS CLI profile used by Terraform; omit for default credentials

terraform init
terraform plan
terraform apply
```

The instances need a few minutes to start and pass the load balancer health check. Print a ready-to-open URL
(paste it into a browser; no signature is required in insecure mode):

```bash
echo "$(terraform output -raw url)/insecure/rs:fit:300:300/plain/https://picsum.photos/1200/800.jpg"
```

## Spot instances

`spot = true` runs the Auto Scaling Group on EC2 Spot capacity, which is up to 90% cheaper than On-Demand.
`spot_instance_types` adds instance types to the pool (better availability, fewer interruptions);
`spot_on_demand_base` and `spot_on_demand_percentage` keep part of the capacity On-Demand. A Spot instance can be
reclaimed with a two-minute warning; the module enables ECS Spot draining and imgproxy is stateless, so ECS just
starts replacement tasks.

## Cleanup

```bash
terraform destroy
```

## Next

Continue with [signed](../signed/).
