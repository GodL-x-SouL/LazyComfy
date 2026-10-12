"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import {
  errMsg,
  fetchLlmConfig,
  fetchLlmStatus,
  llmLoad,
  llmUnload,
  llmInstall,
  llmSearch,
  llmFiles,
  llmDownload,
  llmCancelDownload,
  loadSession,
  saveSession,
} from "@/lib/api";
import { useToast } from "@/lib/store";
import { Select } from "@/components/controls";

type ForgeMode = "enhance" | "caption" | "edit";

const num = (v: string, dflt: number): number => {
  const n = parseFloat(v);
  return Number.isFinite(n) ? n : dflt;
};

const fmtSize = (b: number): string => {
  if (!b) return "—";
  if (b >= 1024 ** 3) return (b / 1024 ** 3).toFixed(2) + " GB";
  if (b >= 1024 ** 2) return (b / 1024 ** 2).toFixed(1) + " MB";
  return Math.round(b / 1024) + " KB";
};

const fmtNum = (n: number): string => (n >= 1000 ? (n / 1000).toFixed(1) + "k" : String(n));

export default function ForgePage() {
  const toast = useToast();
  const [cfg, setCfg] = useState<any>(null);
  const [backendState, setBackendState] = useState<{ dot: string; label: string }>({ dot: "", label: "Checking backend" });
  const [models, setModels] = useState<{ name: string; size_gb: number }[]>([]);
  const [mmprojs, setMmprojs] = useState<{ name: string; size_gb: number }[]>([]);
  const [status, setStatus] = useState<any>(null);
  const [tasks, setTasks] = useState<any[]>([]);
  const [model, setModel] = useState("");
  const [mmproj, setMmproj] = useState("Auto-Detect");
  const [ctx, setCtx] = useState("2048");
  const [temp, setTemp] = useState("0.7");
  const [maxTok, setMaxTok] = useState("512");
  const [topP, setTopP] = useState("0.9");
  const [mode, setModeState] = useState<ForgeMode>("enhance");
  const [prompt, setPrompt] = useState("");
  const [editPrompt, setEditPrompt] = useState("");
  const [output, setOutput] = useState("");
  const [genStatus, setGenStatus] = useState("");
  const [generating, setGenerating] = useState(false);
  const [imageData, setImageData] = useState("");
  const [imageName, setImageName] = useState("");
  const [query, setQuery] = useState("");
  const [searching, setSearching] = useState(false);
  const [repos, setRepos] = useState<any[]>([]);
  const [openRepos, setOpenRepos] = useState<Record<string, { loading: boolean; files: any[]; loaded: boolean; error: string; open: boolean }>>({});
  const [installing, setInstalling] = useState(false);
  const booted = useRef(false);
  const pendingModel = useRef<{ model?: string; mmproj?: string } | null>(null);
  /* Live mirror so the debounced save always carries post-setState values. */
  const live = useRef<any>({});
  live.current = { model, mmproj, ctx, temp, maxTok, topP, mode, prompt, editPrompt };
  const saveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const generatingRef = useRef(false);
  const imgInputRef = useRef<HTMLInputElement>(null);

  const collect = useCallback(
    () => ({
      model: live.current.model,
      mmproj: live.current.mmproj,
      ctx: live.current.ctx,
      temp: live.current.temp,
      max_tokens: live.current.maxTok,
      top_p: live.current.topP,
      mode: live.current.mode,
      prompt: live.current.prompt,
      edit_prompt: live.current.editPrompt,
      output: output.slice(0, 200000),
      image: imageData.length <= 2500000 ? imageData : "",
      imageName,
    }),
    [output, imageData, imageName],
  );

  const persist = useCallback(() => {
    if (!booted.current) return;
    if (saveTimer.current) clearTimeout(saveTimer.current);
    saveTimer.current = setTimeout(() => {
      saveTimer.current = null;
      saveSession("forge", collect());
    }, 400);
  }, [collect]);

  useEffect(() => {
    const onUnload = () => saveSession("forge", collect());
    window.addEventListener("beforeunload", onUnload);
    return () => window.removeEventListener("beforeunload", onUnload);
  }, [collect]);

  const refreshConfig = useCallback(async () => {
    let c: any;
    try {
      c = await fetchLlmConfig();
    } catch {
      setBackendState({ dot: "err", label: "Backend error" });
      return;
    }
    setCfg(c);
    setModels(c.models || []);
    setMmprojs(c.mmprojs || []);
    setStatus(c.status || null);
    setTasks(c.tasks || []);
    if (c.backend_present) setBackendState({ dot: "on", label: "llama.cpp ready" });
    else if (c.install?.status === "error") setBackendState({ dot: "err", label: "backend missing" });
    else setBackendState({ dot: "retry", label: "backend missing" });
  }, []);

  /* boot: restore session, then start 2s config poll */
  useEffect(() => {
    let cancelled = false;
    let timer: ReturnType<typeof setInterval> | null = null;
    (async () => {
      try {
        localStorage.removeItem("lazycomfy.forge");
      } catch {
        /* ignore */
      }
      const saved = (await loadSession()).forge;
      if (!cancelled && saved) {
        if (saved.mode === "caption" || saved.mode === "edit" || saved.mode === "enhance") setModeState(saved.mode);
        if (saved.prompt) setPrompt(saved.prompt);
        if (saved.edit_prompt) setEditPrompt(saved.edit_prompt);
        if (saved.ctx) setCtx(saved.ctx);
        if (saved.temp) setTemp(saved.temp);
        if (saved.max_tokens) setMaxTok(saved.max_tokens);
        if (saved.top_p) setTopP(saved.top_p);
        if (saved.output) {
          setOutput(saved.output);
          setGenStatus("Restored from previous session");
        }
        if (saved.image) {
          setImageData(saved.image);
          setImageName(saved.imageName || "restored image");
        }
        pendingModel.current = { model: saved.model, mmproj: saved.mmproj };
      }
      await refreshConfig();
      if (cancelled) return;
      const sm = pendingModel.current;
      if (sm) {
        if (sm.model) setModel(sm.model);
        if (sm.mmproj) setMmproj(sm.mmproj);
        pendingModel.current = null;
      }
      booted.current = true;
      timer = setInterval(refreshConfig, 2000);
    })();
    return () => {
      cancelled = true;
      if (timer) clearInterval(timer);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const setMode = (m: ForgeMode) => {
    setModeState(m);
    if (booted.current) setTimeout(persist, 0);
  };

  const toggleLoad = async () => {
    let st = status;
    if (!st) {
      try {
        st = await fetchLlmStatus();
        setStatus(st);
      } catch (e) {
        toast(errMsg(e), "error");
        return;
      }
    }
    if (st?.status === "running" || st?.status === "loading") {
      if (generatingRef.current) return;
      try {
        await llmUnload();
        toast("Model unloaded", "ok");
      } catch (e) {
        toast(errMsg(e), "error");
      }
      refreshConfig();
      return;
    }
    if (!model) {
      toast("Select a GGUF model first.", "error");
      return;
    }
    try {
      await llmLoad(model, mmproj, num(ctx, 2048));
      toast("Model loaded", "ok");
    } catch (e) {
      toast(errMsg(e), "error");
    }
    refreshConfig();
  };

  const generate = async () => {
    if (generatingRef.current) return;
    if (!model) {
      toast("Select a GGUF model first.", "error");
      return;
    }
    generatingRef.current = true;
    setGenerating(true);
    setOutput("");
    setGenStatus("Starting…");
    try {
      const res = await fetch("/lazycomfy/api/llm/generate", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          mode,
          model,
          mmproj,
          context_length: num(ctx, 2048),
          temperature: num(temp, 0.7),
          max_tokens: num(maxTok, 512),
          top_p: num(topP, 0.9),
          prompt,
          edit_prompt: editPrompt,
          image: imageData || "",
        }),
      });
      if (!res.ok) {
        let msg = "HTTP " + res.status;
        try {
          const d = await res.json();
          if (d?.error?.message) msg = d.error.message;
        } catch {
          /* ignore */
        }
        throw new Error(msg);
      }
      if (!res.body) throw new Error("Streaming not supported by this browser");
      const reader = res.body.getReader();
      const dec = new TextDecoder();
      let buf = "";
      let acc = "";
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        let idx: number;
        while ((idx = buf.indexOf("\n\n")) >= 0) {
          const ev = buf.slice(0, idx);
          buf = buf.slice(idx + 2);
          const line = ev.startsWith("data:") ? ev.slice(5).trim() : "";
          if (!line) continue;
          let evt: any;
          try {
            evt = JSON.parse(line);
          } catch {
            continue;
          }
          if (evt.type === "chunk") {
            acc += evt.text || "";
            setOutput(acc);
            const s = evt.stats;
            setGenStatus(
              s ? `${s.eval_tokens ?? 0} tokens · ${(s.tokens_sec ?? 0).toFixed(1)} t/s · ${(s.elapsed_time ?? 0).toFixed(1)}s` : "Generating…",
            );
          } else if (evt.type === "done") {
            const s = evt.stats || {};
            setGenStatus(
              `Done · ${s.eval_tokens ?? 0} tokens · ${(s.tokens_sec ?? 0).toFixed(1)} t/s · ${(s.elapsed_time ?? 0).toFixed(1)}s`,
            );
          } else if (evt.type === "error") {
            toast(evt.message || "Generation error", "error");
            setGenStatus("Error: " + (evt.message || "unknown"));
          }
        }
      }
    } catch (e: any) {
      toast(e?.message || String(e), "error");
      setGenStatus("Error: " + (e?.message || e));
    } finally {
      generatingRef.current = false;
      setGenerating(false);
      persist();
    }
  };

  const copyOut = async () => {
    if (!output.trim()) return;
    try {
      await navigator.clipboard.writeText(output);
      toast("Copied to clipboard.", "ok");
    } catch {
      toast("Clipboard unavailable.", "error");
    }
  };

  const readImage = (file?: File | null) => {
    if (!file) return;
    if (!file.type.startsWith("image/")) {
      toast("Please choose an image file.", "error");
      return;
    }
    if (file.size > 11 * 1024 * 1024) {
      toast("Image too large (max ~11 MB).", "error");
      return;
    }
    const fr = new FileReader();
    fr.onload = () => {
      setImageData(String(fr.result || ""));
      setImageName(file.name);
      persist();
    };
    fr.readAsDataURL(file);
  };

  const install = async () => {
    setInstalling(true);
    try {
      const r = await llmInstall();
      if (r?.status === "error") toast(r?.error || "Install failed", "error");
    } catch (e) {
      toast(errMsg(e), "error");
    } finally {
      setInstalling(false);
      refreshConfig();
    }
  };

  const doSearch = async () => {
    const q = query.trim();
    if (!q) {
      toast("Enter a model name to search.", "error");
      return;
    }
    setSearching(true);
    try {
      const r = await llmSearch(q);
      setRepos(r.repos || []);
      if (!(r.repos || []).length) toast(`No GGUF repos found for "${q}".`);
    } catch (e) {
      toast(errMsg(e), "error");
    } finally {
      setSearching(false);
    }
  };

  const toggleFiles = async (repoId: string) => {
    const st = openRepos[repoId];
    if (st?.open) {
      setOpenRepos((prev) => ({ ...prev, [repoId]: { ...st, open: false } }));
      return;
    }
    if (st?.loaded) {
      setOpenRepos((prev) => ({ ...prev, [repoId]: { ...st, open: true } }));
      return;
    }
    setOpenRepos((prev) => ({ ...prev, [repoId]: { loading: true, files: [], loaded: false, error: "", open: true } }));
    try {
      const r = await llmFiles(repoId);
      setOpenRepos((prev) => ({
        ...prev,
        [repoId]: { loading: false, files: r.files || [], loaded: true, error: "", open: true },
      }));
    } catch (e) {
      setOpenRepos((prev) => ({
        ...prev,
        [repoId]: { loading: false, files: [], loaded: false, error: errMsg(e), open: true },
      }));
    }
  };

  const downloadFile = async (url: string, name: string) => {
    try {
      await llmDownload(url, name);
      toast("Downloading " + name, "ok");
    } catch (e) {
      toast(errMsg(e), "error");
    }
    refreshConfig();
  };

  const running = status?.status === "running";
  const loading = status?.status === "loading";
  const alive = running || loading;
  const installInfo = cfg?.install || {};
  const installRunning = installInfo.status === "running" || installInfo.status === "extracting";
  const activeTasks = (tasks || []).filter((t) => ["starting", "downloading", "cancelling"].includes(t.status));
  const doneTasks = (tasks || []).filter((t) => ["done", "error", "cancelled"].includes(t.status));

  return (
    <main className="layout">
      <section className="panel">
        <div className="group">
          <label className="group-label">Model</label>
          {cfg?.models_dir_error && <div className="err-banner">{cfg.models_dir_error}</div>}
          <div className="field">
            <label>GGUF model</label>
            <Select
              value={model}
              options={models.map((m) => ({ value: m.name, label: `${m.name} (${m.size_gb} GB)` }))}
              onChange={(v) => { setModel(v); persist(); }}
              placeholder={models.length ? "Select a model…" : "No models downloaded"}
            />
          </div>
          <div className="field">
            <label>Vision projector (mmproj)</label>
            <Select
              value={mmproj}
              options={[
                { value: "Auto-Detect", label: "Auto-Detect Projector" },
                { value: "None", label: "None (Text-only)" },
                ...mmprojs.map((m) => ({ value: m.name, label: `${m.name} (${m.size_gb} GB)` })),
              ]}
              onChange={(v) => { setMmproj(v); persist(); }}
            />
            <p className="note">Models without a matching mmproj still work for text-only modes.</p>
          </div>
          <div className="grid2">
            <div className="field">
              <label>Context length</label>
              <input type="number" min={512} max={65536} step={512} value={ctx} onChange={(e) => { setCtx(e.target.value); persist(); }} />
            </div>
            <div className="field">
              <label>Temperature</label>
              <input type="number" min={0} max={2} step={0.05} value={temp} onChange={(e) => { setTemp(e.target.value); persist(); }} />
            </div>
            <div className="field">
              <label>Max tokens</label>
              <input type="number" min={1} max={32768} step={1} value={maxTok} onChange={(e) => { setMaxTok(e.target.value); persist(); }} />
            </div>
            <div className="field">
              <label>Top-P</label>
              <input type="number" min={0} max={1} step={0.05} value={topP} onChange={(e) => { setTopP(e.target.value); persist(); }} />
            </div>
          </div>
          {!cfg?.backend_present && (
            <div className="field" style={{ marginTop: 8 }}>
              <div className="progress-wrap" hidden={!installRunning}>
                <div className="progress-bar" style={{ width: (installInfo.progress || 0) + "%" }} />
              </div>
              <p className="hint">
                {installRunning ? installInfo.stage || "installing…" : installInfo.error ? "" : "Backend not installed — click Install to download."}
              </p>
              {installInfo.error && !installRunning && <p className="err-line">{installInfo.error}</p>}
              {!installRunning && (
                <button className="act-btn" type="button" disabled={installing} onClick={install} style={{ marginTop: 6 }}>
                  Install backend
                </button>
              )}
            </div>
          )}
          <button className="btn btn-primary" type="button" disabled={loading || (!alive && !(models.length > 0 && !generating))} onClick={toggleLoad} style={{ marginTop: 8 }}>
            {loading ? "Loading Model…" : alive ? "Unload Model" : "Load Model"}
          </button>
        </div>

        <div className="group">
          <label className="group-label">Engine</label>
          {!cfg?.backend_present && (
            <div className="err-banner">llama.cpp backend is not installed — click Install backend above to download it.</div>
          )}
          <div className="kv"><span>State</span><span>{alive ? `${status?.model || ""}${status?.mmproj ? " · " + status.mmproj : ""}${loading ? " — loading…" : ""}` : status?.status === "failed" ? `Failed — ${status?.last_error || "unknown error"}` : "Idle"}</span></div>
          {alive && (
            <div className="kv"><span>Mode</span><span>{(status?.gpu_layers || 0) > 0 ? `GPU ${status.gpu_layers}/${status.total_layers} layers` : "CPU"}</span></div>
          )}
          {alive && !!status?.placement_note && (
            <p className="note">GPU offload failed, running on CPU: {status.placement_note}</p>
          )}
          {alive && !!status?.log_tail && (
            <details>
              <summary className="hint" style={{ cursor: "pointer", margin: "4px 0" }}>Server log</summary>
              <pre className="logbox">{status.log_tail}</pre>
            </details>
          )}
        </div>

        <div className="group">
          <label className="group-label">Task</label>
          <div className="seg" role="group">
            {(["enhance", "caption", "edit"] as ForgeMode[]).map((m) => (
              <button key={m} type="button" aria-pressed={mode === m} className={mode === m ? "active" : ""} onClick={() => setMode(m)}>
                {m === "enhance" ? "Enhance Prompt" : m === "caption" ? "Image Caption" : "Image Edit"}
              </button>
            ))}
          </div>
        </div>

        <div className="group">
          <label className="group-label">Input</label>
          <div className="field">
            <label>{mode === "caption" ? "Instruction (optional)" : "Prompt to enhance"}</label>
            <textarea value={prompt} placeholder={mode === "caption" ? "Describe this image in detail." : "A cat on a rooftop at sunset…"} onChange={(e) => { setPrompt(e.target.value); persist(); }} />
          </div>
          {mode === "edit" && (
            <div className="field">
              <label>Edit instruction</label>
              <textarea value={editPrompt} placeholder="Change the background to a forest, keep the cat…" onChange={(e) => { setEditPrompt(e.target.value); persist(); }} />
            </div>
          )}
          {mode !== "enhance" && (
            <div className="field">
              <label>Image</label>
              <div className="dz" role="button" tabIndex={0} onClick={() => imgInputRef.current?.click()} onKeyDown={(e) => e.key === "Enter" && imgInputRef.current?.click()}>
                {imageData ? (
                  <>
                    {/* eslint-disable-next-line @next/next/no-img-element */}
                    <img src={imageData} alt="preview" />
                    <div>{imageName}</div>
                  </>
                ) : (
                  <>Click or drop an image here<div className="hint">PNG / JPEG, up to ~11 MB</div></>
                )}
              </div>
              <input ref={imgInputRef} type="file" accept="image/*" hidden onChange={(e) => { readImage(e.target.files?.[0]); e.target.value = ""; }} />
              {imageData && (
                <button className="act-btn danger" type="button" style={{ marginTop: 6 }} onClick={() => { setImageData(""); setImageName(""); persist(); }}>
                  Remove
                </button>
              )}
            </div>
          )}
          <button className="btn btn-primary" type="button" disabled={generating || !models.length} onClick={generate}>
            {generating && <span className="spin" />}
            {generating ? "Generating…" : "Generate"}
          </button>
        </div>

        <div className="group">
          <label className="group-label">Output</label>
          <div className="field">
            <textarea readOnly value={output} placeholder="Generated text appears here…" style={{ minHeight: 140 }} />
            <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 6 }}>
              <span className="hint" style={{ flex: 1 }}>{genStatus}</span>
              <button className="act-btn" type="button" disabled={!output.trim()} onClick={copyOut}>
                Copy
              </button>
            </div>
          </div>
        </div>
      </section>

      <section className="panel">
        <div className="group">
          <label className="group-label">Model downloader</label>
          <p className="note">Search HuggingFace for GGUF repos — view files and download them straight into <span className="mono">ComfyUI/models/llm_gguf</span>.</p>
          <div style={{ display: "flex", gap: 8, marginTop: 8 }}>
            <input style={{ flex: 1 }} placeholder="e.g. Qwen 3 4b vl, SmolVLM, Llama 3.2" value={query} onChange={(e) => setQuery(e.target.value)} onKeyDown={(e) => e.key === "Enter" && doSearch()} />
            <button className="act-btn" type="button" disabled={searching} onClick={doSearch}>
              Search
            </button>
          </div>
          <div style={{ marginTop: 10, display: "flex", flexDirection: "column", gap: 8 }}>
            {repos.map((r) => {
              const st = openRepos[r.id];
              const open = !!st?.open;
              return (
                <div key={r.id} style={{ border: "1px solid var(--border)", borderRadius: 10, padding: 10 }}>
                  <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                    <span style={{ fontWeight: 600, flex: 1, minWidth: 0, overflowWrap: "anywhere" }} title={r.id}>{r.id}</span>
                    <span className="hint" style={{ flex: "none", whiteSpace: "nowrap" }}>
                      {r.gated ? "Gated · " : ""}↓ {fmtNum(r.downloads || 0)} · ★ {fmtNum(r.likes || 0)}
                    </span>
                    <button className="act-btn" type="button" style={{ flex: "none" }} onClick={() => toggleFiles(r.id)}>
                      {open ? "Hide Files" : "View Files"}
                    </button>
                  </div>
                  {open && (
                    <div style={{ marginTop: 8 }}>
                      {st?.loading && <p className="note">Loading files…</p>}
                      {st?.error && <p className="err-line">{st.error}</p>}
                      {st?.loaded && !(st.files?.length) && <p className="note">No .gguf files in this repo.</p>}
                      {(st?.files || []).map((f: any) => (
                        <div key={f.url} className="dl-item" style={{ padding: "4px 0" }}>
                          <div>
                            <div className="dl-item-title" title={f.name}>{f.name}</div>
                            <div className="hint">{fmtSize(f.size)}</div>
                          </div>
                          <button className="act-btn" type="button" onClick={() => downloadFile(f.url, f.name)}>
                            Download
                          </button>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        </div>
        <div className="group">
          <label className="group-label">Downloads</label>
          {activeTasks.length === 0 && doneTasks.length === 0 && <p className="note">No downloads yet.</p>}
          {activeTasks.map((t) => {
            const pct = t.total ? Math.min(100, Math.round((t.downloaded / t.total) * 100)) : 0;
            return (
              <div key={t.id} style={{ border: "1px solid var(--border)", borderRadius: 10, padding: 10, marginBottom: 8 }}>
                <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                  <span style={{ fontWeight: 600 }}>{t.target_name}</span>
                  <span className="hint" style={{ marginLeft: "auto" }}>{t.status}</span>
                  <button className="act-btn danger" type="button" onClick={() => { llmCancelDownload(t.id).catch(() => {}); toast("Cancelling download…"); }}>
                    Cancel
                  </button>
                </div>
                <div className="progress-wrap" style={{ marginTop: 8 }}>
                  <div className="progress-bar" style={{ width: pct + "%" }} />
                </div>
                <div className="hint" style={{ marginTop: 4 }}>{fmtSize(t.downloaded)} / {fmtSize(t.total)}</div>
              </div>
            );
          })}
          {doneTasks.map((t) => (
            <div key={t.id} style={{ border: "1px solid var(--border)", borderRadius: 10, padding: 10, marginBottom: 8 }}>
              <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                <span style={{ fontWeight: 600 }}>{t.target_name}</span>
                <span className="hint" style={{ marginLeft: "auto", color: t.status === "done" ? "var(--ok)" : "var(--err)" }}>
                  {t.status}{t.status === "error" && t.error ? ": " + t.error : ""}
                </span>
              </div>
            </div>
          ))}
        </div>
        <div className="conn">
          <span className={"dot " + backendState.dot} />
          <span>{backendState.label}</span>
        </div>
      </section>
    </main>
  );
}
