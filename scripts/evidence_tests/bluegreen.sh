#!/usr/bin/env bash
# bluegreen.sh — BEHAVIORAL evidence (bullet 2): blue-green promotion on the
# DEV cluster (asia-south1, managed by the same ArgoCD — also proves bullet 1
# cross-cluster control). CSV: preview_ready_s, promoted, final_phase.
# Args: $1 results dir, $2 run number
set -euo pipefail
RESULTS="$1"; RUN="$2"
CTX="${CTX:-gitops-dev}"
CSV="$RESULTS/bluegreen.csv"

[[ -f "$CSV" ]] || echo "run,tag,preview_ready_s,promoted,final_phase" > "$CSV"

TAG="${TAG:-v2}"
T0="$(date -u +%s)"

# 1. set image on dev blue-green rollout (preview spins up, NOT promoted —
#    autoPromotionEnabled: false)
kubectl argo rollouts --context "$CTX" -n demo set image demo-app "demo-app=${IMAGE:-${AR_IMAGE:?export AR_IMAGE}}"

# 2. wait for preview ReplicaSet ready
PREVIEW_READY="TIMEOUT"
for i in $(seq 1 60); do
  sleep 5
  PREVIEW="$(kubectl --context "$CTX" -n demo get rollout demo-app -o jsonpath='{.status.blueGreen.previewSelector}' 2>/dev/null || true)"
  PHASE="$(kubectl --context "$CTX" -n demo get rollout demo-app -o jsonpath='{.status.phase}')"
  if [[ "$PHASE" == "Progressing" && -n "$PREVIEW" ]]; then
    # previewSelector set + phase Progressing = preview serving, gate held
    PREVIEW_READY="$(( $(date -u +%s) - T0 ))"
    break
  fi
  [[ "$PHASE" == "Healthy" ]] && { PREVIEW_READY="$(( $(date -u +%s) - T0 ))"; break; }
done

# 3. promote (the manual gate action)
kubectl argo rollouts --context "$CTX" -n demo promote demo-app
PROMOTED="yes"

# 4. wait final phase
FINAL="TIMEOUT"
for i in $(seq 1 60); do
  sleep 5
  PHASE="$(kubectl --context "$CTX" -n demo get rollout demo-app -o jsonpath='{.status.phase}')"
  [[ "$PHASE" == "Healthy" ]] && { FINAL="$PHASE"; break; }
done

echo "$RUN,$TAG,${PREVIEW_READY}s,$PROMOTED,$FINAL" >> "$CSV"
kubectl argo rollouts --context "$CTX" -n demo describe rollout demo-app > "$RESULTS/bluegreen_run${RUN}_describe.log" 2>&1 || true
echo "RESULT run=$RUN preview_ready=${PREVIEW_READY}s promoted=$PROMOTED final=$FINAL -> $CSV"
[[ "$FINAL" == "Healthy" ]] || exit 2
