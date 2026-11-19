"use client";

import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";
import { Select } from "@/components/controls";
import { useToast } from "@/lib/store";
import {
  cachedSession,
  errMsg,
  fetchInputImages,
  fetchLlmConfig,
  loadSession,
  llmLoad,
  llmUnload,
  saveSession,
} from "@/lib/api";

const ASPECTS = [
  { value: "16:9", label: "16:9 · cinematic" },
  { value: "9:16", label: "9:16 · vertical" },
  { value: "1:1", label: "1:1 · square" },
  { value: "4:3", label: "4:3" },
  { value: "3:4", label: "3:4" },
  { value: "3:2", label: "3:2" },
  { value: "2:3", label: "2:3" },
  { value: "21:9", label: "21:9 · scope" },
];

const STYLES = [
  { value: "cinematic photoreal film still, 35mm, natural skin texture, practical light", label: "Cinematic photoreal" },
  { value: "editorial fashion photograph, medium format, controlled studio light", label: "Editorial fashion" },
  { value: "hand-painted anime frame, cel shading, expressive line work", label: "Anime / cel" },
  { value: "graphic novel panel, bold ink, limited palette, dramatic shadow", label: "Graphic novel" },
  { value: "painterly oil on canvas, visible brushwork, warm varnish", label: "Painterly oil" },
  { value: "dreamlike soft focus, hazy light, muted film grain", label: "Dreamlike" },
  { value: "custom", label: "Custom…" },
];

const INTENSITIES = [
  { value: "none", label: "None — warm, fully clothed" },
  { value: "suggestive", label: "Suggestive — tension and gaze" },
  { value: "sensual", label: "Sensual — tasteful adult" },
  { value: "explicit", label: "Explicit — cinematic adult" },
  { value: "custom", label: "Custom — your own direction" },
];

const num = (v: string, dflt: number): number => {
  const n = parseFloat(v);
  return Number.isFinite(n) ? n : dflt;
};

const wordCount = (text: string): number => (text || "").match(/[A-Za-z0-9][A-Za-z0-9'\-]*/g)?.length || 0;

const inputPath = (it: any): string => (it.subfolder ? it.subfolder + "/" : "") + it.name;

interface CastMember {
  id: number;
  name: string;
  notes: string;
  ref: string;
  image: string;
  inputPath: string;
}

interface Scene {
  n: number;
  title?: string;
  beat?: string;
  prompt: string;
  words?: number;
  [k: string]: any;
}

function newCastMember(id: number, index: number, partial?: Partial<CastMember>): CastMember {
  return {
    id,
    name: "",
    notes: "",
    ref: `<image${index + 1}>`,
    image: "",
    inputPath: "",
    ...(partial || {}),
  };
}

function shrinkImage(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      const maxSide = 1400;
      const scale = Math.min(1, maxSide / Math.max(img.width, img.height));
      const w = Math.max(1, Math.round(img.width * scale));
      const h = Math.max(1, Math.round(img.height * scale));
      const canvas = document.createElement("canvas");
      canvas.width = w;
      canvas.height = h;
      const ctx = canvas.getContext("2d");
      if (!ctx) {
        URL.revokeObjectURL(url);
        reject(new Error("Canvas is unavailable"));
        return;
      }
      ctx.fillStyle = "#fff";
      ctx.fillRect(0, 0, w, h);
      ctx.drawImage(img, 0, 0, w, h);
      URL.revokeObjectURL(url);
      resolve(canvas.toDataURL("image/jpeg", 0.9));
    };
    img.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error("Could not read that image"));
    };
    img.src = url;
  });
}

async function postSSE(
  url: string,
  body: unknown,
  onEvent: (e: any) => void,
  signal: AbortSignal,
): Promise<void> {
  let res: Response;
  try {
    res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal,
    });
  } catch (e: any) {
    if (e?.name === "AbortError") throw e;
    throw new Error("Cannot reach ComfyUI (" + (e?.message || e) + ")");
  }
  if (!res.ok) {
    let data: any = null;
    try {
      data = await res.json();
    } catch {
      /* ignore */
    }
    throw new Error(data?.error?.message || "HTTP " + res.status);
  }
  if (!res.body) throw new Error("Streaming is not supported by this browser");
  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let buf = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let idx: number;
    while ((idx = buf.indexOf("\n\n")) >= 0) {
      const raw = buf.slice(0, idx);
      buf = buf.slice(idx + 2);
      const line = raw.startsWith("data:") ? raw.slice(5).trim() : raw.trim();
      if (!line) continue;
      let ev: any;
      try {
        ev = JSON.parse(line);
      } catch {
        continue;
      }
      onEvent(ev);
    }
  }
}

function copyText(text: string): Promise<void> {
  return navigator.clipboard.writeText(text).catch(() => {
    const ta = document.createElement("textarea");
    ta.value = text;
    document.body.appendChild(ta);
    ta.select();
    try {
      document.execCommand("copy");
    } finally {
      ta.remove();
    }
  });
}

export default function StorylinePage() {
  const toast = useToast();

  const [models, setModels] = useState<any[]>([]);
  const [mmprojs, setMmprojs] = useState<any[]>([]);
  const [status, setStatus] = useState<any>(null);
  const [backend, setBackend] = useState<{ dot: string; label: string }>({ dot: "", label: "Checking backend" });

  const [model, setModel] = useState("");
  const [mmproj, setMmproj] = useState("");
  const [ctx, setCtx] = useState("16384");
  const [temp, setTemp] = useState("0.75");
  const [topP, setTopP] = useState("0.9");

  const [cast, setCast] = useState<CastMember[]>(() => [
    newCastMember(1, 0),
    newCastMember(2, 1),
  ]);
  const castId = useRef(2);
  const fileRefs = useRef<Record<number, HTMLInputElement | null>>({});
  const [inputImages, setInputImages] = useState<any[]>([]);

  const [overview, setOverview] = useState("");
  const [sceneCount, setSceneCount] = useState("12");
  const [aspect, setAspect] = useState("16:9");
  const [style, setStyle] = useState(STYLES[0].value);
  const [styleNotes, setStyleNotes] = useState("");
  const [promptStyle, setPromptStyle] = useState("scene");
  const [intensity, setIntensity] = useState("suggestive");
  const [intensityNotes, setIntensityNotes] = useState("");
  const [adultAck, setAdultAck] = useState(false);

  const [bible, setBible] = useState<any>(null);
  const [scenes, setScenes] = useState<Scene[]>([]);
  const [sceneNotes, setSceneNotes] = useState<Record<number, string>>({});
  const [requested, setRequested] = useState(0);
  const [generating, setGenerating] = useState(false);
  const [regenN, setRegenN] = useState(0);
  const [progress, setProgress] = useState(0);
  const [progressText, setProgressText] = useState("");
  const [showProgress, setShowProgress] = useState(false);
  const [err, setErr] = useState("");

  const abortRef = useRef<AbortController | null>(null);
  const booted = useRef(false);
  const saveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  /* Live mirror so the debounced save always carries the newest values. */
  const live = useRef<any>({});
  live.current = {
    model,
    mmproj,
    ctx,
    temp,
    topP,
    overview,
    sceneCount,
    aspect,
    style,
    styleNotes,
    promptStyle,
    intensity,
    intensityNotes,
    adultAck,
    cast,
    bible,
    scenes,
  };

  const collect = useCallback(() => {
    const s = live.current;
    let imageBudget = 8000000;
    const savedCast = (s.cast as CastMember[]).map((c) => {
      let image = "";
      if (c.image && c.image.length <= imageBudget) {
        image = c.image;
        imageBudget -= c.image.length;
      }
      return { name: c.name, notes: c.notes, ref: c.ref, image, inputPath: c.inputPath || "" };
    });
    return {
      model: s.model,
      mmproj: s.mmproj,
      ctx: s.ctx,
      temp: s.temp,
      topP: s.topP,
      overview: s.overview,
      sceneCount: s.sceneCount,
      aspect: s.aspect,
      style: s.style,
      styleNotes: s.styleNotes,
      promptStyle: s.promptStyle,
      intensity: s.intensity,
      intensityNotes: s.intensityNotes,
      adultAck: s.adultAck,
      cast: savedCast,
      bible: s.bible,
      scenes: (s.scenes as Scene[]).map((scene) => ({
        ...scene,
        words: scene.words || wordCount(scene.prompt || ""),
      })),
    };
  }, []);

  const persist = useCallback(() => {
    if (!booted.current) return;
    if (saveTimer.current) clearTimeout(saveTimer.current);
    saveTimer.current = setTimeout(() => {
      saveTimer.current = null;
      saveSession("storyline", collect());
    }, 500);
  }, [collect]);

  useEffect(() => {
    const onUnload = () => {
      if (booted.current) saveSession("storyline", collect());
    };
    window.addEventListener("beforeunload", onUnload);
    return () => window.removeEventListener("beforeunload", onUnload);
  }, [collect]);

  const refreshConfig = useCallback(async () => {
    let c: any;
    try {
      c = await fetchLlmConfig();
    } catch {
      setBackend({ dot: "err", label: "Backend error" });
      return;
    }
    const ms = c.models || [];
    const ps = c.mmprojs || [];
    setModels(ms);
    setMmprojs(ps);
    setStatus(c.status || null);
    if (c.backend_present) setBackend({ dot: "on", label: "llama.cpp ready" });
    else if (c.install?.status === "error") setBackend({ dot: "err", label: "backend missing" });
    else setBackend({ dot: "retry", label: "backend missing" });

    setModel((prev) => {
      if (prev && ms.some((m: any) => m.name === prev)) return prev;
      const best = ms.find((m: any) => /qwen3.*vl/i.test(m.name)) || ms[0];
      return best?.name || prev;
    });
    setMmproj((prev) => {
      if (prev && (["Auto-Detect", "None"].includes(prev) || ps.some((m: any) => m.name === prev))) return prev;
      const named = ps.find((m: any) => /qwen/i.test(m.name)) || ps[0];
      return named?.name || prev;
    });
  }, []);

  const loadInputs = useCallback(async () => {
    try {
      setInputImages(await fetchInputImages());
    } catch {
      setInputImages([]);
    }
  }, []);

  const applySaved = useCallback((saved: any) => {
    if (!saved) return;
    if (saved.model) setModel(saved.model);
    if (saved.mmproj) setMmproj(saved.mmproj);
    if (saved.ctx) setCtx(saved.ctx);
    if (saved.temp) setTemp(saved.temp);
    if (saved.topP) setTopP(saved.topP);
    if (typeof saved.overview === "string") setOverview(saved.overview);
    if (saved.sceneCount) setSceneCount(saved.sceneCount);
    if (saved.aspect) setAspect(saved.aspect);
    if (saved.style) setStyle(saved.style);
    if (typeof saved.styleNotes === "string") setStyleNotes(saved.styleNotes);
    if (saved.promptStyle) setPromptStyle(saved.promptStyle);
    if (saved.intensity) setIntensity(saved.intensity);
    if (typeof saved.intensityNotes === "string") setIntensityNotes(saved.intensityNotes);
    if (typeof saved.adultAck === "boolean") setAdultAck(saved.adultAck);

    if (Array.isArray(saved.cast) && saved.cast.length) {
      let seq = 0;
      const next: CastMember[] = saved.cast.map((c: any, i: number) => {
        seq += 1;
        return {
          id: seq,
          name: c.name || "",
          notes: c.notes || "",
          ref: c.ref || `<image${i + 1}>`,
          image: c.image || "",
          inputPath: c.inputPath || "",
        };
      });
      castId.current = seq;
      const used = new Set<string>();
      next.forEach((c) => {
        let ref = c.ref.trim();
        if (!/^<image\d+>$/.test(ref) || used.has(ref)) {
          let n = 1;
          while (used.has(`<image${n}>`)) n += 1;
          ref = `<image${n}>`;
        }
        c.ref = ref;
        used.add(ref);
      });
      setCast(next);
    }
    setBible(saved.bible || null);
    setScenes(Array.isArray(saved.scenes) ? saved.scenes : []);
  }, []);

  /* boot: restore session, then poll the llama.cpp config */
  useEffect(() => {
    let cancelled = false;
    (async () => {
      applySaved(cachedSession("storyline"));
      const serverSaved = (await loadSession()).storyline;
      const saved = { ...(serverSaved || {}), ...(cachedSession("storyline") || {}) };
      if (!cancelled && Object.keys(saved).length) applySaved(saved);
      await refreshConfig();
      await loadInputs();
      if (!cancelled) booted.current = true;
    })();
    const timer = setInterval(refreshConfig, 5000);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [applySaved, refreshConfig, loadInputs]);

  const alive = status?.status === "running" || status?.status === "loading";
  const loading = status?.status === "loading";

  const toggleLoad = async () => {
    if (generating) return;
    if (alive) {
      try {
        await llmUnload();
        toast("Model unloaded", "ok");
      } catch (e) {
        toast(errMsg(e), "error");
      }
      await refreshConfig();
      return;
    }
    if (!model) {
      toast("Select a GGUF model first", "error");
      return;
    }
    try {
      await llmLoad(model, mmproj || "Auto-Detect", num(ctx, 16384));
      toast("Model loaded", "ok");
    } catch (e) {
      toast(errMsg(e), "error");
    }
    await refreshConfig();
  };

  const currentStyle = (): string => {
    if (style !== "custom") return style;
    return styleNotes.trim() || "cinematic photoreal film still, 35mm, natural skin texture, practical light";
  };

  const buildBody = () => {
    if (!models.length) throw new Error("No GGUF models found. Download one in Prompt Forge.");
    if (!model) throw new Error("Select a GGUF model first");
    const active = cast.filter((c) => c.image || c.name.trim());
    if (!active.length) throw new Error("Attach at least one character sheet");
    for (const c of active) {
      if (!c.image) throw new Error("Attach a sheet for " + (c.name || "the first character"));
      if (!c.name.trim()) throw new Error("Give every character a name");
    }
    if (overview.trim().length < 10) throw new Error("Write a story overview first");
    if (intensity === "custom" && !intensityNotes.trim()) throw new Error("Write a custom intensity direction first");
    if (!adultAck) throw new Error("Confirm the cast is adults (18+) first");
    if (promptStyle === "edit" && cast.some((c) => c.ref.trim() === "<image1>")) {
      throw new Error("Edit mode uses <image1> for the previous frame. Move the sheets to <image2>+ with Shift tags.");
    }
    return {
      model,
      mmproj: mmproj || "Auto-Detect",
      context_length: num(ctx, 16384),
      temperature: num(temp, 0.75),
      top_p: num(topP, 0.9),
      adult_ack: adultAck,
      characters: cast.filter((c) => c.image).map((c) => ({
        name: c.name.trim(),
        notes: c.notes.trim(),
        ref: c.ref.trim() || "<image1>",
        image: c.image,
      })),
      overview: overview.trim(),
      scene_count: Math.max(2, Math.min(24, Math.round(num(sceneCount, 12)))),
      aspect,
      style: currentStyle(),
      style_notes: style === "custom" ? "" : styleNotes.trim(),
      prompt_style: promptStyle,
      intensity,
      intensity_notes: intensity === "custom" ? intensityNotes.trim() : "",
      source_ref: "<image1>",
    };
  };

  const engineBody = () => ({
    model,
    mmproj: mmproj || "Auto-Detect",
    context_length: num(ctx, 16384),
    temperature: num(temp, 0.75),
    top_p: num(topP, 0.9),
    adult_ack: adultAck,
  });

  const setProgressTo = (pct: number, text: string) => {
    setShowProgress(true);
    setProgress(Math.max(0, Math.min(100, pct)));
    setProgressText(text);
  };

  const handleEvent = (body: { scene_count: number }) => (e: any) => {
    if (e.type === "status") {
      if (e.stage === "load") {
        setProgressTo(2, e.message || "loading model…");
      } else if (e.stage === "bible") {
        setProgressTo(8, e.message || "building the bible…");
      } else if (e.stage === "scene") {
        const total = e.total || body.scene_count || 1;
        const done = Math.max(0, (e.index || 1) - 1);
        setProgressTo(((done + 0.35) / total) * 100, e.message || `writing scene ${e.index}…`);
        setSceneNotes((prev) => ({ ...prev, [e.index]: "writing…" }));
      }
      return;
    }
    if (e.type === "bible") {
      setBible(e.data);
      setRequested(e.requested || body.scene_count);
      setScenes(((e.data && e.data.scenes) || []).map((s: any) => ({ ...s, prompt: "", words: 0 })));
      setSceneNotes({});
      setProgressTo(10, "bible ready — writing scenes");
      return;
    }
    if (e.type === "tick") {
      if (e.stage === "bible") {
        const detail = (e.tokens || 0) + " tokens" + (e.tps ? " · " + Number(e.tps).toFixed(1) + " t/s" : "");
        setProgressTo(10, "story bible · " + detail);
        return;
      }
      if (e.index) {
        const total = body.scene_count || 1;
        const done = Math.max(0, e.index - 1);
        setProgressTo(
          Math.max(10, ((done + 0.55) / total) * 100),
          `scene ${e.index} · ${e.tps ? Number(e.tps).toFixed(1) + " t/s" : "writing…"}`,
        );
        setSceneNotes((prev) => ({
          ...prev,
          [e.index]:
            (e.tokens || 0) + " tokens" + (e.tps ? " · " + Number(e.tps).toFixed(1) + " t/s" : ""),
        }));
      }
      return;
    }
    if (e.type === "scene") {
      const idx = (e.index || 1) - 1;
      setScenes((prev) => {
        const next = prev.slice();
        next[idx] = { ...(next[idx] || { n: e.index }), ...e.scene, prompt: e.scene?.prompt || "" };
        return next;
      });
      const total = e.total || body.scene_count || 1;
      setProgressTo((e.index / total) * 100, `scene ${e.index} of ${total} done`);
      setSceneNotes((prev) => ({ ...prev, [e.index]: "ready" }));
      return;
    }
    if (e.type === "warning") {
      toast(e.message || "Generation warning", "warn");
      return;
    }
    if (e.type === "done") {
      if (e.bible) setBible(e.bible);
      setProgressTo(100, `done · ${body.scene_count} scenes`);
      toast("Storyboard ready", "ok");
      return;
    }
    if (e.type === "error") {
      throw new Error(e.message || "Generation failed");
    }
  };

  const startGeneration = async () => {
    if (generating) return;
    let body: ReturnType<typeof buildBody>;
    try {
      body = buildBody();
    } catch (e) {
      toast(errMsg(e), "error");
      return;
    }
    const ac = new AbortController();
    abortRef.current = ac;
    setGenerating(true);
    setErr("");
    setBible(null);
    setScenes([]);
    setSceneNotes({});
    setRequested(body.scene_count);
    setProgressTo(2, "starting…");
    try {
      await postSSE("/lazycomfy/api/llm/storyline", body, handleEvent(body), ac.signal);
    } catch (e: any) {
      if (e?.name === "AbortError") {
        toast("Stopped", "warn");
        setProgressText("stopped");
      } else {
        const message = errMsg(e);
        setErr(message);
        setProgressText(message);
        toast(message, "error");
      }
    } finally {
      setGenerating(false);
      abortRef.current = null;
      persist();
    }
  };

  const regenerate = async (n: number) => {
    if (generating || !bible) return;
    const scene = scenes[n - 1];
    if (!scene) return;
    const oldPrompt = scene.prompt || "";
    const oldWords = scene.words || wordCount(oldPrompt);
    const ac = new AbortController();
    abortRef.current = ac;
    setGenerating(true);
    setRegenN(n);
    setSceneNotes((prev) => ({ ...prev, [n]: "rewriting…" }));
    setScenes((prev) => {
      const next = prev.slice();
      next[n - 1] = { ...(next[n - 1] || { n }), prompt: "" };
      return next;
    });

    const sceneForApi: any = { ...scene };
    delete sceneForApi.prompt;
    delete sceneForApi.words;
    const body = {
      ...engineBody(),
      bible,
      characters: cast.filter((c) => c.name.trim()).map((c) => ({ name: c.name.trim(), ref: c.ref.trim() })),
      scene: sceneForApi,
      previous_scene: n > 1 ? { beat: scenes[n - 2]?.beat || "", prompt: scenes[n - 2]?.prompt || "" } : null,
      next_scene_beat: scenes[n] ? scenes[n].beat || "" : "",
      prompt_style: promptStyle,
      intensity,
      intensity_notes: intensity === "custom" ? intensityNotes.trim() : "",
      style: currentStyle(),
      aspect,
      source_ref: "<image1>",
      overview: overview.trim(),
    };

    let replaced = false;
    try {
      await postSSE(
        "/lazycomfy/api/llm/storyline/scene",
        body,
        (e) => {
          if (e.type === "chunk") {
            setScenes((prev) => {
              const next = prev.slice();
              const cur = next[n - 1] || { n, prompt: "" };
              next[n - 1] = { ...cur, prompt: (cur.prompt || "") + (e.text || "") };
              return next;
            });
          } else if (e.type === "reset") {
            setScenes((prev) => {
              const next = prev.slice();
              next[n - 1] = { ...(next[n - 1] || { n }), prompt: "" };
              return next;
            });
          } else if (e.type === "done") {
            replaced = true;
            const prompt = e.prompt || live.current.scenes[n - 1]?.prompt || "";
            const words = e.words || wordCount(prompt);
            setScenes((prev) => {
              const next = prev.slice();
              next[n - 1] = { ...(next[n - 1] || { n }), prompt, words };
              return next;
            });
            setSceneNotes((prev) => ({ ...prev, [n]: "ready" }));
          } else if (e.type === "status") {
            setSceneNotes((prev) => ({ ...prev, [n]: e.message || "rewriting…" }));
          } else if (e.type === "error") {
            throw new Error(e.message || "Rewrite failed");
          }
        },
        ac.signal,
      );
    } catch (e: any) {
      if (!replaced) {
        setScenes((prev) => {
          const next = prev.slice();
          next[n - 1] = { ...(next[n - 1] || { n }), prompt: oldPrompt, words: oldWords };
          return next;
        });
        setSceneNotes((prev) => ({ ...prev, [n]: oldPrompt ? "ready" : "rewrite failed" }));
        toast(e?.name === "AbortError" ? "Rewrite stopped" : errMsg(e), e?.name === "AbortError" ? "warn" : "error");
      }
    } finally {
      setRegenN(0);
      setGenerating(false);
      abortRef.current = null;
      persist();
    }
  };

  const addCharacter = () => {
    if (cast.length >= 6) {
      toast("Six characters is the maximum", "warn");
      return;
    }
    const next = newCastMember(castId.current + 1, cast.length);
    castId.current += 1;
    setCast((prev) => [...prev, next]);
    persist();
  };

  const removeCharacter = (id: number) => {
    if (cast.length <= 1) {
      toast("Keep at least one character", "warn");
      return;
    }
    setCast((prev) => prev.filter((c) => c.id !== id));
    persist();
  };

  const patchCast = (id: number, patch: Partial<CastMember>) => {
    setCast((prev) => prev.map((c) => (c.id === id ? { ...c, ...patch } : c)));
    persist();
  };

  const attachSheet = async (c: CastMember, file?: File | null) => {
    if (!file) return;
    if (!file.type.startsWith("image/")) {
      toast("Please choose an image file", "error");
      return;
    }
    if (file.size > 25 * 1024 * 1024) {
      toast("Character sheet is too large (max 25 MB)", "error");
      return;
    }
    try {
      const image = await shrinkImage(file);
      patchCast(c.id, {
        image,
        inputPath: "",
        name: c.name || file.name.replace(/\.[^.]+$/, "").replace(/[_-]+/g, " ").slice(0, 40),
      });
    } catch (e) {
      toast(errMsg(e), "error");
    }
  };

  const pickInputSheet = async (c: CastMember, value: string) => {
    if (!value) return;
    const it = inputImages.find((x) => inputPath(x) === value);
    if (!it) return;
    try {
      const url =
        "/view?" +
        new URLSearchParams({ filename: it.name, subfolder: it.subfolder || "", type: "input" }).toString();
      const res = await fetch(url);
      if (!res.ok) throw new Error("Could not read " + value + " (HTTP " + res.status + ")");
      const blob = await res.blob();
      if (!blob.type.startsWith("image/")) throw new Error("That input file is not an image");
      const file = new File([blob], it.name, { type: blob.type || "image/png" });
      const image = await shrinkImage(file);
      patchCast(c.id, {
        image,
        inputPath: value,
        name: c.name || it.name.replace(/\.[^.]+$/, "").replace(/[_-]+/g, " ").slice(0, 40),
      });
    } catch (e) {
      toast(errMsg(e), "error");
    }
  };

  const shiftRefs = () => {
    if (generating) {
      toast("Wait for the current run to finish", "warn");
      return;
    }
    if (cast.length && cast.every((c, i) => c.ref.trim() === `<image${i + 2}>`)) {
      toast("Character tags already start at <image2>", "warn");
      return;
    }
    const oldRefs = cast.map((c) => c.ref.trim());
    const map = new Map<string, string>();
    const nextCast = cast.map((c, i) => {
      const ref = `<image${i + 2}>`;
      if (/^<image\d+>$/.test(oldRefs[i])) map.set(oldRefs[i], ref);
      return { ...c, ref };
    });
    setCast(nextCast);
    if (bible) {
      const byName = new Map(nextCast.map((c) => [c.name.trim().toLowerCase(), c.ref]));
      setBible((prev: any) => {
        if (!prev) return prev;
        const chars = (prev.characters || []).map((c: any) => {
          const ref = byName.get(String(c.name || "").trim().toLowerCase());
          return ref ? { ...c, ref } : c;
        });
        return { ...prev, characters: chars };
      });
    }
    const rewrite = (text: string) =>
      String(text || "").replace(/<image\d+>/g, (m) => map.get(m) || m);
    let changed = 0;
    const updatedScenes = scenes.map((s) => {
      if (!s.prompt) return s;
      const prompt = rewrite(s.prompt);
      if (prompt === s.prompt) return s;
      changed += 1;
      return { ...s, prompt, words: wordCount(prompt) };
    });
    setScenes(updatedScenes);
    persist();
    toast(changed ? "Moved the tags and updated " + changed + " prompts" : "Character tags moved to <image2> and up", "ok");
  };

  const storyText = (): string =>
    scenes
      .filter((s) => s && s.prompt)
      .map((s, i) => "SCENE " + String(i + 1).padStart(2, "0") + " — " + (s.title || "") + "\n" + s.prompt)
      .join("\n\n");

  const exportName = (): string => {
    const t = bible?.title || "storyline";
    return (
      t
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, "-")
        .replace(/^-|-$/g, "")
        .slice(0, 50) || "storyline"
    );
  };

  const download = (name: string, text: string, type: string) => {
    const blob = new Blob([text], { type });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = name;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 1500);
  };

  const copyAll = async () => {
    const text = storyText();
    if (!text) return;
    try {
      await copyText(text);
      toast("Copied to clipboard", "ok");
    } catch {
      toast("Clipboard unavailable", "error");
    }
  };

  const copyScene = async (n: number) => {
    const text = scenes[n - 1]?.prompt || "";
    if (!text.trim()) return;
    try {
      await copyText(text);
      toast("Copied to clipboard", "ok");
    } catch {
      toast("Clipboard unavailable", "error");
    }
  };

  const hint = (() => {
    if (!models.length) {
      return "No GGUF models yet. Open Prompt Forge → search Huihui-Qwen3-VL-8B-Instruct-abliterated → download Q4_K_M and mmproj-F16.";
    }
    if (/qwen3.*vl/i.test(model) && (mmproj === "Auto-Detect" || !mmproj)) {
      return "Qwen3-VL projector files often omit the model name. Pick mmproj-F16 explicitly in the projector list.";
    }
    if (/qwen3.*vl/i.test(model) && mmproj === "None") {
      return "Vision is off. The story bible pass needs a matching mmproj.";
    }
    return "";
  })();

  const modelOptions = models.map((m) => ({ value: m.name, label: `${m.name} (${m.size_gb} GB)` }));
  const mmprojOptions = [
    { value: "Auto-Detect", label: "Auto-detect projector" },
    { value: "None", label: "None (text only)" },
    ...mmprojs.map((m) => ({ value: m.name, label: `${m.name} (${m.size_gb} GB)` })),
  ];

  const boardTitle = bible?.title || "Your storyboard";
  const boardLogline =
    bible?.logline ||
    (generating ? "Pass 1 — reading the cast and building the bible." : "Attach character sheets, describe the arc, and write 2–24 connected prompts.");
  const hasPrompts = scenes.some((s) => s && s.prompt);

  return (
    <main className="layout">
      <section className="panel storyline-left">
        <div className="group">
          <div className="group-head">
            <label className="group-label">Engine</label>
            <span className="badge" style={{ marginLeft: "auto" }}>
              {loading ? "loading" : alive ? "running" : status?.status === "failed" ? "failed" : "idle"}
            </span>
          </div>
          <div className="field">
            <label>GGUF model</label>
            <Select
              value={model}
              options={modelOptions}
              onChange={(v) => {
                setModel(v);
                persist();
              }}
              placeholder={models.length ? "Select a model…" : "No GGUF models found"}
            />
          </div>
          <div className="field">
            <label>Vision projector</label>
            <Select
              value={mmproj || "Auto-Detect"}
              options={mmprojOptions}
              onChange={(v) => {
                setMmproj(v);
                persist();
              }}
            />
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 6 }}>
            <button className="act-btn" type="button" onClick={toggleLoad} disabled={loading || (!alive && !model)}>
              {loading ? "Loading…" : alive ? "Unload" : "Load model"}
            </button>
            <Link href="/forge" className="hint" style={{ marginLeft: "auto" }}>
              Get a vision model →
            </Link>
          </div>
          {hint && <p className="hint" style={{ marginTop: 8 }}>{hint}</p>}
          <details className="story-details" style={{ marginTop: 8 }}>
            <summary>Inference settings</summary>
            <div className="grid3" style={{ marginTop: 8 }}>
              <div className="field">
                <label>Context</label>
                <input type="number" min={8192} max={65536} step={1024} value={ctx} onChange={(e) => { setCtx(e.target.value); persist(); }} />
              </div>
              <div className="field">
                <label>Temp</label>
                <input type="number" min={0} max={2} step={0.05} value={temp} onChange={(e) => { setTemp(e.target.value); persist(); }} />
              </div>
              <div className="field">
                <label>Top-P</label>
                <input type="number" min={0} max={1} step={0.05} value={topP} onChange={(e) => { setTopP(e.target.value); persist(); }} />
              </div>
            </div>
            <p className="hint">A loaded model is reused. Generating loads it automatically when needed.</p>
          </details>
          <div className="status-strip" style={{ marginTop: 8, marginBottom: 0 }}>
            <span className={"dot " + backend.dot} />
            <span className="hint">{backend.label}</span>
          </div>
        </div>

        <div className="group">
          <div className="group-head">
            <label className="group-label">Cast</label>
            <span className="badge" style={{ marginLeft: "auto" }}>{cast.length}</span>
          </div>
          <div>
            {cast.map((c) => (
              <div className="cast-card" key={c.id}>
                <button
                  className="cast-thumb"
                  type="button"
                  title="Attach a character sheet"
                  onClick={() => fileRefs.current[c.id]?.click()}
                >
                  {c.image ? (
                    // eslint-disable-next-line @next/next/no-img-element
                    <img src={c.image} alt="" />
                  ) : (
                    <span className="cast-plus">+</span>
                  )}
                </button>
                <input
                  ref={(el) => {
                    fileRefs.current[c.id] = el;
                  }}
                  type="file"
                  accept="image/*"
                  hidden
                  onChange={(e) => {
                    attachSheet(c, e.target.files?.[0]);
                    e.target.value = "";
                  }}
                />
                <div className="cast-main">
                  <div className="cast-row">
                    <input
                      className="cast-name"
                      type="text"
                      value={c.name}
                      placeholder="Character name"
                      onChange={(e) => patchCast(c.id, { name: e.target.value })}
                    />
                    <input
                      className="cast-ref"
                      type="text"
                      value={c.ref}
                      title="Reference tag used in prompts"
                      onChange={(e) => patchCast(c.id, { ref: e.target.value })}
                    />
                    <button className="cast-del" type="button" title="Remove character" onClick={() => removeCharacter(c.id)}>
                      ×
                    </button>
                  </div>
                  <input
                    className="cast-notes"
                    type="text"
                    value={c.notes}
                    placeholder="Identity notes (optional)"
                    onChange={(e) => patchCast(c.id, { notes: e.target.value })}
                  />
                  <div className="cast-picker">
                    <Select
                      value={c.inputPath}
                      options={[
                        { value: "", label: "Choose from input folder…" },
                        ...inputImages.map((it) => ({ value: inputPath(it), label: inputPath(it) })),
                      ]}
                      onChange={(v) => {
                        if (v) pickInputSheet(c, v);
                      }}
                    />
                  </div>
                </div>
              </div>
            ))}
          </div>
          <div className="add-row" style={{ marginTop: 8 }}>
            <div style={{ display: "flex", gap: 6 }}>
              <button className="act-btn" type="button" onClick={addCharacter} disabled={generating}>
                + Add character
              </button>
              <button
                className="act-btn"
                type="button"
                title="Refresh the input image list"
                disabled={generating}
                onClick={async () => {
                  await loadInputs();
                  toast("Input folder refreshed", "ok");
                }}
              >
                ↻
              </button>
            </div>
            <span className="hint">Upload or pick from input</span>
          </div>
        </div>

        <div className="group">
          <div className="group-head">
            <label className="group-label">Story</label>
          </div>
          <div className="field">
            <label>Overview</label>
            <textarea
              rows={5}
              value={overview}
              placeholder="Two strangers share a night train across Europe. Quiet tension becomes a confession, then a choice at dawn…"
              onChange={(e) => { setOverview(e.target.value); persist(); }}
            />
          </div>
          <div className="grid2">
            <div className="field">
              <label>Scenes</label>
              <input type="number" min={2} max={24} step={1} value={sceneCount} onChange={(e) => { setSceneCount(e.target.value); persist(); }} />
            </div>
            <div className="field">
              <label>Aspect</label>
              <Select value={aspect} options={ASPECTS} onChange={(v) => { setAspect(v); persist(); }} />
            </div>
          </div>
          <div className="grid2">
            <div className="field">
              <label>Look</label>
              <Select value={style} options={STYLES} onChange={(v) => { setStyle(v); persist(); }} />
            </div>
            <div className="field">
              <label>Prompt mode</label>
              <Select
                value={promptStyle}
                options={[
                  { value: "scene", label: "New frame + refs" },
                  { value: "edit", label: "Edit previous" },
                ]}
                onChange={(v) => { setPromptStyle(v); persist(); }}
              />
            </div>
          </div>
          {style === "custom" && (
            <div className="field">
              <label>Custom look notes</label>
              <input
                type="text"
                value={styleNotes}
                placeholder="e.g. warm tungsten, 1970s Kodak, rain-soaked neon"
                onChange={(e) => { setStyleNotes(e.target.value); persist(); }}
              />
            </div>
          )}
          <div className="field">
            <label>Intensity</label>
            <Select value={intensity} options={INTENSITIES} onChange={(v) => { setIntensity(v); persist(); }} />
          </div>
          {intensity === "custom" && (
            <div className="field">
              <label>Custom intensity direction</label>
              <textarea
                rows={3}
                value={intensityNotes}
                placeholder="Describe the exact content level, focus and phrasing you want the writer to follow…"
                onChange={(e) => { setIntensityNotes(e.target.value); persist(); }}
              />
            </div>
          )}
          {promptStyle === "edit" && (
            <div className="notice">
              <span>
                <b>Edit mode:</b> attach the previous frame as <code>&lt;image1&gt;</code>. Character sheets need <code>&lt;image2&gt;</code> and up.
              </span>
              <button className="act-btn" type="button" onClick={shiftRefs} disabled={generating}>
                Shift tags
              </button>
            </div>
          )}
          <label className="story-check">
            <input type="checkbox" checked={adultAck} onChange={(e) => { setAdultAck(e.target.checked); persist(); }} />
            I confirm every character is an adult (18+), and intimacy is consensual.
          </label>
          <button className="btn btn-primary" type="button" onClick={startGeneration} disabled={generating || !model}>
            {generating && <span className="spin" />}
            {generating ? "Writing…" : "Write the storyboard"}
          </button>
          {generating && (
            <button
              className="btn"
              type="button"
              style={{ width: "100%", marginTop: 8 }}
              onClick={() => abortRef.current?.abort()}
            >
              Cancel
            </button>
          )}
          {showProgress && (
            <div className="progress-row">
              <div className="progress-wrap">
                <div className="progress-bar" style={{ width: progress + "%" }} />
              </div>
              <span className="hint" style={{ maxWidth: 150, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                {progressText}
              </span>
            </div>
          )}
          {err && <div className="err-banner" style={{ marginTop: 8 }}>{err}</div>}
          <details className="story-details" style={{ marginTop: 8 }}>
            <summary>How it works</summary>
            <p className="hint" style={{ marginTop: 8 }}>
              Pass 1 reads the sheets and writes a story bible: identity anchors, wardrobe, continuity and one beat per
              scene. Pass 2 writes each scene&apos;s prompt from that bible, carrying the previous frame forward and
              rejecting thin drafts. Prompts are Qwen-Image-2.1 natural-language paragraphs, not tag lists.
            </p>
          </details>
        </div>
      </section>

      <section className="panel">
        <div className="board-head">
          <div style={{ minWidth: 0 }}>
            <h1 className="story-title">{boardTitle}</h1>
            <p className="note" style={{ marginTop: 2 }}>{boardLogline}</p>
          </div>
          {(hasPrompts || !!bible) && (
            <div className="board-actions">
              <button className="act-btn" type="button" onClick={copyAll}>Copy all</button>
              <button
                className="act-btn"
                type="button"
                onClick={() => download(exportName() + ".txt", storyText(), "text/plain")}
              >
                .txt
              </button>
              <button
                className="act-btn"
                type="button"
                onClick={() =>
                  download(exportName() + ".json", JSON.stringify({ bible, scenes }, null, 2), "application/json")
                }
              >
                .json
              </button>
            </div>
          )}
        </div>

        {bible && (
          <details className="story-bible">
            <summary>Story bible · {(bible.scenes || []).length} scenes</summary>
            <div className="bible-body">
              {bible.world && (
                <div>
                  <b>World.</b> {bible.world}
                </div>
              )}
              {bible.visual_style && (
                <div>
                  <b>Look.</b> {bible.visual_style}
                </div>
              )}
              <div className="bible-chips">
                {(bible.characters || []).map((c: any, i: number) => (
                  <span className="bible-chip" key={i}>
                    {c.name} <em>{c.ref}</em>
                  </span>
                ))}
              </div>
              {!!(bible.continuity_rules || []).length && (
                <div>
                  <b>Continuity.</b>
                  <ul className="bible-scenes">
                    {(bible.continuity_rules || []).map((r: string, i: number) => (
                      <li key={i}>{r}</li>
                    ))}
                  </ul>
                </div>
              )}
              <div>
                <b>Beats.</b>
                <ol className="bible-scenes">
                  {(bible.scenes || []).map((s: any, i: number) => (
                    <li key={i}>
                      <b>{s.title || `Scene ${s.n}`}</b> — {s.beat || ""}
                    </li>
                  ))}
                </ol>
              </div>
            </div>
          </details>
        )}

        {scenes.length === 0 && !bible ? (
          <div className="story-empty">
            <svg width="42" height="42" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round">
              <rect x="2.5" y="5" width="19" height="14" rx="2" />
              <path d="M7 5v14" />
              <path d="M7 9.5h12" />
              <path d="M11 9.5V19" />
            </svg>
            <h2>No storyboard yet</h2>
            <p>Two character sheets, one overview, and a local vision model. The first pass builds the bible; the second writes every frame.</p>
          </div>
        ) : (
          <div className="scene-list">
            {scenes.map((s, i) => {
              const n = i + 1;
              const note = sceneNotes[n] || (s.prompt ? "ready" : "queued");
              const words = s.words || wordCount(s.prompt || "");
              return (
                <div className={"scene-card" + (s.prompt ? "" : " writing")} key={n}>
                  <div className="scene-head">
                    <div className="scene-num">{String(n).padStart(2, "0")}</div>
                    <div className="scene-meta">
                      <div className="scene-title">{s.title || `Scene ${n}`}</div>
                      <div className="scene-beat">{s.beat || ""}</div>
                    </div>
                    <div className="scene-actions">
                      <button className="act-btn" type="button" onClick={() => copyScene(n)} disabled={!s.prompt}>
                        Copy
                      </button>
                      <button
                        className="act-btn"
                        type="button"
                        title="Rewrite this prompt"
                        onClick={() => regenerate(n)}
                        disabled={generating || !bible}
                      >
                        ↻
                      </button>
                    </div>
                  </div>
                  <textarea
                    className="scene-prompt"
                    spellCheck={false}
                    value={s.prompt || ""}
                    placeholder="Writing…"
                    readOnly={generating}
                    onChange={(e) => {
                      const prompt = e.target.value;
                      setScenes((prev) => {
                        const next = prev.slice();
                        next[i] = { ...next[i], prompt, words: wordCount(prompt) };
                        return next;
                      });
                      persist();
                    }}
                  />
                  <div className="scene-foot">
                    <span className={"scene-state" + (note === "ready" ? " ok" : "") + (regenN === n || note.startsWith("writing") ? " busy" : "")}>
                      {note}
                    </span>
                    <span className="scene-words">{words} words</span>
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </section>
    </main>
  );
}
