#!/usr/bin/env bash
# drift.sh — BEHAVIORAL evidence (bullets 1, 2): out-of-band mutation =>
# ArgoCD detects + reconciles. CSV row: drift_detected_s, healed_s.
# Args: $1 results dir, $2 run number
set -euo pipefail
RESULTS="$1"; RUN="$2"
CTX="${CTX:-gitops-prod}"
CSV="$RESULTS/drift.csv"

[[ -f "$CSV" ]] || echo "run,mutation,drift_detected_s,reconciled_s,healthy_before,healthy_after" > "$CSV"

T0="$(date -u +%s)"

# 1. verify baseline is healthy + synced
kubectl --context "$CTX" -n demo get rollout demo-app -o jsonpath='{.status.phase}' | grep -q Healthy \
  || { echo "baseline not healthy — abort"; exit 1; }

# capture expected replica count from the rollout spec (prod=3, dev=2)
EXPECTED_REPLICAS="$(kubectl --context "$CTX" -n demo get rollout demo-app -o jsonpath='{.spec.replicas}')"
MUTATED_REPLICAS=$(( EXPECTED_REPLICAS + 2 ))

# 2. out-of-band mutation: scale replicas via kubectl (bypassing Git)
kubectl --context "$CTX" -n demo scale rollout demo-app --replicas=$MUTATED_REPLICAS
echo "mutated: replicas ${EXPECTED_REPLICAS}->${MUTATED_REPLICAS} out-of-band"

# 3. poll for reconciliation (ArgoCD selfHeal should scale back to $EXPECTED_REPLICAS)
DETECT=""; HEAL=""
for i in $(seq 1 60); do
  sleep 5
  REPLICAS="$(kubectl --context "$CTX" -n demo get rollout demo-app -o jsonpath='{.spec.replicas}')"
  PHASE="$(kubectl --context "$CTX" -n demo get rollout demo-app -o jsonpath='{.status.phase}')"
  NOW="$(( $(date -u +%s) - T0 ))"
  if [[ -z "$DETECT" && "$REPLICAS" != "$MUTATED_REPLICAS" ]]; then
    DETECT="$NOW"
    echo "t=${NOW}s: drift detected (replicas=$REPLICAS — ArgoCD acting)"
  fi
  if [[ -n "$DETECT" && "$REPLICAS" == "$EXPECTED_REPLICAS" && "$PHASE" == "Healthy" ]]; then
    HEAL="$NOW"
    break
  fi
done

[[ -n "$HEAL" ]] || HEAL="TIMEOUT"
PHASE_AFTER="$(kubectl --context "$CTX" -n demo get rollout demo-app -o jsonpath='{.status.phase}')"
echo "$RUN,scale-replicas-${EXPECTED_REPLICAS}to${MUTATED_REPLICAS},${DETECT:-never},${HEAL},Healthy,$PHASE_AFTER" >> "$CSV"
echo "RESULT run=$RUN detect=${DETECT:-never}s heal=${HEAL}s -> $CSV"
[[ "$HEAL" != "TIMEOUT" ]] || exit 2
