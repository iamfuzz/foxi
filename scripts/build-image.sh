#!/usr/bin/env bash
# Build the Foxi OCI image with apko, using local packages + Wolfi/Chainguard.
# Outputs: foxi.tar (multi-arch OCI image tarball)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE_CONFIG="$REPO_ROOT/images/ec2-base.yaml"
OUTPUT_IMAGE="${OUTPUT_IMAGE:-foxi:latest}"
OUTPUT_TAR="${OUTPUT_TAR:-$REPO_ROOT/dist/foxi.tar}"
ARCHES="${ARCHES:-x86_64,aarch64}"

if ! command -v apko &>/dev/null; then
  echo "apko not found. Install from:"
  echo "  https://github.com/chainguard-dev/apko/releases"
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_TAR")"

echo "==> Building OCI image: $OUTPUT_IMAGE"
apko build "$IMAGE_CONFIG" \
  "$OUTPUT_IMAGE" \
  "$OUTPUT_TAR" \
  --arch "$ARCHES" \
  ${APKO_EXTRA_ARGS:-}

echo ""
echo "Image tarball: $OUTPUT_TAR"
echo ""
echo "To load into local Docker:"
echo "  docker load < $OUTPUT_TAR"
echo ""
echo "To push to a registry:"
echo "  crane push $OUTPUT_TAR <registry>/<repo>:latest"
