# Step-by-Step Deployment Guide

**GKE GitOps Platform POC**  
**Credit Expiry Deadline**: 2026-09-21 IST  
**Estimated Time**: Day-0 (prep) + Day-1 (deploy ~45 min) + Day-2-5 (evidence ~90 min)

---

## Overview

This guide walks you through deploying a two-cluster GKE platform with:
- **Prod cluster**: us-central1 (ArgoCD, canary rollouts, SLO monitoring)
- **Dev cluster**: asia-south1 (blue-green rollouts, managed by prod ArgoCD)
- **GitOps**: ArgoCD app-of-apps pattern
- **Observability**: kube-prometheus-stack with MWMB burn alerts
- **Secrets**: Secret Manager + External Secrets Operator via Workload Identity

---

## Day-0: Prerequisites (Do These First)

### 0.1 GCP Project Setup

```bash
# Create or identify a dedicated GCP project
export GCP_PROJECT_ID="gcplearn9-498315"
export BILLING_ACCOUNT_ID="$(gcloud billing accounts list --format='value(ACCOUNT_ID)' | head -1)"

# Link billing account (if new project)
gcloud billing projects link $GCP_PROJECT_ID --billing-account=$BILLING_ACCOUNT_ID

# Set default project
gcloud config set project $GCP_PROJECT_ID
```

### 0.2 Enable Required APIs (Optional - deploy.sh will enable them)

```bash
gcloud services enable \
  compute.googleapis.com \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  cloudbuild.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  billingbudgets.googleapis.com \
  pubsub.googleapis.com \
  cloudbilling.googleapis.com
```

### 0.3 Check Quotas (Both Regions)

```bash
# Check CPU quota in both regions (need ~8 vCPUs each with headroom)
gcloud compute regions describe us-central1 --format='value(quotas)'
gcloud compute regions describe asia-south1 --format='value(quotas)'

# If insufficient, file quota request NOW (approval can take hours-days)
# Go to: Console → IAM & Admin → Quotas → Request quota increase
```

### 0.4 Install Required Tools

```bash
# Terraform >= 1.9
terraform version

# gcloud CLI
gcloud version

# kubectl
kubectl version --client

# Helm
helm version

# kustomize (or use kubectl kustomize)
kustomize version

# argocd CLI
# Linux/macOS:
curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x /usr/local/bin/argocd
# Windows: download from https://github.com/argoproj/argo-cd/releases

# kubectl argo-rollouts plugin
kubectl krew install argo-rollouts

# Python 3
python3 --version
```

### 0.5 Prepare Repository

```bash
# Clone or navigate to the repository
cd code

# Copy secrets template
cp secrets.tfvars.template secrets.tfvars

# Edit secrets.tfvars - set a dummy POC value
# demo_api_key_value = "poc-key-v1"
```

### 0.6 Push to Your GitHub Repository

```bash
# Create a new repository on GitHub (do not initialize with README)
# Then push this code:
git init
git add .
git commit -m "Initial commit"
git branch -M main
git remote add origin https://github.com/deepchatterjeevns/gke-gitops-platform.git
git push -u origin main

# Export the repository URL
export REPO_URL="https://github.com/deepchatterjeevns/gke-gitops-platform.git"
```

---

## Day-1: Deployment (~45 min)

### 1.1 Set Environment Variables

```bash
cd code

# Required environment variables
export GCP_PROJECT_ID="your-project-id"
export BILLING_ACCOUNT_ID="XXXXXX-XXXXXX-XXXXXX"  # from: gcloud billing accounts list
export REPO_URL="https://github.com/YOUR-USER/gke-gitops-platform.git"
export BUCKET_SUFFIX="${BUCKET_SUFFIX:-${GCP_PROJECT_ID##*-}}"  # auto-derived or set manually

# Optional: customize cluster access CIDR (default is 0.0.0.0/0 for POC)
# export MASTER_AUTHORIZED_CIDR="$(curl -s ifconfig.me)/32"
```

### 1.2 Verify secrets.tfvars Exists

```bash
# Ensure secrets.tfvars exists and has the required value
cat secrets.tfvars
# Should contain: demo_api_key_value = "poc-key-v1" (or your value)
```

### 1.3 Run Deployment

```bash
# Full deployment: GCS backend → baseline → network → 2 clusters → ArgoCD → GitOps
make apply

# Or run directly:
# ./scripts/deploy.sh
```

**What `make apply` does:**

1. **Layer 0**: Creates GCS state bucket (~1 min)
2. **Layer 1**: Enables APIs, creates Artifact Registry, Secret Manager secret, budget (~5 min)
3. **Layer 2**: Creates VPCs, subnets, Cloud NAT (~5 min)
4. **Layer 3**: Creates TWO regional GKE clusters (~25-35 min)
5. **Kubeconfigs**: Fetches credentials, renames contexts to `gitops-prod` and `gitops-dev`
6. **Whitelist**: Adds prod NAT IP to dev master authorized networks
7. **ArgoCD**: Installs ArgoCD via Helm (~2 min)
8. **Patching**: Replaces all INSERT placeholders with live values
9. **Registration**: Registers dev cluster with prod ArgoCD
10. **Root App**: Applies app-of-apps root application

### 1.4 Monitor Deployment Progress

```bash
# Watch ArgoCD applications sync (separate terminal)
watch 'kubectl --context gitops-prod -n argocd get applications'

# Expected: All applications should reach Healthy status within 5-8 min
```

### 1.5 Verify Deployment

```bash
# Check clusters
kubectl --context gitops-prod get nodes
kubectl --context gitops-dev get nodes

# Check ArgoCD apps
kubectl --context gitops-prod -n argocd get applications

# Check demo app
kubectl --context gitops-prod -n demo get rollout demo-app
kubectl --context gitops-prod -n demo get pods

# Expected: Rollout phase should be "Healthy"
```

### 1.6 Access ArgoCD UI (Optional)

```bash
# Port-forward ArgoCD server
kubectl --context gitops-prod -n argocd port-forward svc/argocd-server 8080:80 &

# Get initial admin password
kubectl --context gitops-prod -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

# Open: http://localhost:8080
# Login: admin / <password from above>
```

---

## Day-2 to Day-5: Evidence Collection

### 2.1 Build the Bad Image (for SLO Rollback Test)

```bash
# Required for slo.sh test
export AR_HOST="us-central1-docker.pkg.dev"
export PROJECT_ID="$GCP_PROJECT_ID"

make build-bad AR_HOST=$AR_HOST PROJECT_ID=$PROJECT_ID

# Export the bad image reference
export AR_BAD_IMAGE="${AR_HOST}/${PROJECT_ID}/gitops-poc-apps/demo-app:v2-bad"
```

### 2.2 Run Traffic Generator (Terminal 1)

```bash
# Keep this running in a separate terminal throughout evidence collection
make traffic

# Or manually:
# kubectl --context gitops-prod -n demo port-forward svc/demo-app 8080:80 &
# python3 scripts/generate_traffic.py --url http://localhost:8080/api --rate 5 --duration 3600
```

### 2.3 Run Evidence Tests (Terminal 2)

```bash
# Run all evidence tests (n=2 per test, ~90 min total)
make evidence

# Or run single test:
# make evidence-test T=drift
# make evidence-test T=canary
# make evidence-test T=bluegreen
# make evidence-test T=mttd
# make evidence-test T=slo
# make evidence-test T=secrets
# make evidence-test T=scan
```

### 2.4 Review Evidence Results

```bash
# Find the latest results directory
ls -lt results/

# View summary
python3 scripts/summarize_evidence.py results/<latest-timestamp>

# Check individual CSV files
cat results/<latest-timestamp>/drift.csv
cat results/<latest-timestamp>/canary.csv
cat results/<latest-timestamp>/slo.csv
```

---

## Per-Session Teardown (Between Evidence Runs)

```bash
# Stop port-forwards
pkill -f "port-forward"

# Stop traffic generator (Ctrl+C)

# Clusters remain running for next session
```

---

## Day-6: Full Teardown (Before 2026-09-21)

### 6.1 Standard Teardown

```bash
# Destroy everything EXCEPT state bucket
make destroy
```

### 6.2 Full Teardown (Including State Bucket)

```bash
# Destroy everything INCLUDING state bucket
make destroy-full
```

### 6.3 Orphan Hunt Verification

```bash
# Verify all resources are gone
gcloud container clusters list --project=$GCP_PROJECT_ID
gcloud compute instances list --project=$GCP_PROJECT_ID
gcloud compute disks list --project=$GCP_PROJECT_ID --filter="labels.project=gke-gitops-poc"
gcloud compute forwarding-rules list --project=$GCP_PROJECT_ID
gcloud compute addresses list --project=$GCP_PROJECT_ID
gcloud compute routers list --project=$GCP_PROJECT_ID
gcloud pubsub topics list --project=$GCP_PROJECT_ID | grep budget
gcloud secrets list --project=$GCP_PROJECT_ID | grep gitops-poc
gcloud artifacts repositories list --project=$GCP_PROJECT_ID | grep gitops-poc
gcloud storage buckets list --project=$GCP_PROJECT_ID | grep tfstate
```

---

## Troubleshooting

### Issue: API Not Enabled/Effective

```bash
# Symptoms: Terraform apply fails with API not found
# Solution: Wait 90s and retry (deploy.sh handles this automatically)

# Manual fix:
sleep 90
terraform -chdir=terraform/1-baseline apply -auto-approve
```

### Issue: Dev Cluster Registration Hangs

```bash
# Symptoms: register_cluster.sh hangs at "waiting for cluster"
# Solution: Verify prod NAT IP is whitelisted on dev master

# Check:
gcloud container clusters describe gitops-poc-dev-in --region asia-south1 \
  --format='value(masterAuthorizedNetworksConfig)'

# Manual whitelist:
gcloud container clusters update gitops-poc-dev-in --region asia-south1 \
  --enable-master-authorized-networks \
  --master-authorized-networks "$(gcloud compute addresses describe gitops-poc-prod-nat-ip --region us-central1 --format='value(address)')/32"
```

### Issue: ArgoCD App Not Syncing

```bash
# Check app status
kubectl --context gitops-prod -n argocd get applications

# Force sync
argocd app sync <app-name> --auth-token <token>

# Or via kubectl:
kubectl --context gitops-prod -n argocd patch application <app-name> \
  --type merge -p '{"operation":{"sync":{}}}'
```

### Issue: Rollout Stuck in Progressing

```bash
# Check rollout status
kubectl --context gitops-prod -n demo argo rollouts get rollout demo-app

# Check pod status
kubectl --context gitops-prod -n demo get pods -l app=demo-app

# Check events
kubectl --context gitops-prod -n demo describe rollout demo-app
```

---

## Quick Reference Commands

```bash
# Set all required environment variables
export GCP_PROJECT_ID="your-project-id"
export BILLING_ACCOUNT_ID="XXXXXX-XXXXXX-XXXXXX"
export REPO_URL="https://github.com/YOUR-USER/gke-gitops-platform.git"
export AR_HOST="us-central1-docker.pkg.dev"
export AR_BAD_IMAGE="${AR_HOST}/${GCP_PROJECT_ID}/gitops-poc-apps/demo-app:v2-bad"

# Deploy
make apply

# Evidence
make build-bad AR_HOST=$AR_HOST PROJECT_ID=$GCP_PROJECT_ID
make traffic  # Terminal 1
make evidence # Terminal 2

# Teardown
make destroy

# Access
make ui  # Port-forward ArgoCD + Grafana
```

---

## Timeline Summary

| Day | Activity | Duration |
|-----|----------|----------|
| Day-0 | Prerequisites, quotas, tools | 1-2 hours (or days for quota approval) |
| Day-1 | Deployment | ~45 min |
| Day-2-5 | Evidence collection | ~90 min per session |
| Day-6 | Full teardown (BEFORE 2026-09-21) | ~30 min |

---

## Important Dates

- **Credit Expiry**: 2026-09-21 IST
- **Full Teardown Deadline**: 2026-09-20 (day before expiry)
- **Zero-Cost Audit**: 2026-09-21 (verify billing shows $0)

See `docs/credit-expiry-teardown.md` for the hard-date checklist.