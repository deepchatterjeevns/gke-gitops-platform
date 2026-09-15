#!/usr/bin/env bash
# evidence.sh — session driver: runs each evidence test N times (n>=2 per
# methodology), writing timestamped CSV/log rows into results/<run_id>/.
# Safety classification: all tests are BEHAVIORAL/OBSERVATIONAL — none are
# cluster-destructive; the harness never deletes clusters (only kubectl
# scale/annotate + one Rollout abort, all self-healed by ArgoCD).
#
# Usage: ./scripts/evidence.sh [test ...]   (default: all)
#   tests: drift canary bluegreen mttd slo secrets scan
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS="$ROOT/results/$RUN_ID"
N="${EVIDENCE_N:-2}" # n>=2 per methodology
mkdir -p "$RESULTS"

log() { printf '\n\033[1;33m== %s ==\033[0m\n' "$*"; }

run_test() {
  local test_name="$1"
  for i in $(seq 1 "$N"); do
    log "evidence: $test_name (run $i/$N)"
    "$ROOT/scripts/evidence_tests/${test_name}.sh" "$RESULTS" "$i" 2>&1 | tee -a "$RESULTS/${test_name}_run${i}.log"
    sleep 30 # spacing: let ArgoCD self-heal / metrics windows pass
  done
}

TESTS="${*:-drift canary bluegreen mttd slo secrets scan}"
for t in $TESTS; do
  [[ -f "$ROOT/scripts/evidence_tests/${t}.sh" ]] || { echo "unknown test: $t"; exit 1; }
done

echo "run_id: $RUN_ID" > "$RESULTS/meta.txt"
echo "started: $(date -u +%FT%TZ)" >> "$RESULTS/meta.txt"
echo "n_per_test: $N" >> "$RESULTS/meta.txt"

for t in $TESTS; do
  run_test "$t"
done

echo "finished: $(date -u +%FT%TZ)" >> "$RESULTS/meta.txt"
log "ALL EVIDENCE DONE — $RESULTS"
ls -la "$RESULTS"
