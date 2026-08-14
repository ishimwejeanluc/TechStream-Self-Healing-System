data "aws_caller_identity" "current" {}

locals {
  # Bucket names are globally unique, so scope it with account and region.
  # Deterministic, so re-running bootstrap never makes a second bucket.
  state_bucket_name = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}-${var.region}"
  lock_table_name   = "${var.project}-tflock"
}

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket_name

  # Protects the state history from a stray terraform destroy in this dir.
  # Remove this block first if you really mean to tear the backend down.
  lifecycle {
    prevent_destroy = true
  }
}

# Versioning is what makes state recoverable after a bad apply.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = var.kms_key_arn != null
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Reject any plaintext PutObject or GetObject against the state bucket.
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  # Provider 6.x requires this to be explicit once versioning is on.
  depends_on = [aws_s3_bucket_versioning.state]

  rule {
    id     = "retain-noncurrent-state-versions"
    status = "Enabled"

    # Empty filter means the rule covers every object in the bucket.
    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = var.noncurrent_version_retention_days
      newer_noncurrent_versions = var.noncurrent_versions_to_keep
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Only created when create_dynamodb_lock_table = true, for Terraform < 1.10.
resource "aws_dynamodb_table" "lock" {
  count = var.create_dynamodb_lock_table ? 1 : 0

  name         = local.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}
