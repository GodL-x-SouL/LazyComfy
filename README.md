# LazyComfy

A lightweight generation console for ComfyUI. Served at `http://127.0.0.1:8188/lazycomfy` — minimal UI, fast loading, built for slow tunnels.

## Features

- Single self-contained HTML page — tiny initial transfer, few requests.
- Model presets: **Z Image Turbo**, **Krea 2 Turbo**, **Flux 2 Klein 9B**, **Ideogram 4** (text-to-image + image-to-image).
- Queue and progress via native ComfyUI WebSocket.
- Recent outputs gallery with open/download/reuse/send-to-img2img/copy-prompt actions.
- In-app model downloader with progress and cancel.
- AMOLED dark mode, mobile-friendly, `Ctrl+Enter` to generate.

## Requirements

- ComfyUI ≥ 0.3.2x (latest stable recommended).
- Python ≥ 3.10, aiohttp (ships with ComfyUI).

## Install

Clone into ComfyUI's custom nodes directory:

```text
ComfyUI/custom_nodes/lazycomfy/
```

Restart ComfyUI, open `http://127.0.0.1:8188/lazycomfy`.

## Model Installation

Models are not bundled. Use the built-in downloader (download icon in top bar) or download manually into standard ComfyUI model directories. See `docs/model-notes.md` for exact files and sources.

| Model | Total Size |
| --- | --- |
| Z Image Turbo | ~21 GB |
| Krea 2 Turbo | ~18 GB |
| Flux 2 Klein 9B | ~19 GB |
| Ideogram 4 | ~29 GB |

## Usage

1. Open `/lazycomfy`, pick a model and mode (txt2img or img2img).
2. Type a prompt, press Generate.
3. Finished images appear in the gallery with actions.

Outputs saved to `output/lazycomfy/<slug>/`.

## Tunnels

Works well over slow tunnels:

- Cloudflare: `cloudflared tunnel --url http://127.0.0.1:8188`
- Pinggy: `ssh -p 443 -R0:localhost:8188 a.pinggy.io`

Keep ComfyUI bound to `--listen 127.0.0.1`. Do not rewrite the Host header to `localhost`.

## Project Layout

```text
lazycomfy/
  __init__.py
  backend/          # routes, presets, queue, downloader, config
  web/
    index.html      # main UI
    video.html      # video generation
    upscale.html    # upscale
    forge.html      # prompt forge (local LLM)
  workflows/        # API-format workflow templates
  docs/             # model-notes, api-notes, troubleshooting, etc.
```

## Docs

- `docs/model-notes.md` — per-model files, loaders, constraints.
- `docs/api-notes.md` — API and WebSocket protocol.
- `docs/troubleshooting.md` — common problems and fixes.
