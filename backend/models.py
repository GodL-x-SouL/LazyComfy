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
        "modes": ["t2i"],
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
        "id": "flux_3_klein",
        "name": "Flux 3 Klein",
        "family": "Black Forest Labs · FLUX.3 Image Klein · 5.6B distilled",
        "tagline": "Text-to-image + up to 10-image editing in one model.",
        "modes": ["t2i", "i2i"],
        "supports_negative": False,
        "negative_note": "Ignored by this model — only the positive prompt is used.",
        "max_images": 10,
        "files": [
            {"kind": "unet", "label": "Diffusion model", "dir": "diffusion_models", "name": "flux3_image_klein_sd_int8_convrot.safetensors"},
            {"kind": "clip", "label": "Text encoder (Qwen3-VL 4B)", "dir": "text_encoders", "name": "qwen3vl_4b_int8_convrot.safetensors"},
            {"kind": "vae", "label": "VAE", "dir": "vae", "name": "flux2-vae.safetensors"},
        ],
        "pe": {"t2i": "qwen3.5_9b_flux3_prompt_upsampler_int8_convrot.safetensors", "i2i": "qwen3.5_9b_flux3_prompt_upsampler_int8_convrot.safetensors"},
        "defaults": {"width": 1024, "height": 1024, "steps": 16, "cfg": 1.0, "sampler": "euler", "scheduler": "simple", "batch": 1, "denoise": 1.0},
        "limits": {"width_min": 256, "width_max": 2048, "height_min": 256, "height_max": 2048, "steps_min": 1, "steps_max": 32, "cfg_min": 0.5, "cfg_max": 10.0, "batch_max": 4, "denoise_min": 0.05, "denoise_max": 1.0},
        "options": {"cfg_visible": True, "samplers": ["euler", "er_sde", "heun", "dpmpp_2m"], "schedulers": ["simple"], "scheduler_fixed": True, "presets": None},
        "notes": [
            "Distilled model — 16 steps at CFG 1.0, no guidance (official T2I template uses 15 steps er_sde).",
            "Edit takes up to 10 reference images — name them image 1 … image 10 in the prompt.",
            "The first reference image sets the output canvas size (resized to ~1 MP).",
            "Optional prompt upsampler (Qwen 3.5 9B, ~10 GB): rewrites short requests before generation.",
            "All files are gated — accept the FLUX Kommunity license terms on Hugging Face first.",
        ],
        "tip": "Sweet spot: 16 steps, CFG 1.0, euler/simple, 1024×1024.",
    },
    {
        "id": "ideogram_4",
        "name": "Ideogram 4",
        "family": "Ideogram 4.0 · 9.3B · asymmetric CFG (dual model)",
        "tagline": "Photoreal results and accurate in-image text.",
        "modes": ["t2i"],
        "supports_negative": False,
        "negative_note": "This model has no negative prompt — guidance comes from its second 'unconditional' model.",
        "files": [
            {"kind": "unet", "label": "Diffusion model", "dir": "diffusion_models", "name": "ideogram4_fp8_scaled.safetensors"},
            {"kind": "uncond", "label": "Unconditional model", "dir": "diffusion_models", "name": "ideogram4_unconditional_fp8_scaled.safetensors"},
            {"kind": "clip", "label": "Text encoder", "dir": "text_encoders", "name": "qwen3vl_8b_fp8_scaled.safetensors"},
            {"kind": "vae", "label": "VAE", "dir": "vae", "name": "flux2-vae.safetensors"},
        ],
        "defaults": {"width": 1024, "height": 1024, "steps": 20, "cfg": 7.0, "sampler": "euler", "scheduler": "simple", "batch": 1, "denoise": 0.5},
        "limits": {"width_min": 256, "width_max": 2048, "height_min": 256, "height_max": 2048, "steps_min": 2, "steps_max": 64, "cfg_min": 1.0, "cfg_max": 15.0, "batch_max": 4, "denoise_min": 0.05, "denoise_max": 1.0},
        "options": {"cfg_visible": True, "samplers": ["euler", "heun", "dpmpp_2m"], "schedulers": ["simple"], "scheduler_fixed": True, "presets": {"id": "ideogram_mode", "label": "Mode", "options": [{"id": "custom", "label": "Custom · manual steps", "steps": None, "mu": 0.0, "std": 1.75}, {"id": "default", "label": "Default · 20 steps", "steps": 20, "mu": 0.0, "std": 1.75}, {"id": "turbo", "label": "Turbo · 12 steps", "steps": 12, "mu": 0.5, "std": 1.75}, {"id": "quality", "label": "Quality · 48 steps", "steps": 48, "mu": 0.0, "std": 1.5}]}},
        "notes": [
            "Requires BOTH diffusion models (main + unconditional, ~18.6 GB fp8).",
            "Structured JSON captions enable layout control — see docs/model-notes.md.",
            "Width/height must be multiples of 16, minimum 256.",
        ],
        "tip": "Default: 20 steps, guidance 7, euler.",
    },
    {
        "id": "qwen_image_2_1",
        "name": "Qwen Image 2.1",
        "family": "Alibaba Qwen · 7B DiT + Qwen3-VL 8B + 64ch RGBA VAE",
        "tagline": "Native 2K + transparency + up to 10-image editing.",
        "modes": ["t2i", "i2i"],
        "supports_negative": True,
        "max_images": 10,
        "files": [
            {"kind": "unet", "label": "Diffusion model", "dir": "diffusion_models", "name": "qwen_image_2.1_int8_convrot.safetensors"},
            {"kind": "clip", "label": "Text encoder (Qwen3-VL 8B)", "dir": "text_encoders", "name": "qwen3vl_8b_int8_convrot.safetensors"},
            {"kind": "vae", "label": "VAE (RGBA)", "dir": "vae", "name": "qwen_image_2.1_vae_bf16.safetensors"},
        ],
        "pe": {"t2i": "qwen3.5_9b_qwen_image_2.1_pe_t2i.int8_convrot.safetensors", "i2i": "qwen3.5_9b_qwen_image_2.1_pe_i2i.int8_convrot.safetensors"},
        "defaults": {"width": 1024, "height": 1024, "steps": 25, "cfg": 1.0, "sampler": "euler", "scheduler": "simple", "batch": 1, "denoise": 1.0, "resolution": 1024},
        "limits": {"width_min": 256, "width_max": 2048, "height_min": 256, "height_max": 2048, "steps_min": 1, "steps_max": 60, "cfg_min": 1.0, "cfg_max": 10.0, "batch_max": 4, "denoise_min": 0.05, "denoise_max": 1.0, "resolution_min": 0, "resolution_max": 4096},
        "options": {"cfg_visible": True, "samplers": ["euler", "heun", "dpmpp_2m", "res_multistep"], "schedulers": ["simple", "normal", "karras"], "scheduler_fixed": False, "presets": None},
        "notes": [
            "Official nodes: Text Encode Qwen Image 2.1 + Qwen Image 2.1 Cache (edit).",
            "Edit uses up to 10 reference images — address them as <image1> … <image10> in the prompt.",
            "image_1 sets the output canvas size; resolution 0 keeps native sizes.",
            "Keep CFG at 1.0 unless using a negative prompt; 25 steps euler/simple is the official default.",
            "Optional prompt enhancer (Qwen 3.5, ~9 GB): rewrites terse instructions before the edit model sees them.",
            "License: qwen-research (research / non-commercial only).",
        ],
        "tip": "T2I: 25 steps CFG 1.0. Edit: <image1> is the target, <image2>+ are references.",
    },
    {
        "id": "qwen_image_2_1_turbo",
        "name": "Qwen Image 2.1 Turbo",
        "family": "Alibaba Qwen · 7B DiT turbo-distilled · 8-step",
        "tagline": "Official 8-step Turbo — same pipeline, 3x faster.",
        "modes": ["t2i", "i2i"],
        "supports_negative": True,
        "max_images": 10,
        "files": [
            {"kind": "unet", "label": "Diffusion model", "dir": "diffusion_models", "name": "qwen_image_2.1_turbo_int8_convrot.safetensors"},
            {"kind": "clip", "label": "Text encoder (Qwen3-VL 8B)", "dir": "text_encoders", "name": "qwen3vl_8b_int8_convrot.safetensors"},
            {"kind": "vae", "label": "VAE (RGBA)", "dir": "vae", "name": "qwen_image_2.1_vae_bf16.safetensors"},
        ],
        "pe": {"t2i": "qwen3.5_9b_qwen_image_2.1_pe_t2i.int8_convrot.safetensors", "i2i": "qwen3.5_9b_qwen_image_2.1_pe_i2i.int8_convrot.safetensors"},
        "defaults": {"width": 1024, "height": 1024, "steps": 8, "cfg": 1.0, "sampler": "euler", "scheduler": "simple", "batch": 1, "denoise": 1.0, "resolution": 1024},
        "limits": {"width_min": 256, "width_max": 2048, "height_min": 256, "height_max": 2048, "steps_min": 1, "steps_max": 16, "cfg_min": 1.0, "cfg_max": 10.0, "batch_max": 4, "denoise_min": 0.05, "denoise_max": 1.0, "resolution_min": 0, "resolution_max": 4096},
        "options": {"cfg_visible": True, "samplers": ["euler", "heun", "dpmpp_2m", "res_multistep"], "schedulers": ["simple", "normal", "karras"], "scheduler_fixed": False, "presets": None},
        "notes": [
            "Official Alibaba turbo checkpoint (2026-10-09): 8 steps at CFG 1.0, down from ~40.",
            "Same text encoder and VAE as Qwen Image 2.1 — only the transformer is new.",
            "Alternative: base model + qwen_image_2.1_turbo_lora_avg_rank_178_bf16.safetensors LoRA instead of swapping checkpoints.",
            "Edit uses up to 10 reference images — address them as <image1> … <image10> in the prompt.",
            "License: qwen-research (research / non-commercial only).",
        ],
        "tip": "T2I: 8 steps CFG 1.0 euler/simple. Edit: <image1> is the target, <image2>+ are references.",
    },
    {
        "id": "moss_image",
        "name": "MOSS Image",
        "family": "OpenMOSS · MOSS-Image SFT · 5B DiT + Qwen 3.5 9B",
        "tagline": "Faithful text rendering and layout; add the edit LoRA for image edits.",
        "modes": ["t2i", "i2i"],
        "supports_negative": True,
        "negative_note": "T2I: empty by default. Edit: the recommended negative line; CFG 4 makes it matter.",
        "max_images": 4,
        "files": [
            {"kind": "unet", "label": "Diffusion model (SFT)", "dir": "diffusion_models", "name": "moss_image_sft_int8_convrot.safetensors"},
            {"kind": "clip", "label": "Text encoder (Qwen 3.5 9B W4A8)", "dir": "text_encoders", "name": "qwen3.5_9b_w4a8_gptq.safetensors"},
            {"kind": "vae", "label": "VAE (small)", "dir": "vae", "name": "flux2-vae_small.safetensors"},
        ],
        "required_files": {
            "i2i": [
                {"kind": "lora", "label": "Edit LoRA", "dir": "loras", "name": "moss_image_edit_lora_rank_64_bf16.safetensors"},
            ],
        },
        "defaults": {"width": 1024, "height": 1024, "steps": 25, "cfg": 2.5, "sampler": "er_sde", "scheduler": "simple", "batch": 1, "denoise": 1.0},
        "mode_defaults": {
            "t2i": {"negative_prompt": ""},
            "i2i": {"steps": 30, "cfg": 4.0, "sampler": "euler", "scheduler": "normal", "denoise": 1.0, "negative_prompt": "nsfw, worst quality, bad anatomy, watermark, jpeg artifact"},
        },
        "limits": {"width_min": 256, "width_max": 2048, "height_min": 256, "height_max": 2048, "steps_min": 1, "steps_max": 60, "cfg_min": 0.5, "cfg_max": 10.0, "batch_max": 4, "denoise_min": 0.05, "denoise_max": 1.0},
        "options": {"cfg_visible": True, "samplers": ["er_sde", "euler", "heun", "dpmpp_2m", "dpmpp_2m_sde_heun"], "schedulers": ["simple", "normal", "karras"], "scheduler_fixed": False, "denoise_fixed": True, "presets": None},
        "notes": [
            "Official SFT template: `moss_image_sft_int8_convrot.safetensors` + `qwen3.5_9b_w4a8_gptq.safetensors` + `flux2-vae_small.safetensors`.",
            "T2I: 25 steps, CFG 2.5, er_sde/simple, empty negative, 1024x1024 (multiples of 16).",
            "Edit: requires `moss_image_edit_lora_rank_64_bf16.safetensors` and runs at 30 steps, CFG 4.0, euler/normal, 1 MP reference.",
            "The W4A8 file is the text encoder for the model, not a prompt enhancer; this model has no prompt enhancer.",
            "Base checkpoints are pickable in the Files menu; SFT is the official default.",
            "License: Apache-2.0.",
        ],
        "tip": "T2I: 25 steps CFG 2.5 er_sde/simple. Edit: add an image, keep 30 steps CFG 4 euler/normal. Quote text you want rendered exactly.",
    },
    {
        "id": "fibo2",
        "name": "FIBO Image 2.0",
        "family": "BRIA · FIBO 2.0 Dev · 8B flow matching + Qwen3-VL 4B",
        "tagline": "Structured-caption generation and reference editing from one model.",
        "modes": ["t2i", "i2i"],
        "supports_negative": True,
        "negative_note": "Dev edit keeps Bria's structured VGL negative unless you type your own.",
        "max_images": 10,
        "files": [
            {"kind": "unet", "label": "Diffusion model (Dev)", "dir": "diffusion_models", "name": "fibo2_dev_int8_convrot.safetensors"},
            {"kind": "clip", "label": "Text encoder (Qwen3-VL 4B)", "dir": "text_encoders", "name": "qwen3vl_4b_int8_convrot.safetensors"},
            {"kind": "vae", "label": "VAE", "dir": "vae", "name": "flux2-vae.safetensors"},
        ],
        "defaults": {"width": 1024, "height": 1024, "steps": 30, "cfg": 5.0, "sampler": "euler", "scheduler": "simple", "batch": 1, "denoise": 1.0},
        "mode_defaults": {
            "t2i": {"negative_prompt": ""},
            "i2i": {"steps": 50, "cfg": 5.0, "sampler": "euler", "scheduler": "simple", "denoise": 1.0, "negative_prompt": ""},
        },
        "limits": {"width_min": 256, "width_max": 2048, "height_min": 256, "height_max": 2048, "steps_min": 1, "steps_max": 60, "cfg_min": 0.5, "cfg_max": 10.0, "batch_max": 4, "denoise_min": 0.05, "denoise_max": 1.0},
        "options": {"cfg_visible": True, "samplers": ["euler", "heun", "dpmpp_2m"], "schedulers": ["simple", "normal", "karras"], "scheduler_fixed": False, "denoise_fixed": True, "presets": None},
        "notes": [
            "Dev T2I: 30 steps, CFG 5.0, euler/simple; Bria's full-quality edit recipe is 50 steps at CFG 5.0.",
            "Prompt can be plain text or a structured VGL JSON caption. Long, specific captions work best.",
            "Edit: describe the final state of the changed region; avoid 'keep unchanged' phrasing. Output follows the first image's aspect ratio at about 1 MP.",
            "Trained at ~1 MP; larger sizes lose prompt and layout adherence.",
            "Use FIBO Image 2.0 Edit Turbo for 4-step edits.",
            "License: CC BY-NC 4.0 (non-commercial).",
        ],
        "tip": "Dev: 30 steps CFG 5 euler/simple for generation, 50 steps for edits. VGL captions give the most control.",
    },
    {
        "id": "fibo2_edit_turbo",
        "name": "FIBO Image 2.0 Edit Turbo",
        "family": "BRIA · FIBO 2.0 Edit Turbo · 8B flow matching + Qwen3-VL 4B",
        "tagline": "Four-step precision edits from a reference image.",
        "modes": ["i2i"],
        "supports_negative": True,
        "negative_note": "CFG is 1.0, so the negative branch is unused. Leave it empty.",
        "max_images": 10,
        "files": [
            {"kind": "unet", "label": "Diffusion model (Edit Turbo)", "dir": "diffusion_models", "name": "fibo2_edit_turbo_int8_convrot.safetensors"},
            {"kind": "clip", "label": "Text encoder (Qwen3-VL 4B)", "dir": "text_encoders", "name": "qwen3vl_4b_int8_convrot.safetensors"},
            {"kind": "vae", "label": "VAE", "dir": "vae", "name": "flux2-vae.safetensors"},
        ],
        "defaults": {"width": 1024, "height": 1024, "steps": 4, "cfg": 1.0, "sampler": "euler", "scheduler": "simple", "batch": 1, "denoise": 1.0},
        "mode_defaults": {"i2i": {"negative_prompt": ""}},
        "limits": {"width_min": 256, "width_max": 2048, "height_min": 256, "height_max": 2048, "steps_min": 1, "steps_max": 20, "cfg_min": 0.5, "cfg_max": 3.0, "batch_max": 4, "denoise_min": 0.05, "denoise_max": 1.0},
        "options": {"cfg_visible": True, "samplers": ["euler", "heun", "dpmpp_2m"], "schedulers": ["simple", "normal", "karras"], "scheduler_fixed": False, "denoise_fixed": True, "presets": None},
        "notes": [
            "Official Edit Turbo recipe: 4 steps, CFG 1.0, euler/simple, empty negative.",
            "Editing starts from noise with the reference image attached as a latent; the strength slider does not apply.",
            "The result follows the first image's aspect ratio at about 1 MP. Connect more references with <image_1>, <image_2>, ... in the prompt.",
            "For maximum quality, use FIBO Image 2.0 Dev at 50 steps / CFG 5.",
            "License: CC BY-NC 4.0 (non-commercial).",
        ],
        "tip": "4 steps CFG 1 euler/simple. Describe only the change; add more references as <image_2>, <image_3>, ...",
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
    {"label": "21:9 Ultrawide", "width": 1344, "height": 576},
    {"label": "9:21 Tall", "width": 576, "height": 1344},
]


def get_model(model_id):
    for model in MODELS:
        if model["id"] == model_id:
            return model
    return None


def model_defaults(model, mode):
    defaults = dict(model["defaults"])
    defaults.update((model.get("mode_defaults") or {}).get(mode) or {})
    return defaults


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


def missing_files(model_id, overrides=None, mode=None):
    model = get_model(model_id)
    if not model:
        return []
    files = list(model["files"])
    files.extend((model.get("required_files") or {}).get(mode) or [])
    available = {}
    for folder in {f["dir"] for f in files}:
        available[folder] = set(_file_list(folder))
    overrides = overrides or {}
    missing = []
    for f in files:
        name = overrides.get(f["kind"], f["name"])
        if name not in available.get(f["dir"], set()):
            missing.append({"kind": f["kind"], "label": f["label"], "dir": f["dir"], "name": name})
    return missing
