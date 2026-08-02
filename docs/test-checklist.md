# Test checklist

Manual acceptance checklist. Run through in order on both localhost and a tunneled URL. Expected results are stated after each item.

## 0) Environment

- [ ] ComfyUI is the latest stable (>= 0.3.2x); console shows the core nodes `Flux2Scheduler`, `CFGGuider`, `Ideogram4Scheduler`, `DualModelGuider`, `EmptyFlux2LatentImage`, `EmptySD3LatentImage`, `ModelSamplingAuraFlow` at startup.
- [ ] All four models' files are present in `models/diffusion_models/`, `models/text_encoders/`, `models/vae/` (see `model-notes.md`).
- [ ] LazyComfy console log line appears at ComfyUI startup (package loaded).

## 1) Route & load

- [ ] `http://127.0.0.1:8188/lazycomfy` opens the LazyComfy UI.
- [ ] The page loads without the main ComfyUI canvas/UI being loaded first (no dependency).
- [ ] Initial transfer is well under 100 KB (DevTools network tab, first load, no cache).
- [ ] The page renders and is interactive on localhost.
- [ ] Refreshing the page restores the previous model/mode selections.

## 2) Model selection

- [ ] Exactly 4 model cards render: Z Image Turbo, Krea 2 Turbo, Flux 2 Klein 9B, Ideogram 4.
- [ ] Selecting a model switches the controls to that model's preset (steps/cfg/resolution defaults).
- [ ] Selecting a model whose files are missing shows a clear "missing files" warning listing the missing paths.
- [ ] Switching models does not require a page reload.

## 3) Text-to-image, each model

- [ ] Z Image Turbo: prompt → Generate → progress bar fills → result renders in the gallery (1024x1024).
- [ ] Krea 2 Turbo: prompt → Generate → progress bar fills → result renders.
- [ ] Flux 2 Klein 9B: prompt → Generate → 4-step run completes → result renders.
- [ ] Ideogram 4: prompt → Generate (Default preset) → result renders.
- [ ] Ideogram 4: Turbo and Quality presets produce runs with 12 and 48 steps respectively.
- [ ] Seed is applied: same seed + same prompt + same settings → identical output.
- [ ] Ctrl+Enter in the prompt textarea triggers generation.
- [ ] A negative prompt typed for Z Image Turbo / Krea 2 Turbo / Flux 2 Klein has no effect on output (ignored by design).

## 4) Image-to-image, each model

- [ ] Upload button works: choosing an image shows a preview thumbnail.
- [ ] Drag-and-drop a file onto the page: preview appears.
- [ ] Z Image Turbo i2i: result appears; denoise 0.2 keeps structure, denoise 0.7 moves toward the prompt.
- [ ] Krea 2 Turbo i2i: result appears; denoise slider visibly changes output.
- [ ] Flux 2 Klein 9B i2i: result appears; denoise controls strength.
- [ ] Ideogram 4 i2i: result appears (marked experimental; expected to differ from t2i quality).
- [ ] Batch control is hidden in i2i mode (i2i always processes one image); in t2i, batch 2 produces two images.
- [ ] Uploading an oversized or non-image file shows a clean error, not a crash.

## 5) Queue & cancel

- [ ] Submitting a second job while one runs queues it (queue count shown, second job executes after the first finishes).
- [ ] Cancel/interrupt during a run stops it; UI returns to idle; no result is shown for the interrupted job.
- [ ] After an interrupt, the page can immediately generate again (WebSocket still healthy).

## 6) Gallery & actions

- [ ] Completed jobs appear in the recent outputs gallery with the settings used.
- [ ] Open: `view` URL opens the output image in a new tab.
- [ ] Download: downloads the output file.
- [ ] Reuse: clicking reuse restores prompt/settings for that job.
- [ ] Send to img2img: loads the output image as the i2i input and switches to image-to-image mode.
- [ ] Copy prompt: copies the prompt text to the clipboard.
- [ ] Gallery persists across a page refresh (loaded from `/lazycomfy/api/history`).
- [ ] Outputs exist on disk under `output/lazycomfy/<slug>/`.

## 7) Errors

- [ ] Empty prompt → clear validation error, no submission.
- [ ] Out-of-range params (e.g. width below a model's minimum) → validation error listing the field.
- [ ] Generating with missing model files → `missing_model_files` error naming the file.
- [ ] Stopping/killing the ComfyUI backend and clicking Generate → "unreachable" error; page stays usable.
- [ ] A workflow that fails inside ComfyUI shows the node's `exception_message` (not a raw stack trace).

## 8) Tunnels

- [ ] `cloudflared tunnel --url http://127.0.0.1:8188` — page loads over HTTPS; generation and progress work end to end.
- [ ] If WebSocket fails (400/1006) under cloudflared, adding `--protocol http2` fixes it.
- [ ] Pinggy (`ssh -p 443 -R0:localhost:8188 a.pinggy.io`) — page loads; generation works.
- [ ] No 403 errors from rewritten Host headers (tunnel keeps its public hostname; nothing rewrites Host to localhost).
- [ ] Dropping the tunnel mid-generation: page shows a connection error and reconnects (WebSocket auto-retry) when the tunnel returns.

## 9) Mobile

- [ ] On a narrow viewport the layout stacks (controls above, results below) without horizontal overflow.
- [ ] Gallery images render in a responsive grid.
- [ ] Tap targets (generate, upload, gallery actions) are large enough to hit reliably.
- [ ] Generate + progress work on a mobile browser over the tunnel.

## 10) Performance

- [ ] DevTools shows a small number of requests on load (single HTML file, no external CDNs or font downloads).
- [ ] No long-poll or repeated polling loops when idle (progress is WebSocket-driven).
- [ ] Page is usable on a throttled connection (e.g. DevTools "Slow 4G").

## 11) Downloads & variants

- [ ] The download button (top bar) opens a **fixed window**: the page behind is locked (no scrolling), the catalog scrolls inside the panel only, and the header/footer stay put.
- [ ] Catalog is grouped by family with sizes and installed counts.
- [ ] No progress bar is visible anywhere until a download is triggered; the bar appears in the family section only while that family has an active download.
- [ ] Starting a download shows a per-family realtime bar (percentage + speed) and a per-item "x / y · z%" counter; with several files of the same family downloading in parallel the bar aggregates them.
- [ ] Speed readout is stable (smoothed), percentage never goes backwards, and a stalled connection does not hang the bar.
- [ ] Closing the modal keeps the download running and re-locks the page scroll when reopened; progress continues.
- [ ] On completion the row flips to "Installed ✓", the family installed-count increments, and the model card's "Missing" warning disappears without a page reload.
- [ ] Cancel stops a download, removes the `.part` file, and the row becomes re-downloadable.
- [ ] The Files menu under the model card lists all on-disk files for each kind; picking a variant changes Generate to use it.
- [ ] Picking a variant that is later deleted produces an `invalid_request` (400) instead of a ComfyUI submission.
- [ ] Ideogram 4 t2i offers an "Unconditional model" selector; i2i does not.
- [ ] Error path: unreachable mirror (e.g. `LAZYCOMFY_HUB_BASE` pointing nowhere) surfaces the HTTP error in the row and a toast.
- [ ] `smoke_test.py` passes (41 checks: catalog integrity, override validation, traversal guard, build_workflow overrides, split-count logic).
