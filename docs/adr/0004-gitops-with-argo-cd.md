# ADR-0004: GitOps with Argo CD and Kustomize overlays

* Status: Accepted (2026-10-17)

## Context

Deployments must be auditable (who changed what, when), reversible in minutes, and must not depend on someone
having cluster credentials on their laptop. The team already used Argo CD in an earlier project.

## Decision

* **Argo CD** (pinned v3.5.5) reconciles `deploy/k8s/overlays/<env>` from Git with automated sync, **prune** and
  **self-heal**. Manual `kubectl` changes are reverted automatically.
* **AppProject guard rails**: only the HealthQueue repos, only the `healthqueue` namespace, an explicit list of
  resource kinds - and **Secrets are not allowed from Git**.
* **Kustomize** base + overlays (`local`, `production`); images are always pinned by **digest**.
* **Image updates are Git commits**: `scripts/set_image.sh` locally, or the release workflow's PR in production.
  Rollback = `git revert`.
* Production differs: auto-sync without auto-prune; HPA owns replicas (`ignoreDifferences`).

## Alternatives considered

* *Flux* - equally capable; Argo CD's UI makes sync/health/diff easy to show the CTO and was already familiar.
* *`kubectl apply` from CI* - CI would need cluster-admin credentials, and the cluster could drift silently.
* *Helm charts* - templating power we do not need; Kustomize overlays are plain YAML and easier to review.
* *Argo CD Image Updater* - automates digest bumps, but writes to Git with its own credentials; a reviewed PR from the
  release workflow keeps a human in the loop for a patient-facing service.

## Consequences

* + Every deployment is a reviewed commit; rollback tested (`scripts/gitops_verify.sh`).
* + Drift is corrected within one reconciliation cycle (tested).
* − Bootstrap secrets (DB password) need a separate mechanism (local: script; production: External Secrets).
* − Locally Argo CD reads an in-cluster Gitea copy, not GitHub (see ADR-0006).
