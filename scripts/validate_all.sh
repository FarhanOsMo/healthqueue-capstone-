#!/usr/bin/env bash
# Run every static/local check and save the output as evidence in reports/validation/.
# Uses the project venv (.venv) for Python tools and pinned container images for the rest.
# Docker-based checks are SKIPPED (and reported as skipped) when Docker is not running.
#
# Usage: bash scripts/validate_all.sh
set -uo pipefail
export MSYS_NO_PATHCONV=1
ROOT="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"
cd "$ROOT" || exit 1
OUT="reports/validation"
mkdir -p "$OUT"
PY=".venv/bin/python"; [ -x "$PY" ] || PY=".venv/Scripts/python"; [ -x "$PY" ] || PY="python3"
BIN="$(dirname "$PY")"
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"
DOCKER=no; docker info >/dev/null 2>&1 && DOCKER=yes

run() { # run <name> <command...>
  local name=$1; shift
  if "$@" > "$OUT/$name.txt" 2>&1; then r=PASS; else r=FAIL; fi
  printf '%-28s %s\n' "$name" "$r" | tee -a "$SUMMARY"
}
skip() { printf '%-28s SKIPPED (%s)\n' "$1" "$2" | tee -a "$SUMMARY"; }
dock() { docker run --rm -v "$ROOT:/w" -w /w "$@"; }

echo "Validation run $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$SUMMARY"
run ruff-lint        "$BIN/ruff" check .
run ruff-format      "$BIN/ruff" format --check .
run bandit           "$BIN/bandit" -r app -c pyproject.toml
run pip-audit        "$BIN/pip-audit" -r requirements.txt
run pytest           "$PY" -m pytest --cov -p no:cacheprovider
run yamllint         "$BIN/yamllint" -s .
run dora-data-repro  sh -c "'$PY' scripts/generate_dora_data.py --out '$OUT/dora-regen.csv' && cmp '$OUT/dora-regen.csv' data/dora_deployments.csv && rm '$OUT/dora-regen.csv'"
run workbooks        "$PY" scripts/verify_workbooks.py
if command -v tofu >/dev/null; then
  run tofu-fmt       tofu -chdir=infra fmt -recursive -check
  run tofu-validate  sh -c 'for d in modules/healthqueue-platform environments/aws-production environments/localstack bootstrap; do tofu -chdir=infra/$d init -backend=false -input=false -no-color >/dev/null && echo "$d: $(tofu -chdir=infra/$d validate -no-color)" || exit 1; done'
else
  skip tofu-validate "tofu not installed"
fi
if command -v kubectl >/dev/null; then
  run kustomize-build sh -c 'kubectl kustomize deploy/k8s/overlays/local > reports/k8s/rendered-local.yaml && kubectl kustomize deploy/k8s/overlays/production > reports/k8s/rendered-production.yaml && grep -c "^kind:" reports/k8s/rendered-*.yaml'
else
  skip kustomize-build "kubectl not installed"
fi
if [ "$DOCKER" = yes ]; then
  run kubeconform  dock ghcr.io/yannh/kubeconform:latest@sha256:faffaf43f95aa6425306e1ab8d6fcad72acb9049158f38e574c085ea1ec0f64e \
                     -strict -summary -kubernetes-version 1.33.0 reports/k8s/rendered-local.yaml reports/k8s/rendered-production.yaml
  run actionlint   dock rhysd/actionlint:latest@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 -color=false
  run hadolint     sh -c 'docker run --rm -i hadolint/hadolint:latest@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d < Dockerfile'
  run shellcheck   sh -c "docker run --rm -v '$ROOT:/mnt' -w /mnt koalaman/shellcheck:stable -S warning scripts/*.sh"
  run promtool     sh -c "docker run --rm -v '$ROOT:/w' -w /w --entrypoint promtool prom/prometheus:v3.15.0 check rules observability/prometheus/slo-rules.yaml && docker run --rm -v '$ROOT:/w' -w /w --entrypoint promtool prom/prometheus:v3.15.0 test rules tests/prometheus/slo-rules.test.yaml"
  run trivy-config dock -v hq-trivy-cache:/root/.cache/trivy aquasec/trivy:0.76.0@sha256:2416d1f74045b57274df1a340eee6b510cacd73c66a6ccb8da092b117eb7d222 \
                     config --quiet --skip-dirs .venv --skip-dirs .local --skip-dirs "**/.terraform" --severity HIGH,CRITICAL --exit-code 1 .
  # Scan exactly the files that would be committed (git-ignored local secrets such as the
  # throwaway cosign key in .local/ are expected on disk and are never committed).
  SNAP="$(mktemp -d)"
  git ls-files --cached --others --exclude-standard -z | xargs -0 -I{} cp --parents {} "$SNAP/"
  run secret-scan  docker run --rm -v "$(cd "$SNAP" && (pwd -W 2>/dev/null || pwd)):/scan" -v "$ROOT/.gitleaks.toml:/cfg.toml" \
                     zricethezav/gitleaks:v8.30.1 dir /scan --config /cfg.toml --no-banner --redact -v --exit-code 1
  rm -rf "$SNAP"
else
  for c in kubeconform actionlint hadolint shellcheck promtool trivy-config secret-scan; do skip "$c" "Docker not running"; done
fi
echo "Logs: $OUT/  (summary: $SUMMARY)"
grep -q FAIL "$SUMMARY" && exit 1 || exit 0
