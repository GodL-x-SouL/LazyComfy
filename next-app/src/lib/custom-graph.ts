/* Pure graph→prompt logic for the Custom workflow runner.
   Ported from the custom.html algorithms: format detection, widget slots,
   subgraph expansion, bypass, reroute resolution, seed controls, LoRA stacks. */

export interface GraphNode {
  id: number | string;
  type: string;
  title?: string;
  mode?: number;
  inputs?: { name: string; type: string; link?: number | null; widget?: { name: string } }[];
  outputs?: { name: string; links?: number[] }[];
  widgets_values?: any[] | Record<string, any>;
  widgets_values_named?: Record<string, any>;
  properties?: Record<string, any>;
}

export interface Graph {
  nodes: GraphNode[];
  links: any[][];
  groups?: any[];
  definitions?: { subgraphs?: SubgraphDef[] };
}

export interface SubgraphDef {
  id: string;
  name: string;
  inputs?: { name: string; type: string; linkIds?: number[] }[];
  outputs?: { name: string }[];
  nodes: GraphNode[];
  links: { id: number; origin_id: number; origin_slot: number; target_id: number; target_slot: number; type: string }[];
}

export const NOTE_TYPES = new Set(["Note", "MarkdownNote"]);
export const REROUTE_TYPES = new Set(["Reroute"]);
export const CONTROL_MODES = ["fixed", "increment", "decrement", "randomize"];

export function isGraphFormat(obj: any): boolean {
  return !!obj && Array.isArray(obj.nodes);
}

export function isApiFormat(obj: any): boolean {
  if (!obj || typeof obj !== "object" || Array.isArray(obj)) return false;
  const keys = Object.keys(obj);
  if (!keys.length) return false;
  return keys.every((k) => {
    const v = obj[k];
    return v && typeof v === "object" && typeof v.class_type === "string";
  });
}

/* ---------- widget slots from object_info ---------- */

export interface WidgetSlot {
  name: string;
  kind: "combo" | "boolean" | "number" | "text";
  label?: string;
  options?: string[];
  min?: number;
  max?: number;
  step?: number;
  multiline?: boolean;
  intOnly?: boolean;
  control?: boolean;
  defaultValue?: any;
  sub?: { key: string; slots: WidgetSlot[] }[];
}

function comboOptions(spec: any[]): string[] | null {
  const t = spec[0];
  if (t === "COMBO") {
    const o = spec[1]?.options;
    return Array.isArray(o) ? o.map(String) : [];
  }
  if (Array.isArray(t)) return t.map(String);
  return null;
}

function subSlots(inputs: any): WidgetSlot[] {
  const out: WidgetSlot[] = [];
  for (const section of ["required", "optional"]) {
    for (const [name, spec] of Object.entries<any>(inputs?.[section] || {})) {
      if (!Array.isArray(spec)) continue;
      const s = slotFor(name, spec);
      if (s) out.push(s);
    }
  }
  return out;
}

function slotFor(name: string, spec: any[]): WidgetSlot | null {
  const o = spec[1] || {};
  if (o.forceInput) return null;
  if (spec[0] === "COMFY_DYNAMICCOMBO_V3") {
    const options = (o.options || []) as { key: string; inputs?: any }[];
    return {
      name,
      kind: "combo",
      label: o.display_name || undefined,
      options: options.map((x) => String(x.key)),
      sub: options.map((x) => ({ key: String(x.key), slots: subSlots(x.inputs) })),
    };
  }
  const opts = comboOptions(spec);
  if (opts) {
    return { name, kind: "combo", label: o.display_name || undefined, options: opts, defaultValue: o.default };
  }
  if (spec[0] === "BOOLEAN") {
    return { name, kind: "boolean", label: o.display_name || undefined, defaultValue: !!o.default };
  }
  if (spec[0] === "INT" || spec[0] === "FLOAT") {
    return {
      name,
      kind: "number",
      label: o.display_name || undefined,
      min: o.min,
      max: o.max,
      step: o.step ?? (spec[0] === "INT" ? 1 : 0.1),
      intOnly: spec[0] === "INT",
      control: !!o.control_after_generate,
      defaultValue: o.default ?? 0,
    };
  }
  if (spec[0] === "STRING") {
    return { name, kind: "text", label: o.display_name || undefined, multiline: !!o.multiline, defaultValue: o.default ?? "" };
  }
  return null;
}

/* Widget-capable inputs follow the frontend's rules: forceInput stays a
   socket, socket-only types (IMAGE, MODEL, …) are not widgets, files use a
   combo spec with image_upload. */
export function widgetSlots(classDef: any): WidgetSlot[] {
  const slots: WidgetSlot[] = [];
  if (!classDef?.input) return slots;
  for (const section of ["required", "optional"]) {
    const group = classDef.input[section] || {};
    for (const name of Object.keys(group)) {
      const spec = group[name];
      if (!Array.isArray(spec)) continue;
      const s = slotFor(name, spec);
      if (s) slots.push(s);
    }
  }
  return slots;
}

export function isImageLike(name: string, value: any): boolean {
  if (name === "image") return true;
  return typeof value === "string" && /\.(png|jpe?g|webp|mp4|webm|mov|mkv)$/i.test(value);
}

/* ---------- widget serialization order ---------- */

export interface ResolvedWidget {
  slot: WidgetSlot;
  index: number;
  parent?: string;
}

/* Mirror the frontend's widgets_values layout: widget values are positional,
   dynamic-combo sub-widgets (dotted names) follow their combo, widgets flagged
   control_after_generate consume an extra value right after them. Falls back
   to the legacy trailing control value written by older app versions. */
export function resolveWidgets(
  node: GraphNode,
  slots: WidgetSlot[],
): { items: ResolvedWidget[]; control: string; controlIndex: number } {
  const raw = Array.isArray(node.widgets_values) ? (node.widgets_values as any[]) : [];
  const items: ResolvedWidget[] = [];
  let i = 0;
  let control: string | null = null;
  let controlIndex = -1;
  const take = () => (i < raw.length ? i++ : -1);
  for (const slot of slots) {
    if (slot.sub) {
      const index = take();
      items.push({ slot, index });
      const key = index >= 0 ? raw[index] : undefined;
      const option = slot.sub.find((s) => s.key === String(key));
      for (const sub of option?.slots || []) items.push({ slot: sub, index: take(), parent: slot.name });
      continue;
    }
    items.push({ slot, index: take() });
    if (slot.control && i < raw.length && (raw[i] == null || CONTROL_MODES.includes(raw[i]))) {
      control = typeof raw[i] === "string" ? raw[i] : "fixed";
      controlIndex = i++;
    }
  }
  const hasSeed = slots.some((s) => s.control || s.name === "seed" || s.name === "noise_seed");
  if (hasSeed && control === null && controlIndex < 0 && i < raw.length && raw.length === items.length + 1 && (raw[i] == null || (typeof raw[i] === "string" && CONTROL_MODES.includes(raw[i])))) {
    control = typeof raw[i] === "string" ? raw[i] : "fixed";
    controlIndex = i;
  }
  return { items, control: control ?? "fixed", controlIndex };
}

/* Positional values → per-slot values, following the original mapping rules:
   linked widgets still consume their positional value (a link overrides it at
   build time); LoRA-stack dicts are detected by shape. */
export function mapPositional(
  node: GraphNode,
  slots: WidgetSlot[],
): { values: Record<string, any>; control: string; loras: { on: boolean; lora: string; strength: number; strengthTwo?: number }[] } {
  const values: Record<string, any> = {};
  const loras: { on: boolean; lora: string; strength: number; strengthTwo?: number }[] = [];
  const raw = Array.isArray(node.widgets_values) ? (node.widgets_values as any[]) : [];
  const { items, control } = resolveWidgets(node, slots);
  for (const { slot, index, parent } of items) {
    if (index < 0) continue;
    const v = raw[index];
    if (v !== undefined && v !== null && typeof v === "object" && typeof (v as any).lora === "string" && (v as any).lora) {
      loras.push({
        on: !!(v as any).on,
        lora: (v as any).lora,
        strength: Number((v as any).strength) || 0,
        strengthTwo: (v as any).strengthTwo,
      });
      continue;
    }
    values[parent ? `${parent}.${slot.name}` : slot.name] = v;
  }
  return { values, control, loras };
}

export function namedValues(node: GraphNode, slots: WidgetSlot[]): Record<string, any> {
  const out: Record<string, any> = {};
  const rec = node.widgets_values_named || {};
  const names = new Set(slots.map((s) => s.name));
  for (const [k, v] of Object.entries(rec)) {
    if (/^videopreview/i.test(k)) continue;
    if (names.has(k)) out[k] = v;
  }
  if (typeof node.widgets_values === "object" && !Array.isArray(node.widgets_values)) {
    for (const [k, v] of Object.entries(node.widgets_values)) {
      if (/^videopreview/i.test(k)) continue;
      if (names.has(k) && !(k in out)) out[k] = v;
    }
  }
  return out;
}

/* ---------- prompt building ---------- */

export interface BuildError {
  nodeId: string | number;
  message: string;
}

interface FlatNode {
  id?: string;
  class_type: string;
  inputs: Record<string, any>;
}

export function buildPrompt(
  wf: Graph,
  bypassed: Set<string | number>,
  objectInfo: Record<string, any>,
): { prompt: Record<string, FlatNode>; errors: BuildError[] } {
  const errors: BuildError[] = [];
  const prompt: Record<string, FlatNode> = {};
  const linkById = new Map<number, any[]>();
  for (const l of wf.links || []) linkById.set(l[0], l);

  // fresh ids for subgraph expansion
  let maxId = 0;
  for (const n of wf.nodes) {
    const v = typeof n.id === "number" ? n.id : parseInt(String(n.id), 10);
    if (Number.isFinite(v) && v > maxId) maxId = v;
  }
  let nextId = maxId + 1;

  const subgraphs = new Map<string, SubgraphDef>();
  for (const s of wf.definitions?.subgraphs || []) subgraphs.set(s.id, s);

  const emit = (id: string, classType: string, inputs: Record<string, any>) => {
    prompt[id] = { class_type: classType, inputs };
  };

  const resolveReroute = (nodeMap: Map<string, GraphNode>, startId: string | number, slot: number): any => {
    let cur = nodeMap.get(String(startId));
    let curSlot = slot;
    for (let depth = 0; depth < 64 && cur && REROUTE_TYPES.has(cur.type); depth++) {
      const inp = (cur.inputs || []).find((i) => i.link != null);
      if (!inp?.link) {
        const vals = Array.isArray(cur.widgets_values) ? cur.widgets_values : [];
        return vals[0];
      }
      const link = linkById.get(inp.link);
      if (!link) return undefined;
      cur = nodeMap.get(String(link[1]));
      curSlot = link[2];
    }
    if (!cur) return undefined;
    return [String(cur.id), curSlot];
  };

  const applySeedControl = (inputs: Record<string, any>) => {
    for (const key of ["seed", "noise_seed"]) {
      if (!(key in inputs)) continue;
      const ctrl = inputs.control_after_generate;
      delete inputs.control_after_generate;
      const base = Number(inputs[key]) || 0;
      if (ctrl === "randomize") inputs[key] = Math.floor(Math.random() * 1125899906842528);
      else if (ctrl === "increment") inputs[key] = base + 1;
      else if (ctrl === "decrement") inputs[key] = Math.max(0, base - 1);
    }
  };

  const nodeMap = new Map<string, GraphNode>();
  for (const n of wf.nodes) nodeMap.set(String(n.id), n);

  /* Phase 1 — expand subgraph placeholders (single level), record redirects
     from placeholder outputs to the inner nodes driving each boundary output. */
  const redirect = new Map<string, [string, number]>();
  for (const node of wf.nodes) {
    if (node.mode === 4 || bypassed.has(node.id) || bypassed.has(String(node.id))) continue;
    if (!subgraphs.has(node.type)) continue;
    const sub = subgraphs.get(node.type)!;
    for (const inner of sub.nodes) {
      if (subgraphs.has(inner.type)) {
        errors.push({ nodeId: node.id, message: "Nested subgraphs are not supported" });
      } else if (!REROUTE_TYPES.has(inner.type) && objectInfo && !objectInfo[inner.type] && Number(inner.id) >= 0) {
        errors.push({ nodeId: node.id, message: `Unknown node type in subgraph: ${inner.type}` });
      }
    }
    const idMap = new Map<number, string>();
    for (const inner of sub.nodes) {
      if (inner.id === -10 || inner.id === -20) continue;
      idMap.set(Number(inner.id), String(nextId++));
    }
    const named = node.widgets_values_named || {};
    const namedRec =
      typeof node.widgets_values === "object" && !Array.isArray(node.widgets_values)
        ? (node.widgets_values as Record<string, any>)
        : {};
    // placeholder inputs (linked or literal) keyed by boundary input name
    const phInputs = new Map<string, any>();
    for (const inp of node.inputs || []) {
      const bIn = (sub.inputs || []).find((b) => b.name === inp.name);
      if (!bIn) continue;
      if (inp.link != null) {
        const link = linkById.get(inp.link);
        if (link) phInputs.set(bIn.name, resolveReroute(nodeMap, link[1], link[2]));
      } else if (inp.widget) {
        const v = named[inp.widget.name] ?? namedRec[inp.widget.name];
        if (v !== undefined) phInputs.set(bIn.name, v);
      }
    }
    for (const inner of sub.nodes) {
      if (inner.id === -10 || inner.id === -20) continue;
      const nid = idMap.get(Number(inner.id))!;
      const inputs: Record<string, any> = {};
      for (const inp of inner.inputs || []) {
        if (inp.link != null) {
          const sl = sub.links.find((x) => x.id === inp.link);
          if (!sl) continue;
          if (sl.origin_id === -10) {
            const bIn = (sub.inputs || []).find(
              (b) => (b.linkIds || []).includes(sl.id) || (b as any).linkId === sl.id,
            );
            // fall back: boundary inputs are ordered; match by origin slot
            const bInBySlot =
              bIn || (sub.inputs || [])[sl.origin_slot] || (sub.inputs || [])[0];
            if (bInBySlot && phInputs.has(bInBySlot.name)) inputs[inp.name] = phInputs.get(bInBySlot.name);
          } else {
            const src = idMap.get(sl.origin_id);
            if (src) inputs[inp.name] = [src, sl.origin_slot];
          }
        } else if (inp.widget) {
          const vals = Array.isArray(inner.widgets_values) ? inner.widgets_values : [];
          const wi = (inner.inputs || []).filter((x) => x.widget && x.link == null).indexOf(inp);
          if (wi >= 0 && wi < vals.length) inputs[inp.widget.name] = vals[wi];
        }
      }
      applySeedControl(inputs);
      emit(nid, inner.type, inputs);
    }
    // boundary outputs: sub link into -20 with target_slot = placeholder output slot
    const outNames = (node.outputs || []).map((o) => o.name);
    for (const sl of sub.links) {
      if (sl.target_id !== -20) continue;
      const src = idMap.get(sl.origin_id);
      if (!src) {
        errors.push({ nodeId: node.id, message: `Subgraph output ${sl.target_slot} has no source` });
        continue;
      }
      const key = outNames[sl.target_slot] !== undefined ? `${node.id}:${outNames[sl.target_slot]}` : `${node.id}:${sl.target_slot}`;
      redirect.set(`${node.id}:${sl.target_slot}`, [src, sl.origin_slot]);
      redirect.set(key, [src, sl.origin_slot]);
    }
  }

  const resolveLink = (srcId: string | number, srcSlot: number): any => {
    const r = resolveReroute(nodeMap, srcId, srcSlot);
    if (Array.isArray(r)) {
      const hit = redirect.get(`${r[0]}:${r[1]}`);
      if (hit) return hit;
    }
    return r;
  };

  /* Phase 2 — regular nodes. */
  for (const node of wf.nodes) {
    if (node.mode === 4 || bypassed.has(node.id) || bypassed.has(String(node.id))) continue;
    if (NOTE_TYPES.has(node.type)) continue;
    if (REROUTE_TYPES.has(node.type)) continue;
    if (subgraphs.has(node.type)) continue; // expanded in phase 1

    const classDef = objectInfo?.[node.type];
    const slots = classDef ? widgetSlots(classDef) : [];
    const inputs: Record<string, any> = {};
    if (Array.isArray(node.widgets_values)) {
      const { values, control, loras } = mapPositional(node, slots);
      Object.assign(inputs, values);
      if (control !== "fixed") inputs.control_after_generate = control;
      loras.forEach((l, i) => {
        if (l.on && l.lora) {
          inputs[`lora_${i + 1}`] = { on: true, lora: l.lora, strength: l.strength };
        }
      });
    } else {
      Object.assign(inputs, namedValues(node, slots));
    }
    for (const inp of node.inputs || []) {
      if (inp.link == null) continue;
      const link = linkById.get(inp.link);
      if (!link) continue;
      const resolved = resolveLink(link[1], link[2]);
      if (resolved !== undefined) inputs[inp.name] = resolved;
    }
    applySeedControl(inputs);
    emit(String(node.id), node.type, inputs);
  }

  return { prompt, errors };
}

/* ---------- misc ---------- */

export function viewUrl(
  file: { filename: string; subfolder?: string; type?: string },
  preview?: string,
): string {
  const q = new URLSearchParams({
    filename: file.filename,
    subfolder: file.subfolder || "",
    type: file.type || "output",
  });
  if (preview) q.set("preview", preview);
  return "/view?" + q.toString();
}

export function cleanFileName(name: string): string {
  return (name || "workflow").replace(/[\\/:*?"<>|]/g, "_").replace(/\.json$/i, "") + ".json";
}

export function fmtTimeAgo(at: number): string {
  const s = Math.max(0, Math.floor((Date.now() - at) / 1000));
  if (s < 60) return s + "s ago";
  if (s < 3600) return Math.floor(s / 60) + "m ago";
  if (s < 86400) return Math.floor(s / 3600) + "h ago";
  return Math.floor(s / 86400) + "d ago";
}
