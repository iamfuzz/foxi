import os

TRICKS_REMOTE_BASE = os.environ.get(
    "FOXI_TRICKS_URL",
    "https://raw.githubusercontent.com/iamfuzz/foxi-tricks/main",
)
TRICKS_INDEX_URL = f"{TRICKS_REMOTE_BASE}/index.json"
TRICKS_CACHE_DIR = os.environ.get("FOXI_TRICKS_DIR", "/etc/foxi/tricks")

_INSTALLED = "/usr/share/foxi/tricks"
_DEV = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tricks")
TRICKS_BUNDLED_DIR = _INSTALLED if os.path.isdir(_INSTALLED) else _DEV
