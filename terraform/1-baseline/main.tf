# Layer 1 — baseline: APIs, Artifact Registry, Secret Manager secret, budget
#
# Enables every API the higher layers need (ORDER MATTERS — see time_sleep),
# creates the AR repo + the single demo secret + the credit-ceiling budget.
#
# SECRETS DECISION (Step 0.3): Secret Manager + External Secrets Operator
# over Vault-on-GKE. Why: (a) no extra in-cluster stateful HA component to
# run/protect inside a 7-day window; (b) GCP-native IAM via Workload
# Identity = bullet-6 reproof in cloud-idiomatic form (centralized secrets,
# zero hardcoded creds, IAM-governed access, audit-logged reads); (c) free
# tier covers this POC. Vault's portability argument is acknowledged in the
# article's comparison note — not built here.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
  backend "gcs" {
    # >>> INSERT YOUR VALUES: bucket from layer 0 (deploy.sh patches this) <<<
    bucket = "gke-gitops-tfstate-498315"
    prefix = "baseline"
  }
}

# >>> INSERT YOUR VALUES: same project as layer 0 <<<
variable "gcp_project_id" { type = string }

variable "gcp_region" {
  type    = string
  default = "us-central1"
}

variable "name_prefix" {
  type    = string
  default = "gitops-poc"
}

# >>> INSERT YOUR VALUES: from `gcloud billing accounts list` <<<
variable "billing_account_id" {
  type        = string
  description = "Billing account for the credit-ceiling budget"
}

provider "google" {
  project               = var.gcp_project_id
  region                = var.gcp_region
  user_project_override = true
  billing_project       = var.gcp_project_id
}

data "google_project" "current" {
  project_id = var.gcp_project_id
}

# --- API enablement, ORDER MATTERS (gotcha #1: enabled != EFFECTIVE) --------
locals {
  apis = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudbuild.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "billingbudgets.googleapis.com",
    "pubsub.googleapis.com",
    "cloudbilling.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each           = toset(local.apis)
  service            = each.value
  disable_on_destroy = false
}

# "Enabled" != "effective": GCP APIs take 20-60s post-enable. This sleep is
# IN the apply graph before anything that depends on the services.
resource "time_sleep" "api_warm" {
  depends_on      = [google_project_service.apis]
  create_duration = "90s"
}

# --- Artifact Registry (ECR analog; bullet 10) ------------------------------
resource "google_artifact_registry_repository" "apps" {
  location      = var.gcp_region
  repository_id = "${var.name_prefix}-apps"
  format        = "DOCKER"
  description   = "Demo app images for GitOps platform POC"
  labels = {
    project = "gke-gitops-poc"
  }
  depends_on = [time_sleep.api_warm]
}

# --- Secret Manager (bullet 6) ------------------------------------------------
# The demo secret ESO will project into both clusters. VALUE IS A TEMPLATE:
# NEVER commit the real value. Apply-time input via tfvars file that is
# gitignored (secrets.tfvars template in repo root — see runbook).
resource "google_secret_manager_secret" "demo_api_key" {
  secret_id = "${var.name_prefix}-demo-api-key"
  replication {
    auto {}
  }
  labels = {
    project = "gke-gitops-poc"
  }
  depends_on = [time_sleep.api_warm]
}

# >>> INSERT YOUR VALUES: real value lives ONLY in gitignored secrets.tfvars <<<
variable "demo_api_key_value" {
  type        = string
  sensitive   = true
  description = "Initial demo secret value (dummy for POC — e.g. poc-key-v1)"
}

resource "google_secret_manager_secret_version" "demo_api_key_v1" {
  secret      = google_secret_manager_secret.demo_api_key.id
  secret_data = var.demo_api_key_value
}

# --- Credit-ceiling budget (Part C: target = the CREDIT BALANCE, not a token cap)
# ~INR 40,000 ceiling. Thresholds 50/80/100% via Pub/Sub.
resource "google_pubsub_topic" "budget_alerts" {
  name = "${var.name_prefix}-budget-alerts"
}

resource "google_pubsub_subscription" "budget_alerts_sub" {
  name                       = "${var.name_prefix}-budget-alerts-sub"
  topic                      = google_pubsub_topic.budget_alerts.id
  message_retention_duration = "604800s" # 7d — the POC window
}

resource "google_billing_budget" "credit_ceiling" {
  billing_account = var.billing_account_id
  display_name    = "gke-gitops-poc-credit-ceiling"

  budget_filter {
    projects = ["projects/${data.google_project.current.number}"]
  }

  amount {
    specified_amount {
      currency_code = "INR"
      units         = "40000" # credit ceiling in the billing account currency
    }
  }

  dynamic "threshold_rules" {
    for_each = [0.5, 0.8, 1.0]
    content {
      threshold_percent = threshold_rules.value
    }
  }

  all_updates_rule {
    pubsub_topic   = google_pubsub_topic.budget_alerts.id
    schema_version = "1.0"
  }
}

# --- Outputs -------------------------------------------------------------------
output "artifact_registry" {
  value = "${var.gcp_region}-docker.pkg.dev/${var.gcp_project_id}/${var.name_prefix}-apps"
}

output "secret_name" {
  value       = google_secret_manager_secret.demo_api_key.secret_id
  description = "Secret Manager secret id consumed via ESO + Workload Identity"
}
