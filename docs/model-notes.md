# Model notes

Verified profiles for the four supported model families. LazyComfy ships one workflow template per model per mode (see `workflow-notes.md`); the parameter defaults below are what those templates use.

Quick reference:

| Model | CLIPLoader type | Steps | CFG | Sampler/Scheduler | Negative | Extra files |
| --- | --- | --- | --- | --- | --- | --- |
| Z Image Turbo | `lumina2` | 8 | 1.0 | res_multistep / simple | ignored (ConditioningZeroOut) | ModelSamplingAuraFlow shift 3; Z-Image-specific LoRAs |
| Krea 2 Turbo | `krea2` | 8 | 1.0 | euler / simple | ignored (ConditioningZeroOut) | Krea LoRAs (`krea2_*`), ComfyUI >= 0.26.0 |
| Flux 2 Klein 9B | `flux2` (NOT `flux`, NOT DualCLIPLoader) | 4 | 1.0 | euler (custom chain: Flux2Scheduler + CFGGuider) | ignored (ConditioningZeroOut) | Full edit workflows belong in the main editor |
| Ideogram 4 | `ideogram4` | 12–48 (presets) | 7 (DualModelGuider) | euler (custom chain: Ideogram4Scheduler + DualModelGuider) | none anywhere (second "unconditional" model) | Second diffusion model `ideogram4_unconditional_*` (both required) |

---

## 1. Z Image Turbo

### Profile at a glance

| Field | Value |
| --- | --- |
| Official name | Tongyi-MAI Z-Image-Turbo |
| Developer | Tongyi-MAI |
| Architecture | 6B S3-DiT, 8-step distilled |
| ComfyUI loader nodes | UNETLoader + CLIPLoader (type `lumina2`) + VAELoader |
| CLIP type | `lumina2` |
| Steps | 8 |
| CFG | 1.0 |
| Sampler/Scheduler | res_multistep / simple |
| Resolution | native 1024x1024 (1216x832 on low-VRAM) |
| Negative prompt | ignored — conditioning is zeroed out |
| img2img support | yes, via VAEEncode + denoise 0.3–0.7 |
| Special constraints | bilingual (EN/CN); BF16 needs >= 16 GB VRAM; wrong CLIP type breaks encoding |

### Required files

| ComfyUI dir | File | Size | Source |
| --- | --- | --- | --- |
| `models/diffusion_models/` | `z_image_turbo_bf16.safetensors` | 12.3 GB | `Comfy-Org/z_image_turbo/split_files/diffusion_models/` (fp8/int8 alternates available) |
| `models/text_encoders/` | `qwen_3_4b.safetensors` | 8.04 GB | `Comfy-Org/z_image_turbo/split_files/text_encoders/` |
| `models/vae/` | `ae.safetensors` | 335 MB | `Comfy-Org/z_image_turbo/split_files/vae/` |

### Prompt format

Natural-language prompts; works in English and Chinese (bilingual).

### Negative prompt handling

Ignored. The template zeroes the conditioning with `ConditioningZeroOut`, so the negative field is hidden in the UI for this model.

### Sampling guidance

- 8 steps, cfg 1.0, res_multistep / simple, with `ModelSamplingAuraFlow` shift = 3 chained to the model.
- Native resolution 1024x1024; use 1216x832 to save VRAM.
- BF16 weights need >= 16 GB VRAM — use the fp8/int8 files if you have less.

### img2img notes

VAEEncode the input image and lower denoise to 0.3–0.7. Low denoise keeps the source structure; high denoise moves toward the prompt.

### ComfyUI notes

- CLIPLoader type must be `lumina2` — anything else produces broken conditioning.
- LoRAs for this model are Z-Image-specific; Flux/SDXL LoRAs do not apply.

---

## 2. Krea 2 Turbo

### Profile at a glance

| Field | Value |
| --- | --- |
| Official name | Krea 2 Turbo v1.0 |
| Developer | Krea AI |
| Architecture | 12B dense DiT, flow matching, 8-step distilled |
| ComfyUI loader nodes | UNETLoader + CLIPLoader (type `krea2`) + VAELoader |
| CLIP type | `krea2` |
| Steps | 8 |
| CFG | 1.0 (disabled) |
| Sampler/Scheduler | euler / simple |
| Resolution | 1K–2K supported |
| Negative prompt | ignored — conditioning is zeroed out |
| img2img support | yes, via VAEEncode + denoise (classic denoise sampling) |
| Special constraints | Qwen3-VL-4B text encoder, Qwen Image VAE; CFG disabled by design; needs ComfyUI >= 0.26.0 |

### Required files

| ComfyUI dir | File | Size | Source |
| --- | --- | --- | --- |
| `models/diffusion_models/` | `krea2_turbo_fp8_scaled.safetensors` | ~13 GB (recommended) | `Comfy-Org/Krea-2/diffusion_models/` (bf16 26.3 GB / int8 alternates) |
| `models/text_encoders/` | `qwen3vl_4b_fp8_scaled.safetensors` | ~4 GB | `Comfy-Org/Krea-2/text_encoders/` |
| `models/vae/` | `qwen_image_vae.safetensors` | ~1 GB | `Comfy-Org/Krea-2/vae/` |

### Prompt format

Natural-language prompts.

### Negative prompt handling

Ignored — the template zeroes the conditioning with `ConditioningZeroOut`.

### Sampling guidance

Plain `KSampler` with euler / simple, 8 steps, cfg 1.0. CFG is disabled for this model by design. Resolutions from 1K up to 2K work.

### img2img notes

VAEEncode + denoise in a standard KSampler chain. Denoise control works (lower = closer to source). There is no official Krea i2i template — LazyComfy uses classic denoise sampling, which behaves predictably.

### ComfyUI notes

- Requires ComfyUI >= 0.26.0.
- Krea LoRAs exist (`krea2_*` in `Comfy-Org/Krea-2/loras/`); they are Krea-specific and not compatible with Flux/SDXL.

---

## 3. Flux 2 Klein 9B

### Profile at a glance

| Field | Value |
| --- | --- |
| Official name | BFL FLUX.2 [klein] 9B |
| Developer | Black Forest Labs (BFL) |
| Architecture | compact flow-matching DiT, distilled (4-step) variant |
| ComfyUI loader nodes | UNETLoader + CLIPLoader (type `flux2`) + VAELoader |
| CLIP type | `flux2` (NOT `flux`, NOT DualCLIPLoader) |
| Steps | 4 (distilled); base variant: 20 |
| CFG | 1.0 |
| Sampler/Scheduler | euler via Flux2Scheduler + CFGGuider |
| Resolution | standard latent sizes (Flux2) |
| Negative prompt | ignored — conditioning is zeroed out |
| img2img support | yes, via standard KSampler denoise for strength control |
| Special constraints | Qwen3-8B text encoder, Flux2 VAE (32x compression); overcooks above ~6 steps |

### Required files

| ComfyUI dir | File | Size | Source |
| --- | --- | --- | --- |
| `models/diffusion_models/` | `flux-2-klein-9b-fp8.safetensors` | 9.4 GB | gated `black-forest-labs/FLUX.2-klein-9b-fp8` |
| `models/text_encoders/` | `qwen_3_8b_fp8mixed.safetensors` | ~8.3 GB | `Comfy-Org/flux2-klein-9B/split_files/text_encoders/` |
| `models/vae/` | `full_encoder_small_decoder.safetensors` | ~1 GB | `black-forest-labs/FLUX.2-small-decoder` (alt: `flux2-vae.safetensors` 336 MB from `Comfy-Org/flux2-dev/split_files/vae/`) |

### Prompt format

Natural-language prompts.

### Negative prompt handling

Ignored — zeroed with `ConditioningZeroOut` in the T2I template.

### Sampling guidance

- Text-to-image uses the official chain: `Flux2Scheduler` + `CFGGuider` + `KSamplerSelect` (euler) + `RandomNoise` + `SamplerCustomAdvanced`, 4 steps, cfg 1.0.
- Distilled variant overcooks above ~6 steps — keep 4.
- A base (undistilled) variant exists and uses 20 steps, cfg 5, if you prefer.

### img2img notes

LazyComfy's i2i template uses a standard KSampler with denoise for strength control. Full edit workflows (e.g. reference-image conditioning with `ReferenceLatent`) belong in the main ComfyUI editor, not here.

### ComfyUI notes

- Loader type must be `flux2` on a single CLIPLoader — neither `flux` nor `DualCLIPLoader` is correct.
- Flux2 VAE has 32x compression; don't reuse the FLUX.1 `ae.safetensors`.

---

## 4. Ideogram 4

### Profile at a glance

| Field | Value |
| --- | --- |
| Official name | Ideogram 4.0 (open weights) |
| Developer | Ideogram |
| Architecture | ~9.3B flow-matching DiT with asymmetric classifier-free guidance (second "unconditional" model replaces negative prompts) |
| ComfyUI loader nodes | two UNETLoaders + CLIPLoader (type `ideogram4`) + VAELoader |
| CLIP type | `ideogram4` |
| Steps | 20 (Default), 12 (Turbo), 48 (Quality) |
| CFG | 7 (DualModelGuider) |
| Sampler/Scheduler | euler via Ideogram4Scheduler (mu/std) + DualModelGuider |
| Resolution | multiples of 16, min 256 |
| Negative prompt | none anywhere — asymmetric guidance replaces it |
| img2img support | EXPERIMENTAL in LazyComfy (standard CFG sampling; asymmetric guidance not applied) |
| Special constraints | Qwen3-VL-8B text encoder, Flux2 VAE; built-in safety filter; usage restrictions on license |

### Required files

| ComfyUI dir | File | Size | Source |
| --- | --- | --- | --- |
| `models/diffusion_models/` | `ideogram4_fp8_scaled.safetensors` | 9.28 GB | `Comfy-Org/Ideogram-4/diffusion_models/` |
| `models/diffusion_models/` | `ideogram4_unconditional_fp8_scaled.safetensors` | 9.28 GB | `Comfy-Org/Ideogram-4/diffusion_models/` |
| `models/text_encoders/` | `qwen3vl_8b_fp8_scaled.safetensors` | 10.59 GB | `Comfy-Org/Qwen3-VL/text_encoders/` |
| `models/vae/` | `flux2-vae.safetensors` | 336 MB | `Comfy-Org/flux2-dev/split_files/vae/` |

**Both diffusion models are required for full quality.** Bypassing (unloading) the unconditional model degrades results — the asymmetric guidance has nothing to condition against.

### Prompt format

Structured JSON captions give layout and text control. Key order matters. A caption looks like:

```json
{
  "high_level_description": "a poster for a jazz festival",
  "style_description": {
    "mood": "noir",
    "color_palette": ["#101820", "#E0A458", "#FEE715"]
  },
  "compositional_deconstruction": {
    "primary_subject": {"top_left_x": 0, "top_left_y": 0, "bottom_right_x": 1000, "bottom_right_y": 600},
    "primary_subject_description": "a saxophonist in silhouette"
  },
  "elements": [
    {"type": "text", "text": "JAZZ", "top_left_x": 300, "top_left_y": 700, "bottom_right_x": 700, "bottom_right_y": 800, "style": "bold"}
  ]
}
```

Bounding boxes use a 0–1000 grid. Plain natural-language prompts also work.

### Negative prompt handling

No negative prompt anywhere — the second UNET ("unconditional" model) replaces it, so the negative field is hidden in the UI.

### Sampling guidance

Text-to-image chain: `Ideogram4Scheduler` (takes steps, width, height, mu, std) + `DualModelGuider` (cfg 7) + `KSamplerSelect` (euler) + `RandomNoise` + `SamplerCustomAdvanced`. Presets:

| Preset | Steps | mu | std |
| --- | --- | --- | --- |
| Default | 20 | 0.0 | 1.75 |
| Turbo | 12 | 0.5 | 1.75 |
| Quality | 48 | 0.0 | 1.5 |

Resolutions must be multiples of 16, minimum 256.

### img2img notes

EXPERIMENTAL in LazyComfy: the i2i template uses a single UNET plus a plain KSampler (cfg 7, euler). Asymmetric guidance is **not applied** in this mode, so results differ from T2I quality.

### ComfyUI notes

- Built-in safety filter: outputs can fail with "Image blocked by safety filter". Rephrase the prompt; structured JSON captions trigger the filter less often.
- Open-weight release with usage restrictions — check the license before commercial use.

## 5. Model downloader

The download button in the top bar opens a catalog of Hugging Face mirrors maintained by Comfy-Org. Each family lists its diffusion-model precision variants, text encoders, VAEs (and the published LoRAs — wiring them into the UI is future work). Downloads stream to `<file>.part` in the standard ComfyUI models folder and are renamed atomically when complete; the file list under each model card refreshes automatically.

| Family | Repo(s) | Variants |
| --- | --- | --- |
| Z Image Turbo | `Comfy-Org/z_image_turbo` (all files under `split_files/`) | unet: bf16 12.3 GB / int8+convrot 6.2 GB / nvfp4 4.5 GB; TE: bf16 8.0 GB / fp8 5.6 GB / fp4 3.5 GB; VAE `ae.safetensors`; distill patch LoRA |
| Krea 2 Turbo | `Comfy-Org/Krea-2` (flat) | unet: turbo bf16 26.3 GB / fp8 13.1 GB / int8 13.5 GB / mxfp8 13.5 GB / nvfp4 7.7 GB, plus raw (untrained-base) bf16/fp8/int8 for LoRA training; TE: bf16 8.9 GB / fp8 5.2 GB; VAE `qwen_image_vae.safetensors` (the only VAE published for Krea); 11 LoRAs (9 style + turbo + style-reference) |
| Flux 2 Klein 9B | unet: `titomatus0203/flux-2-klein-9b-fp8` (ungated mirror, byte-identical to BFL); TE: `Comfy-Org/flux2-klein-9B`; VAE: `black-forest-labs/FLUX.2-small-decoder` | unet fp8 9.4 GB; TE: bf16 16.4 GB / fp8-mixed 8.7 GB / fp4-mixed 6.8 GB; VAEs: `full_encoder_small_decoder.safetensors` (default) or `flux2-vae.safetensors` |
| Ideogram 4 | `Comfy-Org/Ideogram-4` (flat) | unet: fp8 9.3 GB / int8 9.6 GB / nvfp4 5.5 GB + matching unconditional twin (required together); TE: `qwen3vl_8b_fp8_scaled.safetensors` 10.6 GB; VAE `flux2-vae.safetensors` |

Notes:

- Sizes are exact bytes from the Hugging Face tree API (verified 2026-08-02). Repos are ungated as of that date.
- "nvfp4" variants require NVIDIA RTX 40-series or newer (hardware fp4). "convrot" is a conv-rotation quantization of the linear layers.
- Krea "raw" checkpoints are the base (non-distilled) weights — 52 steps, not 8 — useful for training LoRAs, not for the default workflow.
- Ideogram 4 needs **both** the main and the unconditional model at the same precision — mixing fp8 main with nvfp4 unconditional is supported (they are separate loader nodes) but usually undesirable.
- Flux 2 VAE files are shared between Flux 2 Klein and Ideogram 4 — downloading it once marks both families complete.
- The `Files` menu under each model card lets you pin a specific installed variant (e.g. a smaller int8 unet) — the choice is sent as `files` in generate and overrides the template default for that kind only.
- `LAZYCOMFY_HUB_BASE` overrides the mirror base URL; `LAZYCOMFY_MODELS_DIR` points downloads at a custom models root when running outside ComfyUI.
