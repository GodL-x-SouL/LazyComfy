import asyncio
import logging
import json
import os
import random
import time
import traceback

from . import LazyComfyError
from . import files
from . import hub
from . import llm
from . import queue
from . import session
from . import upscale
from . import video as video_module
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
video_models_by_id = {m["id"]: m for m in video_module.VIDEO_MODELS}
_STATIC_DIR = os.path.join(WEB_DIR, "static")
_INDEX_PATH = os.path.join(WEB_DIR, "index.html")
_FORGE_PATH = os.path.join(WEB_DIR, "forge.html")
_UPSCALE_PATH = os.path.join(WEB_DIR, "upscale.html")
_VIDEO_PATH = os.path.join(WEB_DIR, "video.html")


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


async def _upscale_config_handler(request):
    return upscale.config_payload()


async def _upscale_images_handler(request):
    return upscale.list_dir_images(request.query.get("dir") or "")


async def _upscale_preview_handler(request):
    path = request.query.get("path") or ""
    if not upscale.is_preview_allowed(path):
        raise LazyComfyError("bad_path", "Preview not allowed for this path")
    return web.FileResponse(os.path.abspath(os.path.expanduser(path)), headers={"Cache-Control": "no-cache"})


async def _upscale_generate_handler(request):
    try:
        body = await request.json()
    except Exception as e:
        raise LazyComfyError("invalid_request", f"Request body must be JSON: {e}")
    unet = body.get("unet")
    vae = body.get("vae")
    image = body.get("image")
    if not isinstance(unet, str) or not unet.strip():
        raise LazyComfyError("invalid_request", "SeedVR2 model is required")
    if not isinstance(vae, str) or not vae.strip():
        raise LazyComfyError("invalid_request", "VAE is required")
    if not isinstance(image, str) or not image.strip():
        raise LazyComfyError("invalid_request", "Image is required")
    if unet not in upscale.list_seedvr_unets():
        raise LazyComfyError("invalid_request", f"SeedVR2 model not found on this machine: {unet}")
    if vae not in upscale.list_vaes():
        raise LazyComfyError("invalid_request", f"VAE not found on this machine: {vae}")
    image_name = upscale.ensure_in_input(image)
    try:
        scale = max(1.0, min(8.0, float(body.get("scale", 4))))
    except (TypeError, ValueError):
        scale = 4.0
    try:
        tile_size = max(64, min(4096, int(body.get("tile_size", 512))))
    except (TypeError, ValueError):
        tile_size = 512
    try:
        tile_overlap = max(0, min(4096, int(body.get("tile_overlap", 128))))
    except (TypeError, ValueError):
        tile_overlap = 128
    color = body.get("color")
    if color not in upscale._COLOR_METHODS:
        color = "none"
    try:
        seed = int(body.get("seed", 0))
    except (TypeError, ValueError):
        seed = 0
    if seed <= 0:
        seed = random.randint(1, 0x7FFFFFFFFFFFFFFF)
    out_dir = body.get("out_dir")
    if not isinstance(out_dir, str):
        out_dir = ""
    out_dir = out_dir.strip()
    prefix = "lazycomfy/seedvr2"
    prompt_dict = upscale.build_workflow(image_name, unet, vae, scale, tile_size, tile_overlap, color, seed, prefix)
    extra_data = {"lazycomfy": {
        "kind": "upscale",
        "model_id": "seedvr2",
        "unet": unet,
        "vae": vae,
        "image": image_name,
        "scale": scale,
        "tile_size": tile_size,
        "tile_overlap": tile_overlap,
        "color": color,
        "seed": seed,
    }}
    client_id = body.get("client_id")
    if not isinstance(client_id, str):
        client_id = "lazycomfy-upscale"
    session = await queue.get_session(request)
    submitted = await queue.submit_prompt(prompt_dict, extra_data, client_id, session)
    upscale.remember_out_dir(submitted["prompt_id"], out_dir)
    return {"prompt_id": submitted["prompt_id"], "number": submitted["number"], "submitted_at": int(time.time())}


async def _upscale_result_handler(request):
    prompt_id = request.match_info["prompt_id"]
    session = await queue.get_session(request)
    result = await queue.result(prompt_id, session)
    if result["status"] == "success":
        saved = upscale.save_outputs(prompt_id, result["outputs"])
        result["saved"] = saved.get("saved")
        result["saved_dir"] = saved.get("dir")
        result["saved_error"] = saved.get("error")
        base = upscale.output_dir()
        if base:
            for img in result.get("outputs") or []:
                src = os.path.join(base, img.get("subfolder") or "", img.get("filename") or "")
                if upscale.output_is_black(src):
                    result["black_output"] = True
                    result["black_hint"] = (
                        "The output is all black — NaN values in the VAE decode. "
                        "On T4 (and other GPUs with bf16) start ComfyUI with --bf16-vae "
                        "so the SeedVR2 VAE runs in bf16 instead of fp16."
                    )
                    break
    return result


async def _upscale_unload_handler(request):
    session = await queue.get_session(request)
    out = await upscale.unload_models(session)
    return {"ok": True, "method": out["method"]}


# ---- Video (MiniMax H3 / LTX 2.5) ----

async def _video_config_handler(request, session):
    try:
        return video_module.config_payload()
    except Exception as e:
        raise LazyComfyError("internal_error", str(e))


async def _video_generate_handler(request):
    try:
        body = await request.json()
    except Exception as e:
        raise LazyComfyError("invalid_request", f"Request body must be JSON: {e}")
    params, extra_data = video_module.validate_video_request(body, video_models_by_id, workflow_map)
    # resolve overrides for missing files check
    overrides = {}
    for kind, key in (("unet", "unet_file"), ("clip", "clip_file"), ("vae", "vae_file"), ("audio_vae", "audio_vae_file")):
        if key in params:
            # map kind for missing_files: vae / audio_vae both check vae folder?
            # video missing_files handles mapping
            pass
    # use video missing_files
    # build overrides dict with file keys as expected by missing_files
    ov = {}
    if "unet_file" in params:
        ov["unet_file"] = params["unet_file"]
    if "clip_file" in params:
        ov["clip_file"] = params["clip_file"]
    if "vae_file" in params:
        ov["vae_file"] = params["vae_file"]
    if "audio_vae_file" in params:
        ov["audio_vae_file"] = params["audio_vae_file"]
    missing = video_module.missing_files(extra_data["lazycomfy"]["model_id"], ov)
    if missing:
        labels = ", ".join(f["label"] for f in missing)
        raise LazyComfyError("missing_model_files", f"Missing: {labels}")
    # image param for i2i is already filename string after validation
    if isinstance(params.get("image"), dict):
        img = params["image"]
        # params already contains string? validate returns dict for image? In our validate we left dict handling but params image case we kept?
        # Ensure params image is string filename
        if isinstance(img, dict):
            params["image"] = f"{img['subfolder']}/{img['name']}" if img.get("subfolder") else img["name"]
        else:
            params["image"] = img
    elif isinstance(params.get("image"), str):
        pass
    # Handle prompt dict building
    prompt_dict = workflow_module.build_workflow(extra_data["lazycomfy"]["template_id"], params)
    session = await queue.get_session(request)
    submitted = await queue.submit_prompt(prompt_dict, extra_data, extra_data["lazycomfy"].get("client_id"), session)
    return {"prompt_id": submitted["prompt_id"], "number": submitted["number"], "submitted_at": int(time.time())}


async def _video_result_handler(request):
    prompt_id = request.match_info["prompt_id"]
    session = await queue.get_session(request)
    return await video_module.video_result(prompt_id, session)


async def _video_cancel_handler(request):
    prompt_id = request.match_info["prompt_id"]
    session = await queue.get_session(request)
    await queue.interrupt(prompt_id, session)
    return {"ok": True}


async def _video_history_handler(request):
    try:
        limit = int(request.query.get("limit", "12"))
    except (TypeError, ValueError):
        limit = 12
    limit = max(1, min(limit, 50))
    session = await queue.get_session(request)
    return {"jobs": await video_module.recent_video_jobs(limit, session)}


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

    @routes.get("/lazycomfy/upscale")
    async def upscale_page(request):
        return web.FileResponse(_UPSCALE_PATH, headers={"Cache-Control": "no-cache"})

    @routes.get("/lazycomfy/video")
    async def video_page(request):
        return web.FileResponse(_VIDEO_PATH, headers={"Cache-Control": "no-cache"})

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

    @routes.get("/lazycomfy/api/session/state")
    @_json_handler
    async def session_state(request):
        return session.snapshot()

    @routes.post("/lazycomfy/api/session/state")
    @_json_handler
    async def session_state_save(request):
        try:
            body = await request.json()
        except Exception as e:
            raise LazyComfyError("invalid_request", f"Request body must be JSON: {e}")
        session.save(body.get("key"), body.get("value"))
        return {"ok": True}

    @routes.get("/lazycomfy/api/upscale/config")
    @_json_handler
    async def upscale_config(request):
        return await _upscale_config_handler(request)

    @routes.get("/lazycomfy/api/upscale/images")
    @_json_handler
    async def upscale_images(request):
        return await _upscale_images_handler(request)

    @routes.get("/lazycomfy/api/upscale/preview")
    async def upscale_preview(request):
        return await _upscale_preview_handler(request)

    @routes.post("/lazycomfy/api/upscale/generate")
    @_json_handler
    async def upscale_generate(request):
        return await _upscale_generate_handler(request)

    @routes.get("/lazycomfy/api/upscale/result/{prompt_id}")
    @_json_handler
    async def upscale_result(request):
        return await _upscale_result_handler(request)

    @routes.post("/lazycomfy/api/upscale/unload")
    @_json_handler
    async def upscale_unload(request):
        return await _upscale_unload_handler(request)

    @routes.get("/lazycomfy/api/files")
    @_json_handler
    async def files_list(request):
        return {"dirs": {name: hub.list_files(name) for name in ("diffusion_models", "text_encoders", "vae", "loras")}}

    @routes.get("/lazycomfy/api/folders")
    @_json_handler
    async def folders_list(request):
        return {"folders": hub.list_allowed_folders()}

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

    @routes.post("/lazycomfy/api/generic/download")
    @_json_handler
    async def generic_download_start(request):
        try:
            body = await request.json()
        except Exception as e:
            raise LazyComfyError("invalid_request", f"Request body must be JSON: {e}")
        url = body.get("url")
        target_dir = body.get("target_dir") or body.get("folder") or body.get("dir")
        if not isinstance(url, str) or not url.strip():
            raise LazyComfyError("invalid_request", "url is required")
        if not isinstance(target_dir, str) or not target_dir.strip():
            raise LazyComfyError("invalid_request", "target_dir is required")
        return await hub.start_generic_download(url.strip(), target_dir.strip())

    @routes.get("/lazycomfy/api/hf_token")
    @_json_handler
    async def hf_token_get(request):
        return hub.hf_token_status()

    @routes.post("/lazycomfy/api/hf_token")
    @_json_handler
    async def hf_token_set(request):
        try:
            body = await request.json()
        except Exception as e:
            raise LazyComfyError("invalid_request", f"Request body must be JSON: {e}")
        token = body.get("token")
        if not isinstance(token, str) or not token.strip():
            raise LazyComfyError("invalid_request", "token is required")
        hub.set_hf_token(token.strip())
        return hub.hf_token_status()

    @routes.delete("/lazycomfy/api/hf_token")
    @_json_handler
    async def hf_token_clear(request):
        hub.clear_hf_token()
        return hub.hf_token_status()

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

    # ---- Video routes ----
    @routes.get("/lazycomfy/api/video/config")
    @_json_handler
    async def video_config(request):
        session = await queue.get_session(request)
        return await _video_config_handler(request, session)

    @routes.get("/lazycomfy/api/video/files")
    @_json_handler
    async def video_files(request):
        # limit dirs for video: diffusion_models, text_encoders, vae, latent_upscale_models, loras
        return {"dirs": {name: hub.list_files(name) for name in ("diffusion_models", "text_encoders", "vae", "latent_upscale_models", "loras")}}

    @routes.post("/lazycomfy/api/video/generate")
    @_json_handler
    async def video_generate(request):
        return await _video_generate_handler(request)

    @routes.get("/lazycomfy/api/video/result/{prompt_id}")
    @_json_handler
    async def video_result(request):
        return await _video_result_handler(request)

    @routes.post("/lazycomfy/api/video/cancel/{prompt_id}")
    @_json_handler
    async def video_cancel(request):
        return await _video_cancel_handler(request)

    @routes.get("/lazycomfy/api/video/history")
    @_json_handler
    async def video_history(request):
        return await _video_history_handler(request)

    @routes.get("/lazycomfy/api/video/queue")
    @_json_handler
    async def video_queue(request):
        session = await queue.get_session(request)
        return {"queue_remaining": await queue.queue_remaining(session)}

    instance.app.add_routes(routes)
    instance.app.add_routes([web.static("/lazycomfy/static", _STATIC_DIR)])
    logger.info("LazyComfy: registered routes under /lazycomfy")
