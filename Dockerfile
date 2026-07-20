# syntax=docker/dockerfile:1
#
# Multi-stage build for the sample-api workload.
#   stage 1 (builder): install dependencies into an isolated prefix
#   stage 2 (runtime):  copy only what is needed, run as a non-root user
#
# The image is intentionally distroless-adjacent: slim base, no build tools in the
# final layer, a dedicated unprivileged user, and a pinned Python version so the
# same tag always produces the same behaviour (no :latest anywhere).

# ---------- builder ----------
FROM python:3.12-slim AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

COPY app/requirements.txt ./requirements.txt

# Install into a relocatable prefix we can copy wholesale into the runtime stage.
RUN pip install --prefix=/install -r requirements.txt

# ---------- runtime ----------
FROM python:3.12-slim AS runtime

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    APP_ENV=local \
    APP_VERSION=0.1.0

# Create a non-root user and group. Kubernetes securityContext also enforces this,
# but baking it into the image means the container is safe to run anywhere.
RUN groupadd --system --gid 10001 appuser \
    && useradd --system --uid 10001 --gid appuser --home-dir /app --shell /usr/sbin/nologin appuser

WORKDIR /app

# Bring in the pre-built dependencies and the application source only.
COPY --from=builder /install /usr/local
COPY app/ /app/app/

USER 10001

EXPOSE 8000

# Liveness/readiness are also defined on the Kubernetes side; this HEALTHCHECK
# helps `docker compose` and plain `docker run` report container health locally.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health').status==200 else 1)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
