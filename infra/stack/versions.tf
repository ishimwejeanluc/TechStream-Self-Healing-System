terraform {
  # 1.10 is the floor for use_lockfile (S3-native state locking).
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.6"
    }
  }

  # Points at the bucket created by ../bootstrap. Backend blocks cannot use
  # variables or interpolation, so these values are literal. If your account or
  # region differs, either edit them to match the bootstrap state_bucket_name
  # output, or pass them at init time:
  #
  #   terraform init -reconfigure \
  #     -backend-config="bucket=$(terraform -chdir=../bootstrap output -raw state_bucket_name)" \
  #     -backend-config="region=eu-west-1"
  backend "s3" {
    bucket       = "techstream-tfstate-515966510180-eu-west-1"
    key          = "techstream/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true

    # On Terraform older than 1.10, remove use_lockfile above and use:
    # dynamodb_table = "techstream-tflock"
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      Component = "self-healing-lab"
      ManagedBy = "terraform"
    }
  }
}
