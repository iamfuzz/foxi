import hashlib
import json
import os
import sys
import urllib.request
from pathlib import Path

import yaml

from .config import TRICKS_BUNDLED_DIR, TRICKS_CACHE_DIR, TRICKS_INDEX_URL, TRICKS_REMOTE_BASE


def _fetch(url):
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            return resp.read()
    except Exception as e:
        raise RuntimeError(f"Failed to fetch {url}: {e}")


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def update_index():
    """Fetch the remote index and save it to the cache dir."""
    os.makedirs(TRICKS_CACHE_DIR, exist_ok=True)
    print(f"Fetching tricks index from {TRICKS_INDEX_URL} ...")
    data = _fetch(TRICKS_INDEX_URL)
    index_path = os.path.join(TRICKS_CACHE_DIR, "index.json")
    with open(index_path, "wb") as f:
        f.write(data)
    index = json.loads(data)
    print(f"Index updated: {len(index.get('tricks', {}))} tricks available.")
    return index


def load_index():
    index_path = os.path.join(TRICKS_CACHE_DIR, "index.json")
    if not os.path.exists(index_path):
        return {}
    with open(index_path) as f:
        return json.load(f).get("tricks", {})


def list_tricks():
    index = load_index()
    if not index:
        print("No index found. Run 'foxi tricks update' first.")
        return
    print(f"{'Package':<24} {'Version':<10} Cached")
    print("-" * 45)
    for pkg, meta in sorted(index.items()):
        cached_path = os.path.join(TRICKS_CACHE_DIR, f"{pkg}.yaml")
        cached = "yes" if os.path.exists(cached_path) else "no"
        print(f"{pkg:<24} {meta.get('version', '?'):<10} {cached}")


def fetch_trick(package):
    """Download and verify a trick, returning its parsed YAML."""
    index = load_index()
    os.makedirs(TRICKS_CACHE_DIR, exist_ok=True)
    url = f"{TRICKS_REMOTE_BASE}/tricks/{package}.yaml"
    print(f"Fetching trick for {package} ...")
    data = _fetch(url)

    if package in index:
        expected = index[package].get("sha256")
        if expected and _sha256(data) != expected:
            raise RuntimeError(f"Checksum mismatch for {package} trick — aborting.")

    cache_path = os.path.join(TRICKS_CACHE_DIR, f"{package}.yaml")
    with open(cache_path, "wb") as f:
        f.write(data)
    return yaml.safe_load(data)


def load_trick(package):
    """Return parsed trick for package, checking cache then bundled fallback."""
    cache_path = os.path.join(TRICKS_CACHE_DIR, f"{package}.yaml")
    if os.path.exists(cache_path):
        with open(cache_path) as f:
            return yaml.safe_load(f)

    bundled = Path(TRICKS_BUNDLED_DIR) / f"{package}.yaml"
    if bundled.exists():
        with open(bundled) as f:
            return yaml.safe_load(f)

    # Try fetching remotely as a last resort
    try:
        return fetch_trick(package)
    except Exception:
        return None


def run_hook(package, hook):
    from .actions import execute_action

    trick = load_trick(package)
    if not trick:
        return  # No trick for this package — silent, not an error

    steps = trick.get("hooks", {}).get(hook, [])
    if not steps:
        return

    print(f"[foxi] Running {hook} trick for {package} ...")
    for step in steps:
        execute_action(step)
