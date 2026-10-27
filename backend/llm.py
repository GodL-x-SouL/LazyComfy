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
import tempfile
import threading
import time
import uuid
import tarfile
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
# Current nightly tag without the API. The rolling "latest" release carries
# this file, so the URL keeps working when llama.cpp bumps its release tag.
_NIGHTLY_TAG_URL = "https://github.com/ggml-org/llama.cpp/releases/latest/download/nightly-tag.txt"

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


def _backend_env(bin_dir):
    """Environment for llama-server: its sibling .so files must win.

    Linux release tarballs have no $ORIGIN rpath, so the loader needs the
    backend folder first even when ComfyUI already injected torch's CUDA
    libraries into LD_LIBRARY_PATH.
    """
    env = dict(os.environ)
    if os.name != "nt":
        prev = env.get("LD_LIBRARY_PATH") or ""
        env["LD_LIBRARY_PATH"] = bin_dir + (os.pathsep + prev if prev else "")
    return env


# ---------------------------------------------------------------------------
# Paths / discovery
# ---------------------------------------------------------------------------

def _server_names():
    if os.name == "nt":
        return ("llama-server.exe", "llama-server")
    return ("llama-server", "llama-server.exe")


def _backend_exe(bin_dir):
    if not bin_dir:
        return None
    for name in _server_names():
        cand = os.path.join(bin_dir, name)
        if os.path.isfile(cand):
            return cand
    return None


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
            if _backend_exe(d):
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

def _detect_hardware():
    """Auto-detect best llama.cpp backend for current OS/GPU. Returns list of zip suffixes to try in order."""
    import platform as _plat
    system = _plat.system().lower()
    machine = _plat.machine().lower()
    # Check for NVIDIA CUDA
    cuda = False
    hip = False
    try:
        import torch
        cuda = torch.cuda.is_available()
        # Check for HIP/ROCm (AMD)
        hip = getattr(torch.version, 'hip', None) is not None
        # Also check for XPU (Intel)
        xpu = getattr(torch, 'xpu', None)
        has_xpu = False
        try:
            has_xpu = xpu.is_available() if xpu else False
        except Exception:
            pass
    except Exception:
        pass

    # Darwin (macOS)
    if system == 'darwin':
        # Apple Silicon vs Intel
        if 'arm' in machine or 'aarch64' in machine:
            return ['macos-arm64', 'macos-x64', 'cpu']
        else:
            return ['macos-x64', 'macos-arm64', 'cpu']

    # Windows / Linux
    candidates = []
    if cuda and not hip:
        # NVIDIA - prefer CUDA 12.4, then 13, then Vulkan, then CPU
        candidates.extend(['cuda-12.4', 'cuda-13.3', 'cuda-12', 'vulkan', 'cpu'])
        # Add cudart as extra (handled separately)
    elif hip:
        # AMD ROCm/HIP - try Vulkan then ROCm/HIP then CPU
        candidates.extend(['vulkan', 'rocm', 'hip', 'cpu'])
    else:
        # No CUDA/HIP - try Vulkan (works on AMD/Intel/NVIDIA via Vulkan) then CPU
        # Check if Vulkan is likely available? We can try to detect via gpu name, but just try Vulkan
        candidates.extend(['vulkan', 'cpu'])

    # Deduplicate and map to zip suffixes
    # For Windows, the zip names are like win-cuda-12.4-x64, win-vulkan-x64, win-cpu-x64, win-sycl-x64
    # For Linux, they are ubuntu-... but we handle via platform check later
    # Return the suffixes
    seen = set()
    uniq = []
    for c in candidates:
        if c not in seen:
            seen.add(c)
            uniq.append(c)
    return uniq


_GPU_ASSET_MARKERS = ("cuda", "vulkan", "rocm", "hip", "sycl", "opencl")


def _asset_is_gpu(asset):
    low = (asset or "").lower()
    return any(m in low for m in _GPU_ASSET_MARKERS)


def _gpu_expected():
    if _cuda_available():
        return True
    return any(shutil.which(t) for t in ("nvidia-smi", "rocm-smi"))


def _list_gpu_devices(exe, bin_dir):
    """Non-CPU devices this build can actually see ([] when it cannot).

    `llama-server --list-devices` initializes each backend and prints e.g.
    `CUDA0: Tesla T4 (15360 MiB, 14900 MiB free)`. A Vulkan/CUDA asset that
    only prints `(none)` would load the whole model on CPU, so the installer
    uses this as the acceptance test instead of just `--version`.
    """
    try:
        p = subprocess.run([exe, "--list-devices"], env=_backend_env(bin_dir),
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
    except Exception:
        return []
    devices = []
    for line in (p.stdout or "").splitlines():
        line = line.strip()
        low = line.lower()
        if not line or low == "available devices:" or low == "(none)":
            continue
        if any(sw in low for sw in ("llvmpipe", "swiftshader", "software rasterizer", "basic render")):
            continue
        if re.match(r"^[A-Za-z][\w.-]*\d+:\s+.+\(\d+\s*MiB", line):
            devices.append(line)
    return devices


def _plan_offload(model_path, layers):
    """(layers_to_request, free_vram_gb_or_None, reason).

    reason is "ok", "no_cuda" (torch sees no GPU at all), or "vram_full"
    (a GPU exists but, after a 1.2 GB safety margin, nothing fits — usually
    diffusion models still resident). Callers must surface the reason: a
    silent 0 previously blamed the server for a request we never made.
    """
    try:
        import torch
        if not torch.cuda.is_available():
            return 0, None, "no_cuda"
        free, _total = torch.cuda.mem_get_info()
        if not free:
            return 0, 0.0, "no_cuda"
    except Exception:
        return 0, None, "no_cuda"
    free_gb = free / 1024**3
    vram_margin = 1.2 * 1024**3
    usable = free - vram_margin
    try:
        size = os.path.getsize(model_path)
    except OSError:
        return 0, free_gb, "vram_full"
    if size <= 0 or layers <= 0:
        return 0, free_gb, "vram_full"
    bytes_per_layer = (size / layers) * 1.10
    offload = int(usable / bytes_per_layer)
    if offload <= 0:
        return 0, free_gb, "vram_full"
    return min(layers, offload), free_gb, "ok"


def _release_comfy_vram(required):
    """Return ComfyUI's VRAM to the driver before llama.cpp measures it.

    torch.cuda.mem_get_info() only sees driver-free memory, so ComfyUI's
    cached blocks (and any idle diffusion model) made a Colab GPU look full.
    That turned every llama.cpp launch into an explicit CPU load. Free
    evictable models when the LLM would not fit, then always drop the torch
    cache so llama.cpp can actually allocate what was released.
    """
    try:
        import comfy.model_management as mm
        dev = mm.get_torch_device()
        if mm.is_device_cuda(dev):
            if mm.get_free_memory(dev) < required:
                mm.free_memory(required, dev)
            mm.soft_empty_cache(force=True)
            return
    except Exception:
        pass
    try:
        import torch
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
    except Exception:
        pass


_HELP_CACHE = {}


def _auto_offload_args(exe, bin_dir):
    """llama.cpp's own VRAM fitting, or [] for builds that predate it.

    Newer llama-server accepts -ngl auto/--fit and reserves a safety margin
    itself. An exact -ngl 0 from our old free-VRAM estimate was the reason a
    working CUDA/Vulkan build still loaded every layer on CPU.
    """
    try:
        mtime = os.path.getmtime(exe)
    except OSError:
        return []
    hit = _HELP_CACHE.get(exe)
    if hit and hit[0] == mtime:
        text = hit[1]
    else:
        try:
            p = subprocess.run([exe, "--help"], env=_backend_env(bin_dir),
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
            text = p.stdout or ""
        except Exception:
            text = ""
        _HELP_CACHE[exe] = ((mtime,), text)
    ngl = re.search(r"-ngl,.*?(?=\n-|\Z)", text, re.S)
    if "--fit" in text and ngl and "'auto'" in ngl.group(0):
        return ["-ngl", "auto", "--fit", "on"]
    return []


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
        self._placement_note = ""
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
            exe = _backend_exe(bin_dir)
            if exe is None:
                raise LazyComfyError("llm_backend_missing", "llama-server binary not found in the backend folder")
            gpu_expected = _gpu_expected()
            gpu_devices = _list_gpu_devices(exe, bin_dir) if gpu_expected else []
            if gpu_expected and not gpu_devices:
                build = _asset_pattern(_manifest_asset(bin_dir)) or "unknown build"
                raise LazyComfyError(
                    "llm_backend_missing",
                    f"Installed llama.cpp backend ({build}) cannot see the GPU. "
                    "Click 'Install backend' to download a GPU build.",
                )

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
            try:
                model_bytes = os.path.getsize(model_path)
            except OSError:
                model_bytes = 0
            _release_comfy_vram(model_bytes)
            auto_ngl = _auto_offload_args(exe, bin_dir)
            if auto_ngl:
                offload, offload_free_gb, offload_reason = layers, None, "auto"
            else:
                offload, offload_free_gb, offload_reason = _plan_offload(model_path, layers)
            threads = max(1, os.cpu_count() or 4)
            self.port = _free_port()
            cmd = [
                exe,
                "-m", model_path,
                "-c", str(max(512, min(int(context_length), 65536))),
                "-t", str(threads),
                "-b", "512",
                "--port", str(self.port),
            ]
            # Let llama.cpp fit layers to the VRAM that is actually free;
            # older builds still get the numeric estimate.
            cmd += auto_ngl if auto_ngl else ["-ngl", str(offload)]
            cmd += ["--host", "127.0.0.1"]
            if mmproj_path:
                cmd += ["--mmproj", mmproj_path]
            self.status = "loading"
            self.log_lines.clear()
            self._placement_note = ""
            build = _asset_pattern(_manifest_asset(bin_dir)) or "unknown"
            self.log_lines.append(
                f"lazycomfy: backend={build} devices={'; '.join(gpu_devices) or 'none'} "
                f"offload={'auto' if auto_ngl else str(offload)}"
            )
            child_env = _backend_env(bin_dir)
            try:
                self.process = subprocess.Popen(
                    cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                    cwd=bin_dir,
                    env=child_env,
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
            # Believe the server log, not the request: a CUDA build whose
            # driver cannot init it silently lands everything on CPU. A load
            # that offloaded anything always prints the offloaded layer count,
            # so a missing line is a CPU load too.
            logs = list(self.log_lines)
            actual, note = _parse_placement(logs)
            if actual == 0:
                note = note or "llama.cpp placed all layers on CPU (no usable GPU or not enough free VRAM; see Server log)"
            elif actual is None and note is None:
                if offload_reason == "vram_full":
                    note = (f"only {offload_free_gb:.1f} GB VRAM free — llama.cpp reported no GPU offload; "
                            "unload diffusion models first, then reload")
                elif offload_reason == "no_cuda":
                    note = "torch sees no CUDA device, so no GPU offload was requested (see Server log)"
                else:
                    note = "server reported no GPU offload (see Server log)"
            self.gpu_layers_loaded = min(actual, layers) if actual is not None else 0
            self._placement_note = (note or "") if self.gpu_layers_loaded == 0 else ""
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

    @staticmethod
    def _hint_missing_libs(tail):
        # A partial/old install can leave llama-server without its sibling .so
        # files; the binary then dies instantly with a loader error. The fix
        # is a clean reinstall, so say so instead of printing the raw log.
        low = (tail or "").lower()
        if "shared librar" in low or "libllama" in low or ".so" in low or ".dll" in low:
            return (
                tail + "\nShared libraries are missing next to llama-server — delete the backend "
                "folder and hit Install backend again to fetch a complete build."
            )
        return tail

    async def _wait_health(self):
        url = f"http://127.0.0.1:{self.port}/health"
        timeout = aiohttp.ClientTimeout(total=0.5)
        # First load after an install has to read the GGUF (and mmproj) from
        # disk and initialize the CUDA backend. On Colab that can take well
        # past 20s, so wait longer; a crashed process still returns at once.
        wait_s = 180
        async with aiohttp.ClientSession(timeout=timeout) as s:
            for _ in range(wait_s * 5):
                if self.process is None or self.process.poll() is not None:
                    self.last_error = self._hint_missing_libs(self._tail_log() or "llama-server exited unexpectedly")
                    return False
                try:
                    async with s.get(url) as resp:
                        if resp.status == 200:
                            return True
                except Exception:
                    pass
                await asyncio.sleep(0.2)
        self.last_error = f"llama-server did not become ready within {wait_s}s.\n" + self._tail_log()
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
        self._placement_note = ""
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
            "placement_note": self._placement_note if alive else "",
            "log_tail": self._tail_log(15) if alive else "",
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
    # The model page siblings never carry blob sizes, so fill them from
    # the repo tree (one call per expansion; ignored on any failure).
    if any(not f["size"] for f in files):
        try:
            async with session.get(
                f"{_HF_API}/models/{quote(repo_id, safe='/')}/tree/main?recursive=True",
                headers=_HF_UA,
            ) as tresp:
                if tresp.status == 200:
                    sizes = {
                        (e.get("path") or ""): e.get("size") or 0
                        for e in (await tresp.json() or [])
                        if isinstance(e, dict) and e.get("type") == "file"
                    }
                    for f in files:
                        if not f["size"]:
                            f["size"] = sizes.get(f["name"]) or 0
        except Exception:
            pass
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
_LATEST_RELEASE = {"tag": None, "at": 0.0}  # cleared so _latest_release() re-fetches


async def _latest_release():
    now = time.time()
    if _LATEST_RELEASE["tag"] and now - _LATEST_RELEASE["at"] < 3600:
        return _LATEST_RELEASE["tag"]
    if _LATEST_RELEASE.get("fail_at") and now - _LATEST_RELEASE["fail_at"] < 60:
        return None
    tag = None

    def good(t):
        return bool(t) and bool(re.match(r"^b\d+$", t.strip()))

    async def fetch_text(s, url, tries=3):
        for i in range(tries):
            try:
                async with s.get(url, headers=_HF_UA) as nr:
                    if nr.status == 200:
                        t = (await nr.read()).decode("utf-8").strip()
                        if good(t):
                            return t
            except Exception:
                pass
            await asyncio.sleep(1.0 * (i + 1))
        return None

    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=20)) as s:
            # Fast path, no API quota needed — validated strictly.
            tag = await fetch_text(s, _NIGHTLY_TAG_URL, tries=2)
            if not tag:
                async with s.get("https://api.github.com/repos/ggml-org/llama.cpp/releases/latest", headers=_HF_UA) as resp:
                    if resp.status == 200:
                        data = await resp.json()
                        maybe = data.get("tag_name")
                        if good(maybe):
                            tag = maybe.strip()
                        elif maybe and maybe.startswith("v"):
                            for a in data.get("assets") or []:
                                if a.get("name") == "nightly-tag.txt" and a.get("browser_download_url"):
                                    tag = await fetch_text(s, a["browser_download_url"])
                                    break
    except Exception:
        pass
    if good(tag):
        _LATEST_RELEASE.update(tag=tag.strip(), at=now)
        return _LATEST_RELEASE["tag"]
    _LATEST_RELEASE.update(tag=None, at=0.0, fail_at=now)
    return None


async def _release_assets(s, tag):
    """Exact asset filenames for a release tag (None when the API is unreachable)."""
    try:
        async with s.get(f"https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/{tag}", headers=_HF_UA) as resp:
            if resp.status != 200:
                return None
            data = await resp.json()
            return [a.get("name") for a in data.get("assets") or [] if a.get("name")]
    except Exception:
        return None


def _on_colab():
    """True on a Google Colab runtime (env markers or importable hook)."""
    try:
        if os.environ.get("COLAB_RELEASE_TAG") or os.environ.get("COLAB_GPU"):
            return True
        import google.colab  # noqa: F401
        return True
    except Exception:
        return False


def _candidate_patterns(system, machine, hw_list):
    """Ordered (pattern, ext) pairs, most suitable build first."""
    arm = "arm64" in machine or "aarch64" in machine
    arch = "arm64" if arm else "x64"
    if system == "windows":
        pats = []
        if any(h.startswith("cuda") for h in hw_list):
            pats += [(f"win-cuda-12.8-{arch}", ".zip"), (f"win-cuda-13.4-{arch}", ".zip")]
        pats += [(f"win-vulkan-{arch}", ".zip"), (f"win-cpu-{arch}", ".zip")]
        return pats
    if system == "darwin":
        return [(f"macos-{arch}", ".tar.gz")]
    pats = []
    if any(h.startswith("cuda") for h in hw_list):
        if _on_colab():
            # Colab T4: CUDA is the native backend. Vulkan stays as a
            # fallback for runtimes whose NVIDIA driver has no Vulkan ICD.
            pats += [(f"ubuntu-cuda-12.8-{arch}", ".tar.gz"),
                     (f"ubuntu-cuda-13.4-{arch}", ".tar.gz"),
                     (f"ubuntu-vulkan-{arch}", ".tar.gz")]
        else:
            # Oldest CUDA first: a 13.x binary refuses to init on drivers that
            # only support 12.x (silent CPU fallback at load), while 12.8 runs
            # on both old and new drivers. Driver-newer builds stay as fallback.
            pats += [(f"ubuntu-cuda-12.8-{arch}", ".tar.gz"), (f"ubuntu-cuda-13.4-{arch}", ".tar.gz")]
    if "rocm" in hw_list or "hip" in hw_list:
        pats.append(("ubuntu-rocm", ".tar.gz"))
    if not any("vulkan" in p for p, _ in pats):
        pats.append((f"ubuntu-vulkan-{arch}", ".tar.gz"))
    pats.append((f"ubuntu-{arch}", ".tar.gz"))
    return pats


def _driver_max_cuda():
    """Max CUDA version the NVIDIA driver supports, from nvidia-smi, or None.

    A cuda-13.x build cannot init on a driver that maxes out at 12.x, so the
    installer skips those assets instead of landing a CPU-fallback backend.
    Fail-open: anything unparseable keeps all candidates.
    """
    try:
        p = subprocess.run(["nvidia-smi"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           text=True, timeout=15)
        m = re.search(r"CUDA Version:\s*(\d+)(?:\.(\d+))?", p.stdout or "")
        if m:
            return (int(m.group(1)), int(m.group(2) or 0))
    except Exception:
        pass
    return None


_OFFLOAD_RE = re.compile(
    r"(?:llm_load_tensors|load_tensors|load)\s*:\s*offload(?:ed|ing)\s+(\d+)(?:\s*/\s*\d+)?\s+(?:repeating\s+)?layers?\s+to\s+GPU",
    re.IGNORECASE)
_GPU_FAIL_RES = (
    re.compile(r"cuda.{0,50}?\b(fail|error|unavailable|not available|no device|disabled)\b", re.IGNORECASE),
    re.compile(r"\b(failed to initialize cuda|cannot initialize cuda|ggml_cuda_init.*fail|using cpu|falling back to cpu|no gpu|without gpu|gpu unavailable|gpu not |device not found|no usable gpu|compiled without gpu support)\b",
               re.IGNORECASE),
)


def _parse_placement(lines):
    """Actual GPU offload from llama-server stdout: (layers|None, note|None).

    layers comes from the server's own "offloaded N/N layers to GPU" line;
    note is the first GPU-failure line, if any. Both are None when the build
    printed neither, which means it did not offload (caller reports CPU).
    """
    layers = None
    for line in lines:
        m = _OFFLOAD_RE.search(line or "")
        if m:
            layers = int(m.group(1))
    note = None
    for line in lines:
        if line and any(rx.search(line) for rx in _GPU_FAIL_RES):
            note = line.strip()[:200]
            break
    return layers, note


def _match_assets(patterns, version, names):
    """Resolve each pattern to an exact asset filename."""
    out = []
    for pat, ext in patterns:
        pick = None
        if names:
            for n in names:
                # Only the main release archives. The cudart companions also
                # contain e.g. "ubuntu-cuda-12.8-x64" and sort first, which
                # made the installer extract a runtime-only tarball as the
                # server build ("binary missing after extract").
                if not n.startswith("llama-") or not n.endswith(ext):
                    continue
                if pat in n:
                    pick = n
                    break
        if pick is None:
            pick = f"llama-{version}-bin-{pat}{ext}"
        if pick not in out:
            out.append(pick)
    return out


def _cudart_companions(system, asset):
    """Runtime companion assets for a CUDA build (best effort, may 404)."""
    if "-cuda-" not in asset or not asset.startswith("llama-"):
        return []
    out = ["cudart-" + asset]
    if system == "windows":
        out += ["cudart-llama-bin-win-cuda-13.4-x64.zip", "cudart-llama-bin-win-cuda-12.4-x64.zip"]
    return out


_MANIFEST = ".lazycomfy_manifest"


def _extract_archive(tmp_path, dest_dir, asset=None):
    """Unpack a llama.cpp zip/tarball, flattening binaries and shared libs.

    Two passes: regular files first (basenames flattened into dest_dir),
    then symlinks re-created against the extracted basenames. Release
    tarballs lay libs out as link chains (libllama.so -> libllama.so.0);
    dropping the links left "complete" installs whose loader could not find
    the SONAME entry. A manifest of extracted files backs the usability check.
    """
    win = os.name == "nt"

    def keep(base):
        low = base.lower()
        if win:
            return low.endswith((".exe", ".dll"))
        return (
            low in ("llama-server", "llama-cli", "llama-batched", "llama-parallel", "llama-eval-callback")
            or "." not in low
            or low.endswith(".so")
            or ".so." in low
            or low.endswith(".dylib")
        )

    kept = []

    def store(base, src):
        dst = os.path.join(dest_dir, base)
        with open(dst, "wb") as fh:
            shutil.copyfileobj(src, fh)
        if not win:
            try:
                os.chmod(dst, 0o755)
            except OSError:
                pass
        kept.append(base)

    links = []  # (link_basename, target_basename)

    def add_link(name, target):
        base = os.path.basename(name)
        if not base or not keep(base):
            return
        tbase = os.path.basename(target or "")
        # Same-dir relative links only: never absolute paths or ../ escapes,
        # the flattened layout keeps a single dir.
        if not tbase or os.path.isabs(target) or ".." in target.replace("\\", "/").split("/"):
            return
        links.append((base, tbase))

    def apply_links():
        have = set(kept)
        for base, tbase in links:
            if tbase not in have:
                continue
            dst = os.path.join(dest_dir, base)
            try:
                if os.path.lexists(dst):
                    os.remove(dst)
                os.symlink(tbase, dst)
                kept.append(base)
            except OSError:
                pass

    if tmp_path.endswith(".zip"):
        with zipfile.ZipFile(tmp_path) as z:
            for m in z.infolist():
                if m.is_dir():
                    continue
                base = os.path.basename(m.filename)
                if not base or not keep(base):
                    continue
                if (m.external_attr >> 16) & 0o170000 == 0o120000:
                    try:
                        add_link(m.filename, z.open(m).read().decode("utf-8", "ignore").strip())
                    except Exception:
                        pass
                    continue
                with z.open(m) as src:
                    store(base, src)
            apply_links()
    else:
        with tarfile.open(tmp_path, "r:*") as t:
            for m in t.getmembers():
                if m.issym() or m.islnk():
                    add_link(m.name, m.linkname)
                    continue
                if not m.isfile():
                    continue
                base = os.path.basename(m.name)
                if not base or not keep(base):
                    continue
                src = t.extractfile(m)
                if src is None:
                    continue
                with src:
                    store(base, src)
            apply_links()
    try:
        # Union with any files a companion extraction already recorded; the
        # main asset's record wins for the build-identity check below.
        existing = []
        mpath = os.path.join(dest_dir, _MANIFEST)
        if os.path.isfile(mpath):
            with open(mpath) as fh:
                for line in fh:
                    line = line.strip()
                    if line and not line.startswith("#"):
                        existing.append(line)
        record = asset or _manifest_asset(dest_dir)
        with open(mpath, "w") as fh:
            if record:
                fh.write(f"# asset: {record}\n")
            fh.write("\n".join(sorted(set(existing) | set(kept))))
    except OSError:
        pass


def _manifest_asset(bin_dir):
    try:
        with open(os.path.join(bin_dir, _MANIFEST)) as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("# asset:"):
                    return line.split(":", 1)[1].strip() or None
    except OSError:
        pass
    return None


def _asset_pattern(asset):
    """Build-pattern part of an asset name (version-agnostic).

    llama-b11429-bin-ubuntu-cuda-12.8-x64.tar.gz -> ubuntu-cuda-12.8-x64,
    so installs stay valid across nightlies while wrong-build choices
    (cuda-13.x on a 12.x driver) still trigger repair.
    """
    base = asset or ""
    if "-bin-" in base:
        base = base.split("-bin-", 1)[1]
    for ext in (".tar.gz", ".zip"):
        if base.endswith(ext):
            base = base[: -len(ext)]
    return base


def _install_matches(bin_dir, picks):
    """Does this install hold one of the assets we would pick today?

    Our own dir without an asset record (legacy), or holding a build we no
    longer prefer (e.g. cuda-13.x on a 12.x-max driver), is reinstalled into
    a wiped dir. User/third-party dirs are never touched.
    """
    if os.path.abspath(bin_dir) != os.path.abspath(_OWN_BIN_DIR):
        return True
    asset = _manifest_asset(bin_dir)
    if not asset:
        return False
    wanted = {p for p, _e in picks}
    return _asset_pattern(asset) in wanted


def _wipe_own_dir():
    """Empty our managed backend dir so old-build .so files cannot shadow the
    new binary (mixed-version .so soup silently breaks CUDA init). Only ever
    touches our own non-symlinked llama_cpp dir, after a verified download."""
    target = os.path.abspath(_OWN_BIN_DIR)
    if os.path.realpath(target) != target:
        return
    if os.path.basename(target) != "llama_cpp":
        return
    shutil.rmtree(target, ignore_errors=True)
    os.makedirs(target, exist_ok=True)


_USABLE_CACHE = {}


def _run_version_probe(exe, bin_dir):
    """Run `llama-server --version`; return (ok, note).

    ok is whether it started cleanly. note is the last stderr/stdout line
    (usually the loader error: missing .so, GLIBC, CUDA init failure) so a
    failed install can say WHY instead of "nothing downloaded".
    """
    try:
        p = subprocess.run([exe, "--version"], env=_backend_env(bin_dir), stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True, timeout=30)
        out = (p.stdout or "").strip().splitlines()
        tail = out[-1].strip()[:180] if out else ""
        if p.returncode == 0:
            return True, ""
        return False, tail or f"exit code {p.returncode}"
    except Exception as e:
        return False, f"{type(e).__name__}: {e}"[:180]


def _backend_usable(bin_dir):
    """True only if llama-server is present AND can actually start.

    "Binary exists" lied for partial installs (truncated downloads, dropped
    .so links) and stale dirs, so installs reported done and loads died with
    loader errors. Ground truth is a real `--version` probe; when our
    manifest exists its files must all be present too. Probed once per binary
    mtime, status polls reuse the cached verdict.
    """
    if not bin_dir:
        return False
    exe = _backend_exe(bin_dir)
    if exe is None:
        return False
    try:
        mtime = os.path.getmtime(exe)
    except OSError:
        return False
    hit = None
    ok = False
    key = (mtime, None)
    try:
        man = os.path.join(bin_dir, _MANIFEST)
        sig_files = None
        if os.path.isfile(man):
            with open(man) as fh:
                # Skip the "# asset: ..." header line: it is build identity,
                # not a file, and treating it as one failed every install.
                names = [line.strip() for line in fh.read().splitlines()
                         if line.strip() and not line.strip().startswith("#")]
            if not names:
                _USABLE_CACHE[exe] = ((mtime,), False)
                return False
            sig = []
            for n in names:
                full = os.path.join(bin_dir, n)
                # exists() follows links: a dangling .so chain fails here.
                if not os.path.exists(full):
                    _USABLE_CACHE[exe] = ((mtime,), False)
                    return False
                try:
                    st = os.stat(full)
                    sig.append((n, st.st_size, int(st.st_mtime)))
                except OSError:
                    _USABLE_CACHE[exe] = ((mtime,), False)
                    return False
            sig_files = tuple(sig)
        key = (mtime, sig_files)
        hit = _USABLE_CACHE.get(exe)
        if hit and hit[0] == key:
            return hit[1]
        ok, _note = _run_version_probe(exe, bin_dir)
        if ok and _gpu_expected() and not _list_gpu_devices(exe, bin_dir):
            ok = False
    except Exception:
        ok = False
    _USABLE_CACHE[exe] = (key, ok)
    return ok


async def install_backend():
    if _INSTALL["status"] in ("running", "extracting"):
        raise LazyComfyError("install_busy", "Backend installation is already in progress")
    import platform as _plat2
    system = _plat2.system().lower()
    machine = _plat2.machine().lower()
    hw_list = _detect_hardware()
    patterns = _candidate_patterns(system, machine, hw_list)
    gpu_host = _gpu_expected()
    drv = _driver_max_cuda()
    if drv and drv < (13, 0):
        dropped = [p for p, _e in patterns if "cuda-13" in p]
        if dropped:
            logger.info(f"LazyComfy: driver max CUDA {drv[0]}.{drv[1]}, skipping 13.x assets: {dropped}")
        patterns = [(p, e) for p, e in patterns if "cuda-13" not in p]
    found = find_llama_bin_dir()
    usable_now = bool(found) and _backend_usable(found)
    version = await _latest_release()
    _INSTALL["version"] = version
    picks = []
    if version:
        try:
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=30)) as s:
                picks = _match_assets(patterns, version, await _release_assets(s, version))
        except Exception:
            picks = []
    if usable_now and (not version or _install_matches(found, picks)):
        _INSTALL.update(status="done", stage="", progress=100, version=_LATEST_RELEASE["tag"], error=None)
        return dict(_INSTALL)
    if not version:
        raise LazyComfyError(
            "install_failed",
            "Could not resolve the latest llama.cpp release (GitHub is unreachable). "
            "Check connectivity or run ComfyUI with LAZYCOMFY_LLAMA_BIN pointing to a folder "
            "containing the llama-server binary.",
        )
    _INSTALL.update(status="running", stage="downloading backend", progress=0, downloaded=0, total=0, error=None)
    try:
        staging = os.path.join(tempfile.gettempdir(), "lazycomfy_llama_dl")
        os.makedirs(staging, exist_ok=True)
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=None)) as s:
            candidates = picks or _match_assets(patterns, version, None)
            logger.info(f"LazyComfy: detected hardware {hw_list} on {system}, trying assets: {candidates}")
            tried = []

            async def fetch_to_staging(asset):
                # Parallel ranged segments (like the model downloader) — GitHub
                # release artifacts serve ranges, so N connections beat one
                # slow single stream by a wide margin. Returns the staged file
                # path, or None (reason appended to tried).
                url = f"https://github.com/ggml-org/llama.cpp/releases/download/{version}/{asset}"
                tmp_file = os.path.join(staging, os.path.basename(asset))
                _INSTALL["stage"] = f"downloading {asset}"
                _INSTALL["downloaded"], _INSTALL["total"], _INSTALL["progress"] = 0, 0, 0
                try:
                    supported, total = await _probe(s, url, asset)
                except LazyComfyError as e:
                    tried.append(f"{asset} ({e.message})")
                    return None
                except Exception:
                    tried.append(f"{asset} (error)")
                    return None
                if supported is None:
                    tried.append(f"{asset} (HTTP 404)")
                    return None
                _INSTALL["total"] = total
                task = {"status": "downloading", "downloaded": 0, "target_name": asset}
                stop = False

                async def pump():
                    while not stop:
                        _INSTALL["downloaded"] = task.get("downloaded", 0)
                        _INSTALL["progress"] = round(task["downloaded"] / total * 100) if total else 0
                        await asyncio.sleep(0.3)

                pump_task = asyncio.create_task(pump())
                try:
                    if supported and total >= 8 * 1024 * 1024:
                        await _download_ranges(s, url, tmp_file, total, task)
                    else:
                        await _download_stream(s, url, tmp_file, task, total)
                except LazyComfyError as e:
                    tried.append(f"{asset} ({e.message})")
                    try:
                        os.remove(tmp_file)
                    except OSError:
                        pass
                    return None
                except Exception:
                    tried.append(f"{asset} (error)")
                    try:
                        os.remove(tmp_file)
                    except OSError:
                        pass
                    return None
                finally:
                    stop = True
                    pump_task.cancel()
                    try:
                        await asyncio.gather(pump_task, return_exceptions=True)
                    except Exception:
                        pass
                _INSTALL["downloaded"] = task.get("downloaded", 0)
                _INSTALL["progress"] = 100
                if not os.path.isfile(tmp_file):
                    return None
                if total and task.get("downloaded", 0) < total:
                    # Truncated assembly (slow networks): extracting this
                    # yields a binary without its libs. Drop it, try next.
                    tried.append(f"{asset} (incomplete: {task.get('downloaded', 0)}/{total} bytes)")
                    try:
                        os.remove(tmp_file)
                    except OSError:
                        pass
                    return None
                return tmp_file

            got = None
            for asset in candidates:
                _INSTALL["stage"] = f"downloading {asset}"
                main_tmp = await fetch_to_staging(asset)
                if not main_tmp:
                    continue
                comps = []
                for comp in _cudart_companions(system, asset):
                    t = await fetch_to_staging(comp)
                    if t:
                        comps.append((comp, t))
                _INSTALL["stage"] = "extracting"
                _wipe_own_dir()
                try:
                    _extract_archive(main_tmp, _OWN_BIN_DIR, asset)
                    for _comp, t in comps:
                        _extract_archive(t, _OWN_BIN_DIR)
                except Exception as e:
                    tried.append(f"{asset} (extract failed: {e})")
                else:
                    _INSTALL["progress"] = 100
                    _bd = _OWN_BIN_DIR
                    _exe = _backend_exe(_bd)
                    _ok, _note = _run_version_probe(_exe, _bd) if _exe else (False, "binary missing after extract")
                    if _ok and gpu_host and not _list_gpu_devices(_exe, _bd):
                        _ok = False
                        _note = "CPU-only build" if not _asset_is_gpu(asset) else "no GPU devices visible"
                    if _ok:
                        got = asset
                    elif _note in ("no GPU devices visible", "CPU-only build"):
                        tried.append(f"{asset} ({_note})")
                    else:
                        # A downloaded+extracted binary that will not start is
                        # the common case (missing companion libs, driver too
                        # old for the CUDA build). Record WHY so the final
                        # error names it instead of "nothing downloaded".
                        tried.append(f"{asset} (binary would not start{': ' + _note if _note else ''})")
                for _t in [main_tmp] + [t for _c, t in comps]:
                    try:
                        os.remove(_t)
                    except OSError:
                        pass
                if got:
                    break
            if not got:
                raise LazyComfyError(
                    "install_failed",
                    "Could not obtain a working llama.cpp backend from GitHub "
                    f"(release {version}, tried: {'; '.join(tried) or 'nothing downloaded'}). "
                    "Check connectivity or run ComfyUI with LAZYCOMFY_LLAMA_BIN pointing to a folder "
                    "containing the llama-server binary.",
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
    asset = _manifest_asset(bin_dir) if bin_dir else None
    models, mmprojs = [], []
    dir_error = None
    try:
        models, mmprojs = list_gguf_files()
    except LazyComfyError as e:
        dir_error = e.message
    return {
        "backend_present": bool(bin_dir) and _backend_usable(bin_dir),
        "backend_dir": bin_dir,
        "backend_build": _asset_pattern(asset) if asset else "",
        "backend_version": _LATEST_RELEASE["tag"],
        "models": models,
        "mmprojs": mmprojs,
        "models_dir_error": dir_error,
        "status": manager.status_payload(),
        "tasks": [_llm_serialize(t) for t in _LLM_TASKS.values()],
        "install": dict(_INSTALL),
    }
