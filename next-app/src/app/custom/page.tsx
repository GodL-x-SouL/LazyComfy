"use client";

import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import {
  api,
  errMsg,
  fetchObjectInfo,
  fetchUserFiles,
  fetchUserFile,
  saveUserFile,
  deleteUserFile,
  fetchTemplates,
  fetchTemplate,
  fetchSystemStats,
  restartComfy,
  unloadUpscale,
  submitPrompt,
  fetchPromptHistory,
  interruptPrompt,
  uploadToComfy,
  loadSession,
  saveSession,
} from "@/lib/api";
import { useToast, getClientId, useComfyWs } from "@/lib/store";
import { Select, Switch } from "@/components/controls";
import {
  Graph,
  GraphNode,
  SubgraphDef,
  WidgetSlot,
  widgetSlots,
  subgraphWidgetSlots,
  resolveWidgets,
  namedValues,
  isImageLike,
  isGraphFormat,
  isApiFormat,
  buildPrompt,
  viewUrl,
  cleanFileName,
  fmtTimeAgo,
  CONTROL_MODES,
  NOTE_TYPES,
} from "@/lib/custom-graph";

/* ---------- session / local types ---------- */

interface Source {
  type: "user" | "template" | "device" | "paste";
  path?: string;
  module?: string;
  name?: string;
}

interface GalleryItem {
  at: number;
  prompt_id: string;
  wf: string;
  kind: "image" | "video";
  file: { filename: string; subfolder?: string; type?: string };
  nodeId: string;
}

interface RecentEntry {
  name: string;
  source: Source;
  path?: string;
  at: number;
}

type SideView = "menu" | "recent" | "myworkflows" | "templates" | "paste" | "device" | "saveas" | "server" | null;

const loadRecent = (): RecentEntry[] => {
  try {
    return JSON.parse(localStorage.getItem("lazycomfy.custom.recent") || "[]");
  } catch {
    return [];
  }
};

/* ================= page ================= */

export default function CustomPage() {
  const toast = useToast();
  const [objectInfo, setObjectInfo] = useState<Record<string, any> | null>(null);
  const objectInfoAt = useRef(0);
  const [wf, setWf] = useState<Graph | null>(null);
  const [wfApi, setWfApi] = useState<Record<string, any> | null>(null);
  const [wfName, setWfName] = useState("");
  const [source, setSource] = useState<Source | null>(null);
  const [pristine, setPristine] = useState("");
  const pristineRef = useRef("");
  const setPristineBoth = (v: string) => {
    pristineRef.current = v;
    setPristine(v);
  };
  const [dirty, setDirty] = useState(false);
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});
  const [bypassed, setBypassed] = useState<Set<string>>(new Set());
  const [search, setSearch] = useState("");
  const [nodeErrors, setNodeErrors] = useState<Record<string, { message: string }[]>>({});
  const [gallery, setGallery] = useState<GalleryItem[]>([]);
  const [recent, setRecent] = useState<RecentEntry[]>(loadRecent);
  const [jobState, setJobState] = useState("Idle");
  const [progress, setProgress] = useState<number | null>(null);
  const [side, setSide] = useState<SideView>(null);
  const [errToast, setErrToast] = useState<{ title: string; msg: string; nodes: string[] } | null>(null);
  const jobRef = useRef<{ prompt_id: string; started: number } | null>(null);
  const finishedIds = useRef<Record<string, boolean>>({});
  const finishing = useRef<Set<string>>(new Set());
  const booted = useRef(false);
  const saveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const refs = useRef({ wf, wfApi, bypassed, collapsed, wfName, source });
  refs.current = { wf, wfApi, bypassed, collapsed, wfName, source };

  /* ---------- session ---------- */

  const snapState = useCallback((): string => {
    const r = refs.current;
    if (r.wfApi) return JSON.stringify({ a: r.wfApi });
    if (!r.wf) return "";
    return JSON.stringify({
      w: r.wf.nodes.map((n) => [n.widgets_values, n.widgets_values_named]),
      b: [...r.bypassed].sort(),
    });
  }, []);

  const persist = useCallback(() => {
    if (!booted.current) return;
    if (saveTimer.current) clearTimeout(saveTimer.current);
    saveTimer.current = setTimeout(() => {
      saveTimer.current = null;
      const r = refs.current;
      const value: any = { name: r.wfName, source: r.source, bypassed: [...r.bypassed], collapsed: Object.keys(r.collapsed).filter((k) => r.collapsed[k]) };
      if (r.wfApi) value.api = r.wfApi;
      else if (r.wf) {
        const edits: Record<string, any> = {};
        for (const n of r.wf.nodes) edits[String(n.id)] = { w: n.widgets_values, n: n.widgets_values_named };
        value.edits = edits;
      }
      saveSession("custom", value);
    }, 400);
  }, []);

  const markDirty = useCallback(() => {
    setDirty(snapState() !== pristineRef.current);
  }, [snapState]);

  useEffect(() => {
    const onUnload = () => {
      const r = refs.current;
      saveSession("custom", { name: r.wfName, source: r.source });
    };
    window.addEventListener("beforeunload", onUnload);
    return () => window.removeEventListener("beforeunload", onUnload);
  }, []);

  /* ---------- object_info ---------- */

  const getObjectInfo = useCallback(
    async (force = false): Promise<Record<string, any>> => {
      if (!force && objectInfo && Date.now() - objectInfoAt.current < 60000) return objectInfo;
      const info = await fetchObjectInfo();
      setObjectInfo(info);
      objectInfoAt.current = Date.now();
      return info;
    },
    [objectInfo],
  );

  /* ---------- validation ---------- */

  const revalidate = useCallback(
    (graph: Graph | null, info: Record<string, any> | null) => {
      const errs: Record<string, { message: string }[]> = {};
      if (graph && info) {
        const subgraphIds = new Set((graph.definitions?.subgraphs || []).map((s) => s.id));
        for (const n of graph.nodes) {
          if (NOTE_TYPES.has(n.type)) continue;
          if (subgraphIds.has(n.type)) continue;
          if (!info[n.type]) {
            errs[String(n.id)] = [{ message: `Unknown node type on backend: ${n.type}` }];
          }
        }
      }
      setNodeErrors(errs);
      return errs;
    },
    [],
  );

  /* ---------- workflow loading ---------- */

  const pushRecent = useCallback((name: string, src: Source, path?: string) => {
    setRecent((prev) => {
      const next = [{ name, source: src, path, at: Date.now() }, ...prev.filter((r) => !(r.name === name && r.path === path))].slice(0, 20);
      try {
        localStorage.setItem("lazycomfy.custom.recent", JSON.stringify(next));
      } catch {
        /* ignore */
      }
      return next;
    });
  }, []);

  const setWorkflow = useCallback(
    async (obj: any, name: string, src: Source) => {
      if (isGraphFormat(obj)) {
        const g: Graph = JSON.parse(JSON.stringify(obj));
        const byp = new Set<string>();
        for (const n of g.nodes) if (n.mode === 4) byp.add(String(n.id));
        setWf(g);
        setWfApi(null);
        setBypassed(byp);
        setCollapsed({});
        setWfName(name);
        setSource(src);
        setNodeErrors({});
        const snap = JSON.stringify({ w: g.nodes.map((n) => [n.widgets_values, n.widgets_values_named]), b: [...byp].sort() });
        setPristineBoth(snap);
        setDirty(false);
        pushRecent(name, src, src.path);
        persist();
        const info = await getObjectInfo().catch(() => null);
        if (info) revalidate(g, info);
        toast("Workflow loaded.", "ok");
      } else if (isApiFormat(obj)) {
        const a = JSON.parse(JSON.stringify(obj));
        setWf(null);
        setWfApi(a);
        setBypassed(new Set());
        setCollapsed({});
        setWfName(name);
        setSource(src);
        setNodeErrors({});
        setPristineBoth(JSON.stringify({ a }));
        setDirty(false);
        pushRecent(name, src, src.path);
        persist();
        toast("API-format workflow loaded (run only).", "ok");
      } else {
        toast("Unrecognized workflow format.", "error");
      }
      setSide(null);
    },
    [getObjectInfo, persist, pushRecent, revalidate, toast],
  );

  const loadUserFile = useCallback(
    async (rel: string) => {
      const obj = await fetchUserFile(rel);
      const name = rel.split("/").pop() || rel;
      await setWorkflow(obj, name, { type: "user", path: rel });
    },
    [setWorkflow],
  );

  /* ---------- boot ---------- */

  useEffect(() => {
    let cancelled = false;
    (async () => {
      getObjectInfo().catch(() => {});
      const saved = (await loadSession()).custom;
      if (!cancelled && saved?.source?.type === "user" && saved?.source?.path) {
        try {
          const obj = await fetchUserFile(saved.source.path);
          if (cancelled) return;
          if (isGraphFormat(obj) || isApiFormat(obj)) {
            await setWorkflow(obj, saved.name || saved.source.path.split("/").pop(), saved.source);
            // re-apply edits
            if (saved.edits && isGraphFormat(obj)) {
              setWf((prev) => {
                if (!prev) return prev;
                const next: Graph = JSON.parse(JSON.stringify(prev));
                for (const n of next.nodes) {
                  const e = saved.edits[String(n.id)];
                  if (!e) continue;
                  if (Array.isArray(e.w)) n.widgets_values = e.w;
                  if (e.n && typeof e.n === "object") n.widgets_values_named = e.n;
                }
                return next;
              });
            }
            if (saved.api && isApiFormat(obj)) setWfApi(saved.api);
            if (Array.isArray(saved.bypassed)) setBypassed(new Set(saved.bypassed.map(String)));
            if (Array.isArray(saved.collapsed)) {
              const c: Record<string, boolean> = {};
              for (const k of saved.collapsed) c[String(k)] = true;
              setCollapsed(c);
            }
          }
        } catch (e) {
          toast("Could not restore saved workflow: " + errMsg(e), "error");
        }
      }
      if (!cancelled) booted.current = true;
    })();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  /* ---------- ws + polling ---------- */

  useComfyWs((msg) => {
    const job = jobRef.current;
    const d = (msg as any).data || {};
    if (!job) return;
    if (d.prompt_id && d.prompt_id !== job.prompt_id) return;
    if (msg.type === "progress" && d.max) {
      setProgress(Math.min(100, (d.value / d.max) * 100));
      setJobState(`Sampling ${Math.min(d.value, d.max)} / ${d.max}`);
    } else if (msg.type === "executing") {
      if (d.node) setJobState(`Node ${d.node}…`);
      else void pollHistory();
    } else if (msg.type === "executed" || msg.type === "execution_success") {
      void pollHistory();
    } else if (msg.type === "execution_error") {
      jobRef.current = null;
      setProgress(null);
      setJobState("Error");
      toast(d.exception_message || d.exception_type || "Run failed.", "error");
    } else if (msg.type === "execution_interrupted") {
      jobRef.current = null;
      setProgress(null);
      setJobState("Cancelled");
      toast("Run cancelled.", "");
    }
  });

  const pollHistory = useCallback(async () => {
    const job = jobRef.current;
    if (!job || finishedIds.current[job.prompt_id] || finishing.current.has(job.prompt_id)) return;
    finishing.current.add(job.prompt_id);
    let entry: any;
    try {
      const h = await fetchPromptHistory(job.prompt_id);
      entry = h?.[job.prompt_id];
    } catch {
      finishing.current.delete(job.prompt_id);
      return;
    }
    if (!entry?.status?.completed) {
      finishing.current.delete(job.prompt_id);
      return;
    }
    finishedIds.current[job.prompt_id] = true;
    jobRef.current = null;
    setProgress(null);
    const ok = entry.status.status_str === "success";
    if (ok) {
      setJobState("Done");
      const outs: GalleryItem[] = [];
      for (const [nid, nodeOut] of Object.entries<any>(entry.outputs || {})) {
        for (const kind of ["images", "gifs", "videos"] as const) {
          for (const f of (nodeOut as any)?.[kind] || []) {
            if (!f?.filename) continue;
            outs.push({
              at: Date.now(),
              prompt_id: job.prompt_id,
              wf: refs.current.wfName,
              kind: kind === "images" ? "image" : "video",
              file: { filename: f.filename, subfolder: f.subfolder || "", type: f.type || "output" },
              nodeId: nid,
            });
          }
        }
      }
      setGallery((prev) => [...outs.reverse(), ...prev].slice(0, 60));
      toast("Run finished.", "ok");
    } else {
      setJobState("Error");
      setErrToast({ title: "Run failed", msg: entry.status?.status_str || "error", nodes: [] });
    }
    setTimeout(() => {
      if (saveTimer.current) clearTimeout(saveTimer.current);
      persist();
    }, 0);
  }, [persist, toast]);

  useEffect(() => {
    const t = setInterval(() => {
      if (jobRef.current) void pollHistory();
    }, 2000);
    return () => clearInterval(t);
  }, [pollHistory]);

  /* ---------- run ---------- */

  const onRun = async () => {
    const r = refs.current;
    let promptObj: Record<string, any>;
    try {
      const info = await getObjectInfo();
      if (r.wfApi) {
        promptObj = r.wfApi;
      } else if (r.wf) {
        const { prompt, errors } = buildPrompt(r.wf, r.bypassed, info);
        if (errors.length) {
          const map: Record<string, { message: string }[]> = {};
          for (const e of errors) {
            const k = String(e.nodeId);
            map[k] = [...(map[k] || []), { message: e.message }];
          }
          setNodeErrors(map);
          setErrToast({ title: "Cannot queue", msg: errors.map((e) => `node ${e.nodeId}: ${e.message}`).join("\n"), nodes: errors.map((e) => String(e.nodeId)) });
          return;
        }
        promptObj = prompt;
      } else {
        toast("Load a workflow first.", "error");
        return;
      }
    } catch (e) {
      toast(errMsg(e), "error");
      return;
    }
    setJobState("Queueing " + (r.wfName || "workflow") + "…");
    setProgress(0);
    try {
      const res = await submitPrompt(
        promptObj,
        getClientId(),
        {
          extra_pnginfo: r.wf ? { workflow: r.wf } : undefined,
          custom_workflow: { name: r.wfName, source: r.source?.type },
        },
      );
      jobRef.current = { prompt_id: res.prompt_id, started: Date.now() };
      setJobState("Running… (tap Cancel to stop)");
    } catch (e: any) {
      const data = e?.data;
      const map: Record<string, { message: string }[]> = {};
      const msgs: string[] = [];
      if (data?.node_errors) {
        for (const [nid, ne] of Object.entries<any>(data.node_errors)) {
          for (const er of ne?.errors || []) {
            map[nid] = [...(map[nid] || []), { message: er.message || er.type || "error" }];
            msgs.push(`node ${nid}: ${er.message || er.type}`);
          }
        }
      }
      setNodeErrors(map);
      const msg = typeof data?.error === "string" ? data.error : data?.error?.message || errMsg(e);
      setErrToast({ title: "Cannot queue", msg: msgs.join("\n") || msg, nodes: Object.keys(map) });
      setJobState("Error");
    }
  };

  const onCancel = async () => {
    setJobState("Cancelling…");
    try {
      await interruptPrompt();
    } catch {
      /* ignore */
    }
  };

  /* ---------- edits ---------- */

  const updateNode = (id: string | number, fn: (n: GraphNode) => void) => {
    setWf((prev) => {
      if (!prev) return prev;
      const next: Graph = { ...prev, nodes: prev.nodes.map((n) => (String(n.id) === String(id) ? { ...n } : n)) };
      const target = next.nodes.find((n) => String(n.id) === String(id));
      if (target) fn(target);
      return next;
    });
    setTimeout(() => {
      setDirty(snapState() !== pristineRef.current);
      persist();
      const g = refs.current.wf;
      if (g && objectInfo) revalidate(g, objectInfo);
    }, 0);
  };

  const toggleBypass = (id: string | number) => {
    setBypassed((prev) => {
      const next = new Set(prev);
      const k = String(id);
      if (next.has(k)) next.delete(k);
      else next.add(k);
      return next;
    });
    setTimeout(() => {
      setDirty(true);
      persist();
    }, 0);
  };

  /* ---------- save / discard / reload / unload ---------- */

  const doSave = async () => {
    const r = refs.current;
    if (r.source?.type !== "user" || !r.source.path) {
      toast("Only user workflows can be overwritten — use Save As.", "error");
      return;
    }
    try {
      await saveUserFile(r.source.path, r.wf || r.wfApi, true);
      setPristineBoth(snapState());
      setDirty(false);
      toast("Saved.", "ok");
    } catch (e) {
      toast(errMsg(e), "error");
    }
  };

  const doDiscard = () => {
    try {
      const snap = JSON.parse(pristineRef.current || "null");
      if (snap?.w && refs.current.wf) {
        const pairs: any[] = snap.w;
        setWf((prev) => {
          if (!prev) return prev;
          const next: Graph = { ...prev, nodes: prev.nodes.map((n) => ({ ...n })) };
          next.nodes.forEach((n, i) => {
            if (i < pairs.length) {
              n.widgets_values = pairs[i][0];
              n.widgets_values_named = pairs[i][1];
            }
          });
          return next;
        });
      }
      if (snap?.b) setBypassed(new Set((snap.b as string[]).map(String)));
      setDirty(false);
      persist();
      toast("Changes discarded.", "ok");
    } catch {
      toast("Nothing to discard.", "error");
    }
  };

  const doReload = async () => {
    const r = refs.current;
    if (r.source?.type === "user" && r.source.path) {
      try {
        await loadUserFile(r.source.path);
      } catch (e) {
        toast(errMsg(e), "error");
      }
    } else if (r.source?.type === "template" && r.source.module && r.source.name) {
      try {
        const obj = await fetchTemplate(r.source.module, r.source.name);
        await setWorkflow(obj, r.wfName, r.source);
      } catch (e) {
        toast(errMsg(e), "error");
      }
    } else {
      toast("Nothing to reload from (local copy).", "");
    }
  };

  const doUnload = () => {
    setWf(null);
    setWfApi(null);
    setWfName("");
    setSource(null);
    setNodeErrors({});
    setDirty(false);
    setJobState("Idle");
    setProgress(null);
    persist();
  };

  const nodeCount = wf ? wf.nodes.filter((n) => !NOTE_TYPES.has(n.type)).length : wfApi ? Object.keys(wfApi).length : 0;
  const visibleNodes = (wf?.nodes || []).filter(
    (n) => !search.trim() || (n.title || n.type || "").toLowerCase().includes(search.trim().toLowerCase()) || String(n.id) === search.trim(),
  );

  return (
    <main className="layout">
      <section className="panel">
        <div className="group">
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <button className="act-btn" type="button" onClick={() => setSide("menu")}>
              ☰ Menu
            </button>
            <span className="badge" title={wfName}>{wfName ? `${dirty ? "● " : ""}${wfName} · ${nodeCount} nodes` : "no workflow"}</span>
          </div>
        </div>
        {!wf && !wfApi && (
          <div className="placeholder" style={{ border: "1px dashed var(--border)", borderRadius: 12 }}>
            <p>No workflow loaded.</p>
            <button className="act-btn" type="button" onClick={() => setSide("menu")}>
              Open menu
            </button>
          </div>
        )}
        {(wf || wfApi) && (
          <>
            <div className="field">
              <input type="search" placeholder="Search nodes…" value={search} onChange={(e) => setSearch(e.target.value)} />
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
              {wfApi && <ApiCard count={Object.keys(wfApi).length} api={wfApi} />}
              {visibleNodes.map((n) => (
                <NodeCard
                  key={String(n.id)}
                  node={n}
                  objectInfo={objectInfo}
                  subgraph={(wf?.definitions?.subgraphs || []).find((s) => s.id === n.type)}
                  collapsed={!!collapsed[String(n.id)]}
                  bypassed={bypassed.has(String(n.id))}
                  errors={nodeErrors[String(n.id)] || []}
                  onCollapse={() => {
                    setCollapsed((p) => ({ ...p, [String(n.id)]: !p[String(n.id)] }));
                    persist();
                  }}
                  onBypass={() => toggleBypass(n.id)}
                  onEdit={(fn) => updateNode(n.id, fn)}
                  toast={toast}
                />
              ))}
              {wf && !visibleNodes.length && <p className="note">No matches — try a different search.</p>}
            </div>
          </>
        )}
      </section>

      <section className="panel">
        <div className="group">
          <div className="group-head">
            <label className="group-label">Run</label>
            <span className="job-state">{jobState}</span>
          </div>
          {progress !== null && (
            <div className="progress-wrap">
              <div className="progress-bar" style={{ width: progress + "%" }} />
            </div>
          )}
          {(wf || wfApi) && (
            <div style={{ display: "flex", gap: 8, marginTop: 10 }}>
              <button className="btn btn-primary" type="button" disabled={!!jobRef.current} onClick={onRun} style={{ flex: 1 }}>
                {jobRef.current ? "Running… (tap Cancel to stop)" : "Run workflow"}
              </button>
              {jobRef.current && (
                <button className="btn btn-danger" type="button" onClick={onCancel}>
                  Cancel
                </button>
              )}
            </div>
          )}
          {(wf || wfApi) && (
            <div className="row-actions">
              <button className="act-btn" type="button" disabled={!(source?.type === "user" && dirty)} onClick={doSave}>
                Save{dirty ? " ●" : ""}
              </button>
              <button className="act-btn" type="button" onClick={() => setSide("saveas")}>
                Save as…
              </button>
              <button className="act-btn" type="button" onClick={doDiscard} disabled={!dirty}>
                Discard
              </button>
              <button className="act-btn" type="button" onClick={doReload}>
                Reload
              </button>
              <button className="act-btn" type="button" onClick={() => getObjectInfo(true).then((i) => { if (wf) revalidate(wf, i); toast("Model data refreshed.", "ok"); }).catch((e) => toast(errMsg(e), "error"))}>
                Refresh data
              </button>
              <button className="act-btn danger" type="button" onClick={doUnload}>
                Unload
              </button>
            </div>
          )}
        </div>
        <div className="group">
          <label className="group-label">Outputs {gallery.length > 0 && `(${gallery.length})`}</label>
          {gallery.length === 0 && <p className="note">Nothing yet — queue a workflow to see results here.</p>}
          <div className="gallery">
            {gallery.map((g, i) => (
              <div key={g.prompt_id + g.nodeId + i} className="g-item" style={{ cursor: "default" }}>
                {g.kind === "video" ? (
                  // eslint-disable-next-line jsx-a11y/media-has-caption
                  <video src={viewUrl(g.file)} muted playsInline preload="metadata" />
                ) : (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img loading="lazy" src={viewUrl(g.file, "webp;90")} alt="" />
                )}
                <span className="g-badge">{g.wf} · node {g.nodeId}</span>
              </div>
            ))}
          </div>
        </div>
      </section>

      {side && (
        <SideDrawer
          view={side}
          onClose={() => setSide(null)}
          onGo={(v) => setSide(v)}
          recent={recent}
          wfName={wfName}
          dirty={dirty}
          hasWf={!!(wf || wfApi)}
          source={source}
          toast={toast}
          onLoadRecent={(r) => {
            (async () => {
              try {
                if (r.source.type === "user" && r.path) await loadUserFile(r.path);
                else if (r.source.type === "template" && r.source.module && r.source.name) {
                  const obj = await fetchTemplate(r.source.module, r.source.name);
                  await setWorkflow(obj, r.name, r.source);
                } else toast("Local copies cannot be reloaded — load from disk again.", "error");
              } catch (e) {
                toast(errMsg(e), "error");
              }
            })();
          }}
          onLoadUserFile={loadUserFile}
          onLoadTemplate={(mod, name, obj) => setWorkflow(obj, name, { type: "template", module: mod, name })}
          onLoadObj={(obj, name, src) => setWorkflow(obj, name, src)}
          onSaveAs={(name) => {
            (async () => {
              const r = refs.current;
              try {
                await saveUserFile(name, r.wf || r.wfApi, false);
                setSource({ type: "user", path: name });
                setWfName(name.replace(/\.json$/i, ""));
                setPristineBoth(snapState());
                setDirty(false);
                setSide(null);
                toast("Saved.", "ok");
              } catch (e) {
                toast(errMsg(e), "error");
              }
            })();
          }}
        />
      )}

      {errToast && (
        <div style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,.4)", zIndex: 95, display: "flex", alignItems: "center", justifyContent: "center", padding: 16 }} onClick={() => setErrToast(null)}>
          <div className="panel" role="alert" style={{ maxWidth: 520, width: "100%" }} onClick={(e) => e.stopPropagation()}>
            <h3 style={{ margin: "0 0 8px" }}>{errToast.title}</h3>
            <pre className="logbox" style={{ maxHeight: 200 }}>{errToast.msg}</pre>
            {errToast.nodes.length > 0 && (
              <div style={{ display: "flex", gap: 6, flexWrap: "wrap", marginTop: 8 }}>
                {errToast.nodes.map((n) => (
                  <button key={n} className="act-btn" type="button" onClick={() => {
                    document.getElementById("node-" + n)?.scrollIntoView({ block: "center", behavior: "smooth" });
                    setErrToast(null);
                  }}>
                    node {n}
                  </button>
                ))}
              </div>
            )}
            <div className="row-actions">
              <button className="act-btn" type="button" onClick={() => {
                try {
                  navigator.clipboard.writeText(errToast.title + "\n" + errToast.msg);
                  toast("Copied.", "ok");
                } catch {
                  toast("Clipboard unavailable.", "error");
                }
              }}>
                Copy
              </button>
              <button className="act-btn" type="button" onClick={() => setErrToast(null)}>
                Dismiss
              </button>
            </div>
          </div>
        </div>
      )}
    </main>
  );
}

/* ================= node card ================= */

function NodeCard(props: {
  node: GraphNode;
  objectInfo: Record<string, any> | null;
  subgraph?: SubgraphDef;
  collapsed: boolean;
  bypassed: boolean;
  errors: { message: string }[];
  onCollapse: () => void;
  onBypass: () => void;
  onEdit: (fn: (n: GraphNode) => void) => void;
  toast: (t: string, k?: string) => void;
}) {
  const { node, objectInfo, subgraph, collapsed, bypassed, errors, onCollapse, onBypass, onEdit, toast } = props;
  const nid = String(node.id);
  if (NOTE_TYPES.has(node.type)) {
    const text = Array.isArray(node.widgets_values) ? String(node.widgets_values[0] || "") : "";
    return (
      <div className="panel" style={{ padding: 10 }} id={"node-" + nid}>
        <div style={{ fontWeight: 600, marginBottom: 4 }}>📝 {node.title || "Note"}</div>
        <div className="note" style={{ whiteSpace: "pre-wrap", overflowWrap: "anywhere" }}>{text.slice(0, 2000)}</div>
      </div>
    );
  }
  const classDef = objectInfo?.[node.type];
  const slots = subgraph
    ? subgraphWidgetSlots(subgraph, objectInfo || {})
    : classDef
      ? widgetSlots(classDef)
      : [];
  const links = new Map((node.inputs || []).filter((i) => i.link != null).map((i) => [i.name, i.link] as const));
  const { items, control, controlIndex } = resolveWidgets(node, slots);
  const raw = Array.isArray(node.widgets_values) ? (node.widgets_values as any[]) : [];
  const named = !Array.isArray(node.widgets_values) ? namedValues(node, slots) : null;
  const widgetNames = new Set(items.map((it) => it.slot.name));

  const setPositional = (index: number, value: any) => {
    onEdit((n) => {
      const arr = Array.isArray(n.widgets_values) ? [...(n.widgets_values as any[])] : [];
      while (arr.length <= index) arr.push(undefined);
      arr[index] = value;
      n.widgets_values = arr;
    });
  };

  const setDynamic = (index: number, slot: WidgetSlot, value: string) => {
    onEdit((n) => {
      const arr = Array.isArray(n.widgets_values) ? [...(n.widgets_values as any[])] : [];
      const at = index >= 0 ? index : arr.length;
      while (arr.length <= at) arr.push(undefined);
      const oldKey = String(arr[at] ?? "");
      const oldCount = slot.sub?.find((s) => s.key === oldKey)?.slots.length ?? 0;
      const next = slot.sub?.find((s) => s.key === value)?.slots ?? [];
      const defaults = next.map((s) => s.defaultValue ?? (s.kind === "boolean" ? false : s.kind === "combo" ? s.options?.[0] ?? "" : 0));
      arr.splice(at + 1, oldCount, ...defaults);
      arr[at] = value;
      n.widgets_values = arr;
    });
  };

  const setControl = (value: string) => {
    onEdit((n) => {
      const arr = Array.isArray(n.widgets_values) ? [...(n.widgets_values as any[])] : [];
      if (controlIndex >= 0 && controlIndex < arr.length) {
        arr[controlIndex] = value;
      } else {
        const seedIndex = items.find((it) => it.slot.control || it.slot.name === "seed" || it.slot.name === "noise_seed")?.index ?? -1;
        arr.splice((seedIndex >= 0 ? seedIndex : arr.length - 1) + 1, 0, value);
      }
      n.widgets_values = arr;
    });
  };

  const uploadFor = async (index: number, file?: File | null) => {
    if (!file) return;
    try {
      const r = await uploadToComfy(file);
      const v = (r.subfolder ? r.subfolder + "/" : "") + r.name;
      setPositional(index, v);
      toast("Uploaded " + r.name, "ok");
    } catch (e) {
      toast(errMsg(e), "error");
    }
  };

  return (
    <div className="panel" style={{ padding: 10, opacity: bypassed ? 0.55 : 1 }} id={"node-" + nid}>
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <button className="act-btn" type="button" onClick={onCollapse} aria-label="collapse">
          {collapsed ? "▶" : "▼"}
        </button>
        <span style={{ fontWeight: 650 }}>{node.title || subgraph?.name || node.type}</span>
        <span className="hint">#{nid}</span>
        {subgraph && <span className="badge">Subgraph</span>}
        {errors.length > 0 && <span className="badge" style={{ color: "var(--err)" }}>● {errors.length}</span>}
        {!classDef && !subgraph && objectInfo && <span className="badge">Backend Issue</span>}
        <button
          className="act-btn"
          type="button"
          onClick={onBypass}
          style={{ marginLeft: "auto", borderColor: bypassed ? "var(--warn)" : undefined }}
        >
          {bypassed ? "Bypass ON" : "Bypass"}
        </button>
      </div>
      {errors.length > 0 && (
        <div className="err-line">{errors.map((e) => e.message).join("; ")}</div>
      )}
      {!collapsed && (
        <div style={{ marginTop: 8, display: "flex", flexDirection: "column", gap: 8 }}>
          {items.map(({ slot, index, parent }) => {
            const link = links.get(slot.name);
            const isLinked = link != null;
            const cur = index >= 0 ? raw[index] : named?.[slot.name];
            const label = slot.label || slot.name;
            let field: ReactNode;
            if (slot.kind === "combo") {
              const missing = cur != null && !(slot.options || []).includes(String(cur));
              field = (
                <Select
                  disabled={isLinked}
                  value={cur == null ? "" : String(cur)}
                  options={[
                    ...(missing ? [{ value: String(cur), label: `⚠ ${String(cur)} (missing)` }] : []),
                    ...((slot.options || []).map((o) => ({ value: o, label: o }))),
                  ]}
                  onChange={(v) => {
                    if (slot.sub) setDynamic(index, slot, v);
                    else if (index >= 0) setPositional(index, v);
                    else onEdit((n) => {
                      const rec = { ...((n.widgets_values_named || {}) as object) } as Record<string, any>;
                      rec[slot.name] = v;
                      n.widgets_values_named = rec;
                    });
                  }}
                />
              );
            } else if (slot.kind === "boolean") {
              field = (
                <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                  <Switch
                    checked={!!cur}
                    disabled={isLinked}
                    label={label}
                    onChange={(v) => {
                      if (index >= 0) setPositional(index, v);
                    }}
                  />
                  <span style={{ fontSize: 13, fontWeight: 600 }}>{label}</span>
                </div>
              );
            } else if (slot.kind === "number") {
              const isSeed = slot.control || slot.name === "seed" || slot.name === "noise_seed";
              field = (
                <div style={{ display: "flex", gap: 6 }}>
                  <input
                    type="number"
                    disabled={isLinked}
                    step={slot.step ?? 1}
                    min={slot.min}
                    max={slot.max}
                    value={cur ?? ""}
                    style={{ flex: 1 }}
                    onChange={(e) => {
                      const v = e.target.value === "" ? 0 : Number(e.target.value);
                      if (index >= 0) setPositional(index, slot.intOnly ? Math.round(v) : v);
                    }}
                  />
                  {isSeed && index >= 0 && (
                    <div style={{ width: 150, flex: "none" }}>
                      <Select
                        disabled={isLinked}
                        value={control}
                        options={CONTROL_MODES.map((m) => ({ value: m, label: m }))}
                        onChange={setControl}
                      />
                    </div>
                  )}
                </div>
              );
            } else {
              const str = cur == null ? "" : String(cur);
              if (isImageLike(slot.name, cur)) {
                field = (
                  <div style={{ display: "flex", gap: 6 }}>
                    <input
                      value={str}
                      disabled={isLinked}
                      placeholder="filename"
                      spellCheck={false}
                      style={{ flex: 1 }}
                      onChange={(e) => {
                        if (index >= 0) setPositional(index, e.target.value);
                      }}
                    />
                    {!isLinked && (
                      <label className="act-btn" style={{ cursor: "pointer" }}>
                        ⇪
                        <input
                          type="file"
                          accept="image/*,video/*"
                          hidden
                          onChange={(e) => {
                            uploadFor(index, e.target.files?.[0]);
                            e.target.value = "";
                          }}
                        />
                      </label>
                    )}
                  </div>
                );
              } else if (slot.multiline || str.length > 60 || str.includes("\n")) {
                field = (
                  <textarea
                    rows={3}
                    value={str}
                    disabled={isLinked}
                    onChange={(e) => {
                      if (index >= 0) setPositional(index, e.target.value);
                    }}
                  />
                );
              } else {
                field = (
                  <input
                    value={str}
                    disabled={isLinked}
                    autoComplete="off"
                    spellCheck={false}
                    onChange={(e) => {
                      if (index >= 0) setPositional(index, e.target.value);
                    }}
                  />
                );
              }
            }
            return (
              <div className="field" key={(parent ? parent + "." : "") + slot.name} style={{ marginBottom: 0 }}>
                {slot.kind !== "boolean" && <label>{label}</label>}
                {field}
                {isLinked && <div className="hint">← link #{link}</div>}
              </div>
            );
          })}
          {(node.inputs || [])
            .filter((i) => i.link != null && !widgetNames.has(i.name))
            .map((i) => (
              <div className="hint" key={i.name}>
                {i.name} ← link #{i.link}
              </div>
            ))}
        </div>
      )}
    </div>
  );
}

function ApiCard({ count, api }: { count: number; api: Record<string, any> }) {
  const rows = Object.entries(api).slice(0, 60);
  return (
    <div className="panel" style={{ padding: 10 }}>
      <div style={{ fontWeight: 650 }}>API-format prompt · {count} ops</div>
      <p className="note">Loaded as a raw prompt dict — editing is disabled, run only.</p>
      <div style={{ marginTop: 6 }}>
        {rows.map(([id, n]: [string, any]) => (
          <div className="hint" key={id}>
            <b>{id}</b> {n?.class_type}
          </div>
        ))}
      </div>
    </div>
  );
}

/* ================= side drawer ================= */

function SideDrawer(props: {
  view: Exclude<SideView, null>;
  onClose: () => void;
  onGo: (v: Exclude<SideView, null>) => void;
  recent: RecentEntry[];
  wfName: string;
  dirty: boolean;
  hasWf: boolean;
  source: Source | null;
  toast: (t: string, k?: string) => void;
  onLoadRecent: (r: RecentEntry) => void;
  onLoadUserFile: (rel: string) => Promise<void>;
  onLoadTemplate: (mod: string, name: string, obj: any) => void;
  onLoadObj: (obj: any, name: string, src: Source) => void;
  onSaveAs: (name: string) => void;
}) {
  const { view, onClose, onGo, toast } = props;
  const [files, setFiles] = useState<any[]>([]);
  const [folder, setFolder] = useState("");
  const [query, setQuery] = useState("");
  const [sortDate, setSortDate] = useState(false);
  const [templates, setTemplates] = useState<Record<string, string[]>>({});
  const [paste, setPaste] = useState("");
  const [saveName, setSaveName] = useState("");
  const [deviceName, setDeviceName] = useState("");
  const [stats, setStats] = useState<any>(null);
  const [restartArmed, setRestartArmed] = useState(false);
  const [restarting, setRestarting] = useState(false);
  const [unloading, setUnloading] = useState<null | "all" | "vram">(null);
  const deviceRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (view === "myworkflows") {
      fetchUserFiles()
        .then((f) => setFiles(f || []))
        .catch((e) => toast(errMsg(e), "error"));
    }
    if (view === "templates") {
      api("/api/workflow_templates")
        .then((t) => setTemplates(t || {}))
        .catch((e) => toast(errMsg(e), "error"));
    }
    if (view === "saveas") setSaveName((props.wfName || "workflow").replace(/\.json$/i, ""));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [view]);

  useEffect(() => {
    if (view !== "server") return;
    let stop = false;
    let timer: ReturnType<typeof setInterval> | null = null;
    const load = async () => {
      try {
        const s = await fetchSystemStats();
        if (!stop) setStats(s);
      } catch {
        /* ignore */
      }
    };
    load();
    timer = setInterval(load, 3000);
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => {
      stop = true;
      if (timer) clearInterval(timer);
      window.removeEventListener("keydown", onKey);
    };
  }, [view, onClose]);

  useEffect(() => {
    if (!restartArmed) return;
    const t = setTimeout(() => setRestartArmed(false), 5000);
    return () => clearTimeout(t);
  }, [restartArmed]);

  const doUnloadModels = async (scope: "all" | "vram") => {
    setUnloading(scope);
    try {
      await unloadUpscale(scope);
      toast(scope === "vram" ? "VRAM models unloaded." : "All models unloaded.", "ok");
      fetchSystemStats().then(setStats).catch(() => {});
    } catch (e) {
      toast(errMsg(e), "error");
    } finally {
      setUnloading(null);
    }
  };

  const doRestart = async () => {
    if (!restartArmed) {
      setRestartArmed(true);
      return;
    }
    setRestartArmed(false);
    setRestarting(true);
    try {
      await restartComfy();
      const t0 = Date.now();
      while (Date.now() - t0 < 90000) {
        await new Promise((r) => setTimeout(r, 2000));
        try {
          await fetchSystemStats();
          toast("ComfyUI is back.", "ok");
          break;
        } catch {
          /* still down */
        }
      }
    } catch (e) {
      toast(errMsg(e), "error");
    } finally {
      setRestarting(false);
    }
  };

  const inFolder = files.filter((f) => {
    const rel = String(f.path || "").replace(/^workflows\//, "");
    const dir = rel.includes("/") ? rel.slice(0, rel.lastIndexOf("/")) : "";
    if (dir !== folder) return false;
    if (query && !rel.toLowerCase().includes(query.toLowerCase())) return false;
    return true;
  });
  const subfolders = [...new Set(files.map((f) => {
    const rel = String(f.path || "").replace(/^workflows\//, "");
    const dir = rel.includes("/") ? rel.slice(0, rel.lastIndexOf("/")) : "";
    return dir.startsWith(folder) ? dir.slice(folder.length).split("/").filter(Boolean)[0] : null;
  }).filter(Boolean))] as string[];
  inFolder.sort((a, b) => {
    if (sortDate) return (b.modified || 0) - (a.modified || 0);
    return String(a.name || a.path).localeCompare(String(b.name || b.path));
  });

  const title: Record<string, string> = {
    menu: "Menu",
    recent: "Recent",
    myworkflows: "My Workflows",
    templates: "Templates",
    paste: "Paste JSON",
    device: "From Device",
    saveas: "Save As",
    server: "Server",
  };

  return (
    <div style={{ position: "fixed", inset: 0, zIndex: 80 }}>
      <div style={{ position: "absolute", inset: 0, background: "rgba(0,0,0,.4)" }} onClick={onClose} />
      <div className="panel drawer" style={{ position: "absolute", top: 0, bottom: 0, left: 0, width: "min(380px, 92vw)", borderRadius: 0, overflowY: "auto" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 12 }}>
          {view === "menu" ? (
            <button className="icon-circle" type="button" aria-label="Close menu" onClick={onClose}>
              ✕
            </button>
          ) : (
            <button className="act-btn" type="button" onClick={() => onGo("menu")}>
              ← Back
            </button>
          )}
          <h3 style={{ margin: 0 }}>{title[view]}</h3>
        </div>

        {view === "menu" && (
          <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
            <div className="field">
              <label>Server</label>
              <button className="act-btn" type="button" onClick={() => onGo("server")}>Server stats & restart</button>
            </div>
            <div className="field">
              <label>Load workflow</label>
              <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
                <button className="act-btn" type="button" onClick={() => onGo("recent")}>Recent</button>
                <button className="act-btn" type="button" onClick={() => onGo("myworkflows")}>My Workflows</button>
                <button className="act-btn" type="button" onClick={() => onGo("templates")}>Templates</button>
                <button className="act-btn" type="button" onClick={() => onGo("paste")}>Paste JSON</button>
                <button className="act-btn" type="button" onClick={() => onGo("device")}>From Device</button>
              </div>
            </div>
            <div className="field">
              <label>Pages</label>
              <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
                <a className="act-btn" href="/lazycomfy">Images</a>
                <a className="act-btn" href="/lazycomfy/video">Video</a>
                <a className="act-btn" href="/lazycomfy/upscale">Upscaler</a>
                <a className="act-btn" href="/lazycomfy/forge">Prompt Forge</a>
              </div>
            </div>
          </div>
        )}

        {view === "recent" && (
          <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
            {props.recent.length === 0 && <p className="note">Nothing yet — loaded workflows appear here.</p>}
            {props.recent.map((r, i) => (
              <button key={i} className="act-btn" type="button" style={{ justifyContent: "space-between", minWidth: 0 }} onClick={() => props.onLoadRecent(r)}>
                <span style={{ overflow: "hidden", textOverflow: "ellipsis", minWidth: 0 }}>{r.name}</span>
                <span className="hint" style={{ flex: "none" }}>{fmtTimeAgo(r.at)}</span>
              </button>
            ))}
          </div>
        )}

        {view === "myworkflows" && (
          <>
            <div style={{ display: "flex", gap: 6, marginBottom: 8 }}>
              <input type="search" placeholder="Search…" value={query} onChange={(e) => setQuery(e.target.value)} style={{ flex: 1 }} />
              <button className="act-btn" type="button" onClick={() => setSortDate(!sortDate)}>
                {sortDate ? "⇅ date" : "⇅ name"}
              </button>
            </div>
            {folder && (
              <button className="act-btn" type="button" style={{ marginBottom: 8 }} onClick={() => setFolder(folder.split("/").slice(0, -1).join("/"))}>
                ← {folder}
              </button>
            )}
            {subfolders.map((s) => (
              <button key={s} className="act-btn" type="button" style={{ display: "flex", width: "100%", marginBottom: 4 }} onClick={() => setFolder(folder ? folder + "/" + s : s)}>
                📁 {s}
              </button>
            ))}
            {inFolder.filter((f) => String(f.name || "").endsWith(".json")).map((f) => {
              const rel = String(f.path || "").replace(/^workflows\//, "");
              return (
                <div key={rel} style={{ display: "flex", gap: 6, marginBottom: 4, minWidth: 0 }}>
                  <button className="act-btn" type="button" style={{ flex: 1, minWidth: 0, justifyContent: "flex-start", overflow: "hidden" }} onClick={() => props.onLoadUserFile(rel).catch((e) => toast(errMsg(e), "error"))}>
                    <span style={{ overflow: "hidden", textOverflow: "ellipsis" }}>→ {f.name || rel}</span>
                  </button>
                  <button
                    className="act-btn danger"
                    type="button"
                    style={{ flex: "none" }}
                    onClick={async () => {
                      if (!confirm("Delete " + rel + "?")) return;
                      try {
                        await deleteUserFile(rel);
                        setFiles((prev) => prev.filter((x) => x.path !== f.path));
                        toast("Deleted.", "ok");
                      } catch (e) {
                        toast(errMsg(e), "error");
                      }
                    }}
                  >
                    🗑
                  </button>
                </div>
              );
            })}
            {inFolder.length === 0 && subfolders.length === 0 && <p className="note">Empty folder.</p>}
          </>
        )}

        {view === "templates" && (
          <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
            {Object.entries(templates).map(([mod, names]) => (
              <div key={mod}>
                <label style={{ display: "block", fontSize: 11, fontWeight: 650, color: "var(--ink-3)", marginBottom: 4 }}>{mod}</label>
                <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
                  {names.map((n) => (
                    <button
                      key={n}
                      className="act-btn"
                      type="button"
                      style={{ justifyContent: "flex-start", minWidth: 0, overflow: "hidden" }}
                      onClick={() => fetchTemplate(mod, n).then((obj) => props.onLoadTemplate(mod, n, obj)).catch((e) => toast(errMsg(e), "error"))}
                    >
                      <span style={{ overflow: "hidden", textOverflow: "ellipsis" }}>→ {n}</span>
                    </button>
                  ))}
                </div>
              </div>
            ))}
          </div>
        )}

        {view === "paste" && (
          <>
            <textarea rows={10} placeholder={'{"nodes": …} or {"1": {"class_type": …}}'} value={paste} onChange={(e) => setPaste(e.target.value)} />
            <button
              className="btn btn-primary"
              type="button"
              style={{ marginTop: 8 }}
              onClick={() => {
                try {
                  const obj = JSON.parse(paste);
                  props.onLoadObj(obj, "pasted workflow", { type: "paste" });
                } catch (e) {
                  toast("Invalid JSON: " + errMsg(e), "error");
                }
              }}
            >
              Load workflow
            </button>
          </>
        )}

        {view === "device" && (
          <>
            <p className="note">Pick a .json workflow file</p>
            <div className="dz" role="button" tabIndex={0} onClick={() => deviceRef.current?.click()} onKeyDown={(e) => e.key === "Enter" && deviceRef.current?.click()}>
              {deviceName || "Choose file"}
            </div>
            <input
              ref={deviceRef}
              type="file"
              accept=".json,application/json"
              hidden
              onChange={async (e) => {
                const f = e.target.files?.[0];
                e.target.value = "";
                if (!f) return;
                setDeviceName(f.name);
                try {
                  const obj = JSON.parse(await f.text());
                  props.onLoadObj(obj, f.name, { type: "device" });
                } catch (err) {
                  toast("Invalid JSON: " + errMsg(err), "error");
                }
              }}
            />
          </>
        )}

        {view === "saveas" && (
          <>
            <div className="field">
              <label>Name</label>
              <input value={saveName} onChange={(e) => setSaveName(e.target.value)} />
            </div>
            <button className="btn btn-primary" type="button" onClick={() => props.onSaveAs(cleanFileName(saveName))}>
              Save to My Workflows
            </button>
          </>
        )}

        {view === "server" && (
          <>
            {!stats && <p className="note">Loading…</p>}
            {stats && (
              <>
                <div className="kv"><span>ComfyUI</span><span>{stats.system?.comfyui_version || "?"}</span></div>
                <div className="kv"><span>OS</span><span>{stats.system?.os || "?"}</span></div>
                <div className="kv">
                  <span>RAM used</span>
                  <span>
                    {stats.system?.ram_total
                      ? ((stats.system.ram_total - (stats.system.ram_free || 0)) / 1073741824).toFixed(1) + " / " + (stats.system.ram_total / 1073741824).toFixed(1) + " GB"
                      : "?"}
                  </span>
                </div>
                {(stats.devices || []).map((d: any, i: number) => (
                  <div className="kv" key={i}>
                    <span>{d.name || "GPU"} VRAM</span>
                    <span>
                      {d.vram_total
                        ? ((d.vram_total - (d.vram_free || 0)) / 1073741824).toFixed(1) + " / " + (d.vram_total / 1073741824).toFixed(1) + " GB"
                        : "n/a"}
                    </span>
                  </div>
                ))}
              </>
            )}
            <div style={{ display: "flex", gap: 6, marginTop: 10 }}>
              <button className="act-btn" type="button" style={{ flex: 1, justifyContent: "center" }} disabled={unloading !== null} onClick={() => doUnloadModels("all")}>
                {unloading === "all" ? "Unloading…" : "Unload all models"}
              </button>
              <button className="act-btn" type="button" style={{ flex: 1, justifyContent: "center" }} disabled={unloading !== null} onClick={() => doUnloadModels("vram")}>
                {unloading === "vram" ? "Unloading…" : "Unload VRAM only"}
              </button>
            </div>
            <button className="act-btn danger" type="button" style={{ marginTop: 6, width: "100%", justifyContent: "center" }} disabled={restarting} onClick={doRestart}>
              {restarting ? "Restarting ComfyUI…" : restartArmed ? "Tap again to confirm restart" : "Restart ComfyUI"}
            </button>
          </>
        )}
      </div>
    </div>
  );
}
