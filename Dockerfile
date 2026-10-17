# syntax=docker/dockerfile:1
# HealthQueue API container image.
#  - Base image pinned by digest (immutable) - tag kept for readability.
#  - Multi-stage: build tools stay in the builder, runtime gets only the venv + app.
#  - pip is removed from the runtime image: it is a build tool, and its vendored
#    copies of urllib3/msgpack were the only fixable HIGH findings Trivy reported.
#  - Runs as a fixed non-root UID so Kubernetes `runAsNonRoot` can verify it.
ARG PYTHON_IMAGE=python:3.13-slim@sha256:70729b46c69b4f1e97c4822c1af3df53a1476cf5ddc6c087c0c10bc3a5678c2f

FROM ${PYTHON_IMAGE} AS builder
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
WORKDIR /build
COPY requirements.txt .
RUN pip install --require-virtualenv -r requirements.txt \
 && pip uninstall --yes pip

FROM ${PYTHON_IMAGE} AS runtime
ARG APP_VERSION=0.1.1
LABEL org.opencontainers.image.title="healthqueue-api" \
      org.opencontainers.image.description="HealthQueue appointment scheduling API (capstone reference)" \
      org.opencontainers.image.source="https://github.com/FarhanOsMo/healthqueue-capstone-" \
      org.opencontainers.image.version="${APP_VERSION}"
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    APP_VERSION=${APP_VERSION} \
    DATABASE_URL=sqlite:////data/healthqueue.db
RUN rm -rf /usr/local/lib/python3.13/site-packages/pip /usr/local/lib/python3.13/site-packages/pip-*.dist-info \
           /usr/local/lib/python3.13/ensurepip /usr/local/bin/pip /usr/local/bin/pip3* \
 && groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app \
 && mkdir /data && chown app:app /data
WORKDIR /srv
COPY --from=builder /opt/venv /opt/venv
COPY app ./app
USER 10001:10001
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=2).status == 200 else 1)"]
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--no-server-header"]
