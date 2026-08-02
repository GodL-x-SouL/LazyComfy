import asyncio
import logging
import os
import re
import time
import uuid

import aiohttp

from . import LazyComfyError

logger = logging.getLogger("lazycomfy")

try:
    import folder_paths
except Exception:
    folder_paths = None

HUB_BASE = os.environ.get("LAZYCOMFY_HUB_BASE", "https://huggingface.co")
CHUNK_BYTES = 256 * 1024
MAX_RANGE_SPLITS = int(os.environ.get("LAZYCOMFY_DL_SPLITS", "8"))
_MAX_TASKS = 30

CATALOG = []


def _dir_for_kind(kind):
    if kind in ("unet", "uncond"):
        return "diffusion_models"
    if kind == "clip":
        return "text_encoders"
    if kind == "lora":
        return "loras"
    return "vae"


def _add(model_id, kind, label, repo, path, size, note="", gated=False, alt_paths=None):
    item = {
        "id": f"{model_id}:{kind}:{os.path.basename(path)}",
        "model_id": model_id,
        "kind": kind,
        "label": label,
        "repo": repo,
        "path": path,
        "size": int(size),
        "note": note,
        "gated": bool(gated),
        "target_dir": _dir_for_kind(kind),
        "target_name": os.path.basename(path),
        "alt_paths": list(alt_paths or []),
    }
    CATALOG.append(item)


_ZID = "z_image_turbo"
_KID = "krea_2_turbo"
_FID = "flux_2_klein_9b"
_IID = "ideogram_4"

_Z = "Comfy-Org/z_image_turbo"
_K = "Comfy-Org/Krea-2"
_FU = "titomatus0203/flux-2-klein-9b-fp8"
_FT = "Comfy-Org/flux2-klein-9B"
_FV = "black-forest-labs/FLUX.2-small-decoder"
_I = "Comfy-Org/Ideogram-4"

# --- Z Image Turbo (all files under split_files/) ---
_add(_ZID, "unet", "Diffusion model", _Z, "split_files/diffusion_models/z_image_turbo_bf16.safetensors", 12_309_866_400, "Default (BF16) — needs ~16 GB VRAM")
_add(_ZID, "unet", "Diffusion model", _Z, "split_files/diffusion_models/z_image_turbo_int8_convrot.safetensors", 6_201_001_296, "INT8 + convrot — lower VRAM")
_add(_ZID, "unet", "Diffusion model", _Z, "split_files/diffusion_models/z_image_turbo_nvfp4.safetensors", 4_509_509_600, "NVFP4 — smallest, requires RTX 40-series+")
_add(_ZID, "clip", "Text encoder", _Z, "split_files/text_encoders/qwen_3_4b.safetensors", 8_044_982_048, "Default (BF16)")
_add(_ZID, "clip", "Text encoder", _Z, "split_files/text_encoders/qwen_3_4b_fp8_mixed.safetensors", 5_631_994_051, "FP8 mixed")
_add(_ZID, "clip", "Text encoder", _Z, "split_files/text_encoders/qwen_3_4b_fp4_mixed.safetensors", 3_479_416_193, "FP4 mixed — smallest")
_add(_ZID, "vae", "VAE", _Z, "split_files/vae/ae.safetensors", 335_304_388, "Default VAE")
_add(_ZID, "lora", "LoRA", _Z, "split_files/loras/z_image_turbo_distill_patch_lora_bf16.safetensors", 158_826_336, "Distill patch LoRA")

# --- Krea 2 (subfolder layout: diffusion_models/, loras/, text_encoders/, vae/) ---
_add(_KID, "unet", "Diffusion model", _K, "diffusion_models/krea2_turbo_bf16.safetensors", 26_283_332_608, "Turbo BF16 — needs ~26 GB VRAM")
_add(_KID, "unet", "Diffusion model", _K, "diffusion_models/krea2_turbo_fp8_scaled.safetensors", 13_141_730_784, "Turbo FP8 scaled — default")
_add(_KID, "unet", "Diffusion model", _K, "diffusion_models/krea2_turbo_int8_convrot.safetensors", 13_492_686_496, "Turbo INT8 + convrot")
_add(_KID, "unet", "Diffusion model", _K, "diffusion_models/krea2_turbo_mxfp8.safetensors", 13_532_318_080, "Turbo MXFP8")
_add(_KID, "unet", "Diffusion model", _K, "diffusion_models/krea2_turbo_nvfp4.safetensors", 7_673_668_448, "Turbo NVFP4 — smallest")
_add(_KID, "unet", "Diffusion model", _K, "diffusion_models/krea2_raw_bf16.safetensors", 26_283_332_608, "Base RAW (52 steps) — for LoRA training")
_add(_KID, "unet", "Diffusion model", _K, "diffusion_models/krea2_raw_fp8_scaled.safetensors", 13_141_730_784, "Base RAW FP8 — for LoRA training")
_add(_KID, "unet", "Diffusion model", _K, "diffusion_models/krea2_raw_int8_convrot.safetensors", 13_492_686_496, "Base RAW INT8 — for LoRA training")
_add(_KID, "clip", "Text encoder", _K, "text_encoders/qwen3vl_4b_bf16.safetensors", 8_875_719_384, "BF16")
_add(_KID, "clip", "Text encoder", _K, "text_encoders/qwen3vl_4b_fp8_scaled.safetensors", 5_242_467_968, "FP8 scaled — default")
_add(_KID, "vae", "VAE", _K, "vae/qwen_image_vae.safetensors", 253_806_246, "Default VAE (only VAE published for Krea)")
for _style in ("darkbrush", "dotmatrix", "kidsdrawing", "neondrip", "rainywindow", "retroanime", "softwatercolor", "sunsetblur", "vintagetarot"):
    _add(_KID, "lora", "LoRA", _K, f"loras/krea2_{_style}.safetensors", 469_291_992, f"'{_style}' style LoRA")
_add(_KID, "lora", "LoRA", _K, "loras/krea2_turbo_lora_rank_64_bf16.safetensors", 469_423_778, "Turbo LoRA")
_add(_KID, "lora", "LoRA", _K, "loras/krea2_style_reference.safetensors", 457_111_760, "Style reference LoRA")

# --- Flux 2 Klein 9B ---
_add(_FID, "unet", "Diffusion model", _FU, "flux-2-klein-9b-fp8.safetensors", 9_433_061_528, "FP8 distilled — default (ungated mirror, byte-identical to BFL)")
_add(_FID, "clip", "Text encoder", _FT, "split_files/text_encoders/qwen_3_8b.safetensors", 16_381_517_176, "Qwen3-8B BF16 — needs ~16 GB VRAM")
_add(_FID, "clip", "Text encoder", _FT, "split_files/text_encoders/qwen_3_8b_fp8mixed.safetensors", 8_664_848_742, "Qwen3-8B FP8 mixed — default")
_add(_FID, "clip", "Text encoder", _FT, "split_files/text_encoders/qwen_3_8b_fp4mixed.safetensors", 6_802_593_327, "Qwen3-8B FP4 mixed — smallest")
_add(_FID, "vae", "VAE", _FV, "full_encoder_small_decoder.safetensors", 249_519_092, "Full encoder + small decoder — default (ungated)")
_add(_FID, "vae", "VAE", _FT, "split_files/vae/flux2-vae.safetensors", 336_211_292, "Flux2 VAE (same file as Ideogram 4)")

# --- Ideogram 4 ---
_add(_IID, "unet", "Diffusion model", _I, "diffusion_models/ideogram4_fp8_scaled.safetensors", 9_280_741_285, "FP8 — default")
_add(_IID, "unet", "Diffusion model", _I, "diffusion_models/ideogram4_int8_convrot.safetensors", 9_583_465_712, "INT8 + convrot")
_add(_IID, "unet", "Diffusion model", _I, "diffusion_models/ideogram4_nvfp4_mixed.safetensors", 5_490_550_037, "NVFP4 — smallest")
_add(_IID, "uncond", "Unconditional model", _I, "diffusion_models/ideogram4_unconditional_fp8_scaled.safetensors", 9_280_741_293, "FP8 — default (required together with the main model)")
_add(_IID, "uncond", "Unconditional model", _I, "diffusion_models/ideogram4_unconditional_int8_convrot.safetensors", 9_583_465_712, "INT8 + convrot")
_add(_IID, "uncond", "Unconditional model", _I, "diffusion_models/ideogram4_unconditional_nvfp4_mixed.safetensors", 5_490_550_037, "NVFP4 — smallest")
_add(_IID, "clip", "Text encoder", _I, "text_encoders/qwen3vl_8b_fp8_scaled.safetensors", 10_588_637_512, "FP8 — default")
_add(_IID, "vae", "VAE", _I, "vae/flux2-vae.safetensors", 336_211_292, "Default VAE (same file as Flux 2)")

# Rebuild index once
_CATALOG_BY_ID = {item["id"]: item for item in CATALOG}

_TASKS = {}
_LOCK = None


def _lock():
    global _LOCK
    if _LOCK is None:
        _LOCK = asyncio.Lock()
    return _LOCK


def _models_root():
    if folder_paths is not None:
        try:
            dirs = folder_paths.get_folder_paths("diffusion_models")
            if dirs:
                return os.path.dirname(dirs[0])
        except Exception:
            pass
    return os.environ.get("LAZYCOMFY_MODELS_DIR")


def target_path(item):
    if folder_paths is not None:
        try:
            dirs = folder_paths.get_folder_paths(item["target_dir"])
            if dirs:
                return os.path.join(dirs[0], item["target_name"])
        except Exception:
            pass
    root = _models_root()
    if root:
        return os.path.join(root, item["target_dir"], item["target_name"])
    raise LazyComfyError("models_dir_unavailable", "Cannot resolve the models directory")


def item_present(item):
    try:
        return os.path.isfile(target_path(item))
    except LazyComfyError:
        return False


def list_files(dir_name):
    if folder_paths is not None:
        try:
            return folder_paths.get_filename_list(dir_name)
        except Exception:
            pass
    root = os.environ.get("LAZYCOMFY_MODELS_DIR")
    if root:
        base = os.path.join(root, dir_name)
        try:
            return sorted(
                n for n in os.listdir(base)
                if os.path.isfile(os.path.join(base, n)) and n.lower().endswith((".safetensors", ".ckpt", ".pt", ".pth", ".bin"))
            )
        except OSError:
            return []
    return []


def invalidate_dir_cache(dir_name):
    if folder_paths is None:
        return
    try:
        folder_paths.filename_list_cache.pop(dir_name, None)
    except Exception:
        pass


def catalog_payload():
    items = []
    for item in CATALOG:
        entry = {
            "id": item["id"],
            "model_id": item["model_id"],
            "kind": item["kind"],
            "label": item["label"],
            "repo": item["repo"],
            "path": item["path"],
            "size": item["size"],
            "note": item["note"],
            "gated": item["gated"],
            "target_dir": item["target_dir"],
            "target_name": item["target_name"],
            "present": item_present(item),
        }
        items.append(entry)
    tasks = []
    for task in _TASKS.values():
        entry = {
            "id": task["id"],
            "item_id": task["item_id"],
            "target_name": task["target_name"],
            "status": task["status"],
            "downloaded": task["downloaded"],
            "total": task["total"],
            "error": task["error"],
        }
        tasks.append(entry)
    return {"items": items, "tasks": tasks}


def _prune_tasks():
    if len(_TASKS) <= _MAX_TASKS:
        return
    finished = [t for t in _TASKS.values() if t["status"] in ("done", "error", "cancelled")]
    drop = sorted(finished, key=lambda t: t["finished_at"])[: len(_TASKS) - _MAX_TASKS]
    for t in drop:
        _TASKS.pop(t["id"], None)


def _task_from_item(item):
    return {
        "id": uuid.uuid4().hex[:12],
        "item_id": item["id"],
        "target_name": item["target_name"],
        "status": "starting",
        "downloaded": 0,
        "total": item["size"],
        "error": None,
        "finished_at": None,
    }


async def start_download(item_id):
    item = _CATALOG_BY_ID.get(item_id)
    if item is None:
        raise LazyComfyError("unknown_item", f"No catalog item '{item_id}'")
    return _serialize_task(await _launch(item))


def parse_lora_url(url):
    if not isinstance(url, str) or not url.strip():
        raise LazyComfyError("invalid_request", "Paste a Hugging Face file URL (blob or resolve)")
    cleaned = url.strip().split("#")[0].split("?")[0]
    match = re.match(r"^https?://huggingface\.co/([^/\s?]+/[^/\s?]+)/(?:blob|resolve)/([^/\s?]+)/(.+)$", cleaned)
    if not match:
        raise LazyComfyError(
            "invalid_request",
            "Expected a URL like https://huggingface.co/<owner>/<repo>/blob/main/<file>.safetensors",
        )
    repo, _branch, path = match.groups()
    if ".." in repo or ".." in path or not path:
        raise LazyComfyError("invalid_request", "Invalid repository or file path in URL")
    name = os.path.basename(path)
    if not name.lower().endswith((".safetensors", ".ckpt", ".pt", ".pth", ".bin")):
        raise LazyComfyError("invalid_request", "URL must point to a model file (.safetensors, .ckpt, .pt, .pth, .bin)")
    return repo, path, name


async def start_lora_download(url):
    repo, path, name = parse_lora_url(url)
    item = {
        "id": f"custom:{repo}:{name}",
        "model_id": "custom",
        "kind": "lora",
        "label": "LoRA",
        "repo": repo,
        "path": path,
        "size": 0,
        "note": "Custom LoRA download",
        "gated": False,
        "target_dir": "loras",
        "target_name": name,
        "alt_paths": [name],
    }
    return _serialize_task(await _launch(item))


async def _launch(item):
    if item_present(item):
        raise LazyComfyError("already_downloaded", f"'{item['target_name']}' is already installed")
    async with _lock():
        for task in _TASKS.values():
            if task["status"] not in ("starting", "downloading", "cancelling"):
                continue
            if task["item_id"] == item["id"] or task["target_name"] == item["target_name"]:
                raise LazyComfyError("already_downloading", f"'{item['target_name']}' is already being downloaded")
        task = _task_from_item(item)
        task["_item"] = item
        _TASKS[task["id"]] = task
        _prune_tasks()
    asyncio.get_running_loop().create_task(_run(task["id"]))
    return task


def _serialize_task(task):
    return {
        "id": task["id"],
        "item_id": task["item_id"],
        "target_name": task["target_name"],
        "status": task["status"],
        "downloaded": task["downloaded"],
        "total": task["total"],
        "error": task["error"],
    }


def get_task(task_id):
    task = _TASKS.get(task_id)
    return _serialize_task(task) if task else None


def cancel_download(task_id):
    task = _TASKS.get(task_id)
    if task is None or task["status"] not in ("starting", "downloading", "cancelling"):
        return False
    task["status"] = "cancelling"
    return True


class _Cancelled(Exception):
    pass


def _split_count(size):
    if size >= 8 * 1024**3:
        return 8
    if size >= 1024**3:
        return 4
    if size >= 256 * 1024**2:
        return 2
    return 1


def _add_bytes(task, n, total):
    task["downloaded"] = min(task["downloaded"] + n, total)


async def _probe(session, url, target_name):
    async with session.get(url, headers={"Range": "bytes=0-0"}) as resp:
        if resp.status == 404:
            return None, 0
        if resp.status == 206:
            total = 0
            for part in resp.headers.get("Content-Range", "").split("/"):
                if part.isdigit():
                    total = int(part)
                    break
            return True, total
        if resp.status == 200:
            return False, int(resp.headers.get("Content-Length") or 0)
        raise LazyComfyError("download_failed", f"HTTP {resp.status} fetching '{target_name}'")


async def _download_stream(session, url, tmp_path, task, total):
    with open(tmp_path, "wb") as fh:
        async with session.get(url) as resp:
            if resp.status != 200:
                raise LazyComfyError("download_failed", f"HTTP {resp.status} fetching '{task['target_name']}'")
            async for chunk in resp.content.iter_chunked(CHUNK_BYTES):
                if task["status"] == "cancelling":
                    raise _Cancelled()
                fh.write(chunk)
                _add_bytes(task, len(chunk), total)


async def _download_ranges(session, url, tmp_path, total, task):
    splits = min(_split_count(total), MAX_RANGE_SPLITS)
    with open(tmp_path, "wb") as fh:
        fh.truncate(total)
    seg_size = (total + splits - 1) // splits

    async def segment(i):
        start = i * seg_size
        end = min(start + seg_size, total) - 1
        headers = {"Range": f"bytes={start}-{end}"}
        try:
            async with session.get(url, headers=headers) as resp:
                if resp.status != 206:
                    raise LazyComfyError("download_failed", f"HTTP {resp.status} (server ignored range request)")
                with open(tmp_path, "r+b") as fh:
                    fh.seek(start)
                    async for chunk in resp.content.iter_chunked(CHUNK_BYTES):
                        if task["status"] == "cancelling":
                            raise _Cancelled()
                        fh.write(chunk)
                        _add_bytes(task, len(chunk), total)
        except asyncio.CancelledError:
            raise
        except LazyComfyError:
            raise
        except Exception as e:
            raise LazyComfyError("download_failed", str(e))

    segs = [asyncio.create_task(segment(i)) for i in range(splits)]
    try:
        await asyncio.gather(*segs)
    finally:
        for s in segs:
            s.cancel()
        await asyncio.gather(*segs, return_exceptions=True)


async def _run(task_id):
    task = _TASKS.get(task_id)
    if task is None:
        return
    item = task.get("_item") or _CATALOG_BY_ID.get(task["item_id"])
    tmp_path = None
    session = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=None, connect=30))
    try:
        if item is None:
            raise LazyComfyError("unknown_item", f"No catalog item '{task['item_id']}'")
        task["status"] = "downloading"
        target = target_path(item)
        tmp_path = target + ".part"
        candidates = list(item["alt_paths"]) or []
        candidates.insert(0, item["path"])
        candidates.append(f"split_files/{item['target_dir']}/{item['target_name']}")
        candidates.append(f"{item['target_dir']}/{item['target_name']}")
        url_tpl = f"{HUB_BASE}/{item['repo']}/resolve/main/{{}}"
        chosen = None
        for candidate in candidates:
            url = url_tpl.format(candidate)
            try:
                ranges_ok, total = await _probe(session, url, item["target_name"])
            except LazyComfyError:
                raise
            if ranges_ok is None:
                continue
            chosen = (url, ranges_ok, total)
            break
        if chosen is None:
            raise LazyComfyError("download_failed", f"File not found on Hugging Face (HTTP 404, tried {len(candidates)} paths)")
        url, ranges_ok, total = chosen
        if not total:
            total = item["size"]
        task["total"] = total
        if ranges_ok and total > 0 and _split_count(total) > 1:
            await _download_ranges(session, url, tmp_path, total, task)
        else:
            await _download_stream(session, url, tmp_path, task, total)
        os.replace(tmp_path, target)
        tmp_path = None
        task["status"] = "done"
        task["error"] = None
        invalidate_dir_cache(item["target_dir"])
    except _Cancelled:
        task["status"] = "cancelled"
    except LazyComfyError as e:
        task["status"] = "error"
        task["error"] = e.message
        logger.warning("LazyComfy download failed: %s", e.message)
    except Exception as e:
        task["status"] = "error"
        task["error"] = str(e)
        logger.warning("LazyComfy download failed: %s", e)
    finally:
        task["finished_at"] = task.get("finished_at") or time.time()
        await session.close()
        if tmp_path and os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except OSError:
                pass
