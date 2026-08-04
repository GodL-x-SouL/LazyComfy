import asyncio
import logging
import json
import os
import time
import traceback

from . import LazyComfyError
from . import files
from . import hub
from . import llm
from . import queue
from . import workflows as workflow_module
from .config import MAX_UPLOAD_MB, VERSION, WEB_DIR
from .models import MODELS, list_models_with_files, missing_files
from .validation import error_response, validate_generate_request

logger = logging.getLogger("lazycomfy")

try:
    from server import PromptServer
except Exception:
    PromptServer = None

try:
    from aiohttp import web
except Exception:
    web = None

workflow_map = workflow_module.WORKFLOWS
models_by_id = {m["id"]: m for m in MODELS}
_STATIC_DIR = os.path.join(WEB_DIR, "static")
_INDEX_PATH = os.path.join(WEB_DIR, "index.html")
_FORGE_PATH = os.path.join(WEB_DIR, "forge.html")


def _error_status(error):
    if error.error_type in ("comfyui_error", "comfyui_unreachable", "missing_model_files"):
        return 502
    return 400


def _json_handler(fn):
    async def wrapper(request):
        try:
            return web.json_response(await fn(request))
        except LazyComfyError as e:
            return web.json_response(error_response(e.error_type, e.message, e.details), status=_error_status(e))
        except Exception as e:
            logger.error("LazyComfy: %s %s failed: %s", request.method, request.path, traceback.format_exc())
            return web.json_response(error_response("internal_error", str(e)), status=500)

    wrapper.__name__ = getattr(fn, "__name__", "handler")
    return wrapper


async def _config_handler(request, session):
    stats = None
    try:
        stats = await queue.system_stats(session)
    except LazyComfyError as e:
        logger.warning("LazyComfy: system_stats unavailable: %s", e.message)
    comfyui_version = None
    python_version = None
    device = None
    if stats:
        system = stats.get("system") or {}
        comfyui_version = system.get("comfyui_version")
        python_version = system.get("python_version")
        devices = stats.get("devices") or []
        if devices:
            device = devices[0]
    return {
        "lazycomfy_version": VERSION,
        "comfyui_version": comfyui_version,
        "python_version": python_version,
        "device": device,
        "max_upload_mb": MAX_UPLOAD_MB,
    }


async def _models_handler(request):
    return {"models": list_models_with_files()}


async def _workflows_handler(request):
    return {"workflows": workflow_module.list_workflows()}


async def _generate_handler(request):
    try:
        body = await request.json()
    except Exception as e:
        raise LazyComfyError("invalid_request", f"Request body must be JSON: {e}")
    params, extra_data = validate_generate_request(body, models_by_id, workflow_map)
    meta = extra_data["lazycomfy"]
    overrides = {}
    for kind, key in (("unet", "unet_file"), ("uncond", "uncond_file"), ("clip", "clip_file"), ("vae", "vae_file")):
        if key in params:
            overrides[kind] = params[key]
    missing = missing_files(meta["model_id"], overrides)
    if missing:
        labels = ", ".join(f["label"] for f in missing)
        raise LazyComfyError("missing_model_files", f"Missing: {labels}")
    if isinstance(params.get("image"), dict):
        img = params["image"]
        params["image"] = f"{img['subfolder']}/{img['name']}" if img.get("subfolder") else img["name"]
    prompt_dict = workflow_module.build_workflow(meta["template_id"], params)
    session = await queue.get_session(request)
    submitted = await queue.submit_prompt(prompt_dict, extra_data, meta.get("client_id"), session)
    return {"prompt_id": submitted["prompt_id"], "number": submitted["number"], "submitted_at": int(time.time())}


async def _upload_handler(request):
    session = await queue.get_session(request)
    return await files.upload_image(request, session)


async def _result_handler(request):
    prompt_id = request.match_info["prompt_id"]
    session = await queue.get_session(request)
    return await queue.result(prompt_id, session)


async def _cancel_handler(request):
    prompt_id = request.match_info["prompt_id"]
    session = await queue.get_session(request)
    await queue.interrupt(prompt_id, session)
    return {"ok": True}


async def _history_handler(request):
    try:
        limit = int(request.query.get("limit", "12"))
    except (TypeError, ValueError):
        limit = 12
    limit = max(1, min(limit, 50))
    session = await queue.get_session(request)
    return {"jobs": await queue.recent_jobs(limit, session)}


async def _queue_handler(request):
    session = await queue.get_session(request)
    return {"queue_remaining": await queue.queue_remaining(session)}


_REGISTERED = False


def register():
    global _REGISTERED
    if _REGISTERED:
        return
    _REGISTERED = True
    if PromptServer is None:
        logger.warning("LazyComfy: PromptServer unavailable, routes not registered")
        return
    instance = PromptServer.instance
    if instance is None:
        logger.warning("LazyComfy: PromptServer.instance is None, routes not registered")
        return
    if web is None:
        logger.warning("LazyComfy: aiohttp unavailable, routes not registered")
        return
    try:
        os.makedirs(_STATIC_DIR, exist_ok=True)
    except OSError as e:
        logger.warning("LazyComfy: cannot create static dir: %s", e)
    routes = web.RouteTableDef()

    @routes.get("/lazycomfy")
    async def index(request):
        return web.FileResponse(_INDEX_PATH, headers={"Cache-Control": "no-cache"})

    @routes.get("/lazycomfy/forge")
    async def forge_page(request):
        return web.FileResponse(_FORGE_PATH, headers={"Cache-Control": "no-cache"})

    @routes.get("/lazycomfy/api/config")
    @_json_handler
    async def config(request):
        session = await queue.get_session(request)
        return await _config_handler(request, session)

    @routes.get("/lazycomfy/api/models")
    @_json_handler
    async def models(request):
        return await _models_handler(request)

    @routes.get("/lazycomfy/api/workflows")
    @_json_handler
    async def workflows(request):
        return await _workflows_handler(request)

    @routes.post("/lazycomfy/api/generate")
    @_json_handler
    async def generate(request):
        return await _generate_handler(request)

    @routes.post("/lazycomfy/api/upload")
    @_json_handler
    async def upload(request):
        return await _upload_handler(request)

    @routes.get("/lazycomfy/api/result/{prompt_id}")
    @_json_handler
    async def result(request):
        return await _result_handler(request)

    @routes.post("/lazycomfy/api/cancel/{prompt_id}")
    @_json_handler
    async def cancel(request):
        return await _cancel_handler(request)

    @routes.get("/lazycomfy/api/history")
    @_json_handler
    async def history(request):
        return await _history_handler(request)

    @routes.get("/lazycomfy/api/queue")
    @_json_handler
    async def queue_state(request):
        return await _queue_handler(request)

    @routes.get("/lazycomfy/api/catalog")
    @_json_handler
    async def catalog(request):
        return hub.catalog_payload()

    @routes.get("/lazycomfy/api/files")
    @_json_handler
    async def files_list(request):
        return {"dirs": {name: hub.list_files(name) for name in ("diffusion_models", "text_encoders", "vae", "loras")}}

    @routes.post("/lazycomfy/api/lora/download")
    @_json_handler
    async def lora_download_start(request):
        try:
            body = await request.json()
        except Exception as e:
            raise LazyComfyError("invalid_request", f"Request body must be JSON: {e}")
        url = body.get("url")
        if not isinstance(url, str) or not url.strip():
            raise LazyComfyError("invalid_request", "url is required")
        return await hub.start_lora_download(url)

    @routes.post("/lazycomfy/api/download")
    @_json_handler
    async def download_start(request):
        try:
            body = await request.json()
        except Exception as e:
            raise LazyComfyError("invalid_request", f"Request body must be JSON: {e}")
        item_id = body.get("item_id")
        if not isinstance(item_id, str) or not item_id:
            raise LazyComfyError("invalid_request", "item_id is required")
        return await hub.start_download(item_id)

    @routes.get("/lazycomfy/api/download/{task_id}")
    @_json_handler
    async def download_status(request):
        task = hub.get_task(request.match_info["task_id"])
        if task is None:
            raise LazyComfyError("unknown_task", "No such download task")
        return task

    @routes.post("/lazycomfy/api/download/cancel/{task_id}")
    @_json_handler
    async def download_cancel(request):
        return {"cancelled": hub.cancel_download(request.match_info["task_id"])}

    @routes.get("/lazycomfy/api/llm/config")
    @_json_handler
    async def llm_config(request):
        session = await queue.get_session(request)
        return await llm.config_payload(session)

    @routes.post("/lazycomfy/api/llm/install")
    @_json_handler
    async def llm_install(request):
        return await llm.install_backend()

    @routes.post("/lazycomfy/api/llm/load")
    @_json_handler
    async def llm_load(request):
        try:
            body = await request.json()
        except Exception as e:
            raise LazyComfyError("invalid_request", f"Request body must be JSON: {e}")
        model = body.get("model")
        if not isinstance(model, str) or not model.strip():
            raise LazyComfyError("invalid_request", "model is required")
        mmproj = body.get("mmproj")
        if not isinstance(mmproj, str):
            mmproj = "None"
        try:
            context_length = int(body.get("context_length", 2048))
        except (TypeError, ValueError):
            context_length = 2048
        await llm.manager.start_server(model.strip(), mmproj, context_length)
        return llm.manager.status_payload()

    @routes.post("/lazycomfy/api/llm/unload")
    @_json_handler
    async def llm_unload(request):
        return await llm.manager.stop()

    @routes.get("/lazycomfy/api/llm/status")
    @_json_handler
    async def llm_status(request):
        return llm.manager.status_payload()

    @routes.post("/lazycomfy/api/llm/generate")
    async def llm_generate(request):
        try:
            body = await request.json()
        except Exception as e:
            return web.json_response(error_response("invalid_request", f"Request body must be JSON: {e}"), status=400)
        response = web.StreamResponse(
            status=200,
            headers={"Content-Type": "text/event-stream", "Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )
        await response.prepare(request)
        gen = llm.manager.generate_events(request, body)
        try:
            async for ev in gen:
                await response.write(("data: " + json.dumps(ev) + "\n\n").encode("utf-8"))
        except (ConnectionResetError, asyncio.CancelledError, RuntimeError):
            pass
        except LazyComfyError as e:
            logger.warning("LazyComfy: llm generate error: %s", e.message)
            try:
                await response.write(("data: " + json.dumps({"type": "error", "message": e.message}) + "\n\n").encode("utf-8"))
            except Exception:
                pass
        except Exception as e:
            logger.error("LazyComfy: llm generate failed: %s", traceback.format_exc())
            try:
                await response.write(("data: " + json.dumps({"type": "error", "message": str(e)}) + "\n\n").encode("utf-8"))
            except Exception:
                pass
        finally:
            await gen.aclose()
            try:
                await response.write_eof()
            except Exception:
                pass
        return response

    @routes.post("/lazycomfy/api/llm/search")
    @_json_handler
    async def llm_search(request):
        try:
            body = await request.json()
        except Exception as e:
            raise LazyComfyError("invalid_request", f"Request body must be JSON: {e}")
        query = body.get("query")
        if not isinstance(query, str) or not query.strip():
            raise LazyComfyError("invalid_request", "query is required")
        session = await queue.get_session(request)
        return {"repos": await llm.hf_search(session, query.strip())}

    @routes.post("/lazycomfy/api/llm/files")
    @_json_handler
    async def llm_files(request):
        try:
            body = await request.json()
        except Exception as e:
            raise LazyComfyError("invalid_request", f"Request body must be JSON: {e}")
        repo_id = body.get("repo_id")
        if not isinstance(repo_id, str) or not repo_id.strip():
            raise LazyComfyError("invalid_request", "repo_id is required")
        session = await queue.get_session(request)
        return await llm.hf_files(session, repo_id.strip())

    @routes.post("/lazycomfy/api/llm/download")
    @_json_handler
    async def llm_download_start(request):
        try:
            body = await request.json()
        except Exception as e:
            raise LazyComfyError("invalid_request", f"Request body must be JSON: {e}")
        url = body.get("url")
        name = body.get("name")
        if not isinstance(url, str) or not url.strip():
            raise LazyComfyError("invalid_request", "url is required")
        return await llm.start_llm_download(url, name)

    @routes.get("/lazycomfy/api/llm/download/{task_id}")
    @_json_handler
    async def llm_download_status(request):
        task = llm.get_llm_task(request.match_info["task_id"])
        if task is None:
            raise LazyComfyError("unknown_task", "No such download task")
        return task

    @routes.post("/lazycomfy/api/llm/download/cancel/{task_id}")
    @_json_handler
    async def llm_download_cancel(request):
        return {"cancelled": llm.cancel_llm_download(request.match_info["task_id"])}

    instance.app.add_routes(routes)
    instance.app.add_routes([web.static("/lazycomfy/static", _STATIC_DIR)])
    logger.info("LazyComfy: registered routes under /lazycomfy")
