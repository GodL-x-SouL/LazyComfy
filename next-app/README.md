# LazyComfy App (Next.js)

SPA port of the LazyComfy single-page UIs. Served by the ComfyUI Python
backend at `/lazycomfy/app` — the classic pages (`/lazycomfy`, `/video`,
`/upscale`, `/forge`, `/custom`) keep working untouched.

## Develop

```text
cd next-app
npm install
npm run dev        # dev server (proxy /lazycomfy/api to ComfyUI yourself)
```

## Build (committed bundle)

```text
cd next-app
npm run build      # static export → ../web/app/
```

The `web/app/` bundle is committed so Colab picks it up with a plain
`git pull` — no Node toolchain needed on the server. Rebuild and commit it
whenever `next-app/src` changes.

## Notes

- `output: "export"` + `basePath: "/lazycomfy/app"`. All API calls use
  same-origin `/lazycomfy/api/*`, so any host/tunnel works with zero config.
- Client-side routing: one shared layout, one shared ComfyUI WebSocket for
  all five pages (images, video, upscale, forge, custom).
