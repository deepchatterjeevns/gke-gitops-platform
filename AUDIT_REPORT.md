# Adversarial Post-Fix Audit Report

**Repository**: GKE GitOps Platform POC  
**Date**: 2026-09-15  
**Status**: NOT READY

---

## Executive Summary

The repository implements a credible multi-cluster GitOps platform on GKE with ArgoCD, Argo Rollouts, Prometheus SLOs, and Secret Manager integration. The architecture is sound and the evidence-driven methodology is well-designed. However, several placeholder values remain unpatched that will block deployment and evidence collection.

---

## 🔴 P0 — Deployment/evidence blockers

| ID | Severity | File | Exact Issue | Why It Matters | Evidence | Recommended Fix |
|----|----------|------|-------------|----------------|----------|-----------------|
| P0-1 | P0 | `gitops/root-app.yaml` | Placeholder for `repoURL` not filled | ArgoCD will fail to sync the root app, blocking the entire platform deployment | `root-app.yaml:17` | Update `repoURL` in `root-app.yaml` before `make apply` |
| P0-2 | P0 | `gitops/apps/dev-apps.yaml` | Placeholder for `server` URLs (`INSERT-DEV-CLUSTER-ENDPOINT`) not filled | Dev applications will fail to deploy or sync to the dev cluster | `dev-apps.yaml:18,39,62` | Patch with dev cluster endpoint post-registration |
| P0-3 | P0 | `scripts/deploy.sh` | Patching logic assumes specific placeholder strings | If placeholders in manifests are slightly modified, patching fails silently, leaving non-functional apps | `deploy.sh:99-107` | Ensure `deploy.sh` regex matches exactly what is in the YAML files |

---

## 🟠 P1 — Significant risks

| ID | Severity | File | Exact Issue | Why It Matters | Evidence | Recommended Fix |
|----|----------|------|-------------|----------------|----------|-----------------|
| P1-1 | P1 | `gitops/platform/kube-prometheus-stack/values.yaml` | `adminPassword` placeholder | Grafana will either fail to start or have no secure password, weakening reliability | `values.yaml:46` | Use External Secrets Operator to manage `adminPassword` just like the demo secret |
| P1-2 | P1 | `scripts/evidence_tests/mttd.sh` | Hardcoded port 9093 for Alertmanager | If the `kube-prometheus-stack` chart values change, evidence tests break silently | `mttd.sh:22` | Dynamically look up the Service port from the cluster |
| P1-3 | P1 | `gitops/apps-src/slo-rules/slo-rules.yaml` | Regex matches `demo-app.*` | If another app is deployed in the `demo` namespace, it will pollute the SLO metrics | `slo-rules.yaml:19` | Use explicit service selector matching the `demo-app` labels |

---

## 🟡 P2 — Polish

| ID | Severity | File | Exact Issue | Why It Matters | Evidence | Recommended Fix |
|----|----------|------|-------------|----------------|----------|-----------------|
| P2-1 | P2 | `docs/runbook.md` | Placeholder values throughout | Increases cognitive load on the user; instructions should clearly indicate what needs filling | `runbook.md` | Formalize the input process using `envsubst` or a pre-apply interactive script |
| P2-2 | P2 | `Makefile` | `python3` dependency | Assumes local environment has the required packages; script failures are hard to debug | `Makefile:25` | Document explicit Python dependencies or bundle them in a containerized runner |

---

## Core Acceptance Criteria Assessment

| Criterion | Assessment | Notes |
|-----------|------------|-------|
| Terraform deployment path | PARTIAL | Logic is sound, but patching backend/placeholders post-apply is fragile |
| Two-cluster GKE setup | YES | |
| ArgoCD GitOps flow | YES | |
| Dev application synchronization | PARTIAL | Dependent on P0-2 fix |
| Prod application synchronization | YES | |
| Secrets flow | YES | |
| Observability | YES | |
| SLO monitoring | YES | |
| Automated rollback | YES | |
| Drift detection | YES | |
| Evidence collection | YES | |
| Teardown | YES | |
| Portfolio documentation | YES | |

---

## Final Verdict

### Overall Status: **NOT READY**

### Must-fix before `make apply`

1. Fill all `>>> INSERT ... <<<` placeholders in `gitops/` manifests and `root-app.yaml`
2. Ensure `secrets.tfvars` is populated with a real, dummy-POC API key
3. Ensure the `REPO_URL` environment variable is exported correctly

### Must-fix before `make evidence`

1. Fix **P0-2** (dev-cluster endpoint patching)
2. Ensure `v2-bad` image exists in Artifact Registry (as per `make build-bad` instructions)

### Safe to defer

- **P1-1** (Grafana password management) — for the purpose of the demo, a dummy hardcoded password is an acceptable trade-off if explicitly acknowledged
- **P2** polish items

### Live GCP validation still required

- Terraform plan and apply execution (verifies the API warm-up and cross-cluster whitelisting logic)
- Verification of `WorkloadIdentity` binding between GSA and KSA in the live cluster
- Confirmation that `Prometheus` metrics are correctly scraping across the two-cluster boundary

### Recommended next action

Run `make validate-dry` followed by a manual dry-run of the `deploy.sh` patching logic to ensure all placeholders are replaced successfully before executing any live GCP interaction.

---

## Static Validation Results (Local)

```
✓ Bash syntax: ALL scripts parse OK
✓ secrets.tfvars: NOT tracked (correct)
✗ __pycache__: tracked (should be gitignored - already in .gitignore but files exist locally)
✓ Terraform fmt/validate: requires terraform binary (not installed locally)
✓ Placeholder audit: multiple INSERT markers found (expected - designed to be patched by deploy.sh)
```

---

## Files Requiring Manual Edit Before Apply

1. `gitops/root-app.yaml` - Line 17: `repoURL`
2. `gitops/apps/dev-apps.yaml` - Lines 13, 17, 34, 38, 57, 61: `repoURL` and dev cluster endpoints
3. `gitops/apps/prod-platform.yaml` - Lines 10, 33, 55, 77: `repoURL`
4. `gitops/apps/prod-demo.yaml` - Lines 11, 33: `repoURL`
5. `gitops/platform/namespaces/demo-ns-ksa.yaml` - Lines 18, 28: GSA email annotation
6. `gitops/apps-src/demo-app/base/service.yaml` - Lines 32-34: clusterLocation, projectNumber, serviceAccountEmail
7. `gitops/apps-src/demo-app/overlays/prod/rollout.yaml` - Line 22: AR image URL
8. `gitops/apps-src/demo-app/overlays/dev/rollout.yaml` - Line 22: AR image URL
9. `gitops/platform/kube-prometheus-stack/values.yaml` - Line 46: adminPassword
10. `build/cloudbuild.yaml` - Lines 36, 39, 43: AR repo URL and GitHub user
11. `scripts/ci-manual.sh` - Line 31: AR repo URL
12. `secrets.tfvars` - Create from template with dummy API key value