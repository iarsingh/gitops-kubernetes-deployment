# GitOps Kubernetes Deployment with Argo CD

<!-- project-guide:start -->
## Project guide

[Project architecture](PROJECT_ARCHITECTURE.md) · [Interview questions and answers](INTERVIEW_QA.md)

Use the architecture document for the component diagram, implementation boundaries, and verification entry points. The interview guide includes source-backed answers and project walkthroughs.

### Implementation map

| Component | Responsibility |
| --- | --- |
| [`app/main.py`](app/main.py) | HTTP handlers: `GET /`, `GET /health`, `GET /ready`, `GET /api/v1/echo`, `GET /metrics` |
| [`app/requirements.txt`](app/requirements.txt) | Implementation or supporting configuration |
| [`app/__init__.py`](app/__init__.py) | Implementation or supporting configuration |
| [`scripts/drift-check.sh`](scripts/drift-check.sh) | Implementation or supporting configuration |
| [`scripts/promote-image.sh`](scripts/promote-image.sh) | Implementation or supporting configuration |
| [`scripts/rollback.sh`](scripts/rollback.sh) | Implementation or supporting configuration |
| [`Dockerfile`](Dockerfile) | Container build/service configuration |
| [`Makefile`](Makefile) | Implementation or supporting configuration |
| [`docker-compose.yml`](docker-compose.yml) | Container build/service configuration |
| [`pyproject.toml`](pyproject.toml) | Implementation or supporting configuration |
| [`tests/test_main.py`](tests/test_main.py) | Executable checks and regression examples |
| [`.github/workflows/ci.yml`](.github/workflows/ci.yml) | GitHub Actions job definitions |
| [`.github/workflows/promote.yml`](.github/workflows/promote.yml) | GitHub Actions job definitions |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Project explanations or operating notes |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Project explanations or operating notes |
| [`README.md`](README.md) | Project explanations or operating notes |

### Local setup and verification

From the repository root (the commands follow the checked-in manifests):

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r app/requirements.txt
```

<!-- project-guide:end -->

<!-- repository-summary -->
A GitOps delivery reference using Argo CD, Kustomize, Argo Rollouts, policy guardrails, and environment promotion.
<!-- /repository-summary -->

A reference implementation of **GitOps-based continuous delivery** for a Kubernetes
microservice, using Argo CD, Kustomize, and Argo Rollouts. It deploys a real (small)
FastAPI service through **dev → staging → production** with PR-based environment
promotion, progressive delivery (canary + blue-green), policy guardrails, and no
plaintext secrets in git.

> **Honesty note:** this repo is a complete, valid, buildable reference. There is no
> live Argo CD instance or hosted demo behind it — every manifest is designed to
> apply cleanly to a real cluster, and the sample output in section 12 is real
> `kustomize build` output, not a mock-up.

---

## 1. The business problem

Teams that deploy to Kubernetes by running `kubectl apply` by hand hit the same
failures again and again:

- **Configuration drift** — the cluster no longer matches any file in version
  control. Someone ran `kubectl edit` at 2am during an incident and never wrote it
  down. Nobody can say with confidence what is actually running.
- **No audit trail** — "who changed the replica count, when, and why?" has no
  answer. Access to prod is a person with `kubectl`, not a reviewed change.
- **Risky, irreversible pushes** — a bad rollout takes 100% of traffic instantly;
  rollback means frantically remembering the previous image tag.
- **Inconsistent environments** — dev, staging, and prod diverge because each was
  `apply`-ed separately over time.

**GitOps** fixes this by making **git the single source of truth**. The desired
state of every environment lives in this repo. A controller (**Argo CD**)
continuously reconciles the cluster to match git and reports any drift. Every change
is a reviewed, reverted-in-one-`git revert` commit. Combined with **Argo Rollouts**,
releases become progressive and instantly reversible.

## 2. Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full diagram and rationale. In short:

```
developer PR ──▶ CI builds & pushes image ──▶ promote.yml opens PR bumping the
image tag in the target overlay ──▶ human (or auto, for dev) merges ──▶ Argo CD
detects git↔cluster drift and syncs ──▶ Argo Rollouts runs canary (staging) or
blue-green (production) ──▶ Prometheus analysis gates promotion ──▶ next environment
```

- **dev** auto-syncs on merge (plain RollingUpdate) — fast feedback.
- **staging** auto-syncs within a business-hours window, then a canary with a metric
  analysis gate.
- **production** is manual-sync only, then a blue-green cutover requiring a human
  promotion.

## 3. Technology stack

| Concern | Tool |
|---------|------|
| Container orchestration | Kubernetes |
| Configuration management | Kustomize (base + overlays) |
| GitOps delivery | Argo CD (Applications, AppProjects, app-of-apps) |
| Progressive delivery | Argo Rollouts (canary + blue-green + AnalysisTemplate) |
| CI / promotion | GitHub Actions (`ci.yml`, `promote.yml`) |
| Policy / guardrails | Kyverno ClusterPolicies |
| Secrets | Sealed Secrets *or* External Secrets Operator |
| Workload | Python 3.12 + FastAPI (the `sample-api` service) |

## 4. Repository structure

```
gitops-kubernetes-deployment/
├── app/                      # sample-api FastAPI source
├── tests/                    # pytest unit + health tests
├── Dockerfile                # multi-stage, non-root image
├── docker-compose.yml        # run the app locally, no k8s
├── applications/sample-api/
│   ├── base/                 # Deployment, Service, HPA, PDB, NetworkPolicy, SA, configMap
│   └── overlays/
│       ├── dev/              # scaled-down, moving dev tag, plain Deployment
│       ├── staging/          # Argo Rollouts canary + AnalysisTemplate
│       └── production/       # Argo Rollouts blue-green (manual promote), stricter PDB/limits
├── argocd/
│   ├── projects/             # nonprod + prod AppProjects (least-privilege scoping)
│   └── applications/         # dev/staging/production Applications + app-of-apps root
├── policies/                 # Kyverno ClusterPolicies (limits, no :latest, non-root, PDB)
├── .github/workflows/        # ci.yml (test/validate/build), promote.yml (PR promotion)
├── scripts/                  # promote-image.sh, rollback.sh, drift-check.sh
├── docs/                     # promotion-workflow.md + secret examples
├── Makefile                  # build / lint / validate / promote / rollback targets
├── ARCHITECTURE.md  SECURITY.md  CONTRIBUTING.md  LICENSE
```

## 5. Local setup

### Just the app (no Kubernetes)

```bash
docker compose up --build
curl localhost:8000/health                 # {"status":"ok"}
curl localhost:8000/ready                  # {"ready":true,...}
curl "localhost:8000/api/v1/echo?message=hello"
curl localhost:8000/metrics                # Prometheus format
```

Run the tests:

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r app/requirements-dev.txt
pytest            # 7 passing
```

### The manifests on a local cluster (kind / minikube)

```bash
# 1. start a cluster
minikube start                 # or: kind create cluster

# 2. render + apply an overlay directly (no Argo CD yet)
kubectl create namespace sample-api-dev
kubectl kustomize applications/sample-api/overlays/dev | kubectl apply -f -
kubectl -n sample-api-dev get pods

# 3. install the argocd CLI (macOS)
brew install argocd
# Linux: curl -sSL -o /usr/local/bin/argocd \
#   https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64 && chmod +x /usr/local/bin/argocd
```

Validate everything renders and parses:

```bash
make build-all        # base + all 3 overlays render
make yaml-validate    # Argo CD + policy YAML parse
make lint             # + kubeconform schema validation, if installed
```

## 6. Cloud deployment (real cluster)

```bash
# 1. install Argo CD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 2. install Argo Rollouts (needed for staging/production strategies)
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
kubectl krew install argo-rollouts        # the kubectl plugin

# 3. (optional) install Kyverno for the policy guardrails
kubectl apply -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml

# 4. apply the AppProjects (least-privilege scopes) FIRST
kubectl apply -f argocd/projects/

# 5. apply the app-of-apps root; it renders the dev/staging/production Applications
kubectl apply -f argocd/applications/root-app.yaml

# 6. apply the guardrail policies
kubectl apply -f policies/
```

From here Argo CD takes over: it reconciles dev and staging automatically and leaves
production `OutOfSync` until an operator runs `argocd app sync sample-api-production`.

## 7. CI/CD flow

- **`ci.yml`** (push/PR): `pytest` → `kustomize build | kubeconform` for every
  overlay → build & push `ghcr.io/iarsingh/sample-api:<tag>` (branch → `dev-<sha7>`,
  git tag → semver).
- **`promote.yml`** (workflow_dispatch or push to main touching `app/`): bumps the
  image tag in the target overlay with `kustomize edit set image`, then:
  - **dev** → commits the tag straight to `main` (auto-sync applies it);
  - **staging / production** → opens a **promotion PR**. Merging the PR is the
    approval gate.

Locally the same flow is `make promote-dev|promote-staging|promote-production TAG=…`.
Full walkthrough with commands: [docs/promotion-workflow.md](docs/promotion-workflow.md).

## 8. Security controls

Full detail in [SECURITY.md](SECURITY.md). Summary:

- **No plaintext secrets in git** — Sealed Secrets or External Secrets (examples in
  `docs/examples/`).
- **Least-privilege AppProjects** — each project pins the source repo, destination
  namespaces, and allowed resource kinds; prod denies automated sync entirely.
- **NetworkPolicy default-deny** + a narrow allow (port 8000 ingress, DNS egress).
- **Non-root, read-only-rootfs, all-caps-dropped, seccomp RuntimeDefault** containers.
- **Image tags pinned** — `:latest` is rejected by policy.
- **Kyverno enforcement** — resource limits, non-root, no `:latest`, require PDB.

## 9. Monitoring

The `sample-api` exposes Prometheus metrics at `/metrics`
(`sample_api_requests_total`, `sample_api_request_errors_total`). Argo Rollouts
`AnalysisTemplate`s query Prometheus to gate promotion:

- **staging canary** — success rate **≥ 95%**, sampled 5× at 30s intervals between
  weight steps; a breach auto-aborts the rollout and returns traffic to stable.
- **production blue-green** — `prePromotionAnalysis` requires success rate **≥ 99%**
  on the green stack before an operator may promote it to the active Service.

In a real deployment these would sit alongside dashboards/alerts on latency,
saturation, and the four golden signals; the analysis gate is the automated,
release-blocking subset.

## 10. Failure and rollback

Two layers (see [docs/promotion-workflow.md](docs/promotion-workflow.md) §5):

1. **In-cluster, instant** — `kubectl argo rollouts abort` + `undo` (or
   `make rollback ENV=<env>`) shifts traffic back to the previous ReplicaSet with no
   rebuild (the old ReplicaSet is kept warm via `scaleDownDelaySeconds`).
2. **Restore desired state** — `argocd app rollback <app> <history-id>` or a
   `git revert` of the promotion commit, so Argo CD stops re-applying the bad version.

**Drift** is detected with `argocd app diff` (`make argocd-diff ENV=<env>` /
`scripts/drift-check.sh`). dev/staging self-heal automatically; production surfaces
drift as `OutOfSync` for a human to reconcile.

## 11. Cost considerations

- **Progressive delivery briefly doubles capacity.** Blue-green runs a full second
  (green) stack alongside the live (blue) one until promotion, and keeps blue warm
  for `scaleDownDelaySeconds` after — so production can run ~2× replicas for the
  duration of a release. Canary is cheaper (only the extra weighted pods), but still
  adds surge capacity. Budget node headroom for release windows accordingly.
- **HPA ceilings bound the spend** — each overlay sets `minReplicas`/`maxReplicas`
  (dev 1–2, staging 2–4, production 3–10) so autoscaling can't run away.
- **Dev is deliberately small** — 1 replica, no canary, looser PDB — because dev
  optimizes for iteration speed and cost, not availability.
- **The blue-green tradeoff is control vs. cost**: you pay for the extra stack to buy
  an instant, risk-free cutover and instant rollback. For a low-risk, cost-sensitive
  service, the cheaper canary (staging's strategy) may be the right call in prod too.

## 12. A real example: `kustomize build applications/sample-api/overlays/dev`

The block below is the **actual, unmodified output** of running
`kustomize build applications/sample-api/overlays/dev` (via `kubectl kustomize`) in
this repo — captured, not hand-written. Note the `sample-api-dev` namespace, the
`replicas: 1` dev sizing, the pinned image tag `dev-3f2a1c9`, the non-root
securityContext, and the default-deny NetworkPolicy.

```yaml
apiVersion: v1
automountServiceAccountToken: false
kind: ServiceAccount
metadata:
  labels:
    app.kubernetes.io/component: api
    app.kubernetes.io/environment: dev
    app.kubernetes.io/managed-by: argocd
    app.kubernetes.io/name: sample-api
    app.kubernetes.io/part-of: gitops-kubernetes-deployment
  name: sample-api
  namespace: sample-api-dev
---
apiVersion: v1
data:
  APP_ENV: dev
  APP_NAME: sample-api
  APP_VERSION: 0.1.0
  READINESS_WARMUP_SECONDS: "0"
kind: ConfigMap
metadata:
  labels:
    app.kubernetes.io/environment: dev
    app.kubernetes.io/managed-by: argocd
    app.kubernetes.io/name: sample-api
    app.kubernetes.io/part-of: gitops-kubernetes-deployment
  name: sample-api-config-8gdg2thd6h
  namespace: sample-api-dev
---
apiVersion: v1
kind: Service
metadata:
  labels:
    app.kubernetes.io/component: api
    app.kubernetes.io/environment: dev
    app.kubernetes.io/managed-by: argocd
    app.kubernetes.io/name: sample-api
    app.kubernetes.io/part-of: gitops-kubernetes-deployment
  name: sample-api
  namespace: sample-api-dev
spec:
  ports:
  - name: http
    port: 80
    protocol: TCP
    targetPort: http
  selector:
    app.kubernetes.io/name: sample-api
  type: ClusterIP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app.kubernetes.io/component: api
    app.kubernetes.io/environment: dev
    app.kubernetes.io/managed-by: argocd
    app.kubernetes.io/name: sample-api
    app.kubernetes.io/part-of: gitops-kubernetes-deployment
  name: sample-api
  namespace: sample-api-dev
spec:
  replicas: 1
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app.kubernetes.io/name: sample-api
  strategy:
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
    type: RollingUpdate
  template:
    metadata:
      annotations:
        prometheus.io/path: /metrics
        prometheus.io/port: "8000"
        prometheus.io/scrape: "true"
      labels:
        app.kubernetes.io/component: api
        app.kubernetes.io/managed-by: argocd
        app.kubernetes.io/name: sample-api
        app.kubernetes.io/part-of: gitops-kubernetes-deployment
    spec:
      automountServiceAccountToken: false
      containers:
      - envFrom:
        - configMapRef:
            name: sample-api-config-8gdg2thd6h
        image: ghcr.io/iarsingh/sample-api:dev-3f2a1c9
        imagePullPolicy: IfNotPresent
        livenessProbe:
          failureThreshold: 3
          httpGet:
            path: /health
            port: http
          initialDelaySeconds: 5
          periodSeconds: 10
          timeoutSeconds: 2
        name: sample-api
        ports:
        - containerPort: 8000
          name: http
          protocol: TCP
        readinessProbe:
          failureThreshold: 3
          httpGet:
            path: /ready
            port: http
          initialDelaySeconds: 3
          periodSeconds: 5
          timeoutSeconds: 2
        resources:
          limits:
            cpu: 250m
            memory: 128Mi
          requests:
            cpu: 50m
            memory: 64Mi
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
          readOnlyRootFilesystem: true
          runAsNonRoot: true
        startupProbe:
          failureThreshold: 10
          httpGet:
            path: /health
            port: http
          periodSeconds: 3
        volumeMounts:
        - mountPath: /tmp
          name: tmp
      securityContext:
        fsGroup: 10001
        runAsGroup: 10001
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile:
          type: RuntimeDefault
      serviceAccountName: sample-api
      volumes:
      - emptyDir: {}
        name: tmp
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  labels:
    app.kubernetes.io/component: api
    app.kubernetes.io/environment: dev
    app.kubernetes.io/managed-by: argocd
    app.kubernetes.io/name: sample-api
    app.kubernetes.io/part-of: gitops-kubernetes-deployment
  name: sample-api
  namespace: sample-api-dev
spec:
  minAvailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: sample-api
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  labels:
    app.kubernetes.io/component: api
    app.kubernetes.io/environment: dev
    app.kubernetes.io/managed-by: argocd
    app.kubernetes.io/name: sample-api
    app.kubernetes.io/part-of: gitops-kubernetes-deployment
  name: sample-api
  namespace: sample-api-dev
spec:
  behavior:
    scaleDown:
      policies:
      - periodSeconds: 60
        type: Percent
        value: 50
      stabilizationWindowSeconds: 300
    scaleUp:
      policies:
      - periodSeconds: 30
        type: Percent
        value: 100
      stabilizationWindowSeconds: 60
  maxReplicas: 2
  metrics:
  - resource:
      name: cpu
      target:
        averageUtilization: 70
        type: Utilization
    type: Resource
  - resource:
      name: memory
      target:
        averageUtilization: 80
        type: Utilization
    type: Resource
  minReplicas: 1
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: sample-api
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  labels:
    app.kubernetes.io/component: network-policy
    app.kubernetes.io/environment: dev
    app.kubernetes.io/managed-by: argocd
    app.kubernetes.io/name: sample-api
    app.kubernetes.io/part-of: gitops-kubernetes-deployment
  name: default-deny-all
  namespace: sample-api-dev
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  labels:
    app.kubernetes.io/component: network-policy
    app.kubernetes.io/environment: dev
    app.kubernetes.io/managed-by: argocd
    app.kubernetes.io/name: sample-api
    app.kubernetes.io/part-of: gitops-kubernetes-deployment
  name: sample-api-allow
  namespace: sample-api-dev
spec:
  egress:
  - ports:
    - port: 53
      protocol: UDP
    - port: 53
      protocol: TCP
    to:
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
    - namespaceSelector:
        matchLabels:
          app.kubernetes.io/name: prometheus
    - podSelector: {}
    ports:
    - port: 8000
      protocol: TCP
  podSelector:
    matchLabels:
      app.kubernetes.io/name: sample-api
  policyTypes:
  - Ingress
  - Egress
```


## Documentation checks

Project architecture, interview guides, and local source links are checked automatically on pushes and pull requests. Run the same check locally:

```bash
python3 .github/scripts/validate_project_docs.py
```
