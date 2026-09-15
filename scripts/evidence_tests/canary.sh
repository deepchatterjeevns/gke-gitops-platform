#!/usr/bin/env bash
# canary.sh — BEHAVIORAL evidence (bullet 2): tag flip v1->v2 drives a canary
# through weighted steps with Prometheus analysis gates. CSV row: per-step
# weights + final phase. Uses ci-manual.sh seam but WITHOUT git push (evidence
# mode: patch image in-cluster via kubectl argo rollouts, documented as the one
# sanctioned non-Git mutation — self-healed by re-sync afterward).
# Args: $1 results dir, $2 run number
set -euo pipefail
RESULTS="$1"; RUN="$2"
CTX="${CTX:-gitops-prod}"
CSV="$RESULTS/canary.csv"

[[ -f "$CSV" ]] || echo "run,tag,weights_observed,analysis_result,final_phase" > "$CSV"

TAG="${TAG:-v2}"
echo "promoting demo-app to $TAG via Rollouts (kubectl argo rollouts set image)"

# 1. confirm current stable
kubectl argo rollouts --context "$CTX" get rollout demo-app -n demo --no-color | head -5 || true

# 2. trigger: set image (the Rollouts-native promotion path; Git catches up
#    on next CI commit — this is the rollback-test surface too)
kubectl argo rollouts --context "$CTX" -n demo set image demo-app "demo-app=${IMAGE:-${AR_IMAGE:?export AR_IMAGE=docker.pkg.dev/.../demo-app:v2}}"

# 3. observe weight steps until Healthy/Degraded (max 10 min)
WEIGHTS=""
FINAL=""
for i in $(seq 1 120); do
  sleep 5
  DESIRED="$(kubectl --context "$CTX" -n demo get rollout demo-app -o jsonpath='{.status.canary.weight}' 2>/dev/null || true)"
  PHASE="$(kubectl --context "$CTX" -n demo get rollout demo-app -o jsonpath='{.status.phase}')"
  [[ -n "$DESIRED" && "$DESIRED" != "$LAST" ]] && WEIGHTS="$WEIGHTS $DESIRED" && LAST="$DESIRED"
  if [[ "$PHASE" == "Healthy" || "$PHASE" == "Degraded" ]]; then
    FINAL="$PHASE"; break
  fi
done
[[ -n "$FINAL" ]] || FINAL="TIMEOUT"

echo "$RUN,$TAG,${WEIGHTS:-none},gates-passed-or-aborted,$FINAL" >> "$CSV"
echo "RESULT run=$RUN weights=[${WEIGHTS:-none}] final=$FINAL -> $CSV"

# 4. capture the rollout describe as log artifact
kubectl argo rollouts --context "$CTX" -n demo describe rollout demo-app > "$RESULTS/canary_run${RUN}_describe.log" 2>&1 || true
[[ "$FINAL" == "Healthy" ]] || exit 2
