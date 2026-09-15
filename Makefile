# GKE GitOps Platform POC — v2/expansion of the GitOps-on-GKE plan
# Deadline-driven: credits expire 2026-09-21. See docs/credit-expiry-teardown.md.

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

NS := demo
RUN ?= latest

.PHONY: help
help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

.PHONY: validate-dry
validate-dry: ## $0 validation: terraform fmt/validate + kustomize render + script parse
	for layer in 0-gcs-backend 1-baseline 2-network 3-clusters; do \
	  terraform -chdir=terraform/$$layer init -backend=false >/dev/null && \
	  terraform -chdir=terraform/$$layer validate || exit 1; \
	done
	kubectl kustomize gitops/platform/namespaces >/dev/null && echo "kustomize: namespaces OK"
	kubectl kustomize gitops/apps-src/demo-app/overlays/prod >/dev/null && echo "kustomize: prod overlay OK"
	kubectl kustomize gitops/apps-src/demo-app/overlays/dev >/dev/null && echo "kustomize: dev overlay OK"
	kubectl kustomize gitops/apps-src/slo-rules >/dev/null && echo "kustomize: slo-rules OK"
	for s in scripts/*.sh scripts/evidence_tests/*.sh; do bash -n $$s || exit 1; done && echo "bash parse: OK"
	python3 -m py_compile scripts/generate_traffic.py scripts/summarize_evidence.py && echo "python parse: OK"

.PHONY: apply
apply: ## Day-1: layers 0-3 + ArgoCD + dev registration + root app
	./scripts/deploy.sh

.PHONY: ci-manual
ci-manual: ## Local CI mirror (bullet 10): build+push+git-commit image tag
	./scripts/ci-manual.sh $(TAG)

.PHONY: build-bad
build-bad: ## Build+push v2-bad image (FAULT_PERCENT=100 baked in) for SLO rollback evidence
	@echo "Building v2-bad (100% fault rate) for SLO rollback test"
	@test -n "$(AR_HOST)" || { echo "export AR_HOST=us-central1-docker.pkg.dev"; exit 1; }
	@test -n "$(PROJECT_ID)" || { echo "export PROJECT_ID=your-gcp-project"; exit 1; }
	docker build --build-arg APP_VERSION=v2-bad --build-arg FAULT=100 \
	  -t $(AR_HOST)/$(PROJECT_ID)/gitops-poc-apps/demo-app:v2-bad sample-app/
	docker push $(AR_HOST)/$(PROJECT_ID)/gitops-poc-apps/demo-app:v2-bad
	@echo "export AR_BAD_IMAGE=$(AR_HOST)/$(PROJECT_ID)/gitops-poc-apps/demo-app:v2-bad"
	@echo "Then run: make evidence-test T=slo"

.PHONY: traffic
traffic: ## 5 rps for 120s against prod demo-app (port-forwarded)
	kubectl --context gitops-prod -n $(NS) port-forward svc/demo-app 8080:80 &
	@sleep 3
	python3 scripts/generate_traffic.py --url http://localhost:8080/api --rate 5 --duration 120
	@kill %1 2>/dev/null || true

.PHONY: evidence
evidence: ## Full evidence session (n=2 per test) + summary
	./scripts/evidence.sh
	@LATEST=$$(ls -1dt results/*/ | head -1) && python3 scripts/summarize_evidence.py $$LATEST

.PHONY: evidence-test
evidence-test: ## Single test: make evidence-test T=drift (N=1)
	EVIDENCE_N=1 ./scripts/evidence.sh $$T

.PHONY: ui
ui: ## Port-forward ArgoCD + Grafana (prod)
	@echo "ArgoCD:  http://localhost:8080  (admin / kubectl -n argocd get secret argocd-initial-admin-secret)"
	@echo "Grafana: http://localhost:3000"
	kubectl --context gitops-prod -n argocd port-forward svc/argocd-server 8080:80 &
	kubectl --context gitops-prod -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80 &
	@wait

.PHONY: destroy
destroy: ## Reverse-order teardown + orphan hunt
	./scripts/teardown.sh

.PHONY: destroy-full
destroy-full: ## Teardown INCLUDING state bucket
	./scripts/teardown.sh --full
