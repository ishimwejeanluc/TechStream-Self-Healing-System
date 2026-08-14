# Bootstrap uses LOCAL state on purpose. It creates the S3 bucket that the
# main config in ../terraform uses as its remote backend, so it cannot store
# its own state there. This is the chicken-and-egg break.

terraform {
  # 1.10 is the floor for S3-native state locking (use_lockfile).
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "techstream"
      Component = "tf-backend"
      ManagedBy = "terraform"
    }
  }
}
