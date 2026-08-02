import asyncio
import logging
import os
import urllib.parse

from . import LazyComfyError

logger = logging.getLogger("lazycomfy")

try:
    import aiohttp
except Exception:
    aiohttp = None

_STATE = {}


def _detect_port():
    try:
        from server import PromptServer
    except Exception:
        PromptServer = None
    if PromptServer is not None:
        try:
            instance = getattr(PromptServer, "instance", None)
            if instance is not None:
                port = getattr(instance, "port", None)
                if isinstance(port, int) and port > 0:
                    return port
                listen = getattr(instance, "listen", None)
                if isinstance(listen, int) and listen > 0:
                    return listen
        except Exception:
            pass
    env_port = os.environ.get("LAZYCOMFY_PORT")
    if env_port is not None:
        try:
            parsed = int(env_port)
            if parsed > 0:
                return parsed
        except ValueError:
            pass
    return 8188


def base_url():
    if "base_url" not in _STATE:
        port = _detect_port()
        _STATE["base_url"] = f"http://127.0.0.1:{port}"
        logger.info("LazyComfy: talking to ComfyUI on port %s", port)
    return _STATE["base_url"]


async def get_session(request):
    app = request.app
    session = app.get("lazycomfy_session")
    if session is not None:
        return session
    lock = app.get("lazycomfy_session_lock")
    if lock is None:
        lock = asyncio.Lock()
        app["lazycomfy_session_lock"] = lock
    async with lock:
        session = app.get("lazycomfy_session")
        if session is None:
            session = aiohttp.ClientSession()
            app["lazycomfy_session"] = session
    return session


async def _parse_body(resp):
    try:
        return await resp.json()
    except Exception:
        try:
            return {"_raw": await resp.text()}
        except Exception:
            return {"_raw": None}


async def http_json(method, path, session, **kwargs):
    if aiohttp is None:
        raise LazyComfyError("comfyui_unreachable", "aiohttp is not available")
    url = f"{base_url()}{path}"
    try:
        if session is not None:
            async with session.request(method, url, **kwargs) as resp:
                return resp.status, await _parse_body(resp)
        async with aiohttp.ClientSession() as temp:
            async with temp.request(method, url, **kwargs) as resp:
                return resp.status, await _parse_body(resp)
    except LazyComfyError:
        raise
    except (aiohttp.ClientError, asyncio.TimeoutError, OSError) as e:
        raise LazyComfyError("comfyui_unreachable", f"Cannot reach ComfyUI at {url}: {e}")


async def submit_prompt(prompt_dict, extra_data, client_id, session=None):
    payload = {"prompt": prompt_dict, "client_id": client_id, "extra_data": extra_data}
    status, data = await http_json("POST", "/prompt", session, json=payload)
    if status != 200:
        details = None
        if isinstance(data, dict):
            details = data.get("node_errors")
            if details is None and "_raw" not in data:
                details = data
        raise LazyComfyError("comfyui_error", f"ComfyUI rejected the prompt (HTTP {status})", details=details)
    if not isinstance(data, dict) or not data.get("prompt_id"):
        raise LazyComfyError("comfyui_error", "ComfyUI accepted the prompt but did not return a prompt id", details=data)
    return {"prompt_id": data["prompt_id"], "number": data.get("number")}


async def interrupt(prompt_id, session=None):
    try:
        await http_json("POST", "/interrupt", session, json={"prompt_id": prompt_id})
    except LazyComfyError as e:
        logger.warning("LazyComfy: interrupt failed for %s: %s", prompt_id, e.message)


async def history_entry(prompt_id, session=None):
    status, data = await http_json("GET", f"/history/{prompt_id}", session)
    if status != 200 or not isinstance(data, dict):
        return None
    return data.get(prompt_id)


def _collect_images(entry):
    images = []
    try:
        outputs = entry.get("outputs") or {}
        for node_out in outputs.values():
            for img in (node_out or {}).get("images") or []:
                if not isinstance(img, dict):
                    continue
                filename = img.get("filename")
                if not filename:
                    continue
                subfolder = img.get("subfolder") or ""
                ftype = img.get("type") or "output"
                images.append({
                    "filename": filename,
                    "subfolder": subfolder,
                    "type": ftype,
                    "url": "/view?" + urllib.parse.urlencode({
                        "filename": filename,
                        "subfolder": subfolder,
                        "type": ftype,
                    }),
                })
    except Exception:
        pass
    return images


def _meta_from_entry(entry):
    meta = None
    try:
        prompt = entry.get("prompt")
        if isinstance(prompt, list) and len(prompt) > 3:
            extra_data = prompt[3]
            if isinstance(extra_data, dict):
                meta = extra_data.get("lazycomfy")
    except Exception:
        pass
    return meta


async def recent_jobs(limit=12, session=None):
    status, data = await http_json("GET", "/history", session)
    jobs = []
    if status != 200 or not isinstance(data, dict):
        return jobs
    for prompt_id, entry in data.items():
        if not isinstance(entry, dict):
            continue
        meta = _meta_from_entry(entry)
        if not meta:
            continue
        status_str = "unknown"
        messages = []
        try:
            status_info = entry.get("status") or {}
            status_str = status_info.get("status_str") or "unknown"
            messages = status_info.get("messages") or []
        except Exception:
            pass
        timestamp = 0
        for msg in messages:
            try:
                ts = msg[0]
                if isinstance(ts, (int, float)) and ts > timestamp:
                    timestamp = ts
            except Exception:
                continue
        meta = meta or {}
        jobs.append({
            "prompt_id": prompt_id,
            "status": status_str,
            "timestamp": timestamp,
            "model_id": meta.get("model_id"),
            "mode": meta.get("mode"),
            "prompt": meta.get("prompt"),
            "params": meta.get("params"),
            "images": _collect_images(entry),
        })
    jobs.sort(key=lambda j: j["timestamp"], reverse=True)
    return jobs[:limit]


async def _in_queue(prompt_id, session=None):
    status, data = await http_json("GET", "/queue", session)
    if status != 200 or not isinstance(data, dict):
        return False
    for group in ("queue_running", "queue_pending"):
        for item in data.get(group) or []:
            try:
                if item[1] == prompt_id:
                    return True
            except Exception:
                continue
    return False


async def result(prompt_id, session=None):
    entry = await history_entry(prompt_id, session)
    if entry is None:
        if await _in_queue(prompt_id, session):
            return {"status": "running", "outputs": [], "meta": None, "error": None}
        return {"status": "unknown", "outputs": [], "meta": None, "error": None}
    meta = _meta_from_entry(entry)
    outputs = _collect_images(entry)
    status_info = {}
    try:
        status_info = entry.get("status") or {}
    except Exception:
        pass
    status_str = status_info.get("status_str") or "unknown"
    if status_str == "success":
        return {"status": "success", "outputs": outputs, "meta": meta, "error": None}
    if status_str == "error":
        error = None
        try:
            for msg in status_info.get("messages") or []:
                if not (isinstance(msg, list) and len(msg) > 1):
                    continue
                msg_data = msg[1]
                if not isinstance(msg_data, dict) or msg_data.get("type") != "execution_error":
                    continue
                inner = msg_data.get("data") or {}
                error = {"type": inner.get("exception_type"), "message": inner.get("exception_message")}
                break
        except Exception:
            pass
        return {"status": "error", "outputs": outputs, "meta": meta, "error": error}
    if not status_info.get("completed"):
        return {"status": "running", "outputs": outputs, "meta": meta, "error": None}
    return {"status": "unknown", "outputs": outputs, "meta": meta, "error": None}


async def queue_remaining(session=None):
    status, data = await http_json("GET", "/prompt", session)
    if status != 200 or not isinstance(data, dict):
        return None
    try:
        return data["exec_info"]["queue_remaining"]
    except Exception:
        return None


async def system_stats(session=None):
    status, data = await http_json("GET", "/system_stats", session)
    if status != 200 or not isinstance(data, dict):
        return None
    return data
