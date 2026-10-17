#!/usr/bin/env bash
# Local, zero-cost equivalent of the CI supply-chain stages:
#   build -> push to LOCAL registry -> Trivy scan (gate) -> Syft SBOM ->
#   Cosign sign (local test key) -> attest SBOM + local provenance -> verify all.
#
# Every tool runs from its official container image, so nothing needs to be
# installed except Docker. Nothing is uploaded anywhere: the registry is a
# container on this machine and the Sigstore transparency log upload is
# disabled (--tlog-upload=false).
#
# IMPORTANT: the signature produced here uses a throwaway key generated on this
# machine. It proves the *mechanism* works; it is NOT equivalent to the keyless,
# OIDC-bound signature the GitHub release workflow produces.
#
# Usage (Git Bash on Windows, or any shell on macOS/Linux):
#   bash scripts/local_supply_chain.sh            # uses version 0.1.0
#   APP_VERSION=0.1.1 bash scripts/local_supply_chain.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1   # stop Git Bash rewriting /paths inside docker args

APP_VERSION="${APP_VERSION:-0.1.1}"
REG_NAME="kind-registry"          # container name; resolvable inside the "kind" network
REG_HOST_PORT="5001"              # host side, used only for `docker push`
NETWORK="hq-supplychain"          # tool containers reach the registry here (kind_up.sh also joins it to "kind")
IMAGE_REPO="healthqueue-api"
OUT="reports/supply-chain"
KEYDIR=".local/cosign"            # git-ignored

TRIVY_IMG="aquasec/trivy:0.76.0@sha256:2416d1f74045b57274df1a340eee6b510cacd73c66a6ccb8da092b117eb7d222"
SYFT_IMG="anchore/syft:v1.54.1@sha256:3eb5379ba7b409c3f4069b686110527af0c47df993fa5c10d13e7cf34f49b1aa"
COSIGN_IMG="ghcr.io/sigstore/cosign/cosign:v3.1.3@sha256:9e5c2f2edc34351160407ca3416c61855bdf9403c3c5936e0f0be7fc261611b8"
REGISTRY_IMG="registry:3@sha256:ddf754342cfc8acc51a56d5d0ab6af06826461864460636d8bd5c546dab2a7b8"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
HOST_ROOT="$(pwd -W 2>/dev/null || pwd)"   # Windows path for docker -v on Git Bash
mkdir -p "$OUT" "$KEYDIR"

step() { printf '\n=== %s\n' "$*"; }

step "1/8 Local registry (${REG_NAME}, host port ${REG_HOST_PORT})"
docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create --label project=healthqueue "$NETWORK" >/dev/null
if [ "$(docker inspect -f '{{.State.Running}}' "$REG_NAME" 2>/dev/null)" != "true" ]; then
  docker rm -f "$REG_NAME" >/dev/null 2>&1 || true
  docker run -d --restart=unless-stopped --name "$REG_NAME" \
    --label project=healthqueue -p "127.0.0.1:${REG_HOST_PORT}:5000" "$REGISTRY_IMG" >/dev/null
fi
docker network connect "$NETWORK" "$REG_NAME" 2>/dev/null || true
docker network inspect kind >/dev/null 2>&1 && { docker network connect kind "$REG_NAME" 2>/dev/null || true; }
echo "registry ready"

step "2/8 Build image ${IMAGE_REPO}:${APP_VERSION}"
docker build --build-arg APP_VERSION="$APP_VERSION" -t "${IMAGE_REPO}:${APP_VERSION}" .

step "3/8 Push to local registry and resolve the immutable digest"
docker tag "${IMAGE_REPO}:${APP_VERSION}" "localhost:${REG_HOST_PORT}/${IMAGE_REPO}:${APP_VERSION}"
docker push -q "localhost:${REG_HOST_PORT}/${IMAGE_REPO}:${APP_VERSION}" >/dev/null
DIGEST="$(docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' \
  "localhost:${REG_HOST_PORT}/${IMAGE_REPO}:${APP_VERSION}" | grep "localhost:${REG_HOST_PORT}" | head -1 | cut -d@ -f2 | tr -d '\r')"
# Inside the kind network the registry is addressed by container name.
REF="${REG_NAME}:5000/${IMAGE_REPO}@${DIGEST}"
echo "$REF" | tee "$OUT/image-ref.txt"

run_net() { docker run --rm --network "$NETWORK" -v "${HOST_ROOT}:/work" -w /work "$@"; }

step "4/8 Trivy vulnerability scan (gate: fail on fixable HIGH/CRITICAL)"
docker volume create hq-trivy-cache >/dev/null
run_net -v hq-trivy-cache:/root/.cache/trivy "$TRIVY_IMG" image --insecure --quiet \
  --scanners vuln --format table --output "$OUT/trivy-image-report.txt" "$REF"
run_net -v hq-trivy-cache:/root/.cache/trivy "$TRIVY_IMG" image --insecure --quiet \
  --scanners vuln --format json --output "$OUT/trivy-image-report.json" "$REF"
# The gate: exit-code 1 if any HIGH/CRITICAL vulnerability with a fix exists.
run_net -v hq-trivy-cache:/root/.cache/trivy "$TRIVY_IMG" image --insecure --quiet \
  --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 "$REF"
echo "Trivy gate passed (no fixable HIGH/CRITICAL findings)"

step "5/8 Syft SBOM (SPDX JSON + CycloneDX JSON)"
run_net -e SYFT_REGISTRY_INSECURE_USE_HTTP=true "$SYFT_IMG" "registry:${REF}" \
  -o "spdx-json=/work/${OUT}/sbom.spdx.json" -o "cyclonedx-json=/work/${OUT}/sbom.cdx.json" -q
echo "SBOM packages: $(grep -o '"SPDXID"' "$OUT/sbom.spdx.json" | wc -l | tr -d ' ') SPDX elements"

step "6/8 Cosign: local test key, sign by digest, attest SBOM + provenance"
if [ ! -f "$KEYDIR/password" ]; then
  # A random password for the local throwaway key. Never commit .local/.
  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$KEYDIR/password"
fi
COSIGN_PASSWORD="$(cat "$KEYDIR/password")"
export COSIGN_PASSWORD
cosign() { run_net -e COSIGN_PASSWORD "$COSIGN_IMG" "$@"; }
if [ ! -f "$KEYDIR/cosign.key" ]; then
  cosign generate-key-pair --output-key-prefix ".local/cosign/cosign" >/dev/null
fi
cp "$KEYDIR/cosign.pub" "$OUT/cosign-local-test.pub"

# Minimal SLSA v1 provenance describing THIS local build. The builder id says
# plainly that it is an unverified workstation build.
GIT_SHA="$(git rev-parse --verify -q HEAD 2>/dev/null || echo "uncommitted-working-tree")"
cat > "$OUT/provenance.local.json" <<JSON
{
  "buildDefinition": {
    "buildType": "https://github.com/FarhanOsMo/healthqueue-capstone-/local-build@v1",
    "externalParameters": {"source": "local working tree", "gitCommit": "${GIT_SHA}", "appVersion": "${APP_VERSION}"},
    "resolvedDependencies": [{"uri": "docker-image://python:3.13-slim", "digest": {"sha256": "70729b46c69b4f1e97c4822c1af3df53a1476cf5ddc6c087c0c10bc3a5678c2f"}}]
  },
  "runDetails": {
    "builder": {"id": "local-developer-workstation (UNTRUSTED - demo only)"},
    "metadata": {"invocationId": "local-$(date -u +%Y%m%dT%H%M%SZ)", "startedOn": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
  }
}
JSON

COMMON=(--key /work/.local/cosign/cosign.key --use-signing-config=false --tlog-upload=false --allow-http-registry --allow-insecure-registry -y)
cosign sign "${COMMON[@]}" "$REF"
cosign attest "${COMMON[@]}" --type spdxjson --predicate "/work/${OUT}/sbom.spdx.json" "$REF"
cosign attest "${COMMON[@]}" --type slsaprovenance1 --predicate "/work/${OUT}/provenance.local.json" "$REF"

step "7/8 Verify signature and attestations (fails closed if anything is wrong)"
VERIFY=(--key /work/.local/cosign/cosign.pub --insecure-ignore-tlog=true --allow-http-registry --allow-insecure-registry)
cosign verify "${VERIFY[@]}" "$REF" > "$OUT/cosign-verify.json"
cosign verify-attestation "${VERIFY[@]}" --type spdxjson "$REF" > "$OUT/cosign-verify-sbom-attestation.json"
cosign verify-attestation "${VERIFY[@]}" --type slsaprovenance1 "$REF" > "$OUT/cosign-verify-provenance-attestation.json"
echo "signature + SBOM attestation + provenance attestation verified"

step "8/8 Negative test: a tampered (rebuilt, unsigned) image must FAIL verification"
# Same repository, one extra layer -> different digest -> no valid signature.
printf 'FROM %s\nLABEL tampered="true"\n' "${IMAGE_REPO}:${APP_VERSION}" \
  | docker build -q -t "localhost:${REG_HOST_PORT}/${IMAGE_REPO}:tampered" - >/dev/null
docker push -q "localhost:${REG_HOST_PORT}/${IMAGE_REPO}:tampered" >/dev/null
TAMPERED_DIGEST="$(docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' \
  "localhost:${REG_HOST_PORT}/${IMAGE_REPO}:tampered" | grep "localhost:${REG_HOST_PORT}" | head -1 | cut -d@ -f2 | tr -d '\r')"
if cosign verify "${VERIFY[@]}" "${REG_NAME}:5000/${IMAGE_REPO}@${TAMPERED_DIGEST}" \
    > "$OUT/cosign-verify-tampered.txt" 2>&1; then
  echo "ERROR: tampered image verified - this must never happen" >&2; exit 1
else
  echo "tampered image ${TAMPERED_DIGEST} correctly rejected:"
  tail -1 "$OUT/cosign-verify-tampered.txt"
fi

{
  echo "image_ref=${REF}"
  echo "app_version=${APP_VERSION}"
  echo "git_commit=${GIT_SHA}"
  echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "signing=local test key, tlog upload disabled (NOT a trusted release signature)"
} > "$OUT/summary.txt"
printf '\nDone. Evidence in %s/\n' "$OUT"
