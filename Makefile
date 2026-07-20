# Makefile for the gitops-kubernetes-deployment reference implementation.
#
# Most targets work with either standalone `kustomize` or the built-in
# `kubectl kustomize` (auto-detected). ENV selects an overlay where relevant.
#
#   make help                      # list targets
#   make test                      # run the sample-api unit tests
#   make kustomize-build ENV=dev   # render one overlay
#   make build-all                 # render base + every overlay
#   make lint                      # render + schema-validate (kubeconform if present)
#   make argocd-diff ENV=staging   # git-vs-cluster drift for an app
#   make promote-dev TAG=dev-abc123
#   make promote-staging TAG=1.4.0
#   make promote-production TAG=1.4.0

SHELL := /usr/bin/env bash
IMAGE_NAME := ghcr.io/iarsingh/sample-api
APP_DIR := applications/sample-api
ENV ?= dev
TAG ?=

# Prefer standalone kustomize; fall back to `kubectl kustomize`.
KUSTOMIZE := $(shell command -v kustomize 2>/dev/null || echo "kubectl kustomize")

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | sort \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

.PHONY: test
test: ## Run the sample-api unit tests (pytest)
	pytest

.PHONY: kustomize-build
kustomize-build: ## Render a single overlay: make kustomize-build ENV=<dev|staging|production>
	$(KUSTOMIZE) $(APP_DIR)/overlays/$(ENV)

.PHONY: build-all
build-all: ## Render base + all overlays to confirm they build
	@set -e; for t in base overlays/dev overlays/staging overlays/production; do \
	  echo "== $(APP_DIR)/$$t =="; \
	  $(KUSTOMIZE) $(APP_DIR)/$$t > /dev/null && echo "   OK"; \
	done

.PHONY: lint
lint: ## Render every overlay and schema-validate (kubeconform if installed)
	@set -e; \
	if command -v kubeconform >/dev/null 2>&1; then \
	  for t in base overlays/dev overlays/staging overlays/production; do \
	    echo "== $(APP_DIR)/$$t =="; \
	    $(KUSTOMIZE) $(APP_DIR)/$$t | kubeconform -strict -ignore-missing-schemas -summary; \
	  done; \
	else \
	  echo "kubeconform not found — falling back to build-only validation"; \
	  $(MAKE) build-all; \
	fi

.PHONY: yaml-validate
yaml-validate: ## Parse-check all Argo CD + policy YAML with yq
	@set -e; for f in $$(find argocd policies -name '*.yaml'); do \
	  yq eval 'true' "$$f" > /dev/null && echo "OK  $$f"; \
	done

.PHONY: argocd-diff
argocd-diff: ## Show git-vs-cluster drift for an app: make argocd-diff ENV=<env>
	scripts/drift-check.sh $(ENV)

.PHONY: promote-dev
promote-dev: guard-TAG ## Promote an image tag to dev (commits directly): make promote-dev TAG=<tag>
	scripts/promote-image.sh dev $(TAG) --direct

.PHONY: promote-staging
promote-staging: guard-TAG ## Open a promotion PR for staging: make promote-staging TAG=<tag>
	scripts/promote-image.sh staging $(TAG) --pr

.PHONY: promote-production
promote-production: guard-TAG ## Open a promotion PR for production: make promote-production TAG=<tag>
	scripts/promote-image.sh production $(TAG) --pr

.PHONY: rollback
rollback: ## Roll a Rollout back to its previous revision: make rollback ENV=<env>
	scripts/rollback.sh $(ENV)

.PHONY: docker-build
docker-build: ## Build the sample-api container image locally
	docker build -t $(IMAGE_NAME):local .

.PHONY: compose-up
compose-up: ## Run the sample-api locally via docker compose
	docker compose up --build

.PHONY: guard-TAG
guard-TAG:
	@if [ -z "$(TAG)" ]; then echo "error: TAG is required (e.g. make $(MAKECMDGOALS) TAG=1.4.0)"; exit 1; fi
