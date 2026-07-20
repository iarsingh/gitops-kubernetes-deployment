# Contributing

## Prerequisites

- `kubectl` (v1.27+) — provides `kubectl kustomize`
- `kustomize` (optional; the Makefile falls back to `kubectl kustomize`)
- `python3` 3.11+ and `pip` (for the app + tests)
- `docker` (to build/run the image locally)
- `kubeconform` (optional; enables schema validation in `make lint`)
- For cluster work: `argocd` CLI and the `kubectl argo rollouts` plugin

## Local development loop

Run just the application, no Kubernetes:

```bash
docker compose up --build          # http://localhost:8000
curl localhost:8000/health         # {"status":"ok"}
curl "localhost:8000/api/v1/echo?message=hi"
```

Run the tests:

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r app/requirements-dev.txt
pytest            # or: make test
```

## Testing a Kustomize overlay before opening a PR

Always render an overlay locally before proposing a change — the CI job does
exactly this and will reject a PR that doesn't build:

```bash
make kustomize-build ENV=dev        # render a single overlay
make build-all                      # render base + all overlays
make lint                           # render + schema-validate (kubeconform)
make yaml-validate                  # parse-check Argo CD + policy YAML
```

Apply an overlay to a local cluster (kind/minikube) without Argo CD, to eyeball it:

```bash
kubectl kustomize applications/sample-api/overlays/dev | kubectl apply --dry-run=client -f -
```

## Adding a new environment / overlay

Say you want a `qa` environment:

1. Create `applications/sample-api/overlays/qa/kustomization.yaml`. Start from the
   `dev` overlay as a template:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: sample-api-qa
   resources:
     - ../../base
   labels:
     - includeSelectors: false
       pairs:
         app.kubernetes.io/environment: qa
   configMapGenerator:
     - name: sample-api-config
       behavior: merge
       literals:
         - APP_ENV=qa
   images:
     - name: ghcr.io/iarsingh/sample-api
       newTag: "0.1.0"
   patches:
     - target: { kind: Deployment, name: sample-api }
       patch: |-
         - op: replace
           path: /spec/replicas
           value: 2
   ```
2. If the environment needs progressive delivery, copy `rollout.yaml` and
   `analysistemplate.yaml` from `overlays/staging` (canary) or `overlays/production`
   (blue-green), add them to `resources:`, and patch the Deployment replicas to `0`
   and the HPA `scaleTargetRef` to the Rollout (see the staging overlay for the
   exact patches).
3. Add an Argo CD Application at `argocd/applications/sample-api-qa.yaml` (copy an
   existing one, set `path:` and `namespace:`), and reference it from the correct
   AppProject destination list in `argocd/projects/`.
4. If the root app-of-apps `include` glob doesn't already match the new file, update
   `argocd/applications/root-app.yaml`.
5. Verify: `make build-all && make yaml-validate`.
6. Open a PR.

## Commit conventions

Use conventional-commit prefixes (`feat:`, `fix:`, `docs:`, `chore:`). Keep each
commit a single logical change. CI (`ci.yml`) must pass before merge.
