"""In-memory, session-scoped UI state for the LazyComfy pages.

The store lives only for the lifetime of the ComfyUI process: a fresh
ComfyUI session starts with an empty store, so the pages never carry
state over from a previous ComfyUI session.
"""

import json

from . import LazyComfyError

_MAX_BLOB_BYTES = 16 * 1024 * 1024

_STATE = {}


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
