# Workflow notes

## Template rules

- Templates are pure ComfyUI **API-format** JSON: keys are node ids as strings, each node has `class_type` and `inputs`, and links are `["<node_id>", <output_slot>]`.
- No layout/position data (that belongs to the canvas format only).
- The backend strips nothing — templates are directly POSTable to `/prompt` as-is.
- Node ids are **fixed per template** and mirrored by the fill map in `backend/workflows.py`. Keep the two in sync whenever you edit nodes.
- Every template ends with a `SaveImage` using `filename_prefix: lazycomfy/<slug>` — outputs land in `output/lazycomfy/<slug>/`.

## Template inventory

| Template id | Model | Mode | Key chain |
| --- | --- | --- | --- |
| `z_image_turbo_t2i` | Z Image Turbo | t2i | UNETLoader → ModelSamplingAuraFlow(shift 3) → KSampler; CLIPTextEncode → ConditioningZeroOut; EmptySD3LatentImage; VAEDecode → SaveImage |
| `z_image_turbo_i2i` | Z Image Turbo | i2i | same as t2i + LoadImage → VAEEncode, KSampler denoise 0.5 |
| `krea_2_turbo_t2i` | Krea 2 Turbo | t2i | plain KSampler chain, EmptyLatentImage |
| `krea_2_turbo_i2i` | Krea 2 Turbo | i2i | LoadImage → VAEEncode → KSampler (denoise) |
| `flux_2_klein_9b_t2i` | Flux 2 Klein 9B | t2i | custom chain: Flux2Scheduler + CFGGuider + KSamplerSelect + RandomNoise + SamplerCustomAdvanced; EmptyFlux2LatentImage; 4 steps, cfg 1.0 |
| `flux_2_klein_9b_i2i` | Flux 2 Klein 9B | i2i | KSampler chain for denoise control (deliberate choice — see below) |
| `ideogram_4_t2i` | Ideogram 4 | t2i | two UNETLoaders; Ideogram4Scheduler (mu/std); DualModelGuider (cfg 7); EmptyFlux2LatentImage |
| `ideogram_4_i2i` | Ideogram 4 | i2i | single UNET + plain KSampler — EXPERIMENTAL, asymmetric guidance not applied |

## Per-model graphs

### Z Image Turbo — t2i (`z_image_turbo_t2i.json`)

```
UNETLoader (z_image_turbo_bf16) ──> ModelSamplingAuraFlow (shift 3) ──> KSampler ──> VAEDecode ──> SaveImage
CLIPLoader (lumina2) ──> CLIPTextEncode ──┬─> positive ──> KSampler
                                          └─> ConditioningZeroOut ──> negative ──> KSampler
EmptySD3LatentImage ──> latent ──> KSampler
```

KSampler: steps 8, cfg 1.0, res_multistep / simple, denoise 1.0.

### Z Image Turbo — i2i (`z_image_turbo_i2i.json`)

Adds `LoadImage ──> VAEEncode ──> latent` in place of `EmptySD3LatentImage`; KSampler denoise 0.5.

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

### Flux 2 Klein 9B — t2i (`flux_2_klein_9b_t2i.json`)

```
UNETLoader (flux-2-klein-9b-fp8) ──> CFGGuider (cfg 1.0) ──> SamplerCustomAdvanced ──> VAEDecode ──> SaveImage
CLIPLoader (flux2) ──> CLIPTextEncode ──┬─> positive ──> CFGGuider
                                       └─> ConditioningZeroOut ──> negative ──> CFGGuider
Flux2Scheduler (steps 4, w, h) ──> sigmas ──> SamplerCustomAdvanced
KSamplerSelect (euler) ──> sampler ──> SamplerCustomAdvanced
RandomNoise ──> noise ──> SamplerCustomAdvanced
EmptyFlux2LatentImage ──> latent ──> SamplerCustomAdvanced
```

Official distilled chain: 4 steps, cfg 1.0, euler.

### Flux 2 Klein 9B — i2i (`flux_2_klein_9b_i2i.json`)

Uses a standard KSampler (`LoadImage ──> VAEEncode ──> KSampler`) with denoise instead of the custom chain. Deliberate: `Flux2Scheduler`/`CFGGuider` provide no denoise control, and strength control matters more for i2i. Full reference-latent edit workflows belong in the main editor.

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

### Ideogram 4 — i2i (`ideogram_4_i2i.json`)

EXPERIMENTAL: a single UNET + plain KSampler (cfg 7, euler, denoise). The second (unconditional) UNET and `DualModelGuider` are not used, so asymmetric guidance does not apply and quality differs from T2I.

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

Example for Flux 2 Klein 9B t2i (custom chain has no single sampler node):

| semantic param | node id | input |
| --- | --- | --- |
| `steps` | 8 | `steps` (Flux2Scheduler) |
| `cfg` | 9 | `cfg` (CFGGuider) |
| `sampler` | 7 | `sampler_name` (KSamplerSelect) |
| `seed` | 10 | `noise_seed` (RandomNoise) |
| `width` / `height` | 6 | `width` / `height` (EmptyFlux2LatentImage) |

Model-dependent mappings (seed vs noise_seed, scheduler node selection, etc.) live next to the fill map.

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
- limits: min/max width/height, steps, cfg visibility, denoise range.
- options: aspect ratio list, sampler list, scheduler list, Ideogram preset mapping (preset → mu/std/steps).

The UI renders controls from this data, so adding a model family later is a data change plus a template, not a frontend rewrite.
