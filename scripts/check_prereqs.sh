#!/usr/bin/env bash
# Read-only environment check (macOS / Linux / Git Bash on Windows).
# Tells you which of the three paths your computer can run:
#   Path A  Python only            -> API, tests, workbooks
#   Path B  + Docker               -> container build, Compose, Trivy/Syft/Cosign, LocalStack
#   Path C  + kind + kubectl       -> full Kubernetes + Argo CD GitOps demo
# Nothing is installed or changed. No secrets are printed.
set -u
ok=0
have() { command -v "$1" >/dev/null 2>&1; }
row() { printf '  %-10s %-8s %s\n' "$1" "$2" "$3"; }

echo "HealthQueue prerequisite check ($(uname -s) $(uname -m))"
echo
echo "Tools:"
for spec in "python:python3 python" "docker:docker" "kind:kind" "kubectl:kubectl" "tofu:tofu" "git:git"; do
  name="${spec%%:*}"; found=""
  for cand in ${spec#*:}; do have "$cand" && { found="$cand"; break; }; done
  if [ -n "$found" ]; then
    case "$name" in
      python) v="$($found --version 2>&1)";;
      docker) v="$(docker --version 2>&1)";;
      kind) v="$(kind version 2>&1)";;
      kubectl) v="$(kubectl version --client 2>&1 | head -1)";;
      tofu) v="$(tofu version 2>&1 | head -1)";;
      git) v="$(git --version)";;
    esac
    row "$name" "found" "$v"
  else
    row "$name" "MISSING" "see docs/COST_AND_PREREQUISITES.md for the official free installer"
  fi
done

PY="$(command -v python3 || command -v python || true)"
if [ -n "$PY" ] && "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)'; then
  PATH_A=yes
else
  PATH_A=no; echo "  ! Python 3.12+ is required (3.13 recommended)."
fi

DOCKER_UP=no
if have docker && docker info >/dev/null 2>&1; then
  DOCKER_UP=yes
  mem=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
  cpus=$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)
  echo
  echo "Docker engine: running, ${cpus} CPUs, $((mem / 1024 / 1024 / 1024)) GiB memory available to containers"
  [ "$mem" -lt 4000000000 ] && echo "  ! Less than 4 GiB for Docker: the kind + Argo CD path may be slow or fail."
elif have docker; then
  echo; echo "Docker is installed but the engine is NOT running (start Docker Desktop / the docker service)."
fi

echo
echo "Free disk in this folder: $(df -h . 2>/dev/null | awk 'NR==2{print $4}') (need ~6 GB for images on the full path)"
echo
echo "What you can run:"
echo "  Path A (Python: API + tests + workbooks) ........ $PATH_A"
if [ "$DOCKER_UP" = yes ]; then echo "  Path B (Docker: build, scan, sign, Compose) ..... yes"; else echo "  Path B (Docker) ................................. no"; ok=1; fi
if [ "$DOCKER_UP" = yes ] && have kind && have kubectl; then
  echo "  Path C (kind + Argo CD GitOps) .................. yes"
else
  echo "  Path C (kind + Argo CD GitOps) .................. no (needs Docker running + kind + kubectl)"
fi
if have tofu; then echo "  OpenTofu validate/plan ......................... yes"; else echo "  OpenTofu validate/plan ......................... no (install OpenTofu)"; fi
echo
echo "Reminder: the default workflow needs NO cloud account and NO credentials."
exit $ok
