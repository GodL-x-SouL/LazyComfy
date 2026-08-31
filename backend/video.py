"""Video generation backend for MiniMax H3 and LTX 2.5.

Provides config listing, workflow building, and helpers for t2v / i2v.
Reuses queue + hub infrastructure; workflows live in workflows/*.json
and are filled via workflows.build_workflow.
"""
import logging
import os
import random
import shutil
import urllib.parse

from . import LazyComfyError
from . import hub
from . import queue
from .config import WORKFLOWS_DIR

logger = logging.getLogger("lazycomfy")

try:
    import folder_paths
except Exception:
    folder_paths = None

VIDEO_MODELS = [
    {
        "id": "minimax_h3",
        "name": "MiniMax H3",
        "family": "MiniMax H3 · 33B omni DIT · 24fps AV joint",
        "tagline": "Open-weights AV video — T2V / I2V / R2V with synced audio. 768p short edge locally.",
        "modes": ["t2i", "i2i"],
        "supports_negative": False,
        "files": [
            {"kind": "unet", "label": "Diffusion model (FL2VA)", "dir": "diffusion_models", "name": "minimax_h3_fl2va_pruned_int8_convrot.safetensors"},
            {"kind": "clip", "label": "Text encoder (Qwen3-VL 32B)", "dir": "text_encoders", "name": "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"},
            {"kind": "vae", "label": "Video VAE", "dir": "vae", "name": "minimax_h3_video_vae_fp16.safetensors"},
            {"kind": "audio_vae", "label": "Audio VAE", "dir": "vae", "name": "minimax_h3_audio_vae_fp32.safetensors"},
        ],
        "defaults": {"width": 1344, "height": 768, "length": 124, "steps": 20, "fps": 24, "sampler": "res_multistep", "scheduler": "simple"},
        "limits": {"width_min": 32, "width_max": 2048, "height_min": 32, "height_max": 2048, "length_min": 5, "length_max": 361, "steps_min": 1, "steps_max": 50},
        "options": {"samplers": ["res_multistep", "euler", "euler_ancestral", "dpmpp_2m", "heun"], "schedulers": ["simple", "normal", "karras", "exponential"]},
        "tip": "768p native: 1344x768 (16:9, 0.98MP). Duration snaps to 17k+5 frames (124=~5s at 24fps).",
    },
    {
        "id": "ltx_2_5",
        "name": "LTX 2.5",
        "family": "Lightricks LTX-2.5 · 22B distilled · 4K HDR, 50fps AV",
        "tagline": "Distilled fast AV generation — T2V / I2V, 8 steps distilled, synced audio.",
        "modes": ["t2i", "i2i"],
        "supports_negative": False,
        "files": [
            {"kind": "unet", "label": "Diffusion model (22B distilled)", "dir": "diffusion_models", "name": "ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors"},
            {"kind": "clip", "label": "Text encoder (Gemma 4 12B)", "dir": "text_encoders", "name": "gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors"},
            {"kind": "vae", "label": "Video VAE", "dir": "vae", "name": "ltx-2.5-video-vae-bf16.safetensors"},
            {"kind": "audio_vae", "label": "Audio VAE", "dir": "vae", "name": "ltx-2.5-audio-vae-bf16.safetensors"},
        ],
        "defaults": {"width": 1280, "height": 736, "length": 97, "steps": 8, "fps": 24, "sampler": "euler_ancestral", "scheduler": "simple"},
        "limits": {"width_min": 64, "width_max": 2048, "height_min": 64, "height_max": 2048, "length_min": 9, "length_max": 257, "steps_min": 1, "steps_max": 50},
        "options": {"samplers": ["euler_ancestral", "euler", "dpmpp_2m", "heun", "res_2s"], "schedulers": ["simple", "normal", "karras"]},
        "tip": "Default 1280x720, 97 frames (~4s @24fps, 8k+1 grid). Distilled uses 8 steps + Euler ancestral.",
    },
]

VIDEO_ASPECTS = [
    {"label": "16:9 Widescreen", "width": 1280, "height": 736},
    {"label": "9:16 Portrait", "width": 736, "height": 1280},
    {"label": "1:1 Square", "width": 768, "height": 768},
    {"label": "16:9 Wide", "width": 1344, "height": 768},
    {"label": "4:3 Landscape", "width": 1024, "height": 768},
]

def _models_root():
    if folder_paths is not None:
        try:
            dirs = folder_paths.get_folder_paths("diffusion_models")
            if dirs:
                return os.path.dirname(dirs[0])
        except Exception:
            pass
    return os.environ.get("LAZYCOMFY_MODELS_DIR")

def _file_list(folder_name):
    if folder_paths is not None:
        try:
            return folder_paths.get_filename_list(folder_name)
        except Exception:
            pass
    root = os.environ.get("LAZYCOMFY_MODELS_DIR")
    if root:
        base = os.path.join(root, folder_name)
        try:
            return sorted(
                n for n in os.listdir(base)
                if os.path.isfile(os.path.join(base, n)) and n.lower().endswith((".safetensors", ".ckpt", ".pt", ".pth", ".bin"))
            )
        except OSError:
            return []
    return []

def list_video_models_with_files():
    import copy
    avail = {}
    for m in VIDEO_MODELS:
        for f in m["files"]:
            if f["dir"] not in avail:
                avail[f["dir"]] = set(_file_list(f["dir"]))
    out = copy.deepcopy(VIDEO_MODELS)
    for model in out:
        for f in model["files"]:
            f["present"] = f["name"] in avail.get(f["dir"], set())
        model["options"]["aspects"] = VIDEO_ASPECTS
    return out

def get_video_model(model_id):
    for m in VIDEO_MODELS:
        if m["id"] == model_id:
            return m
    return None

def _folder_path(kind):
    if folder_paths is not None:
        try:
            if kind == "input":
                return folder_paths.get_input_directory()
            if kind == "output":
                return folder_paths.get_output_directory()
            dirs = folder_paths.get_folder_paths(kind)
            if dirs:
                return dirs[0]
        except Exception:
            pass
        try:
            base = getattr(folder_paths, "base_path", None)
            if base:
                return os.path.join(base, kind)
        except Exception:
            pass
    root = os.environ.get("LAZYCOMFY_MODELS_DIR")
    if root:
        return os.path.join(root, kind)
    return None

def video_input_dir():
    return _folder_path("input")

def video_output_dir():
    return _folder_path("output")

def frame_count_for_duration(duration_seconds, fps=24):
    # MiniMax H3 grid 17k+5, LTX grid 8k+1 ; approximate for UI
    # Use 17k+5 for minimax, 8k+1 for ltx — caller should snap accordingly
    # generic: round(duration*fps) snap to nearest valid
    n = max(1, int(round(duration_seconds * fps)))
    # snap to 17k+5 (common for H3) — also valid for LTX? LTX uses 8k+1 but 17k+5 will also pass after modulo adjust in node
    while n % 17 != 5:
        n += 1
    # for LTX 8k+1 grid, also ensure: (n-1)%8==0, but the above also approximates; LTX nodes will internally clamp
    return n

def config_payload():
    return {
        "models": list_video_models_with_files(),
        "input_dir": video_input_dir(),
        "output_dir": video_output_dir(),
    }

def validate_video_request(body, models_by_id, workflow_map):
    if not isinstance(body, dict):
        raise LazyComfyError("invalid_request", "Request body must be a JSON object")
    model_id = body.get("model_id")
    if not isinstance(model_id, str) or model_id not in models_by_id:
        raise LazyComfyError("invalid_request", "Unknown model_id")
    model = models_by_id[model_id]
    mode = body.get("mode")
    if mode not in ("t2i", "i2i") or mode not in model["modes"]:
        raise LazyComfyError("invalid_request", f"Mode '{mode}' is not supported for model '{model_id}'")
    template_ids = [tid for tid, d in workflow_map.items() if d["model_id"] == model_id and d["mode"] == mode]
    if not template_ids:
        raise LazyComfyError("invalid_request", f"No workflow exists for {model_id} / {mode}")
    template_id = template_ids[0]

    prompt = body.get("prompt")
    if not isinstance(prompt, str):
        raise LazyComfyError("invalid_prompt", "prompt must be a string")
    if mode == "t2i" and not prompt.strip():
        raise LazyComfyError("invalid_prompt", "Prompt is required")

    limits = model["limits"]
    defaults = model["defaults"]
    # width/height
    def _int_param(name, lo, hi, default):
        raw = body.get(name)
        if raw is None:
            return default
        try:
            v = int(raw)
        except Exception:
            raise LazyComfyError("invalid_request", f"{name} must be an integer")
        if not (lo <= v <= hi):
            raise LazyComfyError("invalid_request", f"{name} must be between {lo} and {hi}")
        return v

    width = _int_param("width", limits["width_min"], limits["width_max"], defaults["width"])
    height = _int_param("height", limits["height_min"], limits["height_max"], defaults["height"])
    # snap to 32 multiple (video canvas requirement) — round-half-up to preserve 1280x720 etc
    def _snap32(v, lo, hi):
        snapped = ((int(v) + 16) // 32) * 32
        snapped = max(lo, min(hi, snapped))
        if snapped < lo:
            snapped = lo + ((lo - snapped + 31)//32)*32
        return snapped
    width = _snap32(width, limits["width_min"], limits["width_max"])
    height = _snap32(height, limits["height_min"], limits["height_max"])

    # length (frames) — allow either length or duration
    length = body.get("length")
    duration = body.get("duration")
    if length is None and duration is not None:
        try:
            duration = float(duration)
            fps = int(body.get("fps", defaults.get("fps", 24)))
            length = frame_count_for_duration(duration, fps)
        except Exception:
            length = defaults["length"]
    if length is None:
        length = defaults["length"]
    try:
        length = int(length)
    except Exception:
        raise LazyComfyError("invalid_request", "length must be an integer")
    if not (limits["length_min"] <= length <= limits["length_max"]):
        raise LazyComfyError("invalid_request", f"length must be between {limits['length_min']} and {limits['length_max']}")

    # fps
    try:
        fps = int(body.get("fps", defaults.get("fps", 24)))
    except Exception:
        fps = defaults.get("fps", 24)
    fps = max(1, min(60, fps))

    steps = _int_param("steps", limits["steps_min"], limits["steps_max"], defaults["steps"])

    # sampler/scheduler
    samplers = model["options"].get("samplers") or []
    sampler = body.get("sampler", defaults["sampler"])
    if not isinstance(sampler, str) or sampler not in samplers:
        sampler = defaults["sampler"]
    schedulers = model["options"].get("schedulers") or []
    scheduler = body.get("scheduler", defaults["scheduler"])
    if not isinstance(scheduler, str) or scheduler not in schedulers:
        scheduler = defaults["scheduler"]

    # files overrides
    from .validation import FILE_KINDS, FILE_DIRS
    fill_keys = set(workflow_map[template_id]["fill"].keys())
    file_params = {}
    raw_files = body.get("files")
    if raw_files is not None:
        if not isinstance(raw_files, dict):
            raise LazyComfyError("invalid_request", "files must be an object")
        for kind, fname in raw_files.items():
            # video may use audio_vae mapping extra
            if kind == "audio_vae":
                key = "audio_vae_file"
            else:
                key = FILE_KINDS.get(kind)
                if key is None and kind not in ("audio_vae",):
                    raise LazyComfyError("invalid_request", f"Unknown file kind '{kind}'")
                if key is None:
                    key = "audio_vae_file"
            if key not in fill_keys:
                # silently ignore if not needed
                continue
            if not isinstance(fname, str) or not fname or fname != os.path.basename(fname) or ".." in fname:
                raise LazyComfyError("invalid_request", f"Invalid file name for '{kind}'")
            # dir for check
            dir_map = {"unet": "diffusion_models", "uncond": "diffusion_models", "clip": "text_encoders", "vae": "vae", "audio_vae": "vae", "lora": "loras"}
            dir_name = dir_map.get(kind, "diffusion_models")
            if fname not in _file_list(dir_name):
                raise LazyComfyError("invalid_request", f"File '{fname}' is not present on this machine")
            file_params[key] = fname
    # also direct audio_vae_file override via body
    if "audio_vae_file" in body and "audio_vae_file" not in file_params:
        av = body.get("audio_vae_file")
        if isinstance(av, str) and av and av == os.path.basename(av) and ".." not in av:
            if av in _file_list("vae"):
                file_params["audio_vae_file"] = av

    # seed
    raw_seed = body.get("seed")
    MAX_SEED = 2**63 - 1
    if raw_seed is None:
        seed = random.randint(0, MAX_SEED)
    else:
        try:
            seed = int(raw_seed)
        except Exception:
            raise LazyComfyError("invalid_request", "seed must be an integer")
        if not (0 <= seed <= MAX_SEED):
            raise LazyComfyError("invalid_request", "seed out of range")

    # image for i2i
    image = None
    if mode == "i2i":
        raw_image = body.get("image")
        if not isinstance(raw_image, dict):
            # also allow image string path?
            if isinstance(body.get("image"), str):
                # treat as filename in input dir
                raw_image = {"name": os.path.basename(body.get("image")), "subfolder": ""}
            else:
                raise LazyComfyError("invalid_request", "image is required for image-to-video")
        name = raw_image.get("name")
        subfolder = raw_image.get("subfolder") or ""
        if not isinstance(name, str) or not name:
            raise LazyComfyError("invalid_request", "image.name is required")
        if not isinstance(subfolder, str):
            raise LazyComfyError("invalid_request", "image.subfolder must be a string")
        if "/" in name or "\\" in name or ".." in name or "/" in subfolder or "\\" in subfolder or ".." in subfolder:
            raise LazyComfyError("invalid_request", "Invalid image path")
        image = {"name": name, "subfolder": subfolder}

    client_id = body.get("client_id")
    if client_id is not None and not isinstance(client_id, str):
        client_id = None

    values = {
        "prompt": prompt,
        "width": width,
        "height": height,
        "length": length,
        "fps": fps,
        "seed": seed,
        "steps": steps,
        "sampler": sampler,
        "scheduler": scheduler,
        "image": image,
    }
    values.update(file_params)

    # only keep keys that workflow fill expects
    params = {k: v for k, v in values.items() if k in fill_keys}
    # keep image separately? workflows fill expects image key
    if image is not None and "image" in fill_keys:
        params["image"] = image["name"] if isinstance(image, dict) else image

    # Build extra_data meta for history/gallery
    meta_params = {k: v for k, v in params.items() if k not in ("image", "prompt")}
    # convert image back to dict for meta?
    extra_data = {
        "lazycomfy": {
            "model_id": model_id,
            "template_id": template_id,
            "mode": mode,
            "prompt": prompt,
            "params": meta_params,
            "video": True,
        }
    }
    if client_id is not None:
        extra_data["lazycomfy"]["client_id"] = client_id
    return params, extra_data

def missing_files(model_id, overrides=None):
    model = get_video_model(model_id)
    if not model:
        return []
    available = {}
    for f in model["files"]:
        d = f["dir"]
        if d not in available:
            available[d] = set(_file_list(d))
    overrides = overrides or {}
    missing = []
    kind_map = {"unet": "unet_file", "clip": "clip_file", "vae": "vae_file", "audio_vae": "audio_vae_file"}
    # map label handling
    for f in model["files"]:
        key = None
        for k, v in kind_map.items():
            if f["kind"] == k:
                key = v
                break
        name = overrides.get(key, f["name"]) if key else f["name"]
        if name not in available.get(f["dir"], set()):
            missing.append({"kind": f["kind"], "label": f["label"], "dir": f["dir"], "name": name})
    return missing

def _collect_videos(entry):
    videos = []
    try:
        outputs = entry.get("outputs") or {}
        for node_id, node_out in outputs.items():
            if not isinstance(node_out, dict):
                continue
            # videos can be in 'gifs', 'videos', 'images' with video extension?
            for key in ("gifs", "videos", "images"):
                for item in (node_out.get(key) or []):
                    if not isinstance(item, dict):
                        continue
                    filename = item.get("filename")
                    if not filename:
                        continue
                    # check if looks like video
                    if filename.lower().endswith((".mp4", ".webm", ".mov", ".avi", ".mkv")) or key in ("gifs", "videos"):
                        subfolder = item.get("subfolder") or ""
                        ftype = item.get("type") or "output"
                        videos.append({
                            "filename": filename,
                            "subfolder": subfolder,
                            "type": ftype,
                            "url": "/view?" + urllib.parse.urlencode({"filename": filename, "subfolder": subfolder, "type": ftype}),
                        })
                    elif key == "images" and filename.lower().endswith((".mp4", ".webm")):
                        subfolder = item.get("subfolder") or ""
                        ftype = item.get("type") or "output"
                        videos.append({
                            "filename": filename,
                            "subfolder": subfolder,
                            "type": ftype,
                            "url": "/view?" + urllib.parse.urlencode({"filename": filename, "subfolder": subfolder, "type": ftype}),
                        })
            # also direct PreviewVideo uses 'gifs' already handled, but also fallback handle any preview
    except Exception:
        pass
    # fallback: if no videos found but there are images that are actually video previews (ComfyUI stores video as gifs)
    # also check for preview images that are not videos but we treat as videos if entry is video model?
    # If still empty, try generic collect_images logic but filter video-like? Instead also check for 'gifs' in ui preview?
    # For video models, also include images collection as fallback for thumb?
    if not videos:
        try:
            # try to collect anything with .mp4 extension via _collect_images logic extra
            from .queue import _collect_images
            imgs = _collect_images(entry)
            # imgs may contain video files mislabeled as images; return them if they look like video?
            for im in imgs:
                if im["filename"].lower().endswith((".mp4", ".webm", ".mov", ".mkv", ".gif")):
                    videos.append(im)
        except Exception:
            pass
    return videos

async def recent_video_jobs(limit=12, session=None):
    status, data = await queue.http_json("GET", "/history", session)
    jobs = []
    if status != 200 or not isinstance(data, dict):
        return jobs
    for prompt_id, entry in data.items():
        if not isinstance(entry, dict):
            continue
        # extract meta
        meta = None
        try:
            prompt = entry.get("prompt")
            if isinstance(prompt, list) and len(prompt) > 3:
                extra = prompt[3]
                if isinstance(extra, dict):
                    meta = extra.get("lazycomfy")
        except Exception:
            pass
        if not meta or not meta.get("video"):
            continue
        status_info = entry.get("status") or {}
        status_str = status_info.get("status_str") or "unknown"
        messages = status_info.get("messages") or []
        timestamp = 0
        for msg in messages:
            try:
                ts = msg[0]
                if isinstance(ts, (int, float)) and ts > timestamp:
                    timestamp = ts
            except Exception:
                continue
        videos = _collect_videos(entry)
        # fallback to images if no video yet but entry is video model (maybe still sampling)
        from .queue import _collect_images
        images = _collect_images(entry)
        jobs.append({
            "prompt_id": prompt_id,
            "status": status_str,
            "timestamp": timestamp,
            "model_id": meta.get("model_id"),
            "mode": meta.get("mode"),
            "prompt": meta.get("prompt"),
            "params": meta.get("params"),
            "videos": videos,
            "images": images,
        })
    jobs.sort(key=lambda j: j["timestamp"], reverse=True)
    return jobs[:limit]

async def video_result(prompt_id, session=None):
    entry = await queue.history_entry(prompt_id, session)
    if entry is None:
        # check queue
        if await queue._in_queue(prompt_id, session):
            return {"status": "running", "outputs": [], "videos": [], "meta": None, "error": None}
        return {"status": "unknown", "outputs": [], "videos": [], "meta": None, "error": None}
    # extract meta
    meta = None
    try:
        prompt = entry.get("prompt")
        if isinstance(prompt, list) and len(prompt) > 3:
            extra = prompt[3]
            if isinstance(extra, dict):
                meta = extra.get("lazycomfy")
    except Exception:
        pass
    videos = _collect_videos(entry)
    from .queue import _collect_images
    images = _collect_images(entry)
    outputs = videos if videos else images
    status_info = entry.get("status") or {}
    status_str = status_info.get("status_str") or "unknown"
    if status_str == "success":
        return {"status": "success", "outputs": outputs, "videos": videos, "images": images, "meta": meta, "error": None}
    if status_str == "error":
        error = None
        try:
            for msg in status_info.get("messages") or []:
                if not (isinstance(msg, list) and len(msg) > 1):
                    continue
                md = msg[1]
                if not isinstance(md, dict) or md.get("type") != "execution_error":
                    continue
                inner = md.get("data") or {}
                error = {"type": inner.get("exception_type"), "message": inner.get("exception_message")}
                break
        except Exception:
            pass
        return {"status": "error", "outputs": outputs, "videos": videos, "images": images, "meta": meta, "error": error}
    if not status_info.get("completed"):
        return {"status": "running", "outputs": outputs, "videos": videos, "images": images, "meta": meta, "error": None}
    return {"status": "unknown", "outputs": outputs, "videos": videos, "images": images, "meta": meta, "error": None}

