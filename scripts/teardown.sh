#!/usr/bin/env bash
# teardown.sh — reverse-order destroy + orphan hunt. SEPARATE from the
# credit-expiry teardown (docs/credit-expiry-teardown.md) which has its own
# hard date: EVERYTHING off by 2026-09-21 IST.
# Usage: ./scripts/teardown.sh [--full]  (--full also destroys state bucket)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${GCP_PROJECT_ID:?Set GCP_PROJECT_ID env var}"
FULL=0
[[ "${1:-}" == "--full" ]] && FULL=1

log() { printf '\n\033[1;31m== %s ==\033[0m\n' "$*"; }

# --- 1. ArgoCD apps off first (finalizers otherwise fight cluster delete) ---------
log "deleting ArgoCD applications (non-cascading, fast)"
kubectl --context gitops-prod -n argocd delete application --all --wait=false --ignore-not-found 2>/dev/null || true

# --- 2. Clusters (reverse layer order: 3 -> 2 -> 1) -------------------------------
log "terraform destroy: layer 3 (clusters) — ~15-20 min, two regional clusters"
pushd "$ROOT/terraform/3-clusters" >/dev/null
  terraform destroy -auto-approve
popd >/dev/null

log "terraform destroy: layer 2 (network)"
pushd "$ROOT/terraform/2-network" >/dev/null
  terraform destroy -auto-approve
popd >/dev/null

log "terraform destroy: layer 1 (baseline)"
pushd "$ROOT/terraform/1-baseline" >/dev/null
  terraform destroy -auto-approve
popd >/dev/null

# --- 3. Orphan hunt (GCP-specific) --------------------------------------------------
log "ORPHAN HUNT"
echo "--- GKE clusters (expect none):"
gcloud container clusters list --project "$PROJECT" 2>/dev/null || true
echo "--- Compute instances (expect none):"
gcloud compute instances list --project "$PROJECT" 2>/dev/null || true
echo "--- Orphaned PDs:"
gcloud compute disks list --filter="labels.project=gke-gitops-poc" --project "$PROJECT" 2>/dev/null || echo "  (label filter empty = OK)"
echo "--- Forwarding rules / LBs (stack creates none):"
gcloud compute forwarding-rules list --project "$PROJECT" 2>/dev/null || true
echo "--- Static IPs (NAT IPs gone with layer 2):"
gcloud compute addresses list --project "$PROJECT" 2>/dev/null || true
echo "--- Routers / NAT gateways:"
gcloud compute routers list --project "$PROJECT" 2>/dev/null || true
echo "--- Pub/Sub budget topic:"
gcloud pubsub topics list --project "$PROJECT" 2>/dev/null | grep budget || echo "  gone (OK)"
echo "--- Secret Manager:"
gcloud secrets list --project "$PROJECT" 2>/dev/null | grep gitops-poc || echo "  gone (OK)"
echo "--- AR repos:"
gcloud artifacts repositories list --project "$PROJECT" 2>/dev/null | grep gitops-poc || echo "  gone (OK)"
echo "--- Service account KEYS (should be empty):"
gcloud iam service-accounts keys list --project "$PROJECT" 2>/dev/null || true
echo "--- GCS state bucket (intentional survivor until --full):"
gcloud storage buckets list --filter="name~gke-gitops-tfstate" --project "$PROJECT" 2>/dev/null || true

if [[ $FULL -eq 1 ]]; then
  log "FULL MODE: destroying state bucket"
  pushd "$ROOT/terraform/0-gcs-backend" >/dev/null
    terraform state rm google_storage_bucket.state
    terraform destroy -auto-approve
  popd >/dev/null
fi

log "TEARDOWN COMPLETE — see docs/credit-expiry-teardown.md for the HARD-DATE checklist (2026-09-21)"
echo "NOTE: Cloud Build triggers (if created) are NOT managed by Terraform."
echo "      See docs/credit-expiry-teardown.md §2 for manual cleanup."
