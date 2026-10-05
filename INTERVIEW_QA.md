# gitops-kubernetes-deployment — interview questions and answers

[README](README.md) · [Project architecture](PROJECT_ARCHITECTURE.md)

Answers below use this repository’s files and implementation. They distinguish existing behavior from suggested extensions; source links let you verify each walkthrough.

## 1. What problem does gitops-kubernetes-deployment address, and what can you demonstrate?

A GitOps delivery reference using Argo CD, Kustomize, Argo Rollouts, policy guardrails, and environment promotion.

I would demonstrate the linked implementation or examples and distinguish that evidence from any planned production features. Start with [`README.md`](README.md).

## 2. How is this repository organized?

- [`app/main.py`](app/main.py): Implementation or supporting configuration.
- [`app/requirements.txt`](app/requirements.txt): Implementation or supporting configuration.
- [`app/__init__.py`](app/__init__.py): Implementation or supporting configuration.
- [`scripts/drift-check.sh`](scripts/drift-check.sh): Implementation or supporting configuration.
- [`scripts/promote-image.sh`](scripts/promote-image.sh): Implementation or supporting configuration.
- [`scripts/rollback.sh`](scripts/rollback.sh): Implementation or supporting configuration.
- [`Dockerfile`](Dockerfile): Container build/service configuration.
- [`Makefile`](Makefile): Implementation or supporting configuration.

[PROJECT_ARCHITECTURE.md](PROJECT_ARCHITECTURE.md) contains the component diagram and the implementation walkthrough.

## 3. Can you walk through `count_requests` and explain the decision it makes?

The main walkthrough here is `count_requests(request: Any, call_next: Any)` in [`app/main.py`](app/main.py#L43). Count every request and any 5xx so /metrics can expose an error rate.

```python
async def count_requests(request: Any, call_next: Any):
    """Count every request and any 5xx so /metrics can expose an error rate."""
    _REQUEST_COUNT["total"] += 1
    response = await call_next(request)
    if response.status_code >= 500:
        _REQUEST_COUNT["errors"] += 1
    return response
```

The implementation calls `app.middleware`, `call_next`. In an interview, trace those calls in execution order using a fixture input.

## 4. Where would you add input-validation tests?

Start with the handlers `root` in [`app/main.py`](app/main.py#L53), `health` in [`app/main.py`](app/main.py#L64), `ready` in [`app/main.py`](app/main.py#L70). Use the request schema or body access in each handler to build valid, missing-field, wrong-type, and boundary inputs. I would inspect existing tests before claiming coverage.

## 5. Which test would you use to demonstrate correctness?

[`tests/test_main.py`](tests/test_main.py#L16) contains `test_health_returns_ok`:

```python
def test_health_returns_ok() -> None:
    """The liveness endpoint must return 200 with status ok."""
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}
```

This is a concrete regression example from the repository. Its assertions establish that case; they do not establish behavior for every input or under production load.

## 6. What HTTP interface does the code expose?

- `GET /` → `root` in [`app/main.py`](app/main.py#L53).
- `GET /health` → `health` in [`app/main.py`](app/main.py#L64).
- `GET /ready` → `ready` in [`app/main.py`](app/main.py#L70).
- `GET /api/v1/echo` → `echo` in [`app/main.py`](app/main.py#L83).
- `GET /metrics` → `metrics` in [`app/main.py`](app/main.py#L89).

These are literal decorators. Application/router prefixes, authentication, and middleware must be checked in the corresponding setup code.

## 7. Where does state live, and what happens with multiple workers?

Module-level containers include `_REQUEST_COUNT` in [`app/main.py`](app/main.py).

These containers belong to a Python process. Inspect which are constant fixtures and which are mutated. Mutable process state needs an explicit shared-storage or synchronization strategy before multiple workers can provide consistent behavior.

## 8. How would another engineer reproduce your walkthrough?

Start from the repository root:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r app/requirements.txt
```

These commands follow repository manifests; environment setup and command results still need to be checked on the target machine.

## 9. What does automation verify, and what does it not prove?

Inspect [`.github/workflows/ci.yml`](.github/workflows/ci.yml), [`.github/workflows/promote.yml`](.github/workflows/promote.yml) for triggers, permissions, and job commands. I would name the checks that those definitions run and show the latest run separately. A workflow definition alone does not establish a successful deployment, security review, or production SLO.

## 10. How would you present this project in a Forward Deployed Engineer interview?

Start with the user and operational problem described in [`README.md`](README.md). Explain one constraint that changes the implementation, show the linked code or example, and walk through a success case and a failure case. Agree on a measurable acceptance criterion before expanding the solution, and leave a handoff with data boundaries and rollback ownership. Any proposed production or business metric should be identified as a target until measured.

## 11. What is the input-to-output contract of `count_requests`?

In [`app/main.py`](app/main.py#L43), `count_requests(request: Any, call_next: Any)` receives the inputs. The function computes these intermediate values:

- `response = await call_next(request)`

Its result is defined by:

- `response`

## 12. Which decision rules or boundary conditions should an interviewer challenge?

The implementation in [`app/main.py`](app/main.py#L43) branches on:

- `response.status_code >= 500`

A useful extension is a table-driven test that covers each condition just below, at, and above its boundary where applicable. These expressions are the current rules; changing them changes behavior and should be justified by the project’s acceptance criteria.
