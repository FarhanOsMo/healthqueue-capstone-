# ADR-0006: Zero-cost local platform - dedicated kind cluster, local registry, in-cluster Git server

* Status: Accepted (2026-10-17)

## Context

The full CI -> image -> GitOps -> Kubernetes path must be demonstrable without paying for a cluster or a registry,
without publishing the repository before the author approves, and without disturbing other local clusters (the
author's machine already runs a `kind-shipfast` cluster with Argo CD for another project).

## Decision

* A **dedicated kind cluster `healthqueue`** with its own kubeconfig file (`.kube/healthqueue.kubeconfig`) - the
  default kubectl context and other clusters are never touched; cleanup is one command.
* A **local OCI registry** (`registry:3` container `kind-registry`, port 127.0.0.1:5001) that the kind node trusts via
  containerd `certs.d`. The same push-by-digest, sign, attest and verify flow as GHCR.
* An **in-cluster Gitea** as the Git source for Argo CD. `scripts/gitops_publish.sh` snapshots the working tree into a
  git-ignored worktree, commits there and pushes to Gitea - the author's real repository is not committed to or pushed.
* Tools (Trivy, Syft, Cosign, kubeconform, actionlint, hadolint, promtool, LocalStack) run from **pinned container
  images**, so other computers need only Docker.

## Alternatives considered

* *Reuse the existing `kind-shipfast` cluster and its Argo CD* - fewer resources, but changes another project's cluster.
* *`kind load docker-image` instead of a registry* - no digest-based pulls and no place to store signatures.
* *Point Argo CD at GitHub* - requires pushing first; kept as `deploy/argocd/application-github.yaml` for after approval.

## Consequences

* + The GitOps loop (sync, self-heal, commit-driven change, `git revert` rollback) is genuinely exercised.
* − Gitea is a stand-in for GitHub: GitHub branch protection and PR reviews are not exercised locally.
* − Local signatures use a throwaway key, not keyless OIDC.
