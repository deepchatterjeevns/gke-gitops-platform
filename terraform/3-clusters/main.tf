# Layer 3 — TWO regional GKE Standard clusters (bullet 1 parity: multi-region,
# multi-cluster GitOps) + Workload Identity + demo-app KSAs.
#
# GKE MODE RULE (Step 0.4): STANDARD, both clusters. Why not Autopilot:
# kube-prometheus-stack ships node-exporter as a DaemonSet touching hostPath
# /proc + /sys — Autopilot's restricted PSA blocks it, and bullet-1 parity
# is "ArgoCD across regional GKE Standard clusters" (the AWS shape). Cost
# discipline instead via: Spot secondary pool for stateless workloads,
# total_min_count floors, release_channel REGULAR.
#
# Regional clusters = 3-zone control planes — the HA claim in bullet 1 is
# honest at the control-plane level (unlike a 2026-09-02 Autopilot note
# where the evidence plane was 1-replica; nodes here are also multi-zone
# by construction).

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
  backend "gcs" {
    # >>> INSERT YOUR VALUES: bucket from layer 0 (deploy.sh patches this) <<<
    bucket = "gke-gitops-tfstate-498315"
    prefix = "clusters"
  }
}

# >>> INSERT YOUR VALUES: same as previous layers <<<
variable "gcp_project_id" { type = string }
variable "prod_region" {
  type    = string
  default = "us-central1"
}
variable "dev_region" {
  type    = string
  default = "asia-south1"
}

variable "name_prefix" {
  type    = string
  default = "gitops-poc"
}

variable "master_authorized_cidr" {
  type        = string
  default     = "0.0.0.0/0"
  description = "Your workstation CIDR for kubectl. Tighten for real use; POC keeps default documented in runbook."
}

# From layer 2 (data source keeps layers decoupled — remote_state would need
# the bucket; simpler: this layer takes the values via tfvars written by
# deploy.sh. Defaults here are the layer-2 defaults.)
variable "prod_network" { default = "gitops-poc-vpc" }
variable "prod_subnet" { default = "gitops-poc-prod-subnet" }
variable "dev_network" { default = "gitops-poc-dev-vpc" }
variable "dev_subnet" { default = "gitops-poc-dev-subnet" }

provider "google" {
  project               = var.gcp_project_id
  region                = var.prod_region
  user_project_override = true
  billing_project       = var.gcp_project_id
}

# --- PROD cluster (us-central1, regional, Standard) ------------------------------
resource "google_container_cluster" "prod" {
  name     = "${var.name_prefix}-prod-us"
  location = var.prod_region # REGIONAL — 3-zone control plane + nodes

  # Private nodes: no external IPs. Control plane: public endpoint restricted
  # by master authorized networks (tradeoff documented in architecture.md).
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false # ArgoCD needs no public k8s API; kubectl does
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = compact([
        var.master_authorized_cidr,
        # Gotcha #8: prod cluster's OWN nodes reach own control plane via
        # NAT? No — own-cluster components use the private path. Kept for
        # the cross-cluster case only (dev whitelist uses prod NAT IP).
        "",
      ])
      content {
        cidr_block   = cidr_blocks.value
        display_name = "workstation"
      }
    }
  }

  networking_mode = "VPC_NATIVE"
  network         = "projects/${var.gcp_project_id}/global/networks/${var.prod_network}"
  subnetwork      = "projects/${var.gcp_project_id}/regions/${var.prod_region}/subnetworks/${var.prod_subnet}"

  ip_allocation_policy {
    cluster_secondary_range_name  = "prod-pods"
    services_secondary_range_name = "prod-services"
  }

  release_channel {
    channel = "REGULAR"
  }

  workload_identity_config {
    workload_pool = "${var.gcp_project_id}.svc.id.goog"
  }

  deletion_protection      = false # GOTCHA #2: TF default is true — destroy hangs
  enable_l4_ilb_subsetting = true

  resource_labels = {
    project = "gke-gitops-poc" # GOTCHA #7: lowercase+dashes only
    env     = "prod"
  }

  # Default pool: on-demand, small — ArgoCD + monitoring live here.
  # Gotcha #4: min node counts are TOTAL across the region's zones.
  node_pool {
    name               = "platform-pool"
    initial_node_count = 1
    autoscaling {
      total_min_node_count = 1
      total_max_node_count = 2
    }
    node_config {
      machine_type = "e2-standard-2"
      disk_size_gb = 50
      disk_type    = "pd-balanced"
      image_type   = "COS_CONTAINERD"
      oauth_scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
      ]
      labels = {
        project = "gke-gitops-poc"
        pool    = "platform"
      }
    }
    management {
      auto_repair  = true
      auto_upgrade = true
    }
  }

  # Secondary pool: SPOT — demo apps + anything stateless tolerate eviction.
  node_pool {
    name               = "spot-pool"
    initial_node_count = 1
    autoscaling {
      total_min_node_count = 1
      total_max_node_count = 3
    }
    node_config {
      machine_type = "e2-standard-2"
      disk_size_gb = 50
      disk_type    = "pd-balanced"
      image_type   = "COS_CONTAINERD"
      # Spot: preemptible-class VMs, ~60-70% off — mirrors the AWS-era
      # Spot-managed-node-group habit.
      preemptible = false
      spot        = true
      oauth_scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
      ]
      labels = {
        project = "gke-gitops-poc"
        pool    = "spot"
      }
      taint {
        key    = "gitops-poc/spot"
        value  = "true"
        effect = "NO_SCHEDULE"
      }
    }
    management {
      auto_repair  = true
      auto_upgrade = true
    }
  }

  lifecycle {
    ignore_changes = [node_pool] # autoscaler breathes; TF owns creation only
  }

  timeouts {
    create = "45m"
    delete = "45m"
  }
}

# --- DEV cluster (asia-south1, regional, Standard — smaller footprint) -----------
resource "google_container_cluster" "dev" {
  name     = "${var.name_prefix}-dev-in"
  location = var.dev_region

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.1.0/28"
  }

  # Gotcha #8 LIVE HERE: prod ArgoCD reaches this control plane over the
  # internet via prod's NAT IP. deploy.sh patches master_authorized_networks
  # with layer-2's prod_nat_ip output. Patch happens OUTSIDE terraform apply
  # (gcloud one-liner, idempotent) to keep layer boundaries clean.
  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = compact([var.master_authorized_cidr, ""])
      content {
        cidr_block   = cidr_blocks.value
        display_name = "workstation"
      }
    }
  }

  networking_mode = "VPC_NATIVE"
  network         = "projects/${var.gcp_project_id}/global/networks/${var.dev_network}"
  subnetwork      = "projects/${var.gcp_project_id}/regions/${var.dev_region}/subnetworks/${var.dev_subnet}"

  ip_allocation_policy {
    cluster_secondary_range_name  = "dev-pods"
    services_secondary_range_name = "dev-services"
  }

  release_channel {
    channel = "REGULAR"
  }

  workload_identity_config {
    workload_pool = "${var.gcp_project_id}.svc.id.goog"
  }

  deletion_protection = false

  resource_labels = {
    project = "gke-gitops-poc"
    env     = "dev"
  }

  node_pool {
    name               = "platform-pool"
    initial_node_count = 1
    autoscaling {
      total_min_node_count = 1
      total_max_node_count = 2
    }
    node_config {
      machine_type = "e2-standard-2"
      disk_size_gb = 50
      image_type   = "COS_CONTAINERD"
      oauth_scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
      ]
      labels = {
        project = "gke-gitops-poc"
        pool    = "platform"
      }
    }
    management {
      auto_repair  = true
      auto_upgrade = true
    }
  }

  lifecycle {
    ignore_changes = [node_pool]
  }

  timeouts {
    create = "45m"
    delete = "45m"
  }
}

# --- Outputs ---------------------------------------------------------------------
output "prod_cluster_name" {
  value = google_container_cluster.prod.name
}

output "prod_cluster_location" {
  value = google_container_cluster.prod.location
}

output "dev_cluster_name" {
  value = google_container_cluster.dev.name
}

output "dev_cluster_location" {
  value = google_container_cluster.dev.location
}

output "demo_app_gsa_email" {
  value       = google_service_account.demo_app.email
  description = "Annotate ESO's serviceAccount + demo KSAs with this (gitops/ manifests hardcode the INSERT marker)"
}

# --- Workload Identity: GSA for demo app (bullet 6 — SM read via ESO) -------------
resource "google_service_account" "demo_app" {
  account_id   = "${var.name_prefix}-demo-app"
  display_name = "Demo app SA — Secret Manager reader (ESO uses this via WI)"
}

resource "google_project_iam_member" "demo_app_sm_reader" {
  project = var.gcp_project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.demo_app.email}"
}

# GKE metadata server is cluster-scoped: bind the SAME GSA to the KSAs in
# BOTH clusters. Gotcha #3: member string must be exactly
#   serviceAccount:PROJECT.svc.id.goog[NAMESPACE/KSA_NAME]
# and the KSA must EXIST before pods using WI start (gitops/ manifests
# create the KSAs; ESO waits for the annotation).
resource "google_service_account_iam_binding" "demo_app_wi_prod" {
  service_account_id = google_service_account.demo_app.name
  role               = "roles/iam.workloadIdentityUser"

  members = [
    "serviceAccount:${var.gcp_project_id}.svc.id.goog[demo/demo-app]",
  ]
}

# Same binding covers the dev cluster — GSA is project-global, the WI pool
# is per-project, binding is namespace/ksa-scoped. One binding, two clusters.
