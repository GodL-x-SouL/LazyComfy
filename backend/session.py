"""Session-scoped UI state for the LazyComfy pages.

The store is a plain dict mirrored to a JSON file next to this module so
page settings survive ComfyUI restarts. All disk I/O is best-effort: a
missing or corrupt file simply yields an empty store, and write failures
never break the request that triggered them.
"""

import json
import os
import tempfile

from . import LazyComfyError

_MAX_BLOB_BYTES = 16 * 1024 * 1024

_STATE = {}
_SESSION_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".session.json")


def _load():
    try:
        if os.path.isfile(_SESSION_FILE):
            with open(_SESSION_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict):
                _STATE.update(data)
    except Exception:
        pass


def _store():
    try:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(_SESSION_FILE), prefix=".session", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(_STATE, f, ensure_ascii=True)
            os.replace(tmp, _SESSION_FILE)
        except BaseException:
            try:
                os.remove(tmp)
            except OSError:
                pass
            raise
    except Exception:
        pass


_load()


def snapshot():
    return dict(_STATE)


def save(key, value):
    if not isinstance(key, str) or not key.strip():
        raise LazyComfyError("invalid_request", "Session state key must be a non-empty string")
    if not isinstance(value, dict):
        raise LazyComfyError("invalid_request", "Session state value must be an object")
    blob = json.dumps(value, ensure_ascii=True)
    if len(blob.encode("utf-8")) > _MAX_BLOB_BYTES:
        raise LazyComfyError("invalid_request", "Session state value is too large")
    _STATE[key.strip()] = value
    _store()
