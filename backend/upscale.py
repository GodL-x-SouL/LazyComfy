import asyncio
import gc
import logging
import os
import shutil

from . import LazyComfyError
from . import hub
from . import queue

logger = logging.getLogger("lazycomfy")

try:
    import folder_paths
except Exception:
    folder_paths = None

_IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".webp", ".bmp")
_ALLOWED_EXT = (".png", ".jpg", ".jpeg", ".webp", ".bmp", ".gif")

_SAVED = {}
_ALLOWED_DIRS = set()

_COLOR_METHODS = ("lab", "wavelet", "adain", "none")


def _folder_path(kind):
    if folder_paths is not None:
        try:
            if kind == "input":
                return folder_paths.get_input_directory()
            if kind == "output":
                return folder_paths.get_output_directory()
            dirs = folder_paths.get_folder_paths(kind)
            if dirs:
                return dirs[0]
        except Exception:
            pass
        try:
            base = getattr(folder_paths, "base_path", None)
            if base:
                return os.path.join(base, kind)
        except Exception:
            pass
    root = os.environ.get("LAZYCOMFY_MODELS_DIR")
    if root:
        return os.path.join(root, kind)
    return None


def input_dir():
    return _folder_path("input")


def output_dir():
    return _folder_path("output")


def list_seedvr_unets():
    names = hub.list_files("diffusion_models")
    return [n for n in names if "seedvr" in n.lower()]


def list_vaes():
    names = hub.list_files("vae")
    seed = [n for n in names if "seedvr" in n.lower() or n.lower().startswith("ema")]
    return seed or names


def config_payload():
    return {
        "unets": list_seedvr_unets(),
        "vaes": list_vaes(),
        "input_dir": input_dir(),
        "output_dir": output_dir(),
    }


def list_dir_images(path):
    if not path:
        base = input_dir()
        if not base:
            raise LazyComfyError("input_dir_unavailable", "Cannot resolve the ComfyUI input folder")
    else:
        base = os.path.abspath(os.path.expanduser(path))
        if not os.path.isdir(base):
            raise LazyComfyError("bad_directory", f"Not a directory: {base}")
    out = []
    for name in sorted(os.listdir(base)):
        if not name.lower().endswith(_IMAGE_EXTS):
            continue
        full = os.path.join(base, name)
        if not os.path.isfile(full):
            continue
        try:
            st = os.stat(full)
        except OSError:
            continue
        out.append({"name": name, "path": full, "size": st.st_size, "mtime": int(st.st_mtime)})
    out.sort(key=lambda i: i["mtime"], reverse=True)
    _ALLOWED_DIRS.add(base)
    return {"dir": base, "images": out}


def is_preview_allowed(path):
    if not path:
        return False
    full = os.path.abspath(os.path.expanduser(path))
    if not os.path.isfile(full) or not full.lower().endswith(_ALLOWED_EXT):
        return False
    for allowed in _ALLOWED_DIRS:
        if full == allowed or full.startswith(allowed + os.sep):
            return True
    return False


def ensure_in_input(image):
    base = input_dir()
    if not base:
        raise LazyComfyError("input_dir_unavailable", "Cannot resolve the ComfyUI input folder")
    name = os.path.basename(image)
    if not name or ".." in name:
        raise LazyComfyError("invalid_request", "Invalid image name")
    if not os.path.isfile(image):
        raise LazyComfyError("invalid_request", f"Image not found: {image}")
    if os.path.abspath(image).lower() == os.path.abspath(os.path.join(base, name)).lower():
        return name
    try:
        os.makedirs(base, exist_ok=True)
        shutil.copy2(image, os.path.join(base, name))
    except OSError as e:
        raise LazyComfyError("copy_failed", f"Cannot stage image into the ComfyUI input folder: {e}")
    return name


def build_workflow(image_name, unet, vae, scale, tile_size, tile_overlap, color_correction, seed, prefix):
    return {
        "1": {"class_type": "LoadImage", "inputs": {"image": image_name}},
        "2": {"class_type": "ImageScaleBy", "inputs": {"image": ["1", 0], "upscale_method": "bicubic", "scale_by": scale}},
        "3": {"class_type": "SeedVR2Preprocess", "inputs": {"resized_images": ["2", 0]}},
        "4": {"class_type": "UNETLoader", "inputs": {"unet_name": unet, "weight_dtype": "default"}},
        "5": {"class_type": "VAELoader", "inputs": {"vae_name": vae}},
        "6": {"class_type": "VAEEncodeTiled", "inputs": {"pixels": ["3", 0], "vae": ["5", 0], "tile_size": tile_size, "overlap": tile_overlap}},
        "7": {"class_type": "SeedVR2Conditioning", "inputs": {"model": ["4", 0], "vae_conditioning": ["6", 0]}},
        "8": {"class_type": "KSampler", "inputs": {"model": ["4", 0], "positive": ["7", 0], "negative": ["7", 1], "latent_image": ["6", 0], "seed": seed, "steps": 1, "cfg": 1.0, "sampler_name": "euler", "scheduler": "simple", "denoise": 1.0}},
        "9": {"class_type": "VAEDecodeTiled", "inputs": {"samples": ["8", 0], "vae": ["5", 0], "tile_size": tile_size, "overlap": tile_overlap}},
        "10": {"class_type": "SeedVR2PostProcessing", "inputs": {"images": ["9", 0], "original_resized_images": ["2", 0], "color_correction_method": color_correction}},
        "11": {"class_type": "SaveImage", "inputs": {"images": ["10", 0], "filename_prefix": prefix}},
    }


async def unload_models(session=None):
    """Unload every diffusion model from VRAM so the next heavy model can load without OOM."""
    if session is not None:
        try:
            status, data = await queue.http_json("GET", "/queue", session)
            if status == 200 and isinstance(data, dict) and data.get("queue_running"):
                raise LazyComfyError("busy", "ComfyUI is still executing a job — wait for it to finish before unloading")
        except LazyComfyError as e:
            if e.error_type == "busy":
                raise
    try:
        import comfy.model_management as mm

        mm.unload_all_models()
        gc.collect()
        mm.soft_empty_cache()
        return {"method": "direct"}
    except LazyComfyError:
        raise
    except Exception as e:
        logger.warning("LazyComfy: direct model unload unavailable (%s), falling back to ComfyUI /free", e)
        try:
            await queue.http_json("POST", "/free", session, json={"unload_models": True, "free_memory": True})
            return {"method": "comfyui_free"}
        except LazyComfyError as e2:
            raise LazyComfyError("unload_failed", f"Could not unload models: {e2.message}")


def remember_out_dir(prompt_id, out_dir):
    if out_dir:
        _SAVED[prompt_id] = {"out_dir": out_dir, "done": False, "result": None}


def save_outputs(prompt_id, outputs):
    record = _SAVED.get(prompt_id)
    if not record:
        return {"saved": [], "dir": None}
    if record.get("done"):
        return record.get("result") or {"saved": [], "dir": None}
    out_dir = record["out_dir"]
    target = os.path.abspath(os.path.expanduser(out_dir))
    if not os.path.isdir(target):
        record["done"] = True
        record["result"] = {"saved": [], "dir": target, "error": "Directory does not exist"}
        return record["result"]
    base = output_dir()
    if not base:
        record["done"] = True
        record["result"] = {"saved": [], "dir": None, "error": "Cannot resolve the ComfyUI output folder"}
        return record["result"]
    saved = []
    for img in outputs or []:
        src = os.path.join(base, img.get("subfolder") or "", img.get("filename") or "")
        if not os.path.isfile(src):
            continue
        dst = os.path.join(target, os.path.basename(src))
        try:
            shutil.copy2(src, dst)
        except OSError as e:
            logger.warning("LazyComfy: cannot copy %s -> %s: %s", src, dst, e)
            continue
        saved.append(dst)
    record["done"] = True
    record["result"] = {"saved": saved, "dir": target}
    return record["result"]
