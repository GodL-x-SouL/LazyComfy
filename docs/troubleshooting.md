# Troubleshooting

## Page 404s at /lazycomfy

**Cause:** the package is not loaded — ComfyUI did not import it, or it is in the wrong place.

**Fix:**
- Check the ComfyUI console for a `lazycomfy` log line at startup.
- Verify the folder is at `ComfyUI/custom_nodes/lazycomfy/` (with `__init__.py` inside, not nested one level deeper).
- Restart ComfyUI after adding the package; route registration happens at import time.

## Missing model files errors

The UI shows `missing_model_files` with the exact path expected (e.g. `models/diffusion_models/z_image_turbo_bf16.safetensors`).

**Cause:** files not downloaded, wrong filename, or placed in the wrong directory.

**Fix:**
- Download via ComfyUI's built-in Model Manager (works for ungated `Comfy-Org/*` repos), or manually from Hugging Face.
- Use the exact filenames and directories from the tables in `docs/model-notes.md`.
- Flux 2 Klein's BFL repos are gated — accept the license on Hugging Face first; the `Comfy-Org` mirrors are not gated.

## WebSocket fails over cloudflared (HTTP 400 / close code 1006)

**Cause:** cloudflared's default HTTP/2 WebSocket handling rejects the upgrade on some setups.

**Fix:**
- Add `--protocol http2`: `cloudflared tunnel --url http://127.0.0.1:8188 --protocol http2`.
- Check tunnel logs for upgrade failures.
- Note: cloudflared drops idle connections after ~100s; the page pings every ~25s to keep it alive. If it still drops, generation over the API keeps working — only live progress is affected.

## 403 errors through tunnels

**Cause:** the tunnel rewrites the Host header to `localhost`, or the Origin no longer matches the Host. ComfyUI rejects mismatched Host/Origin on loopback-bound servers.

**Fix:**
- Do NOT rewrite the Host header through the tunnel — keep the tunnel's public hostname.
- Keep `--listen 127.0.0.1` unless the tunnel runs on a different machine (then bind appropriately).
- If a reverse proxy is in play, preserve Host and pass through Origin; a matching Origin is required for the WebSocket.

## WS connects but no progress

**Cause:** `client_id` mismatch — the page's WebSocket `clientId` does not equal the `client_id` in `POST /prompt`, so the server never sends that job's execution events (the server tracks ONE executing client).

**Fix:**
- Reconnect the page (reload). The page must generate its clientId once and reuse it for both the WebSocket and `/prompt` submissions.

## Generation errors with `exception_message`

**Cause:** a node failed during execution — usually missing/unsupported nodes (outdated ComfyUI) or out-of-VRAM loads.

**Fix:**
- Confirm the `class_type` in the error exists in this ComfyUI version; update ComfyUI to latest stable if a core node is unknown.
- VRAM: use the fp8/int8 variants of the diffusion files and text encoders listed in `docs/model-notes.md`; Z Image Turbo BF16 needs >= 16 GB VRAM.
- Unload other models before running: free VRAM via ComfyUI's `/free` endpoint (`POST /free` with `unload_models=true`, `free_memory=true`) or the main UI's free button, then retry.
- Ideogram 4 needs both diffusion files loaded; running it while other big models are resident can OOM — free first.

## Ideogram 4: "Image blocked by safety filter"

**Cause:** the model's built-in safety filter rejected the generation.

**Fix:**
- Rephrase the prompt (remove explicit violence/NCS content).
- Structured JSON captions trigger the filter less often than raw text.
- This is not a LazyComfy bug; the same prompt fails in the main ComfyUI UI.

## Z Image Turbo: gray / noisy output

**Cause:** wrong CLIPLoader type or missing files.

**Fix:**
- CLIPLoader type must be `lumina2` — anything else produces broken conditioning.
- Verify all three files are present (UNET, `qwen_3_4b.safetensors`, `ae.safetensors`) and use the template defaults: 8 steps, cfg 1.0, res_multistep / simple, shift 3.

## Flux 2 Klein: artifacts

**Cause:** too many steps on the distilled variant, or the wrong VAE.

**Fix:**
- Keep the distilled template at 4 steps, cfg 1.0; it overcooks above ~6 steps.
- Use the Flux2 VAE (`full_encoder_small_decoder.safetensors` or `flux2-vae.safetensors`) — do NOT use FLUX.1's `ae.safetensors`.
- Loader type must be `flux2` (single CLIPLoader), not `flux` and not `DualCLIPLoader`.

## Krea 2 rejects LoRAs

**Cause:** wrong LoRA family loaded.

**Fix:**
- Krea LoRAs are Krea-specific (`krea2_*` from `Comfy-Org/Krea-2/loras/`). Flux/SDXL LoRAs are incompatible; remove them.

## Page heavy or slow

**Cause:** cache, or the page is not the intended single file.

**Fix:**
- The UI is one self-contained file (`web/index.html`) — open DevTools → Network and confirm there are no extra requests (CDNs, fonts, external assets). If there are, the served file is not the repo's.
- Hard refresh (Ctrl+Shift+R) after updates.
- If the page grows heavy over time, check for added assets/bundles and remove them.

## History gallery empty

**Cause:** jobs not created through LazyComfy are not shown.

**Fix:**
- This is by design: `/lazycomfy/api/history` filters native history by the `extra_data.lazycomfy` tag. Only jobs submitted via LazyComfy (or tagged manually) appear.

## Port is not 8188

**Cause:** ComfyUI is listening on a different port (`--port`).

**Fix:**
- Set `LAZYCOMFY_PORT` to match (the backend falls back to detecting ComfyUI's configured port and to 8188).
- Open the UI at `<actual-port>/lazycomfy` and confirm the WebSocket URL uses the same host/port.
