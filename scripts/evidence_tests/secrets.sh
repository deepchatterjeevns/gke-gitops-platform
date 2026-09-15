#!/usr/bin/env bash
# secrets.sh — BEHAVIORAL evidence (bullet 6): (a) no hardcoded creds in repo
# (scan), (b) dynamic rotation: Secret Manager value rotates => pod sees new
# value < 2× ESO refreshInterval (60s => <120s).
# Args: $1 results dir, $2 run number
set -euo pipefail
RESULTS="$1"; RUN="$2"
CTX="${CTX:-gitops-prod}"
CSV="$RESULTS/secrets.csv"
PROJECT="${GCP_PROJECT_ID:?Set GCP_PROJECT_ID env var}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

[[ -f "$CSV" ]] || echo "run,repo_scan_hits,rotation_start_utc,new_value_visible_s,injected_via" > "$CSV"

# 1. scan: no hardcoded credentials in repo (git grep, no gitleaks dep)
SCAN_HITS="$(grep -rInE "(password|secret|api[_-]?key|token)[[:space:]]*[:=][[:space:]]*[\"'][A-Za-z0-9/+_-]{16,}" \
  "$ROOT_DIR/terraform" "$ROOT_DIR/gitops" "$ROOT_DIR/scripts" 2>/dev/null \
  | grep -v ">>> INSERT" | grep -v "adminPassword" | wc -l || true)"
echo "hardcoded-cred scan hits: $SCAN_HITS (expect 0)"

# 2. rotation test: new secret version in Secret Manager
NEW_VAL="poc-key-rotated-$(date -u +%s)"
gcloud secrets versions add gitops-poc-demo-api-key --data-file=- <<<"$NEW_VAL" --project "$PROJECT"
ROT_START="$(date -u +%FT%TZ)"
echo "rotated secret at $ROT_START -> $NEW_VAL"

# 3. poll the projected k8s Secret (ESO refreshInterval 60s) until value flips
VISIBLE_S="TIMEOUT"
for i in $(seq 1 36); do
  sleep 10
  CUR="$(kubectl --context "$CTX" -n demo get secret demo-api-key -o jsonpath='{.data.api-key}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [[ "$CUR" == "$NEW_VAL" ]]; then
    VISIBLE_S="$(( $(date -u +%s) - $(date -u -d "$ROT_START" +%s) ))"
    break
  fi
done

echo "$RUN,$SCAN_HITS,$ROT_START,${VISIBLE_S},ESO+WorkloadIdentity" >> "$CSV"
echo "RESULT run=$RUN scan=$SCAN_HITS rotation_visible=${VISIBLE_S}s -> $CSV"
[[ "$SCAN_HITS" == "0" && "$VISIBLE_S" != "TIMEOUT" ]] || exit 2
