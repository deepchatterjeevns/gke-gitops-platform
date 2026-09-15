# Layer 0 — GCS remote-state backend (native locking; no DynamoDB analog needed)
#
# Cost: standard ~$0.020/GB-month — pennies. Keep-alive across sessions BY
# DESIGN: state survives stack teardown; hand-delete only at project
# retirement (or `make destroy-full`).
#
# CREDIT-EXPIRY NOTE: this bucket is the ONE intentional survivor — but see
# docs/credit-expiry-teardown.md: by 2026-09-21 it must be either emptied
# (zero objects) or the project must be scheduled for shutdown. It costs
# < $0.01/mo, but the rule is no billing past 2026-09-21.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

# >>> INSERT YOUR VALUES: GCP project that owns the POC (billing linked) <<<
variable "gcp_project_id" {
  type        = string
  description = "Dedicated project hosting state bucket + all POC resources"
}

variable "gcp_region" {
  type    = string
  default = "us-central1"
}

# >>> INSERT YOUR VALUES: globally-unique bucket suffix (e.g. your initials+date) <<<
variable "bucket_suffix" {
  type        = string
  description = "Globally-unique suffix for the state bucket name"
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

resource "google_storage_bucket" "state" {
  name                       = "gke-gitops-tfstate-${var.bucket_suffix}"
  location                   = "US"
  force_destroy              = false
  uniform_bucket_level_access = true

  # State survives stack teardown; hand-delete at retirement only.
  lifecycle {
    prevent_destroy = true
  }

  labels = {
    project = "gke-gitops-poc"
  }
}

output "state_bucket" {
  value = google_storage_bucket.state.name
}
