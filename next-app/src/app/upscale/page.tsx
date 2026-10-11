"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import {
  api,
  errMsg,
  fetchUpscaleConfig,
  fetchUpscaleResult,
  loadSession,
  saveSession,
  scanUpscaleImages,
  submitUpscale,
  unloadUpscale,
  uploadImage,
  deleteMedia,
  fmtSize,
  fmtDur,
} from "@/lib/api";
import { useToast, getClientId } from "@/lib/store";

interface DirImage {
  name: string;
  path: string;
  size: number;
}

interface UpscaleResult {
  url: string;
  filename: string;
  file: { filename?: string; subfolder?: string; type?: string };
}

const clampInt = (v: string, lo: number, hi: number): number => {
  const n = parseInt(v, 10);
  if (isNaN(n)) return lo;
  return Math.max(lo, Math.min(hi, n));
};

export default function UpscalePage() {
  const toast = useToast();
  const [cfg, setCfg] = useState<any>(null);
  const [backendOk, setBackendOk] = useState<boolean | null>(null);
  const [inDir, setInDir] = useState("");
  const [images, setImages] = useState<DirImage[]>([]);
  const [dirPath, setDirPath] = useState("");
  const [selIdx, setSelIdx] = useState(0);
  const [unet, setUnet] = useState("");
  const [vae, setVae] = useState("");
  const [scale, setScale] = useState("4");
  const [seed, setSeed] = useState("0");
  const [tileSize, setTileSize] = useState("512");
  const [tileOverlap, setTileOverlap] = useState("128");
  const [color, setColor] = useState("none");
  const [outDir, setOutDir] = useState("");
  const [busy, setBusy] = useState(false);
  const [jobState, setJobState] = useState("Idle");
  const [progress, setProgress] = useState<number | null>(null);
  const [result, setResult] = useState<UpscaleResult | null>(null);
  const [meta, setMeta] = useState("");
  const [savedLine, setSavedLine] = useState("");
  const [blackWarn, setBlackWarn] = useState("");
  const [restored, setRestored] = useState(false);
  const booted = useRef(false);
  const saveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const pollTimer = useRef<ReturnType<typeof setInterval> | null>(null);
  const jobRef = useRef<string | null>(null);
  const jobStart = useRef(0);
  const stateRef = useRef({ inDir, images, selIdx, unet, vae, scale, seed, tileSize, tileOverlap, color, outDir });
  stateRef.current = { inDir, images, selIdx, unet, vae, scale, seed, tileSize, tileOverlap, color, outDir };
  const fileRef = useRef<HTMLInputElement>(null);

  const collect = useCallback(() => {
    const s = stateRef.current;
    return {
      in_dir: s.inDir,
      image: s.images[s.selIdx] ? s.images[s.selIdx].path : "",
      unet: s.unet,
      vae: s.vae,
      scale: s.scale,
      seed: s.seed,
      tile_size: s.tileSize,
      tile_overlap: s.tileOverlap,
      color: s.color,
      out_dir: s.outDir,
    };
  }, []);

  const persist = useCallback(() => {
    if (saveTimer.current) clearTimeout(saveTimer.current);
    saveTimer.current = setTimeout(() => {
      saveTimer.current = null;
      saveSession("upscale", collect());
    }, 400);
  }, [collect]);

  useEffect(() => {
    const onUnload = () => saveSession("upscale", collect());
    window.addEventListener("beforeunload", onUnload);
    return () => window.removeEventListener("beforeunload", onUnload);
  }, [collect]);

  const previewUrl = (img?: DirImage): string => {
    if (!img) return "";
    const inputRoot = cfg?.input_dir || "";
    if (!dirPath || (inputRoot && dirPath === inputRoot)) {
      return "/view?filename=" + encodeURIComponent(img.name) + "&type=input";
    }
    return "/lazycomfy/api/upscale/preview?path=" + encodeURIComponent(img.path);
  };

  const scan = useCallback(
    async (dir: string) => {
      try {
        const r = await scanUpscaleImages(dir);
        const list: DirImage[] = r.images || [];
        setImages(list);
        setDirPath(r.dir || "");
        setSelIdx((prev) => Math.min(prev, Math.max(0, list.length - 1)));
      } catch (e) {
        toast(errMsg(e), "error");
      }
    },
    [toast],
  );

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const saved = (await loadSession()).upscale;
      if (!cancelled && saved) {
        setInDir(saved.in_dir || "");
        setScale(saved.scale || "4");
        setSeed(saved.seed || "0");
        setTileSize(saved.tile_size || "512");
        setTileOverlap(saved.tile_overlap || "128");
        setColor(saved.color || "none");
        setOutDir(saved.out_dir || "");
        (saved as any)._image = saved.image || "";
        (saved as any)._unet = saved.unet || "";
        (saved as any)._vae = saved.vae || "";
        setRestored(true);
        toast("Restored your previous settings", "ok");
      }
      try {
        const c = await fetchUpscaleConfig();
        if (cancelled) return;
        setCfg(c);
        setBackendOk(true);
        if (saved) {
          if (saved.unet && (c.unets || []).includes(saved.unet)) setUnet(saved.unet);
          else if ((c.unets || []).length) setUnet(c.unets[0]);
          if (saved.vae && (c.vaes || []).includes(saved.vae)) setVae(saved.vae);
          else if ((c.vaes || []).length) setVae(c.vaes[0]);
        } else {
          if ((c.unets || []).length) setUnet(c.unets[0]);
          if ((c.vaes || []).length) setVae(c.vaes[0]);
        }
        await scan(saved?.in_dir || "");
        if (cancelled) return;
      } catch (e) {
        if (!cancelled) {
          setBackendOk(false);
          setJobState("Backend unavailable");
        }
        return;
      }
      booted.current = true;
    })();
    return () => {
      cancelled = true;
      if (pollTimer.current) clearInterval(pollTimer.current);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Re-select the restored image path once the listing arrives.
  useEffect(() => {
    if (!restored || !images.length) return;
    setRestored(false);
    loadSession().then((all) => {
      const p = all?.upscale?.image;
      if (!p) return;
      const idx = images.findIndex((i) => i.path === p);
      if (idx >= 0) setSelIdx(idx);
    });
  }, [restored, images]);

  const onScan = () => {
    scan(inDir);
    persist();
  };

  const handleFile = async (file?: File | null) => {
    if (!file) return;
    if (!/^image\/(png|jpeg|webp)$/.test(file.type || "")) {
      toast("Only PNG, JPEG or WebP images are accepted.", "error");
      return;
    }
    const fd = new FormData();
    fd.append("image", file, file.name);
    try {
      const r = await api("/lazycomfy/api/upload", { method: "POST", body: fd });
      const sub = String(r.subfolder || "lazycomfy").replace(/^\/+|\/+$/g, "");
      const root = String((cfg && cfg.input_dir) || "").replace(/\/+$/g, "");
      const targetDir = root ? root + "/" + sub : inDir;
      if (targetDir !== inDir) setInDir(targetDir);
      const listed = await scanUpscaleImages(root ? root + "/" + sub : targetDir);
      setImages(listed.images || []);
      setDirPath(listed.dir || "");
      const idx = (listed.images || []).findIndex(
        (i: DirImage) => i.path.endsWith("/" + r.name) || i.name === r.name,
      );
      setSelIdx(idx >= 0 ? idx : 0);
      persist();
      toast("Image uploaded: " + r.name, "ok");
    } catch (e) {
      toast(errMsg(e), "error");
    }
  };

  const stopPoll = () => {
    if (pollTimer.current) {
      clearInterval(pollTimer.current);
      pollTimer.current = null;
    }
  };

  const startUpscale = async () => {
    const img = images[selIdx];
    if (!img) {
      toast("Pick an image first.", "error");
      return;
    }
    if (!unet || !vae) {
      toast("Pick a SeedVR2 model and a VAE first.", "error");
      return;
    }
    const body = {
      unet,
      vae,
      image: img.path,
      scale: parseFloat(scale),
      tile_size: clampInt(tileSize, 64, 4096),
      tile_overlap: clampInt(tileOverlap, 0, 4096),
      color,
      seed: clampInt(seed, 1, 9007199254740991),
      out_dir: outDir.trim(),
      client_id: getClientId(),
    };
    try {
      const r = await submitUpscale(body);
      jobRef.current = r.prompt_id;
      jobStart.current = Date.now();
      setResult(null);
      setBusy(true);
      setJobState("Submitted — waiting for the queue…");
      setProgress(8);
      stopPoll();
      pollTimer.current = setInterval(poll, 1200);
    } catch (e) {
      toast(errMsg(e), "error");
      setJobState("Failed to start");
    }
  };

  const poll = async () => {
    const id = jobRef.current;
    if (!id) {
      stopPoll();
      return;
    }
    let r: any;
    try {
      r = await fetchUpscaleResult(id);
    } catch (e) {
      toast(errMsg(e), "error");
      stopPoll();
      setBusy(false);
      setJobState("Polling failed");
      return;
    }
    if (r.status === "running") {
      setJobState("Upscaling (tiled)…");
      setProgress(45);
      return;
    }
    stopPoll();
    setBusy(false);
    if (r.status === "success") {
      setProgress(100);
      setJobState(jobStart.current ? "Done in " + fmtDur(Date.now() - jobStart.current) : "Done");
      showResult(r);
    } else if (r.status === "error") {
      setProgress(null);
      setJobState("Failed");
      toast("Upscale failed: " + ((r.error && (r.error.message || r.error.type)) || "unknown error"), "error");
      if (r.error_hint) toast(r.error_hint, "error");
    } else {
      setProgress(null);
      setJobState("Unknown status");
    }
  };

  const showResult = (r: any) => {
    const out = (r.outputs || [])[0];
    if (out) {
      const url =
        "/view?" +
        new URLSearchParams({
          filename: out.filename,
          subfolder: out.subfolder || "",
          type: out.type || "output",
        }).toString();
      setResult({
        url,
        filename: out.filename || "lazycomfy-upscale.png",
        file: { filename: out.filename, subfolder: out.subfolder || "", type: out.type || "output" },
      });
    }
    setMeta(`SeedVR2 · ${unet} · VAE ${vae} · ${scale}x · tiles ${tileSize}px · color ${color}`);
    if (r.saved_dir) {
      if (r.saved_error) setSavedLine("Custom save folder: " + r.saved_error);
      else if (r.saved && r.saved.length) setSavedLine("Saved to: " + r.saved.join(", "));
      else setSavedLine("Custom save folder has no matching output file.");
    } else {
      setSavedLine("Saved in the ComfyUI output folder.");
    }
    setBlackWarn(r.black_output ? r.black_hint || "Output came out all black — possible NaN in the VAE decode." : "");
  };

  const unload = async () => {
    try {
      setJobState("Unloading models…");
      const r = await unloadUpscale();
      setJobState("Models unloaded");
      toast("VRAM freed (" + (r.method === "direct" ? "direct" : "ComfyUI /free") + ")", "ok");
    } catch (e) {
      setJobState("Idle");
      toast(errMsg(e), "error");
    }
  };

  const delResult = async () => {
    if (!result) return;
    try {
      await deleteMedia(result.file);
      toast("Image deleted.", "ok");
    } catch (e) {
      toast(errMsg(e), "error");
      return;
    }
    setResult(null);
  };

  const modelsMissing = cfg && (cfg.unets?.length === 0 || cfg.vaes?.length === 0);
  const selImg = images[selIdx];

  return (
    <main className="layout">
      <section className="panel">
        <div className="group">
          <label className="group-label">Input</label>
          <div className="field">
            <label htmlFor="inDir">Image folder</label>
            <div style={{ display: "flex", gap: 8 }}>
              <input
                id="inDir"
                style={{ flex: 1 }}
                placeholder="Leave empty for the ComfyUI input folder"
                spellCheck={false}
                value={inDir}
                onChange={(e) => {
                  setInDir(e.target.value);
                  persist();
                }}
                onKeyDown={(e) => {
                  if (e.key === "Enter") onScan();
                }}
              />
              <button className="act-btn" type="button" onClick={onScan}>
                Scan
              </button>
            </div>
            <p className="hint">
              {dirPath ? `Folder: ${dirPath} · ${images.length} image${images.length === 1 ? "" : "s"}` : cfg?.input_dir ? `Empty folder = ComfyUI input: ${cfg.input_dir}` : ""}
            </p>
          </div>
          <div className="field">
            <label htmlFor="imgSel">Image</label>
            <select
              id="imgSel"
              value={selIdx}
              disabled={!images.length}
              onChange={(e) => setSelIdx(parseInt(e.target.value, 10) || 0)}
            >
              {images.length === 0 && <option value={0}>No images found</option>}
              {images.map((img, i) => (
                <option key={img.path} value={i}>
                  {img.name} · {fmtSize(img.size)}
                </option>
              ))}
            </select>
            <p className="note">Uploaded images join the ComfyUI input folder automatically.</p>
          </div>
          {selImg && (
            <div style={{ display: "flex", justifyContent: "center", marginTop: 9 }}>
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={previewUrl(selImg)} alt="Selected image preview" style={{ maxWidth: "100%", maxHeight: 200, borderRadius: 8, border: "1px solid var(--border)" }} />
            </div>
          )}
          <div style={{ marginTop: 9 }}>
            <div className="dz" role="button" tabIndex={0} onClick={() => fileRef.current?.click()} onKeyDown={(e) => e.key === "Enter" && fileRef.current?.click()}>
              Click to upload an image (PNG / JPEG / WebP)
            </div>
            <input
              ref={fileRef}
              type="file"
              accept="image/png,image/jpeg,image/webp"
              hidden
              onChange={(e) => {
                handleFile(e.target.files?.[0]);
                e.target.value = "";
              }}
            />
          </div>
        </div>

        <div className="group">
          <label className="group-label">Model</label>
          {modelsMissing && (
            <div className="err-banner">SeedVR2 model or VAE is missing — download them from the Model downloads window on the main page.</div>
          )}
          <div className="field">
            <label htmlFor="unetSel">SeedVR2 model</label>
            <select id="unetSel" value={unet} disabled={!(cfg?.unets?.length > 0)} onChange={(e) => { setUnet(e.target.value); persist(); }}>
              {!(cfg?.unets?.length > 0) && <option>No SeedVR2 model found</option>}
              {(cfg?.unets || []).map((n: string) => (
                <option key={n} value={n}>{n}</option>
              ))}
            </select>
          </div>
          <div className="field">
            <label htmlFor="vaeSel">VAE</label>
            <select id="vaeSel" value={vae} disabled={!(cfg?.vaes?.length > 0)} onChange={(e) => { setVae(e.target.value); persist(); }}>
              {!(cfg?.vaes?.length > 0) && <option>No VAE found</option>}
              {(cfg?.vaes || []).map((n: string) => (
                <option key={n} value={n}>{n}</option>
              ))}
            </select>
            <p className="note">SeedVR2 uses no text encoder — only the diffusion model and its VAE.</p>
          </div>
        </div>

        <div className="group">
          <label className="group-label">Settings</label>
          <div className="grid2">
            <div className="field">
              <label htmlFor="scaleSel">Scale</label>
              <select id="scaleSel" value={scale} onChange={(e) => { setScale(e.target.value); persist(); }}>
                <option value="2">2x</option>
                <option value="3">3x</option>
                <option value="4">4x</option>
              </select>
            </div>
            <div className="field">
              <label htmlFor="seed">Seed</label>
              <input id="seed" type="number" min={1} step={1} value={seed} title="0 or empty = random" onChange={(e) => { setSeed(e.target.value); persist(); }} />
            </div>
            <div className="field">
              <label htmlFor="tileSize">Tile size</label>
              <input id="tileSize" type="number" min={64} max={4096} step={64} value={tileSize} onChange={(e) => { setTileSize(e.target.value); persist(); }} />
            </div>
            <div className="field">
              <label htmlFor="tileOverlap">Tile overlap</label>
              <input id="tileOverlap" type="number" min={0} max={4096} step={32} value={tileOverlap} onChange={(e) => { setTileOverlap(e.target.value); persist(); }} />
            </div>
          </div>
          <div className="field">
            <label htmlFor="colorSel">Color correction</label>
            <select id="colorSel" value={color} onChange={(e) => { setColor(e.target.value); persist(); }}>
              <option value="none">None (official default)</option>
              <option value="wavelet">Wavelet</option>
              <option value="lab">LAB (can produce black output)</option>
              <option value="adain">AdaIN</option>
            </select>
          </div>
          <p className="note">If you run out of VRAM, lower the tile size — 1024 works well on ~14.5 GB VRAM, drop to 512 if needed.</p>
        </div>

        <div className="group">
          <label className="group-label">Output</label>
          <div className="field">
            <label htmlFor="outDir">Save folder</label>
            <input id="outDir" placeholder="Leave empty for the ComfyUI output folder" spellCheck={false} value={outDir} onChange={(e) => { setOutDir(e.target.value); persist(); }} />
            <p className="note">Upscaled images are saved to your custom folder as well as the ComfyUI output folder.</p>
          </div>
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: 9 }}>
          <button className="btn btn-primary" type="button" disabled={busy || !images.length} onClick={startUpscale}>
            {busy && <span className="spin" />}
            {busy ? "Upscaling…" : "Upscale"}
          </button>
          <button className="btn btn-danger" type="button" onClick={unload}>
            Unload VRAM models
          </button>
        </div>
      </section>

      <section className="panel">
        <div className="group">
          <label className="group-label">Job</label>
          <div className="status-strip">
            <span className="job-state">{jobState}</span>
            <span className="conn" style={{ marginLeft: "auto" }}>
              <span className={"dot" + (backendOk === null ? "" : backendOk ? " on" : " err")} />
              {backendOk === null ? "…" : backendOk ? "Connected" : "Error"}
            </span>
          </div>
          {progress !== null && (
            <div className="progress-wrap">
              <div className="progress-bar" style={{ width: progress + "%" }} />
            </div>
          )}
        </div>
        <div className="view">
          {!result && (
            <div className="placeholder">
              <p>Pick an image on the left and hit Upscale.<br />SeedVR2 7B scales it to up to 4x — tiled for low VRAM.</p>
            </div>
          )}
          {result && (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={result.url} alt="Upscaled result" />
          )}
        </div>
        {meta && <div className="meta-line">{meta}</div>}
        {savedLine && <div className="saved-line">{savedLine}</div>}
        {blackWarn && <div className="err-line">{blackWarn}</div>}
        {result && (
          <div className="row-actions">
            <button className="act-btn" type="button" onClick={() => window.open(result.url, "_blank")}>
              Open
            </button>
            <a className="act-btn" href={result.url} download={result.filename}>
              Download
            </a>
            <button className="act-btn danger" type="button" onClick={delResult}>
              Delete
            </button>
          </div>
        )}
      </section>
    </main>
  );
}
