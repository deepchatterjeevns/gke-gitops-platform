#!/usr/bin/env bash
# deploy.sh — day-1: GCS backend → baseline → network → 2 clusters → ArgoCD
# bootstrap → dev cluster registration → root app → wait.
# Usage: ./scripts/deploy.sh
# Prereqs: terraform, gcloud, kubectl, helm, kustomize, git.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="$ROOT/terraform"
PROJECT="${GCP_PROJECT_ID:?Set GCP_PROJECT_ID env var}"
BILLING_ACCOUNT="${BILLING_ACCOUNT_ID:?Set BILLING_ACCOUNT_ID env var (gcloud billing accounts list)}"
BUCKET_SUFFIX="${BUCKET_SUFFIX:-${PROJECT##*-}}"
SECRETS_TFVARS="$ROOT/secrets.tfvars"
log() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

# --- 0. Prereq gates -----------------------------------------------------------
for tool in terraform gcloud kubectl helm kustomize git; do
  command -v "$tool" >/dev/null || { echo "FATAL: missing $tool"; exit 1; }
done
[[ -f "$SECRETS_TFVARS" ]] || { echo "FATAL: $SECRETS_TFVARS not found. Copy secrets.tfvars.template and fill values."; exit 1; }
log "prereq tools + secrets.tfvars OK"

# --- 1. Layer 0: GCS state backend ----------------------------------------------
log "layer 0: GCS state backend"
pushd "$TF/0-gcs-backend" >/dev/null
  terraform init -input=false
  terraform apply -auto-approve \
    -var "gcp_project_id=$PROJECT" \
    -var "bucket_suffix=$BUCKET_SUFFIX"
  STATE_BUCKET="$(terraform output -raw state_bucket)"
popd >/dev/null
echo "state bucket: $STATE_BUCKET"

# --- 2. Layers 1-3: point backends at the real bucket ------------------------------
log "layers 1-3: patching backend bucket refs"
for layer in 1-baseline 2-network 3-clusters; do
  sed -i.bak "s/gke-gitops-tfstate-YOUR-SUFFIX/$STATE_BUCKET/g" "$TF/$layer/main.tf"
  rm -f "$TF/$layer/main.tf.bak"
done

log "layer 1: baseline (APIs + AR + secret + budget)"
pushd "$TF/1-baseline" >/dev/null
  terraform init -input=false
  # First apply may hit enabled-not-effective APIs — sleep + retry is the fix.
  TF_BASELINE_VARS=(-var "gcp_project_id=$PROJECT" -var "billing_account_id=$BILLING_ACCOUNT" -var-file="$SECRETS_TFVARS")
  terraform apply -auto-approve "${TF_BASELINE_VARS[@]}" || { echo "retrying after API warm..."; sleep 90; terraform apply -auto-approve "${TF_BASELINE_VARS[@]}"; }
  AR_REPO="$(terraform output -raw artifact_registry)"
popd >/dev/null
echo "AR: $AR_REPO"

log "layer 2: network (2 VPCs + private subnets + Cloud NAT)"
pushd "$TF/2-network" >/dev/null
  terraform init -input=false
  terraform apply -auto-approve -var "gcp_project_id=$PROJECT" || { echo "retrying after API warm..."; sleep 60; terraform apply -auto-approve -var "gcp_project_id=$PROJECT"; }
  PROD_NAT_IP="$(terraform output -raw prod_nat_ip)"
popd >/dev/null
echo "prod NAT IP (must be whitelisted on dev master): $PROD_NAT_IP"

log "layer 3: TWO regional clusters (us-central1 + asia-south1)"
pushd "$TF/3-clusters" >/dev/null
  terraform init -input=false
  # Two regional clusters in ONE apply: 25-35 min. Retry once on API races.
  terraform apply -auto-approve -var "gcp_project_id=$PROJECT" || { echo "retrying after API warm..."; sleep 90; terraform apply -auto-approve -var "gcp_project_id=$PROJECT"; }
  PROD_CLUSTER="$(terraform output -raw prod_cluster_name)"
  PROD_LOC="$(terraform output -raw prod_cluster_location)"
  DEV_CLUSTER="$(terraform output -raw dev_cluster_name)"
  DEV_LOC="$(terraform output -raw dev_cluster_location)"
  GSA_EMAIL="$(terraform output -raw demo_app_gsa_email)"
popd >/dev/null
echo "prod: $PROD_CLUSTER ($PROD_LOC)  dev: $DEV_CLUSTER ($DEV_LOC)"
echo "demo GSA: $GSA_EMAIL"

# --- 3. kubeconfigs ----------------------------------------------------------------
log "kubeconfigs (contexts: gitops-prod / gitops-dev)"
gcloud container clusters get-credentials "$PROD_CLUSTER" --region "$PROD_LOC" --project "$PROJECT"
gcloud container clusters get-credentials "$DEV_CLUSTER" --region "$DEV_LOC" --project "$PROJECT"
kubectl config rename-context "gke_${PROJECT}_${PROD_LOC}_${PROD_CLUSTER}" gitops-prod || true
kubectl config rename-context "gke_${PROJECT}_${DEV_LOC}_${DEV_CLUSTER}" gitops-dev || true

# --- 4. Multi-cluster gotcha #8: whitelist prod NAT on dev master ------------------
log "whitelisting prod NAT IP ($PROD_NAT_IP) on dev master authorized networks"
gcloud container clusters update "$DEV_CLUSTER" --region "$DEV_LOC" \
  --enable-master-authorized-networks \
  --master-authorized-networks "${PROD_NAT_IP}/32" >/dev/null \
  || echo "NOTE: add ${PROD_NAT_IP}/32 to dev master authorized networks manually (or rerun deploy)"

# --- 5. Bootstrap ArgoCD on prod --------------------------------------------------
log "bootstrap: ArgoCD (helm)"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --values "$ROOT/gitops/bootstrap/argocd-values.yaml" --wait

# --- 6. Patch INSERT markers with live values ------------------------------------
log "patching INSERT markers (repo URL, GSA, project number)"
REPO_URL="${REPO_URL:-">>> INSERT YOUR VALUES: repo URL — export REPO_URL before deploy <<<"}"
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"
grep -rl ">>> INSERT YOUR VALUES: repo URL <<<" "$ROOT/gitops" | while read -r f; do
  sed -i.bak "s|>>> INSERT YOUR VALUES: repo URL <<<|$REPO_URL|g" "$f"; rm -f "$f.bak"
done
grep -rl ">>> INSERT YOUR VALUES: GSA EMAIL <<<\|>>> INSERT YOUR VALUES: GSA EMAIL (gitops-poc-demo-app@PROJECT.iam.gserviceaccount.com) <<<" "$ROOT/gitops" | while read -r f; do
  sed -i.bak "s|>>> INSERT YOUR VALUES: GSA EMAIL (gitops-poc-demo-app@PROJECT.iam.gserviceaccount.com) <<<|$GSA_EMAIL|g; s|>>> INSERT YOUR VALUES: GSA EMAIL <<<|$GSA_EMAIL|g" "$f"; rm -f "$f.bak"
done
grep -rl ">>> INSERT YOUR VALUES: PROJECT NUMBER (gcloud projects describe --format=value(projectNumber)) <<<" "$ROOT/gitops" | while read -r f; do
  sed -i.bak "s|>>> INSERT YOUR VALUES: PROJECT NUMBER (gcloud projects describe --format=value(projectNumber)) <<<|$PROJECT_NUMBER|g" "$f"; rm -f "$f.bak"
done
sed -i.bak "s|>>> INSERT YOUR AR REPO URL <<<|$AR_REPO|g" \
  "$ROOT/gitops/apps-src/demo-app/overlays/prod/rollout.yaml" \
  "$ROOT/gitops/apps-src/demo-app/overlays/dev/rollout.yaml"
rm -f "$ROOT/gitops/apps-src/demo-app/overlays/prod/rollout.yaml.bak" "$ROOT/gitops/apps-src/demo-app/overlays/dev/rollout.yaml.bak"

# --- 7. Register dev cluster with prod ArgoCD ---------------------------------------
log "registering dev cluster with prod ArgoCD"
"$ROOT/scripts/register_cluster.sh"

# --- 7b. Patch dev cluster endpoint into dev-apps.yaml ------------------------------
log "patching dev cluster endpoint into dev-apps.yaml"
DEV_ENDPOINT="$(kubectl --context gitops-dev config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
if [[ -n "$DEV_ENDPOINT" && "$DEV_ENDPOINT" != *"INSERT"* ]]; then
  sed -i.bak "s|https://INSERT-DEV-CLUSTER-ENDPOINT|$DEV_ENDPOINT|g" "$ROOT/gitops/apps/dev-apps.yaml"
  rm -f "$ROOT/gitops/apps/dev-apps.yaml.bak"
  echo "dev endpoint patched: $DEV_ENDPOINT"
else
  echo "WARNING: could not determine dev endpoint — patch gitops/apps/dev-apps.yaml manually"
fi

# --- 8. Root app ----------------------------------------------------------------------
log "applying root app-of-apps"
kubectl apply -f "$ROOT/gitops/root-app.yaml" --context gitops-prod

log "waiting for ArgoCD apps to sync (platform ~5-8 min)"
sleep 60
kubectl --context gitops-prod -n argocd get applications

log "DEPLOY COMPLETE"
echo "next: make traffic (prod) && watch rollouts: kubectl argo rollouts get rollout demo-app -n demo --watch"
