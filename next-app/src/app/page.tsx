"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import {
  api,
  errMsg,
  fmtSize,
  fetchModels,
  fetchHistory,
  submitGenerate,
  cancelJob,
  fetchResult,
  uploadImage,
  deleteMedia,
  fetchInputImages,
  fetchCatalog,
  fetchHfToken,
  fetchVideoConfig,
  startDownload,
  cancelDownload,
  startLoraDownload,
  startGenericDownload,
  loadSession,
  saveSession,
  ModelDef,
  JobEntry,
  MediaFile,
} from "@/lib/api";
import { useToast, getClientId, useComfyWs } from "@/lib/store";
import { Select, Switch } from "@/components/controls";

interface InputImage {
  name: string;
  subfolder?: string;
  blobUrl?: string;
}

const clampInt = (v: any, lo: number, hi: number, dflt?: number): number => {
  const n = parseInt(v, 10);
  if (!Number.isFinite(n)) return dflt ?? lo;
  return Math.max(lo, Math.min(hi, n));
};

const maxImagesFor = (m: ModelDef | null): number => {
  if (!m) return 1;
  const n = parseInt((m as any).max_images, 10);
  if (!Number.isFinite(n)) return 1;
  return Math.max(1, Math.min(10, n));
};

const fileKey = (f: { subfolder?: string; filename?: string }) =>
  (f.subfolder || "") + "/" + (f.filename || "");

const isQwen21 = (id: string) => id === "qwen_image_2_1" || id === "qwen_image_2_1_turbo";

export default function ImagesPage() {
  const toast = useToast();
  const [models, setModels] = useState<ModelDef[]>([]);
  const [modelId, setModelId] = useState<string | null>(null);
  const [mode, setMode] = useState<"t2i" | "i2i">("t2i");
  const [prompt, setPrompt] = useState("");
  const [negPrompt, setNegPrompt] = useState("");
  const [width, setWidth] = useState("1024");
  const [height, setHeight] = useState("1024");
  const [steps, setSteps] = useState("8");
  const [cfg, setCfg] = useState("1");
  const [sampler, setSampler] = useState("");
  const [scheduler, setScheduler] = useState("");
  const [seed, setSeed] = useState("");
  const [randSeed, setRandSeed] = useState(true);
  const [batch, setBatch] = useState("1");
  const [denoise, setDenoise] = useState("0.5");
  const [qwenRes, setQwenRes] = useState("");
  const [preset, setPreset] = useState("");
  const [enhance, setEnhance] = useState(false);
  const [fileSel, setFileSel] = useState<Record<string, Record<string, string>>>({});
  const [lora, setLora] = useState("");
  const [loraStrength, setLoraStrength] = useState("1");
  const [loraStack, setLoraStack] = useState<{ name: string; strength: number }[]>([]);
  const [inputImages, setInputImages] = useState<InputImage[]>([]);
  const [inputLib, setInputLib] = useState<{ name: string; subfolder?: string }[]>([]);
  const [dirFiles, setDirFiles] = useState<Record<string, string[]>>({});
  const [dirFilesLoaded, setDirFilesLoaded] = useState(false);
  const [catalog, setCatalog] = useState<any>(null);
  const [jobState, setJobState] = useState("Idle");
  const [progress, setProgress] = useState<number | null>(null);
  const [current, setCurrent] = useState<{ images: MediaFile[]; meta?: any; promptId?: string } | null>(null);
  const [metaLine, setMetaLine] = useState("");
  const [gallery, setGallery] = useState<JobEntry[]>([]);
  const [deleted, setDeleted] = useState<Set<string>>(new Set());
  const [queueN, setQueueN] = useState(0);
  const [dlOpen, setDlOpen] = useState(false);
  const [sysInfo, setSysInfo] = useState<any>(null);
  const jobRef = useRef<{ promptId: string; startedAt: number; done: boolean } | null>(null);
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const booted = useRef(false);

  const model = models.find((m) => m.id === modelId) || null;
  const maxN = maxImagesFor(model);

  /* Live mirror: persist() must read post-setState values. A plain closure
     would save the pre-update snapshot (setTimeout fires before re-render),
     and rapid fire-and-forget saves could land out of order. */
  const live = useRef<any>({});
  live.current = {
    modelId,
    mode,
    prompt,
    negPrompt,
    steps,
    cfg,
    sampler,
    scheduler,
    width,
    height,
    seed,
    batch,
    denoise,
    qwenRes,
    enhance,
    inputImages,
    fileSel,
    lora,
    loraStrength,
    loraStack,
  };

  const collect = useCallback(() => {
    const s = live.current;
    return {
      modelId: s.modelId,
      mode: s.mode,
      prompt: s.prompt,
      negPrompt: s.negPrompt,
      steps: s.steps,
      cfg: s.cfg,
      sampler: s.sampler,
      scheduler: s.scheduler,
      width: s.width,
      height: s.height,
      seed: s.seed,
      batch: s.batch,
      denoise: s.denoise,
      qwenResolution: s.qwenRes,
      enhance: s.enhance,
      inputImages: (s.inputImages || []).map((e: InputImage) => ({ name: e.name, subfolder: e.subfolder || "" })),
      fileSel: s.fileSel,
      lora: s.lora,
      loraStrength: s.loraStrength,
      loraStack: s.loraStack,
    };
  }, []);

  const persist = useCallback(() => {
    if (!booted.current) return;
    saveSession("main", collect());
  }, [collect]);

  useEffect(() => {
    const onUnload = () => saveSession("main", collect());
    window.addEventListener("beforeunload", onUnload);
    return () => window.removeEventListener("beforeunload", onUnload);
  }, [collect]);

  /* shared ws */
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
    } else if (msg.type === "execution_interrupted") {
      job.done = true;
      jobRef.current = null;
      stopPoll();
      setJobState("Cancelled");
      toast("Run cancelled.", "");
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
      setGallery(await fetchHistory(10));
    } catch {
      /* ignore */
    }
  }, []);

  const refreshDirFiles = useCallback(async () => {
    try {
      const r = await api("/lazycomfy/api/files");
      setDirFiles(r.dirs || {});
      setDirFilesLoaded(true);
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
    const openDl = () => setDlOpen(true);
    window.addEventListener("lazycomfy:open-downloads", openDl);
    try {
      if (sessionStorage.getItem("lazycomfy.openDl") === "1") {
        sessionStorage.removeItem("lazycomfy.openDl");
        setDlOpen(true);
      }
    } catch {
      /* ignore */
    }
    return () => window.removeEventListener("lazycomfy:open-downloads", openDl);
  }, []);

  /* boot data */
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const [modsR, histR, queueR, filesR, catR, cfgR] = await Promise.allSettled([
        fetchModels(),
        fetchHistory(10),
        api("/lazycomfy/api/queue"),
        api("/lazycomfy/api/files"),
        fetchCatalog(),
        api("/lazycomfy/api/config"),
      ]);

      if (cancelled) return;
      if (modsR.status === "fulfilled") setModels(modsR.value);
      if (histR.status === "fulfilled") setGallery(histR.value);
      if (queueR.status === "fulfilled" && typeof (queueR.value as any).queue_remaining === "number")
        setQueueN((queueR.value as any).queue_remaining);
      if (filesR.status === "fulfilled") {
        setDirFiles((filesR.value as any).dirs || {});
        setDirFilesLoaded(true);
      }
      if (catR.status === "fulfilled") setCatalog(catR.value);
      if (cfgR.status === "fulfilled") setSysInfo(cfgR.value);
      const saved = (await loadSession()).main;
      if (!cancelled && saved) {
        if (saved.modelId) setModelId(saved.modelId);
        else {
          try {
            const last = localStorage.getItem("lazycomfy.model");
            if (last) setModelId(last);
          } catch {
            /* ignore */
          }
        }
        if (saved.mode === "i2i" || saved.mode === "t2i") setMode(saved.mode);
        if (saved.prompt != null) setPrompt(saved.prompt);
        if (saved.negPrompt != null) setNegPrompt(saved.negPrompt);
        if (saved.steps != null) setSteps(saved.steps);
        if (saved.cfg != null) setCfg(saved.cfg);
        if (saved.sampler) setSampler(saved.sampler);
        if (saved.scheduler) setScheduler(saved.scheduler);
        if (saved.width) setWidth(saved.width);
        if (saved.height) setHeight(saved.height);
        if (saved.seed != null) {
          setSeed(saved.seed);
          setRandSeed(!String(saved.seed).trim());
        }
        if (saved.batch) setBatch(saved.batch);
        if (saved.denoise) setDenoise(saved.denoise);
        if (saved.qwenResolution) setQwenRes(saved.qwenResolution);
        if (saved.enhance) setEnhance(true);
        if (saved.fileSel) setFileSel(saved.fileSel);
        if (saved.lora) setLora(saved.lora);
        if (saved.loraStrength != null) setLoraStrength(saved.loraStrength);
        if (Array.isArray(saved.loraStack)) setLoraStack(saved.loraStack);
        if (Array.isArray(saved.inputImages)) setInputImages(saved.inputImages);
      } else if (!cancelled) {
        try {
          const last = localStorage.getItem("lazycomfy.model");
          if (last) setModelId(last);
        } catch {
          /* ignore */
        }
      }
      loadInputLib();
      if (!cancelled) booted.current = true;
    })();
    return () => {
      cancelled = true;
      stopPoll();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  /* model defaults on select */
  const selectModel = (id: string | null) => {
    setModelId(id);
    try {
      if (id) localStorage.setItem("lazycomfy.model", id);
    } catch {
      /* ignore */
    }
    const m = models.find((x) => x.id === id);
    if (!m) return;
    const d = m.defaults || {};
    const l = m.limits || {};
    if (d.width) setWidth(String(d.width));
    if (d.height) setHeight(String(d.height));
    if (d.steps) setSteps(String(d.steps));
    if (d.cfg != null) setCfg(String(d.cfg));
    if (d.sampler) setSampler(d.sampler);
    if (d.scheduler) setScheduler(d.scheduler);
    if (d.batch) setBatch(String(d.batch));
    if (d.denoise != null) setDenoise(String(d.denoise));
    if ((d as any).resolution) setQwenRes(String((d as any).resolution));
    if (!m.modes.includes(mode)) setMode(m.modes[0] as "t2i" | "i2i");
    setPreset("");
    void l;
    setTimeout(persist, 0);
  };

  const setModeAndSide = (md: "t2i" | "i2i") => {
    setMode(md);
    if (md === "i2i") loadInputLib();
    setTimeout(persist, 0);
  };

  /* file gating */
  const dirHas = (dir: string, name: string) => (dirFiles[dir] || []).includes(name);
  const kindSatisfied = (m: ModelDef, f: { kind: string; dir: string; name: string; present?: boolean }): boolean => {
    if (f.present) return true;
    if (dirHas(f.dir, f.name)) return true;
    const items = catalog?.items || [];
    return items.some(
      (it: any) =>
        it.model_id === m.id &&
        it.kind === f.kind &&
        (it.present || dirHas(it.target_dir || f.dir, it.target_name)),
    );
  };

  const missingFiles = (): string[] => {
    if (!model || !dirFilesLoaded) return [];
    const sel = fileSel[model.id] || {};
    return model.files
      .filter((f) => !dirHas(f.dir, sel[f.kind] || f.name))
      .map((f) => f.label);
  };

  const loraOptions = (): string[] => {
    const local = dirFiles["loras"] || [];
    const cat = (catalog?.items || [])
      .filter((it: any) => it.kind === "lora" && (!model || it.model_id === model.id))
      .map((it: any) => it.target_name);
    return [...new Set([...local, ...cat])];
  };

  /* input images */
  const addInputImages = (entries: InputImage[]) => {
    const room = maxN - inputImages.length;
    if (room <= 0) {
      if (mode === "i2i") toast(`Maximum ${maxN} image${maxN === 1 ? "" : "s"}.`, "error");
      return;
    }
    const fresh: InputImage[] = [];
    for (const e of entries.slice(0, room)) {
      if (inputImages.some((x) => x.name === e.name && (x.subfolder || "") === (e.subfolder || "")) || fresh.some((x) => x.name === e.name)) {
        toast(e.name + " already added.", "error");
        continue;
      }
      fresh.push(e);
    }
    if (fresh.length) {
      setInputImages((prev) => [...prev, ...fresh]);
      setTimeout(persist, 0);
    }
  };

  const handleFiles = async (files: FileList | File[] | null) => {
    if (!files?.length) return;
    const list = [...files];
    const room = mode === "i2i" ? maxN - inputImages.length : 0;
    if (room <= 0) {
      if (mode === "i2i") toast(`Maximum ${maxN} image${maxN === 1 ? "" : "s"}.`, "error");
      return;
    }
    let ok = 0;
    for (const f of list.slice(0, room)) {
      if (!/^image\/(png|jpeg|webp)$/.test(f.type || "")) {
        toast(f.name + ": only PNG, JPEG or WebP.", "error");
        continue;
      }
      try {
        const r = await uploadImage(f);
        addInputImages([{ name: r.name, subfolder: r.subfolder || "", blobUrl: URL.createObjectURL(f) }]);
        ok++;
      } catch (e) {
        toast(errMsg(e), "error");
      }
    }
    if (ok) {
      toast(`${ok} image${ok === 1 ? "" : "s"} uploaded.`, "ok");
      loadInputLib();
    }
  };

  const primaryPreview = (): string => {
    const e = inputImages[0];
    if (!e) return "";
    if (e.blobUrl) return e.blobUrl;
    return (
      "/view?filename=" +
      encodeURIComponent(e.name) +
      "&subfolder=" +
      encodeURIComponent(e.subfolder || "") +
      "&type=input"
    );
  };

  /* generate */
  const generate = async () => {
    if (jobRef.current || !model) return;
    if (mode === "i2i" && !inputImages.length) {
      toast("Add an input image first.", "error");
      return;
    }
    if (mode === "t2i" && !prompt.trim()) {
      toast("Describe your image first.", "error");
      return;
    }
    const miss = missingFiles();
    if (miss.length) {
      toast("Missing: " + miss.join(", "), "error");
      return;
    }
    const m = model;
    const l = m.limits || {};
    const d = m.defaults || {};
    const presetOpts = m.options?.presets?.options || [];
    let stepsVal = clampInt(steps, l.steps_min ?? 1, l.steps_max ?? 100, d.steps ?? 8);
    const presetOpt = presetOpts.find((o) => o.id === preset);
    if (presetOpt && presetOpt.steps != null) stepsVal = clampInt(presetOpt.steps, l.steps_min ?? 1, l.steps_max ?? 100);
    const seedVal = randSeed ? Math.floor(Math.random() * 9007199254740991) : clampInt(seed, 0, 9007199254740991);
    const body: Record<string, any> = {
      model_id: m.id,
      mode,
      prompt,
      width: clampInt(width, l.width_min ?? 64, l.width_max ?? 2048),
      height: clampInt(height, l.height_min ?? 64, l.height_max ?? 2048),
      steps: stepsVal,
      cfg: Number.isFinite(parseFloat(cfg)) ? parseFloat(cfg) : d.cfg,
      sampler: sampler || d.sampler,
      scheduler: scheduler || d.scheduler,
      seed: seedVal,
      batch: mode === "i2i" ? 1 : clampInt(batch, 1, l.batch_max ?? 4),
      client_id: getClientId(),
    };
    if (m.supports_negative) body.negative_prompt = negPrompt;
    if ((m as any).pe && enhance) body.enhance = true;
    if (presetOpts.length) body.preset = preset;
    const sel = fileSel[m.id] || {};
    const files: Record<string, string> = {};
    for (const f of m.files) if (sel[f.kind]) files[f.kind] = sel[f.kind];
    if (Object.keys(files).length) body.files = files;
    const loras: { name: string; strength: number }[] = [];
    if (lora) loras.push({ name: lora, strength: parseFloat(loraStrength) || 1 });
    for (const s of loraStack) if (s.name) loras.push({ name: s.name, strength: s.strength || 1 });
    if (loras.length) body.loras = loras;
    if (mode === "i2i") {
      const imgs = inputImages.map((e) => ({ name: e.name, subfolder: e.subfolder || "" }));
      body.image = imgs[0];
      if (maxN > 1) body.images = imgs;
      if (isQwen21(m.id)) {
        body.resolution = Math.max(0, Math.min(4096, parseInt(qwenRes, 10) || (d as any).resolution || 1024));
      } else {
        body.denoise = parseFloat(denoise) || d.denoise;
      }
    }
    try {
      const r = await submitGenerate(body);
      jobRef.current = { promptId: r.prompt_id, startedAt: Date.now(), done: false };
      setCurrent(null);
      setMetaLine("");
      setJobState("Queueing…");
      setProgress(0);
      stopPoll();
      pollRef.current = setInterval(() => void pollOnce(), 5000);
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
      const r = await fetchResult(job.promptId);
      if (r.status === "success" || r.status === "error") finishJob();
    } catch {
      /* keep polling */
    }
  };

  const finishJob = async () => {
    const job = jobRef.current;
    if (!job || job.done) return;
    stopPoll();
    const elapsed = ((Date.now() - job.startedAt) / 1000).toFixed(0);
    try {
      const r = await fetchResult(job.promptId);
      if (r.status === "unknown" || (r.status === "success" && !(r.outputs?.length))) {
        setTimeout(() => {
          if (jobRef.current === job) finishJob();
        }, 1500);
        return;
      }
      job.done = true;
      jobRef.current = null;
      if (r.status === "error") {
        setJobState("Error");
        toast(r.error?.message || r.error?.exception_type || "Generation failed.", "error");
        return;
      }
      if (r.outputs?.length) {
        setJobState("Done in " + elapsed + "s");
        showResult({ images: r.outputs, meta: r.meta, promptId: job.promptId, elapsed });
      }
    } catch (e) {
      job.done = true;
      jobRef.current = null;
      setJobState("Error");
      toast(errMsg(e), "error");
    }
    refreshHistory();
  };

  const buildMeta = (res: { images: MediaFile[]; meta?: any; elapsed?: string }): string => {
    const mta = res.meta || {};
    const mod = models.find((x) => x.id === mta.model_id);
    const img = res.images[0];
    if (!mod) return `${img.filename} · ${res.elapsed || ""}s`;
    const p = mta.params || {};
    let meta = `${mod.name} · ${mta.mode === "i2i" ? "img2img" : "text2img"}`;
    if (p.width && p.height) meta += ` · ${p.width}×${p.height}`;
    if (p.steps) meta += ` · ${p.steps} steps`;
    if (p.cfg) meta += ` · guidance ${p.cfg}`;
    if (p.sampler) meta += ` · ${p.sampler}`;
    if (p.enhance) meta += " · +PE";
    if (Array.isArray(p.loras) && p.loras.length) {
      meta += " · LoRA " + p.loras.map((x: any) => String(x.name || "").replace(/\.safetensors$/i, "") + (x.strength != null ? " ×" + x.strength : "")).join(", ");
    } else if (p.lora_name) {
      meta += " · LoRA " + String(p.lora_name).replace(/\.safetensors$/i, "") + (p.lora_strength != null ? " ×" + p.lora_strength : "");
    }
    if (p.seed != null) meta += ` · seed ${p.seed}`;
    if (mta.mode === "i2i" && p.denoise != null) meta += ` · strength ${Math.round(p.denoise * 100)}%`;
    if (Array.isArray(p.images) && p.images.length > 1) meta += ` · ${p.images.length} images`;
    if (p.resolution) meta += ` · res ${p.resolution}`;
    if (res.elapsed) meta += ` · ${res.elapsed}s`;
    return meta;
  };

  const showResult = (res: { images: MediaFile[]; meta?: any; promptId?: string; elapsed?: string }) => {
    const kept = res.images.filter((f) => !deleted.has(fileKey(f)));
    if (!kept.length) return;
    setCurrent({ images: kept, meta: res.meta, promptId: res.promptId });
    setMetaLine(buildMeta({ ...res, images: kept }));
  };

  const cancel = async () => {
    const job = jobRef.current;
    if (!job) return;
    try {
      await cancelJob(job.promptId);
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

  /* actions */
  const cur = current?.images?.[0];
  const delCurrent = async () => {
    const f = current?.images?.[0];
    if (!f?.filename) return;
    try {
      await deleteMedia(f);
      toast("Image deleted.", "ok");
    } catch (e) {
      toast(errMsg(e), "error");
      return;
    }
    setDeleted((prev) => new Set(prev).add(fileKey(f)));
    const rest = (current?.images || []).slice(1);
    if (!rest.length) {
      setCurrent(null);
      setMetaLine("");
    } else {
      showResult({ images: rest, meta: current?.meta, promptId: current?.promptId });
    }
    refreshHistory();
  };

  const reuse = () => {
    const mta = current?.meta;
    if (!mta) return;
    if (mta.model_id) selectModel(mta.model_id);
    if (mta.mode === "i2i" || mta.mode === "t2i") setModeAndSide(mta.mode);
    const p = mta.params || {};
    if (mta.prompt != null) setPrompt(mta.prompt);
    if (mta.negative_prompt != null) setNegPrompt(mta.negative_prompt);
    if (p.width) setWidth(String(p.width));
    if (p.height) setHeight(String(p.height));
    if (p.steps) setSteps(String(p.steps));
    if (p.cfg != null) setCfg(String(p.cfg));
    const mod = models.find((x) => x.id === mta.model_id);
    if (p.sampler && mod?.options.samplers?.includes(p.sampler)) setSampler(p.sampler);
    if (p.scheduler && mod?.options.schedulers?.includes(p.scheduler)) setScheduler(p.scheduler);
    if (p.seed != null) {
      setSeed(String(p.seed));
      setRandSeed(false);
    }
    if (p.batch) setBatch(String(p.batch));
    if (p.denoise != null) setDenoise(String(p.denoise));
    if (p.enhance) setEnhance(true);
    if (Array.isArray(p.loras) && p.loras.length) {
      const [first, ...rest] = p.loras;
      setLora(first.name || "");
      setLoraStrength(String(first.strength ?? 1));
      setLoraStack(rest.map((x: any) => ({ name: x.name || "", strength: x.strength ?? 1 })));
    } else if (p.lora_name) {
      setLora(p.lora_name);
      setLoraStrength(String(p.lora_strength ?? 1));
      setLoraStack([]);
    }
    setTimeout(persist, 0);
    toast("Settings restored.", "ok");
  };

  const toI2I = async () => {
    if (!model) return;
    if (!model.modes.includes("i2i")) {
      toast(model.name + " is text-to-image only.", "error");
      return;
    }
    const url = current?.images?.[0]?.url;
    const mta = current?.meta;
    if (!url) return;
    setModeAndSide("i2i");
    try {
      const res = await fetch(url);
      const blob = await res.blob();
      let name = "source.png";
      try {
        const u = new URL(url, location.href);
        name = (u.searchParams.get("filename") || "source.png").split("/").pop() || "source.png";
      } catch {
        /* ignore */
      }
      const file = new File([blob], name, { type: blob.type || "image/png" });
      const r = await uploadImage(file);
      addInputImages([{ name: r.name, subfolder: r.subfolder || "", blobUrl: URL.createObjectURL(file) }]);
    } catch (e) {
      toast("Could not load image: " + errMsg(e), "error");
      return;
    }
    if (mta?.prompt != null) setPrompt(mta.prompt);
    if (mta?.mode === "t2i") {
      if (mta.params?.width) setWidth(String(mta.params.width));
      if (mta.params?.height) setHeight(String(mta.params.height));
    }
    setTimeout(persist, 0);
  };

  const copyPrompt = async () => {
    const txt = current?.meta?.prompt != null ? current.meta.prompt : prompt;
    try {
      await navigator.clipboard.writeText(txt);
      toast("Prompt copied.", "ok");
    } catch {
      toast("Clipboard unavailable.", "error");
    }
  };

  const miss = missingFiles();
  const presetOpts = model?.options?.presets?.options || [];
  const showEnhance = !!(model as any)?.pe;
  const showDenoise = mode === "i2i" && model && !isQwen21(model.id);
  const showQwenRes = mode === "i2i" && model && isQwen21(model.id);

  return (
    <main className="layout">
      <section className="panel">
        <div className="group">
          <label className="group-label">Model</label>
          <div className="field">
            <Select
              value={modelId || ""}
              options={models.map((m) => {
                const missing = m.files.filter((f) => !kindSatisfied(m, f)).map((f) => f.label);
                return {
                  value: m.id,
                  label: m.name,
                  hint: missing.length ? `Missing: ${missing.join(", ")}` : m.family || m.tagline || "",
                };
              })}
              onChange={(v) => selectModel(v || null)}
              placeholder={models.length ? "Select a model…" : "No models available"}
            />
            {model?.family && <p className="note">{model.family}</p>}
          </div>
          {model && (
            <div className="field">
              <div className="seg" role="group">
                {model.modes.map((md) => (
                  <button key={md} type="button" className={mode === md ? "active" : ""} onClick={() => setModeAndSide(md as "t2i" | "i2i")}>
                    {md === "i2i" ? "Image to image" : "Text to image"}
                  </button>
                ))}
              </div>
            </div>
          )}
          {miss.length > 0 && model && <div className="err-banner">Missing files: {miss.join(", ")} — download them from Models below.</div>}
        </div>

        <div className="group">
          <label className="group-label">Prompt</label>
          <div className="field">
            <textarea value={prompt} placeholder="Describe your image…" onChange={(e) => { setPrompt(e.target.value); persist(); }} />
            <p className="hint">{prompt.length} chars</p>
          </div>
          {model?.supports_negative && (
            <div className="field">
              <label>Negative prompt</label>
              <textarea value={negPrompt} onChange={(e) => { setNegPrompt(e.target.value); persist(); }} />
            </div>
          )}
          {mode === "i2i" && (
            <div className="field">
              <label>Input images ({inputImages.length}/{maxN})</label>
              <div className="dz" role="button" tabIndex={0} onClick={() => fileInputRef.current?.click()} onKeyDown={(e) => e.key === "Enter" && fileInputRef.current?.click()}>
                {inputImages[0] ? (
                  <>
                    {/* eslint-disable-next-line @next/next/no-img-element */}
                    <img src={primaryPreview()} alt="Input preview" />
                    <div>{inputImages[0].name}</div>
                  </>
                ) : (
                  "Click or drop images here (PNG / JPEG / WebP)"
                )}
              </div>
              <input ref={fileInputRef} type="file" accept="image/png,image/jpeg,image/webp" multiple hidden onChange={(e) => { handleFiles(e.target.files); e.target.value = ""; }} />
              {inputImages.length > 1 && (
                <div className="thumbs">
                  {inputImages.slice(1).map((e, i) => (
                    <span key={e.name + i} style={{ position: "relative" }}>
                      {/* eslint-disable-next-line @next/next/no-img-element */}
                      <img src={e.blobUrl || `/view?filename=${encodeURIComponent(e.name)}&subfolder=${encodeURIComponent(e.subfolder || "")}&type=input`} alt="" />
                      <button className="act-btn" type="button" style={{ position: "absolute", top: -8, right: -8, padding: "0 5px" }} onClick={() => {
                        setInputImages((prev) => prev.filter((_, j) => j !== i + 1));
                        setTimeout(persist, 0);
                      }}>
                        ✕
                      </button>
                    </span>
                  ))}
                </div>
              )}
              {inputImages.length > 0 && (
                <button className="act-btn danger" type="button" style={{ marginTop: 6 }} onClick={() => { setInputImages([]); setTimeout(persist, 0); }}>
                  Clear images
                </button>
              )}
              <div className="field" style={{ marginTop: 8 }}>
                <label>Or pick from input folder</label>
                <Select
                  value=""
                  options={[
                    { value: "", label: inputLib.length ? "Choose an image…" : "No images…" },
                    ...inputLib.map((x) => {
                      const v = (x.subfolder ? x.subfolder + "/" : "") + x.name;
                      return { value: v, label: v };
                    }),
                  ]}
                  onChange={(v) => {
                    if (!v) return;
                    const found = inputLib.find((x) => ((x.subfolder ? x.subfolder + "/" : "") + x.name) === v);
                    if (found) addInputImages([{ name: found.name, subfolder: found.subfolder || "" }]);
                  }}
                />
              </div>
              {maxN > 1 && <p className="note">{inputImages.length} / {maxN} images · the first image is the edit target.</p>}
            </div>
          )}
        </div>

        {model && (
          <div className="group">
            <label className="group-label">Files & LoRA</label>
            {model.files.map((f) => (
              <div className="field" key={f.kind}>
                <label>{f.label}</label>
                <Select
                  value={(fileSel[model.id] || {})[f.kind] || ""}
                  options={[
                    { value: "", label: `Template default — ${f.name}` },
                    ...(dirFiles[f.dir] || []).map((n) => ({ value: n, label: n + (n === f.name ? " (default)" : "") })),
                  ]}
                  onChange={(v) => {
                    setFileSel((prev) => {
                      const next = { ...(prev[model.id] || {}) };
                      if (v) next[f.kind] = v;
                      else delete next[f.kind];
                      return { ...prev, [model.id]: next };
                    });
                    setTimeout(persist, 0);
                  }}
                />
              </div>
            ))}
            <div className="field">
              <label>LoRA (optional)</label>
              <Select
                value={lora}
                options={[{ value: "", label: "None" }, ...loraOptions().map((n) => ({ value: n, label: n }))]}
                onChange={(v) => { setLora(v); setTimeout(persist, 0); }}
              />
            </div>
            {lora && (
              <div className="field">
                <label>LoRA strength ({Math.max(0, Math.min(5, parseFloat(loraStrength) || 0))})</label>
                <input type="range" min={0} max={5} step={0.05} value={Math.max(0, Math.min(5, parseFloat(loraStrength) || 0))} onChange={(e) => { setLoraStrength(e.target.value); setTimeout(persist, 0); }} />
              </div>
            )}
            {loraStack.map((s, i) => (
              <div className="field" key={i} style={{ display: "flex", gap: 8, alignItems: "center" }}>
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
                <input style={{ flex: "1 1 70px", minWidth: 70 }} type="range" min={0} max={5} step={0.05} title={`strength ${s.strength}`} value={Math.max(0, Math.min(5, s.strength || 0))} onChange={(e) => {
                  const next = [...loraStack];
                  next[i] = { ...next[i], strength: parseFloat(e.target.value) || 0 };
                  setLoraStack(next);
                }} />
                <span className="hint" style={{ width: 28, textAlign: "right" }}>{s.strength}</span>
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

        {model && (
          <div className="group">
            <label className="group-label">Settings</label>
            {mode === "t2i" && (
              <>
                <div className="grid2">
                  <div className="field">
                    <label>Width</label>
                    <input type="number" value={width} onChange={(e) => { setWidth(e.target.value); persist(); }} />
                  </div>
                  <div className="field">
                    <label>Height</label>
                    <input type="number" value={height} onChange={(e) => { setHeight(e.target.value); persist(); }} />
                  </div>
                </div>
                {model.options.aspects && (
                  <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: 6, marginBottom: 8 }}>
                    {model.options.aspects.map((a) => (
                      <button key={a.label} className="act-btn" type="button" style={{ justifyContent: "center" }} onClick={() => { setWidth(String(a.width)); setHeight(String(a.height)); setTimeout(persist, 0); }}>
                        {a.label}
                      </button>
                    ))}
                  </div>
                )}
              </>
            )}
            <div className="grid2">
              <div className="field">
                <label>Steps</label>
                <input type="number" value={steps} onChange={(e) => { setSteps(e.target.value); persist(); }} />
              </div>
              <div className="field">
                <label>Seed {randSeed ? "(random)" : ""}</label>
                <div style={{ display: "flex", gap: 6 }}>
                  <input type="number" value={seed} placeholder="random" style={{ flex: 1 }} onChange={(e) => { setSeed(e.target.value); setRandSeed(!e.target.value.trim()); persist(); }} />
                  <button className="act-btn" type="button" title="Randomize" onClick={() => { setSeed(String(Math.floor(Math.random() * 9007199254740991))); setRandSeed(false); setTimeout(persist, 0); }}>
                    🎲
                  </button>
                </div>
              </div>
              {(model.options.cfg_visible ?? true) && (
                <div className="field">
                  <label>Guidance (CFG)</label>
                  <input type="number" step="any" value={cfg} onChange={(e) => { setCfg(e.target.value); persist(); }} />
                </div>
              )}
              {mode === "t2i" && (
                <div className="field">
                  <label>Batch</label>
                  <input type="number" min={1} value={batch} onChange={(e) => { setBatch(e.target.value); persist(); }} />
                </div>
              )}
            </div>
            {!(model.options.cfg_visible ?? true) && <p className="note">Guidance is fixed at {model.defaults.cfg} for this model.</p>}
            <div className="grid2">
              <div className="field">
                <label>Sampler</label>
                <Select
                  value={sampler}
                  options={(model.options.samplers || []).map((s) => ({ value: s, label: s }))}
                  onChange={(v) => { setSampler(v); persist(); }}
                />
              </div>
              {!(model.options.scheduler_fixed ?? false) && (
                <div className="field">
                  <label>Scheduler</label>
                  <Select
                    value={scheduler}
                    options={(model.options.schedulers || []).map((s) => ({ value: s, label: s }))}
                    onChange={(v) => { setScheduler(v); persist(); }}
                  />
                </div>
              )}
            </div>
            {(model.options.scheduler_fixed ?? false) && <p className="note">Schedule is fixed for this model.</p>}
            {presetOpts.length > 0 && (
              <div className="field">
                <label>{model.options.presets?.label || "Preset"}</label>
                <Select
                  value={preset}
                  options={[{ value: "", label: "Custom · manual steps" }, ...presetOpts.map((o) => ({ value: o.id, label: o.label }))]}
                  onChange={(v) => {
                    setPreset(v);
                    const o = presetOpts.find((x) => x.id === v);
                    if (o?.steps != null) setSteps(String(o.steps));
                    setTimeout(persist, 0);
                  }}
                />
              </div>
            )}
            {showEnhance && (
              <div className="field">
                <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                  <Switch checked={enhance} onChange={(v) => { setEnhance(v); persist(); }} label="Enhance prompt" />
                  <span style={{ fontSize: 13, fontWeight: 600 }}>Enhance prompt (+PE)</span>
                </div>
              </div>
            )}
            {showDenoise && (
              <div className="field">
                <label>Strength ({Math.round((parseFloat(denoise) || 0) * 100)}%)</label>
                <input type="range" min={0.05} max={1} step={0.05} value={denoise} onChange={(e) => { setDenoise(e.target.value); persist(); }} />
              </div>
            )}
            {showQwenRes && (
              <div className="field">
                <label>Reference resolution</label>
                <input type="number" value={qwenRes} placeholder={String((model.defaults as any).resolution || 1024)} onChange={(e) => { setQwenRes(e.target.value); persist(); }} />
              </div>
            )}
          </div>
        )}

        <div style={{ display: "flex", gap: 8 }}>
          <button className="btn btn-primary" type="button" style={{ flex: 1 }} disabled={!!jobRef.current || miss.length > 0} title={miss.length ? "Missing: " + miss.join(", ") : ""} onClick={generate}>
            {jobRef.current ? "Working…" : "Generate"}
          </button>
          {jobRef.current && (
            <button className="btn btn-danger" type="button" onClick={cancel}>
              Cancel
            </button>
          )}
        </div>
        <div style={{ display: "flex", gap: 8, marginTop: 8 }}>
          {queueN > 0 && <span className="badge">{queueN} queued</span>}
        </div>
        {sysInfo && (
          <p className="hint" style={{ marginTop: 8 }}>
            LazyComfy {sysInfo.lazycomfy_version || ""} · ComfyUI {sysInfo.comfyui_version || "?"} · {sysInfo.device?.name || sysInfo.device?.type || ""}
          </p>
        )}
      </section>

      <section className="panel">
        <div className="group">
          <div className="group-head">
            <label className="group-label">Result</label>
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
              <p>Pick a model and describe your image</p>
            </div>
          )}
          {cur && (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={cur.url} alt="result" />
          )}
          {current && current.images.length > 1 && (
            <div className="thumbs">
              {current.images.map((f, i) => (
                // eslint-disable-next-line @next/next/no-img-element
                <img
                  key={f.url + i}
                  src={f.url}
                  alt=""
                  className={f.url === cur?.url ? "active" : ""}
                  onClick={() => {
                    const el = document.querySelector(".view img");
                    if (el) el.setAttribute("src", f.url);
                    document.querySelectorAll(".thumbs img").forEach((x) => x.classList.remove("active"));
                    (document.querySelectorAll(".thumbs img")[i] as HTMLElement)?.classList.add("active");
                  }}
                />
              ))}
            </div>
          )}
        </div>
        {metaLine && <div className="meta-line">{metaLine}</div>}
        {cur && (
          <div className="row-actions">
            <button className="act-btn" type="button" onClick={() => window.open(cur.url, "_blank")}>
              Open
            </button>
            <a className="act-btn" href={cur.url} download={cur.filename || "lazycomfy.png"}>
              Download
            </a>
            <button className="act-btn danger" type="button" onClick={delCurrent}>
              Delete
            </button>
            <button className="act-btn" type="button" onClick={reuse}>
              Reuse settings
            </button>
            <button className="act-btn" type="button" onClick={toI2I}>
              To img2img
            </button>
            <button className="act-btn" type="button" onClick={copyPrompt}>
              Copy prompt
            </button>
          </div>
        )}
        <div className="gallery-wrap">
          <h3>Recent</h3>
          <div className="gallery">
            {gallery
              .map((j) => ({ ...j, images: (j.images || []).filter((f) => !deleted.has(fileKey(f))) }))
              .filter((j) => j.images.length)
              .map((j) => {
                const img = j.images[0];
                const mod = models.find((x) => x.id === j.model_id);
                return (
                  <button
                    key={j.prompt_id}
                    type="button"
                    className="g-item"
                    title={(j.prompt || "").slice(0, 140) || "output"}
                    onClick={() => {
                      if (!jobRef.current) setJobState("Done");
                      showResult({ images: j.images, meta: { model_id: j.model_id, mode: j.mode, prompt: j.prompt, params: j.params }, promptId: j.prompt_id });
                    }}
                  >
                    {/* eslint-disable-next-line @next/next/no-img-element */}
                    <img loading="lazy" src={img.url} alt="" />
                    <span className="g-badge">{mod ? mod.name : j.model_id || "output"}</span>
                  </button>
                );
              })}
            {gallery.length === 0 && <p className="g-empty">No generations yet</p>}
          </div>
        </div>
      </section>

      {dlOpen && (
        <Downloader
          onClose={() => setDlOpen(false)}
          onChanged={async () => {
            await refreshDirFiles();
            try {
              setModels(await fetchModels());
            } catch {
              /* ignore */
            }
            try {
              setCatalog(await fetchCatalog());
            } catch {
              /* ignore */
            }
          }}
        />
      )}
    </main>
  );
}

/* ================= model downloader modal ================= */

function Downloader(props: { onClose: () => void; onChanged: () => void }) {
  const toast = useToast();
  const [catalog, setCatalog] = useState<any>(null);
  const [modelNames, setModelNames] = useState<Record<string, string>>({});
  const [folders, setFolders] = useState<string[]>(["loras"]);
  const [folder, setFolder] = useState("loras");
  const [genericUrl, setGenericUrl] = useState("");
  const [loraUrl, setLoraUrl] = useState("");
  const [downloader, setDownloader] = useState("huggingface");
  const [hfToken, setHfToken] = useState("");
  const [hfStatus, setHfStatus] = useState<any>(null);

  const refresh = useCallback(async () => {
    try {
      setCatalog(await fetchCatalog());
    } catch (e) {
      toast(errMsg(e), "error");
    }
    try {
      const ms = await fetchModels();
      const names: Record<string, string> = {};
      for (const m of ms) names[m.id] = m.name;
      try {
        const vc = await fetchVideoConfig();
        for (const m of vc.models || []) names[m.id] = m.name;
      } catch {
        /* ignore */
      }
      setModelNames(names);
    } catch {
      /* ignore */
    }
    try {
      const f = await api("/lazycomfy/api/folders");
      if (f.folders?.length) {
        setFolders(f.folders);
        setFolder((prev) => (f.folders.includes(prev) ? prev : "loras"));
      }
    } catch {
      /* ignore */
    }
    try {
      setHfStatus(await fetchHfToken());
    } catch {
      /* ignore */
    }
  }, [toast]);

  useEffect(() => {
    try {
      const saved = localStorage.getItem("lazycomfy.downloader");
      if (saved) setDownloader(saved);
    } catch {
      /* ignore */
    }
    refresh();
    const t = setInterval(async () => {
      const prev = catalog;
      try {
        const c = await fetchCatalog();
        setCatalog(c);
        const wasBusy = (prev?.tasks || []).some((x: any) => ["starting", "downloading", "cancelling"].includes(x.status));
        const isBusy = (c?.tasks || []).some((x: any) => ["starting", "downloading", "cancelling"].includes(x.status));
        if (wasBusy && !isBusy) props.onChanged();
      } catch {
        /* ignore */
      }
    }, 1000);
    return () => clearInterval(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const setDl = (v: string) => {
    setDownloader(v);
    try {
      localStorage.setItem("lazycomfy.downloader", v);
    } catch {
      /* ignore */
    }
  };

  const start = async (itemId: string) => {
    try {
      await startDownload(itemId, downloader);
      refresh();
    } catch (e) {
      toast(errMsg(e), "error");
    }
  };

  const items: any[] = catalog?.items || [];
  const tasks: any[] = catalog?.tasks || [];
  const PINNED = ["qwen_image_2_1_turbo", "z_image_turbo"];
  const byModel = new Map<string, any[]>();
  for (const it of items) {
    if (!byModel.has(it.model_id)) byModel.set(it.model_id, []);
    byModel.get(it.model_id)!.push(it);
  }
  const orderedModels = [...byModel.keys()].sort((a, b) => {
    const pa = PINNED.indexOf(a);
    const pb = PINNED.indexOf(b);
    if (pa >= 0 || pb >= 0) return (pa < 0 ? 99 : pa) - (pb < 0 ? 99 : pb);
    return a.localeCompare(b);
  });
  const prettyModel = (mid: string) =>
    modelNames[mid] || mid.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
  const customTasks = tasks
    .filter((t) => String(t.item_id || "").startsWith("custom:"))
    .sort((a, b) => (b.created_at || 0) - (a.created_at || 0));

  const taskFor = (itemId: string) => tasks.find((t) => t.item_id === itemId);

  useEffect(() => {
    const prev = document.documentElement.style.overflow;
    document.documentElement.style.overflow = "hidden";
    return () => {
      document.documentElement.style.overflow = prev;
    };
  }, []);

  return (
    <div className="modal-backdrop">
      <div className="panel" style={{ maxWidth: 640, width: "100%", maxHeight: "88vh", display: "flex", flexDirection: "column", padding: 0, overflow: "hidden" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "16px 20px 12px", borderBottom: "1px solid var(--border-soft)", flex: "none" }}>
          <h3 style={{ margin: 0 }}>Model downloads</h3>
          <div style={{ width: 140, marginLeft: "auto" }}>
            <Select
              value={downloader}
              options={[{ value: "huggingface", label: "HF Hub" }, { value: "aria2c", label: "aria2c" }]}
              onChange={setDl}
            />
          </div>
          <button className="icon-circle" type="button" aria-label="Close" onClick={props.onClose}>
            ✕
          </button>
        </div>
        <div style={{ overflowY: "auto", overscrollBehavior: "contain", padding: "16px 20px 20px" }}>

        <div className="group">
          <label className="group-label">HuggingFace token (gated repos)</label>
          <p className={hfStatus?.has_token ? "saved-line" : "note"}>
            {hfStatus?.has_token ? `Token saved (${hfStatus.masked || "***"}) via ${hfStatus.source || "file"}` : "No token saved."}
          </p>
          <div style={{ display: "flex", gap: 8 }}>
            <input style={{ flex: 1 }} type="password" placeholder="hf_…" value={hfToken} onChange={(e) => setHfToken(e.target.value)} />
            <button
              className="act-btn"
              type="button"
              onClick={async () => {
                try {
                  await api("/lazycomfy/api/hf_token", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ token: hfToken }) });
                  setHfToken("");
                  toast("Token saved.", "ok");
                  refresh();
                } catch (e) {
                  toast(errMsg(e), "error");
                }
              }}
            >
              Save
            </button>
          </div>
        </div>

        <div className="group">
          <label className="group-label">Custom file URL → any folder</label>
          <div style={{ display: "flex", gap: 8 }}>
            <input style={{ flex: 1 }} placeholder="https://huggingface.co/…/file.safetensors" value={genericUrl} onChange={(e) => setGenericUrl(e.target.value)} />
            <div style={{ width: 150, flex: "none" }}>
              <Select
                value={folder}
                options={folders.map((f) => ({ value: f, label: f }))}
                onChange={setFolder}
              />
            </div>
          </div>
          <button
            className="act-btn"
            type="button"
            style={{ marginTop: 6 }}
            onClick={async () => {
              if (!genericUrl.trim()) return;
              try {
                await startGenericDownload(genericUrl.trim(), folder, downloader);
                setGenericUrl("");
                toast(`Download to ${folder} started.`, "ok");
                refresh();
              } catch (e) {
                toast(errMsg(e), "error");
              }
            }}
          >
            Download file
          </button>
        </div>

        <div className="group">
          <label className="group-label">Custom LoRA URL (→ loras)</label>
          <div style={{ display: "flex", gap: 8 }}>
            <input style={{ flex: 1 }} placeholder="https://…" value={loraUrl} onChange={(e) => setLoraUrl(e.target.value)} />
            <button
              className="act-btn"
              type="button"
              onClick={async () => {
                if (!loraUrl.trim()) return;
                try {
                  await startLoraDownload(loraUrl.trim(), downloader);
                  setLoraUrl("");
                  toast("LoRA download started.", "ok");
                  refresh();
                } catch (e) {
                  toast(errMsg(e), "error");
                }
              }}
            >
              Download
            </button>
          </div>
        </div>

        {customTasks.length > 0 && (
          <div className="group">
            <label className="group-label">Custom downloads</label>
            {customTasks.map((t) => (
              <TaskRow key={t.id} task={t} downloader={downloader} onStart={start} />
            ))}
          </div>
        )}

        {orderedModels.map((mid) => {
          const group = byModel.get(mid)!;
          const done = group.filter((g) => g.present).length;
          return (
            <div className="group" key={mid}>
              <label className="group-label">{prettyModel(mid)} · {done}/{group.length} installed</label>
              {group.map((it: any) => {
                const t = taskFor(it.id);
                const active = t && ["starting", "downloading", "cancelling"].includes(t.status);
                return (
                  <div key={it.id} style={{ border: "1px solid var(--border)", borderRadius: 10, padding: 10, marginBottom: 8 }}>
                    <div className="dl-item">
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ fontWeight: 600 }}>{it.label}</div>
                        <div className="hint">{it.target_name}{it.size ? ` · ${(it.size / 1073741824).toFixed(1)} GB` : ""}</div>
                        {it.note && <div className="note">{it.note}</div>}
                      </div>
                      {it.present && <span className="badge">Installed ✓</span>}
                      {!it.present && !active && (
                        <button className="act-btn" type="button" onClick={() => start(it.id)}>
                          Download
                        </button>
                      )}
                      {!it.present && t?.status === "error" && (
                        <button className="act-btn" type="button" onClick={() => start(it.id)}>
                          Retry
                        </button>
                      )}
                    </div>
                    {active && <TaskRow task={t} downloader={downloader} onStart={start} bare />}
                    {t?.status === "error" && <div className="err-line">{t.error || "failed"}</div>}
                  </div>
                );
              })}
            </div>
          );
        })}
        </div>
      </div>
    </div>
  );
}

function TaskRow(props: { task: any; downloader: string; onStart: (id: string) => void; bare?: boolean }) {
  const t = props.task;
  const pct = t.total ? Math.min(100, Math.round((t.downloaded / t.total) * 100)) : 0;
  const inner = (
    <>
      <div className="dl-item">
        <div>
          <div className="dl-item-title">{t.target_name}</div>
        </div>
        <button
          className="act-btn danger"
          type="button"
          onClick={async () => {
            try {
              await cancelDownload(t.id);
            } catch {
              /* ignore */
            }
          }}
        >
          Cancel
        </button>
      </div>
      <div className="progress-wrap" style={{ marginTop: 8 }}>
        <div className="progress-bar" style={{ width: pct + "%" }} />
      </div>
      <div className="hint" style={{ marginTop: 4 }}>
        {fmtSize(t.downloaded)} / {fmtSize(t.total)} · {pct}% · {t.downloader === "aria2c" ? "aria2c" : "HF"} · {t.status}
      </div>
    </>
  );
  if (props.bare) return <div style={{ marginTop: 8 }}>{inner}</div>;
  return <div style={{ border: "1px solid var(--border)", borderRadius: 10, padding: 10, marginBottom: 8 }}>{inner}</div>;
}
