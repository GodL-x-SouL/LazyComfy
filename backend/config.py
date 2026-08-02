import os

VERSION = "0.1.0"
PKG_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB_DIR = os.path.join(PKG_DIR, "web")
WORKFLOWS_DIR = os.path.join(PKG_DIR, "workflows")

try:
    MAX_UPLOAD_MB = int(os.environ.get("LAZYCOMFY_MAX_UPLOAD_MB", "50"))
except ValueError:
    MAX_UPLOAD_MB = 50
