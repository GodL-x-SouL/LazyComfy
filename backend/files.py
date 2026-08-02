import logging
import mimetypes

from . import LazyComfyError
from .queue import aiohttp, http_json
from .validation import validate_upload

logger = logging.getLogger("lazycomfy")


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
