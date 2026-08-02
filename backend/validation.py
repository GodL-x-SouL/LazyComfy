import logging
import os
import random

from . import LazyComfyError
from .config import MAX_UPLOAD_MB
from .models import _file_list

logger = logging.getLogger("lazycomfy")

ALLOWED_CONTENT_TYPES = {"image/png", "image/jpeg", "image/webp"}
MAX_SEED = 2**63 - 1
MAX_UPLOAD_BYTES = MAX_UPLOAD_MB * 1024 * 1024

FILE_KINDS = {
    "unet": "unet_file",
    "uncond": "uncond_file",
    "clip": "clip_file",
    "vae": "vae_file",
}
FILE_DIRS = {
    "unet": "diffusion_models",
    "uncond": "diffusion_models",
    "clip": "text_encoders",
    "vae": "vae",
}


def error_response(error_type, message, details=None):
    body = {"error": {"type": error_type, "message": message}}
    if details is not None:
        body["error"]["details"] = details
    return body


def _int_param(body, name, lo, hi, default):
    raw = body.get(name)
    if raw is None:
        return default
    try:
        value = int(raw)
    except (TypeError, ValueError):
        raise LazyComfyError("invalid_request", f"{name} must be an integer")
    if not (lo <= value <= hi):
        raise LazyComfyError("invalid_request", f"{name} must be between {lo} and {hi}")
    return value


def _float_param(body, name):
    raw = body.get(name)
    if raw is None:
        return None
    try:
        return float(raw)
    except (TypeError, ValueError):
        raise LazyComfyError("invalid_request", f"{name} must be a number")


def validate_generate_request(body, models_by_id, workflow_map):
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

    negative_prompt = body.get("negative_prompt")
    if negative_prompt is not None and not isinstance(negative_prompt, str):
        raise LazyComfyError("invalid_prompt", "negative_prompt must be a string")
    if not model["supports_negative"]:
        negative_prompt = None

    limits = model["limits"]
    defaults = model["defaults"]

    width = _int_param(body, "width", limits["width_min"], limits["width_max"], defaults["width"])
    height = _int_param(body, "height", limits["height_min"], limits["height_max"], defaults["height"])
    adjusted = False
    rounded_w = max(limits["width_min"], (width // 16) * 16)
    rounded_h = max(limits["height_min"], (height // 16) * 16)
    if rounded_w != width:
        width = rounded_w
        adjusted = True
    if rounded_h != height:
        height = rounded_h
        adjusted = True

    steps = _int_param(body, "steps", limits["steps_min"], limits["steps_max"], defaults["steps"])

    raw_cfg = _float_param(body, "cfg")
    cfg = float(defaults["cfg"]) if raw_cfg is None else raw_cfg
    cfg = max(limits["cfg_min"], min(limits["cfg_max"], cfg))
    cfg = float(cfg)

    samplers = model["options"].get("samplers") or []
    sampler = body.get("sampler", defaults["sampler"])
    if not isinstance(sampler, str) or sampler not in samplers:
        sampler = defaults["sampler"]

    schedulers = model["options"].get("schedulers") or []
    scheduler = body.get("scheduler", defaults["scheduler"])
    if not isinstance(scheduler, str) or scheduler not in schedulers:
        scheduler = defaults["scheduler"]

    fill_keys = set(workflow_map[template_id]["fill"].keys())
    file_params = {}
    raw_files = body.get("files")
    if raw_files is not None:
        if not isinstance(raw_files, dict):
            raise LazyComfyError("invalid_request", "files must be an object mapping kind to file name")
        for kind, fname in raw_files.items():
            key = FILE_KINDS.get(kind)
            if key is None:
                raise LazyComfyError("invalid_request", f"Unknown file kind '{kind}'")
            if key not in fill_keys:
                raise LazyComfyError("invalid_request", f"File kind '{kind}' is not supported by this workflow")
            if not isinstance(fname, str) or not fname or fname != os.path.basename(fname) or ".." in fname:
                raise LazyComfyError("invalid_request", f"Invalid file name for '{kind}'")
            dir_name = FILE_DIRS[kind]
            if fname not in _file_list(dir_name):
                raise LazyComfyError("invalid_request", f"File '{fname}' is not present on this machine")
            file_params[key] = fname

    raw_seed = body.get("seed")
    if raw_seed is None:
        seed = random.randint(0, MAX_SEED)
    else:
        try:
            seed = int(raw_seed)
        except (TypeError, ValueError):
            raise LazyComfyError("invalid_request", "seed must be an integer")
        if not (0 <= seed <= MAX_SEED):
            raise LazyComfyError("invalid_request", "seed out of range")

    batch = _int_param(body, "batch", 1, limits["batch_max"], defaults["batch"])
    if mode == "i2i":
        batch = 1

    raw_denoise = _float_param(body, "denoise")
    denoise = float(defaults["denoise"]) if raw_denoise is None else raw_denoise
    if not (limits["denoise_min"] <= denoise <= limits["denoise_max"]):
        raise LazyComfyError("invalid_request", f"denoise must be between {limits['denoise_min']} and {limits['denoise_max']}")

    image = None
    if mode == "i2i":
        raw_image = body.get("image")
        if not isinstance(raw_image, dict):
            raise LazyComfyError("invalid_request", "image is required for image-to-image")
        name = raw_image.get("name")
        subfolder = raw_image.get("subfolder") or ""
        if not isinstance(name, str) or not name:
            raise LazyComfyError("invalid_request", "image.name is required")
        if not isinstance(subfolder, str):
            raise LazyComfyError("invalid_request", "image.subfolder must be a string")
        if "/" in name or "\\" in name or ".." in name or "/" in subfolder or "\\" in subfolder or ".." in subfolder:
            raise LazyComfyError("invalid_request", "Invalid image path")
        image = {"name": name, "subfolder": subfolder}

    mu = None
    std = None
    preset = None
    steps_explicit = body.get("steps") is not None
    raw_preset = body.get("preset")
    if raw_preset is not None:
        presets = model["options"].get("presets")
        matched = None
        if isinstance(raw_preset, str) and presets:
            for opt in presets.get("options", []):
                if opt.get("id") == raw_preset:
                    matched = opt
                    break
        if matched is None:
            raise LazyComfyError("invalid_request", f"Unknown preset '{raw_preset}'")
        preset = raw_preset
        if not steps_explicit and "steps" in matched:
            steps = matched["steps"]
        if "mu" in matched:
            mu = matched["mu"]
        if "std" in matched:
            std = matched["std"]

    client_id = body.get("client_id")
    if client_id is not None and not isinstance(client_id, str):
        client_id = None

    values = {
        "prompt": prompt,
        "width": width,
        "height": height,
        "batch": batch,
        "seed": seed,
        "steps": steps,
        "cfg": cfg,
        "sampler": sampler,
        "scheduler": scheduler,
        "denoise": denoise,
        "image": image,
    }
    if mu is not None:
        values["mu"] = mu
    if std is not None:
        values["std"] = std
    values.update(file_params)
    params = {k: v for k, v in values.items() if k in fill_keys}

    meta_params = {k: v for k, v in params.items() if k not in ("image", "prompt")}
    if preset is not None:
        meta_params["preset"] = preset

    extra_data = {
        "lazycomfy": {
            "model_id": model_id,
            "template_id": template_id,
            "mode": mode,
            "prompt": prompt,
            "negative_prompt": negative_prompt,
            "params": meta_params,
            "adjusted": adjusted,
        }
    }
    if client_id is not None:
        extra_data["lazycomfy"]["client_id"] = client_id

    return params, extra_data


def validate_upload(content_type, size):
    if content_type not in ALLOWED_CONTENT_TYPES:
        raise LazyComfyError(
            "invalid_file_type",
            f"Only PNG, JPEG and WebP images are allowed (got {content_type or 'unknown type'})",
        )
    if size > MAX_UPLOAD_BYTES:
        raise LazyComfyError("file_too_large", f"Image exceeds the {MAX_UPLOAD_MB} MB upload limit")
