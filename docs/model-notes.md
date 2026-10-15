# Model notes

Verified profiles for the four supported model families. LazyComfy ships one workflow template per model per mode (see `workflow-notes.md`); the parameter defaults below are what those templates use.

Quick reference:

| Model | CLIPLoader type | Steps | CFG | Sampler/Scheduler | Negative | Extra files |
| --- | --- | --- | --- | --- | --- | --- |
| Z Image Turbo | `lumina2` | 8 | 1.0 | res_multistep / simple | ignored (ConditioningZeroOut) | ModelSamplingAuraFlow shift 3; Z-Image-specific LoRAs |
| Krea 2 Turbo | `krea2` | 8 | 1.0 | euler / simple | ignored (ConditioningZeroOut) | Krea LoRAs (`krea2_*`), ComfyUI >= 0.26.0 |
| Flux 3 Klein | `flux3` (NOT `flux2`, NOT DualCLIPLoader) | 16 | 1.0 | euler / simple (official T2I: 15 steps er_sde) | ignored (empty encode / ConditioningZeroOut) | Up to 10 reference images; prompt upsampler file for Enhance |
| Ideogram 4 | `ideogram4` | 12–48 (presets) | 7 (DualModelGuider) | euler (custom chain: Ideogram4Scheduler + DualModelGuider) | none anywhere (second "unconditional" model) | Second diffusion model `ideogram4_unconditional_*` (both required) |
| Qwen Image 2.1 | `qwen_image` (TextEncodeQwenImage21) | 25 | 1.0 | euler / simple | supported | Up to 10 reference images, RGBA VAE |
| Qwen Image 2.1 Turbo | `qwen_image` (TextEncodeQwenImage21) | 8 | 1.0 | euler / simple | supported | Official 8-step distilled checkpoint (2026-10-09); same encoder/VAE as 2.1 |

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
| img2img support | not supported — text-to-image only |
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

## 3. Flux 3 Klein

### Profile at a glance

| Field | Value |
| --- | --- |
| Official name | BFL FLUX.3 Image Klein (distilled) |
| Developer | Black Forest Labs (BFL) |
| Architecture | 5.6B flow-matching DiT, distilled (16-step, no guidance) |
| ComfyUI loader nodes | UNETLoader + CLIPLoader (type `flux3`) + VAELoader |
| CLIP type | `flux3` (NOT `flux2`, NOT DualCLIPLoader) |
| Steps | 16 (distilled); official T2I template uses 15 steps er_sde, edit uses 16 steps euler |
| CFG | 1.0 |
| Sampler/Scheduler | euler / simple (T2I default); er_sde optional |
| Resolution | standard latent sizes via EmptyFlux2LatentImage (same /16 128ch format) |
| Negative prompt | ignored — empty encode (T2I) / zeroed conditioning (edit) |
| img2img support | yes, up to 10 reference images via ReferenceMultiLatent (`images.image0`..`image9`, resize ~1 MP); name them image 1 … image 10 in the prompt |
| Prompt upsampler | `qwen3.5_9b_flux3_prompt_upsampler_int8_convrot.safetensors` via TextGenerate (max 3584), same file for T2I and edit |
| Special constraints | Qwen3-VL-4B-Instruct text encoder, Flux2 VAE; repo is gated (FLUX Kommunity license) |

### Required files

| ComfyUI dir | File | Size | Source |
| --- | --- | --- | --- |
| `models/diffusion_models/` | `flux3_image_klein_sd_int8_convrot.safetensors` | 5.8 GB | gated `black-forest-labs/flux-3-image-klein-comfy/diffusion_models/` (alt: `_sd_bf16` 11.1 GB, `_sd_nvfp4` 5.3 GB Blackwell-only) |
| `models/text_encoders/` | `qwen3vl_4b_int8_convrot.safetensors` | 4.9 GB | same repo `text_encoders/` (alt: `_bf16` 8.9 GB) |
| `models/text_encoders/` | `qwen3.5_9b_flux3_prompt_upsampler_int8_convrot.safetensors` | 9.8 GB | same repo `text_encoders/` — Enhance toggle only |
| `models/vae/` | `flux2-vae.safetensors` | 336 MB | same repo `vae/` (same file as Ideogram 4) |

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
| img2img support | not supported — text-to-image only |
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

### ComfyUI notes

- Built-in safety filter: outputs can fail with "Image blocked by safety filter". Rephrase the prompt; structured JSON captions trigger the filter less often.
- Open-weight release with usage restrictions — check the license before commercial use.

## 5. Qwen Image 2.1 Turbo

### Profile at a glance

| Field | Value |
| --- | --- |
| Official name | Qwen-Image-2.1-Turbo |
| Developer | Alibaba Qwen |
| Architecture | 7B DiT turbo-distilled, 8-step |
| ComfyUI loader nodes | UNETLoader + CLIPLoader (type `qwen_image`) + VAELoader |
| CLIP type | `qwen_image` |
| Steps | 8 |
| CFG | 1.0 |
| Sampler/Scheduler | euler / simple |
| Resolution | native 2K presets, same as base 2.1 |
| Negative prompt | supported (TextEncodeQwenImage21 `negative_prompt`) |
| img2img support | yes, up to 10 reference images via TextEncodeQwenImage21 + QwenImage21Cache |
| Special constraints | same text encoder and VAE as Qwen Image 2.1 — only the transformer is new |

### Required files

| ComfyUI dir | File | Size | Source |
| --- | --- | --- | --- |
| `models/diffusion_models/` | `qwen_image_2.1_turbo_int8_convrot.safetensors` | 7.26 GB | `Comfy-Org/Qwen-Image-2.1/diffusion_models/` |
| `models/text_encoders/` | `qwen3vl_8b_int8_convrot.safetensors` | ~9.35 GB | `Comfy-Org/Qwen-Image-2.1/text_encoders/` (shared with base 2.1) |
| `models/vae/` | `qwen_image_2.1_vae_bf16.safetensors` | 676 MB | `Comfy-Org/Qwen-Image-2.1/vae/` (shared with base 2.1) |

Alternates in the same repo: `qwen_image_2.1_turbo_bf16.safetensors` (14.23 GB full precision) and the `qwen_image_2.1_turbo_lora_avg_rank_178_bf16.safetensors` LoRA (913 MB) — load the LoRA on top of the base transformer instead of swapping checkpoints.

### Sampling guidance

- 8 steps, cfg 1.0, euler / simple. The distillation schedule is baked into the checkpoint; other step counts are unevaluated.
- Same resolution presets as the base model (up to 2048x2048, 2752x1536 16:9 and portrait ratios).
- Transparency survives the acceleration — RGBA output works as on the base model.

### img2img notes

Same pipeline as Qwen Image 2.1: `image_1` sets the output canvas, `resolution` 0 keeps native sizes, `<image1> … <image10>` addressing in the prompt.

## 6. Model downloader

The download button in the top bar opens a catalog of Hugging Face mirrors maintained by Comfy-Org. Each family lists its diffusion-model precision variants, text encoders, VAEs (and the published LoRAs — wiring them into the UI is future work). Downloads stream to `<file>.part` in the standard ComfyUI models folder and are renamed atomically when complete; the file list under each model card refreshes automatically.

| Family | Repo(s) | Variants |
| --- | --- | --- |
| Z Image Turbo | `Comfy-Org/z_image_turbo` (all files under `split_files/`) | unet: bf16 12.3 GB / int8+convrot 6.2 GB / nvfp4 4.5 GB; TE: bf16 8.0 GB / fp8 5.6 GB / fp4 3.5 GB; VAE `ae.safetensors`; distill patch LoRA |
| Krea 2 Turbo | `Comfy-Org/Krea-2` (flat) | unet: turbo bf16 26.3 GB / fp8 13.1 GB / int8 13.5 GB / mxfp8 13.5 GB / nvfp4 7.7 GB, plus raw (untrained-base) bf16/fp8/int8 for LoRA training; TE: bf16 8.9 GB / fp8 5.2 GB; VAE `qwen_image_vae.safetensors` (the only VAE published for Krea); 11 LoRAs (9 style + turbo + style-reference) |
| Flux 3 Klein | `black-forest-labs/flux-3-image-klein-comfy` (GATED, FLUX Kommunity license) | unet: distilled sd int8 5.8 GB / bf16 11.1 GB / nvfp4 5.3 GB; TE Qwen3-VL-4B: int8 4.9 GB / bf16 8.9 GB; prompt upsampler int8 9.8 GB; VAE `flux2-vae.safetensors` |
| Ideogram 4 | `Comfy-Org/Ideogram-4` (flat) | unet: fp8 9.3 GB / int8 9.6 GB / nvfp4 5.5 GB + matching unconditional twin (required together); TE: `qwen3vl_8b_fp8_scaled.safetensors` 10.6 GB; VAE `flux2-vae.safetensors` |
| Qwen Image 2.1 Turbo | `Comfy-Org/Qwen-Image-2.1` (flat) | unet: turbo bf16 14.23 GB / turbo int8+convrot 7.26 GB; LoRA `qwen_image_2.1_turbo_lora_avg_rank_178_bf16.safetensors` 913 MB; TE + VAE shared with base 2.1 |
| Qwen 2.1 prompt enhancer | `Comfy-Org/Qwen-Image-2.1` `text_encoders/` | `qwen3.5_9b_qwen_image_2.1_pe_i2i.int8_convrot.safetensors` 9.47 GB (edit) + `qwen3.5_9b_qwen_image_2.1_pe_t2i.int8_convrot.safetensors` 9.47 GB (T2I); shared by base 2.1 and Turbo; opt-in via the Enhance toggle |

Notes:

- Sizes are exact bytes from the Hugging Face tree API (verified 2026-08-02) except Flux 3 Klein (rounded GB from the repo card, 2026-10-15). All repos are ungated except Flux 3 Klein (gated — needs license acceptance + token).
- "nvfp4" variants require NVIDIA RTX 40-series or newer (hardware fp4). "convrot" is a conv-rotation quantization of the linear layers.
- Krea "raw" checkpoints are the base (non-distilled) weights — 52 steps, not 8 — useful for training LoRAs, not for the default workflow.
- Ideogram 4 needs **both** the main and the unconditional model at the same precision — mixing fp8 main with nvfp4 unconditional is supported (they are separate loader nodes) but usually undesirable.
- Flux2 VAE (`flux2-vae.safetensors`) is shared between Flux 3 Klein and Ideogram 4 — downloading it once marks both families complete.
- The Enhance toggle (Qwen 2.1 / Turbo / Flux 3 Klein) rewrites the prompt first, mirroring the official templates (TextGenerate + BatchImages over the same references for edits). Needs the matching PE file above; without it, generation refuses with a missing-file error naming it. Terse instructions ("uncrop", "make it red") measurably need it; explicit descriptions work without it.
- The `Files` menu under each model card lets you pin a specific installed variant (e.g. a smaller int8 unet) — the choice is sent as `files` in generate and overrides the template default for that kind only.
- `LAZYCOMFY_HUB_BASE` overrides the mirror base URL; `LAZYCOMFY_MODELS_DIR` points downloads at a custom models root when running outside ComfyUI.
