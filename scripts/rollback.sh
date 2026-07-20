#!/usr/bin/env bash
#
# rollback.sh — roll a sample-api environment back to its previous good version.
#
# Two rollback layers exist and this script drives the fast one (Argo Rollouts):
#   1. Argo Rollouts undo  — instantly shifts traffic back to the previous
#      ReplicaSet without a rebuild (works because scaleDownDelaySeconds keeps the
#      old ReplicaSet warm). THIS is what the script runs.
#   2. Git/Argo CD rollback — revert the tag-bump commit (or `argocd app rollback`)
#      to restore the previous *desired* state. Printed as a follow-up hint.
#
# Usage:
#   scripts/rollback.sh <env> [revision]
#
# Examples:
#   scripts/rollback.sh production        # undo to the immediately previous revision
#   scripts/rollback.sh staging 3         # undo to a specific Rollout revision number
#
# Requires: kubectl and the Argo Rollouts kubectl plugin (`kubectl argo rollouts`).
set -euo pipefail

ENV="${1:-}"
REVISION="${2:-}"

case "$ENV" in
  dev|staging|production) ;;
  *) echo "usage: $0 <dev|staging|production> [revision]" >&2; exit 1 ;;
esac

NAMESPACE="sample-api-${ENV}"

if ! kubectl argo rollouts version >/dev/null 2>&1; then
  echo "error: 'kubectl argo rollouts' plugin not found." >&2
  echo "install: https://argoproj.github.io/argo-rollouts/installation/#kubectl-plugin-installation" >&2
  exit 1
fi

if [[ "$ENV" == "dev" ]]; then
  echo "note: dev runs a plain Deployment (no Rollout). Rolling back via kubectl."
  kubectl -n "$NAMESPACE" rollout undo deployment/sample-api
  kubectl -n "$NAMESPACE" rollout status deployment/sample-api
  exit 0
fi

echo ">> Aborting any in-flight rollout in ${NAMESPACE} (safe if none is running)"
kubectl argo rollouts abort sample-api -n "$NAMESPACE" || true

if [[ -n "$REVISION" ]]; then
  echo ">> Undoing rollout sample-api to revision ${REVISION}"
  kubectl argo rollouts undo sample-api -n "$NAMESPACE" --to-revision="$REVISION"
else
  echo ">> Undoing rollout sample-api to the previous revision"
  kubectl argo rollouts undo sample-api -n "$NAMESPACE"
fi

echo ">> Current rollout status:"
kubectl argo rollouts get rollout sample-api -n "$NAMESPACE" --no-color || true

cat <<EOF

Traffic is now back on the previous version.

IMPORTANT: this only changed the live cluster. To keep Argo CD from re-applying
the bad version, also fix the git desired state:
  * revert the promotion commit, or
  * roll the Argo CD app back:  argocd app rollback sample-api-${ENV} <history-id>
EOF
