"""Storyline prompt engine for LazyComfy.

Two passes over the shared llama.cpp server:

1. ``bible`` — the vision model reads the character sheets plus the user's
   overview and returns identity anchors, world/style notes, continuity rules
   and a numbered beat sheet.
2. ``scene`` — a text-only pass per scene turns the bible into one long,
   continuity-aware Qwen-Image-2.1 prompt. The sheets are encoded once, which
   keeps a 12-scene run fast enough for local inference.

Public entry points are async generators yielding SSE-ready event dicts;
routes.py owns the HTTP streaming.
"""
import json
import re

from . import LazyComfyError
from . import llm

_MAX_TOTAL_IMAGE_BYTES = 40 * 1024 * 1024
_MAX_CHARACTERS = 6
_MIN_SCENES = 2
_MAX_SCENES = 30

_ASPECTS = ("1:1", "4:3", "3:4", "3:2", "2:3", "16:9", "9:16", "21:9")

_INTENSITY = {
    "none": "Keep the frame non-sexual; affection stays warm, fully clothed and understated.",
    "suggestive": "You may build attraction through gaze, proximity and tension, but keep everyone fully clothed.",
    "sensual": (
        "You may depict tasteful adult sensuality — bare shoulders or back, partial undress, "
        "intimate touch, parted clothing — in cinematic, non-graphic language."
    ),
    "explicit": (
        "You may depict explicit nudity and sexual intimacy between consenting adults in direct "
        "but cinematic language, focusing on bodies, touch, light and emotion; avoid crude slang."
    ),
}

_BIBLE_SYSTEM = """You are a film director, screenwriter and continuity supervisor building a visual story bible for AI image generation.

You receive one or more character reference sheets, each labelled with its reference tag (<image1>, <image2>, ...), plus a story overview, target scene count, visual style, aspect ratio and content intensity.

TASK 1 — CAST ANALYSIS. Study every sheet and extract a reusable identity description: face shape, skin tone and texture, eyes (colour and shape), eyebrows, nose, mouth, jawline, hair (colour, cut, length, texture, parting), build and height impression, visible marks, tattoos or scars, and signature clothing and accessories. Be specific and visual. Never contradict the sheet. If a detail is hidden, choose one stable detail and keep it for the whole story. Every character is an adult (18 years or older); state the adult age range. Never include minor characters.

TASK 2 — STORY. Build a compact, coherent story that follows the overview and fits exactly __COUNT__ scenes. Scenes must connect causally and raise the emotional stakes. Vary location, time, weather, shot size and emotional temperature; never reuse the same composition twice. Give the story a clear opening, turn and resolution. The final scene must land as an ending, not a new beginning.

TASK 3 — CONTINUITY. For every scene record who is present, their exact wardrobe state, physical state, props, time of day, weather and emotional carry-over. If clothing is removed, wet, torn or changed, say so and keep it that way until the story changes it.

KEEP IT COMPACT. This is a beat sheet, not prose. Keep each scene object under 70 words: one short sentence for "beat"; short phrases for location, time, weather, camera and transition; one short phrase per character in wardrobe and emotion; 2-3 short props. Character appearance should be 2 compact sentences. Do not restate the schema or add commentary — the scene writer will expand every beat into a full prompt.

Return ONE JSON object. No markdown fences, no commentary. Start with { and end with }.
Exact shape:
{
  "title": "short evocative title",
  "logline": "one sentence",
  "world": "2-3 sentences: setting, era, atmosphere, rules of this world",
  "visual_style": "medium, lens or film stock, palette, lighting philosophy",
  "palette": "5-6 specific colours",
  "characters": [
    {
      "name": "exact name from the brief",
      "ref": "<image1>",
      "age": "adult age range, e.g. late 20s (adult)",
      "appearance": "2-4 dense sentences identifying face, hair, eyes, skin, build and marks",
      "signature_wardrobe": "default outfit: colours, fabrics, fit, accessories, footwear",
      "personality": "3-5 traits and how they show physically",
      "arc": "one sentence"
    }
  ],
  "continuity_rules": ["3-6 concrete rules that must hold across scenes"],
  "scenes": [
    {
      "n": 1,
      "title": "2-4 word scene title",
      "beat": "1-2 sentences of visible action, not dialogue or inner monologue",
      "location": "specific place with 2-3 visual details",
      "time": "time of day",
      "weather": "weather or interior atmosphere",
      "wardrobe": {"Character name": "exact outfit and its current state"},
      "props": ["2-5 key props"],
      "emotion": {"Character name": "dominant emotion + one physical tell"},
      "camera": "shot size + camera angle + lens feel",
      "transition": "how this scene follows the previous one",
      "intimacy": "none | charged | intimate"
    }
  ]
}

Rules for the JSON:
- "characters" contains exactly the cast from the brief, in order, with their given names and reference tags.
- "scenes" contains exactly __COUNT__ entries numbered 1 through __COUNT__.
- "wardrobe" and "emotion" keys exactly match character names and include only characters present in that scene.
- "beat" describes what the camera can see. No quoted dialogue.
- "camera" must vary and must not repeat the previous scene's framing.
- "intimacy" is "none" unless the intensity permits it and the story earns it. Never force it.
- CONTENT: __INTENSITY__
- VISUAL STYLE: __STYLE__
All characters are adults; intimacy is consensual. Never include minors, coercion or sexual violence.
"""

_SCENE_SYSTEM = """You are a senior visual prompt writer for Qwen-Image-2.1, a natural-language image model. You turn a story bible and ONE scene beat into the final prompt that generates that frame.

Qwen-Image-2.1 ignores tag lists and weight syntax. It responds to fluent, concrete, observational English. Write as if the photograph or film still already exists.

Output exactly ONE paragraph of 190-320 words in English. No title, no bullets, no preamble, no quotation marks, no markdown.

Build the paragraph in this order, woven into flowing prose:
1. FRAME — shot size, camera height and angle, lens character, subject placement, foreground/midground/background layers.
2. PEOPLE — for every character marked present, name them and their exact reference tag (for example: Mira, the woman in <image1>). Restate the identity anchors that matter here: face shape, eyes, hair, build, marks. Give the exact wardrobe and its current state. Describe pose, weight, hand placement, gaze, and a precise facial expression — brows, eyelids, mouth, jaw, skin — and the emotion it reveals.
3. ACTION — the exact frozen instant, physical interaction, distance between bodies, reactions.
4. PLACE — specific environment, props, textures, weather, time of day, background activity.
5. LIGHT — key direction and quality, practical sources, colour temperature, contrast, rim light, bounce, shadows.
6. COLOUR AND MOOD — palette, atmosphere, medium, depth of field.
7. CONTINUITY — preserve identity, wardrobe state, injuries, props and time of day from the bible. Do not repeat the previous scene's composition.

Hard rules:
- Use only the reference tags provided. Never invent a tag or a character.
- Only describe characters marked present: true.
- All characters are adults (18+). Intimacy only between consenting adults. Never minors, coercion or sexual violence.
- CONTENT: __INTENSITY__
- STYLE: __STYLE__
- Compose for __ASPECT__.
- No text, captions, watermarks, logos, borders or UI unless the beat explicitly needs readable text.
- Output only the prompt paragraph.
"""

_EDIT_SYSTEM = """You are a senior prompt writer for Qwen-Image-2.1 image editing. You write ONE imperative edit instruction that turns a base frame into the next story beat.

The base frame is attached as __SOURCE__. Character sheets use the tags in the JSON (<image2>, <image3>, ...). Qwen-Image-2.1 follows short, precise imperatives plus an explicit preserve clause; it ignores tag lists and weights.

Output exactly ONE paragraph of 70-150 words in English. No title, no preamble, no quotes, no markdown.

Structure:
1. Start with "Using __SOURCE__ as the base frame, ...".
2. State only what changes: action, pose, expression, wardrobe state, location or background, props, time of day, lighting, framing.
3. If a character enters or must be re-identified, name them, give their sheet tag, and restate the identity anchors that must survive.
4. End with a preserve clause naming face, identity, body, and every continuity element that must not change.

Hard rules:
- Use only the tags provided. Never invent one.
- Keep the same people, faces and bodies across the edit.
- All characters are adults (18+); intimacy only between consenting adults; never minors, coercion or sexual violence.
- CONTENT: __INTENSITY__
- STYLE: __STYLE__
- Compose for __ASPECT__.
- Output only the instruction.
"""

_REF_RE = re.compile(r"^<image\d+>$")


def _clip(value, limit):
    return str(value or "").strip()[:limit]


def _engine(body):
    model = _clip(body.get("model"), 400)
    if not model:
        raise LazyComfyError("invalid_request", "Select a GGUF model first")
    try:
        ctx = int(body.get("context_length", 16384))
    except (TypeError, ValueError):
        ctx = 16384
    try:
        temperature = float(body.get("temperature", 0.75))
    except (TypeError, ValueError):
        temperature = 0.75
    try:
        top_p = float(body.get("top_p", 0.9))
    except (TypeError, ValueError):
        top_p = 0.9
    return {
        "model": model,
        "mmproj": _clip(body.get("mmproj"), 400) or "None",
        "context_length": max(8192, min(ctx, 65536)),
        "temperature": max(0.0, min(temperature, 2.0)),
        "top_p": max(0.0, min(top_p, 1.0)),
    }


def _cast(body):
    raw = body.get("characters")
    if not isinstance(raw, list) or not raw:
        raise LazyComfyError("invalid_request", "Add at least one character sheet")
    if len(raw) > _MAX_CHARACTERS:
        raise LazyComfyError("invalid_request", f"At most {_MAX_CHARACTERS} characters are supported")
    cast, names, refs, total = [], set(), set(), 0
    for i, item in enumerate(raw):
        if not isinstance(item, dict):
            continue
        name = _clip(item.get("name"), 60) or f"Character {i + 1}"
        key = name.casefold()
        if key in names:
            raise LazyComfyError("invalid_request", f"Duplicate character name '{name}'")
        names.add(key)
        image = item.get("image")
        if not isinstance(image, str) or not image.startswith("data:image/"):
            raise LazyComfyError("invalid_request", f"Character '{name}' needs a reference image")
        total += len(image)
        ref = _clip(item.get("ref"), 20) or f"<image{i + 1}>"
        if not _REF_RE.match(ref):
            raise LazyComfyError("invalid_request", f"Character '{name}' has an invalid reference tag '{ref}' (use <imageN>)")
        if ref in refs:
            raise LazyComfyError("invalid_request", f"Reference tag {ref} is used twice")
        refs.add(ref)
        cast.append({"name": name, "notes": _clip(item.get("notes"), 400), "image": image, "ref": ref})
    if not cast:
        raise LazyComfyError("invalid_request", "Add at least one character sheet")
    if total > _MAX_TOTAL_IMAGE_BYTES:
        raise LazyComfyError("invalid_request", "Character sheets are too large in total (max 40 MB)")
    return cast


def _settings(body, cast):
    if body.get("adult_ack") is not True:
        raise LazyComfyError(
            "invalid_request",
            "Confirm every character is an adult (18+) and that intimacy is consensual",
        )
    overview = _clip(body.get("overview"), 4000)
    if len(overview) < 10:
        raise LazyComfyError("invalid_request", "Write a story overview first")
    try:
        scene_count = int(body.get("scene_count", 12))
    except (TypeError, ValueError):
        scene_count = 12
    scene_count = max(_MIN_SCENES, min(scene_count, _MAX_SCENES))
    style = _clip(body.get("style"), 300) or "cinematic photoreal film still"
    style_notes = _clip(body.get("style_notes"), 800)
    if style_notes:
        style = f"{style}; {style_notes}"
    prompt_style = _clip(body.get("prompt_style"), 20) or "scene"
    if prompt_style not in ("scene", "edit"):
        prompt_style = "scene"
    intensity = _clip(body.get("intensity"), 20) or "suggestive"
    if intensity not in _INTENSITY:
        intensity = "suggestive"
    aspect = _clip(body.get("aspect"), 10) or "16:9"
    if aspect not in _ASPECTS:
        aspect = "16:9"
    source_ref = _clip(body.get("source_ref"), 20) or "<image1>"
    if not _REF_RE.match(source_ref):
        raise LazyComfyError("invalid_request", "The edit source tag must look like <image1>")
    if prompt_style == "edit":
        clash = [c["name"] for c in cast if c["ref"] == source_ref]
        if clash:
            raise LazyComfyError(
                "invalid_request",
                f"In edit mode {source_ref} is the previous frame, but "
                f"{', '.join(clash)} uses it for a character sheet. Move the sheets to <image2> and up.",
            )
    return {
        "overview": overview,
        "scene_count": scene_count,
        "style": style,
        "prompt_style": prompt_style,
        "intensity": intensity,
        "aspect": aspect,
        "source_ref": source_ref,
    }


def _bible_messages(cfg, cast):
    system = (
        _BIBLE_SYSTEM
        .replace("__COUNT__", str(cfg["scene_count"]))
        .replace("__INTENSITY__", _INTENSITY[cfg["intensity"]])
        .replace("__STYLE__", cfg["style"])
    )
    intro = (
        "STORY OVERVIEW:\n" + cfg["overview"] + "\n\n"
        f"TARGET: exactly {cfg['scene_count']} scenes.\n"
        f"ASPECT RATIO: {cfg['aspect']}.\n"
        f"PROMPT MODE: {'edit instructions from a previous frame' if cfg['prompt_style'] == 'edit' else 'new cinematic frames with character references'}.\n\n"
        "CHARACTERS — study each attached sheet. Use these exact names and tags:\n"
    )
    content = [{"type": "text", "text": intro}]
    for i, ch in enumerate(cast):
        label = f"Character {i + 1} — name: {ch['name']} — reference tag: {ch['ref']}"
        if ch["notes"]:
            label += f"\nNotes from the user: {ch['notes']}"
        content.append({"type": "text", "text": label})
        content.append({"type": "image_url", "image_url": {"url": ch["image"]}})
    content.append({"type": "text", "text": "\nReturn the JSON story bible now."})
    return [{"role": "system", "content": system}, {"role": "user", "content": content}]


_MINIMAL_BIBLE_SYSTEM = """You are a continuity writer. Return ONE compact JSON object and nothing else. No markdown, no commentary, no fences.

Exact shape:
{
  "title": "short title",
  "logline": "one sentence",
  "characters": [{"name": "exact name", "ref": "<imageN>", "appearance": "2 short sentences"}],
  "continuity_rules": ["short rule", "short rule"],
  "scenes": [{"n": 1, "title": "short title", "beat": "one visible-action sentence naming who is present, where, when, and any wardrobe state"}]
}

Rules:
- Use the exact cast names and reference tags given below. Reuse identity details from the previous draft if it contained any.
- "scenes" must contain exactly __COUNT__ entries numbered 1 through __COUNT__.
- Keep the whole JSON under 1200 tokens. Short phrases only.
- Every character is an adult (18+). Never minors, coercion or sexual violence.
- CONTENT: __INTENSITY__
"""


def _minimal_bible_messages(cfg, cast, raw):
    system = (
        _MINIMAL_BIBLE_SYSTEM
        .replace("__COUNT__", str(cfg["scene_count"]))
        .replace("__INTENSITY__", _INTENSITY[cfg["intensity"]])
    )
    cast_lines = "\n".join(
        f"- {c['name']} — {c['ref']}" + (f" — notes: {c['notes']}" if c["notes"] else "")
        for c in cast
    )
    user = (
        "STORY OVERVIEW:\n" + cfg["overview"] + "\n\n"
        f"CAST (use these exact names and tags):\n{cast_lines}\n\n"
        "A previous attempt produced this (possibly malformed or truncated) draft:\n"
        + str(raw or "")[:8000]
        + "\n\nRewrite it as the compact JSON object described above. Output JSON only."
    )
    return [{"role": "system", "content": system}, {"role": "user", "content": user}]


async def _stream_minimal_bible(result, engine_cfg, settings, cast, raw):
    """Last-resort bible pass: tiny JSON, no images, no response grammar."""
    minimal = _minimal_bible_messages(settings, cast, raw)
    async for ev in _stream_into(
        result, minimal, stage="bible",
        temperature=0.25,
        top_p=0.9,
        max_tokens=min(1600, _bible_limit(minimal, engine_cfg, settings["scene_count"])),
    ):
        yield ev


def _scene_system(cfg):
    template = _EDIT_SYSTEM if cfg["prompt_style"] == "edit" else _SCENE_SYSTEM
    return (
        template
        .replace("__INTENSITY__", _INTENSITY[cfg["intensity"]])
        .replace("__STYLE__", cfg["style"])
        .replace("__ASPECT__", cfg["aspect"])
        .replace("__SOURCE__", cfg["source_ref"])
    )


def _as_dict(value):
    return value if isinstance(value, dict) else {}


def _key(value):
    return re.sub(r"[^a-z0-9]+", "", str(value or "").casefold())


def _present_cast(bible, scene):
    cast = [c for c in (bible.get("characters") or []) if isinstance(c, dict)]
    wardrobe = _as_dict(scene.get("wardrobe"))
    emotion = _as_dict(scene.get("emotion"))
    names = {_key(k) for k in list(wardrobe) + list(emotion)}
    if not names:
        haystack = " ".join(str(scene.get(k) or "") for k in ("title", "beat", "location", "weather"))
        names = {
            _key(c.get("name")) for c in cast
            if c.get("name") and re.search(rf"(?<![A-Za-z]){re.escape(str(c['name']))}(?![A-Za-z])", haystack, re.I)
        }
    present = [c for c in cast if _key(c.get("name")) in names] or cast
    wmap = {_key(k): v for k, v in wardrobe.items()}
    emap = {_key(k): v for k, v in emotion.items()}
    out = []
    for c in present:
        print_name = _key(c.get("name"))
        item = {k: c.get(k) for k in ("name", "ref", "age", "appearance", "signature_wardrobe", "personality", "arc")}
        item["present"] = True
        if wmap.get(print_name):
            item["current_wardrobe"] = wmap[print_name]
        if emap.get(print_name):
            item["current_emotion"] = emap[print_name]
        out.append(item)
    return out


def _scene_messages(cfg, bible, scene, previous, next_beat):
    payload = {
        "story": {k: bible.get(k) for k in ("title", "logline", "world", "visual_style", "palette")},
        "continuity_rules": bible.get("continuity_rules") or [],
        "characters": _present_cast(bible, scene),
        "scene": scene,
        "previous_scene": previous,
        "next_scene_beat": next_beat,
        "settings": {
            "prompt_style": cfg["prompt_style"],
            "aspect": cfg["aspect"],
            "intensity": cfg["intensity"],
        },
    }
    user = "Story bible and scene:\n" + json.dumps(payload, ensure_ascii=False) + "\n\nWrite the prompt now."
    return [{"role": "system", "content": _scene_system(cfg)}, {"role": "user", "content": user}]


def _normalize_bible(bible, cfg, cast):
    if not isinstance(bible, dict):
        return None
    pool = [c for c in (bible.get("characters") or []) if isinstance(c, dict)]
    merged = []
    for inp in cast:
        key = _key(inp["name"])
        match = next((c for c in pool if _key(c.get("name")) == key), None)
        if match is None and len(cast) == 1 and len(pool) == 1:
            match = pool[0]
        if match is not None:
            pool.remove(match)
        item = dict(match or {})
        item["name"] = inp["name"]
        item["ref"] = inp["ref"]
        item["age"] = _clip(item.get("age"), 80) or "adult"
        item["appearance"] = _clip(item.get("appearance"), 2000) or (inp["notes"] or "as shown in the attached reference sheet")
        item["signature_wardrobe"] = _clip(item.get("signature_wardrobe"), 600) or "as shown in the reference sheet"
        item["personality"] = _clip(item.get("personality"), 400) or "reserved but expressive"
        item["arc"] = _clip(item.get("arc"), 400)
        merged.append(item)
    bible["characters"] = merged
    bible["title"] = _clip(bible.get("title"), 120) or "Untitled story"
    bible["logline"] = _clip(bible.get("logline"), 400)
    bible["world"] = _clip(bible.get("world"), 1200)
    bible["visual_style"] = _clip(bible.get("visual_style"), 600) or cfg["style"]
    bible["palette"] = _clip(bible.get("palette"), 300)
    rules = bible.get("continuity_rules")
    bible["continuity_rules"] = (
        [_clip(x, 300) for x in rules if isinstance(x, str)][:8] if isinstance(rules, list) else []
    )
    raw_scenes = [s for s in (bible.get("scenes") or []) if isinstance(s, dict)]
    scenes = []
    for i, scene in enumerate(raw_scenes, 1):
        item = dict(scene)
        item["n"] = i
        item["title"] = _clip(item.get("title"), 80) or f"Scene {i}"
        item["beat"] = _clip(item.get("beat"), 800) or item["title"]
        item["location"] = _clip(item.get("location"), 400)
        item["time"] = _clip(item.get("time"), 120)
        item["weather"] = _clip(item.get("weather"), 200)
        item["wardrobe"] = _as_dict(item.get("wardrobe"))
        item["emotion"] = _as_dict(item.get("emotion"))
        props = item.get("props")
        item["props"] = [_clip(x, 120) for x in props if isinstance(x, str)][:8] if isinstance(props, list) else []
        item["camera"] = _clip(item.get("camera"), 200) or "medium shot, eye level"
        item["transition"] = _clip(item.get("transition"), 300)
        item["intimacy"] = _clip(item.get("intimacy"), 20)
        scenes.append(item)
    bible["scenes"] = scenes
    return bible


def _parse_json(text):
    if not text:
        return None
    s = str(text).strip()
    if "</think>" in s:
        s = s.split("</think>", 1)[1].strip()
    s = re.sub(r"^```(?:json)?\s*", "", s)
    s = re.sub(r"\s*```$", "", s)
    start, end = s.find("{"), s.rfind("}")
    if start < 0 or end <= start:
        return None
    body = re.sub(r",\s*([}\]])", r"\1", s[start:end + 1])
    try:
        data = json.loads(body)
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def _clean_prompt(text):
    s = str(text or "").strip()
    if "</think>" in s:
        s = s.split("</think>", 1)[1].strip()
    s = re.sub(r"^```[a-zA-Z]*\s*", "", s)
    s = re.sub(r"\s*```$", "", s)
    s = re.sub(r"^(?:here(?:'s| is)[^\n]*\n+)+", "", s, flags=re.I)
    s = re.sub(r"^(?:final\s+)?prompt\s*[:\-]\s*", "", s, flags=re.I)
    s = re.sub(r"^scene\s*\d+\s*[:\-]\s*", "", s, flags=re.I)
    s = re.sub(r"\s+", " ", s)
    return s.strip().strip('"').strip("“”").strip()


def _words(text):
    return len(re.findall(r"[A-Za-z0-9][A-Za-z0-9'\-]*", text or ""))


def _slop(prompt):
    if re.search(r"(?im)^\s*(?:[-*•]|\d+[.)])\s+", prompt):
        return True
    return bool(re.search(r"(?i)\b(?:tags?|negative prompt)\s*:", prompt))


def _needs_retry(prompt, cfg, present):
    if _slop(prompt):
        return True
    if cfg["prompt_style"] == "edit":
        low = prompt.lower()
        return _words(prompt) < 55 or not low.startswith("using ") or "preserve" not in low
    if _words(prompt) < 150:
        return True
    return any(c.get("ref") and c["ref"] not in prompt for c in present)


def _retry_note(prompt, cfg, present):
    notes = []
    if _slop(prompt):
        notes.append("Write flowing prose only — no bullet points, tag lists, weights or negative prompt.")
    if cfg["prompt_style"] == "edit":
        low = prompt.lower()
        if not low.startswith("using "):
            notes.append(f'Start with "Using {cfg["source_ref"]} as the base frame, ...".')
        if _words(prompt) < 70:
            notes.append("Expand to 70-150 words.")
        if "preserve" not in low:
            notes.append('End with an explicit "Preserve ..." clause.')
    else:
        if _words(prompt) < 190:
            notes.append("Expand to 190-320 words with more specific face, pose, wardrobe, light and environment detail.")
        missing = [c["ref"] for c in present if c.get("ref") and c["ref"] not in prompt]
        if missing:
            notes.append("Mention these reference tags exactly where the character appears: " + ", ".join(missing) + ".")
    notes.append("Output only the rewritten prompt paragraph.")
    return " ".join(notes)


async def _stream_into(result, messages, *, index=None, stage=None, temperature=0.75,
                       top_p=0.9, max_tokens=1200, response_format=None):
    parts, count = [], 0
    every = 8 if stage else 12
    async for ev in llm.manager.stream_chat(
        messages, temperature, top_p, max_tokens, response_format=response_format
    ):
        kind = ev.get("type")
        if kind == "chunk":
            parts.append(ev.get("text") or "")
            count += 1
            if count % every == 0 and (index is not None or stage):
                stats = ev.get("stats") or {}
                tick = {
                    "type": "tick",
                    "tokens": stats.get("eval_tokens"),
                    "tps": stats.get("tokens_sec"),
                    "elapsed": stats.get("elapsed_time"),
                }
                if stage:
                    tick["stage"] = stage
                if index is not None:
                    tick["index"] = index
                yield tick
        elif kind == "error":
            raise LazyComfyError("llm_error", ev.get("message") or "Generation failed")
    result["text"] = "".join(parts).strip()


def _bible_tokens(scene_count):
    # The bible is a beat sheet, not prose. Keeping it compact is the single
    # biggest win for local inference: a 12-scene bible writes ~2.5k tokens
    # instead of ~4.7k, then the scene pass expands each beat into full prose.
    return min(5200, max(1800, 650 + scene_count * 160))


def _bible_limit(messages, cfg, scene_count):
    """Keep the bible reply inside the model's context window.

    The vision sheets are charged to `context_length` too. Without this, a
    low-context run can ask for 8k tokens with only 3k left, which produces a
    truncated JSON object and a failed generation.
    """
    estimate = getattr(llm, "_estimate_tokens", None)
    if callable(estimate):
        used = estimate(messages)
    else:
        used = max(1, len(json.dumps(messages)) // 4)
    available = cfg["context_length"] - used - 384
    if available < 1400:
        raise LazyComfyError(
            "context_too_small",
            f"Context {cfg['context_length']} is too small for this cast and {scene_count} scenes. "
            f"Raise it to at least {used + 1800} in the engine panel.",
        )
    return max(1400, min(_bible_tokens(scene_count), available))


def _repair_messages(messages, raw, instruction):
    return messages + [
        {"role": "assistant", "content": (raw or "")[:18000]},
        {"role": "user", "content": instruction},
    ]


async def run(body):
    """Full two-pass storyline generation, yielding SSE-ready events."""
    cfg = _engine(body)
    cast = _cast(body)
    settings = _settings(body, cast)
    count = settings["scene_count"]

    llm.manager.begin_generation()
    try:
        yield {"type": "status", "stage": "load", "message": "Preparing the local vision model…"}
        loader = llm.manager.ensure_loaded_events(cfg["model"], cfg["mmproj"], cfg["context_length"])
        try:
            async for ev in loader:
                if ev.get("type") == "status":
                    yield {"type": "status", "stage": "load", "message": ev.get("message") or "Loading model…"}
        finally:
            await loader.aclose()
        if not llm.manager.mmproj:
            raise LazyComfyError(
                "vision_unavailable",
                f"'{cfg['model']}' was loaded without a vision projector. "
                "Pick the matching mmproj in the engine panel, then generate again.",
            )

        yield {"type": "status", "stage": "bible", "message": "Reading the sheets and writing the compact story bible…"}
        messages = _bible_messages(settings, cast)
        result = {}
        async for ev in _stream_into(
            result, messages, stage="bible",
            temperature=min(cfg["temperature"], 0.7),
            top_p=cfg["top_p"],
            max_tokens=_bible_limit(messages, cfg, count),
            response_format={"type": "json_object"},
        ):
            yield ev
        raw = result.get("text", "")
        bible = _parse_json(raw)

        if bible is None:
            yield {"type": "status", "stage": "bible", "message": "The story bible arrived malformed — repairing the JSON…"}
            result = {}
            repair = _repair_messages(
                messages, raw,
                "That was not valid JSON. Return the same story bible as ONE valid JSON object only, "
                "starting with { and ending with }. No commentary, no markdown.",
            )
            async for ev in _stream_into(
                result, repair, stage="bible",
                temperature=0.2,
                top_p=0.9,
                max_tokens=_bible_limit(repair, cfg, count),
                response_format={"type": "json_object"},
            ):
                yield ev
            raw = result.get("text", "")
            bible = _parse_json(raw)

        used_minimal = False
        if not isinstance(bible, dict):
            yield {
                "type": "status", "stage": "bible",
                "message": "The full bible was unusable — switching to a compact beat sheet…",
            }
            result = {}
            async for ev in _stream_minimal_bible(result, cfg, settings, cast, raw):
                yield ev
            raw = result.get("text", "")
            bible = _parse_json(raw)
            used_minimal = isinstance(bible, dict)

        if not isinstance(bible, dict):
            raise LazyComfyError(
                "generation_failed",
                "The model could not return valid JSON even for the compact beat sheet. "
                "Try fewer scenes or a lower temperature.",
            )
        bible = _normalize_bible(bible, settings, cast)
        scenes = bible.get("scenes") or []
        if not scenes:
            raise LazyComfyError("generation_failed", "The model returned no scenes. Try again.")

        if not used_minimal and len(scenes) != count:
            yield {
                "type": "status", "stage": "bible",
                "message": f"Got {len(scenes)} of {count} scenes — asking for the full beat sheet…",
            }
            result = {}
            repair = _repair_messages(
                messages, raw,
                f"You returned {len(scenes)} scenes, but the brief requires exactly {count}. "
                f"Return the complete JSON again with exactly {count} scenes, keeping the same cast, "
                "identities and story. Output JSON only.",
            )
            async for ev in _stream_into(
                result, repair, stage="bible",
                temperature=0.25,
                top_p=0.9,
                max_tokens=_bible_limit(repair, cfg, count),
                response_format={"type": "json_object"},
            ):
                yield ev
            correction_raw = result.get("text", "")
            replacement = _normalize_bible(_parse_json(correction_raw), settings, cast)
            if replacement and replacement.get("scenes") and abs(len(replacement["scenes"]) - count) < abs(len(scenes) - count):
                bible = replacement
                scenes = bible["scenes"]
            else:
                raw = correction_raw or raw
        if len(scenes) != count and not used_minimal:
            yield {
                "type": "status", "stage": "bible",
                "message": "Still short of the requested scenes — writing a compact beat sheet…",
            }
            result = {}
            async for ev in _stream_minimal_bible(result, cfg, settings, cast, raw):
                yield ev
            compact = _normalize_bible(_parse_json(result.get("text", "")), settings, cast)
            if compact and compact.get("scenes"):
                bible = compact
                scenes = bible["scenes"]
                used_minimal = True
        if used_minimal and len(scenes) != count:
            yield {
                "type": "warning",
                "message": f"The compact beat sheet produced {len(scenes)} scenes instead of {count}.",
            }

        if len(scenes) > count:
            yield {"type": "warning", "message": f"The model produced {len(scenes)} scenes; keeping the first {count}."}
            scenes = scenes[:count]
            bible["scenes"] = scenes
        if len(scenes) < count:
            yield {"type": "warning", "message": f"The model produced {len(scenes)} scenes instead of {count}."}
        yield {"type": "bible", "data": bible, "requested": count}

        previous = None
        for i, scene in enumerate(scenes):
            n = i + 1
            yield {"type": "status", "stage": "scene", "index": n, "total": len(scenes), "message": f"Writing scene {n} of {len(scenes)}…"}
            present = _present_cast(bible, scene)
            next_beat = scenes[i + 1].get("beat") if i + 1 < len(scenes) else None
            messages = _scene_messages(settings, bible, scene, previous, next_beat)
            result = {}
            async for ev in _stream_into(
                result, messages, index=n,
                temperature=cfg["temperature"], top_p=cfg["top_p"], max_tokens=1300,
            ):
                yield ev
            first_text = result.get("text", "")
            prompt = _clean_prompt(first_text)

            if not prompt or _needs_retry(prompt, settings, present):
                yield {"type": "status", "stage": "scene", "index": n, "total": len(scenes), "message": f"Scene {n} needs more detail — rewriting…"}
                result = {}
                async for ev in _stream_into(
                    result,
                    _repair_messages(messages, first_text, _retry_note(prompt, settings, present)),
                    index=n,
                    temperature=max(0.55, cfg["temperature"] - 0.1),
                    top_p=cfg["top_p"],
                    max_tokens=1300,
                ):
                    yield ev
                prompt = _clean_prompt(result.get("text", "")) or prompt

            if not prompt:
                raise LazyComfyError("generation_failed", f"Scene {n} produced an empty prompt. Try again.")
            out = dict(scene)
            out["n"] = n
            out["prompt"] = prompt
            out["words"] = _words(prompt)
            yield {"type": "scene", "index": n, "total": len(scenes), "scene": out}
            previous = {"beat": scene.get("beat") or "", "prompt": prompt}

        yield {"type": "done", "bible": bible, "scenes": len(scenes)}
    finally:
        llm.manager.end_generation()


async def run_scene(body):
    """Regenerate a single scene prompt, streaming its text as it is written."""
    cfg = _engine(body)
    bible = body.get("bible")
    scene = body.get("scene")
    if not isinstance(bible, dict) or not isinstance(scene, dict):
        raise LazyComfyError("invalid_request", "A story bible and scene are required")
    if len(json.dumps(bible)) > 500000:
        raise LazyComfyError("invalid_request", "The story bible is too large")
    # The UI may have remapped reference tags since the bible was written
    # (for example switching from scene mode to edit mode). Its current cast
    # mapping wins, so regeneration cannot inherit a stale tag collision.
    provided = body.get("characters")
    if isinstance(provided, list):
        ref_by_name = {}
        for item in provided:
            if not isinstance(item, dict):
                continue
            name, ref = _key(item.get("name")), _clip(item.get("ref"), 20)
            if name and _REF_RE.match(ref):
                ref_by_name[name] = ref
        chars = bible.get("characters")
        if isinstance(chars, list):
            for c in chars:
                if isinstance(c, dict):
                    ref = ref_by_name.get(_key(c.get("name")))
                    if ref:
                        c["ref"] = ref
    seen_refs = set()
    for c in bible.get("characters") or []:
        if not isinstance(c, dict):
            continue
        ref = str(c.get("ref") or "")
        if not ref:
            continue
        if ref in seen_refs:
            raise LazyComfyError("invalid_request", f"Reference tag {ref} is used twice")
        seen_refs.add(ref)
    data = dict(body)
    if not str(data.get("overview") or "").strip():
        data["overview"] = str(bible.get("logline") or bible.get("title") or "Continue the story") + " — continue the story."
    cast_refs = [
        {"name": str(c.get("name") or ""), "ref": str(c.get("ref") or "")}
        for c in (bible.get("characters") or []) if isinstance(c, dict)
    ]
    settings = _settings(data, cast_refs)
    previous = body.get("previous_scene")
    if not isinstance(previous, dict):
        previous = None
    next_beat = body.get("next_scene_beat")
    messages = _scene_messages(settings, bible, scene, previous, next_beat if isinstance(next_beat, str) else None)

    llm.manager.begin_generation()
    try:
        yield {"type": "status", "stage": "load", "message": "Preparing the model…"}
        loader = llm.manager.ensure_loaded_events(cfg["model"], cfg["mmproj"], cfg["context_length"])
        try:
            async for ev in loader:
                if ev.get("type") == "status":
                    yield {"type": "status", "stage": "load", "message": ev.get("message") or "Loading model…"}
        finally:
            await loader.aclose()
        yield {"type": "status", "stage": "scene", "message": "Rewriting the scene…"}
        parts = []
        async for ev in llm.manager.stream_chat(
            messages, cfg["temperature"], cfg["top_p"], 1300,
        ):
            kind = ev.get("type")
            if kind == "chunk":
                text = ev.get("text") or ""
                parts.append(text)
                yield {"type": "chunk", "text": text}
            elif kind == "error":
                raise LazyComfyError("llm_error", ev.get("message") or "Generation failed")
        first_text = "".join(parts)
        prompt = _clean_prompt(first_text)
        present = _present_cast(bible, scene)
        if not prompt or _needs_retry(prompt, settings, present):
            yield {"type": "status", "stage": "scene", "message": "Rewrite needs another pass — improving it…"}
            yield {"type": "reset"}
            retry_result = {}
            retry = _stream_into(
                retry_result,
                _repair_messages(messages, first_text, _retry_note(prompt, settings, present)),
                temperature=max(0.55, cfg["temperature"] - 0.1),
                top_p=cfg["top_p"],
                max_tokens=1300,
            )
            async for ev in retry:
                if ev.get("type") == "chunk":
                    yield {"type": "chunk", "text": ev.get("text") or ""}
            prompt = _clean_prompt(retry_result.get("text", "")) or prompt
        if not prompt:
            raise LazyComfyError("generation_failed", "The rewrite came back empty. Try again.")
        yield {"type": "done", "prompt": prompt, "words": _words(prompt)}
    finally:
        llm.manager.end_generation()
