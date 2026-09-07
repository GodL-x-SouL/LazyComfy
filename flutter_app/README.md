# MobileComfy Android app

This folder contains the Flutter client for the LazyComfy custom node. It is a thin native shell around the existing `/lazycomfy` frontend, so the current generation, gallery, Forge, upscale, and video features continue to use the backend APIs they already understand.

## How it works

1. The first screen requires a ComfyUI backend URL.
2. MobileComfy normalizes the URL to `<backend>/lazycomfy` and probes `<backend>/lazycomfy/api/config`.
3. Once the probe succeeds, the app opens that URL in an Android WebView. Relative API calls and the ComfyUI WebSocket therefore stay on the configured tunnel host.
4. The last working endpoint is stored locally for faster subsequent launches. Use the swap button in the app bar to change it.

The app accepts either a tunnel root such as `https://your-subdomain.trycloudflare.com` or a complete URL such as `http://127.0.0.1:8188/lazycomfy`.

## Build

Install Flutter, then from this directory run:

```bash
flutter pub get
flutter test
flutter build apk --release
```

The generated APK is placed under `build/app/outputs/flutter-apk/`.

The local release build is signed with the Android debug keystore so it can be
sideloaded directly. Before publishing to Google Play, replace that signing
configuration with a private production keystore.

## Backend setup

Start ComfyUI with this custom node installed, then expose port 8188 with one of the following examples:

For Google Colab, leave the ComfyUI launch cell running and execute the tunnel command in a separate cell. The public tunnel URL is the value to paste into MobileComfy.

```bash
cloudflared tunnel --url http://127.0.0.1:8188
ssh -p 443 -R0:localhost:8188 a.pinggy.io
```

Paste the resulting `https://...` URL into the app. For a ComfyUI process on the development computer and the Android emulator, use `http://10.0.2.2:8188`; on a physical phone use a tunnel or a reachable LAN IP instead of `127.0.0.1`.
