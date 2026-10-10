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

    # Qwen Image 2.1 reference resolution budget (0 = native size, else ~N×N).
    resolution = None
    if model_id in ("qwen_image_2_1", "qwen_image_2_1_turbo") and mode == "i2i":
        resolution = _int_param(body, "resolution", 0, 4096, model["defaults"].get("resolution", 1024))

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
    if mode == "t2i":
        denoise = 1.0
    else:
        denoise = float(defaults["denoise"]) if raw_denoise is None else raw_denoise
        if not (limits["denoise_min"] <= denoise <= limits["denoise_max"]):
            raise LazyComfyError("invalid_request", f"denoise must be between {limits['denoise_min']} and {limits['denoise_max']}")

    image = None
    images = None
    if mode == "i2i":
        max_images = int(model.get("max_images", 1) or 1)
        max_images = max(1, min(10, max_images))

        def _clean_image_entry(entry):
            if not isinstance(entry, dict):
                raise LazyComfyError("invalid_request", "each image must be an object with 'name'")
            name = entry.get("name")
            subfolder = entry.get("subfolder") or ""
            if not isinstance(name, str) or not name:
                raise LazyComfyError("invalid_request", "image.name is required")
            if not isinstance(subfolder, str):
                raise LazyComfyError("invalid_request", "image.subfolder must be a string")
            if "/" in name or "\\" in name or ".." in name or "/" in subfolder or "\\" in subfolder or ".." in subfolder:
                raise LazyComfyError("invalid_request", "Invalid image path")
            return {"name": name, "subfolder": subfolder}

        raw_images = body.get("images")
        raw_image = body.get("image")
        if raw_images is not None:
            if not isinstance(raw_images, list) or not (1 <= len(raw_images) <= max_images):
                raise LazyComfyError("invalid_request", f"images must be a list of 1 to {max_images} items")
            images = [_clean_image_entry(e) for e in raw_images]
            image = images[0]
        elif raw_image is not None:
            # single-image callers (older UI + all non-Qwen models)
            image = _clean_image_entry(raw_image)
            if max_images > 1:
                images = [image]
        else:
            raise LazyComfyError("invalid_request", "image is required for image-to-image")

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
        if not steps_explicit and matched.get("steps") is not None:
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
    if model["supports_negative"]:
        values["negative_prompt"] = negative_prompt or ""
    if resolution is not None:
        values["resolution"] = resolution
    if images is not None:
        values["images"] = images
    if mu is not None:
        values["mu"] = mu
    if std is not None:
        values["std"] = std
    values.update(file_params)
    raw_lora = body.get("lora_name")
    lora_strength = 1.0
    raw_loras = body.get("loras")
    if raw_loras is not None:
        if not isinstance(raw_loras, list) or not raw_loras or len(raw_loras) > 5:
            raise LazyComfyError("invalid_request", "loras must be a list of 1 to 5 items")
        parsed = []
        for entry in raw_loras:
            if not isinstance(entry, dict):
                raise LazyComfyError("invalid_request", "each loras entry must be an object with 'name' and 'strength'")
            name = entry.get("name")
            if not isinstance(name, str) or name != os.path.basename(name) or ".." in name:
                raise LazyComfyError("invalid_request", "Invalid lora name")
            if name not in _file_list("loras"):
                raise LazyComfyError("invalid_request", f"LoRA '{name}' is not present on this machine")
            strength = _float_param(entry, "strength")
            strength = float(strength) if strength is not None else 1.0
            strength = max(0.0, min(5.0, strength))
            parsed.append({"name": name, "strength": strength})
        values["loras"] = parsed
    elif raw_lora is not None and raw_lora != "":
        if not isinstance(raw_lora, str) or raw_lora != os.path.basename(raw_lora) or ".." in raw_lora:
            raise LazyComfyError("invalid_request", "Invalid lora name")
        if raw_lora not in _file_list("loras"):
            raise LazyComfyError("invalid_request", f"LoRA '{raw_lora}' is not present on this machine")
        raw_strength = _float_param(body, "lora_strength")
        lora_strength = float(raw_strength) if raw_strength is not None else 1.0
        lora_strength = max(0.0, min(5.0, lora_strength))
        values["lora_name"] = raw_lora
        values["lora_strength"] = lora_strength

    params = {k: v for k, v in values.items() if k in fill_keys}
    if "lora_name" in values:
        params["lora_name"] = values["lora_name"]
        params["lora_strength"] = values["lora_strength"]
    if "loras" in values:
        params["loras"] = values["loras"]
    if "images" in values:
        params["images"] = values["images"]

    meta_params = {k: v for k, v in params.items() if k not in ("image", "images", "prompt")}
    if mode == "t2i":
        meta_params.pop("denoise", None)
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
