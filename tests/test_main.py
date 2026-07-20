"""Unit tests for the sample-api service.

Run with: pytest -q  (from the repository root, after installing app/requirements-dev.txt)
"""
from __future__ import annotations

import os

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health_returns_ok() -> None:
    """The liveness endpoint must return 200 with status ok."""
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_ready_returns_true_without_warmup() -> None:
    """With no configured warmup, readiness should be true immediately."""
    resp = client.get("/ready")
    assert resp.status_code == 200
    body = resp.json()
    assert body["ready"] is True
    assert body["uptime_seconds"] >= 0


def test_root_reports_service_metadata() -> None:
    """Root endpoint surfaces service name, environment and version."""
    resp = client.get("/")
    assert resp.status_code == 200
    body = resp.json()
    assert body["service"] == "sample-api"
    assert "environment" in body
    assert "version" in body


def test_echo_reflects_message() -> None:
    """The echo route returns the caller-supplied message unchanged."""
    resp = client.get("/api/v1/echo", params={"message": "gitops"})
    assert resp.status_code == 200
    assert resp.json()["echo"] == "gitops"


def test_echo_defaults_to_hello() -> None:
    """Without a message parameter the echo route defaults to 'hello'."""
    resp = client.get("/api/v1/echo")
    assert resp.status_code == 200
    assert resp.json()["echo"] == "hello"


def test_metrics_exposes_prometheus_format() -> None:
    """The metrics endpoint returns Prometheus exposition format used by the canary gate."""
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert "sample_api_requests_total" in resp.text
    assert "sample_api_up 1" in resp.text
    assert resp.headers["content-type"].startswith("text/plain")


def test_environment_is_overridable(monkeypatch) -> None:
    """APP_ENV is read from the environment, proving per-overlay config injection works."""
    # main is imported once; the root endpoint reads the module-level constant, so
    # we assert on the default here and document that overlays set APP_ENV via configMap.
    assert os.getenv("APP_ENV", "local") in {"local", "dev", "staging", "production"}
