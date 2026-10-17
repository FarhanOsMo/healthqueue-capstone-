#!/usr/bin/env bash
# Publish the current working tree to the in-cluster Gitea repository and make
# sure the Argo CD Application exists. Argo CD then pulls from Git and syncs.
#
# Your own repository is NOT committed to or pushed: a snapshot of the working
# tree is committed inside .local/gitops-worktree (git-ignored) and pushed to
# the local Gitea server only. Nothing leaves your machine.
#
# Usage: bash scripts/gitops_publish.sh ["commit message"]
set -euo pipefail
export MSYS_NO_PATHCONV=1

ROOT="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"  # native path (Windows kind/kubectl need C:/...)
cd "$ROOT"
export KUBECONFIG="$ROOT/.kube/healthqueue.kubeconfig"
MSG="${1:-Publish HealthQueue manifests $(date -u +%Y-%m-%dT%H:%M:%SZ)}"
WT=".local/gitops-worktree"
PORT=13000
GITEA_PW="$(cat .local/gitea-admin-password)"
REMOTE="http://hq-admin:${GITEA_PW}@localhost:${PORT}/hq-admin/healthqueue-capstone.git"

# 1. Snapshot the tracked project files (respecting .gitignore) into the worktree.
if [ ! -d "$WT/.git" ]; then
  git init -q -b main "$WT"
  git -C "$WT" config user.name "HealthQueue Local GitOps"
  git -C "$WT" config user.email "gitops@healthqueue.local"
fi
find "$WT" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
git ls-files --cached --others --exclude-standard -z \
  | grep -zv '^\.local/' | xargs -0 -I{} cp --parents {} "$WT/"
git -C "$WT" add -A
if git -C "$WT" diff --cached --quiet; then
  echo "No changes since last publish."
else
  git -C "$WT" commit -q -m "$MSG"
  echo "Committed: $(git -C "$WT" log -1 --format='%h %s')"
fi

# 2. Push to Gitea through a temporary port-forward.
kubectl -n gitops-local port-forward svc/gitea-http "${PORT}:3000" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
for _ in $(seq 1 20); do curl -sf "http://localhost:${PORT}/api/healthz" >/dev/null && break; sleep 1; done
git -C "$WT" push -q --force "$REMOTE" main
echo "Pushed $(git -C "$WT" rev-parse --short HEAD) to Gitea"

# 3. Register the Argo CD Application (idempotent). This is the one-time
#    bootstrap; from here on Argo CD - not kubectl - applies the app manifests.
kubectl apply -f deploy/argocd/application-local.yaml >/dev/null
kubectl -n argocd annotate application healthqueue-local argocd.argoproj.io/refresh=normal --overwrite >/dev/null

# 4. Wait for Argo CD to sync the new revision and report health.
TARGET="$(git -C "$WT" rev-parse HEAD)"
echo "Waiting for Argo CD to sync revision ${TARGET:0:7} ..."
for _ in $(seq 1 90); do
  REV="$(kubectl -n argocd get application healthqueue-local -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
  SYNC="$(kubectl -n argocd get application healthqueue-local -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  HEALTH="$(kubectl -n argocd get application healthqueue-local -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  if [ "$REV" = "$TARGET" ] && [ "$SYNC" = "Synced" ] && [ "$HEALTH" = "Healthy" ]; then
    echo "Argo CD: revision ${REV:0:7}  sync=${SYNC}  health=${HEALTH}"
    exit 0
  fi
  sleep 5
done
echo "Timed out. Current: revision=${REV:0:7} sync=${SYNC} health=${HEALTH}" >&2
kubectl -n argocd get application healthqueue-local -o jsonpath='{.status.conditions}' >&2 || true
exit 1
