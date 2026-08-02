# API notes

## Overview

LazyComfy is a hybrid: a small Python backend (`backend/`) plus a single-file vanilla frontend (`web/index.html`). The page talks to two surfaces:

- `/lazycomfy/api/*` — LazyComfy's own endpoints (config, models, workflows, generate, upload, result, cancel, history, queue).
- Native ComfyUI endpoints — `/prompt`, `/ws`, `/view`, `/upload/image`, `/history`, `/interrupt`, `/queue`.

LazyComfy does not reimplement generation: it fills an API-format template, submits it to ComfyUI's `/prompt`, and streams progress from the WebSocket.

## LazyComfy endpoints

Every non-static route is also registered under the `/api/...` prefix by ComfyUI (e.g. `/api/lazycomfy/api/models`), but the paths below are the canonical ones.

| Method | Path | Purpose | Request | Response |
| --- | --- | --- | --- | --- |
| GET | `/lazycomfy` | serve the UI shell | — | HTML page (`web/index.html`) |
| GET | `/lazycomfy/static/*` | static assets (unused by default; page is self-contained) | — | files from `web/static/` |
| GET | `/lazycomfy/api/config` | app configuration | — | see below |
| GET | `/lazycomfy/api/models` | model presets + file availability | — | `{ "models": [...] }` |
| GET | `/lazycomfy/api/workflows` | template inventory | — | `{ "workflows": [...] }` |
| POST | `/lazycomfy/api/generate` | validate params, fill template, submit to ComfyUI | see below | `{ "prompt_id", "number", "submitted_at" }` |
| POST | `/lazycomfy/api/upload` | accept image upload, relay to `/upload/image` | multipart field `image` | `{ "name", "subfolder", "type" }` |
| GET | `/lazycomfy/api/result/{prompt_id}` | job result | — | see below |
| POST | `/lazycomfy/api/cancel/{prompt_id}` | targeted interrupt (proxies `/interrupt`) | — | `{ "ok": true }` |
| GET | `/lazycomfy/api/history` | recent LazyComfy jobs | query `?limit=12` (max 50) | `{ "jobs": [...] }` |
| GET | `/lazycomfy/api/queue` | queue depth | — | `{ "queue_remaining": n }` |
| GET | `/lazycomfy/api/catalog` | downloadable model-file catalog + active download tasks | — | see below |
| GET | `/lazycomfy/api/files` | what model files ComfyUI has on disk | — | `{ "dirs": { "diffusion_models": [...], "text_encoders": [...], "vae": [...], "loras": [...] } }` |
| POST | `/lazycomfy/api/download` | start a background download | `{ "item_id" }` | `{ "id", "item_id", "target_name", "status", "downloaded", "total", "error" }` |
| GET | `/lazycomfy/api/download/{task_id}` | single download task status | — | task object (above) or 400 `unknown_task` |
| POST | `/lazycomfy/api/download/cancel/{task_id}` | cancel a running download | — | `{ "cancelled": bool }` |

### `GET /lazycomfy/api/config`

```json
{
  "lazycomfy_version": "0.1.0",
  "comfyui_version": "0.3.26",
  "python_version": "3.12.0",
  "device": { "name": "NVIDIA GeForce RTX 4090", "type": "cuda", "index": 0, "vram_total": 25767067648, "vram_free": 0 },
  "max_upload_mb": 50
}
```

`device` is the first entry of `/system_stats` devices, or `null` when stats are unavailable. `max_upload_mb` defaults to 50 and can be overridden with the `LAZYCOMFY_MAX_UPLOAD_MB` environment variable.

### `GET /lazycomfy/api/models`

```json
{
  "models": [
    {
      "id": "z_image_turbo",
      "name": "Z Image Turbo",
      "family": "Alibaba Z-Image · S3-DiT 6B · 8-step distilled",
      "tagline": "Fast, bilingual natural-language images in 8 steps.",
      "modes": ["t2i", "i2i"],
      "supports_negative": false,
      "negative_note": "Ignored by this model — only the positive prompt is used.",
      "files": [
        { "kind": "unet", "label": "Diffusion model", "dir": "diffusion_models", "name": "z_image_turbo_bf16.safetensors", "present": true }
      ],
      "defaults": { "width": 1024, "height": 1024, "steps": 8, "cfg": 1.0, "sampler": "res_multistep", "scheduler": "simple", "batch": 1, "denoise": 0.5 },
      "limits": { "width_min": 256, "width_max": 2048, "height_min": 256, "height_max": 2048, "steps_min": 1, "steps_max": 10, "cfg_min": 0.5, "cfg_max": 4.0, "batch_max": 4, "denoise_min": 0.05, "denoise_max": 1.0 },
      "options": {
        "cfg_visible": true,
        "samplers": ["res_multistep", "euler", "euler_ancestral", "heun", "dpmpp_2m"],
        "schedulers": ["simple", "normal", "karras", "exponential"],
        "scheduler_fixed": false,
        "aspects": [ { "label": "Square 1:1", "width": 1024, "height": 1024 } ],
        "presets": null
      },
      "notes": ["..."],
      "tip": "Sweet spot: 8 steps, CFG 1.0, 1024×1024."
    }
  ]
}
```

- `files[].present` reflects what ComfyUI currently has on disk (`folder_paths.get_filename_list`); the UI warns and disables Generate when a file is missing.
- `options.cfg_visible: false` means guidance is fixed (Krea 2 Turbo: cfg 1.0).
- `options.scheduler_fixed: true` means the schedule is produced by a dedicated scheduler node (Flux 2 Klein, Ideogram 4) — the UI hides the scheduler select.
- `options.presets` (Ideogram 4 only) is `{ "id", "label", "options": [ { "id", "label", "steps", "mu", "std" } ] }`; the chosen preset id is sent as `preset` in generate.

### `GET /lazycomfy/api/workflows`

```json
{
  "workflows": [
    { "id": "z_image_turbo_t2i", "model_id": "z_image_turbo", "mode": "t2i", "output_node": "10", "node_count": 10, "class_types": ["CLIPLoader", "CLIPTextEncode", "ConditioningZeroOut", "EmptySD3LatentImage", "KSampler", "ModelSamplingAuraFlow", "SaveImage", "UNETLoader", "VAEDecode", "VAELoader"] }
  ]
}
```

Templates that fail to load are skipped with a server-side warning.

### `POST /lazycomfy/api/generate`

Request:

```json
{
  "model_id": "z_image_turbo",
  "mode": "t2i",
  "prompt": "a red car in the rain",
  "negative_prompt": "blurry",              // optional; ignored when the model has no negative support
  "width": 1024, "height": 1024,
  "steps": 8, "cfg": 1.0,
  "sampler": "res_multistep", "scheduler": "simple",
  "seed": 123456,                            // optional; server picks a random seed when absent
  "batch": 1,
  "denoise": 0.5,                            // i2i only
  "image": { "name": "photo.png", "subfolder": "lazycomfy" },  // i2i only
  "preset": "default",                       // optional; Ideogram 4 only
  "files": { "unet": "z_image_turbo_int8_convrot.safetensors" },  // optional; per-kind variant overrides
  "client_id": "e8e74dbd-..."                // optional; ties /ws execution events to this client
}
```

The optional `files` object overrides which on-disk files the workflow loads, per kind (`unet`, `uncond`, `clip`, `vae`). Keys are validated against the template's loader nodes (`uncond` is accepted only by Ideogram 4 t2i), names must be plain basenames, and each named file must exist in ComfyUI's model folders at submit time — otherwise `invalid_request` (400). The chosen files also drive the `missing_model_files` (502) check instead of the template defaults. Values land in the workflow via the `*_file` fill keys (`unet_name` / `clip_name` / `vae_name` on the loader nodes).

Response 200:

```json
{ "prompt_id": "9a0f...", "number": 3, "submitted_at": 1754000000 }
```

Validation behavior:

- Width/height are rounded **down** to multiples of 16 when needed (flagged in history metadata as `adjusted`).
- `batch` is forced to 1 in i2i mode.
- `cfg` is clamped to the model's `limits`; an invalid sampler/scheduler silently falls back to the model default.
- `preset` (Ideogram 4) applies the preset's `mu`/`std` to `Ideogram4Scheduler`; the preset's steps are used unless `steps` was explicitly provided.
- If any required model file is missing on disk, the request fails with `missing_model_files` (HTTP 502) before submission.

Errors return the envelope below with HTTP 400 (client errors) or 502 (ComfyUI-side errors).

### `POST /lazycomfy/api/upload`

Multipart body with a single file field `image` (PNG, JPEG, or WebP; size ≤ `max_upload_mb`). The backend validates type/size/name, then relays to ComfyUI's `/upload/image` with `overwrite=true`, `type=input`, `subfolder=lazycomfy`.

```json
{ "name": "photo_00001_.png", "subfolder": "lazycomfy", "type": "input" }
```

For `LoadImage`, the input value is `"<subfolder>/<name>"` = `"lazycomfy/photo_00001_.png"` (no type suffix because `type` is `input`).

### `GET /lazycomfy/api/result/{prompt_id}`

```json
{
  "status": "success",
  "outputs": [
    { "filename": "ComfyUI_00001_.png", "subfolder": "lazycomfy/z-image-turbo", "type": "output", "url": "/view?filename=ComfyUI_00001_.png&subfolder=lazycomfy%2Fz-image-turbo&type=output" }
  ],
  "meta": { "model_id": "z_image_turbo", "template_id": "z_image_turbo_t2i", "mode": "t2i", "prompt": "a red car", "negative_prompt": null, "params": { "width": 1024, "steps": 8, "cfg": 1.0, "seed": 123456 }, "adjusted": false },
  "error": null
}
```

`status` is one of `success | error | running | unknown`. On `error`, `error` is `{ "exception_type", "exception_message" }` when known. On `running`, the backend checks the live queue before giving up.

### `GET /lazycomfy/api/history?limit=10`

```json
{
  "jobs": [
    {
      "prompt_id": "9a0f...",
      "status": "success",
      "timestamp": 1754000000000,
      "model_id": "z_image_turbo",
      "mode": "t2i",
      "prompt": "a red car",
      "params": { "width": 1024, "steps": 8, "cfg": 1.0, "seed": 123456 },
      "images": [ { "filename": "...", "subfolder": "lazycomfy/z-image-turbo", "type": "output", "url": "/view?..." } ]
    }
  ]
}
```

Only jobs submitted through LazyComfy appear (filtered by the `extra_data.lazycomfy` tag), newest first.

### `GET /lazycomfy/api/catalog`

```json
{
  "items": [
    {
      "id": "z_image_turbo:unet:z_image_turbo_int8_convrot.safetensors",
      "model_id": "z_image_turbo",
      "kind": "unet",
      "label": "Diffusion model",
      "repo": "Comfy-Org/z_image_turbo",
      "path": "split_files/diffusion_models/z_image_turbo_int8_convrot.safetensors",
      "size": 6201001296,
      "note": "INT8 + convrot — lower VRAM",
      "gated": false,
      "target_dir": "diffusion_models",
      "target_name": "z_image_turbo_int8_convrot.safetensors",
      "present": false
    }
  ],
  "tasks": [ { "id": "ab12cd34ef56", "item_id": "...", "target_name": "...", "status": "downloading", "downloaded": 1048576, "total": 6201001296, "error": null } ]
}
```

- The catalog is static (`backend/hub.py`), verified against Hugging Face on 2026-08-02. `kind` is one of `unet | uncond | clip | vae | lora`. `present` reflects the file on disk.
- Z Image Turbo files all live under the `split_files/` prefix; the downloader also tries `split_files/<dir>/<name>` as a fallback path for every item.
- `POST /lazycomfy/api/download` starts a background task; progress is polled through `GET /lazycomfy/api/catalog` or the per-task endpoint. Tasks survive the UI closing (they live in the backend event loop).
- **Multi-connection downloads**: the backend probes the mirror with a 1-byte `Range` request. If the server answers `206`, the file is fetched with parallel byte-range connections (2 for ≥256 MB, 4 for ≥1 GB, 8 for ≥8 GB — capped by `LAZYCOMFY_DL_SPLITS`, default 8); otherwise a single connection is used. Each segment writes to its own offset of `<file>.part` (pre-sized, seek writes) and the file is renamed atomically on completion. ComfyUI's `filename_list_cache` is invalidated after each finished download.
- **Progress contract (multi-connection safe)**: `downloaded` is a cumulative byte counter incremented per chunk written and clamped to `total` (`min(downloaded + n, total)`) — it is monotonic, never overshoots, and is independent of how many connections run, so it stays correct for any split count (including external engines like aria2c with `-x 1/2/4/...`). `total` comes from the probe's `Content-Range` (falling back to the catalog size). The UI derives percentage purely from these two numbers.
- Mirror URLs follow `https://huggingface.co/<repo>/resolve/main/<path>`; the base can be overridden with `LAZYCOMFY_HUB_BASE`. When neither ComfyUI's `folder_paths` nor a `LAZYCOMFY_MODELS_DIR` env var is available, `models_dir_unavailable` is returned.

## WebSocket protocol (native ComfyUI)

- URL: `ws(s)://<host>/ws?clientId=<uuid>` — reuse the same client id you send as `client_id` in generate.
- On connect, the **client** sends first: `{"type": "feature_flags", "data": {"supports_preview_metadata": true}}`; the server replies with its feature flags. Without this handshake, no live previews are pushed.
- The first `status` message carries `data.sid` — the authoritative client id.
- Completion is signaled by `execution_success` / `execution_error` / `execution_interrupted` **matching the prompt_id** of the job. Current servers no longer send a `{"type": "executing", "data": {"node": null}}` completion marker — do not wait for one.

Message table (server → client):

| type | data fields | notes |
| --- | --- | --- |
| `status` | `status.exec_info.queue_remaining`, `sid` (first only) | broadcast on queue changes |
| `feature_flags` | server capability dict | reply to the client handshake |
| `execution_start` | `prompt_id`, `timestamp` | job started |
| `executing` | `prompt_id`, `node`, `display_node`, `timestamp` | per-node start; executing client only |
| `executed` | `prompt_id`, `node`, `display_node`, `output`, `timestamp` | per-node UI output, incl. `images` from SaveImage |
| `progress` | `prompt_id`, `value`, `max` | sampler progress (throttled server-side) |
| `progress_state` | `prompt_id`, `nodes` map (`node_id → { value, max, state, ... }`) | newer combined per-node state |
| `execution_success` | `prompt_id`, `timestamp` | job finished OK |
| `execution_error` | `prompt_id`, `node_id`, `node_type`, `exception_type`, `exception_message`, `traceback`, `executed` | job failed |
| `execution_interrupted` | `prompt_id`, `executed`, `timestamp` | job cancelled; broadcast to all clients |

Client rules:

- Filter everything except `status` by the current job's `prompt_id`.
- Keepalive: send `{"type": "ping"}` every ~25 s (also hides cloudflared's ~100 s idle drop).
- The `client_id` in `POST /prompt` must equal the WebSocket `clientId` to receive per-client execution events — the server tracks one executing client at a time. Broadcast messages (`status`, `execution_interrupted`) reach all sockets.

## Native ComfyUI endpoints used

| Endpoint | Notes |
| --- | --- |
| `POST /prompt` | Body `{ "prompt": {...}, "client_id": "...", "extra_data": {...} }` → `{ "prompt_id", "number", "node_errors" }`; 400 → `{ "error", "node_errors" }` |
| `GET /history/{prompt_id}` | Entry: `{ prompt: [number, prompt_id, prompt, extra_data, outputs], outputs: { <node>: { images: [{filename, subfolder, type}] } }, status: { status_str: "success"\|"error", messages: [...] } }` |
| `GET /view?filename=...&subfolder=...&type=...` | File bytes for display/download; supports `preview=webp;90` re-encoding |
| `POST /upload/image` | multipart (`image`, `overwrite`, `type`, `subfolder`) → `{ name, subfolder, type }` |
| `POST /interrupt` | optional `{ "prompt_id" }` body for a targeted interrupt |
| `GET /queue` | `{ queue_running: [...], queue_pending: [...] }` |
| `GET /prompt` | `{ exec_info: { queue_remaining: n } }` |
| `GET /system_stats` | versions + devices (used by `/lazycomfy/api/config`) |

Details that matter:

- `LoadImage` input value format: `[subfolder/]filename` plus a ` [type]` suffix only when `type != "input"` (e.g. `lazycomfy/x.png [output]`).
- The backend talks to ComfyUI over loopback HTTP (`http://127.0.0.1:<port>`) with an `aiohttp.ClientSession`. The port is detected from `PromptServer` (fallbacks: `LAZYCOMFY_PORT` env var, then 8188).
- Every native route also exists under the `/api/...` prefix (e.g. `/api/prompt`).

## History metadata

Every job LazyComfy submits tags `extra_data.lazycomfy`:

```json
{
  "extra_data": {
    "lazycomfy": {
      "model_id": "z_image_turbo",
      "template_id": "z_image_turbo_t2i",
      "mode": "t2i",
      "prompt": "...",
      "negative_prompt": null,
      "params": { "width": 1024, "height": 1024, "steps": 8, "seed": 42 },
      "adjusted": false
    }
  }
}
```

`/lazycomfy/api/history` reads native `/history` and filters entries by this tag, so the gallery only shows LazyComfy jobs and can restore settings ("reuse settings" / "send to img2img").

## Error envelope

All `/lazycomfy/api/*` failures return:

```json
{ "error": { "type": "...", "message": "...", "details": ... } }
```

| HTTP | type | meaning |
| --- | --- | --- |
| 400 | `invalid_request` | malformed body, unknown model/mode, out-of-range numeric param, invalid image path |
| 400 | `invalid_prompt` | prompt not a string / empty prompt in t2i |
| 400 | `invalid_file_type` | upload is not PNG/JPEG/WebP |
| 400 | `file_too_large` | upload exceeds `max_upload_mb` |
| 400 | `upload_error` | ComfyUI rejected the upload |
| 400 | `unknown_item` | download requested for an item id not in the catalog |
| 400 | `unknown_task` | download status/cancel for a task id that does not exist |
| 400 | `already_downloaded` | the file is already on disk |
| 400 | `already_downloading` | a task for the same item is already running |
| 400 | `models_dir_unavailable` | cannot resolve a models folder (no ComfyUI, no `LAZYCOMFY_MODELS_DIR`) |
| 400 | `download_failed` | HTTP error or 404 on every candidate path while fetching |
| 502 | `missing_model_files` | the workflow references model files not on disk |
| 502 | `comfyui_error` | ComfyUI rejected the prompt (details carry `node_errors`) |
| 502 | `comfyui_unreachable` | backend could not reach ComfyUI's own API |
| 500 | `internal_error` | unexpected backend failure |
