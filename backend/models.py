import copy
import logging
import os

logger = logging.getLogger("lazycomfy")

try:
    import folder_paths
except Exception:
    folder_paths = None

MODELS = [
    {
        "id": "z_image_turbo",
        "name": "Z Image Turbo",
        "family": "Alibaba Z-Image · S3-DiT 6B · 8-step distilled",
        "tagline": "Fast, bilingual natural-language images in 8 steps.",
        "modes": ["t2i", "i2i"],
        "supports_negative": False,
        "negative_note": "Ignored by this model — only the positive prompt is used.",
        "files": [
            {"kind": "unet", "label": "Diffusion model", "dir": "diffusion_models", "name": "z_image_turbo_bf16.safetensors"},
            {"kind": "clip", "label": "Text encoder", "dir": "text_encoders", "name": "qwen_3_4b.safetensors"},
            {"kind": "vae", "label": "VAE", "dir": "vae", "name": "ae.safetensors"},
        ],
        "defaults": {"width": 1024, "height": 1024, "steps": 8, "cfg": 1.0, "sampler": "res_multistep", "scheduler": "simple", "batch": 1, "denoise": 0.5},
        "limits": {"width_min": 256, "width_max": 2048, "height_min": 256, "height_max": 2048, "steps_min": 1, "steps_max": 10, "cfg_min": 0.5, "cfg_max": 4.0, "batch_max": 4, "denoise_min": 0.05, "denoise_max": 1.0},
        "options": {"cfg_visible": True, "samplers": ["res_multistep", "euler", "euler_ancestral", "heun", "dpmpp_2m"], "schedulers": ["simple", "normal", "karras", "exponential"], "scheduler_fixed": False, "presets": None},
        "notes": [
            "BF16 checkpoint needs ~16 GB VRAM — use the fp8 file for less.",
            "Natural language works best; avoid keyword spam like 'masterpiece, 8k'.",
            "Keep steps near 8 — more steps do not improve quality.",
        ],
        "tip": "Sweet spot: 8 steps, CFG 1.0, 1024×1024.",
    },
    {
        "id": "krea_2_turbo",
        "name": "Krea 2 Turbo",
        "family": "Krea 2 · 12B DiT · 8-step distilled (CFG disabled)",
        "tagline": "Balanced quality and speed with CFG disabled.",
        "modes": ["t2i", "i2i"],
        "supports_negative": False,
        "negative_note": "Ignored by this model — only the positive prompt is used.",
        "files": [
            {"kind": "unet", "label": "Diffusion model", "dir": "diffusion_models", "name": "krea2_turbo_fp8_scaled.safetensors"},
            {"kind": "clip", "label": "Text encoder", "dir": "text_encoders", "name": "qwen3vl_4b_fp8_scaled.safetensors"},
            {"kind": "vae", "label": "VAE", "dir": "vae", "name": "qwen_image_vae.safetensors"},
        ],
        "defaults": {"width": 1024, "height": 1024, "steps": 8, "cfg": 1.0, "sampler": "euler", "scheduler": "simple", "batch": 1, "denoise": 0.5},
        "limits": {"width_min": 256, "width_max": 2048, "height_min": 256, "height_max": 2048, "steps_min": 1, "steps_max": 16, "cfg_min": 1.0, "cfg_max": 1.0, "batch_max": 4, "denoise_min": 0.05, "denoise_max": 1.0},
        "options": {"cfg_visible": False, "samplers": ["euler", "euler_ancestral", "dpmpp_2m", "heun"], "schedulers": ["simple", "normal", "karras"], "scheduler_fixed": False, "presets": None},
        "notes": [
            "Turbo runs with CFG disabled — the guidance control is hidden.",
            "FP8 checkpoint needs ~12 GB VRAM; int8 variant fits less.",
            "LoRAs are Krea-2 specific; SDXL/Flux LoRAs do not transfer.",
        ],
        "tip": "Sweet spot: 8 steps, CFG 1.0, euler/simple.",
    },
    {
        "id": "flux_2_klein_9b",
        "name": "Flux 2 Klein 9B",
        "family": "Black Forest Labs · FLUX.2 [klein] 9B · 4-step distilled",
        "tagline": "The fastest FLUX.2 — distilled for 4-step generation.",
        "modes": ["t2i", "i2i"],
        "supports_negative": False,
        "negative_note": "Ignored by this model — only the positive prompt is used.",
        "files": [
            {"kind": "unet", "label": "Diffusion model", "dir": "diffusion_models", "name": "flux-2-klein-9b-fp8.safetensors"},
            {"kind": "clip", "label": "Text encoder", "dir": "text_encoders", "name": "qwen_3_8b_fp8mixed.safetensors"},
            {"kind": "vae", "label": "VAE", "dir": "vae", "name": "full_encoder_small_decoder.safetensors"},
        ],
        "defaults": {"width": 1024, "height": 1024, "steps": 4, "cfg": 1.0, "sampler": "euler", "scheduler": "simple", "batch": 1, "denoise": 0.5},
        "limits": {"width_min": 256, "width_max": 2048, "height_min": 256, "height_max": 2048, "steps_min": 1, "steps_max": 10, "cfg_min": 0.5, "cfg_max": 10.0, "batch_max": 4, "denoise_min": 0.05, "denoise_max": 1.0},
        "options": {"cfg_visible": True, "samplers": ["euler", "heun", "dpmpp_2m"], "schedulers": ["simple"], "scheduler_fixed": True, "presets": None},
        "notes": [
            "Distilled model — 4 steps is the sweet spot; more steps overcook.",
            "Text-to-image uses the official Flux2Scheduler + CFGGuider chain.",
            "Image-to-image uses standard denoise sampling; full editing lives in the main ComfyUI editor.",
        ],
        "tip": "Sweet spot: 4 steps, CFG 1.0, 1024×1024.",
    },
    {
        "id": "ideogram_4",
        "name": "Ideogram 4",
        "family": "Ideogram 4.0 · 9.3B · asymmetric CFG (dual model)",
        "tagline": "Photoreal results and accurate in-image text.",
        "modes": ["t2i", "i2i"],
        "supports_negative": False,
        "negative_note": "This model has no negative prompt — guidance comes from its second 'unconditional' model.",
        "files": [
            {"kind": "unet", "label": "Diffusion model", "dir": "diffusion_models", "name": "ideogram4_fp8_scaled.safetensors"},
            {"kind": "uncond", "label": "Unconditional model", "dir": "diffusion_models", "name": "ideogram4_unconditional_fp8_scaled.safetensors"},
            {"kind": "clip", "label": "Text encoder", "dir": "text_encoders", "name": "qwen3vl_8b_fp8_scaled.safetensors"},
            {"kind": "vae", "label": "VAE", "dir": "vae", "name": "flux2-vae.safetensors"},
        ],
        "defaults": {"width": 1024, "height": 1024, "steps": 20, "cfg": 7.0, "sampler": "euler", "scheduler": "simple", "batch": 1, "denoise": 0.5},
        "limits": {"width_min": 256, "width_max": 2048, "height_min": 256, "height_max": 2048, "steps_min": 4, "steps_max": 64, "cfg_min": 1.0, "cfg_max": 15.0, "batch_max": 4, "denoise_min": 0.05, "denoise_max": 1.0},
        "options": {"cfg_visible": True, "samplers": ["euler", "heun", "dpmpp_2m"], "schedulers": ["simple"], "scheduler_fixed": True, "presets": {"id": "ideogram_mode", "label": "Mode", "options": [{"id": "default", "label": "Default · 20 steps", "steps": 20, "mu": 0.0, "std": 1.75}, {"id": "turbo", "label": "Turbo · 12 steps", "steps": 12, "mu": 0.5, "std": 1.75}, {"id": "quality", "label": "Quality · 48 steps", "steps": 48, "mu": 0.0, "std": 1.5}]}},
        "notes": [
            "Requires BOTH diffusion models (main + unconditional, ~18.6 GB fp8).",
            "Image-to-image is experimental: standard CFG sampling, asymmetric guidance is not applied.",
            "Structured JSON captions enable layout control — see docs/model-notes.md.",
            "Width/height must be multiples of 16, minimum 256.",
        ],
        "tip": "Default: 20 steps, guidance 7, euler.",
    },
]

ASPECTS = [
    {"label": "Square 1:1", "width": 1024, "height": 1024},
    {"label": "4:3 Landscape", "width": 1152, "height": 864},
    {"label": "3:4 Portrait", "width": 864, "height": 1152},
    {"label": "3:2 Landscape", "width": 1216, "height": 832},
    {"label": "2:3 Portrait", "width": 832, "height": 1216},
    {"label": "16:9 Wide", "width": 1344, "height": 768},
    {"label": "9:16 Tall", "width": 768, "height": 1344},
]


def get_model(model_id):
    for model in MODELS:
        if model["id"] == model_id:
            return model
    return None


def model_file_requirements(model_id):
    model = get_model(model_id)
    return list(model["files"]) if model else []


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


def _available_names():
    available = {}
    for model in MODELS:
        for f in model["files"]:
            if f["dir"] not in available:
                available[f["dir"]] = set(_file_list(f["dir"]))
    return available


def list_models_with_files():
    available = _available_names()
    out = copy.deepcopy(MODELS)
    for model in out:
        for f in model["files"]:
            f["present"] = f["name"] in available.get(f["dir"], set())
        model["options"]["aspects"] = ASPECTS
    return out


def missing_files(model_id, overrides=None):
    model = get_model(model_id)
    if not model:
        return []
    available = {}
    for folder in {f["dir"] for f in model["files"]}:
        available[folder] = set(_file_list(folder))
    overrides = overrides or {}
    missing = []
    for f in model["files"]:
        name = overrides.get(f["kind"], f["name"])
        if name not in available.get(f["dir"], set()):
            missing.append({"kind": f["kind"], "label": f["label"], "dir": f["dir"], "name": name})
    return missing
