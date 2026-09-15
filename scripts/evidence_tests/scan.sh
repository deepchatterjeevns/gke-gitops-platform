#!/usr/bin/env bash
# scan.sh — BEHAVIORAL evidence (bullet 6): standalone hardcoded-credentials
# scan of the whole repo (used by the GitHub Actions dry CI too).
# Args: $1 results dir, $2 run number
set -euo pipefail
RESULTS="$1"; RUN="$2"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CSV="$RESULTS/scan.csv"

[[ -f "$CSV" ]] || echo "run,scan_scope,hits,verdict" > "$CSV"

HITS="$(grep -rInE "(password|secret|api[_-]?key|token)[[:space:]]*[:=][[:space:]]*[\"'][A-Za-z0-9/+_-]{16,}" \
  "$ROOT_DIR/terraform" "$ROOT_DIR/gitops" "$ROOT_DIR/scripts" "$ROOT_DIR/build" 2>/dev/null \
  | grep -v ">>> INSERT" | grep -v "adminPassword" | wc -l || true)"

VERDICT="PASS"
[[ "$HITS" != "0" ]] && VERDICT="FAIL"
echo "$RUN,repo-wide,$HITS,$VERDICT" >> "$CSV"
echo "RESULT run=$RUN hardcoded-cred scan: $HITS hits ($VERDICT) -> $CSV"
[[ "$HITS" == "0" ]] || exit 2
