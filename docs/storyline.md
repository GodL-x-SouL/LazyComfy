# Storyline

Storyline turns one story overview plus one or more character sheets into a numbered storyboard of detailed Qwen Image 2.1 prompts. It runs entirely on a local vision LLM through llama.cpp, then hands the prompts back to you — it never submits an image job itself.

Open it at:

```text
http://127.0.0.1:8188/lazycomfy/storyline
```

Use the storyboard icon in the main LazyComfy top bar, or go straight to the URL from the Next app.

---

## 1. What the two passes do

| Pass | Model input | Output |
| --- | --- | --- |
| 1. Story bible | Every character sheet (vision) + overview + style + intensity | Identity anchors, wardrobe, world, palette, continuity rules, and exactly N compact scene beats |
| 2. Scene prompts | Text only: the bible, one scene, the previous prompt, the next beat | One 190–320 word Qwen Image 2.1 prompt per scene (70–150 words in edit mode) |

The character sheets are encoded once during pass 1. Pass 2 is text-only, so a 12-scene run does not re-read six images for every frame. If a scene prompt is thin, missing a reference tag, or written as a tag list, the engine asks the model for one rewrite before accepting it.

The bible is deliberately a **compact beat sheet**, not prose: a 12-scene run writes roughly 2.5k tokens in pass 1 instead of 4.7k, then pass 2 expands each beat into the full 190–320 word prompt. Live token count and speed stream into the progress text during both passes, so a slow Bible pass is visible instead of looking hung.

Every scene carries forward:

- who is present (from the bible's `wardrobe` / `emotion` maps)
- exact wardrobe state (dry, wet, torn, removed, changed)
- props, time of day, weather
- emotional carry-over and physical tells
- the previous scene's composition, so the next shot does not repeat it

---

## 2. Install the vision model

The recommended engine is **Qwen3-VL-8B Instruct, abliterated** — small enough to run locally, strong at reading character sheets, and uncensored enough for adult storytelling.

| Item | Value |
| --- | --- |
| Base model | `huihui-ai/Huihui-Qwen3-VL-8B-Instruct-abliterated` |
| GGUF repo | `noctrex/Huihui-Qwen3-VL-8B-Instruct-abliterated-GGUF` |
| Quantized weights | `Huihui-Qwen3-VL-8B-Instruct-abliterated-Q4_K_M.gguf` |
| Vision projector | `mmproj-F16.gguf` |
| Backend | llama.cpp `b11429` or newer, with mtmd / Qwen3-VL support |

Approximate download: **~5 GB** for Q4_K_M and **~1.3 GB** for the projector. Keep at least 12 GB of free VRAM, or enough system RAM to run on CPU (slow but workable).

### Download through Prompt Forge

1. On the Storyline page, click **Get a vision model →**. It opens Prompt Forge with the search prefilled.
2. Or open `http://127.0.0.1:8188/lazycomfy/forge?q=Huihui-Qwen3-VL-8B-Instruct-abliterated`.
3. Open the `noctrex/...-GGUF` repo.
4. Download both files into `ComfyUI/models/llm_gguf/`.
5. If the llama.cpp backend is not installed yet, use **Install backend** in the Forge model panel. Do not use a build older than `b11429`; older builds do not understand the Qwen3-VL projector.

### Select the engine

On Storyline:

1. Pick the Q4_K_M model.
2. Pick **`mmproj-F16.gguf`** in the projector list. Auto-detect often misses this file because its name does not contain a model keyword.
3. Leave context at **16384**. Raise it to 24576–32768 for 18–24 scenes; lower it only if memory is tight.
4. Click **Load model**, or just generate — a cold load starts automatically and streams progress.

The engine sizes the story-bible reply to the context left after the sheets are encoded, so it will not ask for more tokens than the window can hold. If the cast is too large for the selected context, it stops with a clear message asking you to raise it.

If the page says `vision_unavailable`, the projector is missing or was not loaded. Set it explicitly and generate again.

---

## 3. Reference-tag workflow

Storyline writes textual tags, not image files. The tags map to the reference slots in your existing Qwen Image 2.1 workflow.

### Scene mode (new frames)

Use this for a fresh storyboard where each scene is a new image generated with the character sheets as references.

1. Give each character a name and a tag. Defaults are `<image1>`, `<image2>`, …
2. Attach one clear sheet per character. Face and full body are ideal; one character per sheet is best.
3. In the Qwen Image 2.1 workflow, attach the same sheets to the reference inputs in the same order:
   - `<image1>` must be the first reference image
   - `<image2>` the second, and so on
4. Paste each scene prompt into the positive prompt. Keep the reference images attached.
5. If your workflow has a prompt-enhancer subgraph, bypass it for these prompts. The storyboard prompts are already written for Qwen 2.1; a second writer usually dilutes them.

Up to **10** reference slots are supported by Qwen Image 2.1. Storyline caps the cast at **6** to keep the vision pass and the prompts readable.

### Edit mode (carry the previous frame forward)

Use this when you want a continuous run: image 1 is the frame you just generated, and each next prompt edits it.

1. Set **Prompt mode** to **Edit previous**.
2. Attach the previous frame as `<image1>` in the Qwen workflow.
3. Character sheets must move to `<image2>` and up. Storyline shows a warning and a **Shift tags** button.
4. Generate the storyboard. Every prompt starts with `Using <image1> as the base frame, …` and ends with an explicit preserve clause.
5. Generate scene 1 with the sheets, then feed the result back as `<image1>` for scene 2, and so on.

The **Shift tags** button rewrites the cast tags, the bible's character refs, and every existing scene prompt in one pass. Re-check the first prompt after shifting if you have manually edited any tags.

### Tag rules

- Tags are case-sensitive in the prompt text: use `<image1>`, not `<Image1>`.
- Do not reuse a tag. One character per tag.
- In edit mode, `<image1>` is reserved for the base frame. Never map a character to it.
- In scene mode, tags are just references. `<image1>` can be a character.
- The `image_1` node in the Qwen workflow is the edit target/canvas. The textual `<image1>` tag refers to the first reference image, not the canvas node. Keep the workflow's reference order aligned with the tags.

---

## 4. Writing the brief

The overview is the only story input. Write 2–6 sentences with a clear arc, not a list of images.

Good:

> Two strangers share a night train across Europe. Quiet tension becomes a confession, then a choice at dawn. He is leaving the country; she has not decided whether to follow.

Weak:

> a girl, a train, rain, cinematic, 8k, many scenes

Useful details:

- **Relationship and stakes** — why these people, why now.
- **Turning point** — the moment the story changes.
- **Ending** — the final image should land, not open a new thread.
- **Visual anchors** — city, season, weather, time period, recurring prop.
- **Wardrobe changes** — if a coat comes off, say when and why; the bible will track it.

Choose **Scenes** from 10 to 24. Twelve is a good default for a short story. More scenes means more continuity state and a longer run.

### Cast sheets

- Each cast card has two ways to attach a sheet: the thumbnail/upload button, or the themed picker underneath it. The picker lists images already in ComfyUI's input folder, including one subfolder deep (`input/lazycomfy` is included), with paths shown as `subfolder/name.png`. Use the small **↻** next to **+ Add character** to refresh that list.
- Selecting a picker entry loads a compressed copy into the card, exactly like an upload. The chosen path is remembered in the saved session; if the original file is later deleted, reattach it.
- One character per sheet.
- Prefer a clean front or three-quarter view, face visible, full body if the outfit matters.
- Screenshots of a character-select screen work; busy collages are harder for the 8B model.
- Use the optional **Identity notes** field for details the sheet hides: height, accent, a scar, a specific accessory.
- The model is told every character is an adult (18+). Do not attach minor characters.

### Intensity

| Level | What the writer may describe |
| --- | --- |
| None | Warm, fully clothed, non-sexual |
| Suggestive | Gaze, proximity, tension; still fully clothed |
| Sensual | Tasteful adult sensuality: bare shoulders/back, partial undress, intimate touch, cinematic and non-graphic |
| Explicit | Explicit nudity and sexual intimacy between consenting adults, direct but cinematic language |

The adult acknowledgment is mandatory in both the page and the backend. Every character must be an adult, and intimacy must be consensual. The prompts explicitly forbid minors, coercion, and sexual violence.

Even with an abliterated VLM, Qwen Image 2.1 may apply its own content filtering or produce a softer frame than the prompt asks for. That is a model/workflow limit, not a Storyline setting.

---

## 5. Reading the storyboard

Each scene card shows:

- scene number and title
- the visible beat from the bible
- the generated prompt in an editable textarea
- a word count
- **Copy** and **↻** (rewrite this prompt)

The story bible panel at the top lists the cast tags, world, look, continuity rules, and all beats. Open it to check that the model read the sheets correctly before you use the prompts.

Board actions:

- **Copy all** — every prompt, headed by `SCENE 01 — title`
- **.txt** — the same text as a download
- **.json** — the full bible, scenes, settings, and export timestamp

Edits are saved automatically. The page stores its state under the `storyline` key in `backend/.session.json`, including the bible and prompts. Character sheet images are stored only when the total is under ~4 MB; larger casts are reattached after a browser reload. Sheets are compressed to a 1400 px JPEG before upload.

---

## 6. Prompt contract

Storyline follows Qwen Image 2.1's natural-language behavior:

- one flowing paragraph
- concrete, observable detail
- no SD tag lists, weights, or negative prompts
- no text/captions/watermarks unless the beat needs readable text

Scene prompts are **190–320 words** and cover, in order:

1. frame — shot size, angle, lens, layers
2. people — identity anchors, exact wardrobe, pose, hands, gaze, facial expression
3. action — the frozen instant and physical interaction
4. place — environment, props, textures, weather, time
5. light — direction, quality, practicals, colour temperature, contrast
6. colour and mood — palette, medium, depth of field
7. continuity — what must survive from the bible

Edit prompts are **70–150 words**:

1. `Using <image1> as the base frame, …`
2. only what changes
3. re-identify an entering character with their sheet tag
4. an explicit `Preserve …` clause for face, identity, body, wardrobe, props, and light

The scene pass includes the previous scene's beat and prompt, plus the next beat. That is what keeps the camera moving and stops the model from writing the same medium shot twelve times.

---

## 7. API (advanced)

Both endpoints stream server-sent events and require `adult_ack: true`.

### `POST /lazycomfy/api/llm/storyline`

```json
{
  "model": "Huihui-Qwen3-VL-8B-Instruct-abliterated-Q4_K_M.gguf",
  "mmproj": "mmproj-F16.gguf",
  "context_length": 16384,
  "temperature": 0.75,
  "top_p": 0.9,
  "adult_ack": true,
  "characters": [
    {
      "name": "Mira",
      "ref": "<image1>",
      "notes": "black hair, charcoal coat",
      "image": "data:image/jpeg;base64,..."
    }
  ],
  "overview": "A woman waits in a rented room as the rain falls.",
  "scene_count": 12,
  "aspect": "16:9",
  "style": "cinematic photoreal film still, 35mm",
  "style_notes": "warm tungsten, wet glass",
  "prompt_style": "scene",
  "intensity": "suggestive",
  "source_ref": "<image1>"
}
```

Events:

```text
status   {stage: load|bible|scene, message, index?, total?}
bible    {data: {...}, requested: 12}
tick     {index, tokens, tps, elapsed}
scene    {index, total, scene: {n, title, beat, prompt, words, ...}}
warning  {message}
done     {bible, scenes}
error    {message}
```

### `POST /lazycomfy/api/llm/storyline/scene`

Regenerates one prompt. Send the same engine fields plus:

```json
{
  "adult_ack": true,
  "bible": { "...": "the bible object" },
  "scene": { "n": 3, "title": "...", "beat": "...", "wardrobe": {}, "emotion": {} },
  "characters": [{ "name": "Mira", "ref": "<image2>" }],
  "previous_scene": { "beat": "...", "prompt": "..." },
  "next_scene_beat": "...",
  "prompt_style": "edit",
  "intensity": "sensual",
  "style": "cinematic photoreal film still",
  "aspect": "16:9",
  "source_ref": "<image1>"
}
```

The current `characters` refs override stale refs in the bible, so you can remap tags without rebuilding the whole storyboard. Events are `status`, `chunk`, `reset`, `done`, and `error`. `reset` is sent when the first rewrite fails the prompt-quality checks and a second pass replaces it.

---

## 8. Limitations and troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `vision_unavailable` | No projector loaded. Select `mmproj-F16.gguf` explicitly, not Auto-Detect. |
| `llm_backend_missing` | Install the llama.cpp backend from Prompt Forge; need b11429+. |
| `generation_busy` | A Forge or Storyline generation is still running. Wait or unload the model. |
| Slow first scene | Cold load reads the GGUF and initializes the GPU. Later scenes are much faster. |
| `The model did not return a usable story bible` | Shorten the overview, reduce scenes, or lower temperature. The engine already tried one JSON repair. |
| Fewer scenes than requested | The engine asks for a correction once, then warns. Regenerate individual scenes or lower the target. |
| Scenes repeat compositions | Regenerate the offending scene; the previous prompt is included to discourage repeats. |
| Character drifts across frames | Attach a clearer sheet, add identity notes, or keep the same reference order. The image workflow's own reference strength still matters. |
| Prompts feel generic | Lower intensity is not the cause; add specific visual anchors to the overview and use a custom look. Regenerate thin scenes. |
| Adult content comes back softened | Qwen Image 2.1's own filtering. Storyline cannot override the image model. |
| Character sheets missing after reload | The saved state exceeded the image budget. Reattach the sheets. |
| JSON parse errors in console | Check the server log; a malformed model reply is retried once, then reported as a clean error. |

Known limits:

- **Runtime inference was not tested on the development machine** used to build this page (no GPU and ~9.7 GB RAM). The backend orchestration was tested with a scripted fake llama manager, and all Python/JavaScript was syntax-checked. Run one real 10-scene story on your GPU before relying on it for a batch.
- An 8B VLM can misread dense collages, stylized sheets, or hidden details. One character per sheet is strongly recommended.
- Continuity is best-effort. Wardrobe state, injuries, and props are carried in the bible, but the image model may still drift. Review each frame.
- The story bible pass needs vision. A text-only GGUF can write prose but cannot analyze the sheets; Storyline will refuse to continue without `mmproj`.
- Up to 6 characters and 10–24 scenes. The backend accepts 10–30 scenes, but the UI stops at 24 to keep the bible pass inside a reasonable context.
- Prompts are drafts. You own the final selection, edits, and use.

---

## 9. Quick checklist

- [ ] llama.cpp backend installed (b11429+) and visible in Forge.
- [ ] Q4_K_M + `mmproj-F16.gguf` in `ComfyUI/models/llm_gguf/`.
- [ ] Storyline model selected, projector set explicitly, context 16384.
- [ ] 1–6 character sheets attached; names and tags match the Qwen workflow.
- [ ] Overview has an arc and an ending.
- [ ] Scenes 10–24; intensity chosen; adult box checked.
- [ ] Story bible reviewed for identity mistakes.
- [ ] Scene prompts pasted into Qwen Image 2.1 with the same reference order.
- [ ] Prompt enhancer bypassed in the image workflow.
- [ ] Each frame reviewed; regenerate any weak scene.
