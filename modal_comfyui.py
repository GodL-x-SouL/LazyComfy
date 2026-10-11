"""LazyComfy + ComfyUI on Modal (replaces EasyComfy.ipynb for Modal).

What this does (mirrors EasyComfy.ipynb):
  1. Clones latest ComfyUI, ComfyUI-Manager and LazyComfy onto EPHEMERAL
     container storage and installs requirements at container startup.
     Heavy deps (CUDA torch) are baked into the Modal Image, so rebuilds
     reuse cached layers and repeat runs skip re-downloading them.
  2. Creates (if missing) and mounts the persistent Volume
     ``comfyui-persistent``. Inputs, outputs and models live there.
  3. Exposes ComfyUI through Modal's own tunnel (no cloudflared needed).

Storage layout (privacy-first):
  <volume>/input/    <->  ComfyUI --input-directory   (read/written DIRECTLY,
  <volume>/output/   <->  ComfyUI --output-directory   never copied to the
                                                       ephemeral container)
  <volume>/models/*  <->  ComfyUI/models/*             (working COPY in the
                                                       container; synced both
                                                       ways, see below)

  Images/videos are small, so ComfyUI reads/writes them straight from the
  volume via --input-directory/--output-directory. Nothing private ever sits
  on ephemeral disk for these.
  Model weights are big and read hard at load time, so each run copies
  new/changed files volume -> container at startup, and container -> volume
  at shutdown (plus a periodic safety sync). VRAM loading itself only needs
  a readable file path, which the container copy provides.

Shutdown (stop the app / Ctrl-C on `modal serve` / deploy stop):
  SIGTERM/SIGINT -> stop ComfyUI -> final model sync to the volume ->
  vol.commit() -> DELETE ComfyUI/input, ComfyUI/output, ComfyUI/models and
  ComfyUI/temp from ephemeral storage. Order matters: save first, wipe after.
  (Modal also auto-commits volumes periodically and on shutdown; the explicit
  commit + wipe here is what guarantees nothing is left behind.)

Quickstart (local machine, one time):
  pip install modal && modal setup

Run (dev, URL printed in the terminal, stays up while you watch):
  modal serve modal_comfyui.py

Deploy (persistent https://<workspace>--lazycomfy-comfyui.modal.run):
  modal deploy modal_comfyui.py
  modal app stop lazycomfy-comfyui          # triggers the save+wipe shutdown

Notes:
  - First boot downloads torch into the image (~minutes, cached afterwards);
    later boots only git-clone (~seconds) + copy back changed models.
  - Idle containers may scale to zero; reopening the URL cold-starts and
    re-runs setup (model copy skips unchanged files, so it is fast).
  - Your HF token (for gated repos) is entered in the LazyComfy UI per
    session and lives only on ephemeral disk. Re-enter it each run.
"""

import os
import shutil
import signal
import subprocess
import sys
import threading
import time

import modal

APP_NAME = "lazycomfy-comfyui"
VOLUME_NAME = "comfyui-persistent"
VOL_MOUNT = "/mnt/comfyui-persistent"
VOL_INPUT = os.path.join(VOL_MOUNT, "input")
VOL_OUTPUT = os.path.join(VOL_MOUNT, "output")
VOL_MODELS = os.path.join(VOL_MOUNT, "models")

COMFY_DIR = "/root/ComfyUI"
SESS_MODELS = os.path.join(COMFY_DIR, "models")
# Ephemeral dirs that must not survive shutdown (after the volume sync).
SESS_WIPE_DIRS = ("input", "output", "models", "temp")

COMFYUI_REPO = "https://github.com/comfyanonymous/ComfyUI.git"
MANAGER_REPO = "https://github.com/Comfy-Org/ComfyUI-Manager.git"
LAZYCOMFY_REPO = "https://github.com/GodL-x-SouL/LazyComfy.git"

PORT = 8188
SYNC_EVERY_SEC = 20 * 60  # periodic model safety sync (plus final sync)

app = modal.App(APP_NAME)
vol = modal.Volume.from_name(VOLUME_NAME, create_if_missing=True)

image = (
    modal.Image.debian_slim(python_version="3.12")
    .apt_install("git", "ffmpeg", "libgl1", "libglib2.0-0")
    # Latest stable CUDA torch from the default index. Do NOT pin cu124:
    # torch 2.6's torch.library rejects the `list[int]` annotations used by
    # current ComfyUI (comfy/utils.py), killing main.py on import.
    .pip_install("torch", "torchvision", "torchaudio")
)


def _log(msg):
    print(f"[modal-comfyui] {msg}", flush=True)


def _run(cmd, cwd=None):
    _log("+ " + " ".join(cmd))
    subprocess.run(cmd, cwd=cwd, check=True)


def _git_latest(repo, dest):
    if os.path.isdir(os.path.join(dest, ".git")):
        _run(["git", "-C", dest, "fetch", "--depth", "1", "origin"], cwd=None)
        _run(["git", "-C", dest, "reset", "--hard", "origin/HEAD"])
    else:
        _run(["git", "clone", "--depth", "1", repo, dest])


def _sync_tree(src, dst):
    """Copy new/changed files src -> dst. Newer side wins; equal mtime+size
    is treated as identical. Returns the copied count."""
    copied = 0
    if not os.path.isdir(src):
        return 0
    for root, _dirs, files in os.walk(src):
        rel = os.path.relpath(root, src)
        target_root = dst if rel == "." else os.path.join(dst, rel)
        os.makedirs(target_root, exist_ok=True)
        for name in files:
            s = os.path.join(root, name)
            d = os.path.join(target_root, name)
            try:
                st = os.stat(s)
            except OSError:
                continue
            try:
                dst_stat = os.stat(d)
                if int(dst_stat.st_mtime) > int(st.st_mtime):
                    continue
                if int(dst_stat.st_mtime) == int(st.st_mtime) and dst_stat.st_size == st.st_size:
                    continue
            except OSError:
                pass
            try:
                shutil.copy2(s, d)
                copied += 1
            except OSError as e:
                _log(f"skip {s}: {e}")
    return copied


def _wipe_ephemeral():
    for sub in SESS_WIPE_DIRS:
        path = os.path.join(COMFY_DIR, sub)
        outside = os.path.abspath(path) != os.path.abspath(COMFY_DIR) and os.path.abspath(path).startswith(
            os.path.abspath(COMFY_DIR) + os.sep
        )
        if not outside or not os.path.lexists(path):
            continue
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path, ignore_errors=True)
        else:
            try:
                os.remove(path)
            except OSError:
                pass
        _log(f"wiped ephemeral {path}")


def setup():
    os.makedirs(VOL_INPUT, exist_ok=True)
    os.makedirs(VOL_OUTPUT, exist_ok=True)
    os.makedirs(VOL_MODELS, exist_ok=True)

    _git_latest(COMFYUI_REPO, COMFY_DIR)
    nodes = os.path.join(COMFY_DIR, "custom_nodes")
    os.makedirs(nodes, exist_ok=True)
    _git_latest(MANAGER_REPO, os.path.join(nodes, "ComfyUI-Manager"))
    _git_latest(LAZYCOMFY_REPO, os.path.join(nodes, "LazyComfy"))

    req = os.path.join(COMFY_DIR, "requirements.txt")
    if os.path.isfile(req):
        _run([sys.executable, "-m", "pip", "install", "-r", req])

    n = _sync_tree(VOL_MODELS, SESS_MODELS)
    _log(f"models volume -> session: {n} file(s) copied")
    vol.commit()


def teardown():
    n = _sync_tree(SESS_MODELS, VOL_MODELS)
    _log(f"models session -> volume: {n} file(s) saved")
    vol.commit()
    _wipe_ephemeral()
    _log("shutdown complete: volume saved, ephemeral input/output/models wiped")


def _periodic_sync(stop):
    while not stop.wait(SYNC_EVERY_SEC):
        try:
            n = _sync_tree(SESS_MODELS, VOL_MODELS)
            if n:
                _log(f"periodic sync: {n} model file(s) saved")
                vol.commit()
        except Exception as e:
            _log(f"periodic sync failed (will retry): {e}")


def run():
    setup()
    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            signal.signal(sig, lambda *_: stop.set())
        except (OSError, ValueError):
            pass
    syncer = threading.Thread(target=_periodic_sync, args=(stop,), daemon=True)
    syncer.start()
    cmd = [
        sys.executable,
        "main.py",
        "--listen",
        "0.0.0.0",
        "--port",
        str(PORT),
        "--input-directory",
        VOL_INPUT,
        "--output-directory",
        VOL_OUTPUT,
    ]
    if shutil.which("nvidia-smi") is None:
        # CPU container (free-tier smoke test): without this, ComfyUI dies
        # at import probing torch.cuda. GPU runs are unaffected.
        cmd.append("--cpu")
        _log("no NVIDIA driver detected, launching ComfyUI with --cpu")
    proc = subprocess.Popen(cmd, cwd=COMFY_DIR)
    _log(f"ComfyUI pid={proc.pid} on port {PORT}")
    try:
        while proc.poll() is None and not stop.is_set():
            time.sleep(1)
    finally:
        stop.set()
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                proc.kill()
        teardown()


@app.function(
    image=image,
    gpu="T4",
    memory=16384,
    volumes={VOL_MOUNT: vol},
    timeout=12 * 3600,
    # One container only: concurrent hits while cold-starting (git clone +
    # pip install takes minutes) must queue on the same container instead of
    # spawning duplicates that each redo setup and fight over the volume.
    max_containers=1,
)
@modal.web_server(port=PORT, startup_timeout=1800)
def ui():
    run()
