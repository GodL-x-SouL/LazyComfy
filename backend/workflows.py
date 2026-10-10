import copy
import json
import logging
import os

from . import LazyComfyError
from .config import WORKFLOWS_DIR
from .models import get_model

logger = logging.getLogger("lazycomfy")

WORKFLOWS = {
    "z_image_turbo_t2i": {
        "model_id": "z_image_turbo",
        "mode": "t2i",
        "file": "z_image_turbo_t2i.json",
        "output_node": "10",
        "fill": {
            "prompt": [("4", "text")],
            "width": [("6", "width")],
            "height": [("6", "height")],
            "batch": [("6", "batch_size")],
            "seed": [("8", "seed")],
            "steps": [("8", "steps")],
            "cfg": [("8", "cfg")],
            "sampler": [("8", "sampler_name")],
            "scheduler": [("8", "scheduler")],
            "denoise": [("8", "denoise")],
            "unet_file": [("1", "unet_name")],
            "clip_file": [("2", "clip_name")],
            "vae_file": [("3", "vae_name")],
        },
    },
    "krea_2_turbo_t2i": {
        "model_id": "krea_2_turbo",
        "mode": "t2i",
        "file": "krea_2_turbo_t2i.json",
        "output_node": "9",
        "fill": {
            "prompt": [("4", "text")],
            "width": [("6", "width")],
            "height": [("6", "height")],
            "batch": [("6", "batch_size")],
            "seed": [("7", "seed")],
            "steps": [("7", "steps")],
            "cfg": [("7", "cfg")],
            "sampler": [("7", "sampler_name")],
            "scheduler": [("7", "scheduler")],
            "denoise": [("7", "denoise")],
            "unet_file": [("1", "unet_name")],
            "clip_file": [("2", "clip_name")],
            "vae_file": [("3", "vae_name")],
        },
    },
    "krea_2_turbo_i2i": {
        "model_id": "krea_2_turbo",
        "mode": "i2i",
        "file": "krea_2_turbo_i2i.json",
        "output_node": "10",
        "fill": {
            "prompt": [("4", "text")],
            "image": [("6", "image")],
            "seed": [("8", "seed")],
            "steps": [("8", "steps")],
            "cfg": [("8", "cfg")],
            "sampler": [("8", "sampler_name")],
            "scheduler": [("8", "scheduler")],
            "denoise": [("8", "denoise")],
            "unet_file": [("1", "unet_name")],
            "clip_file": [("2", "clip_name")],
            "vae_file": [("3", "vae_name")],
        },
    },
    "flux_2_klein_9b_t2i": {
        "model_id": "flux_2_klein_9b",
        "mode": "t2i",
        "file": "flux_2_klein_9b_t2i.json",
        "output_node": "13",
        "fill": {
            "prompt": [("4", "text")],
            "width": [("6", "width"), ("8", "width")],
            "height": [("6", "height"), ("8", "height")],
            "batch": [("6", "batch_size")],
            "seed": [("10", "noise_seed")],
            "steps": [("8", "steps")],
            "cfg": [("9", "cfg")],
            "sampler": [("7", "sampler_name")],
            "unet_file": [("1", "unet_name")],
            "clip_file": [("2", "clip_name")],
            "vae_file": [("3", "vae_name")],
        },
    },
    "flux_2_klein_9b_i2i": {
        "model_id": "flux_2_klein_9b",
        "mode": "i2i",
        "file": "flux_2_klein_9b_i2i.json",
        "output_node": "10",
        "fill": {
            "prompt": [("4", "text")],
            "image": [("6", "image")],
            "seed": [("8", "seed")],
            "steps": [("8", "steps")],
            "cfg": [("8", "cfg")],
            "sampler": [("8", "sampler_name")],
            "scheduler": [("8", "scheduler")],
            "denoise": [("8", "denoise")],
            "unet_file": [("1", "unet_name")],
            "clip_file": [("2", "clip_name")],
            "vae_file": [("3", "vae_name")],
        },
    },
    "ideogram_4_t2i": {
        "model_id": "ideogram_4",
        "mode": "t2i",
        "file": "ideogram_4_t2i.json",
        "output_node": "14",
        "fill": {
            "prompt": [("5", "text")],
            "width": [("7", "width"), ("9", "width")],
            "height": [("7", "height"), ("9", "height")],
            "batch": [("7", "batch_size")],
            "seed": [("11", "noise_seed")],
            "steps": [("9", "steps")],
            "cfg": [("10", "cfg")],
            "sampler": [("8", "sampler_name")],
            "mu": [("9", "mu")],
            "std": [("9", "std")],
            "unet_file": [("1", "unet_name")],
            "uncond_file": [("2", "unet_name")],
            "clip_file": [("3", "clip_name")],
            "vae_file": [("4", "vae_name")],
        },
    },
    # ---- Qwen Image 2.1 (official nodes: TextEncodeQwenImage21 + QwenImage21Cache) ----
    "qwen_image_2_1_t2i": {
        "model_id": "qwen_image_2_1",
        "mode": "t2i",
        "file": "qwen_image_2_1_t2i.json",
        "output_node": "8",
        "fill": {
            "prompt": [("4", "prompt")],
            "negative_prompt": [("4", "negative_prompt")],
            "width": [("5", "width")],
            "height": [("5", "height")],
            "batch": [("5", "batch_size")],
            "seed": [("6", "seed")],
            "steps": [("6", "steps")],
            "cfg": [("6", "cfg")],
            "sampler": [("6", "sampler_name")],
            "scheduler": [("6", "scheduler")],
            "unet_file": [("1", "unet_name")],
            "clip_file": [("2", "clip_name")],
            "vae_file": [("3", "vae_name")],
        },
    },
    "qwen_image_2_1_i2i": {
        "model_id": "qwen_image_2_1",
        "mode": "i2i",
        "file": "qwen_image_2_1_i2i.json",
        "output_node": "9",
        "fill": {
            "prompt": [("4", "prompt")],
            "negative_prompt": [("4", "negative_prompt")],
            "resolution": [("4", "resolution")],
            "image": [("5", "image")],
            "seed": [("7", "seed")],
            "steps": [("7", "steps")],
            "cfg": [("7", "cfg")],
            "sampler": [("7", "sampler_name")],
            "scheduler": [("7", "scheduler")],
            "unet_file": [("1", "unet_name")],
            "clip_file": [("2", "clip_name")],
            "vae_file": [("3", "vae_name")],
        },
    },
    # ---- Qwen Image 2.1 Turbo (official 8-step distilled checkpoint) ----
    "qwen_image_2_1_turbo_t2i": {
        "model_id": "qwen_image_2_1_turbo",
        "mode": "t2i",
        "file": "qwen_image_2_1_turbo_t2i.json",
        "output_node": "8",
        "fill": {
            "prompt": [("4", "prompt")],
            "negative_prompt": [("4", "negative_prompt")],
            "width": [("5", "width")],
            "height": [("5", "height")],
            "batch": [("5", "batch_size")],
            "seed": [("6", "seed")],
            "steps": [("6", "steps")],
            "cfg": [("6", "cfg")],
            "sampler": [("6", "sampler_name")],
            "scheduler": [("6", "scheduler")],
            "unet_file": [("1", "unet_name")],
            "clip_file": [("2", "clip_name")],
            "vae_file": [("3", "vae_name")],
        },
    },
    "qwen_image_2_1_turbo_i2i": {
        "model_id": "qwen_image_2_1_turbo",
        "mode": "i2i",
        "file": "qwen_image_2_1_turbo_i2i.json",
        "output_node": "9",
        "fill": {
            "prompt": [("4", "prompt")],
            "negative_prompt": [("4", "negative_prompt")],
            "resolution": [("4", "resolution")],
            "image": [("5", "image")],
            "seed": [("7", "seed")],
            "steps": [("7", "steps")],
            "cfg": [("7", "cfg")],
            "sampler": [("7", "sampler_name")],
            "scheduler": [("7", "scheduler")],
            "unet_file": [("1", "unet_name")],
            "clip_file": [("2", "clip_name")],
            "vae_file": [("3", "vae_name")],
        },
    },
    # ---- Video: MiniMax H3 ----
    "minimax_h3_t2v": {
        "model_id": "minimax_h3",
        "mode": "t2i",
        "file": "minimax_h3_t2v.json",
        "output_node": "15",
        "fill": {
            "prompt": [("5", "prompt")],
            "width": [("5", "width")],
            "height": [("5", "height")],
            "length": [("5", "length")],
            "seed": [("7", "noise_seed")],
            "steps": [("9", "steps")],
            "sampler": [("8", "sampler_name")],
            "scheduler": [("9", "scheduler")],
            "fps": [("14", "fps")],
            "unet_file": [("1", "unet_name")],
            "clip_file": [("2", "clip_name")],
            "vae_file": [("3", "vae_name")],
            "audio_vae_file": [("4", "vae_name")],
        },
    },
    "minimax_h3_i2v": {
        "model_id": "minimax_h3",
        "mode": "i2i",
        "file": "minimax_h3_i2v.json",
        "output_node": "16",
        "fill": {
            "prompt": [("6", "prompt")],
            "width": [("6", "width")],
            "height": [("6", "height")],
            "length": [("6", "length")],
            "image": [("5", "image")],
            "seed": [("8", "noise_seed")],
            "steps": [("10", "steps")],
            "sampler": [("9", "sampler_name")],
            "scheduler": [("10", "scheduler")],
            "fps": [("15", "fps")],
            "unet_file": [("1", "unet_name")],
            "clip_file": [("2", "clip_name")],
            "vae_file": [("3", "vae_name")],
            "audio_vae_file": [("4", "vae_name")],
        },
    },
    # ---- Video: LTX 2.5 ----
    "ltx_2_5_t2v": {
        "model_id": "ltx_2_5",
        "mode": "t2i",
        "file": "ltx_2_5_t2v.json",
        "output_node": "19",
        "fill": {
            "prompt": [("5", "text")],
            "width": [("7", "width")],
            "height": [("7", "height")],
            "length": [("7", "length")],
            "seed": [("12", "noise_seed")],
            "steps": [("10", "steps")],
            "sampler": [("11", "sampler_name")],
            "fps": [("8", "frame_rate"), ("18", "fps")],
            "unet_file": [("1", "unet_name")],
            "clip_file": [("2", "clip_name")],
            "vae_file": [("3", "vae_name")],
            "audio_vae_file": [("4", "vae_name")],
        },
    },
    "ltx_2_5_i2v": {
        "model_id": "ltx_2_5",
        "mode": "i2i",
        "file": "ltx_2_5_i2v.json",
        "output_node": "21",
        "fill": {
            "prompt": [("6", "text")],
            "width": [("8", "width")],
            "height": [("8", "height")],
            "length": [("8", "length")],
            "image": [("5", "image")],
            "seed": [("14", "noise_seed")],
            "steps": [("12", "steps")],
            "sampler": [("13", "sampler_name")],
            "fps": [("10", "frame_rate"), ("20", "fps")],
            "unet_file": [("1", "unet_name")],
            "clip_file": [("2", "clip_name")],
            "vae_file": [("3", "vae_name")],
            "audio_vae_file": [("4", "vae_name")],
        },
    },
}

_PE_SYSTEM_CACHE = {}


def _pe_system_prompt(mode):
    if mode not in _PE_SYSTEM_CACHE:
        path = os.path.join(WORKFLOWS_DIR, f"qwen_pe_system_{mode}.txt")
        try:
            with open(path, "r", encoding="utf-8") as fh:
                text = fh.read().strip()
        except OSError as e:
            raise LazyComfyError("template_not_found", f"Cannot load Qwen PE system prompt for {mode}: {e}")
        if not text:
            raise LazyComfyError("template_not_found", f"Qwen PE system prompt for {mode} is empty")
        _PE_SYSTEM_CACHE[mode] = text
    return _PE_SYSTEM_CACHE[mode]


file_class_inputs = {
    "UNETLoader": "unet_name",
    "CLIPLoader": "clip_name",
    "VAELoader": "vae_name",
}


def load_template(template_id):
    desc = WORKFLOWS.get(template_id)
    if desc is None:
        raise LazyComfyError("template_not_found", f"Unknown workflow template: {template_id}")
    path = os.path.join(WORKFLOWS_DIR, desc["file"])
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError) as e:
        raise LazyComfyError("template_not_found", f"Cannot load template {template_id}: {e}")
    if not isinstance(data, dict) or not data:
        raise LazyComfyError("template_not_found", f"Template {template_id} is not a node dictionary")
    for node_id, node in data.items():
        if not isinstance(node, dict) or "class_type" not in node:
            raise LazyComfyError("template_not_found", f"Template {template_id} node {node_id} is missing class_type")
    return data


def list_workflows():
    out = []
    for template_id, desc in WORKFLOWS.items():
        try:
            data = load_template(template_id)
        except LazyComfyError as e:
            logger.warning("LazyComfy: skipping workflow %s: %s", template_id, e.message)
            continue
        out.append({
            "id": template_id,
            "model_id": desc["model_id"],
            "mode": desc["mode"],
            "output_node": desc["output_node"],
            "node_count": len(data),
            "class_types": sorted({node["class_type"] for node in data.values()}),
        })
    return out


def build_workflow(template_id, params, files_ok=None):
    template = load_template(template_id)
    desc = WORKFLOWS[template_id]
    out = copy.deepcopy(template)
    fill = desc["fill"]
    for key, value in params.items():
        if key == "images":
            # handled below for Qwen multi-image edit; skip generic fill
            continue
        targets = fill.get(key)
        if not targets:
            continue
        for node_id, input_name in targets:
            node = out.get(node_id)
            if node is None or not isinstance(node, dict) or "inputs" not in node or input_name not in node["inputs"]:
                raise LazyComfyError(
                    "template_drift",
                    f"Template {template_id} is missing fill target {node_id}.{input_name} for parameter '{key}'",
                )
            if isinstance(value, list):
                node["inputs"][input_name] = {"__value__": value}
            else:
                node["inputs"][input_name] = value

    loras = params.get("loras")
    if not loras and params.get("lora_name"):
        loras = [{"name": params["lora_name"], "strength": float(params.get("lora_strength", 1.0))}]
    # ---- Qwen Image 2.1 multi-image edit (up to 10, official TextEncodeQwenImage21) ----
    # params["images"] is a list of 1..10 ComfyUI image paths (strings).
    # The encode node takes an Autogrow "images" input: slots are addressed as
    # flat dotted keys "images.image_1" .. "images.image_10" in API format.
    # Slot 1 reuses the template LoadImage node 5 (filled via "image");
    # slots 2..N get fresh LoadImage nodes 20..28 wired to images.image_2..images.image_10.
    if template_id in ("qwen_image_2_1_i2i", "qwen_image_2_1_turbo_i2i"):
        images = params.get("images")
        if isinstance(images, list) and len(images) > 1:
            if len(images) > 10:
                raise LazyComfyError("invalid_request", "Qwen Image 2.1 supports at most 10 reference images")
            encode_node = out.get("4")
            if encode_node is None or encode_node.get("class_type") != "TextEncodeQwenImage21":
                raise LazyComfyError("template_drift", f"Template {template_id} is missing TextEncodeQwenImage21 node 4")
            for idx, img_path in enumerate(images[1:], start=2):
                node_id = str(18 + idx)  # image_2->20, image_3->21, … image_10->28
                out[node_id] = {"class_type": "LoadImage", "inputs": {"image": img_path}}
                encode_node["inputs"][f"images.image_{idx}"] = [node_id, 0]
    # ---- Qwen prompt enhancer (optional TextGenerate + Qwen3.5 PE encoder) ----
    # Mirrors the official Comfy-Org Qwen 2.1 templates: the raw prompt goes
    # through TextGenerate first, whose output feeds the encode node. Node ids
    # 40-43 are reserved for the injected chain (templates use 1-28, LoRAs 90+).
    if params.get("enhance") and desc["model_id"].startswith("qwen_image_2_1"):
        model = get_model(desc["model_id"])
        pe_file = ((model or {}).get("pe") or {}).get(desc["mode"])
        if not pe_file:
            raise LazyComfyError("invalid_request", f"Prompt enhancement is not available for {desc['model_id']} / {desc['mode']}")
        for nid in ("40", "41", "42", "43"):
            if nid in out:
                raise LazyComfyError("template_drift", f"Template {template_id} already uses reserved node id {nid}")
        out["40"] = {"class_type": "CLIPLoader", "inputs": {
            "clip_name": pe_file,
            "type": "qwen_image" if desc["mode"] == "i2i" else "stable_diffusion",
            "device": "default",
        }}
        out["42"] = {"class_type": "PrimitiveStringMultiline", "inputs": {"value": _pe_system_prompt(desc["mode"])}}
        # NOTE: DynamicCombo inputs serialize as flat dotted keys ("sampling_mode"
        # selects the option, "sampling_mode.temperature" etc. carry the values);
        # a nested dict is dropped and execute() reports a missing argument.
        tg_inputs = {
            "clip": ["40", 0],
            "prompt": params["prompt"],
            "max_length": 1024,
            "sampling_mode": "on",
            "sampling_mode.temperature": 1.0,
            "sampling_mode.top_k": 20,
            "sampling_mode.top_p": 0.95,
            "sampling_mode.min_p": 0.0,
            "sampling_mode.repetition_penalty": 1.0,
            "sampling_mode.seed": 0,
            "sampling_mode.presence_penalty": 1.5 if desc["mode"] == "t2i" else 0.0,
            "thinking": False,
            "use_default_template": True,
            "mtp": "auto",
            "system_prompt": ["42", 0],
        }
        if desc["mode"] == "i2i":
            # Batch the same reference images wired into the encode node
            # (Autogrow slots are 0-indexed image0.. on BatchImagesNode).
            encode_node = out.get("4")
            slots = sorted(
                [k for k in (encode_node.get("inputs") if isinstance(encode_node, dict) else {} or {}) if k.startswith("images.image_")],
                key=lambda k: int(k.rsplit("_", 1)[1]),
            )
            batch_inputs = {}
            for i, slot in enumerate(slots):
                link = encode_node["inputs"][slot]
                if isinstance(link, list) and link:
                    batch_inputs[f"images.image{i}"] = list(link)
            if not batch_inputs:
                raise LazyComfyError("invalid_request", "Prompt enhancement needs at least one source image")
            out["41"] = {"class_type": "BatchImagesNode", "inputs": batch_inputs}
            tg_inputs["image"] = ["41", 0]
        out["43"] = {"class_type": "TextGenerate", "inputs": tg_inputs}
        encode_node = out.get("4")
        if not isinstance(encode_node, dict) or encode_node.get("class_type") != "TextEncodeQwenImage21" or "prompt" not in encode_node.get("inputs", {}):
            raise LazyComfyError("template_drift", f"Template {template_id} is missing TextEncodeQwenImage21 node 4 prompt input")
        encode_node["inputs"]["prompt"] = ["43", 0]
    if loras:
        unet_node = None
        unet_name = params.get("unet_file")
        for node_id, node in out.items():
            if node.get("class_type") == "UNETLoader" and (unet_name is None or node.get("inputs", {}).get("unet_name") == unet_name):
                unet_node = node_id
                break
        if unet_node is None:
            for node_id, node in out.items():
                if node.get("class_type") == "UNETLoader":
                    unet_node = node_id
                    break
        if unet_node is None:
            raise LazyComfyError("template_drift", f"Template {template_id} has no UNETLoader to attach the LoRA to")
        lora_ids = [str(90 + i) for i in range(len(loras))]
        prev = [unet_node, 0]
        last = None
        for i, lora in enumerate(loras):
            node_id = lora_ids[i]
            out[node_id] = {
                "class_type": "LoraLoaderModelOnly",
                "inputs": {
                    "model": prev,
                    "lora_name": lora["name"],
                    "strength_model": float(lora["strength"]),
                },
            }
            prev = [node_id, 0]
            last = node_id
        for node_id, node in out.items():
            if node_id in lora_ids or not isinstance(node, dict):
                continue
            inputs = node.get("inputs")
            if not isinstance(inputs, dict):
                continue
            for input_name, value in inputs.items():
                if isinstance(value, list) and len(value) > 0 and value[0] == unet_node:
                    inputs[input_name] = [last, 0]
    return out
