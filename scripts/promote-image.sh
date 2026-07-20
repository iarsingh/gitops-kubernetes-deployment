#!/usr/bin/env bash
#
# promote-image.sh — bump the sample-api image tag in one environment overlay and
# open a promotion Pull Request (or, for dev, commit directly).
#
# This is the local equivalent of the .github/workflows/promote.yml job. It uses
# `kustomize edit set image` so the change is exactly what CI would produce.
#
# Usage:
#   scripts/promote-image.sh <env> <image-tag> [--pr|--direct]
#
# Examples:
#   scripts/promote-image.sh dev        dev-<sha>        --direct   # auto-apply to dev
#   scripts/promote-image.sh staging    1.4.0            --pr       # open PR for staging
#   scripts/promote-image.sh production 1.4.0            --pr       # open PR for production
#
# Requires: kustomize (or `kubectl kustomize`), git, and (for --pr) the GitHub CLI `gh`.
set -euo pipefail

IMAGE_NAME="ghcr.io/iarsingh/sample-api"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

ENV="${1:-}"
TAG="${2:-}"
MODE="${3:-}"
[[ -z "$ENV" || -z "$TAG" ]] && usage

case "$ENV" in
  dev|staging|production) ;;
  *) echo "error: env must be one of dev|staging|production" >&2; exit 1 ;;
esac

# Default mode: dev applies directly (mirrors auto-sync); others open a PR.
if [[ -z "$MODE" ]]; then
  if [[ "$ENV" == "dev" ]]; then MODE="--direct"; else MODE="--pr"; fi
fi

OVERLAY_DIR="$REPO_ROOT/applications/sample-api/overlays/$ENV"
[[ -d "$OVERLAY_DIR" ]] || { echo "error: overlay not found: $OVERLAY_DIR" >&2; exit 1; }

# Prefer standalone kustomize; fall back to `kubectl kustomize` for build checks.
if command -v kustomize >/dev/null 2>&1; then
  KUSTOMIZE=(kustomize)
else
  KUSTOMIZE=(kubectl kustomize)
fi

echo ">> Setting image ${IMAGE_NAME}:${TAG} in overlays/${ENV}"
if command -v kustomize >/dev/null 2>&1; then
  ( cd "$OVERLAY_DIR" && kustomize edit set image "${IMAGE_NAME}=${IMAGE_NAME}:${TAG}" )
else
  # No standalone kustomize: edit the newTag with yq as an equivalent operation.
  yq -i "(.images[] | select(.name == \"${IMAGE_NAME}\")).newTag = \"${TAG}\"" \
    "$OVERLAY_DIR/kustomization.yaml"
fi

echo ">> Validating the overlay still builds"
"${KUSTOMIZE[@]}" "$OVERLAY_DIR" >/dev/null
echo "   build OK"

BRANCH="promote/${ENV}-${TAG}"
COMMIT_MSG="promote(${ENV}): sample-api image -> ${TAG}"

if [[ "$MODE" == "--direct" ]]; then
  echo ">> Committing directly to the current branch (dev auto-promotion)"
  git -C "$REPO_ROOT" add "applications/sample-api/overlays/${ENV}/kustomization.yaml"
  git -C "$REPO_ROOT" commit -m "$COMMIT_MSG"
  echo "   committed. Push to main to let Argo CD auto-sync dev."
else
  echo ">> Opening a promotion PR for ${ENV}"
  git -C "$REPO_ROOT" checkout -b "$BRANCH"
  git -C "$REPO_ROOT" add "applications/sample-api/overlays/${ENV}/kustomization.yaml"
  git -C "$REPO_ROOT" commit -m "$COMMIT_MSG"
  git -C "$REPO_ROOT" push -u origin "$BRANCH"
  if command -v gh >/dev/null 2>&1; then
    gh pr create \
      --title "$COMMIT_MSG" \
      --body "Automated image promotion for **${ENV}** to \`${TAG}\`.

Merging this PR updates the git desired state. Argo CD then:
- **staging**: auto-syncs (within the business-hours window) and runs the canary.
- **production**: marks the app OutOfSync; an operator must run \`argocd app sync sample-api-production\` and then promote the blue-green Rollout.

Review the rendered diff with: \`make argocd-diff ENV=${ENV}\`." \
      --base main --head "$BRANCH"
  else
    echo "   gh CLI not found — branch pushed. Open the PR manually against main."
  fi
fi
