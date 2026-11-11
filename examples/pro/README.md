# imgproxy Pro

imgproxy Pro with a license key and an S3 result cache. It fetches public placeholder images, so no source bucket is
needed.

Like every example here, it waives two secure defaults for testing (`assign_public_ip = true` and
`allow_insecure_http = true`): see [signed](../signed/#production-setup) for the production setup.

## AWS setup

You need an AWS account and the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
authenticated:

```bash
aws configure
# or: aws sso login --profile my-profile && export AWS_PROFILE=my-profile
```

> The `aws` commands below use two profiles, set at the start of Prerequisites: `PROFILE_NAME` is the one Terraform uses, and `ADMIN_PROFILE_NAME` creates, reads and deletes the Secrets Manager secrets and the S3 buckets. They may be the same or different; drop the flags if you use the default credentials.
> `ADMIN_PROFILE_NAME` must be allowed `secretsmanager:CreateSecret`, `GetSecretValue` and `DeleteSecret` (and S3 bucket and object management for the buckets), or `aws secretsmanager create-secret` fails with `AccessDeniedException`. `PROFILE_NAME` does not need them: Terraform only looks the secrets up (`DescribeSecret`, `GetResourcePolicy`).
> An `aws: [ERROR]: An error occurred (ForbiddenException) when calling the GetRoleCredentials operation: No access` error usually means the profile is missing or wrong.

## Prerequisites

Create the imgproxy Pro secrets, the signing keys (see [signed](../signed/)), and a private bucket for the result
cache. `imgproxy-pro-registry` holds the `docker.imgproxy.pro` registry credentials, passed as `repo_credentials_secret`.
Unlike the license key it is a **JSON** secret with `username` and `password` keys, which is the format ECS requires
to pull from a private registry:

```bash
PROFILE_NAME=my-profile # AWS CLI profile used by Terraform; see AWS setup
ADMIN_PROFILE_NAME=$PROFILE_NAME # profile that creates the secrets and buckets; may differ, see AWS setup
REGION=us-east-1
ACCOUNT_ID=$(aws sts get-caller-identity --profile $PROFILE_NAME --query Account --output text)

aws secretsmanager create-secret --profile $ADMIN_PROFILE_NAME --region $REGION --name imgproxy-pro-license --secret-string "your-license-key"
aws secretsmanager create-secret --profile $ADMIN_PROFILE_NAME --region $REGION --name imgproxy-pro-registry \
  --secret-string '{"username":"imgproxy","password":"your-registry-password"}'

aws secretsmanager create-secret --profile $ADMIN_PROFILE_NAME --region $REGION --name imgproxy-keys --secret-string "$(openssl rand -hex 64)"
aws secretsmanager create-secret --profile $ADMIN_PROFILE_NAME --region $REGION --name imgproxy-salts --secret-string "$(openssl rand -hex 64)"

aws s3 mb --profile $ADMIN_PROFILE_NAME s3://$ACCOUNT_ID-imgproxy-cache --region $REGION
```

## Deploy

```bash
echo "region = \"$REGION\"" > terraform.tfvars
echo "profile = \"$PROFILE_NAME\"" >> terraform.tfvars # AWS CLI profile used by Terraform; omit for default credentials

terraform init
terraform plan
terraform apply
```

Print a signed URL for a placeholder image (see [signed](../signed/) for how signing works) and open it:

```bash
(
URL=$(terraform output -raw url)
KEY=$(aws secretsmanager get-secret-value --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-keys --query SecretString --output text)
SALT=$(aws secretsmanager get-secret-value --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-salts --query SecretString --output text)
IMG_PATH="/rs:fit:300:200/plain/https://picsum.photos/1200/800.jpg"
SIG=$( (printf '%s' "$SALT" | xxd -r -p; printf '%s' "$IMG_PATH") \
  | openssl dgst -sha256 -mac HMAC -macopt hexkey:$KEY -binary \
  | openssl base64 -A | tr '+/' '-_' | tr -d '=' )
echo "$URL/$SIG$IMG_PATH"
)
```

imgproxy Pro caches processed results in the cache bucket (`cache_bucket`, Pro only), so repeated requests are
served faster. Request the URL printed above with `curl` and look for the `X-Imgproxy-Cache` response header:

```bash
curl -s -D- -o /dev/null "<url from above>" | grep -i x-imgproxy-cache
# A request for a new URL is processed and stored; repeating it returns "x-imgproxy-cache: Hit"
```

The processed results are stored in the cache bucket:

```bash
aws s3 ls --profile $ADMIN_PROFILE_NAME s3://$ACCOUNT_ID-imgproxy-cache --recursive
```

## Using your own registry

To pull from your own image instead, set `repo` (the image without tag) and `tag`; `pro = true` then only enables Pro
features and no longer selects the image:

```hcl
repo = "123456789012.dkr.ecr.us-east-1.amazonaws.com/imgproxy-custom"
tag  = "my-tag"
```

- **ECR in your account**: nothing else is needed. The task execution role the module creates can pull from ECR. If
  you pass your own `execution_role_arn`, it needs the usual ECR pull permissions.
- **Any other private registry**: also set `repo_credentials_secret` to a JSON secret with `username` and `password`
  keys. The module lets the execution role read it.
- **Public images** need neither.

Instances and tasks run on ARM64 (Graviton, `c6g`) by default, so the image must support `linux/arm64`; otherwise set
`cpu_architecture = "X86_64"`.

## Cleanup

```bash
terraform destroy
```

The bucket and the secrets were created with the AWS CLI, so delete them separately:

```bash
aws s3 rb --profile $ADMIN_PROFILE_NAME s3://$ACCOUNT_ID-imgproxy-cache --force
aws secretsmanager delete-secret --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-pro-license --force-delete-without-recovery
aws secretsmanager delete-secret --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-pro-registry --force-delete-without-recovery
aws secretsmanager delete-secret --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-keys --force-delete-without-recovery
aws secretsmanager delete-secret --profile $ADMIN_PROFILE_NAME --region $REGION --secret-id imgproxy-salts --force-delete-without-recovery
```

## Next

Continue with [complete](../complete/).
