"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import {
  api,
  errMsg,
  fmtSize,
  fetchCatalog,
  fetchInputImages,
  fetchVideoConfig,
  fetchVideoFiles,
  fetchVideoHistory,
  fetchVideoResult,
  loadSession,
  saveSession,
  submitVideo,
  cancelVideo,
  uploadImage,
  deleteMedia,
  JobEntry,
  MediaFile,
} from "@/lib/api";
import { useToast, getClientId, useComfyWs } from "@/lib/store";
import { Select } from "@/components/controls";

interface VideoModel {
  id: string;
  name: string;
  modes: string[];
  files: { kind: string; label: string; dir: string; name: string; present?: boolean }[];
  defaults: Record<string, any>;
  limits: Record<string, any>;
  options: { samplers?: string[]; schedulers?: string[] };
}

interface InputImage {
  name: string;
  subfolder?: string;
  blobUrl?: string;
}

const clampInt = (v: any, lo: number, hi: number, dflt: number): number => {
  const n = parseInt(v, 10);
  if (!Number.isFinite(n)) return dflt;
  return Math.max(lo, Math.min(hi, n));
};

const fileKey = (f: { subfolder?: string; filename?: string }) =>
  (f.subfolder || "") + "/" + (f.filename || "");

export default function VideoPage() {
  const toast = useToast();
  const [models, setModels] = useState<VideoModel[]>([]);
  const [modelId, setModelId] = useState<string | null>(null);
  const [mode, setMode] = useState("t2i");
  const [dirs, setDirs] = useState<Record<string, string[]>>({});
  const [inputDir, setInputDir] = useState("");
  const [prompt, setPrompt] = useState("");
  const [width, setWidth] = useState("1280");
  const [height, setHeight] = useState("736");
  const [length, setLength] = useState("97");
  const [fps, setFps] = useState("24");
  const [steps, setSteps] = useState("8");
  const [seed, setSeed] = useState("");
  const [randSeed, setRandSeed] = useState(true);
  const [sampler, setSampler] = useState("");
  const [scheduler, setScheduler] = useState("");
  const [fileSel, setFileSel] = useState<Record<string, Record<string, string>>>({});
  const [lora, setLora] = useState("");
  const [loraStrength, setLoraStrength] = useState("1");
  const [loraStack, setLoraStack] = useState<{ name: string; strength: number }[]>([]);
  const [inputImage, setInputImage] = useState<InputImage | null>(null);
  const [inputLib, setInputLib] = useState<InputImage[]>([]);
  const [jobState, setJobState] = useState("Idle");
  const [progress, setProgress] = useState<number | null>(null);
  const [current, setCurrent] = useState<{ videos: MediaFile[]; outputs?: MediaFile[]; meta?: any } | null>(null);
  const [metaLine, setMetaLine] = useState("");
  const [gallery, setGallery] = useState<JobEntry[]>([]);
  const [deleted, setDeleted] = useState<Set<string>>(new Set());
  const [queueN, setQueueN] = useState(0);
  const jobRef = useRef<{ promptId: string; startedAt: number; done: boolean } | null>(null);
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const booted = useRef(false);

  const model = models.find((m) => m.id === modelId) || null;

  const collect = useCallback(
    () => ({
      modelId,
      mode,
      width,
      height,
      length,
      fps,
      steps,
      seed,
      sampler,
      scheduler,
      fileSel,
      prompt,
    }),
    [modelId, mode, width, height, length, fps, steps, seed, sampler, scheduler, fileSel, prompt],
  );

  const persist = useCallback(() => {
    if (!booted.current) return;
    saveSession("video", collect());
  }, [collect]);

  useEffect(() => {
    const onUnload = () => saveSession("video", collect());
    window.addEventListener("beforeunload", onUnload);
    return () => window.removeEventListener("beforeunload", onUnload);
  }, [collect]);

  /* shared ws: progress + queue for the active job */
  useComfyWs((msg) => {
    const job = jobRef.current;
    const d = (msg as any).data || {};
    if (msg.type === "status") {
      if (typeof d?.status?.exec_info?.queue_remaining === "number") setQueueN(d.status.exec_info.queue_remaining);
      return;
    }
    if (!job || job.done || d.prompt_id !== job.promptId) return;
    if (msg.type === "execution_start") setJobState("Sampling…");
    else if (msg.type === "executing") setJobState("Working…");
    else if (msg.type === "progress" && d.max) {
      setProgress(Math.min(100, (d.value / d.max) * 100));
      setJobState(`Sampling ${Math.min(d.value, d.max)} / ${d.max}`);
    } else if (msg.type === "execution_success") finishJob();
    else if (msg.type === "execution_error") {
      job.done = true;
      jobRef.current = null;
      stopPoll();
      setJobState("Error");
      toast(d.exception_message || d.exception_type || "Generation failed.", "error");
    }
  });

  const stopPoll = () => {
    if (pollRef.current) {
      clearInterval(pollRef.current);
      pollRef.current = null;
    }
  };

  const refreshHistory = useCallback(async () => {
    try {
      setGallery(await fetchVideoHistory(10));
    } catch {
      /* ignore */
    }
  }, []);

  const loadInputLib = useCallback(async () => {
    try {
      const imgs = await fetchInputImages();
      setInputLib(imgs.map((i: any) => ({ name: i.name, subfolder: i.subfolder || "" })));
    } catch {
      /* ignore */
    }
  }, []);

  /* boot */
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const [cfgR, filesR, histR] = await Promise.allSettled([
        fetchVideoConfig(),
        fetchVideoFiles(),
        fetchVideoHistory(10),
      ]);
      if (cancelled) return;
      if (cfgR.status === "fulfilled") {
        setModels(cfgR.value.models || []);
        if (cfgR.value.input_dir) setInputDir(cfgR.value.input_dir);
      }
      if (filesR.status === "fulfilled") setDirs(filesR.value.dirs || {});
      if (histR.status === "fulfilled") setGallery(histR.value);
      try {
        const q = await api("/lazycomfy/api/queue");
        if (!cancelled && typeof q.queue_remaining === "number") setQueueN(q.queue_remaining);
      } catch {
        /* ignore */
      }
      const saved = (await loadSession()).video;
      if (!cancelled && saved) {
        if (saved.modelId) setModelId(saved.modelId);
        if (saved.mode) setMode(saved.mode);
        if (saved.width) setWidth(saved.width);
        if (saved.height) setHeight(saved.height);
        if (saved.length) setLength(saved.length);
        if (saved.fps) setFps(saved.fps);
        if (saved.steps) setSteps(saved.steps);
        if (saved.seed != null) {
          setSeed(saved.seed);
          setRandSeed(!String(saved.seed).trim());
        }
        if (saved.sampler) setSampler(saved.sampler);
        if (saved.scheduler) setScheduler(saved.scheduler);
        if (saved.fileSel) setFileSel(saved.fileSel);
        if (saved.prompt) setPrompt(saved.prompt);
      }
      await loadInputLib();
      if (!cancelled) booted.current = true;
    })();
    fetchCatalog().catch(() => {});
    return () => {
      cancelled = true;
      stopPoll();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  /* apply model defaults on select */
  useEffect(() => {
    if (!model || !booted.current) return;
    const d = model.defaults || {};
    const l = model.limits || {};
    if (d.width) setWidth(String(d.width));
    if (d.height) setHeight(String(d.height));
    if (d.length) setLength(String(d.length));
    if (d.fps) setFps(String(d.fps));
    if (d.steps) setSteps(String(d.steps));
    if (d.sampler) setSampler(d.sampler);
    if (d.scheduler) setScheduler(d.scheduler);
    if (!model.modes.includes(mode)) setMode(model.modes[0]);
    void l;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [modelId]);

  const missing = (): string[] => {
    if (!model) return ["model"];
    const sel = fileSel[model.id] || {};
    return model.files
      .filter((f) => {
        const chosen = sel[f.kind] || f.name;
        return !(dirs[f.dir] || []).includes(chosen);
      })
      .map((f) => f.label);
  };

  const loraOptions = (): string[] => {
    const local = dirs["loras"] || [];
    return [...new Set(local)];
  };

  const handleFile = async (file?: File | null) => {
    if (!file) return;
    if (!/^image\/(png|jpeg|webp)$/.test(file.type || "")) {
      toast("Only PNG, JPEG or WebP images are accepted.", "error");
      return;
    }
    try {
      const r = await uploadImage(file);
      const entry = { name: r.name, subfolder: r.subfolder || "", blobUrl: URL.createObjectURL(file) };
      setInputImage(entry);
      persist();
      loadInputLib();
      toast("Image uploaded: " + r.name, "ok");
    } catch (e) {
      toast(errMsg(e), "error");
    }
  };

  const pickFromLib = (value: string) => {
    if (!value) {
      setInputImage(null);
      return;
    }
    const found = inputLib.find((i) => (i.subfolder ? i.subfolder + "/" : "") + i.name === value);
    if (found) setInputImage({ name: found.name, subfolder: found.subfolder || "" });
  };

  const previewSrc = (): string => {
    if (!inputImage) return "";
    if (inputImage.blobUrl) return inputImage.blobUrl;
    return (
      "/view?filename=" +
      encodeURIComponent(inputImage.name) +
      "&subfolder=" +
      encodeURIComponent(inputImage.subfolder || "") +
      "&type=input"
    );
  };

  const generate = async () => {
    if (jobRef.current) return;
    if (!model) {
      toast("Pick a model first.", "error");
      return;
    }
    const miss = missing();
    if (miss.length) {
      toast("Missing: " + miss.join(", "), "error");
      return;
    }
    if (mode === "t2i" && !prompt.trim()) {
      toast("Describe your video first.", "error");
      return;
    }
    if (mode === "i2i" && !inputImage) {
      toast("Pick an input image first.", "error");
      return;
    }
    const l = model.limits || {};
    const d = model.defaults || {};
    const seedVal = randSeed ? Math.floor(Math.random() * 9007199254740991) : clampInt(seed, 0, 9007199254740991, 0);
    const body: Record<string, any> = {
      model_id: model.id,
      mode,
      prompt,
      width: clampInt(width, l.width_min ?? 32, l.width_max ?? 2048, d.width ?? 1280),
      height: clampInt(height, l.height_min ?? 32, l.height_max ?? 2048, d.height ?? 736),
      length: clampInt(length, l.length_min ?? 5, l.length_max ?? 361, d.length ?? 97),
      fps: clampInt(fps, 1, 60, d.fps ?? 24),
      steps: clampInt(steps, l.steps_min ?? 1, l.steps_max ?? 50, d.steps ?? 8),
      sampler: sampler || d.sampler,
      scheduler: scheduler || d.scheduler,
      seed: seedVal,
      client_id: getClientId(),
    };
    const sel = fileSel[model.id] || {};
    const files: Record<string, string> = {};
    for (const f of model.files) if (sel[f.kind]) files[f.kind] = sel[f.kind];
    if (Object.keys(files).length) body.files = files;
    const loras: { name: string; strength: number }[] = [];
    if (lora) loras.push({ name: lora, strength: parseFloat(loraStrength) || 1 });
    for (const s of loraStack) if (s.name) loras.push({ name: s.name, strength: s.strength || 1 });
    if (loras.length) body.loras = loras;
    if (mode === "i2i" && inputImage) body.image = { name: inputImage.name, subfolder: inputImage.subfolder || "" };
    try {
      const r = await submitVideo(body);
      jobRef.current = { promptId: r.prompt_id, startedAt: Date.now(), done: false };
      setCurrent(null);
      setJobState("Queueing…");
      setProgress(0);
      stopPoll();
      pollRef.current = setInterval(() => void pollOnce(), 3000);
    } catch (e) {
      toast(errMsg(e), "error");
      setJobState("Error");
    }
  };

  const pollOnce = async () => {
    const job = jobRef.current;
    if (!job || job.done) {
      stopPoll();
      return;
    }
    try {
      const r = await fetchVideoResult(job.promptId);
      if (r.status === "success" || r.status === "error") finishJob();
    } catch {
      /* keep polling */
    }
  };

  const finishJob = async () => {
    const job = jobRef.current;
    if (!job || job.done) return;
    stopPoll();
    const elapsed = ((Date.now() - job.startedAt) / 1000).toFixed(1);
    try {
      const r = await fetchVideoResult(job.promptId);
      if (r.status === "unknown" || (r.status === "success" && !(r.videos?.length || r.outputs?.length))) {
        setTimeout(() => {
          if (jobRef.current === job) finishJob();
        }, 1500);
        return;
      }
      job.done = true;
      jobRef.current = null;
      if (r.status === "error") {
        setJobState("Error");
        toast((r.error && (r.error.message || r.error.type)) || "Generation failed.", "error");
        return;
      }
      const vids = r.videos?.length ? r.videos : r.outputs;
      if (vids?.length) {
        setJobState("Done in " + elapsed + "s");
        showResult({ videos: vids, meta: r.meta, elapsed });
      } else {
        setJobState("Done in " + elapsed + "s");
      }
    } catch (e) {
      job.done = true;
      jobRef.current = null;
      setJobState("Error");
      toast(errMsg(e), "error");
    }
    refreshHistory();
  };

  const showResult = (res: { videos: MediaFile[]; meta?: any; elapsed?: string }) => {
    const kept = res.videos.filter((v) => !deleted.has(fileKey(v)));
    if (!kept.length) return;
    setCurrent({ videos: kept, meta: res.meta });
    const v = kept[0];
    const m = res.meta || {};
    const mod = models.find((x) => x.id === m.model_id);
    let meta = "";
    if (mod) {
      meta = `${mod.name} · ${m.mode === "i2i" ? "img2vid" : "text2vid"} · ${m.params?.width ?? "?"}×${m.params?.height ?? "?"} · ${m.params?.length ?? "?"} frames @ ${m.params?.fps ?? 24}fps · ${m.params?.steps ?? "?"} steps`;
      if (res.elapsed) meta += " · " + res.elapsed + "s";
    } else {
      meta = v.filename + (res.elapsed ? " · " + res.elapsed + "s" : "");
    }
    setMetaLine(meta);
  };

  const cancel = async () => {
    const job = jobRef.current;
    if (!job) return;
    try {
      await cancelVideo(job.promptId);
    } catch {
      /* ignore */
    }
    setTimeout(() => {
      if (jobRef.current?.promptId === job.promptId) {
        stopPoll();
        jobRef.current = null;
        setJobState("Cancelled");
      }
    }, 4000);
  };

  const reuse = () => {
    const m = current?.meta;
    if (!m) return;
    if (m.model_id) setModelId(m.model_id);
    if (m.mode) setMode(m.mode);
    const p = m.params || {};
    if (m.prompt != null) setPrompt(m.prompt);
    if (p.width) setWidth(String(p.width));
    if (p.height) setHeight(String(p.height));
    if (p.length) setLength(String(p.length));
    if (p.fps) setFps(String(p.fps));
    if (p.steps) setSteps(String(p.steps));
    if (p.sampler) setSampler(p.sampler);
    if (p.scheduler) setScheduler(p.scheduler);
    toast("Settings restored.", "ok");
  };

  const delCurrent = async () => {
    const v = current?.videos?.[0];
    if (!v?.filename) return;
    try {
      await deleteMedia(v);
      toast("Video deleted.", "ok");
    } catch (e) {
      toast(errMsg(e), "error");
      return;
    }
    setDeleted((prev) => new Set(prev).add(fileKey(v)));
    setCurrent(null);
    setMetaLine("");
    refreshHistory();
  };

  const miss = missing();
  const cur = current?.videos?.[0];
  const lengthHint =
    model && length && fps
      ? `${length} frames @ ${fps}fps ≈ ${(parseInt(length, 10) / Math.max(1, parseInt(fps, 10))).toFixed(1)}s`
      : "";

  return (
    <main className="layout">
      <section className="panel">
        <div className="group">
          <label className="group-label">Model</label>
          <div className="field">
            <Select
              value={modelId || ""}
              options={models.map((m) => ({ value: m.id, label: m.name }))}
              onChange={(v) => {
                setModelId(v || null);
                persist();
              }}
              placeholder="Select a model…"
            />
            {model && <p className="note">{model.name}</p>}
          </div>
          {model && (
            <div className="field">
              <div className="seg" role="group">
                {model.modes.map((md) => (
                  <button key={md} type="button" className={mode === md ? "active" : ""} onClick={() => { setMode(md); persist(); }}>
                    {md === "i2i" ? "Image to video" : "Text to video"}
                  </button>
                ))}
              </div>
            </div>
          )}
          {miss.length > 0 && model && <div className="err-banner">Missing files: {miss.join(", ")} — download them from the main page.</div>}
        </div>

        {model && (
          <div className="group">
            <label className="group-label">Files</label>
            {(fileSel[model.id] ? model.files : model.files).map((f) => (
              <div className="field" key={f.kind}>
                <label>{f.label}</label>
                <Select
                  value={(fileSel[model.id] || {})[f.kind] || ""}
                  options={[
                    { value: "", label: `Template default — ${f.name}` },
                    ...(dirs[f.dir] || []).map((n) => ({ value: n, label: n + (n === f.name ? " (default)" : "") })),
                  ]}
                  onChange={(v) => {
                    setFileSel((prev) => {
                      const next = { ...(prev[model.id] || {}) };
                      if (v) next[f.kind] = v;
                      else delete next[f.kind];
                      return { ...prev, [model.id]: next };
                    });
                    persist();
                  }}
                />
              </div>
            ))}
            <div className="field">
              <label>LoRA (optional)</label>
              <Select
                value={lora}
                options={[{ value: "", label: "None" }, ...loraOptions().map((n) => ({ value: n, label: n }))]}
                onChange={(v) => { setLora(v); persist(); }}
              />
            </div>
            {lora && (
              <div className="field">
                <label>LoRA strength ({parseFloat(loraStrength) || 1})</label>
                <input type="number" min={0} max={5} step={0.05} value={loraStrength} onChange={(e) => { setLoraStrength(e.target.value); persist(); }} />
              </div>
            )}
            {loraStack.map((s, i) => (
              <div className="field" key={i} style={{ display: "flex", gap: 8 }}>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <Select
                    value={s.name}
                    options={[{ value: "", label: "None" }, ...loraOptions().map((n) => ({ value: n, label: n }))]}
                    onChange={(v) => {
                      const next = [...loraStack];
                      next[i] = { ...next[i], name: v };
                      setLoraStack(next);
                    }}
                  />
                </div>
                <input style={{ width: 80 }} type="number" min={0} max={5} step={0.05} value={s.strength} onChange={(e) => {
                  const next = [...loraStack];
                  next[i] = { ...next[i], strength: parseFloat(e.target.value) || 1 };
                  setLoraStack(next);
                }} />
                <button className="act-btn" type="button" onClick={() => setLoraStack(loraStack.filter((_, j) => j !== i))}>✕</button>
              </div>
            ))}
            {loraStack.length < 4 && (
              <button className="act-btn" type="button" onClick={() => setLoraStack([...loraStack, { name: "", strength: 1 }])}>
                + LoRA
              </button>
            )}
          </div>
        )}

        {mode === "i2i" && (
          <div className="group">
            <label className="group-label">Input image</label>
            <div className="dz" role="button" tabIndex={0} onClick={() => fileInputRef.current?.click()} onKeyDown={(e) => e.key === "Enter" && fileInputRef.current?.click()}>
              {inputImage ? (
                <>
                  {/* eslint-disable-next-line @next/next/no-img-element */}
                  {previewSrc() && <img src={previewSrc()} alt="Input preview" />}
                  <div>{inputImage.name}</div>
                </>
              ) : (
                "Click or drop an image here"
              )}
            </div>
            <input ref={fileInputRef} type="file" accept="image/png,image/jpeg,image/webp" hidden onChange={(e) => { handleFile(e.target.files?.[0]); e.target.value = ""; }} />
            <div className="field" style={{ marginTop: 8 }}>
              <label>Or pick from input folder</label>
              <Select
                value={inputImage && !inputImage.blobUrl ? (inputImage.subfolder ? inputImage.subfolder + "/" : "") + inputImage.name : ""}
                options={[
                  { value: "", label: inputLib.length ? "Choose an image…" : "No images…" },
                  ...inputLib.map((x) => {
                    const v = (x.subfolder ? x.subfolder + "/" : "") + x.name;
                    return { value: v, label: v };
                  }),
                ]}
                onChange={pickFromLib}
              />
            </div>
            {inputImage && (
              <button className="act-btn danger" type="button" onClick={() => setInputImage(null)}>
                Remove image
              </button>
            )}
          </div>
        )}

        <div className="group">
          <label className="group-label">Prompt & dimensions</label>
          <div className="field">
            <label htmlFor="vprompt">Prompt</label>
            <textarea id="vprompt" value={prompt} onChange={(e) => { setPrompt(e.target.value); persist(); }} placeholder="Describe your video…" />
          </div>
          <div className="grid2">
            <div className="field">
              <label>Width</label>
              <input type="number" value={width} onChange={(e) => { setWidth(e.target.value); persist(); }} />
            </div>
            <div className="field">
              <label>Height</label>
              <input type="number" value={height} onChange={(e) => { setHeight(e.target.value); persist(); }} />
            </div>
            <div className="field">
              <label>Frames</label>
              <input type="number" value={length} onChange={(e) => { setLength(e.target.value); persist(); }} />
            </div>
            <div className="field">
              <label>FPS</label>
              <input type="number" min={1} max={60} value={fps} onChange={(e) => { setFps(e.target.value); persist(); }} />
            </div>
            <div className="field">
              <label>Steps</label>
              <input type="number" value={steps} onChange={(e) => { setSteps(e.target.value); persist(); }} />
            </div>
            <div className="field">
              <label>Seed</label>
              <input type="number" value={seed} placeholder={randSeed ? "random" : ""} onChange={(e) => { setSeed(e.target.value); setRandSeed(!e.target.value.trim()); persist(); }} />
            </div>
          </div>
          {lengthHint && <p className="note">{lengthHint}</p>}
          <div className="grid2" style={{ marginTop: 8 }}>
            <div className="field">
              <label>Sampler</label>
              <Select
                value={sampler}
                options={(model?.options.samplers || []).map((s) => ({ value: s, label: s }))}
                onChange={(v) => { setSampler(v); persist(); }}
              />
            </div>
            <div className="field">
              <label>Scheduler</label>
              <Select
                value={scheduler}
                options={(model?.options.schedulers || []).map((s) => ({ value: s, label: s }))}
                onChange={(v) => { setScheduler(v); persist(); }}
              />
            </div>
          </div>
        </div>

        <div style={{ display: "flex", gap: 8 }}>
          <button className="btn btn-primary" type="button" disabled={!!jobRef.current || miss.length > 0} onClick={generate} style={{ flex: 1 }}>
            {jobRef.current ? "Working…" : "Generate"}
          </button>
          {jobRef.current && (
            <button className="btn btn-danger" type="button" onClick={cancel}>
              Cancel
            </button>
          )}
        </div>
        {queueN > 0 && <p className="note">{queueN} job{queueN === 1 ? "" : "s"} in queue</p>}
      </section>

      <section className="panel">
        <div className="group">
          <label className="group-label">Result</label>
          <div className="status-strip">
            <span className="job-state">{jobState}</span>
          </div>
          {progress !== null && jobRef.current && (
            <div className="progress-wrap">
              <div className="progress-bar" style={{ width: progress + "%" }} />
            </div>
          )}
        </div>
        <div className="view">
          {!cur && (
            <div className="placeholder">
              <p>Pick a model and describe your video</p>
            </div>
          )}
          {cur && (
            <video src={cur.url} controls playsInline />
          )}
        </div>
        {metaLine && <div className="meta-line">{metaLine}</div>}
        {cur && (
          <div className="row-actions">
            <button className="act-btn" type="button" onClick={() => window.open(cur.url, "_blank")}>
              Open
            </button>
            <a className="act-btn" href={cur.url} download={cur.filename || "lazycomfy-video.mp4"}>
              Download
            </a>
            <button className="act-btn danger" type="button" onClick={delCurrent}>
              Delete
            </button>
            <button className="act-btn" type="button" onClick={reuse}>
              Reuse settings
            </button>
          </div>
        )}
        <div className="gallery-wrap">
          <h3>Recent videos</h3>
          <div className="gallery">
            {gallery
              .map((j) => ({
                ...j,
                videos: (j.videos || []).filter((v) => !deleted.has(fileKey(v))),
                images: (j.images || []).filter((v) => !deleted.has(fileKey(v))),
              }))
              .filter((j) => (j.videos?.length || j.images?.length))
              .map((j) => {
                const v = (j.videos?.[0] || j.images?.[0]) as MediaFile;
                const mod = models.find((x) => x.id === j.model_id);
                const isVid = v.filename && /\.(mp4|webm|mov|mkv)$/i.test(v.filename);
                return (
                  <button
                    key={j.prompt_id}
                    type="button"
                    className="g-item"
                    title={(j.prompt || "").slice(0, 140) || "output"}
                    onClick={() => {
                      const vids = j.videos?.length ? j.videos : (j.images as MediaFile[]);
                      setCurrent({ videos: vids, meta: { model_id: j.model_id, mode: j.mode, prompt: j.prompt, params: j.params } });
                      setJobState("Done");
                      setMetaLine(`${mod?.name || j.model_id || "video"} · ${v.filename}`);
                    }}
                  >
                    {isVid ? (
                      // eslint-disable-next-line jsx-a11y/media-has-caption
                      <video src={v.url} muted playsInline preload="metadata" />
                    ) : (
                      // eslint-disable-next-line @next/next/no-img-element
                      <img loading="lazy" src={v.url} alt="" />
                    )}
                    <span className="g-badge">{mod ? mod.name : j.model_id || "video"}</span>
                  </button>
                );
              })}
            {gallery.length === 0 && <p className="g-empty">No generations yet</p>}
          </div>
        </div>
      </section>
    </main>
  );
}
