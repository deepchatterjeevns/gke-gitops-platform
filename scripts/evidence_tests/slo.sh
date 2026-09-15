#!/usr/bin/env bash
# slo.sh — PERFORMANCE evidence (bullets 4, 5): SLO series + budget burn +
# AUTOMATED ROLLBACK trigger test (v2-bad image => AnalysisTemplate failure
# => Rollouts abort => stable v1 serving again).
# Args: $1 results dir, $2 run number
set -euo pipefail
RESULTS="$1"; RUN="$2"
CTX="${CTX:-gitops-prod}"
CSV="$RESULTS/slo.csv"
PROM_PORT="9090"

[[ -f "$CSV" ]] || echo "run,pre_fault_burn_rate,burn_alert_fired,budget_remaining_ratio,rollback_to,rollback_total_s" > "$CSV"

kubectl --context "$CTX" -n monitoring port-forward svc/kube-prometheus-stack-prometheus ${PROM_PORT}:${PROM_PORT} >/dev/null 2>&1 &
PROM_PID=$!
trap 'kill $PROM_PID 2>/dev/null || true' EXIT
sleep 5
PROM="http://localhost:9090"

query() { curl -sG "$PROM/api/v1/query" --data-urlencode "query=$1" | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else 'none')"; }

# 1. baseline: burn rate + budget remaining (bullet-5 tracking series)
PRE_BURN="$(query 'demo:burn_rate5m')"
BUDGET="$(query 'demo:error_budget_remaining:ratio')"
echo "baseline burn_rate5m=$PRE_BURN budget_remaining=$BUDGET"

# 2. rollback trigger test: deploy v2-bad (100% fault baked into image)
T0="$(date -u +%s)"
kubectl argo rollouts --context "$CTX" -n demo set image demo-app "demo-app=${AR_BAD_IMAGE:?export AR_BAD_IMAGE=.../demo-app:v2-bad}"

# 3. expect: analysis gates fail => abort => rollback to stable v1
FINAL=""; ROLLBACK_S="TIMEOUT"
for i in $(seq 1 90); do
  sleep 10
  PHASE="$(kubectl --context "$CTX" -n demo get rollout demo-app -o jsonpath='{.status.phase}')"
  NOW="$(( $(date -u +%s) - T0 ))"
  if [[ -n "$FINAL" && "$PHASE" == "Healthy" ]]; then
    ROLLBACK_S="$NOW"
    break
  fi
  # Degraded = analysis failed & aborting — record first observation
  [[ -z "$FINAL" && "$PHASE" == "Degraded" ]] && FINAL="Degraded@${NOW}s" && echo "abort detected at t=${NOW}s"
done

IMAGE_AFTER="$(kubectl --context "$CTX" -n demo get rollout demo-app -o jsonpath='{.spec.template.spec.containers[0].image}')"
BURN_ALERT="$(query 'ALERTS{alertname=~"DemoSLOBurnRate.*",alertstate="firing"}')"

echo "$RUN,$PRE_BURN,$([[ "$BURN_ALERT" != "none" ]] && echo fired || echo not-yet),$BUDGET,$IMAGE_AFTER,${ROLLBACK_S}" >> "$CSV"
kubectl argo rollouts --context "$CTX" -n demo describe rollout demo-app > "$RESULTS/slo_run${RUN}_describe.log" 2>&1 || true
echo "RESULT run=$RUN rollback_total=${ROLLBACK_S}s final_image=$IMAGE_AFTER -> $CSV"
[[ "$ROLLBACK_S" != "TIMEOUT" ]] || exit 2
