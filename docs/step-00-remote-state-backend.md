# Step 0: Remote state backend

Directory: `infra/bootstrap/`

## What this step solves

The main Terraform config stores its state in S3. But that S3 bucket has to be
created by Terraform too, and Terraform cannot store its state in a bucket that
does not exist yet. That is the chicken-and-egg problem.

The fix is a second, separate Terraform config that uses **local state** and
whose only job is creating the backend. It runs once. After that, the main
config in `infra/stack/` uses the bucket it made.

## What we built

Seven resources, confirmed by `terraform plan`.

| Resource | Why |
|---|---|
| `aws_s3_bucket.state` | Holds the state file |
| `aws_s3_bucket_versioning.state` | Every state write keeps the old version, so a bad apply is recoverable |
| `aws_s3_bucket_server_side_encryption_configuration.state` | State contains resource IDs and any sensitive values, so it is encrypted at rest |
| `aws_s3_bucket_public_access_block.state` | All four public access settings blocked |
| `aws_s3_bucket_ownership_controls.state` | `BucketOwnerEnforced`, which disables ACLs entirely |
| `aws_s3_bucket_policy.state` | Denies any request arriving without TLS |
| `aws_s3_bucket_lifecycle_configuration.state` | Retains noncurrent versions instead of growing without limit |

### Bucket naming

S3 bucket names are globally unique across all AWS accounts, so the name is
scoped with the account ID and region:

```hcl
state_bucket_name = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}-${var.region}"
```

For this account that resolves to `techstream-tfstate-515966510180-eu-west-1`.
It is deterministic, so re-running bootstrap never creates a second bucket.

### State locking

Two engineers running apply at the same time can corrupt state. Terraform 1.10
added S3-native locking, which removes the need for a separate DynamoDB table:

```hcl
use_lockfile = true
```

The installed Terraform is 1.14.8, so this is the path we take. A DynamoDB
table (`PAY_PER_REQUEST`, hash key `LockID` of type `S`) is still in the config
behind `create_dynamodb_lock_table`, defaulting to `false`, for anyone stuck on
an older Terraform.

### Version retention

```hcl
noncurrent_version_expiration {
  noncurrent_days           = 90
  newer_noncurrent_versions = 10
}
```

Noncurrent versions expire after 90 days, but the 10 most recent are always
kept regardless of age. Without the second line, a quiet project could age out
every recoverable version.

### Encryption choice

Defaults to `AES256` (SSE-S3), which costs nothing. Passing `kms_key_arn`
switches to `aws:kms` and turns on S3 Bucket Keys to cut KMS request charges.
The conditional lives in one place:

```hcl
sse_algorithm     = var.kms_key_arn == null ? "AES256" : "aws:kms"
kms_master_key_id = var.kms_key_arn
```

## How to verify it works

Run these after applying:

```bash
cd infra/bootstrap
terraform init
terraform apply

# 1. The bucket exists and the name matches what the stack backend expects
terraform output state_bucket_name

# 2. Versioning is on. Must print "Enabled".
aws s3api get-bucket-versioning --bucket "$(terraform output -raw state_bucket_name)"

# 3. Encryption is configured
aws s3api get-bucket-encryption --bucket "$(terraform output -raw state_bucket_name)"

# 4. Public access is fully blocked. All four values must be true.
aws s3api get-public-access-block --bucket "$(terraform output -raw state_bucket_name)"

# 5. The copy-paste backend block for the next step
terraform output backend_block
```

## Handing off to Step 1

`infra/stack/versions.tf` already contains the matching backend block with
literal values, because backend blocks cannot use variables or interpolation:

```hcl
backend "s3" {
  bucket       = "techstream-tfstate-515966510180-eu-west-1"
  key          = "techstream/terraform.tfstate"
  region       = "eu-west-1"
  encrypt      = true
  use_lockfile = true
}
```

If your account or region differs, either edit those literals or pass them at
init time:

```bash
terraform init -reconfigure \
  -backend-config="bucket=$(terraform -chdir=../bootstrap output -raw state_bucket_name)" \
  -backend-config="region=eu-west-1"
```

Use `-reconfigure` for a fresh setup. Use `-migrate-state` only when moving
existing local state into the bucket, which Terraform will prompt about.

## Two things to know

**The bucket has `prevent_destroy = true`.** That guards the state history
against a stray `terraform destroy` in this directory. It also means teardown
requires deliberately removing that `lifecycle` block first. Bootstrap is
destroyed last, after the main stack, because the main stack's state lives in
it.

**`.terraform.lock.hcl` is committed, local state is not.** The lock file pins
the provider to the exact version resolved (6.60.0) with checksums, so every
machine gets the same build. The `*.tfstate` files are gitignored, since
bootstrap's local state is the one state file that is never in S3.

## Verification results

| Check | Result |
|---|---|
| `terraform fmt -check` | clean |
| `terraform validate` | Success |
| `terraform plan` | 7 to add, 0 to change, 0 to destroy |
| `trivy config` | 0 misconfigurations |

Not applied yet. No AWS resources were created during this step.
