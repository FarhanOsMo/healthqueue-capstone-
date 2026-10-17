#!/usr/bin/env bash
# Remove ONLY what this project created on your machine:
#   - kind cluster "healthqueue" (other kind clusters are not touched)
#   - containers labelled project=healthqueue (kind-registry, hq-localstack)
#   - the Docker Compose stack "healthqueue" and its volume
#   - the Trivy cache volume, local .kube/ and the GitOps worktree
# Keeps: your source code, reports/, and .local/cosign keys (use --all to delete .local too).
#
# Usage: bash scripts/cleanup.sh [--yes] [--all]
set -euo pipefail
YES=no; ALL=no
for a in "$@"; do
  case "$a" in --yes|-y) YES=yes;; --all) ALL=yes;; *) echo "unknown option $a"; exit 2;; esac
done
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "This will remove:"
kind get clusters 2>/dev/null | grep -qx healthqueue && echo "  - kind cluster: healthqueue"
docker ps -a --filter label=project=healthqueue --format '  - container: {{.Names}} ({{.Image}})' 2>/dev/null || true
docker compose ls -q 2>/dev/null | grep -qx healthqueue && echo "  - compose project: healthqueue (+ volume)"
docker volume inspect hq-trivy-cache >/dev/null 2>&1 && echo "  - volume: hq-trivy-cache"
echo "  - folders: .kube/ .local/gitops-worktree/ data/*.db$([ "$ALL" = yes ] && echo ' .local/ (including the local cosign test key)')"
if [ "$YES" != yes ]; then
  read -r -p "Proceed? [y/N] " ans
  [ "$ans" = y ] || [ "$ans" = Y ] || { echo "Aborted."; exit 0; }
fi

kind get clusters 2>/dev/null | grep -qx healthqueue && kind delete cluster --name healthqueue --kubeconfig "$(pwd -W 2>/dev/null || pwd)/.kube/healthqueue.kubeconfig"
for c in $(docker ps -a --filter label=project=healthqueue --format '{{.Names}}'); do docker rm -f "$c" >/dev/null && echo "removed container $c"; done
docker compose -p healthqueue down -v >/dev/null 2>&1 || true
docker volume rm hq-trivy-cache >/dev/null 2>&1 || true
docker network rm hq-supplychain >/dev/null 2>&1 || true
rm -rf .kube .local/gitops-worktree data/*.db data/*.db-*
[ "$ALL" = yes ] && rm -rf .local
echo "Cleanup complete. Your default kubectl context and other clusters were not changed."
