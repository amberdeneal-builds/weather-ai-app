terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Zips the Lambda source in src/ at plan/apply time - see lambda.tf.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    # Manages the Workload Identity Federation pool/provider on the GCP side
    # (see wif.tf). Authenticates with your own user credentials via
    # `gcloud auth application-default login` - deliberately not a service
    # account key, which is the thing this whole change exists to remove.
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # No remote backend yet — state is local for this lab. Before this is used
  # for anything real, add an S3 backend (versioned bucket + DynamoDB lock
  # table, both provisioned out-of-band so state isn't managing itself):
  #
  # backend "s3" {
  #   bucket         = "weather-ai-tfstate-<account-id>"
  #   key            = "weather-ai/account-structure.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "weather-ai-tflock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_vertex_location
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}
