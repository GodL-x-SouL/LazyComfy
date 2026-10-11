/* Typed client for the LazyComfy Python backend (same origin, /lazycomfy/api/*). */

export class ApiError extends Error {
  status: number;
  data: unknown;
  constructor(message: string, status: number, data: unknown) {
    super(message);
    this.status = status;
    this.data = data;
  }
}

export async function api(path: string, opts?: RequestInit): Promise<any> {
  let res: Response;
  try {
    res = await fetch(path, opts);
  } catch (e: any) {
    throw new Error("Cannot reach ComfyUI (" + (e?.message || e) + ")");
  }
  let data: any = null;
  try {
    data = await res.json();
  } catch {
    /* non-JSON body */
  }
  if (!res.ok) {
    throw new ApiError(
      (data && data.error && data.error.message) || "HTTP " + res.status,
      res.status,
      data,
    );
  }
  if (data === null) throw new Error("Empty response from server (HTTP " + res.status + ")");
  return data;
}

export const errMsg = (e: unknown): string =>
  e instanceof Error ? e.message : String(e);

export const jsonPost = (path: string, body: unknown): Promise<any> =>
  api(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

/* ---------- shared shapes ---------- */

export interface MediaFile {
  filename: string;
  subfolder?: string;
  type?: string;
  url: string;
  thumb?: string | null;
}

export interface JobMeta {
  model_id?: string;
  mode?: string;
  prompt?: string;
  params?: Record<string, any>;
}

export interface JobEntry {
  prompt_id: string;
  status?: string;
  timestamp?: number;
  model_id?: string;
  mode?: string;
  prompt?: string;
  params?: Record<string, any>;
  images?: MediaFile[];
  videos?: MediaFile[];
}

export interface ModelFile {
  kind: string;
  label: string;
  dir: string;
  name: string;
  present?: boolean;
}

export interface ModelDef {
  id: string;
  name: string;
  family?: string;
  tagline?: string;
  modes: string[];
  supports_negative?: boolean;
  negative_note?: string;
  files: ModelFile[];
  defaults: Record<string, any>;
  limits: Record<string, any>;
  options: {
    cfg_visible?: boolean;
    samplers?: string[];
    schedulers?: string[];
    scheduler_fixed?: boolean;
    presets?: {
      id: string;
      label: string;
      options: { id: string; label: string; steps?: number | null; mu?: number; std?: number }[];
    } | null;
    aspects?: { id?: string; label: string; width: number; height: number }[];
  };
  notes?: string[];
  tip?: string;
  pe?: Record<string, string>;
}

/* ---------- session ---------- */

export async function loadSession(): Promise<Record<string, any>> {
  try {
    return (await api("/lazycomfy/api/session/state")) || {};
  } catch {
    return {};
  }
}

export function saveSession(key: string, value: unknown): void {
  try {
    fetch("/lazycomfy/api/session/state", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ key, value }),
      keepalive: true,
    }).catch(() => {});
  } catch {
    /* ignore */
  }
}

/* ---------- images ---------- */

export const fetchModels = async (): Promise<ModelDef[]> =>
  (await api("/lazycomfy/api/models")).models || [];

export const fetchHistory = async (limit = 10): Promise<JobEntry[]> =>
  (await api("/lazycomfy/api/history?limit=" + limit)).jobs || [];

export const fetchQueueCount = async (): Promise<number> => {
  const r = await api("/lazycomfy/api/queue");
  return r.queue_remaining ?? 0;
};

export const submitGenerate = (body: unknown): Promise<{ prompt_id: string; number?: number }> =>
  jsonPost("/lazycomfy/api/generate", body);

export const fetchResult = (promptId: string): Promise<any> =>
  api("/lazycomfy/api/result/" + encodeURIComponent(promptId));

export const cancelJob = (promptId: string): Promise<any> =>
  jsonPost("/lazycomfy/api/cancel/" + encodeURIComponent(promptId), {});

export const uploadImage = async (file: File): Promise<{ name: string; subfolder: string; type: string }> => {
  const fd = new FormData();
  fd.append("image", file, file.name);
  return api("/lazycomfy/api/upload", { method: "POST", body: fd });
};

export const deleteMedia = (f: { filename?: string; subfolder?: string; type?: string }): Promise<any> =>
  jsonPost("/lazycomfy/api/delete", {
    filename: f.filename,
    subfolder: f.subfolder || "",
    type: f.type || "output",
  });

export const fetchInputImages = async (): Promise<any[]> =>
  (await api("/lazycomfy/api/input/images")).images || [];

/* ---------- model downloads ---------- */

export const fetchCatalog = async (): Promise<any> =>
  api("/lazycomfy/api/catalog");

export const startDownload = (itemId: string, downloader: string): Promise<any> =>
  jsonPost("/lazycomfy/api/download", { item_id: itemId, downloader });

export const fetchDownloadTask = (taskId: string): Promise<any> =>
  api("/lazycomfy/api/download/" + encodeURIComponent(taskId));

export const cancelDownload = (taskId: string): Promise<any> =>
  jsonPost("/lazycomfy/api/download/cancel/" + encodeURIComponent(taskId), {});

export const startLoraDownload = (url: string, downloader: string): Promise<any> =>
  jsonPost("/lazycomfy/api/lora/download", { url, downloader });

export const startGenericDownload = (url: string, targetDir: string, downloader: string): Promise<any> =>
  jsonPost("/lazycomfy/api/generic/download", { url, target_dir: targetDir, downloader });

export const fetchHfToken = async (): Promise<any> =>
  api("/lazycomfy/api/hf_token").catch(() => null);

/* ---------- video ---------- */

export const fetchVideoConfig = (): Promise<any> => api("/lazycomfy/api/video/config");
export const fetchVideoFiles = (): Promise<any> => api("/lazycomfy/api/video/files");
export const submitVideo = (body: unknown): Promise<{ prompt_id: string }> =>
  jsonPost("/lazycomfy/api/video/generate", body);
export const fetchVideoResult = (promptId: string): Promise<any> =>
  api("/lazycomfy/api/video/result/" + encodeURIComponent(promptId));
export const cancelVideo = (promptId: string): Promise<any> =>
  jsonPost("/lazycomfy/api/video/cancel/" + encodeURIComponent(promptId), {});
export const fetchVideoHistory = async (limit = 10): Promise<JobEntry[]> =>
  (await api("/lazycomfy/api/video/history?limit=" + limit)).jobs || [];

/* ---------- upscale ---------- */

export const fetchUpscaleConfig = (): Promise<any> => api("/lazycomfy/api/upscale/config");
export const scanUpscaleImages = (dir: string): Promise<{ dir: string; images: any[] }> =>
  api("/lazycomfy/api/upscale/images?dir=" + encodeURIComponent(dir || ""));
export const submitUpscale = (body: unknown): Promise<{ prompt_id: string }> =>
  jsonPost("/lazycomfy/api/upscale/generate", body);
export const fetchUpscaleResult = (promptId: string): Promise<any> =>
  api("/lazycomfy/api/upscale/result/" + encodeURIComponent(promptId));
export const unloadUpscale = (): Promise<any> =>
  jsonPost("/lazycomfy/api/upscale/unload", {});

/* ---------- prompt forge (llama.cpp) ---------- */

export const fetchLlmConfig = (): Promise<any> => api("/lazycomfy/api/llm/config");
export const fetchLlmStatus = (): Promise<any> => api("/lazycomfy/api/llm/status");
export const llmLoad = (model: string, mmproj: string, contextLength: number): Promise<any> =>
  jsonPost("/lazycomfy/api/llm/load", { model, mmproj, context_length: contextLength });
export const llmUnload = (): Promise<any> => jsonPost("/lazycomfy/api/llm/unload", {});
export const llmInstall = (): Promise<any> => jsonPost("/lazycomfy/api/llm/install", {});
export const llmSearch = (query: string): Promise<any> =>
  jsonPost("/lazycomfy/api/llm/search", { query });
export const llmFiles = (repoId: string): Promise<any> =>
  jsonPost("/lazycomfy/api/llm/files", { repo_id: repoId });
export const llmDownload = (url: string, name: string): Promise<any> =>
  jsonPost("/lazycomfy/api/llm/download", { url, name });
export const llmCancelDownload = (taskId: string): Promise<any> =>
  jsonPost("/lazycomfy/api/llm/download/cancel/" + encodeURIComponent(taskId), {});

/* ---------- custom workflows (raw ComfyUI APIs) ---------- */

export const fetchObjectInfo = async (): Promise<Record<string, any>> =>
  (await (await fetch("/object_info")).json()) || {};

export const fetchUserFiles = async (): Promise<any[]> => {
  const res = await fetch("/api/v2/userdata?path=workflows");
  if (res.status === 404) return [];
  if (!res.ok) throw new Error("HTTP " + res.status);
  return res.json();
};

export const udUrl = (rel: string): string =>
  "/api/userdata/" + encodeURIComponent("workflows/" + rel);

export const fetchUserFile = async (rel: string): Promise<any> =>
  (await (await fetch(udUrl(rel) + "?t=" + Date.now())).json());

export const saveUserFile = async (rel: string, obj: unknown, overwrite: boolean): Promise<void> => {
  const res = await fetch(udUrl(rel) + "?overwrite=" + (overwrite ? "true" : "false"), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(obj),
  });
  if (!res.ok) throw new Error("HTTP " + res.status);
};

export const deleteUserFile = async (rel: string): Promise<void> => {
  const res = await fetch(udUrl(rel), { method: "DELETE" });
  if (!res.ok) throw new Error("HTTP " + res.status);
};

export const fetchTemplates = async (): Promise<Record<string, string[]>> =>
  (await (await fetch("/api/workflow_templates")).json()) || {};

export const fetchTemplate = async (mod: string, name: string): Promise<any> => {
  const n = name.endsWith(".json") ? name : name + ".json";
  return await (
    await fetch("/api/workflow_templates/" + encodeURIComponent(mod) + "/" + encodeURIComponent(n))
  ).json();
};

export const fetchSystemStats = async (): Promise<any> =>
  (await (await fetch("/system_stats")).json());

export const restartComfy = (): Promise<any> =>
  jsonPost("/lazycomfy/api/restart", { confirm: true });

export const submitPrompt = (prompt: unknown, clientId: string, extraData: unknown): Promise<{ prompt_id: string }> =>
  jsonPost("/prompt", { prompt, client_id: clientId, extra_data: extraData });

export const fetchPromptHistory = async (promptId: string): Promise<any> =>
  (await (await fetch("/history/" + encodeURIComponent(promptId))).json());

export const interruptPrompt = (): Promise<any> =>
  jsonPost("/interrupt", {});

export const uploadToComfy = async (file: File): Promise<{ name: string; subfolder: string }> => {
  const fd = new FormData();
  fd.append("image", file, file.name);
  fd.append("overwrite", "true");
  const res = await fetch("/upload/image", { method: "POST", body: fd });
  if (!res.ok) throw new Error("HTTP " + res.status);
  return res.json();
};

/* ---------- formatting ---------- */

export function fmtSize(n: number): string {
  if (!n) return "0 B";
  const u = ["B", "KB", "MB", "GB"];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) {
    n /= 1024;
    i++;
  }
  return n.toFixed(n >= 100 || i === 0 ? 0 : 1) + " " + u[i];
}

export function fmtDur(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000));
  if (s < 60) return s + "s";
  const m = Math.floor(s / 60);
  if (m < 60) return m + "m " + String(s % 60).padStart(2, "0") + "s";
  return Math.floor(m / 60) + "h " + String(m % 60).padStart(2, "0") + "m";
}
