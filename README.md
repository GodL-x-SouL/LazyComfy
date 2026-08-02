# LazyComfy — a lightweight generation console for ComfyUI

LazyComfy is a ComfyUI custom-node package that adds a fast-loading, minimal generation UI at `http://127.0.0.1:8188/lazycomfy`. The default ComfyUI frontend is heavy — canvas bootstrapping, graph state, and large asset bundles take many round trips that are painful over slow tunnels (Cloudflare Tunnel, Pinggy). LazyComfy is a focused "generation console": one self-contained HTML page, a handful of API calls, and a WebSocket. It is not a canvas replacement — there is no graph editor. It supports exactly four model families — **Z Image Turbo**, **Krea 2 Turbo**, **Flux 2 Klein 9B**, and **Ideogram 4** — in both **text-to-image** and **image-to-image** modes.

## Features

- Served at its own route, `GET /lazycomfy` — no dependency on the main frontend.
- Minimal single-file UI (`web/index.html`) — tiny initial transfer, few requests.
- Model presets for the four supported families, with per-model defaults, limits, and options.
- Text-to-image and image-to-image for every model.
- Queue and progress via the native ComfyUI WebSocket (percentages and current stage).
- Recent outputs gallery with per-image actions: open, download, reuse settings, send to img2img, copy prompt.
- Image upload and drag-and-drop for img2img.
- In-app model downloader (top bar): variant catalog for all four families with progress, cancel, and auto-refreshing file state.
- Per-family file pickers to pin a specific installed variant (e.g. an int8 unet) for generation.
- AMOLED dark mode toggle and themed scrollbars.
- Mobile-friendly: stacked panels, large tap targets, responsive gallery.
- Keyboard shortcut: `Ctrl+Enter` to generate.

## Requirements

- Recent ComfyUI. The templates rely on core nodes that ship with the current stable line: `Flux2Scheduler`, `CFGGuider`, `Ideogram4Scheduler`, `DualModelGuider`, `EmptyFlux2LatentImage`, `EmptySD3LatentImage`, `ModelSamplingAuraFlow`. These exist in ComfyUI 0.3.2x and newer (Krea 2 support needs ComfyUI >= 0.26.0). **Update ComfyUI to the latest stable before use.**
- Python >= 3.10.
- aiohttp (ships with ComfyUI).
- Model files for whichever families you want to use (see below).

## Install

Clone or copy this folder into ComfyUI's custom nodes directory, then restart ComfyUI:

```text
ComfyUI/
  custom_nodes/
    lazycomfy/          <- this repository
```

After restart, open `http://127.0.0.1:8188/lazycomfy`.

### Model installation

Models are not bundled. Download them into the standard ComfyUI model directories:

| Model | Diffusion model (`models/diffusion_models/`) | Text encoder (`models/text_encoders/`) | VAE (`models/vae/`) | Total |
| --- | --- | --- | --- | --- |
| Z Image Turbo | `z_image_turbo_bf16.safetensors` (12.3 GB) | `qwen_3_4b.safetensors` (8.04 GB) | `ae.safetensors` (335 MB) | ~21 GB |
| Krea 2 Turbo | `krea2_turbo_fp8_scaled.safetensors` (~13 GB) | `qwen3vl_4b_fp8_scaled.safetensors` (~4 GB) | `qwen_image_vae.safetensors` (~1 GB) | ~18 GB |
| Flux 2 Klein 9B | `flux-2-klein-9b-fp8.safetensors` (9.4 GB) | `qwen_3_8b_fp8mixed.safetensors` (~8.3 GB) | `full_encoder_small_decoder.safetensors` (~1 GB) | ~19 GB |
| Ideogram 4 | `ideogram4_fp8_scaled.safetensors` + `ideogram4_unconditional_fp8_scaled.safetensors` (9.28 GB each) | `qwen3vl_8b_fp8_scaled.safetensors` (10.59 GB) | `flux2-vae.safetensors` (336 MB) | ~29 GB |

Sources (HF repos):

- Z Image Turbo: `Comfy-Org/z_image_turbo` — `split_files/diffusion_models/`, `split_files/text_encoders/`, `split_files/vae/` (fp8/int8 alternates available).
- Krea 2 Turbo: `Comfy-Org/Krea-2` — `diffusion_models/`, `text_encoders/`, `vae/` (bf16 26.3 GB / int8 alternates exist; the fp8 files above are recommended).
- Flux 2 Klein 9B: diffusion model from gated `black-forest-labs/FLUX.2-klein-9b-fp8`; text encoder from `Comfy-Org/flux2-klein-9B/split_files/text_encoders/`; VAE from `black-forest-labs/FLUX.2-small-decoder` (alt: `flux2-vae.safetensors` 336 MB from `Comfy-Org/flux2-dev/split_files/vae/`).
- Ideogram 4: `Comfy-Org/Ideogram-4` (`diffusion_models/`), `Comfy-Org/Qwen3-VL` (`text_encoders/`), `Comfy-Org/flux2-dev/split_files/vae/`.

ComfyUI's built-in **Model Manager** can download the ungated `Comfy-Org/*` repos directly. The Flux 2 Klein BFL repos are **gated** — accept the license on Hugging Face first, then download.

**Easier:** use the built-in downloader (download icon in the LazyComfy top bar). It offers all precision variants, text encoders, and VAEs for the four families, downloads in the background with progress and cancel, and drops files straight into the correct model folders. See `docs/model-notes.md` §5 for the full catalog.

See `docs/model-notes.md` for exact per-model requirements and constraints.

## Usage

1. Open `http://127.0.0.1:8188/lazycomfy`.
2. Pick a model (one of the four cards).
3. Pick a mode: Text to Image or Image to Image (i2i shows the upload/drop zone and denoise control).
4. Type a prompt and press Generate (`Ctrl+Enter` also generates).

Progress streams through the WebSocket; finished images land in the gallery with open/download/reuse/send-to-img2img/copy-prompt actions. Outputs are saved by ComfyUI under `output/lazycomfy/<slug>/`.

If something goes wrong, see `docs/troubleshooting.md`.

## Tunnels

LazyComfy is built for slow tunnels. Example tunnels:

- Cloudflare Quick Tunnel: `cloudflared tunnel --url http://127.0.0.1:8188` — if the WebSocket fails with HTTP 400 or WS close code 1006, add `--protocol http2`.
- Pinggy: `ssh -p 443 -R0:localhost:8188 a.pinggy.io`

Rules:

- Keep ComfyUI bound to `--listen 127.0.0.1` unless the tunnel runs on another machine.
- **Do not rewrite the Host header to `localhost`** through the tunnel. ComfyUI rejects requests whose Host/Origin mismatch on loopback hosts — the tunnel must keep its public hostname as the Host header.

## Project layout

```text
lazycomfy/
  __init__.py
  README.md
  backend/            # routes, downloader, templates (fill map), model presets, queue, files, validation, config
  web/
    index.html        # the entire UI: single self-contained file
  workflows/          # 8 API-format workflow templates (one per model x mode)
  docs/
    model-notes.md
    api-notes.md
    workflow-notes.md
    test-checklist.md
    troubleshooting.md
```

## Docs index

- `docs/model-notes.md` — per-model profiles: files, loaders, prompts, sampling, img2img notes.
- `docs/api-notes.md` — `/lazycomfy` API, native ComfyUI endpoints, WebSocket protocol.
- `docs/workflow-notes.md` — template rules, node chains, fill map, presets.
- `docs/test-checklist.md` — acceptance-driven manual test checklist.
- `docs/troubleshooting.md` — common problems and fixes.

## Dev notes

- Workflow templates are plain ComfyUI API-format JSON in `workflows/`; they are POSTable directly and read from disk per request (edits apply after a page refresh, no backend restart).
- The semantic-parameter-to-node mapping ("fill map") lives in `backend/workflows.py` and must stay in sync with node ids in the templates.
- Model presets (defaults, limits, options) live in `backend/models.py`.
- The page is a single self-contained file, `web/index.html` — keep it that way (no bundled libraries, no extra assets).
