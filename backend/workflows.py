import copy
import json
import logging
import os

from . import LazyComfyError
from .config import WORKFLOWS_DIR

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
    "z_image_turbo_i2i": {
        "model_id": "z_image_turbo",
        "mode": "i2i",
        "file": "z_image_turbo_i2i.json",
        "output_node": "11",
        "fill": {
            "prompt": [("4", "text")],
            "image": [("6", "image")],
            "seed": [("9", "seed")],
            "steps": [("9", "steps")],
            "cfg": [("9", "cfg")],
            "sampler": [("9", "sampler_name")],
            "scheduler": [("9", "scheduler")],
            "denoise": [("9", "denoise")],
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
    "ideogram_4_i2i": {
        "model_id": "ideogram_4",
        "mode": "i2i",
        "file": "ideogram_4_i2i.json",
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
}

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
