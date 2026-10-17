# ADR-0003: OpenTofu module + per-environment roots, S3 remote state with native locking, LocalStack for free testing

* Status: Accepted (2026-10-17)

## Context

The assignment requires OpenTofu provisioning at least two cloud resources with state management. HealthQueue
has a $0 budget for this phase, so no real AWS resources may be created, yet the configuration must be
production-credible and testable.

## Decision

* **One reusable module** (`infra/modules/healthqueue-platform`) with 4 resource groups: KMS key (rotation on),
  S3 evidence bucket (versioned, SSE-KMS, public access blocked, ACLs disabled, TLS-only policy, lifecycle), CloudWatch
  log group (KMS, retention), IAM role for GitHub OIDC (write-only to `releases/*`).
* **Separate root per environment**: `environments/aws-production` (real provider, `allowed_account_ids`, default
  tags) and `environments/localstack` (every endpoint forced to localhost). Local test config never mixes with the
  real one.
* **Remote state in S3 with `use_lockfile = true`** (OpenTofu ≥ 1.10 native S3 locking via conditional writes - no
  DynamoDB table). State bucket created once by `infra/bootstrap` (local state, `prevent_destroy`, versioned,
  CMK-encrypted, TLS-only).
* **Never `tofu apply` from this project.** Validation ladder: `fmt` -> `validate` -> Trivy IaC scan -> `plan` against
  LocalStack (including remote-state init and a lock-contention test). Real `plan`/`apply` is a manual, reviewed
  procedure ([runbooks/opentofu.md](../runbooks/opentofu.md)).
* Provider versions pinned with a lock file containing checksums for linux/darwin/windows.

## Alternatives considered

* *DynamoDB lock table* - the classic approach, now deprecated in favour of S3 native locking; one less resource.
* *Terraform* - OpenTofu is the open-source (MPL) fork the course uses; syntax is compatible.
* *Provision the EKS cluster and RDS too* - realistic but expensive and slow; out of scope for a $0 build. The
  module boundary leaves room to add them.
* *Workspaces instead of separate roots* - workspaces share one backend config and make it easy to run against the
  wrong environment; separate roots are explicit.

## Consequences

* + Static validation, a successful plan and real lock enforcement are proven for free.
* − LocalStack is an emulator: it does not enforce IAM, SCPs or quotas. A plan that passes against LocalStack can
  still fail on AWS. This gap is stated in every report.
* − The production root has never been planned against a real account.
