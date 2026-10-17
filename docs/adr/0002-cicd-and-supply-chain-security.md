# ADR-0002: GitHub Actions with a split trust model, Trivy + Syft + Cosign keyless + GitHub provenance

* Status: Accepted (2026-10-17)

## Context

A health-tech API must be able to prove *what* is running and *how it was built*. Pull requests can come from
anyone (including forks), so the pipeline must not let untrusted code publish or sign. In March 2026 the Trivy
GitHub Action itself was compromised (tags force-pushed to credential-stealing code), which shows that CI
dependencies are part of the attack surface.

## Decision

1. **Two workflows, two trust levels.** `ci.yml` (PRs + main) is read-only: tests, scans, builds, SBOM - but no
   secrets, no OIDC token, no push. `release.yml` runs only on `v*.*.*` tags in a protected `release` environment and
   is the only place with `packages: write`, `id-token: write`, `attestations: write`.
2. **Gate before publish.** The image is built locally on the runner, Trivy-scanned, and pushed only if there are no
   *fixable* HIGH/CRITICAL vulnerabilities. Findings are fixed at the source (e.g. removing pip from the runtime
   image), never suppressed.
3. **SBOM with Syft** (SPDX JSON in CI; SPDX + CycloneDX locally), attached as a signed attestation.
4. **Cosign keyless signing** by digest using GitHub OIDC -> no private key to store, rotate or leak. Verification pins
   the certificate identity to `release.yml` on a tag.
5. **SLSA provenance** with `actions/attest-build-provenance`, verified with `gh attestation verify`.
6. **Pin everything**: third-party actions to commit SHAs; Trivy run from a digest-pinned image (post-incident
   version 0.76.0) instead of `trivy-action`; base image by digest; Python deps by exact version; Dependabot proposes
   updates through the same gates.
7. **GHCR** as the registry (free for public packages, same identity as the repo).

## Alternatives considered

* *Key-based Cosign signing with a stored secret key* - works offline, but the key becomes a secret to protect and
  rotate. Used **only** locally, with a throwaway key, clearly labelled as not a release signature.
* *Single workflow with `if: github.event_name != 'pull_request'`* - common, but one mistake in an `if` gives PR code
  publishing rights. Separate workflows make the boundary obvious.
* *Grype instead of Trivy* - equally good; Trivy was chosen because it also scans IaC/Dockerfiles (one tool).
* *Docker Hub / ECR* - Docker Hub rate limits; ECR costs money and needs AWS credentials in CI.

## Consequences

* + Every release has: scan report, SBOM, signature, provenance, and a verified digest pinned in Git.
* + Compromise of a PR cannot publish an image.
* − Keyless signatures and provenance are public (Rekor). Acceptable for an open-source reference project.
* − Build L3 is not reached (build and attestation share a job) - see
  [supply-chain-security.md](../supply-chain-security.md#2-slsa-mapping).
