#!/usr/bin/env bash
# Build all Foxi APK packages with melange.
# Outputs signed .apk files into packages/<arch>/.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGES_DIR="$REPO_ROOT/packages"
SIGNING_KEY="${SIGNING_KEY:-$REPO_ROOT/signing.rsa}"
ARCHES="${ARCHES:-x86_64 aarch64}"

# Verify melange is available
if ! command -v melange &>/dev/null; then
  echo "melange not found. Install from:"
  echo "  https://github.com/chainguard-dev/melange/releases"
  exit 1
fi

# Generate a signing key if one doesn't exist yet.
# In CI, inject the private key as MELANGE_SIGNING_KEY env var and write it here.
if [ -n "${MELANGE_SIGNING_KEY:-}" ]; then
  echo "$MELANGE_SIGNING_KEY" > "$SIGNING_KEY"
  chmod 600 "$SIGNING_KEY"
elif [ ! -f "$SIGNING_KEY" ]; then
  echo "No signing key found. Generating a new one (development only)..."
  melange keygen "$SIGNING_KEY"
  echo ""
  echo "WARNING: Commit signing.rsa.pub to the repo but keep signing.rsa secret."
  echo "         In CI, store signing.rsa as the MELANGE_SIGNING_KEY secret."
  echo ""
fi

# Copy the public key into the packages directory so apko can verify packages.
cp "${SIGNING_KEY}.pub" "$PACKAGES_DIR/melange.rsa.pub" 2>/dev/null || true

detect_runner() {
  if [ -n "${MELANGE_RUNNER:-}" ]; then
    echo "$MELANGE_RUNNER"
  elif [ "$(id -u)" = "0" ]; then
    echo "bubblewrap"
  elif command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    echo "docker"
  else
    echo "bubblewrap"
  fi
}

build_package() {
  local pkg_dir="$1"
  local arch="$2"
  local spec="$pkg_dir/melange.yaml"

  [ -f "$spec" ] || return 0

  pkg_name=$(basename "$pkg_dir")
  local runner
  runner=$(detect_runner)
  echo "==> Building $pkg_name for $arch (runner: $runner)"

  melange build "$spec" \
    --arch "$arch" \
    --signing-key "$SIGNING_KEY" \
    --out-dir "$PACKAGES_DIR" \
    --runner "$runner" \
    ${MELANGE_EXTRA_ARGS:-}
}

for arch in $ARCHES; do
  echo "── Building packages for $arch ──────────────────────────────────"
  for pkg_dir in "$PACKAGES_DIR"/*/; do
    build_package "$pkg_dir" "$arch"
  done
done

echo ""
echo "Packages written to: $PACKAGES_DIR"
echo "Public key:          $PACKAGES_DIR/melange.rsa.pub"
