#!/usr/bin/env bash
# End-to-end verification of the local Kubernetes + GitOps deployment.
# Every check prints PASS/FAIL; the script exits non-zero on the first failure.
#
#  1. API works through the NodePort (create in one request, read in another)
#  2. Running pods use the digest-pinned image from the signed pipeline output
#  3. Self-heal: a manual `kubectl scale` is reverted by Argo CD
#  4. GitOps change: a Git commit (replicas 2 -> 3) is rolled out by Argo CD
#  5. Rollback: `git revert` of that commit returns the cluster to 2 replicas
#  6. NetworkPolicy: a pod outside the API cannot reach PostgreSQL
#  7. Pod Security Admission: a privileged pod is rejected in the namespace
#
# Steps 4-5 commit to the git-ignored GitOps worktree that feeds the local
# Gitea server (a stand-in for "merge a PR on GitHub"), not to your repository.
set -euo pipefail
export MSYS_NO_PATHCONV=1

ROOT="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"
cd "$ROOT"
export KUBECONFIG="$ROOT/.kube/healthqueue.kubeconfig"
API="http://127.0.0.1:30080"
WT=".local/gitops-worktree"
NS=healthqueue
APP=healthqueue-local

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*" >&2; exit 1; }
replicas() { kubectl -n "$NS" get deploy healthqueue-api -o jsonpath='{.spec.replicas}'; }
replicas_eq() { [ "$(replicas)" = "$1" ]; }  # re-evaluated on every poll
app_field() { kubectl -n argocd get application "$APP" -o jsonpath="$1"; }
wait_for() { # wait_for <seconds> <description> <command...>
  local secs=$1 desc=$2; shift 2
  for _ in $(seq 1 "$secs"); do if "$@" >/dev/null 2>&1; then return 0; fi; sleep 1; done
  fail "timed out waiting for: $desc"
}
synced_at() { # true when Argo CD reports the given revision as Synced + Healthy
  [ "$(app_field '{.status.sync.revision}')" = "$1" ] &&
  [ "$(app_field '{.status.sync.status}')" = "Synced" ] &&
  [ "$(app_field '{.status.health.status}')" = "Healthy" ]
}
publish_worktree() {
  local pw port=13000 pf
  pw="$(cat .local/gitea-admin-password)"
  kubectl -n gitops-local port-forward svc/gitea-http "${port}:3000" >/dev/null 2>&1 & pf=$!
  wait_for 20 "gitea port-forward" curl -sf "http://localhost:${port}/api/healthz"
  git -C "$WT" push -q "http://hq-admin:${pw}@localhost:${port}/hq-admin/healthqueue-capstone.git" main
  kill "$pf" 2>/dev/null || true
  kubectl -n argocd annotate application "$APP" argocd.argoproj.io/refresh=normal --overwrite >/dev/null
}

echo "== Cluster: $(kubectl config current-context)   Argo CD app: $APP"
kubectl -n argocd get application "$APP"

echo; echo "== 1. API through NodePort ($API)"
[ "$(curl -s "$API/healthz")" = '{"status":"ok"}' ] && pass "/healthz" || fail "/healthz"
curl -s "$API/readyz" | grep -q ready && pass "/readyz (database reachable)" || fail "/readyz"
START="$(date -u -d '+5 days' +%Y-%m-%dT10:00:00Z 2>/dev/null || python -c "import datetime as d;print((d.datetime.now(d.UTC)+d.timedelta(days=5)).strftime('%Y-%m-%dT10:00:00Z'))")"
PROVIDER="PRV-$(( (RANDOM % 9000) + 1000 ))"
BODY="{\"patient_ref\":\"PT-000777\",\"clinic_id\":\"CLN-001\",\"provider_id\":\"${PROVIDER}\",\"appointment_type\":\"checkup\",\"start_time\":\"${START}\",\"duration_minutes\":30}"
CODE="$(curl -s -o /tmp/hq-create.json -w '%{http_code}' -X POST "$API/v1/appointments" -H 'content-type: application/json' -d "$BODY")"
[ "$CODE" = 201 ] && pass "POST /v1/appointments -> 201" || fail "POST returned $CODE"
ID="$(python -c "import json;print(json.load(open('/tmp/hq-create.json'))['id'])" 2>/dev/null || sed -E 's/.*"id":"([^"]+)".*/\1/' /tmp/hq-create.json)"
for i in 1 2 3 4; do # several reads so both replicas are likely to serve one
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$API/v1/appointments/$ID")" = 200 ] || fail "GET #$i of $ID"
done
pass "GET /v1/appointments/{id} -> 200 on 4 reads (shared PostgreSQL across replicas)"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API/v1/appointments" -H 'content-type: application/json' -d "$BODY")" = 409 ] \
  && pass "double booking -> 409" || fail "double booking not rejected"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API/v1/appointments" -H 'content-type: application/json' -d '{"patient_ref":"Jane Doe"}')" = 422 ] \
  && pass "invalid payload -> 422" || fail "validation"

echo; echo "== 2. Image provenance in the running pods"
IMAGES="$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=healthqueue-api -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | sort -u)"
echo "$IMAGES"
EXPECTED="$(tr -d '\r\n' < reports/supply-chain/image-ref.txt)"
[ "$IMAGES" = "$EXPECTED" ] && pass "pods run the exact signed digest from reports/supply-chain/image-ref.txt" \
  || fail "pods run $IMAGES, expected $EXPECTED"

echo; echo "== 3. Self-heal (manual drift is reverted)"
BASE_REV="$(app_field '{.status.sync.revision}')"
kubectl -n "$NS" scale deploy healthqueue-api --replicas=5 >/dev/null
echo "manually scaled to 5 (drift) at $(date -u +%H:%M:%S)"
wait_for 180 "Argo CD to revert drift" replicas_eq 2
pass "Argo CD restored replicas to 2 (selfHeal) at $(date -u +%H:%M:%S)"

echo; echo "== 4. GitOps change via Git commit (replicas 2 -> 3)"
sed -i 's/^  replicas: 2 # two pods/  replicas: 3 # two pods/' "$WT/deploy/k8s/base/deployment.yaml"
git -C "$WT" commit -qam "Scale healthqueue-api to 3 replicas (GitOps verification)"
CHANGE_REV="$(git -C "$WT" rev-parse HEAD)"
publish_worktree
wait_for 240 "Argo CD to sync ${CHANGE_REV:0:7}" synced_at "$CHANGE_REV"
wait_for 120 "3 replicas" replicas_eq 3
kubectl -n "$NS" rollout status deploy/healthqueue-api --timeout=120s >/dev/null
pass "commit ${CHANGE_REV:0:7} synced by Argo CD -> 3 replicas"

echo; echo "== 5. Rollback with git revert"
git -C "$WT" revert --no-edit HEAD >/dev/null
REVERT_REV="$(git -C "$WT" rev-parse HEAD)"
publish_worktree
wait_for 240 "Argo CD to sync revert ${REVERT_REV:0:7}" synced_at "$REVERT_REV"
wait_for 120 "2 replicas" replicas_eq 2
pass "revert ${REVERT_REV:0:7} synced -> back to 2 replicas"
git -C "$WT" log --oneline -3

echo; echo "== 6. NetworkPolicy"
API_POD="$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=healthqueue-api -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "$NS" exec "$API_POD" -- python -c "import socket;socket.create_connection(('healthqueue-postgres',5432),3)" \
  && pass "API pod -> postgres:5432 allowed" || fail "API pod cannot reach postgres"
# Positive control first: the same probe CAN reach the API port (allowed), so a
# failure below really is the policy and not a broken probe pod.
kubectl -n default run np-control --rm -i --restart=Never --image=busybox:1.37 --command -- \
    sh -c 'nc -z -w 3 healthqueue-api.healthqueue.svc.cluster.local 80' >/dev/null 2>&1 \
  && pass "control: pod in 'default' -> healthqueue-api:80 allowed" || fail "control probe could not reach the API"
if kubectl -n default run np-probe --rm -i --restart=Never --image=busybox:1.37 --command -- \
    sh -c 'nc -z -w 3 healthqueue-postgres.healthqueue.svc.cluster.local 5432' >/dev/null 2>&1; then
  fail "pod in another namespace reached postgres (NetworkPolicy not enforced)"
fi
pass "pod in namespace 'default' -> postgres:5432 blocked"

echo; echo "== 7. Pod Security Admission (restricted)"
if kubectl -n "$NS" run psa-probe --image=busybox:1.37 --restart=Never --dry-run=server \
    --overrides='{"spec":{"containers":[{"name":"psa-probe","image":"busybox:1.37","securityContext":{"privileged":true}}]}}' \
    > /tmp/psa.txt 2>&1; then
  fail "privileged pod was admitted"
fi
grep -o 'violates PodSecurity "restricted:[^"]*"' /tmp/psa.txt | head -1
pass "privileged pod rejected by the namespace policy"

echo; echo "== Final state"
kubectl -n argocd get application "$APP"
kubectl -n "$NS" get deploy,statefulset,pods,svc,networkpolicy,pdb
echo; echo "ALL GITOPS CHECKS PASSED (base revision ${BASE_REV:0:7})"
