#!/usr/bin/env bash
# OpenTofu checks against LocalStack (free, local). NEVER runs `tofu apply`.
#
#  1. fmt + validate every root (static validation)
#  2. start LocalStack community 3.8 (pinned - newer "latest" images need a paid token)
#  3. create the state bucket with awslocal (inside the LocalStack container)
#  4. tofu init against the S3 backend in LocalStack  -> remote state configured
#  5. lock test: plant a lock object, prove plan is BLOCKED, then force-unlock
#  6. tofu plan -lock=true -> the plan acquires and releases a real S3 lock file
#
# What this proves: syntax/types, provider schema, remote-state backend init,
# lock enforcement and release, and a successful plan (no resources created).
# What it does NOT prove: that real AWS would accept the plan (IAM limits, SCPs,
# quotas) - that needs a real account. See docs/runbooks/opentofu.md.
set -euo pipefail
export MSYS_NO_PATHCONV=1

ROOT="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"  # native path for Windows tofu.exe
OUT="$ROOT/reports/opentofu"
LS_NAME="hq-localstack"
LS_IMG="localstack/localstack:3.8"
STATE_BUCKET="healthqueue-tfstate-local"
STATE_KEY="healthqueue/local/platform.tfstate"
mkdir -p "$OUT"
step() { printf '\n=== %s\n' "$*"; }

step "1/6 Static validation (fmt + validate, no backend)"
tofu -chdir="$ROOT/infra" fmt -recursive -check
for d in modules/healthqueue-platform environments/aws-production environments/localstack bootstrap; do
  tofu -chdir="$ROOT/infra/$d" init -backend=false -input=false -no-color >/dev/null
  printf '%-36s ' "$d"; tofu -chdir="$ROOT/infra/$d" validate -no-color
done

step "2/6 Start LocalStack ($LS_IMG) on 127.0.0.1:4566"
if [ "$(docker inspect -f '{{.State.Running}}' "$LS_NAME" 2>/dev/null)" != "true" ]; then
  docker rm -f "$LS_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$LS_NAME" --label project=healthqueue \
    -p 127.0.0.1:4566:4566 -e SERVICES=s3,sts,iam,kms,logs "$LS_IMG" >/dev/null
fi
for _ in $(seq 1 60); do
  curl -sf http://localhost:4566/_localstack/health >/dev/null && break; sleep 2
done
curl -s http://localhost:4566/_localstack/health | tee "$OUT/localstack-health.json"; echo

step "3/6 Create versioned state bucket (awslocal, not tofu apply)"
docker exec "$LS_NAME" awslocal s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1 \
  || docker exec "$LS_NAME" awslocal s3 mb "s3://$STATE_BUCKET"
docker exec "$LS_NAME" awslocal s3api put-bucket-versioning --bucket "$STATE_BUCKET" \
  --versioning-configuration Status=Enabled
docker exec "$LS_NAME" awslocal s3api get-bucket-versioning --bucket "$STATE_BUCKET"

ENV_DIR="$ROOT/infra/environments/localstack"
step "4/6 tofu init with the S3 remote backend (LocalStack)"
tofu -chdir="$ENV_DIR" init -reconfigure -input=false -no-color -backend-config=backend.hcl \
  | tee "$OUT/init.txt" | grep -E "backend|Successfully|Error" || true

step "5/6 Lock enforcement test"
# Simulate a teammate holding the lock by writing a lock object exactly where
# OpenTofu's S3 native locking puts it (<key>.tflock).
LOCK_ID="11111111-2222-3333-4444-555555555555"
docker exec "$LS_NAME" sh -c "printf '%s' '{\"ID\":\"$LOCK_ID\",\"Operation\":\"OperationTypeApply\",\"Info\":\"\",\"Who\":\"teammate@laptop\",\"Version\":\"1.12.6\",\"Created\":\"2026-10-17T00:00:00Z\",\"Path\":\"$STATE_BUCKET/$STATE_KEY\"}' > /tmp/lock.json && awslocal s3 cp /tmp/lock.json s3://$STATE_BUCKET/$STATE_KEY.tflock >/dev/null"
if tofu -chdir="$ENV_DIR" plan -input=false -no-color -lock-timeout=5s > "$OUT/plan-while-locked.txt" 2>&1; then
  echo "ERROR: plan ran while state was locked" >&2; exit 1
fi
grep -m1 "Error acquiring the state lock" "$OUT/plan-while-locked.txt"
echo "-> plan correctly BLOCKED while another holder had the lock"
tofu -chdir="$ENV_DIR" force-unlock -force "$LOCK_ID" -no-color | tee "$OUT/force-unlock.txt"

step "6/6 tofu plan (acquires + releases the S3 lock; creates nothing)"
tofu -chdir="$ENV_DIR" plan -input=false -no-color -lock=true -out=localstack.tfplan > "$OUT/plan.txt"
grep -E "^Plan:" "$OUT/plan.txt"
tofu -chdir="$ENV_DIR" show -no-color localstack.tfplan | grep -E '^  # ' | sed 's/^  //' > "$OUT/plan-resources.txt"
cat "$OUT/plan-resources.txt"
rm -f "$ENV_DIR/localstack.tfplan"
echo "lock objects left after plan (should be none):"
docker exec "$LS_NAME" awslocal s3 ls "s3://$STATE_BUCKET/" --recursive || true

printf '\nOpenTofu LocalStack checks passed. Evidence in reports/opentofu/\n'
echo "Reminder: no 'tofu apply' was run. LocalStack container '$LS_NAME' is still running;"
echo "stop it with: docker rm -f $LS_NAME"
