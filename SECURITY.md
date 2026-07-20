# Security Controls

This repository is designed so that the secure option is the default one. The
controls below are all demonstrated by the manifests in this repo, and several are
additionally *enforced* by policy.

## 1. No plaintext secrets in git

Secrets are never committed in the clear. Two supported approaches, both with a
reference example under [`docs/examples/`](docs/examples/):

### SealedSecrets (Bitnami) — encrypt into git
See [`docs/examples/sealedsecret.yaml`](docs/examples/sealedsecret.yaml). A
`SealedSecret` holds asymmetrically-encrypted data that **only** the in-cluster
sealed-secrets controller can decrypt. It is safe to commit to a public repo.

```bash
kubectl create secret generic sample-api-secrets \
  --namespace sample-api-production \
  --from-literal=DATABASE_URL='postgres://user:pass@db:5432/app' \
  --dry-run=client -o yaml \
| kubeseal --controller-namespace kube-system --format yaml > sealedsecret.yaml
```

### External Secrets Operator — reference, don't store
See [`docs/examples/externalsecret.yaml`](docs/examples/externalsecret.yaml). Git
holds only a *pointer* to a secret in AWS Secrets Manager / GCP Secret Manager /
Vault; the operator materialises the real Kubernetes Secret. The service account
authenticates via workload identity (IRSA / Workload Identity) — no static
credentials anywhere in git. Rotation happens in the external store with no commit.

`.gitignore` additionally blocks `*.dec.yaml`, `secrets/*.plain.yaml`, and `.env`
to stop accidental commits of decrypted material.

## 2. Least-privilege AppProject scoping

Argo CD `AppProject`s constrain what each environment's apps may touch:

- **`sample-api-nonprod`** — only this git repo as a source; only the
  `sample-api-dev` / `sample-api-staging` namespaces as destinations; a whitelist
  of allowed namespaced resource kinds; **zero** cluster-scoped resources.
- **`sample-api-prod`** — strictest: this repo only, the `sample-api-production`
  namespace only, and a **deny sync window** so automated sync can never touch
  production (manual sync only).

A compromised or misconfigured Application therefore cannot deploy an arbitrary
repo, escape into another namespace, or create cluster-scoped objects.

## 3. NetworkPolicy default-deny

Every namespace gets a `default-deny-all` NetworkPolicy (empty podSelector, both
Ingress and Egress) plus a narrow `sample-api-allow` policy that re-opens only:

- **ingress** to port 8000 from the ingress-controller namespace, the Prometheus
  namespace (for `/metrics`), and same-namespace pods;
- **egress** to `kube-dns` on port 53 for name resolution.

Nothing else can talk to or from the workload.

## 4. Non-root, hardened containers

The container image and the Deployment both enforce:

- `runAsNonRoot: true`, `runAsUser: 10001` (a dedicated unprivileged user baked
  into the image);
- `allowPrivilegeEscalation: false`;
- `readOnlyRootFilesystem: true` (with a writable `/tmp` emptyDir for scratch);
- `capabilities.drop: [ALL]`;
- `seccompProfile: RuntimeDefault`;
- `automountServiceAccountToken: false` (the workload needs no API access).

## 5. Image tag pinning (no `:latest`)

Images are always pinned to an immutable tag. A mutable `:latest` would make the
git state a lie and break auditability and rollback. Promotion works by writing an
explicit tag with `kustomize edit set image`.

## 6. Policy enforcement (Kyverno)

The controls above are enforced cluster-wide by the `ClusterPolicy` objects in
[`policies/`](policies/), so a non-compliant manifest is rejected at admission (or
flagged in audit) even if someone forgets:

| Policy | Enforces | Action |
|--------|----------|--------|
| `require-resource-limits` | CPU/memory requests **and** limits on every container | Enforce |
| `disallow-latest-tag` | explicit, non-`:latest` image tag | Enforce |
| `require-non-root` | `runAsNonRoot: true` + `allowPrivilegeEscalation: false` | Enforce |
| `require-pdb` | a PodDisruptionBudget for every multi-replica Deployment | Audit |

## Reporting a vulnerability

This is a portfolio/reference repository, not a production service. If you spot a
security issue in the manifests or code, please open an issue describing it.
