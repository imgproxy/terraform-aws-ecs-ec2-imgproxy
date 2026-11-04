# S3 source bucket

imgproxy reading source images from a private S3 bucket via the `s3://` URL scheme. The module grants `s3:GetObject`
and `s3:ListBucket` on the bucket to the task role, so the bucket stays private.

Like every example here, it waives two secure defaults for testing (`assign_public_ip = true` and
`allow_insecure_http = true`): see [signed](../signed/#production-setup) for the production setup.

## AWS setup

You need an AWS account and the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
authenticated:

```bash
aws configure
# or: aws sso login --profile my-profile && export AWS_PROFILE=my-profile
```

> The `aws` commands below use `--profile my-profile`: replace it with your profile, or drop it if you use the default credentials.
> An `aws: [ERROR]: An error occurred (ForbiddenException) when calling the GetRoleCredentials operation: No access` error usually means the profile is missing or wrong.

## Prerequisites

Create the signing keys and a private bucket for source images (see [signed](../signed/) for the keys). Bucket names
are global, so the example prefixes it with your account ID:

```bash
REGION=us-east-1
ACCOUNT_ID=$(aws sts get-caller-identity --profile my-profile --query Account --output text)

aws secretsmanager create-secret --profile my-profile --region $REGION --name imgproxy-keys --secret-string "$(openssl rand -hex 64)"
aws secretsmanager create-secret --profile my-profile --region $REGION --name imgproxy-salts --secret-string "$(openssl rand -hex 64)"

aws s3 mb --profile my-profile s3://$ACCOUNT_ID-imgproxy-images --region $REGION
```

## Deploy

```bash
echo "region = \"$REGION\"" > terraform.tfvars
echo "profile = \"my-profile\"" >> terraform.tfvars # your AWS CLI profile; omit for default credentials

terraform init
terraform plan
terraform apply

aws s3 cp --profile my-profile photo.jpg s3://$ACCOUNT_ID-imgproxy-images/photo.jpg
```

Sign the request as in [signed](../signed/), with `IMG_PATH` pointing at the bucket object:

```bash
(
URL=$(terraform output -raw url)
KEY=$(aws secretsmanager get-secret-value --profile my-profile --region $REGION --secret-id imgproxy-keys --query SecretString --output text)
SALT=$(aws secretsmanager get-secret-value --profile my-profile --region $REGION --secret-id imgproxy-salts --query SecretString --output text)
IMG_PATH="/rs:fit:300:200/plain/s3://$ACCOUNT_ID-imgproxy-images/photo.jpg"
SIG=$( (printf '%s' "$SALT" | xxd -r -p; printf '%s' "$IMG_PATH") \
  | openssl dgst -sha256 -mac HMAC -macopt hexkey:$KEY -binary \
  | openssl base64 -A | tr '+/' '-_' | tr -d '=' )
echo "$URL/$SIG$IMG_PATH"
)
```

The module does not create buckets: it only grants the task role read access to the ones you list in `source_buckets`.
`IMGPROXY_S3_REGION` in `environment` tells imgproxy which region the bucket is in; set it to the bucket's region if
it differs from the one the service runs in.

## Cleanup

```bash
terraform destroy
```

The bucket and the secrets were created with the AWS CLI, so delete them separately:

```bash
aws s3 rb --profile my-profile s3://$ACCOUNT_ID-imgproxy-images --force
aws secretsmanager delete-secret --profile my-profile --region $REGION --secret-id imgproxy-keys --force-delete-without-recovery
aws secretsmanager delete-secret --profile my-profile --region $REGION --secret-id imgproxy-salts --force-delete-without-recovery
```

## Next

Continue with [cdn](../cdn/).
