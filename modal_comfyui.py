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
  <volume>/models/   <->  ComfyUI/models               (SYMLINK: downloads land
                                                       on the volume instantly,
                                                       loads read from it)

  Why a symlink instead of copying models to the container: Modal's
  @modal.web_server pattern REQUIRES the function to start the server and
  RETURN (a function that blocks forever holds its request open and starves
  every later request). After return nothing of ours runs at shutdown except
  @modal.exit, which only gets a 30-second grace - far too short to copy
  gigabytes back. The symlink removes the copy-back entirely: there is no
  sync to forget, no shutdown race, and nothing model-sized on ephemeral
  disk, ever. Volume reads are high-throughput; only first page-in latency
  differs from local SSD.
  Inputs/outputs additionally never touch ephemeral storage at all, so the
  "wipe on stop" requirement is satisfied by construction: there is nothing
  private to wipe. The container's overlay filesystem is destroyed with it.

Quickstart (local machine, one time):
  pip install modal && modal setup

Run (dev, URL printed in the terminal, stays up while you watch):
  modal serve modal_comfyui.py

Deploy (persistent https://<workspace>--lazycomfy-comfyui.modal.run):
  modal deploy modal_comfyui.py
  modal app stop lazycomfy-comfyui          # idle containers also stop alone

Notes:
  - First boot downloads torch into the image (~minutes, cached afterwards);
    later boots only git-clone + pip-check (~2-4 min). The first HTTP hit
    waits through cold start; retry once if the proxy times it out.
  - scaledown_window keeps the warm container for 30 min of idle; idle GPU
    time still bills, lower it to save credits.
  - max_containers=1: concurrent hits during cold start queue instead of
    spawning duplicate containers that each redo setup.
  - Your HF token (for gated repos) is entered in the LazyComfy UI per
    session and lives only on ephemeral disk. Re-enter it each run.
"""

import os
import shutil
import socket
import subprocess
import sys
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

COMFYUI_REPO = "https://github.com/comfyanonymous/ComfyUI.git"
MANAGER_REPO = "https://github.com/Comfy-Org/ComfyUI-Manager.git"
LAZYCOMFY_REPO = "https://github.com/GodL-x-SouL/LazyComfy.git"

PORT = 8188

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
        _run(["git", "-C", dest, "fetch", "--depth", "1", "origin"])
        _run(["git", "-C", dest, "reset", "--hard", "origin/HEAD"])
    else:
        _run(["git", "clone", "--depth", "1", repo, dest])


def _link_models_to_volume():
    # Point the whole models tree at the volume: downloads persist
    # instantly, loads read straight from it, ephemeral stays clean.
    os.makedirs(VOL_MODELS, exist_ok=True)
    if os.path.islink(SESS_MODELS):
        return
    if os.path.isdir(SESS_MODELS):
        shutil.rmtree(SESS_MODELS)
    elif os.path.lexists(SESS_MODELS):
        os.remove(SESS_MODELS)
    os.symlink(VOL_MODELS, SESS_MODELS)
    _log(f"linked {SESS_MODELS} -> {VOL_MODELS}")


def _wait_for_port(timeout=1500):
    start = time.time()
    while time.time() - start < timeout:
        try:
            with socket.create_connection(("127.0.0.1", PORT), timeout=2):
                _log(f"port {PORT} open, returning (container stays warm)")
                return
        except OSError:
            time.sleep(2)
    raise RuntimeError(f"ComfyUI did not open port {PORT} within {timeout}s")


def setup():
    os.makedirs(VOL_INPUT, exist_ok=True)
    os.makedirs(VOL_OUTPUT, exist_ok=True)

    _git_latest(COMFYUI_REPO, COMFY_DIR)
    nodes = os.path.join(COMFY_DIR, "custom_nodes")
    os.makedirs(nodes, exist_ok=True)
    _git_latest(MANAGER_REPO, os.path.join(nodes, "ComfyUI-Manager"))
    _git_latest(LAZYCOMFY_REPO, os.path.join(nodes, "LazyComfy"))

    req = os.path.join(COMFY_DIR, "requirements.txt")
    if os.path.isfile(req):
        _run([sys.executable, "-m", "pip", "install", "-r", req])

    _link_models_to_volume()
    vol.commit()


@app.function(
    image=image,
    gpu="T4",
    memory=16384,
    volumes={VOL_MOUNT: vol},
    timeout=12 * 3600,
    scaledown_window=1800,
    max_containers=1,
)
@modal.web_server(port=PORT, startup_timeout=1800)
def ui():
    # Modal serves requests only after this function RETURNS, so: set up,
    # start ComfyUI detached, wait for its port, return. The container (and
    # ComfyUI) stays warm afterwards. Never block here forever - that holds
    # the triggering request open and starves all later requests.
    setup()
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
    subprocess.Popen(cmd, cwd=COMFY_DIR)
    _log("ComfyUI launched, waiting for port")
    _wait_for_port()
