# Grafana Cloud Machine Learning jobs, provisioned as code.
#
# Separate state from infra/stack on purpose. This directory uses the grafana
# provider and a Grafana service account token. The AWS stack uses the aws
# provider and AWS credentials. Different credentials, different blast radius,
# and different lifecycles: ML jobs get tuned often, the EC2 instance does not.
#
# Same bucket as the rest of the project, different key, so the two states are
# independent and neither apply can lock or corrupt the other.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    bucket = "techstream-tfstate-515966510180-eu-west-1"
    # Different key from infra/stack, which uses techstream/terraform.tfstate.
    key          = "techstream/grafana-ml.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
  }
}

# Authenticated with the stack URL and a service account token, not a personal
# login, so it survives the person who created it leaving.
provider "grafana" {
  url  = var.grafana_url
  auth = var.grafana_auth
}
