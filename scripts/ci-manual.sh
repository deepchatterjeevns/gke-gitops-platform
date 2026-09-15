#!/usr/bin/env bash
# ci-manual.sh — LOCAL mirror of the Cloud Build flow (bullet 10), for when
# the GitHub App trigger isn't wired yet (or for evidence capture without
# a second GitHub roundtrip). Same seam: commit kustomize image tag to Git.
#
# Usage: ./scripts/ci-manual.sh <tag>       e.g. ./scripts/ci-manual.sh v2
# Prereqs: docker, kustomize, git push rights to the repo.
set -euo pipefail

TAG="${1:?usage: ci-manual.sh <tag> (e.g. v2)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# >>> INSERT YOUR VALUES: fill these or export before running <<<
AR_HOST="${AR_HOST:-INSERT-AR-HOST.us-central1-docker.pkg.dev}"
PROJECT_ID="${PROJECT_ID:-INSERT-GCP-PROJECT-ID}"
AR_REPO="${AR_REPO:-gitops-poc-apps}"
IMAGE="${AR_HOST}/${PROJECT_ID}/${AR_REPO}/demo-app"

log() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

log "docker auth for AR"
gcloud auth configure-docker "$AR_HOST"

log "build + push ${IMAGE}:${TAG}"
docker build --build-arg APP_VERSION="${TAG}" -t "${IMAGE}:${TAG}" "$ROOT/sample-app"
docker push "${IMAGE}:${TAG}"

log "commit image tag into overlays (the GitOps seam)"
for overlay in prod dev; do
  (cd "$ROOT/gitops/apps-src/demo-app/overlays/$overlay" &&
    kustomize edit set image ">>> INSERT YOUR AR REPO URL <<<demo-app=${IMAGE}:${TAG}")
done
git add "$ROOT/gitops/apps-src/demo-app/overlays"
git commit -m "ci: demo-app ${TAG} [skip ci]" || echo "nothing to commit"
git push origin main

log "DONE — ArgoCD auto-sync now drives the rollout. Watch with:"
echo "  kubectl argo rollouts get rollout demo-app -n demo --watch (prod)"
echo "  kubectl --context <dev-context> argo rollouts get rollout demo-app -n demo --watch (dev)"
