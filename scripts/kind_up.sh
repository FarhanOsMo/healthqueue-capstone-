#!/usr/bin/env bash
# Bring up the local GitOps platform for HealthQueue (free, local):
#   - a DEDICATED kind cluster "healthqueue" (other clusters are untouched)
#   - nodes trust the local registry kind-registry:5000
#   - Argo CD (pinned version) in namespace argocd
#   - Gitea (in-cluster Git server) in namespace gitops-local
#   - the database Secret, generated randomly and never written to Git
#
# The kubeconfig is written to .kube/healthqueue.kubeconfig, so your default
# kubectl context does not change. Use:  export KUBECONFIG=.kube/healthqueue.kubeconfig
#
# Requirements: Docker (running), kind, kubectl. ~3 GB free RAM for Docker.
set -euo pipefail
export MSYS_NO_PATHCONV=1

ARGOCD_VERSION="v3.5.5"
CLUSTER="healthqueue"
ROOT="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"  # native path (Windows kind/kubectl need C:/...)
cd "$ROOT"
mkdir -p .kube .local
export KUBECONFIG="$ROOT/.kube/healthqueue.kubeconfig"
step() { printf '\n=== %s\n' "$*"; }

for tool in docker kind kubectl; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool (see docs/COST_AND_PREREQUISITES.md)"; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "Docker is not running. Start Docker Desktop / the Docker daemon first."; exit 1; }

step "1/6 kind cluster '$CLUSTER'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "cluster exists"
  kind export kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG" >/dev/null
else
  kind create cluster --config deploy/kind/cluster.yaml --kubeconfig "$KUBECONFIG" --wait 120s
fi
kubectl cluster-info | head -1

step "2/6 Local registry kind-registry:5000 (trusted over plain HTTP by the nodes only)"
if [ "$(docker inspect -f '{{.State.Running}}' kind-registry 2>/dev/null)" != "true" ]; then
  docker rm -f kind-registry >/dev/null 2>&1 || true
  docker run -d --restart=unless-stopped --name kind-registry --label project=healthqueue \
    -p 127.0.0.1:5001:5000 registry:3 >/dev/null
fi
docker network connect kind kind-registry 2>/dev/null || true
for node in $(kind get nodes --name "$CLUSTER"); do
  docker exec "$node" mkdir -p /etc/containerd/certs.d/kind-registry:5000
  printf '[host."http://kind-registry:5000"]\n' | docker exec -i "$node" cp /dev/stdin /etc/containerd/certs.d/kind-registry:5000/hosts.toml
done
echo "registry configured on nodes"

step "3/6 Argo CD $ARGOCD_VERSION"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# --server-side: the Argo CD CRDs are too large for client-side apply annotations.
kubectl apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" >/dev/null
# Faster demo feedback: poll Git every 30 s instead of the default 120 s.
kubectl -n argocd patch configmap argocd-cm --type merge -p '{"data":{"timeout.reconciliation":"30s"}}' >/dev/null
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
kubectl -n argocd rollout restart statefulset/argocd-application-controller >/dev/null
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

step "4/6 Gitea (local Git server for Argo CD)"
kubectl apply -f deploy/gitops-local/gitea.yaml >/dev/null
kubectl -n gitops-local rollout status deploy/gitea --timeout=300s
if [ ! -f .local/gitea-admin-password ]; then
  head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > .local/gitea-admin-password
fi
GITEA_PW="$(cat .local/gitea-admin-password)"
kubectl -n gitops-local exec deploy/gitea -- gitea admin user create --username hq-admin \
  --password "$GITEA_PW" --email admin@healthqueue.local --admin --must-change-password=false \
  >/dev/null 2>&1 || echo "gitea admin user already exists"

step "5/6 Namespace + database Secret (random, not in Git)"
kubectl apply -f deploy/k8s/base/namespace.yaml >/dev/null
if ! kubectl -n healthqueue get secret healthqueue-db >/dev/null 2>&1; then
  kubectl -n healthqueue create secret generic healthqueue-db \
    --from-literal=POSTGRES_PASSWORD="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')" >/dev/null
  echo "secret created"
else
  echo "secret already exists"
fi

step "6/6 Argo CD project (guard rails)"
kubectl apply -f deploy/argocd/project.yaml

cat <<EOF

Platform ready.
  export KUBECONFIG="$KUBECONFIG"
Next: bash scripts/gitops_publish.sh     # push manifests to Gitea + register the Argo CD app
Argo CD UI:  kubectl -n argocd port-forward svc/argocd-server 8443:443
             user: admin  password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
Gitea UI:    kubectl -n gitops-local port-forward svc/gitea-http 3000:3000   (user hq-admin, password in .local/gitea-admin-password)
EOF
