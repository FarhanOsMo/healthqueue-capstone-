#!/usr/bin/env bash
# Point an overlay at a new immutable image digest. This is the ONLY way a new
# version reaches the cluster: edit Git -> commit/PR -> Argo CD syncs.
#
# Usage:
#   bash scripts/set_image.sh local                       # digest from reports/supply-chain/image-ref.txt
#   bash scripts/set_image.sh local sha256:<64 hex chars>
set -euo pipefail
OVERLAY="${1:?usage: set_image.sh <local|production> [sha256:digest]}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$ROOT/deploy/k8s/overlays/$OVERLAY/kustomization.yaml"
DIGEST="${2:-$(tr -d '\r\n' < "$ROOT/reports/supply-chain/image-ref.txt" | sed 's/.*@//')}"

[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "Not a sha256 digest: $DIGEST" >&2; exit 1; }
[ -f "$FILE" ] || { echo "No overlay: $FILE" >&2; exit 1; }

OLD="$(grep -Eo 'sha256:[0-9a-f]{64}' "$FILE" | head -1)"
sed -i -E "s|^(    digest: )sha256:[0-9a-f]{64}|\1${DIGEST}|" "$FILE"
echo "overlays/$OVERLAY: ${OLD:0:19}... -> ${DIGEST:0:19}..."
echo "Next: commit + PR (or locally: bash scripts/gitops_publish.sh \"deploy ${DIGEST:0:19}\")"
