# CloudFront CDN

A CloudFront distribution in front of the load balancer, caching processed images at edge locations. A domain name is
optional: this example serves the CDN on its own `*.cloudfront.net` domain over HTTPS (see below for adding your own
domain). It fetches public placeholder images, so no bucket is needed.

## AWS setup

You need an AWS account and the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
authenticated:

```bash
aws configure
# or: aws sso login --profile my-profile && export AWS_PROFILE=my-profile
```

> The `aws` commands below use two profiles, set at the start of Prerequisites: `PROFILE_NAME` is the one Terraform uses, and `ADMIN_PROFILE_NAME` creates, reads and deletes the Secrets Manager secrets and the S3 buckets. They may be the same or different; drop the flags if you use the default credentials.
> `ADMIN_PROFILE_NAME` must be allowed `secretsmanager:CreateSecret`, `GetSecretValue` and `DeleteSecret`, or `aws secretsmanager create-secret` fails with `AccessDeniedException`. `PROFILE_NAME` does not need them: Terraform only looks the secrets up (`DescribeSecret`, `GetResourcePolicy`).
> An `aws: [ERROR]: An error occurred (ForbiddenException) when calling the GetRoleCredentials operation: No access` error usually means the profile is missing or wrong.

## Prerequisites

Create the signing keys (see [signed](../signed/)):

```bash
PROFILE_NAME=my-profile # AWS CLI profile used by Terraform; see AWS setup
ADMIN_PROFILE_NAME=$PROFILE_NAME # profile that creates the secrets and buckets; may differ, see AWS setup
REGION=us-east-1

aws secretsmanager create-secret --profile $ADMIN_PROFILE_NAME --region $REGION --name imgproxy-keys --secret-string "$(openssl rand -hex 64)"
aws secretsmanager create-secret --profile $ADMIN_PROFILE_NAME --region $REGION --name imgproxy-salts --secret-string "$(openssl rand -hex 64)"
```

## Deploy

```bash
echo "region = \"$REGION\"" > terraform.tfvars
echo "profile = \"$PROFILE_NAME\"" >> terraform.tfvars # AWS CLI profile used by Terraform; omit for default credentials

terraform init
terraform plan
terraform apply
```

CloudFront takes 5-10 minutes to deploy, and the instances need a few minutes to become healthy. Print a signed URL
for a placeholder image and request it twice:

```bash
(
URL=$(terraform output -raw url)
KEY=$(aws secretsmanager get-secret-value --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-keys --query SecretString --output text)
SALT=$(aws secretsmanager get-secret-value --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-salts --query SecretString --output text)
IMG_PATH="/rs:fit:300:300/plain/https://picsum.photos/1200/800.jpg"
SIG=$( (printf '%s' "$SALT" | xxd -r -p; printf '%s' "$IMG_PATH") \
  | openssl dgst -sha256 -mac HMAC -macopt hexkey:$KEY -binary \
  | openssl base64 -A | tr '+/' '-_' | tr -d '=' )
echo "$URL/$SIG$IMG_PATH"
)

# Repeated requests for the same URL: the second response says "Hit from cloudfront" and carries an Age header
curl -sI "<url from above>" | grep -i -E '^(HTTP|x-cache|age)'
```

## Adding a domain

In [main.tf](main.tf), uncomment `cloudfront_domains` and `cloudfront_certificate_arn`. This certificate is for the
public name and must be issued in **us-east-1** (an ACM requirement for CloudFront), whatever region the service runs
in. It is separate from the ALB certificate described under Production below. After `terraform apply`,
point your domain at `terraform output cloudfront_domain_name` with a CNAME record, or with a Route 53 alias record
using `terraform output cloudfront_hosted_zone_id`. The `url` output then returns `https://<your domain>`.

## Locked-down origin, and what this example waives

With CloudFront enabled, the load balancer only accepts traffic from CloudFront: its security group admits just the
CloudFront origin-facing IP ranges, and the listener returns `403` unless the request carries a secret
`X-Origin-Verify` header that only your distribution adds. Direct requests to the ALB DNS name are rejected, so all
traffic goes through the CDN.

That lock is only as strong as the connection between CloudFront and the ALB. This example has no domain and
certificate for the ALB, so it sets `allow_insecure_http = true`, which makes CloudFront reach the ALB over **plain
HTTP**: the secret header and all traffic then cross the network in clear text, and anyone who captures the header can
bypass the lock. It is a testing shortcut. (Like the other examples it also sets `assign_public_ip = true`; see
[signed](../signed/#production-setup).)

## Production: HTTPS between CloudFront and the ALB

The module refuses to plan CloudFront with an HTTPS origin unless you give CloudFront a name it can validate.
CloudFront checks the ALB certificate against the origin's domain name, so it cannot use the ALB's own
`*.elb.amazonaws.com` name with a certificate for your domain. Use a dedicated origin name:

1. Request an ACM certificate **in the service's region** for an origin name, for example `origin.example.com`.
2. In [main.tf](main.tf), remove `allow_insecure_http` and set:

   ```hcl
   alb_certificate_arns     = ["arn:aws:acm:us-east-1:123456789012:certificate/..."]
   cloudfront_origin_domain = "origin.example.com"
   ```

3. After `terraform apply`, create a DNS record for `origin.example.com` pointing at the load balancer:
   `terraform output alb_dns_name` (CNAME), or a Route 53 alias record using `alb_zone_id`.

`cloudfront_origin_domain` must differ from `cloudfront_domains` (the public names that point at CloudFront).

Cache keys follow your imgproxy configuration: the `Accept` header is added when format detection
(`IMGPROXY_AUTO_WEBP`, `IMGPROXY_AUTO_AVIF`, ...) is enabled, the client hints headers with
`IMGPROXY_ENABLE_CLIENT_HINTS`, and so on. An authorization token (`secret_secret`) cannot be combined with
CloudFront, which does not forward the `Authorization` header.

## Cleanup

```bash
terraform destroy
```

The secrets were created with the AWS CLI, so delete them separately (and remove the DNS record if you added a domain):

```bash
aws secretsmanager delete-secret --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-keys --force-delete-without-recovery
aws secretsmanager delete-secret --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-salts --force-delete-without-recovery
```

## Next

Continue with [pro](../pro/).
