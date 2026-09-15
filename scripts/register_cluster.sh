#!/usr/bin/env bash
# register_cluster.sh — register the DEV cluster with prod's ArgoCD (bullet 1:
# ONE ArgoCD, TWO clusters). Idempotent.
#
# Uses the argocd CLI's built-in `argocd cluster add` (creates the cluster
# secret + RBAC on the target) and then captures the endpoint so the
# dev-apps.yaml destinations can be patched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${GCP_PROJECT_ID:?Set GCP_PROJECT_ID env var}"
PROD_CTX="${PROD_CTX:-gitops-prod}"
DEV_CTX="${DEV_CTX:-gitops-dev}"

log() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

command -v argocd >/dev/null || {
  echo "FATAL: argocd CLI missing — install: https://argo-cd.readthedocs.io (brew/scoop/krew)"
  exit 1
}

# ArgoCD server is ClusterIP-only: port-forward for CLI ops.
PORTFWD_PID=""
cleanup() { [[ -n "$PORTFWD_PID" ]] && kill "$PORTFWD_PID" 2>/dev/null || true; }
trap cleanup EXIT

log "port-forwarding ArgoCD (kubectl -n argocd port-forward svc/argocd-server 8080:80)"
kubectl --context "$PROD_CTX" -n argocd port-forward svc/argocd-server 8080:80 >/dev/null 2>&1 &
PORTFWD_PID=$!
sleep 5

ARGO_PWD="$(kubectl --context "$PROD_CTX" -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
argocd login localhost:8080 --username admin --password "$ARGO_PWD" --insecure

log "adding dev cluster to ArgoCD"
argocd cluster add "$DEV_CTX" --name gitops-dev --upsert --yes

log "registered clusters:"
argocd cluster list

# Print the dev server URL — deploy.sh patches dev-apps.yaml destinations.
DEV_ENDPOINT="$(kubectl --context "$DEV_CTX" config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
echo
echo "DEV cluster endpoint (paste into gitops/apps/dev-apps.yaml destinations):"
echo "  $DEV_ENDPOINT"
