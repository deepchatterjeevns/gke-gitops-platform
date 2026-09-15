# Runbook — GKE GitOps Platform POC

**Deadline-driven build: GCP credits (~INR 40,000 ≈ $480) expire
2026-09-21.** Two teardown regimes exist — per-session (below) and the
HARD-DATE credit-expiry teardown (its own doc:
[credit-expiry-teardown.md](credit-expiry-teardown.md)). Missing the second
one means real-card billing. Read it now, calendar it.

## 0. Prerequisites (day-0 — front-load, these have lead time)

- **Billing**: dedicated GCP project with the credit-bearing billing account
  linked. `gcloud billing projects describe <PROJECT>`.
- **Org policy check**: `gcloud resource-manager org-policies list --project=<PROJECT>`
  (or folder-level): no `gcp.resourceLocations` block on us-central1 /
  asia-south1, no `iam.allowedPolicyMemberDomains` interference, no
  `constraints/iam.disableServiceAccountKeyCreation` issue (we create NO
  keys — WI only).
- **Quotas (day-0, both regions)**: regional GKE clusters need in-region
  CPU headroom. Check: `gcloud compute regions describe us-central1` and
  `asia-south1` — need ~8 vCPUs each with headroom. File quota bumps
  NOW (approval can take hours-days): Service Usage / Cloud KMS rarely
  matter here; COMPUTE cpus + CPUS_ALL_REGIONS are the ones that bite.
- **Tools**: terraform ≥1.9, gcloud, kubectl, helm, kustomize, argocd CLI,
  kubectl-argo-rollouts plugin, python3. `argocd` CLI:
  `curl -sSL -o /usr/local/bin/argocd https://.../argocd-linux-amd64` (see
  argoproj docs); rollouts plugin: `krew install kubectl-argo-rollouts`.
- **Secrets**: `cp secrets.tfvars.template secrets.tfvars`, fill the dummy
  value. NEVER commit it (.gitignore covers).
- **Repo**: this code pushed to YOUR GitHub repo (main branch). Export
  `REPO_URL=https://github.com/USER/gke-gitops-platform.git` before apply —
  deploy.sh patches the INSERT markers.
- **Cloud Build GitHub App** (bullet 10, optional day-5): connect the repo
  in Cloud Build → Triggers → GitHub App. Substitutions: `_AR_HOST`,
  `_GITHUB_TOKEN` (fine-grained PAT, contents:write, repo-only scope).

## 1. Credit math (Part C — maximization bounded by the ceiling)

Ceiling = **the full credit balance**: ~INR 40,000 ≈ **$480**. The
`google_billing_budget` is sized at $480 (50/80/100% → Pub/Sub topic
`gitops-poc-budget-alerts`, pull sub — check with
`gcloud pubsub subscriptions pull gitops-poc-budget-alerts-sub --auto-ack`).

**Concurrent both-clusters burn (sized for demo fidelity, Part C.3/C.4):**

| Item | Rate |
|---|---|
| 2 × regional GKE Standard fee | $0.20/hr × 2 = $0.40/hr |
| Prod nodes: platform e2-standard-2 ×3 zones min 1 (total floor 1) + spot ×1 | ≈ $0.10/hr |
| Dev nodes: e2-standard-2 ×1 | ≈ $0.035/hr |
| 2 × Cloud NAT (prod+dev) | ≈ $0.04/hr + data |
| AR + SM + GCS state + Pub/Sub | < $0.01/hr |
| **Total ≈** | **$0.55–0.60/hr ≈ $13–14/day ≈ ₹1,100/day** |

Full 6-day live window (D1 evening → D6 teardown) ≈ **$75–85 ≈ ₹6,300–7,100**
— ~6× headroom under the $480 ceiling. This is the intended posture: run
the full multi-region shape concurrently, sized for fidelity, torn down on
the calendar — NOT the old one-cloud-at-a-time minimal-burn rule.

Night rule (Part C.4): clusters may run overnight ONLY during the D2–D5
evidence calendar (an active run justifies it); any other night, either
tear down or scale node pools to total_min_count=1 (the floor is already
1 — do not run idle days).

## 2. Apply (day-1, ~45 min)

```bash
cd code
export GCP_PROJECT_ID=YOUR_PROJECT
export REPO_URL=https://github.com/USER/gke-gitops-platform.git
make apply
# scripts/deploy.sh: layer0 GCS → 1 baseline → 2 network → 3 clusters (2× regional,
#   25–35 min) → kubeconfigs → dev master whitelist → ArgoCD → INSERT patch →
#   register dev cluster → root app
```

Expected first-apply wobbles (both scripted-retried):
- "API not enabled/effective" → the time_sleep + retry in deploy.sh
- dev master whitelist step may need rerun (idempotent gcloud update)
- ArgoCD login for register_cluster.sh uses the initial admin secret

After: `kubectl --context gitops-prod -n argocd get applications` — all
Healthy within 5–8 min. dev-apps.yaml destinations need the printed
endpoint pasted in (register_cluster.sh prints it) if it changed.

## 3. Evidence sessions (D2–D5)

```bash
make traffic        # terminal 1 — keep running for mttd/slo
make evidence       # terminal 2 — all tests, n=2, ~90 min
# or single: make evidence-test T=drift
python3 scripts/summarize_evidence.py results/<latest>
```

Order matters: `scan` and `secrets` are independent; `canary` before `slo`
(so a fresh v2 baseline exists); `mttd` needs traffic flowing. The driver
runs them in a sane default order; single-test mode is for debugging.

v2-bad image build (needed by slo.sh — uses Dockerfile's FAULT build-arg):
```bash
make build-bad AR_HOST=us-central1-docker.pkg.dev PROJECT_ID=$GCP_PROJECT_ID
export AR_BAD_IMAGE=us-central1-docker.pkg.dev/$GCP_PROJECT_ID/gitops-poc-apps/demo-app:v2-bad
```
This bakes `FAULT_PERCENT=100` into the image at build time (deterministic
100% 5xx). The SLO test then sets this image via `kubectl argo rollouts set
image` — the AnalysisTemplate detects the error ratio and aborts.

## 4. Per-session teardown (routine)

Clusters STAY UP across D1–D5 sessions (the credit posture above). Per
SESSION teardown = stop port-forwards, stop traffic generator, confirm no
rogue kubectl sessions. Full teardown is D6 (or whenever a multi-day gap
appears in the calendar):

```bash
make destroy     # ArgoCD apps → TF 3 → 2 → 1 → orphan hunt
```

### Orphan-hunt checklist (every full teardown)

- [ ] `gcloud container clusters list` — empty
- [ ] `gcloud compute instances list` — empty
- [ ] `gcloud compute disks list --filter="labels.project=gke-gitops-poc"` — empty
- [ ] `gcloud compute forwarding-rules list` + `addresses list` — empty (stack creates NO LBs — any hit is foreign or leftover NAT IP)
- [ ] `gcloud compute routers list` — empty (NAT gateways die with routers)
- [ ] `gcloud pubsub topics list | grep budget` — gone
- [ ] `gcloud secrets list | grep gitops-poc` — gone
- [ ] `gcloud artifacts repositories list | grep gitops-poc` — gone
- [ ] `gcloud iam service-accounts keys list` — empty (WI only, no keys by design)
- [ ] GCS state bucket — intentional survivor (pennies) UNTIL credit-expiry doc says otherwise
- [ ] Console Billing → Reports filtered to project — run-rate $0 except state-bucket pennies

## 5. Gotchas specific to this build

1. **API enablement order** — layer 1 enables ALL APIs first + 90s warm;
   layers 2–3 retry once on races. If a cluster apply fails on
   container.googleapis.com, it's warm-up, not permissions.
1b. **`master_authorized_cidr` defaults to `0.0.0.0/0`** — this allows any
   IP to reach the Kubernetes API public endpoint. **Deliberate POC
   tradeoff**: private nodes + short-lived clusters + no persistent
   workloads. For real use, restrict to your workstation IP (`curl
   ifconfig.me`/32). Set via `-var master_authorized_cidr=x.x.x.x/32` on
   the layer-3 apply or add to `secrets.tfvars`.
2. **deletion_protection** — false in TF (GKE default true hangs destroy).
3. **WI binding syntax** — `serviceAccount:PROJECT.svc.id.goeg[demo/demo-app]`
   typo class: the pool is `svc.id.goog`. KSA must exist (wave 0) before
   ESO pods start; ESO reconciles once the annotation resolves.
4. **Regional node counts** — autoscaling uses TOTAL counts (across 3
   zones); `min_node_count=1` per-zone means 3 nodes. We set totals
   deliberately: prod platform total_max 2, spot total 1→3.
5. **asia-south1** — ~1.2× us-central1 pricing; spot availability tighter;
   quota bump filed day-0 (see §0).
6. **ArgoCD vs Rollouts controller convergence** — evidence tests mutate
   out-of-band (set image/scale/env). ArgoCD selfHeal reverts WITHIN ~3 min;
   rollouts tests complete inside that window. If a test stalls in
   Progressing longer than 6 min, check `argocd app diff` — it's the two
   controllers converging, documented + benign for the test window.
7. **Labels** — lowercase+dashes only; budget filter + orphan hunt rely on
   `project=gke-gitops-poc` matching TF state exactly.
8. **Cross-cluster reachability** — prod ArgoCD → dev control plane goes
   over prod NAT's IP; deploy.sh whitelists it on dev master. If
   register_cluster.sh hangs at "waiting for cluster", this whitelist is
   the first suspect. Verify:
   `gcloud container clusters describe gitops-poc-dev-in --region asia-south1 --format='value(masterAuthorizedNetworksConfig)'`

## 6. Cloud Build trigger (bullet 10, day-5)

1. Cloud Build → Triggers → Connect repository (GitHub App) → select repo.
2. Create trigger "ci-gitops": event=push to main, config=
   `build/cloudbuild.yaml`, substitutions `_AR_HOST=us-central1-docker.pkg.dev`,
   `_GITHUB_TOKEN` (Secret Manager-backed secret, fine-grained PAT with
   contents:write on this repo only).
3. Test: push a README tweak → watch build → the commit-back lands in git
   → ArgoCD syncs → canary starts on prod.
4. No trigger? `./scripts/ci-manual.sh v2` is the same flow locally (still
   proves the seam; the article says which one ran).
