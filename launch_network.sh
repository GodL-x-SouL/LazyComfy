#!/usr/bin/env bash
# Launch ComfyUI on the LAN and print the network URLs.
# Run from anywhere: ./launch_network.sh [--cpu] [main.py args...]
set -u

PORT=8188
ARGS=()

for a in "$@"; do
  if [[ "$a" =~ ^--port(=|[[:space:]]|$) ]]; then
    echo "pass --port only via PORT= env (default 8188)" >&2
    exit 1
  fi
  ARGS+=("$a")
done
if [[ -n "${PORT_OVERRIDE:-}" ]]; then
  PORT="$PORT_OVERRIDE"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$HERE/main.py" ]]; then
  COMFY="$HERE"
elif [[ -f "$HERE/../../main.py" ]]; then
  COMFY="$(cd "$HERE/../.." && pwd)"
else
  echo "main.py not found (looked in $HERE and $HERE/../..)" >&2
  exit 1
fi

command -v fuser >/dev/null && fuser -k "$PORT/tcp" >/dev/null 2>&1 || true
lsof -ti:"$PORT" 2>/dev/null | xargs -r kill -9 2>/dev/null || true

IPS="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
echo "comfyui  $COMFY"
echo "local    http://127.0.0.1:$PORT/lazycomfy"
for ip in $IPS; do
  echo "network  http://$ip:$PORT/lazycomfy"
done

cd "$COMFY"
exec python3 -u main.py --listen 0.0.0.0 --port "$PORT" "${ARGS[@]}"
