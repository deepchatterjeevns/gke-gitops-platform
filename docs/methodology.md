# Evidence Methodology

Every in-scope resume bullet maps to a GCP/GKE artifact + a measured test
run ≥2 times. The point: proof the AWS-era accomplishments generalize to a
second cloud.

## Bullet → test map (the actual point of this exercise)

| Resume bullet | Claim | Test (n≥2) | Pass criteria | CSV |
|---|---|---|---|---|
| 1 — ArgoCD multi-cluster/multi-region | one ArgoCD controls 2 regional clusters, 2 regions | structural + dev-apps sync health | dev Applications Healthy from prod ArgoCD | app inventory (screenshot) |
| 2 — drift −25% deploy failures | automated drift detection + reconciliation | `drift.sh`: out-of-band scale 3→5 | ArgoCD detects + heals < 5 min, rollout Healthy after | drift.csv |
| 2 — canary/blue-green | progressive rollouts | `canary.sh` (prod weights), `bluegreen.sh` (dev promote) | ≥2 weight steps observed; final Healthy | canary.csv, bluegreen.csv |
| 3 — MTTD 25min→<5min | real-time scraping + tuned Alertmanager | `mttd.sh`: FAULT_PERCENT=100 → DemoAppErrorRateHigh firing | MTTD < 300s | mttd.csv |
| 4 — −30% Sev1/Sev2 | symptom-based alerts (burn rates) | `slo.sh` baseline + SLO rules | MWMB fast-burn alert fires during fault | slo.csv |
| 5 — SLOs + error budget + auto-rollback | 99.9% SLO, budget tracking, rollback on breach | `slo.sh`: v2-bad image → analysis fail → abort | rollback < 6 min, stable image serving, budget series present | slo.csv |
| 6 — Vault/no hardcoded creds | centralized secrets | `secrets.sh` + `scan.sh` | repo scan 0 hits; SM rotation visible in < 120s (2× ESO refresh) | secrets.csv, scan.csv |
| 9 — Terraform modules | repeatable multi-env | 4-layer build, GCS state | `make apply` from zero to green | deploy log |
| 10 — CI webhooks | GitHub→CI→deploy | Cloud Build trigger (or `ci-manual.sh` mirror) | image built → git commit → ArgoCD sync → rollout | CI log |

Out of scope (documented, not claimed): 7 (Backstage), 8 (migration cost
−20% — historical statistical claim), 11 (Cloud DNS/LB/MIG parity).

## How each test works (harness internals)

All tests live in `scripts/evidence_tests/`, driven by `scripts/evidence.sh`
(n per test, default 2), summarized by `scripts/summarize_evidence.py`
into `evidence_summary.csv` with an OVERALL PASS/FAIL. Results land in
`results/<UTC-timestamp>/` — commit the CSVs/logs; screenshots manual
(blog assets).

- **drift.sh** — `kubectl scale` out-of-band → poll rollout spec/status →
  CSV: detect_s, heal_s, phase before/after. ArgoCD selfHeal is the
  mechanism under test. Timeout 300s.
- **canary.sh** — `kubectl argo rollouts set image` → poll
  `.status.canary.weight` through steps → CSV: weights observed, final
  phase. Analysis gates (success-rate) run inline at 10/30/60%.
- **bluegreen.sh** — same on dev cluster, blue-green: preview readiness
  wait → `promote` → CSV: preview_ready_s, final phase. ALSO the bullet-1
  proof (this command goes through prod ArgoCD's registered-cluster path).
- **mttd.sh** — `kubectl set env FAULT_PERCENT=100` → port-forward
  Alertmanager :9093 → poll `/api/v2/alerts` for firing DemoAppErrorRateHigh
  → CSV: fault_start, alert_activeAt, mttd_s. Harness needs `make traffic`
  running in a second terminal (the counter must move for the ratio to trip).
- **slo.sh** — baseline Prometheus queries (burn_rate5m,
  error_budget_remaining:ratio) → set image v2-bad → poll phase Degraded→
  Healthy (abort+rollback) → CSV: burn fired?, rollback_total_s, image after.
  ALSO captures the budget-remaining series = bullet-5 tracking proof.
- **secrets.sh** — `gcloud secrets versions add` (rotation) → poll the ESO-
  projected k8s Secret until value flips → CSV: scan hits (0), visible_s.
- **scan.sh** — repo-wide hardcoded-credential grep (CI parity: same
  expression as the GitHub Actions job).

## Safety classification (Step 0.5)

- All tests: **behavioral/observational** — no cluster-destructive ops.
- ArgoCD self-heal reverts every mutation; Rollouts abort is by design.
- Cluster-destructive changes (terraform destroy) are gated behind the
  explicit `make destroy` + documented in the runbook — never run by the
  harness.
- Stateful risk: only the GCS state bucket (prevent_destroy) and Secret
  Manager value (POC dummy — disposable by design).

## Honest-limitation disclosures (write these INTO the article)

1. 2 clusters ≠ 4; dev region asia-south1 proves multi-region, not
   multi-active-region failover. No region-drain test.
2. 1 demo app ≠ 80+ services. The app-of-apps SHAPE scales to N apps; the
   evidence covers the mechanism, not the census.
3. Canary traffic routing is Service/replica-weight (no LB traffic split —
   bullet 11 deferred by scope decision). Weights are honest replica
   weights, and the analysis gate is real.
4. ArgoCD itself is single-replica (its own HA was never the claim; bullet 1
   is about clusters under management).
5. MTTD measures scrape→rule→Alertmanager (the pipeline); human-paging
   latency is out of scope (no PagerDuty in POC).
6. 28d-window budget math on a 3d-retention Prometheus: the series exist
   and are correct; the window is a POC-scale stand-in. Burn ALERTS use
   5m/1h/6h/3d windows — those are live and real.
