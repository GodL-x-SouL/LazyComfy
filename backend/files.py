import hashlib
import logging
import mimetypes
import os
import tempfile

from . import LazyComfyError
from .queue import aiohttp, http_json
from .validation import validate_upload

logger = logging.getLogger("lazycomfy")

try:
    import folder_paths
except Exception:
    folder_paths = None

_IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".webp")
_DELETE_EXTS = (".png", ".jpg", ".jpeg", ".webp", ".bmp", ".gif",
                ".mp4", ".webm", ".mov", ".m4v", ".avi", ".mkv")
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


def _base_dir(ftype):
    if folder_paths is None:
        return None
    try:
        if ftype == "input":
            return folder_paths.get_input_directory()
        if ftype == "output":
            return folder_paths.get_output_directory()
    except Exception:
        pass
    return None


def resolve_media(filename, subfolder, ftype):
    """Same containment rules as delete_media; returns the absolute file path."""
    if ftype not in ("input", "output"):
        raise LazyComfyError("invalid_request", "type must be 'input' or 'output'")
    if not isinstance(filename, str) or not filename or "/" in filename or "\\" in filename or ".." in filename:
        raise LazyComfyError("invalid_request", "Invalid filename")
    if not isinstance(subfolder, str):
        raise LazyComfyError("invalid_request", "Invalid subfolder")
    parts = [p for p in subfolder.replace("\\", "/").split("/") if p not in ("", ".")]
    if any(p == ".." for p in parts):
        raise LazyComfyError("invalid_request", "Invalid subfolder")
    if not filename.lower().endswith(_IMAGE_EXTS):
        raise LazyComfyError("invalid_request", "Only images can be thumbnailed")
    base = _base_dir(ftype)
    if not base or not os.path.isdir(base):
        raise LazyComfyError("input_dir_unavailable" if ftype == "input" else "output_dir_unavailable",
                              f"Cannot resolve the ComfyUI {ftype} folder")
    full = os.path.abspath(os.path.join(base, *parts, filename))
    if full != os.path.abspath(base) and not full.startswith(os.path.abspath(base) + os.sep):
        raise LazyComfyError("invalid_request", "Path escapes the ComfyUI folder")
    if not os.path.isfile(full):
        raise LazyComfyError("invalid_request", "File not found")
    return full


def thumb_for_path(full, size=256):
    """Downscaled JPEG cached on disk (keyed by path+mtime+size); ~10x smaller than full previews."""
    try:
        size = max(64, min(512, int(size or 256)))
    except (TypeError, ValueError):
        size = 256
    try:
        mtime = os.path.getmtime(full)
    except OSError:
        raise LazyComfyError("invalid_request", "File not found")
    key = hashlib.sha1(f"{full}|{mtime}|{size}".encode("utf-8")).hexdigest()
    cache = os.path.join(tempfile.gettempdir(), "lazycomfy_thumbs", key + ".jpg")
    if os.path.isfile(cache):
        return cache
    try:
        from PIL import Image
    except ImportError:
        raise LazyComfyError("thumb_unavailable", "Pillow is not installed")
    try:
        os.makedirs(os.path.dirname(cache), exist_ok=True)
        with Image.open(full) as im:
            im = im.convert("RGB")
            im.thumbnail((size, size), Image.LANCZOS)
            tmp = cache + ".tmp"
            im.save(tmp, "JPEG", quality=72)
        os.replace(tmp, cache)
    except Exception as e:
        raise LazyComfyError("thumb_failed", f"Cannot thumbnail image: {e}")
    return cache


def delete_media(filename, subfolder, ftype):
    """Delete one generated/uploaded media file. Contained to input/output dirs."""
    if ftype not in ("input", "output"):
        raise LazyComfyError("invalid_request", "type must be 'input' or 'output'")
    if not isinstance(filename, str) or not filename or "/" in filename or "\\" in filename or ".." in filename:
        raise LazyComfyError("invalid_request", "Invalid filename")
    if not isinstance(subfolder, str):
        raise LazyComfyError("invalid_request", "Invalid subfolder")
    parts = [p for p in subfolder.replace("\\", "/").split("/") if p not in ("", ".")]
    if any(p == ".." for p in parts):
        raise LazyComfyError("invalid_request", "Invalid subfolder")
    if not filename.lower().endswith(_DELETE_EXTS):
        raise LazyComfyError("invalid_request", "Only media files can be deleted")
    base = _base_dir(ftype)
    if not base or not os.path.isdir(base):
        raise LazyComfyError("input_dir_unavailable" if ftype == "input" else "output_dir_unavailable",
                              f"Cannot resolve the ComfyUI {ftype} folder")
    full = os.path.abspath(os.path.join(base, *parts, filename))
    if full != os.path.abspath(base) and not full.startswith(os.path.abspath(base) + os.sep):
        raise LazyComfyError("invalid_request", "Path escapes the ComfyUI folder")
    if not os.path.isfile(full):
        raise LazyComfyError("invalid_request", "File not found")
    try:
        os.remove(full)
    except OSError as e:
        raise LazyComfyError("delete_failed", f"Cannot delete file: {e}")
    return {"deleted": True, "filename": filename}


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
