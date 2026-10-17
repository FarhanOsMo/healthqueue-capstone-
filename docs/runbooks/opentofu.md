# OpenTofu: setup, validation, planning, state protection and recovery

> This project **never runs `tofu apply` or `tofu destroy`.** Everything below up to section 5 is free and local.

## Layout

```
infra/
  modules/healthqueue-platform/   KMS key, S3 evidence bucket (+ versioning, SSE-KMS, public-access block,
                                  ownership, TLS-only policy, lifecycle), CloudWatch log group, GitHub OIDC role
  environments/aws-production/    real AWS root: backend "s3" (partial config), allowed_account_ids, default tags
  environments/localstack/        free test root: same module, all endpoints -> http://localhost:4566
  bootstrap/                      one-time state bucket (local state, prevent_destroy, CMK, versioning)
```

## 1. Static validation (no credentials, no network after provider download)

```bash
tofu -chdir=infra fmt -recursive -check
for d in modules/healthqueue-platform environments/aws-production environments/localstack bootstrap; do
  tofu -chdir=infra/$d init -backend=false -input=false && tofu -chdir=infra/$d validate
done
```

IaC security scan (Trivy, container image - nothing to install):

```bash
docker run --rm -v "$PWD:/work" -w /work aquasec/trivy:0.76.0 config --skip-dirs "**/.terraform" \
  --severity HIGH,CRITICAL --exit-code 1 .
```

## 2. Plan + remote state + locking against LocalStack (free)

One command does it all: `bash scripts/tofu_localstack_check.sh`. It:

1. starts `localstack/localstack:3.8` (community, no token) as container `hq-localstack` on 127.0.0.1:4566;
2. creates a **versioned** state bucket with `awslocal` (not with `tofu apply`);
3. `tofu init -backend-config=backend.hcl` -> the S3 backend in LocalStack (remote state configured);
4. **lock test** - writes a lock object as if a teammate were running `apply`, proves `plan` is **blocked**
   (`Error acquiring the state lock`, HTTP 412 from the conditional write), then `tofu force-unlock`;
5. `tofu plan -lock=true` -> `Plan: 13 to add, 0 to change, 0 to destroy` and confirms no lock file is left behind.

Evidence: `reports/opentofu/` (`init.txt`, `plan-while-locked.txt`, `force-unlock.txt`, `plan.txt`,
`plan-resources.txt`). Stop LocalStack afterwards: `docker rm -f hq-localstack`.

**What each level proves**

| Level | Proves | Does not prove |
|---|---|---|
| `fmt` / `validate` | syntax, types, references, provider schema | anything about AWS |
| Trivy config | no known HIGH/CRITICAL misconfigurations | business logic of policies |
| `plan` vs LocalStack | the configuration produces a coherent plan; remote state init; lock enforcement | IAM permissions, SCPs, quotas, real API validation on AWS |
| real `plan` on AWS | AWS accepts the read side; diff vs real state | that `apply` will succeed (create-time errors) |
| real `apply` | resources exist | - **not done in this project** |

## 3. State protection

* **Remote, encrypted, versioned** S3 state; `use_lockfile = true` prevents two writers.
* State bucket: `prevent_destroy`, public access blocked, TLS-only, ACLs disabled, customer-managed KMS key.
* State files are **git-ignored** (`*.tfstate*`); state can contain secrets.
* Access: only the platform admins' role can read/write the state prefix (bucket policy in production).
* CI never writes state; it only runs `plan` against LocalStack.

## 4. Recovery procedures

| Problem | Recovery |
|---|---|
| Stale lock after a crashed run | Confirm nobody is running (ask in channel), then `tofu force-unlock <LOCK_ID>` (ID is in the error message). Tested in step 4 above. |
| Corrupted / bad state written | S3 versioning: list versions `aws s3api list-object-versions --bucket <b> --prefix <key>`, download the previous version, `tofu state push` it (after review). |
| Resource deleted outside OpenTofu | `tofu plan` shows it will be recreated; or `tofu state rm` if intentionally removed. |
| Resource created outside OpenTofu | `tofu import` (or an `import {}` block) then plan to confirm no diff. |
| Lost bootstrap state | The bucket still exists: `tofu import aws_s3_bucket.state healthqueue-tfstate-<account>` (+ the sub-resources). |

## 5. Real AWS (manual, reviewed, NOT part of this project)

Only with explicit approval and an account owner present:

```bash
cd infra/bootstrap && tofu init && tofu plan -var aws_account_id=<id>          # review, then apply once (admin)
cd ../environments/aws-production
cp backend.hcl.example backend.hcl && cp production.tfvars.example production.tfvars   # fill in values
tofu init -backend-config=backend.hcl
tofu plan -var-file=production.tfvars -out=tfplan                             # review in a PR
# tofu apply tfplan   <- only after approval; costs money (KMS key ~$1/month, S3/CloudWatch usage)
```
