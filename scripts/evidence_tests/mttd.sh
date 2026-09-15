#!/usr/bin/env bash
# mttd.sh — OBSERVABILITY evidence (bullet 3): inject 100% faults via env
# override, measure fault-start -> Alertmanager alert FIRING. MTTD target:
# < 5 min (the AWS-era 25min-><5min claim re-proved).
# Faults injected by patching the canary/preview env via kubectl set env on
# the Rollout — ArgoCD will revert the env patch after (self-heal), which is
# EXACTLY the drift behavior we want post-test.
# Args: $1 results dir, $2 run number
set -euo pipefail
RESULTS="$1"; RUN="$2"
CTX="${CTX:-gitops-prod}"
CSV="$RESULTS/mttd.csv"

[[ -f "$CSV" ]] || echo "run,fault_start_utc,alert_name,alert_fired_utc,mttd_s,severity" > "$CSV"

# 1. capture Alertmanager start time; inject FAULT_PERCENT=100 on all pods
FAULT_START="$(date -u +%FT%TZ)"
kubectl --context "$CTX" -n demo set env rollout/demo-app FAULT_PERCENT=100
echo "fault injected at $FAULT_START"

# 2. poll Alertmanager API (port-forward) for DemoAppErrorRateHigh firing
AM_PORT="9093"
kubectl --context "$CTX" -n monitoring port-forward svc/kube-prometheus-stack-alertmanager ${AM_PORT}:${AM_PORT} >/dev/null 2>&1 &
AM_PID=$!
trap 'kill $AM_PID 2>/dev/null || true' EXIT
sleep 5

MTTD_S="TIMEOUT"
ALERT_UTC=""
for i in $(seq 1 60); do
  sleep 10
  ALERTS="$(curl -s "http://localhost:9093/api/v2/alerts" 2>/dev/null || echo '[]')"
  HIT="$(python3 - "$ALERTS" <<'PY'
import json, sys
alerts = json.loads(sys.argv[1])
for a in alerts:
    if a.get("labels", {}).get("alertname") == "DemoAppErrorRateHigh" \
       and a.get("status", {}).get("state") in ("firing",):
        print(a.get("activeAt", ""))
        break
PY
)"
  if [[ -n "$HIT" ]]; then
    ALERT_UTC="$HIT"
    MTTD_S="$(python3 -c "
from datetime import datetime
try:
    a=datetime.strptime('$FAULT_START'.replace('+00:00','').rstrip('Z'), '%Y-%m-%dT%H:%M:%S.%fZ')
except ValueError:
    a=datetime.strptime('$FAULT_START'[:19], '%Y-%m-%dT%H:%M:%S')
try:
    b=datetime.strptime('$ALERT_UTC'[:26], '%Y-%m-%dT%H:%M:%S.%fZ')
except ValueError:
    b=datetime.strptime('$ALERT_UTC'[:19], '%Y-%m-%dT%H:%M:%S')
print(int((b-a).total_seconds()))
")"
    break
  fi
done

# 3. remove fault: revert env to 0 — ArgoCD ALSO self-heals this (belt+braces)
kubectl --context "$CTX" -n demo set env rollout/demo-app FAULT_PERCENT=0

echo "$RUN,$FAULT_START,DemoAppErrorRateHigh,${ALERT_UTC:-never},${MTTD_S},critical" >> "$CSV"
echo "RESULT run=$RUN mttd=${MTTD_S}s -> $CSV"
[[ "$MTTD_S" != "TIMEOUT" ]] || exit 2
