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
- Flux 3 Klein's BFL repo is gated — accept the license on Hugging Face first, then set a token (HF_TOKEN env / Colab secret / Model downloads window).

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

**Cause:** wrong CLIPLoader type, missing files, or a denoise < 1.0 reaching the text-to-image KSampler.

**Fix:**
- CLIPLoader type must be `lumina2` — anything else produces broken conditioning.
- Verify all three files are present (UNET, `qwen_3_4b.safetensors`, `ae.safetensors`) and use the template defaults: 8 steps, cfg 1.0, res_multistep / simple, shift 3.
- Text-to-image must run at **denoise 1.0**. A denoise < 1.0 (the img2img "strength" default of 50%) samples only part of the schedule and produces noisy output that is also faster than normal — LazyComfy now forces denoise 1.0 on t2i automatically (fixed in 0.1.0; update the package on the server and restart ComfyUI).

## Flux 3 Klein: artifacts

**Cause:** too many steps on the distilled variant, or the wrong VAE.

**Fix:**
- Keep the distilled template at 16 steps, cfg 1.0 (official T2I uses 15 steps er_sde); it overcooks far above that.
- Use the Flux2 VAE (`flux2-vae.safetensors`) — do NOT use FLUX.1's `ae.safetensors`.
- Loader type must be `flux3` (single CLIPLoader), not `flux2` and not `DualCLIPLoader`.

## MOSS Image: full-frame static / noise

**Cause:** the sampler, text encoder, or VAE produced non-finite values, so the decode is random pixels. Sampling settings (steps/cfg/prompt) cannot cause this.

**Fix / first aid (verified report: T4 GPU):**
- OpenMOSS's own pipeline runs the VAE in fp32 (`torch_dtype={"default": "bfloat16", "vae": "float32"}`), and T4 has no bf16. Restart ComfyUI with `--fp32-vae` and regenerate the same seed.
- If still static, restart with `--fp32-text-enc` (the Qwen 3.5 encoder runs fp16 on T4 by default), then as the last resort `--force-fp32` to test the whole chain.
- The int8_convrot quant path is tuned for Ampere and newer GPUs; on a T4 use the BF16 unet file (Files menu, fp32 compute there) to rule the quant path out.
- The Comfy-Org repo re-uploaded the int8 checkpoints (files were renamed from `*_int8_convrot_attn.safetensors` to `*_int8_convrot.safetensors`) — re-download if the file was fetched during the first hours.
- Use the official SFT/T2I and edit settings: 25 steps / CFG 2.5 / er_sde / simple for T2I, 30 steps / CFG 4.0 / euler / normal for edits. The W4A8 file is the text encoder; there is no MOSS prompt enhancer to toggle.

## MOSS Image edit: output ignores the instruction

**Cause:** the edit LoRA is missing, the wrong `edit_format` is selected, or the run used T2I settings.

**Fix:**
- Download `moss_image_edit_lora_rank_64_bf16.safetensors`; edit refuses to start without it.
- Both `TextEncodeMOSSImageEdit` nodes must use `Moss-Image-Edit` with this LoRA (the graph does this).
- Keep 30 steps, CFG 4.0, euler/normal. Lower CFG makes the model invent details (necklaces, earrings) during edits.
- Describe only the change and keep the reference at 1 MP; a much smaller reference loosens identity and framing.

## FIBO Image 2.0: weak prompt adherence or smeared edits

**Cause:** off-recipe sampling, oversized output, or a negative prompt that fights the edit.

**Fix:**
- Use the card defaults: Dev 30 steps at CFG 5.0 for T2I, 50 steps for edits; Edit Turbo 4 steps at CFG 1.0.
- Output follows the first reference at about 1 MP. Larger canvases lose layout and prompt adherence.
- Leave the negative empty on Dev edits to keep Bria's structured VGL negative; typing a negative replaces it.
- Loader type must be `fibo2`; use `flux2-vae.safetensors` and `qwen3vl_4b_int8_convrot.safetensors`.
- Edit Turbo is a separate checkpoint. Do not try to use it as a LoRA on Dev.

## Cancelling a run crashes the server

**Cause:** an interrupt mid-run can hit an already-queued CUDA kernel with an illegal memory access (sticky for the context). The error then surfaces during interrupt cleanup (`torch.cuda.synchronize()`), and while unwinding, the next tensor free goes through PyTorch's default cudaMallocAsync allocator, which aborts the process natively (`terminate called after throwing an instance of 'c10::AcceleratorError'` in `CUDAMallocAsyncAllocator.cpp`). The server — and any tunnel — die with it. Observed on a Colab T4, most reliably while the model compiler is still initializing (`Model Initializing...`).

**Fix:**
- Launch with `--disable-cuda-malloc` — cudaMallocAsync is the torch 2.x default; disabling it removes the native abort path.
- If cancelling still poisons the CUDA context, launch with `--disable-comfy-compiler` too — the cancel lands in the compiled-model path, which is the likely source of the bad access on T4.
- EasyComfy cell 05 has both as form toggles (`disable_cuda_malloc`, `disable_comfy_compiler`), enabled by default.
- Avoid cancelling during the first run after server start — that init window carries the highest risk.

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
