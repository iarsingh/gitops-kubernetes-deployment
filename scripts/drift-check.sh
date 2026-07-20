#!/usr/bin/env bash
#
# drift-check.sh — report drift between git (desired state) and the cluster
# (live state) for a sample-api environment, using `argocd app diff`.
#
# GitOps drift = anything changed in the cluster that git did not author (a manual
# `kubectl edit`, an operator mutating a field, a deleted resource). Argo CD is
# the source of truth for detecting it.
#
# Usage:
#   scripts/drift-check.sh <env> [--refresh]
#
# Examples:
#   scripts/drift-check.sh production           # show live-vs-git diff for prod
#   scripts/drift-check.sh staging --refresh    # force a fresh compare first
#
# Requires: the argocd CLI, logged in to your Argo CD server (`argocd login`).
#
# Exit codes: 0 = in sync (no drift), 1 = drift detected (argocd app diff returns
# non-zero when there is a difference), 2 = usage/tooling error.
set -euo pipefail

ENV="${1:-}"
REFRESH="${2:-}"

case "$ENV" in
  dev|staging|production) ;;
  *) echo "usage: $0 <dev|staging|production> [--refresh]" >&2; exit 2 ;;
esac

APP="sample-api-${ENV}"

if ! command -v argocd >/dev/null 2>&1; then
  echo "error: argocd CLI not found. install: https://argo-cd.readthedocs.io/en/stable/cli_installation/" >&2
  exit 2
fi

if [[ "$REFRESH" == "--refresh" ]]; then
  echo ">> Refreshing ${APP} to pull the latest git + live state"
  argocd app get "$APP" --refresh >/dev/null
fi

echo ">> Diffing git (desired) vs cluster (live) for ${APP}"
echo "   (no output below the line means the app is in sync / no drift)"
echo "----------------------------------------------------------------------"
# `argocd app diff` exits non-zero when a difference exists; capture that as the
# script's own drift signal instead of letting `set -e` abort silently.
if argocd app diff "$APP"; then
  echo "----------------------------------------------------------------------"
  echo "RESULT: no drift — cluster matches git."
  exit 0
else
  echo "----------------------------------------------------------------------"
  echo "RESULT: DRIFT DETECTED for ${APP}."
  echo "Remediate by syncing back to git:  argocd app sync ${APP}"
  echo "(dev/staging self-heal automatically; production requires a manual sync.)"
  exit 1
fi
