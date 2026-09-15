# results/

Timestamped evidence runs from `make evidence`.

Each run dir `results/<UTC-timestamp>/` contains:
- `meta.txt` — run id, started/finished, n-per-test
- `drift.csv`, `canary.csv`, `bluegreen.csv`, `mttd.csv`, `slo.csv`,
  `secrets.csv`, `scan.csv` — one row per run (n≥2 per methodology)
- `*_describe.log` — `kubectl argo rollouts describe` captures
- `evidence_summary.csv` — `scripts/summarize_evidence.py` output, with
  OVERALL verdict

Screenshots (ArgoCD tree, Grafana burn panels, rollout weight progress)
are manual — save to the blog assets, referenced from the article.

The README evidence table in the repo root maps each resume bullet → the
specific CSV/artifact that proves it. That mapping is the point of the POC.
