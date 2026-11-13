# Workflow notes

## Template rules

- Templates are pure ComfyUI **API-format** JSON: keys are node ids as strings, each node has `class_type` and `inputs`, and links are `["<node_id>", <output_slot>]`.
- No layout/position data (that belongs to the canvas format only).
- The backend strips nothing — templates are directly POSTable to `/prompt` as-is.
- Node ids are **fixed per template** and mirrored by the fill map in `backend/workflows.py`. Keep the two in sync whenever you edit nodes.
- Every image template ends with a `SaveImage` using `filename_prefix: lazycomfy/<slug>` — outputs land in `output/lazycomfy/<slug>/`. Video templates end with `SaveVideo` in the same folder.

## Template inventory

| Template id | Model | Mode | Key chain |
| --- | --- | --- | --- |
| `z_image_turbo_t2i` | Z Image Turbo | t2i | UNETLoader → ModelSamplingAuraFlow(shift 3) → KSampler; CLIPTextEncode → ConditioningZeroOut; EmptySD3LatentImage; VAEDecode → SaveImage |
| `krea_2_turbo_t2i` | Krea 2 Turbo | t2i | plain KSampler chain, EmptyLatentImage |
| `flux_3_klein_t2i` | Flux 3 Klein | t2i | UNETLoader(sd int8) + CLIPLoader(flux3) + EmptyFlux2LatentImage + KSampler; 16 steps euler cfg 1.0 (official template: 15 steps er_sde) |
| `flux_3_klein_i2i` | Flux 3 Klein | i2i | ReferenceMultiLatent (images.image0..image9, resize 1 MP) + ConditioningZeroOut + KSampler; up to 10 reference images |
| `ideogram_4_t2i` | Ideogram 4 | t2i | two UNETLoaders; Ideogram4Scheduler (mu/std); DualModelGuider (cfg 7); EmptyFlux2LatentImage |
| `qwen_image_2_1_t2i` | Qwen Image 2.1 | t2i | bare TextEncodeQwenImage21 + KSampler; EmptyLatentImage; no cache/sigma nodes; 25 steps, cfg 1.0 |
| `qwen_image_2_1_i2i` | Qwen Image 2.1 | i2i | TextEncodeQwenImage21 (image_1..image_10) + QwenImage21Cache + KSampler; EmptyLatentImage w×h; 25 steps euler/simple |
| `qwen_image_2_1_turbo_t2i` | Qwen Image 2.1 Turbo | t2i | same bare chain as 2.1 t2i with turbo transformer; 8 steps, cfg 1.0 |
| `qwen_image_2_1_turbo_i2i` | Qwen Image 2.1 Turbo | i2i | QwenImage21Cache + CFGGuider + ManualSigmas (official 8-step curve) + SamplerCustomAdvanced; EmptyLatentImage w×h |
| `moss_image_t2i` | MOSS Image | t2i | SFT int8 + W4A8 encoder + small VAE; 25 steps, cfg 2.5, er_sde/simple |
| `moss_image_i2i_lora` | MOSS Image | i2i | LoadImage → ImageScaleToTotalPixels (1 MP) → TextEncodeMOSSImageEdit ×2; edit LoRA + SLG layer 22; 30 steps, cfg 4.0, euler/normal |
| `fibo2_t2i` | FIBO Image 2.0 | t2i | TextEncodeFibo2 (positive/negative/latent) → KSampler; 30 steps, cfg 5.0, euler/simple |
| `fibo2_dev_i2i` | FIBO Image 2.0 | i2i | TextEncodeFibo2 with `images.image_1`; Bria VGL negative; 50 steps, cfg 5.0, euler/simple |
| `fibo2_edit_turbo_i2i` | FIBO Image 2.0 Edit Turbo | i2i | TextEncodeFibo2 with `images.image_1`; 4 steps, cfg 1.0, euler/simple |
| `minimax_h3_image_t2i` | MiniMax H3 Image | t2i | MiniMaxH3ImageConditioning (prompt/width/height) → positive + latent; ConditioningZeroOut → negative; KSampler; 6 steps, cfg 1.0 |
| `minimax_h3_image_i2i` | MiniMax H3 Image | i2i | LoadImage → `images.image_1`..`image_10` on MiniMaxH3ImageConditioning; ConditioningZeroOut → negative; KSampler; 1024×1280 edit default |
| `ltx_2_5_t2v` | LTX 2.5 | t2v | two-stage distilled AV: 8 base steps at half resolution → 2× latent upscale → 3-step refine; ManualSigmas, DualCFGGuider, tiled video decode + audio VAE |
| `ltx_2_5_i2v` | LTX 2.5 | i2v | same two-stage chain with LoadImage → LTXVPreprocess → LTXVImgToVideoInplace (strength 0.7 base / 1.0 refine) |

## Per-model graphs

### Z Image Turbo — t2i (`z_image_turbo_t2i.json`)

```
UNETLoader (z_image_turbo_bf16) ──> ModelSamplingAuraFlow (shift 3) ──> KSampler ──> VAEDecode ──> SaveImage
CLIPLoader (lumina2) ──> CLIPTextEncode ──┬─> positive ──> KSampler
                                          └─> ConditioningZeroOut ──> negative ──> KSampler
EmptySD3LatentImage ──> latent ──> KSampler
```

KSampler: steps 8, cfg 1.0, res_multistep / simple, denoise 1.0.

### Krea 2 Turbo — t2i (`krea_2_turbo_t2i.json`)

```
UNETLoader (krea2_turbo_fp8_scaled) ──> KSampler ──> VAEDecode ──> SaveImage
CLIPLoader (krea2) ──> CLIPTextEncode ──┬─> positive ──> KSampler
                                       └─> ConditioningZeroOut ──> negative ──> KSampler
EmptyLatentImage ──> latent ──> KSampler
```

Plain KSampler: steps 8, cfg 1.0, euler / simple.

### Krea 2 Turbo — i2i (`krea_2_turbo_i2i.json`)

Same chain with `LoadImage ──> VAEEncode` replacing `EmptyLatentImage`; KSampler denoise.

### Flux 3 Klein — t2i (`flux_3_klein_t2i.json`)

```
UNETLoader (flux3_image_klein_sd_int8_convrot) ──> KSampler (steps 16, cfg 1.0, euler/simple) ──> VAEDecode ──> SaveImage
CLIPLoader (qwen3vl_4b_int8_convrot, type flux3) ──> CLIPTextEncode ──┬─> positive ──> KSampler
                                                                    └─> CLIPTextEncode ("") ──> negative ──> KSampler
EmptyFlux2LatentImage (w, h) ──> latent ──> KSampler
```

Official distilled chain (T2I template uses 15 steps er_sde; the UI default of 16 euler is within the "try 4-16" band). Optional Enhance injects CLIPLoader(prompt upsampler, type flux3) + TextGenerate(max 3584) feeding node 4.

### Flux 3 Klein — i2i (`flux_3_klein_i2i.json`)

```
LoadImage ──┬─> images.image0 ──> ReferenceMultiLatent (resize 1 MP, vae) ──┬─> positive ──> KSampler (denoise)
            └─> (images 2..10 via LoadImage 20..28 ──> images.image1..image9) ├─> negative ──> KSampler
CLIPLoader (flux3) ──> CLIPTextEncode ──> positive ──> ReferenceMultiLatent   └─> empty_latent ──> KSampler
                                    └─> ConditioningZeroOut ──> negative ──> ReferenceMultiLatent
```

The first reference sets the output canvas (empty_latent). Optional Enhance batches the same references into TextGenerate(image) with the edit system prompt.

### Qwen Image 2.1 — t2i (`qwen_image_2_1_t2i.json`, `qwen_image_2_1_turbo_t2i.json`)

```
UNETLoader (qwen_image_2.1[_turbo]_int8_convrot) ──> KSampler ──> VAEDecode ──> SaveImage
CLIPLoader (qwen3vl_8b_int8_convrot) ──> TextEncodeQwenImage21 ──┬─> positive ──> KSampler
                                                                  └─> negative ──> KSampler
EmptyLatentImage (w, h) ──> latent ──> KSampler
```

Base is 25 steps euler/simple; Turbo is 8 steps euler/simple, CFG 1.0. T2I is deliberately the bare chain: `QwenImage21Cache` only pays off for edits, and the Turbo manual-sigma schedule only exists in the edit graph.

### Qwen Image 2.1 — edit (`qwen_image_2_1_i2i.json`)

```
UNETLoader ──> QwenImage21Cache ──> KSampler (25, cfg 1.0, euler/simple) ──> VAEDecode ──> SaveImage
CLIPLoader ──> TextEncodeQwenImage21 ──┬─> positive ──> KSampler
                                        ├─> negative ──> KSampler
                                        └─> reference latents (encode node)
LoadImage (5) ──> images.image_1 ──> TextEncodeQwenImage21
EmptyLatentImage (6, w×h) ──> latent ──> KSampler
VAELoader ──> TextEncodeQwenImage21 + VAEDecode
```

The first reference is the edit target; extra references are LoadImage nodes 20..28 wired to `images.image_2`..`images.image_10`. Up to 10 references. Reference images are resized to about `resolution × resolution` pixels (0 keeps native sizes), while the output canvas comes from the EmptyLatentImage width/height. Edit defaults to 1024×1280. LoRAs attach as LoraLoaderModelOnly nodes 90+ in front of the cache node.

### Qwen Image 2.1 Turbo — edit (`qwen_image_2_1_turbo_i2i.json`)

```
UNETLoader ──> QwenImage21Cache ──> CFGGuider (cfg 1.0)
TextEncodeQwenImage21 ──┬─> positive ──> CFGGuider
                         └─> negative ──> CFGGuider
KSamplerSelect (euler) + ManualSigmas + RandomNoise ──> SamplerCustomAdvanced ──> VAEDecode ──> SaveImage
EmptyLatentImage (w×h) ──> SamplerCustomAdvanced
```

Uses the official 8-step Turbo sigma curve `1.0, 0.978453, 0.95418, 0.926626, 0.89508, 0.845148, 0.704534, 0.414568, 0`. Requesting a different step count resamples that curve; the scheduler picker is unused in this graph. Same 1–10 reference slots, 1024×1280 default canvas, and LoRA chain as the base edit.

### Ideogram 4 — t2i (`ideogram_4_t2i.json`)

```
UNETLoader (ideogram4) ──────────────> DualModelGuider (cfg 7) ──> SamplerCustomAdvanced ──> VAEDecode ──> SaveImage
UNETLoader (ideogram4_unconditional) ─> model_negative ──> DualModelGuider
CLIPLoader (ideogram4) ──> CLIPTextEncode ──┬─> positive ──> DualModelGuider
                                           └─> ConditioningZeroOut ──> negative ──> DualModelGuider
Ideogram4Scheduler (steps, w, h, mu, std) ──> sigmas ──> SamplerCustomAdvanced
KSamplerSelect (euler) ──> sampler ──> SamplerCustomAdvanced
RandomNoise ──> noise ──> SamplerCustomAdvanced
EmptyFlux2LatentImage ──> latent ──> SamplerCustomAdvanced
```

Ideogram presets (mapped to scheduler inputs in `backend/models.py`):

| Preset | steps | mu | std |
| --- | --- | --- | --- |
| Default | 20 | 0.0 | 1.75 |
| Turbo | 12 | 0.5 | 1.75 |
| Quality | 48 | 0.0 | 1.5 |

### MOSS Image — t2i (`moss_image_t2i.json`)

```
UNETLoader (moss_image_sft_int8_convrot) ──> KSampler (25, cfg 2.5, er_sde/simple) ──> VAEDecode ──> SaveImage
CLIPLoader (qwen3.5_9b_w4a8_gptq, type moss_image) ──> CLIPTextEncode ──┬─> positive ──> KSampler
                                                                       └─> CLIPTextEncode ("") ──> negative ──> KSampler
EmptyFlux2LatentImage (w, h) ──> latent ──> KSampler
VAELoader (flux2-vae_small) ──> VAEDecode
```

Derived from the official SFT template. Recipe: 25 steps, CFG 2.5, er_sde/simple, empty negative, no SLG or shift chain. The official optional prompt upsampler is intentionally omitted (MOSS has no enhancer; the W4A8 file is the text encoder).

### MOSS Image — i2i with edit LoRA (`moss_image_i2i_lora.json`)

```
LoadImage ──> ImageScaleToTotalPixels (1 MP, 16 px step) ──┬─> images.image_0 ──> TextEncodeMOSSImageEdit (39, positive)
                                                           ├─> images.image_0 ──> TextEncodeMOSSImageEdit (36, negative)
                                                           └─> GetImageSize ──> EmptyFlux2LatentImage ──> latent ──> KSampler
UNETLoader (moss_image_sft_int8_convrot) ──> LoraLoaderModelOnly (edit rank 64) ──> SkipLayerGuidanceDiTSimple (layer 22) ──> KSampler
CLIPLoader (qwen3.5_9b_w4a8_gptq, type moss_image) ──> both TextEncodeMOSSImageEdit nodes
VAELoader (flux2-vae_small) ──> both encode nodes + VAEDecode ──> SaveImage
```

KSampler: 30 steps, CFG 4.0, euler/normal, denoise 1.0. The negative node uses the LoRA author's recommended line. Additional references are injected as LoadImage + ImageScaleToTotalPixels pairs (nodes 60/61, 62/63, …) and wired into `images.image_1`, `images.image_2`, … on both encode nodes. Maximum 4 references.

### FIBO Image 2.0 — t2i (`fibo2_t2i.json`)

```
UNETLoader (fibo2_dev_int8_convrot) ──> KSampler (30, cfg 5.0, euler/simple) ──> VAEDecode ──> SaveImage
CLIPLoader (qwen3vl_4b_int8_convrot, type fibo2) ──> TextEncodeFibo2 (positive, negative, latent)
                                                        └─> latent ──> KSampler
VAELoader (flux2-vae) ──> VAEDecode
```

No official local FIBO T2I template exists; this uses the official `TextEncodeFibo2` node without images and explicit 1024x1024. `TextEncodeFibo2` returns positive, negative, and the starting latent directly.

### FIBO Image 2.0 — Dev edit (`fibo2_dev_i2i.json`)

```
LoadImage ──> images.image_1 ──> TextEncodeFibo2 ──┬─> positive ──> KSampler (50, cfg 5.0, euler/simple)
                                                    ├─> negative ──> KSampler
                                                    └─> latent ──> KSampler
UNETLoader (fibo2_dev_int8_convrot) ──> KSampler
VAELoader (flux2-vae) ──> TextEncodeFibo2 + VAEDecode ──> SaveImage
```

The template ships Bria's structured VGL negative (802 characters) in `negative_prompt`; `build_workflow` keeps it when the request's negative is empty. Extra references become LoadImage nodes (60, 61, …) wired to `images.image_2` … `images.image_16`.

### FIBO Image 2.0 Edit Turbo — i2i (`fibo2_edit_turbo_i2i.json`)

Same graph with `fibo2_edit_turbo_int8_convrot`, 4 steps, CFG 1.0, empty negative. Turbo is a separate diffusion model, not a LoRA on Dev.

### MiniMax H3 Image — t2i (`minimax_h3_image_t2i.json`)

```
UNETLoader (minimax_h3_image_pruned_w4a8) ──> KSampler (6, cfg 1.0, euler/simple) ──> VAEDecode ──> SaveImage
CLIPLoader (qwen3vl_32b_minimax_h3_nvfp4_awq, type minimax) ──> MiniMaxH3ImageConditioning
VAELoader (minimax_h3_image_vae_fp16) ──> MiniMaxH3ImageConditioning + VAEDecode
MiniMaxH3ImageConditioning ──┬─> positive ──> KSampler
                             ├─> latent ──> KSampler
                             └─> ConditioningZeroOut ──> negative ──> KSampler
```

`MiniMaxH3ImageConditioning` builds the empty 24-channel image latent from width/height (multiples of 32). The negative is the zeroed-out positive because CFG is fixed at 1.0.

### MiniMax H3 Image — edit (`minimax_h3_image_i2i.json`)

Same graph plus `LoadImage → images.image_1` on the conditioning node, using the tested 4-reference edit chain. Extra references are LoadImage nodes (20..28) wired to `images.image_2`..`images.image_10`; up to 10 total. The VAE anchors each reference as a latent; image 1 is the picture being edited and the prompt addresses references as `<Picture 1>`, `<Picture 2>`, …. Edit defaults to 1024×1280 and can be raised from the size controls. T2I omits all edit-only reference and resize nodes.

## Video two-stage graphs

### LTX 2.5 — t2v / i2v (`ltx_2_5_t2v.json`, `ltx_2_5_i2v.json`)

LTX 2.5 distilled uses the official two-pass setup. A single full-resolution pass is lower quality, so stage 1 samples a half-resolution latent and stage 2 refines its 2× upscale.

```
Stage 1 (base, 8 steps)
EmptyLTXVLatentVideo (width/2, height/2) ─┐
LTXVEmptyLatentAudio ─────────────────────┴─> LTXVConcatAVLatent ─> SamplerCustomAdvanced ─> LTXVSeparateAVLatent
CLIPTextEncode positive/negative ─> LTXVConditioning ─> LTXVDualCFGGuider (video 1.0 / audio 1.0)
ManualSigmas (1.0, 0.99375, 0.9875, 0.98125, 0.975, 0.909375, 0.725, 0.421875, 0.0)
KSamplerSelect (euler_ancestral) + RandomNoise (seed)

Stage 2 (refine, 3 steps)
video latent ─> LTXVLatentUpsampler (x2 model + video VAE) ─┐
audio latent (from stage 1) ────────────────────────────────┴─> LTXVConcatAVLatent ─> SamplerCustomAdvanced
ManualSigmas (t2v: 0.85, 0.725, 0.4219, 0.0; i2v: 0.909375, 0.725, 0.421875, 0.0)
RandomNoise (seed + 1)

Decode: LTXVSeparateAVLatent ─┬─> VAEDecodeTiled (512 / 64 / 64 / 16) ─┐
                             └─> LTXVAudioVAEDecode ──────────────────┴─> CreateVideo ─> SaveVideo
```

- i2v adds `LoadImage → LTXVPreprocess (18) → LTXVImgToVideoInplace` at strength 0.7 before stage 1 and strength 1.0 after the upscale.
- `width_half` / `height_half` are computed in the backend. Output width/height snap to the nearest multiple of 64 so stage 1 lands on the 32-px latent grid; frame counts snap to `8k+1`.
- `backend/video.py` exposes `steps` as the total. The official split is 8 base + 3 refine (11 total); other counts resample both official sigma curves with the same 8:3 ratio.
- The scheduler field is hidden in both UIs because `ManualSigmas` owns the schedule.

## Fill map

`backend/workflows.py` maps semantic parameter names to `(node_id, input)` targets. The UI only ever speaks semantics; it never addresses node ids.

| semantic param | node id (example) | input |
| --- | --- | --- |
| `prompt` | 4 (z t2i) | `text` |
| `width` / `height` | 6 (z t2i) | `width` / `height` |
| `batch` | 6 (z t2i) | `batch_size` |
| `seed` | 8 (z t2i) | `seed` |
| `steps` / `cfg` | 8 (z t2i) | `steps` / `cfg` |
| `sampler` / `scheduler` | 8 (z t2i) | `sampler_name` / `scheduler` |
| `denoise` | 9 (z i2i) | `denoise` |
| `image` | 6 (z i2i) | `image` |

Multi-image edits append LoadImage nodes: Qwen 2.1 (20..28), MiniMax H3 Image (20..28) and MOSS (60/61 pairs, scaled) target `images.image_2`.. on their encode node; Flux 3 Klein (20..28) targets `images.image1`.. on ReferenceMultiLatent node 17; FIBO (60, 61, …) targets `images.image_2`.. on TextEncodeFibo2 node 4. Enhance injects the TextGenerate chain nodes 40-43. LoRAs attach as LoraLoaderModelOnly nodes 90+.

Model-dependent mappings (seed vs noise_seed, scheduler node selection, etc.) live next to the fill map. LTX video maps `width_half`/`height_half` to the stage-1 latent, `sigmas_base`/`sigmas_refine` to the two `ManualSigmas` nodes, and `seed_refine` to stage-2 noise.

## Editing a template

1. Change values in the JSON only (e.g. a different VAE file name).
2. If you add, remove, or rename nodes, update the fill map in `backend/workflows.py` to match — mismatches surface as a loud drift-guard error at generate time, not silent breakage.
3. Template files are read from disk on every request, so edits apply after a **page refresh** — no backend restart needed.

## Validation

- Templates are validated at generate time: the backend checks the fill map against the template (node ids exist, inputs exist, values in range) and lets ComfyUI validate the final prompt.
- `/lazycomfy/api/workflows` reports each template's `class_types` — a quick way to confirm the templates only use nodes ComfyUI exposes.

## Preset system

Per-model defaults, limits, and options live in `backend/models.py` and are served to the UI by `/lazycomfy/api/models`:

- defaults: steps, cfg, sampler, scheduler, seed handling, resolution, denoise, mu/std.
- mode_defaults: per-mode overrides for steps/cfg/sampler/scheduler/denoise/negative_prompt (MOSS T2I vs edit, FIBO Dev T2I vs edit).
- limits: min/max width/height, steps, cfg visibility, denoise range.
- options: aspect ratio list, sampler list, scheduler list, `denoise_fixed` for reference-edit models, Ideogram preset mapping (preset → mu/std/steps).

The UI renders controls from this data, so adding a model family later is a data change plus a template, not a frontend rewrite.
