# GKE GitOps Platform — multi-cluster ArgoCD, progressive delivery, SLOs, Secret Manager

![K8s](https://img.shields.io/badge/kubernetes-1.31-326CE5?logo=kubernetes&logoColor=white)
![ArgoCD](https://img.shields.io/badge/ArgoCD-2.13-EF7B4D?logo=argo&logoColor=white)
![Rollouts](https://img.shields.io/badge/Argo--Rollouts-1.8-EF7B4D)
![GKE](https://img.shields.io/badge/GKE-Standard-4285F4?logo=googlecloud&logoColor=white)
![Terraform](https://img.shields.io/badge/Terraform-1.9-7B42BC?logo=terraform&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-blue)

> **I ran this platform at scale on AWS — this is the from-scratch,
> GCP-native rebuild that proves the claims generalize to a second cloud.**
> v2/expansion of my planned GitOps-on-GKE POC. Every AWS-era resume bullet
> in scope maps to a measured, timestamped test in [results/](results).

**The build**: TWO regional GKE Standard clusters (us-central1 prod +
asia-south1 dev) — ONE ArgoCD on prod controlling both via app-of-apps;
Argo Rollouts canary (prod) + blue-green (dev) gated by Prometheus
AnalysisTemplates; kube-prometheus-stack with hand-rolled SLO recording
rules, MWMB burn alerts, error-budget tracking, automated rollback on
breach; Secret Manager + External Secrets Operator over Workload Identity
(zero hardcoded credentials); Cloud Build CI with commit-back-to-Git (the
GitOps seam); 4-layer Terraform with GCS remote state.

## Bullet → evidence table (the point of this repo)

| # | AWS-era claim | GCP re-proof | Evidence (results/) |
|---|---|---|---|
| 1 | ArgoCD across 4 multi-region clusters, 80+ services | One ArgoCD, 2 regional clusters in 2 regions, app-of-apps incl. cross-cluster dev apps | app inventory + `bluegreen.csv` (dev test runs through prod ArgoCD's registered cluster) |
| 2 | −25% deploy failures: drift detection + reconciliation; canary/B-G | ArgoCD selfHeal+prune on every app; Rollouts canary+blue-green with analysis gates | `drift.csv` (out-of-band scale, heal <5min), `canary.csv`, `bluegreen.csv` |
| 3 | MTTD 25min → <5min | FAULT_PERCENT injection → Alertmanager firing | `mttd.csv` (target <300s) |
| 4 | −30% Sev1/Sev2 via symptom-based alerts | MWMB burn-rate alerts (fast 14.4×, slow 6×) on the 99.9% SLO | `slo.csv` (burn_alert_fired) + SLO rules in [gitops/apps-src/slo-rules](gitops/apps-src/slo-rules) |
| 5 | SLOs + error budget + automated rollback on breach | Budget-remaining series + AnalysisTemplate error-ratio gate → Rollouts abort | `slo.csv` (rollback_total_s, budget_remaining_ratio) |
| 6 | Vault: centralized secrets, no hardcoded creds | Secret Manager + ESO + Workload Identity; rotation propagation measured | `secrets.csv` (scan=0, rotation <120s) + `scan.csv` |
| 9 | Custom Terraform modules, multi-env | 4 layers: GCS state → baseline → network → 2 clusters, one-command apply/destroy | [terraform/](terraform), deploy log |
| 10 | GitHub↔Jenkins webhooks CI | Cloud Build trigger (GitHub App) OR `ci-manual.sh` mirror — build → AR → commit image tag → ArgoCD sync | CI run log |

**Out of scope, deliberately** (see [docs/methodology.md](docs/methodology.md)):
Backstage IDP (bullet 7), migration cost claim (bullet 8), Cloud DNS/Global
LB/MIG parity (bullet 11) — flagged for follow-up POCs.

## Quickstart

```bash
# day-0 (runbook §0): billing project, quotas (us-central1 + asia-south1),
#   cp secrets.tfvars.template secrets.tfvars, export GCP_PROJECT_ID + REPO_URL
make apply        # ~45 min: 2 regional clusters + ArgoCD + both apps trees
make traffic      # terminal 1 (keep running)
make evidence     # terminal 2: all tests n=2, ~90 min, then auto-summary
```

**Deadline**: GCP credits expire **2026-09-21** — teardown is calendar-driven:
[docs/credit-expiry-teardown.md](docs/credit-expiry-teardown.md). Spend
ceiling = the credit balance ($480 budget guardrail as code, ₹40,000 ≈
$0.55–0.60/hr concurrent burn ≈ ₹1,100/day — sized for fidelity, not
minimum-viable).

## Layout

```
code/
├── terraform/            # 0-gcs-backend → 1-baseline → 2-network → 3-clusters
├── gitops/               # ArgoCD's Git tree (app-of-apps):
│   ├── root-app.yaml     #   root application
│   ├── apps/             #   child Applications (prod-*.yaml, dev-apps.yaml)
│   ├── platform/         #   namespaces+KSA, argo-rollouts, kps values, ESO
│   ├── apps-src/         #   demo-app (base/prod-canary/dev-bluegreen), slo-rules
│   └── bootstrap/        #   ArgoCD helm values (pre-Git bootstrap)
├── sample-app/           # Flask fault-injection surface (/metrics, FAULT_PERCENT)
├── build/                # cloudbuild.yaml (GitHub App trigger — bullet 10)
├── scripts/              # deploy, register_cluster, ci-manual, teardown,
│   │                     #   evidence.sh + evidence_tests/ (drift/canary/...)
│   └── generate_traffic.py, summarize_evidence.py
├── results/              # timestamped CSV/log evidence (committed — no secrets)
├── docs/                 # architecture, methodology, runbook,
│                         # credit-expiry-teardown (HARD DATE 2026-09-21)
└── .github/workflows/    # DRY-ONLY CI: validate/render/parse/cred-scan — no cloud
```

## Honest-limitation notes

- 2 clusters ≠ 4, 1 demo service ≠ 80+ — the POC proves the MECHANISM
  (multi-cluster control, drift-reconcile, gated rollouts, burn alerts,
  budget tracking, secret rotation), not the census. Full list in
  [docs/methodology.md](docs/methodology.md) — the article keeps the same
  honesty.
- Canary traffic routing is replica/Service-weight (no LB traffic split —
  bullet 11 explicitly deferred). Analysis gates are real Prometheus queries.
- ArgoCD itself is single-replica; its HA was never the claim.

## License

MIT — see [LICENSE](LICENSE).
