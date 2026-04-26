import os

TRICKS_REMOTE_BASE = os.environ.get(
    "FOXI_TRICKS_URL",
    "https://raw.githubusercontent.com/iamfuzz/foxi-tricks/main",
)
TRICKS_INDEX_URL = f"{TRICKS_REMOTE_BASE}/index.json"
TRICKS_CACHE_DIR = os.environ.get("FOXI_TRICKS_DIR", "/etc/foxi/tricks")
TRICKS_BUNDLED_DIR = os.path.join(os.path.dirname(__file__), "..", "tricks")
