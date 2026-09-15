# Layer 2 — network: shared VPC per region, private nodes, Cloud NAT
#
# Two regional GKE Standard clusters need: VPC + subnet per region, private
# nodes (no external IPs), and Cloud NAT so ArgoCD (prod) can reach the dev
# cluster control plane AND so nodes can pull from Artifact Registry /
# Secret Manager via Private Google Access.
#
# Gotcha #8 (multi-cluster): prod ArgoCD must reach the DEV control plane.
# Dev master authorized networks (layer 3) must contain prod's Cloud NAT
# egress IP — this layer outputs it.

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
    bucket = "gke-gitops-tfstate-YOUR-SUFFIX"
    prefix = "network"
  }
}

# >>> INSERT YOUR VALUES: same as previous layers <<<
variable "gcp_project_id" { type = string }

variable "name_prefix" {
  type    = string
  default = "gitops-poc"
}

# Regions fixed by the design: prod=us-central1, dev=asia-south1 (IST-local
# for the cross-region story). Change only with the runbook's quota caveats.
variable "prod_region" {
  type    = string
  default = "us-central1"
}

variable "dev_region" {
  type    = string
  default = "asia-south1"
}

provider "google" {
  project = var.gcp_project_id
}

# --- Prod region network (us-central1) ------------------------------------------
resource "google_compute_network" "prod" {
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "prod" {
  name          = "${var.name_prefix}-prod-subnet"
  ip_cidr_range = "10.10.0.0/20"
  region        = var.prod_region
  network       = google_compute_network.prod.id

  private_ip_google_access = true # free AR/SM pulls via Google's peering

  secondary_ip_range {
    range_name    = "prod-pods"
    ip_cidr_range = "10.16.0.0/14"
  }
  secondary_ip_range {
    range_name    = "prod-services"
    ip_cidr_range = "10.20.0.0/20"
  }
}

resource "google_compute_router" "prod" {
  name    = "${var.name_prefix}-prod-router"
  region  = var.prod_region
  network = google_compute_network.prod.id
}

resource "google_compute_address" "prod_nat" {
  name   = "${var.name_prefix}-prod-nat-ip"
  region = var.prod_region
}

resource "google_compute_router_nat" "prod" {
  name                               = "${var.name_prefix}-prod-nat"
  region                             = var.prod_region
  router                             = google_compute_router.prod.name
  nat_ips                            = [google_compute_address.prod_nat.self_link]
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# --- Dev region network (asia-south1) -------------------------------------------
resource "google_compute_network" "dev" {
  name                    = "${var.name_prefix}-dev-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "dev" {
  name          = "${var.name_prefix}-dev-subnet"
  ip_cidr_range = "10.30.0.0/20"
  region        = var.dev_region
  network       = google_compute_network.dev.id

  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "dev-pods"
    ip_cidr_range = "10.36.0.0/14"
  }
  secondary_ip_range {
    range_name    = "dev-services"
    ip_cidr_range = "10.40.0.0/20"
  }
}

resource "google_compute_router" "dev" {
  name    = "${var.name_prefix}-dev-router"
  region  = var.dev_region
  network = google_compute_network.dev.id
}

resource "google_compute_address" "dev_nat" {
  name   = "${var.name_prefix}-dev-nat-ip"
  region = var.dev_region
}

resource "google_compute_router_nat" "dev" {
  name                               = "${var.name_prefix}-dev-nat"
  region                             = var.dev_region
  router                             = google_compute_router.dev.name
  nat_ips                            = [google_compute_address.dev_nat.self_link]
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# --- Firewall: allow GKE master→nodes (tag-based), health checks ------------
# NOTE: GKE Standard auto-creates its own firewall rules using generated node
# tags (gke-<cluster>-<hash>-node). These rules serve as documentation of
# the required ports/ranges; GKE's auto-managed rules handle actual traffic.
resource "google_compute_firewall" "prod_master_to_nodes" {
  name    = "${var.name_prefix}-prod-master-to-nodes"
  network = google_compute_network.prod.id

  allow {
    protocol = "tcp"
    ports    = ["10250", "443", "8443"]
  }

  # Master CIDR is set in layer 3 output patch; GKE auto-adds its own rule.
  source_ranges = ["10.10.0.0/20"] # placeholder = subnet (GKE adds real rule)
  target_tags   = ["${var.name_prefix}-prod-node"]
}

resource "google_compute_firewall" "dev_master_to_nodes" {
  name    = "${var.name_prefix}-dev-master-to-nodes"
  network = google_compute_network.dev.id

  allow {
    protocol = "tcp"
    ports    = ["10250", "443", "8443"]
  }

  source_ranges = ["10.30.0.0/20"]
  target_tags   = ["${var.name_prefix}-dev-node"]
}

# --- Outputs --------------------------------------------------------------------
output "prod_network" {
  value = google_compute_network.prod.name
}

output "prod_subnet" {
  value = google_compute_subnetwork.prod.name
}

output "prod_pods_range" {
  value = google_compute_subnetwork.prod.secondary_ip_range[0].range_name
}

output "prod_services_range" {
  value = google_compute_subnetwork.prod.secondary_ip_range[1].range_name
}

output "dev_network" {
  value = google_compute_network.dev.name
}

output "dev_subnet" {
  value = google_compute_subnetwork.dev.name
}

output "dev_pods_range" {
  value = google_compute_subnetwork.dev.secondary_ip_range[0].range_name
}

output "dev_services_range" {
  value = google_compute_subnetwork.dev.secondary_ip_range[1].range_name
}

# THE multi-cluster gotcha output: prod NAT IP must be allowed into the dev
# cluster's master authorized networks (used by layer 3 + register_cluster.sh).
output "prod_nat_ip" {
  value       = google_compute_address.prod_nat.address
  description = "Whitelist THIS in dev master authorized networks so prod ArgoCD can reach dev control plane"
}

output "dev_nat_ip" {
  value       = google_compute_address.dev_nat.address
  description = "Dev NAT egress IP (informational)"
}
