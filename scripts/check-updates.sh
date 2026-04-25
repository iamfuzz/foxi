#!/usr/bin/env bash
# Check for upstream updates to the kernel or Wolfi packages and emit
# GitHub Actions output variables.  Call as:
#
#   ./check-updates.sh kernel
#
# Outputs (written to GITHUB_OUTPUT if set, otherwise printed):
#   update_available  - "true" or "false"
#   current_version   - version in the repo
#   new_version       - latest upstream version
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MELANGE_YAML="$REPO_ROOT/packages/linux-lts/melange.yaml"

emit() {
  local key="$1" val="$2"
  echo "${key}=${val}"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "${key}=${val}" >> "$GITHUB_OUTPUT"
  fi
}

check_kernel() {
  # kernel.org publishes a JSON feed of releases
  local api_url="https://www.kernel.org/releases.json"
  local releases
  releases=$(curl -sf "$api_url") || {
    echo "Failed to fetch $api_url" >&2
    exit 1
  }

  # Prefer the "longterm" (LTS) series that matches our current major.minor
  local current_version
  current_version=$(grep -m1 '^  version:' "$MELANGE_YAML" | awk '{print $2}')
  local current_series
  current_series=$(echo "$current_version" | grep -oP '^\d+\.\d+')

  local new_version
  new_version=$(echo "$releases" | python3 -c "
import sys, json
data = json.load(sys.stdin)
series = '${current_series}'
for r in data['releases']:
    v = r['version']
    # Match the same major.minor LTS series
    if r.get('moniker') in ('longterm', 'stable') and v.startswith(series + '.'):
        print(v)
        break
" 2>/dev/null || echo "")

  if [ -z "$new_version" ]; then
    echo "Could not determine latest ${current_series}.x version" >&2
    exit 1
  fi

  emit current_version "$current_version"
  emit new_version     "$new_version"

  if [ "$current_version" != "$new_version" ]; then
    echo "Kernel update available: $current_version -> $new_version"
    emit update_available true

    # Patch the melange.yaml version in-place so the calling workflow can
    # commit the change and open a PR.
    if [ "${APPLY_UPDATE:-false}" = "true" ]; then
      sed -i "s/^  version: ${current_version}$/  version: ${new_version}/" "$MELANGE_YAML"

      # Fetch the SHA256 from kernel.org's published checksum file (no need to download the tarball)
      local sha256
      sha256=$(curl -sf "https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc" \
               | grep "linux-${new_version}.tar.xz" | awk '{print $1}')
      [ -n "$sha256" ] || { echo "Could not find SHA256 for linux-${new_version}.tar.xz" >&2; exit 1; }
      sed -i "s/expected-sha256: .*/expected-sha256: ${sha256}/" "$MELANGE_YAML"

      echo "Updated $MELANGE_YAML to version ${new_version} (sha256: ${sha256})"
    fi
  else
    echo "Kernel is up to date: $current_version"
    emit update_available false
  fi
}

case "${1:-}" in
  kernel) check_kernel ;;
  *)
    echo "Usage: $0 kernel"
    exit 1
    ;;
esac
