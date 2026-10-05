# gitops-kubernetes-deployment — project architecture

[README](README.md) · [Interview questions and answers](INTERVIEW_QA.md)

## Purpose and scope

A GitOps delivery reference using Argo CD, Kustomize, Argo Rollouts, policy guardrails, and environment promotion.

This document describes files and symbols in this checkout. Deployment templates and statements in the original overview are distinguished from a verified running environment.

## Component diagram

```mermaid
flowchart LR
    M0["app/__init__.py"]
    M1["app/main.py"]
    R["Repository"] -. contains .-> M0
    R["Repository"] -. contains .-> M1
```

For Python repositories, arrows show resolved local imports, not network calls or deployment order. Otherwise the diagram is a repository component map; containment arrows do not assert runtime integration.

## Components and responsibilities

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

## Existing design and operating guides

These checked-in guides provide the project’s detailed design, operational context, or deployment view:

- [`ARCHITECTURE.md`](ARCHITECTURE.md).
- [`SECURITY.md`](SECURITY.md).

### Existing deployment/design view

The following view is retained from [`ARCHITECTURE.md`](ARCHITECTURE.md). Read that guide for its assumptions and the distinction between configured and deployed components.

```mermaid
flowchart TD
    subgraph dev_local["Developer"]
        A["Commit to app/ or Dockerfile"] --> PR1["Open PR to main"]
    end

    PR1 --> CI

    subgraph ci["GitHub Actions"]
        CI["ci.yml: pytest + kustomize/kubeconform validate"] --> IMG["Build & push image<br/>ghcr.io/iarsingh/sample-api:TAG<br/>(immutable tag, never :latest)"]
        IMG --> PROM["promote.yml"]
        PROM -->|dev: commit tag to main| DEVOVL["overlays/dev/kustomization.yaml"]
        PROM -->|staging/prod: open promotion PR| PRENV["PR bumps tag in<br/>overlays/&lt;env&gt;/kustomization.yaml"]
    end

    PRENV -->|human review + merge| GIT
    DEVOVL --> GIT

    subgraph git["Git = desired state"]
        GIT["main branch<br/>Kustomize base + overlays"]
    end

    GIT -->|Argo CD polls / webhook| ACD

    subgraph cluster["Kubernetes cluster"]
        ACD["Argo CD<br/>detects drift git↔cluster"]
        ACD -->|dev: auto-sync selfHeal+prune| DEVAPP["Deployment (RollingUpdate)"]
        ACD -->|staging: auto-sync in window| STGAPP["Argo Rollouts: canary"]
        ACD -->|production: MANUAL sync only| PRDAPP["Argo Rollouts: blue-green"]

        STGAPP --> ANALYSIS["AnalysisTemplate<br/>success rate ≥ 95% (Prometheus)"]
        ANALYSIS -->|pass| PROMOTE100["shift to 100%"]
        ANALYSIS -->|fail| ABORT["auto-abort + rollback"]

        PRDAPP --> PREVIEW["preview Service<br/>(green stack)"]
        PREVIEW --> PREANALYSIS["prePromotionAnalysis ≥ 99%"]
        PREANALYSIS -->|human promote| ACTIVE["active Service cutover"]
    end

    PROMOTE100 -.->|"gate passed → promote image to next env (new PR)"| PROM
```

## Request interface

| Method and path | Handler | Source |
| --- | --- | --- |
| `GET /` | `root` | [`app/main.py`](app/main.py#L53) |
| `GET /health` | `health` | [`app/main.py`](app/main.py#L64) |
| `GET /ready` | `ready` | [`app/main.py`](app/main.py#L70) |
| `GET /api/v1/echo` | `echo` | [`app/main.py`](app/main.py#L83) |
| `GET /metrics` | `metrics` | [`app/main.py`](app/main.py#L89) |

The table lists literal route decorators found in the inspected Python modules. Router prefixes and middleware can add behavior; check the linked handler and application setup before calling an endpoint.

## Implementation walkthrough

### `count_requests(request: Any, call_next: Any)`

Source: [`app/main.py`](app/main.py#L43).

Count every request and any 5xx so /metrics can expose an error rate.

Calls visible in this function: `app.middleware`, `call_next`.

```python
async def count_requests(request: Any, call_next: Any):
    """Count every request and any 5xx so /metrics can expose an error rate."""
    _REQUEST_COUNT["total"] += 1
    response = await call_next(request)
    if response.status_code >= 500:
        _REQUEST_COUNT["errors"] += 1
    return response
```

## Data and state

- [`app/main.py`](app/main.py) defines module-level containers: `_REQUEST_COUNT`.

Module-level dictionaries/lists live in a Python process. They can be fixtures or mutable state; inspect writes before treating them as persistent storage. A production extension would need to define persistence and concurrency behavior explicitly.

## Data flow and design decisions

### What is the input-to-output contract of `count_requests`

In [`app/main.py`](app/main.py#L43), `count_requests(request: Any, call_next: Any)` receives the inputs. The function computes these intermediate values:

- `response = await call_next(request)`

Its result is defined by:

- `response`

### Which decision rules or boundary conditions should an interviewer challenge

The implementation in [`app/main.py`](app/main.py#L43) branches on:

- `response.status_code >= 500`

A useful extension is a table-driven test that covers each condition just below, at, and above its boundary where applicable. These expressions are the current rules; changing them changes behavior and should be justified by the project’s acceptance criteria.

## Setup and verification

The following commands are derived from the checked-in dependency/test contracts. Execute them from the repository root; the block prepares a local environment, not a cloud deployment.

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r app/requirements.txt
```

Python dependencies: [`app/requirements.txt`](app/requirements.txt).

Test entry points: [`tests/test_main.py`](tests/test_main.py).

Automation definitions: [`.github/workflows/ci.yml`](.github/workflows/ci.yml), [`.github/workflows/promote.yml`](.github/workflows/promote.yml). Read their triggers and job steps to determine what CI actually runs.

## Operating boundaries and design review

Before turning this checkout into a customer deployment, establish the input contract, data ownership, access controls, failure response, evaluation criteria, and rollback owner. Repository fixtures and unit tests demonstrate local behavior; they do not establish throughput, uptime, compliance, or business impact.

A useful architecture review starts with the linked implementation: identify where input enters, where a decision is made, which state can change, and which external dependency can fail. Add a deployment view only for infrastructure that is actually configured and exercised.
