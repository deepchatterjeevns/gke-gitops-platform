# Architecture — GKE GitOps Platform POC

**What this is**: v2/expansion of the planned "GitOps CI/CD pipeline on GKE
using Cloud Build, Artifact Registry, and ArgoCD" POC. A from-scratch,
GCP-native rebuild of the AWS-era platform stack (EKS/ArgoCD/Vault/
Prometheus/SLOs/Terraform/Jenkins), re-proving the resume claims on a
second cloud with evidence.

## Components, data flow, and which resume bullet each re-proves

```
                        GIT — single source of truth
   GitHub: gke-gitops-platform
     │ repo layout: terraform/ (IaC) · gitops/ (app-of-apps tree) · build/ · scripts/
     │
     ├──push──▶ Cloud Build trigger (GitHub App)                    [bullet 10]
     │            └─ pack → AR image (${SHORT_SHA})                [bullet 10]
     │            └─ kustomize edit set image → git commit [skip ci]
     │                        │ (the GitOps seam — no direct kubectl deploy)
     ▼
us-central1 · gitops-prod-us (GKE Standard, REGIONAL — 3 zones)
     │
     ├─ ArgoCD (helm, ClusterIP) ◀── root app-of-apps              [bullets 1,2]
     │    ├─ prod-platform.yaml → namespaces/rollouts/kps/ESO       [bullets 1,2]
     │    ├─ prod-demo.yaml      → canary Rollout + SLO rules       [bullets 2,4,5]
     │    └─ dev-apps.yaml ──────┼──▶ registered cluster secret ──┐
     │                            │   (argocd cluster add)        │
     ▼                            ▼                               ▼
     ├─ Argo Rollouts: canary steps + AnalysisTemplate            asia-south1 · gitops-dev-in
     │    (Prometheus error-ratio gate ⇒ abort = auto-rollback)    (GKE Standard, REGIONAL)
     │                                                             │
     ├─ kube-prometheus-stack: Prom/AM/Grafana/node-exporter      ├─ argo-rollouts CRDs
     │    └─ SLO rules: SLI, burn rates, budget remaining         │   (managed BY prod ArgoCD —
     │       MWMB alerts (fast 14.4x / slow 6x)                   │   bullet 1's multi-cluster
     │                                                            │   control claim)
     ├─ ESO + Workload Identity ──▶ Secret Manager                └─ demo app: BLUE-GREEN
     │    (demo-api-key, 60s refresh)                                  rollout (bullet 2)
     │
     └─ demo-app (Flask): /metrics, FAULT_PERCENT env = injection surface
```

## Control flow (the GitOps contract)

1. **Deploy path** (bullet 10): git push → Cloud Build → image → AR →
   kustomize image tag commit → ArgoCD auto-sync (selfHeal+prune) → Rollouts
   canary (prod) / blue-green (dev). No human kubectl. The ONLY sanctioned
   out-of-band mutations are the evidence-harness tests (below), each
   designed to be reverted by ArgoCD self-heal.
2. **Drift posture** (bullet 2): every Application has automated+prune+
   selfHeal. Out-of-band mutation (scale, set env) is detected and
   reconciled — measured by `evidence_tests/drift.sh`.
3. **Rollback path** (bullet 5): AnalysisTemplate queries Prometheus at each
   canary step; error-ratio < 0.95 twice ⇒ Rollouts aborts ⇒ stable ReplicaSet
   keeps serving — measured by `evidence_tests/slo.sh`.

## Trust boundaries

| Boundary | Mechanism |
|---|---|
| Workstation → clusters | master authorized networks (public endpoint, CIDR-restricted) — documented tradeoff; private endpoint would break kubectl ergonomics for the POC window |
| ArgoCD → dev cluster | `argocd cluster add` cluster secret (RBAC: ArgoCD's SA on dev is cluster-admin-scoped by that command — POC-acceptable, noted honestly) |
| Dev control plane reachability | prod NAT IP whitelisted on dev master authorized networks (gotcha #8) |
| ESO → Secret Manager | Workload Identity: KSA `demo/external-secrets-eso` → GSA `gitops-poc-demo-app` with `roles/secretmanager.secretAccessor` ONLY |
| Cloud Build → AR/Git | Cloud Build SA: AR writer; git push via `x-token:${_GITHUB_TOKEN}` substitution (token set at trigger, never in repo) |
| Nodes → internet | NO external IPs; egress via Cloud NAT (AR/SM via Private Google Access — free) |

## State ownership

| State | Owner |
|---|---|
| Cloud infra (VPC, clusters, AR, SM, budget) | Terraform, GCS remote state, layered 0→3, `prevent_destroy` on the state bucket ONLY |
| Everything in both clusters | Git (app-of-apps tree) — ArgoCD enforces |
| Rollout promotion state | Rollouts CRs (derivable from Git) |
| The one sanctioned non-Git mutation | `kubectl argo rollouts set image` during evidence tests — self-healed by next ArgoCD sync after the CI commit lands |

## GKE mode + reasoning (Step 0.4 rule)

**Standard, both clusters** — node-exporter DaemonSet (hostPath /proc,/sys)
+ the full kube-prometheus-stack shape need node control; bullet-1 parity
is "ArgoCD across regional GKE Standard clusters" (the AWS shape). Cost
discipline: Spot secondary pool (stateless workloads) + total-count node
floors + ClusterIP-only services (zero LB spend — bullet 11's Global LB is
deliberately out of scope and nothing in this build creates one).

## Secrets decision (Step 0.3)

**Secret Manager + External Secrets Operator** over Vault-on-GKE:
- no extra in-cluster stateful component to keep alive/HA in a 7-day window
- GCP-native IAM (Workload Identity) + audit logging = the AWS-era Vault
  guarantees re-proved in cloud-idiomatic form (bullet 6: centralized
  secrets, no hardcoded creds, IAM-governed, rotatable — rotation measured)
- Vault's multi-cloud portability argument → the article's one stretch
  comparison note; not built.
