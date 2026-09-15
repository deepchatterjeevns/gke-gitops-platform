# Credit-Expiry Teardown — HARD DATE 2026-09-21 IST

**This doc is NOT the routine teardown.** The per-session/POC teardown
(runbook §4) is operational hygiene. THIS one exists because the GCP
credits (~INR 40,000 ≈ $480) **expire 2026-09-21**, and anything still
running after that date bills a real card. Missing this checklist is the
one unacceptable failure mode of this exercise.

## The dates

| Milestone | Date | Action |
|---|---|---|
| Credit expiry | **2026-09-21** | everything below must be $0-run-rate by end of day IST |
| Deadline - 1 | **2026-09-20** | full `make destroy` + orphan hunt (day D6 of the plan) |
| Deadline day | **2026-09-21** | zero-cost audit only (§3) — no builds, no clusters |

## 1. Full teardown (2026-09-20, D6)

```bash
cd code
export GCP_PROJECT_ID=YOUR_PROJECT
make destroy-full    # clusters → network → baseline → INCLUDING state bucket
```

`destroy-full` differs from `make destroy`: it also removes the GCS state
bucket (the routine teardown's intentional survivor). After credits expire
there is no reason to keep state — the repo re-creates everything if the
POC is ever rebuilt (that's the bullet-9 claim: repeatable by design).

## 2. Orphan hunt — run the FULL checklist, then these

The runbook §4 checklist (clusters, instances, disks, forwarding rules,
addresses, routers, pubsub, secrets, AR, SA keys) PLUS credit-expiry-only
items:

- [ ] `gcloud storage buckets list` — the tfstate bucket GONE (destroy-full)
  - [ ] if destroy-full hit `prevent_destroy` (it does a state-rm first —
        verify the bucket object count: `gcloud storage ls gs://gke-gitops-tfstate-*`
        — must be 0 objects or no bucket)
- [ ] Cloud Build triggers deleted:
      `gcloud builds triggers list --filter='trigger_template.repo_name~gke-gitops'`
- [ ] GitHub App connection revoked (Cloud Build → GitHub App settings →
      disconnect) — not billable, but closes the trust boundary
- [ ] `_GITHUB_TOKEN` Secret Manager entry + the fine-grained PAT REVOKED
      on GitHub (it had contents:write)
- [ ] `gcloud billing accounts get-iam-policy` — no new grants to clean
- [ ] Budget/PubSub: dies with layer 1 destroy — confirm topics list empty

## 3. Zero-cost audit (2026-09-21 — the deadline day)

No live sessions. Verify only:

```bash
# every list must be EMPTY (or object-free)
gcloud container clusters list --project=$PROJECT
gcloud compute instances list --project=$PROJECT
gcloud compute disks list --project=$PROJECT
gcloud compute addresses list --project=$PROJECT
gcloud compute routers list --project=$PROJECT
gcloud pubsub topics list --project=$PROJECT
gcloud secrets list --project=$PROJECT
gcloud artifacts repositories list --project=$PROJECT
gcloud storage buckets list --project=$PROJECT
```

Then: Console → Billing → Reports → filter to project → set date range to
2026-09-14→today → **capture the final spend number** (the article's
footnote: "built for ₹X of GCP credit, expiring 2026-09-21").

Optional belt-and-braces (if the project exists solely for this POC):
shutdown the project itself —
`gcloud projects delete $PROJECT` (30-day soft-delete; nothing recovers
billable resources from soft-delete).

## 4. If something MUST survive past the deadline

Only acceptable survivor: NOTHING billable. If a demo recording session is
pushed late and needs one more day, the rule flips to: tear down
everything, re-apply on 2026-09-21 morning, capture, destroy by 21:00 IST
the SAME day — the audit (§3) then runs 2026-09-22 morning against a $0
baseline. This exception requires the §3 audit to be re-run with the same
empty-list expectations.

## 5. Failure escalation

If `make destroy-full` fails partway (finalizer hang is the classic):
1. `kubectl --context gitops-prod -n argocd delete application --all --force`
   then delete the argocd namespace manually.
2. Retry the failing terraform layer destroy; if a cluster still hangs:
   `gcloud container clusters delete <name> --region <r> --quiet` (bypasses
   TF state; then `terraform state rm` the leftover).
3. Any GCE resource refusing to die: check it isn't protected by a label
   mismatch (gotcha #7) — orphan hunt with `--filter="labels.project=gke-gitops-poc"`.
