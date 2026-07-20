# Promotion Workflow

This document walks the full lifecycle of a change: from a source-code commit, to
a container image, through **dev → staging → production**, and back out again via
rollback. Every command shown here is real and runnable against a cluster that has
Argo CD and Argo Rollouts installed.

## The core idea

Git is the single source of truth. Nobody runs `kubectl apply` by hand. A change
to what runs in a cluster is always a change to a file in this repo:

- **Application source** (`app/`, `Dockerfile`) → produces a new **image tag**.
- **Desired state** (`applications/sample-api/overlays/<env>/kustomization.yaml`) →
  records which image tag each environment should run.

Argo CD continuously compares git (desired) with the cluster (live) and reconciles
the difference. Promotion is therefore just "change the tag in the next
environment's overlay", done through a reviewable Pull Request.

## 1. Build an image (CI)

On merge to `main` (or on a `v*` tag), `.github/workflows/ci.yml`:

1. runs the unit tests (`pytest`),
2. validates every overlay renders (`kustomize build | kubeconform`),
3. builds and pushes `ghcr.io/iarsingh/sample-api:<tag>` where `<tag>` is
   `dev-<sha7>` for a branch build or the semver for a git tag.

The tag is **immutable** — never `:latest` (a Kyverno policy rejects `:latest`).

## 2. Automatic promotion to dev

Dev is the fast lane. `.github/workflows/promote.yml` (on push to `main` touching
`app/**` or `Dockerfile`) commits the new `dev-<sha7>` tag straight into the dev
overlay:

```bash
cd applications/sample-api/overlays/dev
kustomize edit set image ghcr.io/iarsingh/sample-api=ghcr.io/iarsingh/sample-api:dev-3f2a1c9
# committed directly to main by the workflow
```

Locally this is:

```bash
make promote-dev TAG=dev-3f2a1c9
# wraps: scripts/promote-image.sh dev dev-3f2a1c9 --direct
```

The `sample-api-dev` Argo CD Application has `syncPolicy.automated { prune, selfHeal }`,
so the cluster converges to the new tag within a minute — no human gate. Dev runs a
plain Deployment with a RollingUpdate (fast and cheap, no canary).

## 3. PR-based promotion to staging

Staging is never committed directly. Open a promotion PR:

```bash
make promote-staging TAG=1.4.0
# wraps: scripts/promote-image.sh staging 1.4.0 --pr
```

or trigger `promote.yml` via **workflow_dispatch** (environment=`staging`,
image_tag=`1.4.0`). Either way a branch `promote/staging-1.4.0` is pushed and a PR
is opened that changes only:

```diff
 images:
   - name: ghcr.io/iarsingh/sample-api
-    newTag: "1.3.0"
+    newTag: "1.4.0"
```

**Merging the PR is the approval.** Two gates then apply:

- The `sample-api-nonprod` AppProject has a **business-hours sync window**, so
  automated sync only reconciles staging Mon–Fri 09:00–18:00 UTC; outside that a
  human must sync manually.
- Argo Rollouts runs a **canary**: 20% → 50% → 80% → 100%, pausing between steps and
  running an `AnalysisTemplate` (success rate ≥ 95% from Prometheus). If analysis
  fails, the rollout **auto-aborts** and traffic snaps back to the stable version.

Watch and, if needed, drive the canary:

```bash
kubectl argo rollouts get rollout sample-api -n sample-api-staging --watch
kubectl argo rollouts promote sample-api -n sample-api-staging      # advance a paused step
kubectl argo rollouts abort   sample-api -n sample-api-staging      # abort + roll back
```

## 4. Manual promotion to production

Production is deliberately manual end-to-end.

```bash
make promote-production TAG=1.4.0
# opens PR promote/production-1.4.0
```

After the PR merges, **nothing happens automatically**. The `sample-api-production`
Application has **no automated sync policy**, and the `sample-api-prod` AppProject
carries a permanent **deny sync window** (with `manualSync: true`). Argo CD marks
the app `OutOfSync`; an operator must explicitly sync:

```bash
argocd app diff sample-api-production      # review what will change
argocd app sync sample-api-production      # apply the desired state
```

Syncing brings up a **blue-green** green stack behind the `sample-api-preview`
Service. `autoPromotionEnabled: false`, so live traffic still points at the old
(blue) version. A `prePromotionAnalysis` (success rate ≥ 99%) must pass, then a
human promotes:

```bash
kubectl argo rollouts get rollout sample-api -n sample-api-production --watch
# smoke-test the green stack via the preview Service, then:
kubectl argo rollouts promote sample-api -n sample-api-production
```

Promotion is an instant Service cutover. The blue ReplicaSet is kept warm for
`scaleDownDelaySeconds` (300s) so rollback is instant.

## 5. Rollback

Two layers, fast first:

```bash
# (a) instant traffic rollback — no rebuild (uses the warm previous ReplicaSet)
make rollback ENV=production
# wraps: kubectl argo rollouts abort + undo sample-api -n sample-api-production

# (b) restore git desired state so Argo CD doesn't re-apply the bad version
argocd app rollback sample-api-production <history-id>
#   or: git revert <promotion-commit> && open a PR
```

Always do both: (a) stops the bleeding in the cluster, (b) makes git agree so the
next reconcile doesn't undo your rollback.

## 6. Drift detection

Drift = the cluster diverging from git (a manual `kubectl edit`, an operator
mutating a field, a deleted resource).

```bash
make argocd-diff ENV=production
# wraps: scripts/drift-check.sh production  ->  argocd app diff sample-api-production
```

- **dev / staging**: `selfHeal: true` reverts drift automatically.
- **production**: drift surfaces as `OutOfSync`; an operator reviews and runs
  `argocd app sync sample-api-production` to reconcile. The AppProject's
  `orphanedResources.warn` also flags resources in the namespace that git doesn't
  own.

## Summary table

| Environment | Sync            | Strategy              | Promotion gate                                   |
|-------------|-----------------|-----------------------|--------------------------------------------------|
| dev         | automated       | RollingUpdate         | none (auto on merge)                             |
| staging     | automated       | Argo Rollouts canary  | business-hours window + canary analysis (≥95%)   |
| production  | **manual only** | Argo Rollouts blue-green | merged PR → manual `argocd app sync` → manual `rollouts promote` (analysis ≥99%) |
