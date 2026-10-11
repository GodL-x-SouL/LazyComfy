/** @type {import('next').NextConfig} */
const nextConfig = {
  // Static SPA bundle served by the ComfyUI Python backend at /lazycomfy/app.
  // Same-origin API calls (/lazycomfy/api/*) keep working behind any host/tunnel.
  output: "export",
  distDir: "../web/app",
  basePath: "/lazycomfy/app",
  images: { unoptimized: true },
};

export default nextConfig;
