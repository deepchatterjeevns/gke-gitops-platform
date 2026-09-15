# Cluster registry for app-of-apps (bullet 1).
# app-of-apps pattern: each file here is a child Application of the root app.
# prod-*.yaml gets synced by the root app on the PROD cluster's ArgoCD;
# dev-*.yaml targets the dev cluster through the registered cluster secret.
# (Registered via scripts/register_cluster.sh + label, NOT by hand.)
#
# Dev-cluster Applications use the in-cluster destination of THAT cluster:
# ArgoCD creates them against the registered cluster context (see
# docs/architecture.md — the app-of-apps tree spans both clusters from
# ONE control plane, which is the bullet-1 claim).
