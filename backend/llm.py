"""Prompt Forge backend: llama.cpp (llama-server) manager, GGUF utilities,
HuggingFace search, GGUF downloads and streaming OpenAI-style generation.

Mirrors the architecture of ComfyUI-Local-LLM-Assistant: llama-server.exe is
spawned as a subprocess (binaries kept in backend/llama_cpp/) and talked to
over HTTP at http://127.0.0.1:<port>/v1/chat/completions.
"""
import asyncio
import collections
import gc
import json
import logging
import os
import re
import shutil
import socket
import struct
import subprocess
import threading
import time
import uuid
import zipfile
from urllib.parse import quote

import aiohttp

from . import LazyComfyError
from .hub import (CHUNK_BYTES, _Cancelled, _download_ranges, _download_stream,
                  _probe, _split_count)

logger = logging.getLogger("lazycomfy")

try:
    import folder_paths
except Exception:
    folder_paths = None

try:
    import psutil
except Exception:
    psutil = None

_PKG_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_OWN_BIN_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "llama_cpp")
_HF_API = "https://huggingface.co/api"
_HF_UA = {"User-Agent": "Mozilla/5.0 (LazyComfy/1.0)"}
_MAX_IMAGE_BYTES = 15 * 1024 * 1024
_MAX_TASKS = 30
_RELEASE_FALLBACK = "b3524"

SYSTEM_PROMPTS = {
    "enhance": (
        "You are an expert prompt engineer for modern text-to-image models (Flux, Z-Image, Krea, Stable Diffusion). "
        "Rewrite the user's simple prompt into ONE detailed natural-language prompt, written as fluent descriptive English, not tag lists. "
        "Start with the main subject and its specific attributes (appearance, clothing, pose, expression), then the setting and background, "
        "then lighting and atmosphere, color palette, camera angle and framing, and finally the artistic style or medium. "
        "Make every sentence concrete and visual, build detail progressively, and strictly preserve the user's core intent. "
        "Output ONLY the final prompt — no preamble, no explanation, no quotation marks, no extra words."
    ),
    "caption": (
        "You are a vision assistant whose caption will be fed to a text-to-image model to recreate the image almost identically. "
        "Describe the image in exhaustive visual detail: the main subject (identity, appearance, clothing, pose, expression), secondary subjects, "
        "the background and environment, camera angle and framing, lighting, shadows and atmosphere, color palette, textures, composition, mood, "
        "and the artistic style or medium (e.g. candid photo, oil painting, anime, digital illustration). "
        "Follow one consistent level of detail throughout. Output ONLY the caption — no preamble, no commentary."
    ),
    "edit": (
        "You are an expert AI image editor. Given an image and a short edit instruction, produce ONE detailed edit prompt "
        "that a text-to-image model can follow with image-to-image guidance. "
        "State exactly what must change (colors, clothing, background, objects, lighting, style) and explicitly what must be preserved "
        "(subject identity, face, pose, composition, camera angle, lighting direction, key background elements). "
        "Describe the desired final result against the original image, as one natural-language paragraph. "
        "Output ONLY the edit prompt — no preamble, no explanation, no quotation marks."
    ),
}


def _startupinfo():
    si = None
    if os.name == "nt":
        si = subprocess.STARTUPINFO()
        si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    return si


# ---------------------------------------------------------------------------
# Paths / discovery
# ---------------------------------------------------------------------------

def find_llama_bin_dir():
    candidates = []
    env = os.environ.get("LAZYCOMFY_LLAMA_BIN")
    if env:
        candidates.append(env)
    candidates.append(_OWN_BIN_DIR)
    try:
        if folder_paths is not None:
            base = getattr(folder_paths, "base_path", None)
            if base:
                cn = os.path.join(base, "custom_nodes")
                candidates.append(os.path.join(cn, "ComfyUI-Local-LLM-Assistant", "llama_cpp"))
                candidates.append(os.path.join(cn, ".disabled", "ComfyUI-Local-LLM-Assistant", "llama_cpp"))
    except Exception:
        pass
    for d in candidates:
        try:
            if os.path.isfile(os.path.join(d, "llama-server.exe")):
                return d
        except Exception:
            continue
    return None


def llm_gguf_dir():
    env = os.environ.get("LAZYCOMFY_LLM_GGUF_DIR")
    if env:
        return env
    try:
        if folder_paths is not None:
            try:
                dirs = folder_paths.get_folder_paths("llm_gguf")
                if dirs:
                    return dirs[0]
            except Exception:
                pass
            if getattr(folder_paths, "models_dir", None):
                return os.path.join(folder_paths.models_dir, "llm_gguf")
    except Exception:
        pass
    root = os.environ.get("LAZYCOMFY_MODELS_DIR")
    if root:
        return os.path.join(root, "llm_gguf")
    raise LazyComfyError("models_dir_unavailable", "Cannot resolve the models directory (llm_gguf)")


def list_gguf_files():
    d = llm_gguf_dir()
    models, mmprojs = [], []
    try:
        names = sorted(n for n in os.listdir(d) if n.lower().endswith(".gguf"))
    except OSError:
        names = []
    for n in names:
        try:
            size = os.path.getsize(os.path.join(d, n))
        except OSError:
            size = 0
        entry = {"name": n, "size_gb": round(size / (1024**3), 2), "bytes": size}
        (mmprojs if "mmproj" in n.lower() else models).append(entry)
    return models, mmprojs


def _invalidate_gguf_cache():
    try:
        if folder_paths is not None:
            folder_paths.filename_list_cache.pop("llm_gguf", None)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# GGUF header parsing (layer count for auto GPU offload)
# ---------------------------------------------------------------------------

def parse_gguf_header(path):
    """Read llama.block_count / general.architecture from the GGUF metadata."""
    info = {}
    try:
        with open(path, "rb") as f:
            if f.read(4) != b"GGUF":
                return info
            _version, _n_tensors, n_kv = struct.unpack("<IQQ", f.read(20))

            def read_str():
                n = struct.unpack("<Q", f.read(8))[0]
                if n > 64 * 1024 * 1024:
                    raise ValueError("implausible string length")
                return f.read(n).decode("utf-8", "replace")

            def read_val(t):
                if t == 0:
                    return f.read(1)[0]
                if t == 1:
                    return struct.unpack("<b", f.read(1))[0]
                if t == 2:
                    return struct.unpack("<H", f.read(2))[0]
                if t == 3:
                    return struct.unpack("<h", f.read(2))[0]
                if t == 4:
                    return struct.unpack("<I", f.read(4))[0]
                if t == 5:
                    return struct.unpack("<i", f.read(4))[0]
                if t == 6:
                    return struct.unpack("<f", f.read(4))[0]
                if t == 7:
                    return f.read(1)[0] != 0
                if t == 8:
                    return read_str()
                if t in (10, 11, 12):
                    return struct.unpack("<Q" if t == 10 else ("<q" if t == 11 else "<d"), f.read(8))[0]
                if t == 9:
                    at = struct.unpack("<I", f.read(4))[0]
                    count = struct.unpack("<Q", f.read(8))[0]
                    if count > 50_000_000:
                        raise ValueError("implausible array length")
                    if at == 8:
                        return [read_str() for _ in range(count)]
                    size = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 10: 8, 11: 8, 12: 8}.get(at)
                    if size is None:
                        raise ValueError("unsupported array element type")
                    f.read(size * count)
                    return None
                return None

            for _ in range(min(n_kv, 2_000_000)):
                key = read_str()
                t = struct.unpack("<I", f.read(4))[0]
                try:
                    val = read_val(t)
                except Exception:
                    return info
                if key == "llama.block_count" and isinstance(val, int):
                    info["layers"] = val
                    return info
                if key == "general.architecture" and isinstance(val, str):
                    info["architecture"] = val
    except Exception as e:
        logger.debug("LazyComfy: GGUF parse failed for %s: %s", os.path.basename(path), e)
    return info


# ---------------------------------------------------------------------------
# Vision projector auto-detect
# ---------------------------------------------------------------------------

_VISION_KEYWORDS = ("qwen", "gemma", "llava", "minicpm", "vision", "smolvlm")


def find_matching_mmproj(model_path):
    model_name = os.path.basename(model_path).lower()
    try:
        candidates = [n for n in os.listdir(llm_gguf_dir()) if "mmproj" in n.lower() and n.lower().endswith(".gguf")]
    except OSError:
        return ""
    best, best_score = "", 0
    for n in candidates:
        score = sum(4 for kw in _VISION_KEYWORDS if kw in n.lower())
        common = set(re.split(r"[\s._-]+", model_name)) & set(re.split(r"[\s._-]+", n.lower().replace("mmproj", "")))
        score += len(common) * 3
        if score > best_score:
            best, best_score = n, score
    return os.path.join(llm_gguf_dir(), best) if best_score > 0 else ""


# ---------------------------------------------------------------------------
# GPU offload / memory helpers
# ---------------------------------------------------------------------------

def _cuda_available():
    try:
        import torch
        return torch.cuda.is_available()
    except Exception:
        return False


def _calculate_offload_layers(model_path, layers):
    try:
        import torch
        if not torch.cuda.is_available():
            return 0
        free, _total = torch.cuda.mem_get_info()
        if not free:
            return 0
    except Exception:
        return 0
    vram_margin = 1.2 * 1024**3
    usable = free - vram_margin
    try:
        size = os.path.getsize(model_path)
    except OSError:
        return 0
    if size <= 0 or layers <= 0:
        return 0
    bytes_per_layer = (size / layers) * 1.10
    offload = int(usable / bytes_per_layer)
    return max(0, min(layers, offload))


def _mem_info():
    ram_pct, vram_pct = None, None
    if psutil is not None:
        try:
            ram_pct = psutil.virtual_memory().percent
        except Exception:
            pass
    try:
        import torch
        if torch.cuda.is_available():
            free, total = torch.cuda.mem_get_info()
            if total > 0:
                vram_pct = round((1 - free / total) * 100, 1)
    except Exception:
        pass
    return ram_pct, vram_pct


def _free_port():
    for port in range(8089, 8099):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(("127.0.0.1", port))
                return port
            except OSError:
                continue
    raise LazyComfyError("llm_no_port", "No free port found for llama-server")


# ---------------------------------------------------------------------------
# llama-server process manager
# ---------------------------------------------------------------------------

_IDLE_GEN = {"status": "idle", "prompt_tokens": 0, "eval_tokens": 0, "tokens_sec": 0.0, "elapsed_time": 0.0}


class LlamaManager:
    def __init__(self):
        self._lock = asyncio.Lock()
        self.process = None
        self._drain = None
        self.status = "idle"
        self.port = 0
        self.model = ""
        self.mmproj = ""
        self._req_mmproj = ""
        self.gpu_layers_loaded = 0
        self.total_layers = 0
        self.last_error = None
        self.log_lines = collections.deque(maxlen=120)
        self.generation = dict(_IDLE_GEN)
        self._gen_busy = False

    # -- lifecycle ---------------------------------------------------------

    async def start_server(self, model_name, mmproj, context_length):
        async with self._lock:
            alive = self.process is not None and self.process.poll() is None
            if alive and self.model == model_name and self._req_mmproj == mmproj and self.status == "running":
                return
            self._stop_locked()
            self.last_error = None
            model_path = os.path.join(llm_gguf_dir(), model_name)
            if not os.path.isfile(model_path):
                raise LazyComfyError("invalid_request", f"Model file not found: {model_name}")
            bin_dir = find_llama_bin_dir()
            if not bin_dir:
                raise LazyComfyError(
                    "llm_backend_missing",
                    "llama.cpp backend is not installed. Click 'Install backend' in the model panel.",
                )
            exe = os.path.join(bin_dir, "llama-server.exe")
            if not os.path.isfile(exe):
                raise LazyComfyError("llm_backend_missing", "llama-server.exe not found in the backend folder")

            mmproj_path = ""
            if mmproj == "Auto-Detect":
                mmproj_path = find_matching_mmproj(model_path)
            elif mmproj and mmproj != "None":
                p = os.path.join(llm_gguf_dir(), mmproj)
                if os.path.isfile(p):
                    mmproj_path = p
            self._req_mmproj = mmproj
            self.mmproj = os.path.basename(mmproj_path) if mmproj_path else ""
            self.model = model_name

            layers = int(parse_gguf_header(model_path).get("layers") or 32)
            self.total_layers = layers
            offload = _calculate_offload_layers(model_path, layers)
            threads = max(1, os.cpu_count() or 4)
            self.port = _free_port()
            cmd = [
                exe,
                "-m", model_path,
                "-c", str(max(512, min(int(context_length), 65536))),
                "-t", str(threads),
                "-b", "512",
                "--port", str(self.port),
                "-ngl", str(offload),
                "--host", "127.0.0.1",
            ]
            if mmproj_path:
                cmd += ["--mmproj", mmproj_path]
            self.status = "loading"
            self.log_lines.clear()
            try:
                self.process = subprocess.Popen(
                    cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                    cwd=bin_dir,
                    env=dict(os.environ),
                    startupinfo=_startupinfo(),
                )
            except OSError as e:
                self.process = None
                self.status = "failed"
                self.last_error = f"Cannot start llama-server: {e}"
                raise LazyComfyError("llm_load_failed", self.last_error)
            self._drain = threading.Thread(target=self._drain_loop, daemon=True)
            self._drain.start()
            if not await self._wait_health():
                self._stop_locked()
                raise LazyComfyError(
                    "llm_load_failed",
                    self.last_error or "llama-server did not become ready (check the model/mmproj pairing)",
                )
            self.status = "running"
            self.gpu_layers_loaded = offload
            self.generation = dict(_IDLE_GEN)

    def _drain_loop(self):
        while True:
            try:
                line = self.process.stdout.readline()
            except Exception:
                return
            if not line:
                return
            self.log_lines.append(line.rstrip("\r\n"))

    def _tail_log(self, n=8):
        return "\n".join(list(self.log_lines)[-n:])

    async def _wait_health(self):
        url = f"http://127.0.0.1:{self.port}/health"
        timeout = aiohttp.ClientTimeout(total=0.5)
        async with aiohttp.ClientSession(timeout=timeout) as s:
            for _ in range(100):
                if self.process is None or self.process.poll() is not None:
                    self.last_error = self._tail_log() or "llama-server exited unexpectedly"
                    return False
                try:
                    async with s.get(url) as resp:
                        if resp.status == 200:
                            return True
                except Exception:
                    pass
                await asyncio.sleep(0.2)
        self.last_error = "llama-server did not become ready within 20s.\n" + self._tail_log()
        return False

    def _stop_locked(self):
        p = self.process
        if p is not None:
            if p.poll() is None:
                try:
                    p.terminate()
                except Exception:
                    pass
                try:
                    p.wait(timeout=3)
                except Exception:
                    try:
                        p.kill()
                    except Exception:
                        pass
        self.process = None
        self._drain = None
        self.status = "idle"
        self.model = ""
        self.mmproj = ""
        self._req_mmproj = ""
        self.gpu_layers_loaded = 0
        self.total_layers = 0
        self.generation = dict(_IDLE_GEN)
        try:
            if _cuda_available():
                import torch
                torch.cuda.empty_cache()
        except Exception:
            pass
        gc.collect()

    async def stop(self):
        async with self._lock:
            self._stop_locked()
        return {"ok": True}

    # -- generation ---------------------------------------------------------

    async def generate_events(self, request, body):
        mode = body.get("mode")
        if mode not in SYSTEM_PROMPTS:
            raise LazyComfyError("invalid_request", f"Unknown mode '{mode}'")
        model = str(body.get("model") or "").strip()
        if not model:
            raise LazyComfyError("invalid_request", "Select a GGUF model first")
        mmproj = str(body.get("mmproj") or "None")
        ctx = _clamp_int(body.get("context_length"), 512, 65536, 2048)
        temp = _clamp_float(body.get("temperature"), 0.0, 2.0, 0.7)
        top_p = _clamp_float(body.get("top_p"), 0.0, 1.0, 0.9)
        max_tokens = _clamp_int(body.get("max_tokens"), 1, 32768, 512)
        prompt = str(body.get("prompt") or "").strip()
        edit_prompt = str(body.get("edit_prompt") or "").strip()
        image = body.get("image")
        if not isinstance(image, str):
            image = ""
        if image and not image.startswith("data:image/"):
            raise LazyComfyError("invalid_request", "Image must be a base64 data URL")
        if len(image) > _MAX_IMAGE_BYTES:
            raise LazyComfyError("invalid_request", "Image is too large (max ~11 MB)")

        needs_image = mode in ("caption", "edit")
        if needs_image and not image:
            raise LazyComfyError("invalid_request", f"'{mode}' mode requires an image")
        if mode == "edit" and not (edit_prompt or prompt):
            raise LazyComfyError("invalid_request", "Enter an edit instruction")

        if self._gen_busy:
            raise LazyComfyError("generation_busy", "Another generation is still running")
        self._gen_busy = True
        try:
            await self.start_server(model, mmproj, ctx)
            if needs_image and not self.mmproj:
                raise LazyComfyError(
                    "vision_unavailable",
                    f"'{model}' has no vision projector loaded (mmproj set to '{self._req_mmproj or 'None'}'). "
                    "Vision modes require a matching mmproj.",
                )
            content = []
            if mode == "enhance":
                content.append({"type": "text", "text": f"Enhance this prompt: {prompt}"})
            else:
                text = prompt if prompt else ("Describe this image in detail." if mode == "caption" else "")
                if mode == "edit":
                    text = f"Edit Instruction: {edit_prompt or prompt}"
                if text:
                    content.append({"type": "text", "text": text})
                if image:
                    content.append({"type": "image_url", "image_url": {"url": image}})
            messages = [{"role": "system", "content": SYSTEM_PROMPTS[mode]}, {"role": "user", "content": content}]
            payload = {
                "model": model,
                "messages": messages,
                "temperature": temp,
                "top_p": top_p,
                "max_tokens": max_tokens,
                "stream": True,
            }
            url = f"http://127.0.0.1:{self.port}/v1/chat/completions"
            self.generation = {
                "status": "generating",
                "prompt_tokens": max(1, len(json.dumps(messages)) // 4),
                "eval_tokens": 0,
                "tokens_sec": 0.0,
                "elapsed_time": 0.0,
            }
            start = time.time()
            connector = aiohttp.TCPConnector(force_close=True)
            session = aiohttp.ClientSession(
                timeout=aiohttp.ClientTimeout(total=None, connect=30),
                connector=connector,
            )
            try:
                async with session.post(url, json=payload) as resp:
                    if resp.status != 200:
                        try:
                            err = (await resp.text())[:1200]
                        except Exception:
                            err = f"HTTP {resp.status}"
                        self.generation = dict(_IDLE_GEN)
                        yield {"type": "error", "message": f"llama-server error ({resp.status}): {err}"}
                        return
                    buf = ""
                    pieces = []
                    evals = 0
                    done = False
                    async for raw in resp.content.iter_any():
                        if not raw:
                            continue
                        buf += raw.decode("utf-8", "replace")
                        while "\n" in buf:
                            line, buf = buf.split("\n", 1)
                            line = line.strip()
                            if not line.startswith("data:"):
                                continue
                            p = line[5:].strip()
                            if p == "[DONE]":
                                done = True
                                break
                            try:
                                chunk = json.loads(p)
                                delta = (chunk.get("choices") or [{}])[0].get("delta") or {}
                            except Exception:
                                continue
                            text = delta.get("content") or ""
                            if not text:
                                continue
                            pieces.append(text)
                            evals += 1
                            elapsed = time.time() - start
                            stats = {
                                "status": "generating",
                                "prompt_tokens": self.generation["prompt_tokens"],
                                "eval_tokens": evals,
                                "tokens_sec": round(evals / elapsed, 2) if elapsed > 0 else 0.0,
                                "elapsed_time": round(elapsed, 2),
                            }
                            self.generation.update(stats)
                            yield {"type": "chunk", "text": text, "stats": stats}
                        if done:
                            break
                    elapsed = time.time() - start
                    final = {
                        "status": "completed",
                        "prompt_tokens": self.generation["prompt_tokens"],
                        "eval_tokens": evals,
                        "tokens_sec": round(evals / elapsed, 2) if elapsed > 0 else 0.0,
                        "elapsed_time": round(elapsed, 2),
                    }
                    self.generation = final
                    yield {"type": "done", "text": "".join(pieces).strip(), "stats": dict(final)}
            finally:
                await session.close()
        finally:
            self._gen_busy = False

    # -- status -------------------------------------------------------------

    def status_payload(self):
        alive = self.process is not None and self.process.poll() is None
        ram, vram = _mem_info()
        if alive:
            status = self.status
        else:
            status = "idle" if self.status != "failed" else "failed"
        return {
            "status": status,
            "port": self.port if alive else 0,
            "model": self.model if alive else "",
            "mmproj": self.mmproj if alive else "",
            "gpu_layers": self.gpu_layers_loaded if alive else 0,
            "total_layers": self.total_layers,
            "ram_percent": ram,
            "vram_percent": vram,
            "last_error": self.last_error,
            "generation": dict(self.generation) if alive else dict(_IDLE_GEN),
        }


manager = LlamaManager()


def _clamp_int(v, lo, hi, default):
    try:
        return max(lo, min(hi, int(v)))
    except (TypeError, ValueError):
        return default


def _clamp_float(v, lo, hi, default):
    try:
        return max(lo, min(hi, float(v)))
    except (TypeError, ValueError):
        return default


# ---------------------------------------------------------------------------
# HuggingFace search / file listing
# ---------------------------------------------------------------------------

async def hf_search(session, query):
    url = f"{_HF_API}/models?search={quote(query)}&filter=gguf&sort=downloads&direction=-1&limit=20"
    data = None
    for u in (url, url.replace("&filter=gguf", "")):
        try:
            async with session.get(u, headers=_HF_UA) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    break
        except Exception:
            continue
    if data is None:
        raise LazyComfyError("search_failed", "HuggingFace API unreachable")
    out = []
    for m in data:
        if not isinstance(m, dict) or not m.get("id"):
            continue
        out.append({
            "id": m["id"],
            "downloads": m.get("downloads") or 0,
            "likes": m.get("likes") or 0,
            "gated": bool(m.get("gated")),
            "tags": m.get("tags") or [],
            "last_modified": m.get("lastModified"),
        })
    return out


async def hf_files(session, repo_id):
    async with session.get(f"{_HF_API}/models/{quote(repo_id, safe='/')}", headers=_HF_UA) as resp:
        if resp.status == 404:
            raise LazyComfyError("not_found", f"Repository '{repo_id}' not found")
        if resp.status != 200:
            raise LazyComfyError("search_failed", f"HuggingFace API error (HTTP {resp.status})")
        data = await resp.json()
    files = []
    for s in data.get("siblings") or []:
        name = s.get("rfilename") or ""
        if not name.lower().endswith(".gguf"):
            continue
        files.append({
            "name": name,
            "size": s.get("size") or 0,
            "url": f"https://huggingface.co/{repo_id}/resolve/main/{name}",
        })
    files.sort(key=lambda f: f["name"].lower())
    return {"repo_id": repo_id, "gated": bool(data.get("gated")), "files": files}


def _rewrite_hf_url(url):
    cleaned = url.strip().split("#")[0].split("?")[0]
    m = re.match(r"^(https?://huggingface\.co/[^/\s?]+/[^/\s?]+)/(?:blob|resolve)/[^/\s?]+/(.+)$", cleaned)
    if m:
        cleaned = f"{m.group(1)}/resolve/main/{m.group(2)}"
    try:
        from .hub import HUB_BASE
        if HUB_BASE and HUB_BASE != "https://huggingface.co" and cleaned.startswith("https://huggingface.co/"):
            cleaned = HUB_BASE + cleaned[len("https://huggingface.co"):]
    except Exception:
        pass
    return cleaned


# ---------------------------------------------------------------------------
# GGUF downloads (task list, same shape as hub tasks)
# ---------------------------------------------------------------------------

_LLM_TASKS = {}


def _llm_serialize(t):
    return {
        "id": t["id"],
        "item_id": None,
        "target_name": t["target_name"],
        "status": t["status"],
        "downloaded": t["downloaded"],
        "total": t["total"],
        "error": t["error"],
    }


def _prune_llm():
    if len(_LLM_TASKS) <= _MAX_TASKS:
        return
    finished = [t for t in _LLM_TASKS.values() if t["status"] in ("done", "error", "cancelled")]
    for t in sorted(finished, key=lambda t: t.get("finished_at") or 0)[: len(_LLM_TASKS) - _MAX_TASKS]:
        _LLM_TASKS.pop(t["id"], None)


def get_llm_task(task_id):
    t = _LLM_TASKS.get(task_id)
    return _llm_serialize(t) if t else None


def cancel_llm_download(task_id):
    t = _LLM_TASKS.get(task_id)
    if t is None or t["status"] not in ("starting", "downloading", "cancelling"):
        return False
    t["status"] = "cancelling"
    return True


def start_llm_download(url, name):
    raw = (name or "").strip()
    if not raw or "/" in raw or "\\" in raw or ".." in raw:
        raise LazyComfyError("invalid_request", "Invalid file name")
    name = raw
    if not name.lower().endswith(".gguf"):
        raise LazyComfyError("invalid_request", "Only .gguf files can be downloaded")
    url = _rewrite_hf_url(url)
    if not url.startswith(("http://", "https://")):
        raise LazyComfyError("invalid_request", "Invalid download URL")
    d = llm_gguf_dir()
    try:
        os.makedirs(d, exist_ok=True)
    except OSError as e:
        raise LazyComfyError("download_failed", f"Cannot create model folder '{d}': {e}")
    target = os.path.join(d, name)
    if os.path.isfile(target):
        raise LazyComfyError("already_downloaded", f"'{name}' is already downloaded")
    for t in _LLM_TASKS.values():
        if t["target_name"] == name and t["status"] in ("starting", "downloading", "cancelling"):
            raise LazyComfyError("already_downloading", f"'{name}' is already downloading")
    task = {
        "id": uuid.uuid4().hex[:12],
        "target_name": name,
        "url": url,
        "status": "starting",
        "downloaded": 0,
        "total": 0,
        "error": None,
        "finished_at": None,
    }
    _LLM_TASKS[task["id"]] = task
    asyncio.get_running_loop().create_task(_llm_run(task))
    _prune_llm()
    return _llm_serialize(task)


async def _llm_run(task):
    session = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=None, connect=30))
    tmp = None
    try:
        task["status"] = "downloading"
        d = llm_gguf_dir()
        tmp = os.path.join(d, task["target_name"] + ".part")
        ranges_ok, total = await _probe(session, task["url"], task["target_name"])
        if ranges_ok is None:
            raise LazyComfyError("download_failed", f"File not found on Hugging Face (HTTP 404)")
        task["total"] = total or 0
        if ranges_ok and total > 0 and _split_count(total) > 1:
            await _download_ranges(session, task["url"], tmp, total, task)
        else:
            await _download_stream(session, task["url"], tmp, task, total or 0)
        os.replace(tmp, os.path.join(d, task["target_name"]))
        tmp = None
        task["status"] = "done"
        task["error"] = None
        _invalidate_gguf_cache()
    except _Cancelled:
        task["status"] = "cancelled"
    except LazyComfyError as e:
        task["status"] = "error"
        task["error"] = e.message
        logger.warning("LazyComfy llm download failed: %s", e.message)
    except Exception as e:
        task["status"] = "error"
        task["error"] = str(e)
        logger.warning("LazyComfy llm download failed: %s", e)
    finally:
        task["finished_at"] = task.get("finished_at") or time.time()
        await session.close()
        if tmp and os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


# ---------------------------------------------------------------------------
# Backend installer (downloads llama.cpp release binaries on demand)
# ---------------------------------------------------------------------------

_INSTALL = {"status": "idle", "stage": "", "progress": 0, "downloaded": 0, "total": 0, "error": None, "version": None}
_LATEST_RELEASE = {"tag": None, "at": 0.0}


async def _latest_release():
    now = time.time()
    if _LATEST_RELEASE["tag"] and now - _LATEST_RELEASE["at"] < 3600:
        return _LATEST_RELEASE["tag"]
    tag = _RELEASE_FALLBACK
    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=20)) as s:
            async with s.get("https://api.github.com/repos/ggml-org/llama.cpp/releases/latest", headers=_HF_UA) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    if data.get("tag_name"):
                        tag = data["tag_name"]
    except Exception:
        pass
    _LATEST_RELEASE.update(tag=tag, at=now)
    return tag


async def install_backend():
    if _INSTALL["status"] in ("running", "extracting"):
        raise LazyComfyError("install_busy", "Backend installation is already in progress")
    if find_llama_bin_dir():
        _INSTALL.update(status="done", stage="", progress=100, version=_LATEST_RELEASE["tag"], error=None)
        return dict(_INSTALL)
    _INSTALL.update(status="running", stage="resolving release", progress=0, downloaded=0, total=0, error=None)
    try:
        os.makedirs(_OWN_BIN_DIR, exist_ok=True)
        version = await _latest_release()
        _INSTALL["version"] = version
        cuda = _cuda_available()
        zips = [f"llama-{version}-bin-win-cuda-12.4-x64.zip" if cuda else f"llama-{version}-bin-win-cpu-x64.zip"]
        if cuda:
            zips.append(f"cudart-llama-bin-win-cuda-12.4-x64.zip")
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=None)) as s:
            for zip_name in zips:
                url = f"https://github.com/ggml-org/llama.cpp/releases/download/{version}/{zip_name}"
                tmp_zip = os.path.join(_OWN_BIN_DIR, zip_name)
                _INSTALL["stage"] = f"downloading {zip_name}"
                _INSTALL["downloaded"], _INSTALL["total"], _INSTALL["progress"] = 0, 0, 0
                try:
                    async with s.get(url, headers=_HF_UA) as resp:
                        if resp.status != 200:
                            continue
                        total = int(resp.headers.get("Content-Length") or 0)
                        _INSTALL["total"] = total
                        with open(tmp_zip, "wb") as fh:
                            async for chunk in resp.content.iter_chunked(CHUNK_BYTES):
                                fh.write(chunk)
                                _INSTALL["downloaded"] += len(chunk)
                                _INSTALL["progress"] = round(_INSTALL["downloaded"] / total * 100) if total else 0
                except Exception as e:
                    logger.warning("LazyComfy: llama.cpp zip download failed: %s", e)
                    continue
                if os.path.isfile(tmp_zip):
                    _INSTALL["stage"] = "extracting"
                    try:
                        with zipfile.ZipFile(tmp_zip) as z:
                            for m in z.infolist():
                                base = os.path.basename(m.filename)
                                if m.is_dir() or not base.lower().endswith((".exe", ".dll")):
                                    continue
                                with z.open(m) as src, open(os.path.join(_OWN_BIN_DIR, base), "wb") as dst:
                                    shutil.copyfileobj(src, dst)
                    except Exception as e:
                        logger.warning("LazyComfy: llama.cpp zip extract failed: %s", e)
                    try:
                        os.remove(tmp_zip)
                    except OSError:
                        pass
                _INSTALL["progress"] = 100
        if not find_llama_bin_dir():
            raise LazyComfyError(
                "install_failed",
                "Could not obtain llama.cpp binaries from GitHub. Check connectivity or run ComfyUI with "
                "LAZYCOMFY_LLAMA_BIN pointing to a folder containing llama-server.exe.",
            )
        _INSTALL["status"] = "done"
        _INSTALL["stage"] = ""
    except LazyComfyError as e:
        _INSTALL.update(status="error", error=e.message)
    except Exception as e:
        _INSTALL.update(status="error", error=str(e))
        logger.warning("LazyComfy: llama.cpp install failed: %s", e)
    return dict(_INSTALL)


# ---------------------------------------------------------------------------
# Config payload
# ---------------------------------------------------------------------------

async def config_payload(session):
    bin_dir = find_llama_bin_dir()
    models, mmprojs = [], []
    dir_error = None
    try:
        models, mmprojs = list_gguf_files()
    except LazyComfyError as e:
        dir_error = e.message
    return {
        "backend_present": bool(bin_dir),
        "backend_dir": bin_dir,
        "backend_version": _LATEST_RELEASE["tag"],
        "models": models,
        "mmprojs": mmprojs,
        "models_dir_error": dir_error,
        "status": manager.status_payload(),
        "tasks": [_llm_serialize(t) for t in _LLM_TASKS.values()],
        "install": dict(_INSTALL),
    }
