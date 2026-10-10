import logging
import mimetypes
import os

from . import LazyComfyError
from .queue import aiohttp, http_json
from .validation import validate_upload

logger = logging.getLogger("lazycomfy")

try:
    import folder_paths
except Exception:
    folder_paths = None

_IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".webp")
_INPUT_LIB_LIMIT = 200


async def upload_image(request, session):
    if aiohttp is None:
        raise LazyComfyError("upload_error", "aiohttp is not available")
    try:
        post = await request.post()
    except Exception as e:
        raise LazyComfyError("upload_error", f"Failed to read upload body: {e}")
    image = post.get("image")
    if image is None:
        raise LazyComfyError("upload_error", "Missing 'image' file field")
    filename = getattr(image, "filename", "") or ""
    if not filename:
        raise LazyComfyError("upload_error", "Uploaded file has no filename")
    if "/" in filename or "\\" in filename or ".." in filename:
        raise LazyComfyError("upload_error", "Invalid filename")
    try:
        payload = image.file.read()
    except Exception as e:
        raise LazyComfyError("upload_error", f"Cannot read uploaded file: {e}")
    content_type = getattr(image, "content_type", None)
    if not content_type:
        content_type = mimetypes.guess_type(filename)[0]
    validate_upload(content_type, len(payload))

    form = aiohttp.FormData()
    form.add_field("image", payload, filename=filename, content_type=content_type or "application/octet-stream")
    form.add_field("overwrite", "true")
    form.add_field("type", "input")
    form.add_field("subfolder", "lazycomfy")
    status, data = await http_json("POST", "/upload/image", session, data=form)
    if status != 200 or not isinstance(data, dict) or not data.get("name"):
        raise LazyComfyError("upload_error", f"ComfyUI upload failed (HTTP {status})")
    return {
        "name": data.get("name"),
        "subfolder": data.get("subfolder") or "lazycomfy",
        "type": data.get("type") or "input",
    }


def list_input_images():
    """Images already present in the ComfyUI input folder (top level + one subfolder deep)."""
    base = None
    if folder_paths is not None:
        try:
            base = folder_paths.get_input_directory()
        except Exception:
            base = None
    if not base or not os.path.isdir(base):
        raise LazyComfyError("input_dir_unavailable", "Cannot resolve the ComfyUI input folder")

    out = []

    def add(sub):
        try:
            names = os.listdir(os.path.join(base, sub) if sub else base)
        except OSError:
            return
        for name in names:
            if not name.lower().endswith(_IMAGE_EXTS):
                continue
            full = os.path.join(base, sub, name) if sub else os.path.join(base, name)
            if not os.path.isfile(full):
                continue
            try:
                st = os.stat(full)
            except OSError:
                continue
            out.append({"name": name, "subfolder": sub, "size": st.st_size, "mtime": int(st.st_mtime)})

    add("")
    try:
        subs = sorted(n for n in os.listdir(base)
                      if os.path.isdir(os.path.join(base, n)) and not n.startswith("."))
    except OSError:
        subs = []
    for sub in subs:
        add(sub)
    out.sort(key=lambda i: i["mtime"], reverse=True)
    return {"images": out[:_INPUT_LIB_LIMIT]}
