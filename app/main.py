"""sample-api: a minimal FastAPI service used as the GitOps deployment workload.

This service intentionally stays small. Its purpose in this repository is to be a
real, buildable, testable container image that Argo CD + Argo Rollouts promote
through dev -> staging -> production overlays.

Endpoints:
  GET /            -> service banner / metadata
  GET /health      -> liveness probe target (process is up)
  GET /ready       -> readiness probe target (dependencies ready)
  GET /api/v1/echo -> echoes a message, demonstrates a real request path
  GET /metrics     -> Prometheus exposition format (scraped by canary AnalysisTemplate)
"""
from __future__ import annotations

import os
import time
from typing import Any

from fastapi import FastAPI, Query
from fastapi.responses import PlainTextResponse

# Metadata surfaced on the root endpoint. These are wired to environment variables
# so the same image behaves identically across every overlay; only the injected
# values differ per environment (set via the Kustomize configMapGenerator).
APP_NAME = os.getenv("APP_NAME", "sample-api")
APP_ENV = os.getenv("APP_ENV", "local")
APP_VERSION = os.getenv("APP_VERSION", "0.1.0")

# Process start time, used to report uptime and to gate readiness during warmup.
_START_TIME = time.monotonic()

# Simple in-process counters exposed on /metrics. In a production service these
# would come from a real Prometheus client; keeping them hand-rolled avoids an
# extra dependency while still producing valid exposition-format output that a
# canary AnalysisTemplate can scrape.
_REQUEST_COUNT: dict[str, int] = {"total": 0, "errors": 0}

app = FastAPI(title=APP_NAME, version=APP_VERSION)


@app.middleware("http")
async def count_requests(request: Any, call_next: Any):
    """Count every request and any 5xx so /metrics can expose an error rate."""
    _REQUEST_COUNT["total"] += 1
    response = await call_next(request)
    if response.status_code >= 500:
        _REQUEST_COUNT["errors"] += 1
    return response


@app.get("/")
def root() -> dict[str, str]:
    """Return service identity and the environment it believes it is running in."""
    return {
        "service": APP_NAME,
        "environment": APP_ENV,
        "version": APP_VERSION,
        "message": "GitOps-deployed sample API. See /health, /ready, /metrics.",
    }


@app.get("/health")
def health() -> dict[str, str]:
    """Liveness: the process is running and can serve requests. Never touches deps."""
    return {"status": "ok"}


@app.get("/ready")
def ready() -> dict[str, Any]:
    """Readiness: report whether the service has finished its (simulated) warmup.

    Kubernetes will keep the pod out of the Service endpoints until this returns
    a 2xx, which is what makes a rolling/canary update safe.
    """
    uptime = time.monotonic() - _START_TIME
    warmup_seconds = float(os.getenv("READINESS_WARMUP_SECONDS", "0"))
    is_ready = uptime >= warmup_seconds
    return {"ready": is_ready, "uptime_seconds": round(uptime, 3)}


@app.get("/api/v1/echo")
def echo(message: str = Query(default="hello", max_length=256)) -> dict[str, str]:
    """Echo a caller-provided message. A representative real application route."""
    return {"echo": message, "environment": APP_ENV}


@app.get("/metrics", response_class=PlainTextResponse)
def metrics() -> str:
    """Expose Prometheus-format metrics consumed by the canary analysis gate."""
    total = _REQUEST_COUNT["total"]
    errors = _REQUEST_COUNT["errors"]
    lines = [
        "# HELP sample_api_requests_total Total HTTP requests handled.",
        "# TYPE sample_api_requests_total counter",
        f"sample_api_requests_total {total}",
        "# HELP sample_api_request_errors_total Total HTTP 5xx responses.",
        "# TYPE sample_api_request_errors_total counter",
        f"sample_api_request_errors_total {errors}",
        "# HELP sample_api_up Whether the service is up (always 1 when scraped).",
        "# TYPE sample_api_up gauge",
        "sample_api_up 1",
    ]
    return "\n".join(lines) + "\n"
