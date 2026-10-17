/* Pure graph→prompt logic for the Custom workflow runner.
   Ported from the custom.html algorithms: format detection, widget slots,
   subgraph expansion, bypass, reroute resolution, seed controls, LoRA stacks. */

export interface GraphNode {
  id: number | string;
  type: string;
  title?: string;
  mode?: number;
  inputs?: { name: string; type: string; link?: number | null; label?: string; widget?: { name: string } | null }[];
  outputs?: { name: string; type?: string; links?: number[] }[];
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
  inputNode?: { id: number };
  inputs?: { name: string; type: string; label?: string; linkIds?: number[] }[];
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
  kind: "combo" | "boolean" | "number" | "text" | "raw" | "autogrow" | "group";
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

/* Widget-capable ComfyType types: these have a widget UI in the frontend
   (serialized positionally) even though they aren't primitive inputs. */
const RAW_WIDGET_TYPES = new Set([
  "COLOR", "COLORS", "BOUNDING_BOX", "BOUNDING_BOXES", "IMAGECOMPARE", "CURVE",
  "COMPOSITOR", "PAINTER", "GALLERIA", "CHART", "MARKDOWN", "TEXTAREA",
  "RANGE", "VIDEO_EDIT", "RESOLUTION_PREVIEW", "AUDIO_RECORD", "LOAD_3D",
]);

function comboOptions(type: any, o: any): string[] | null {
  if (type === "COMBO") {
    const options = o?.options;
    return Array.isArray(options) ? options.map(String) : [];
  }
  if (Array.isArray(type)) return type.map(String);
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
  if (spec[0] === "COMFY_AUTOGROW_V3") {
    return { name, kind: "autogrow", label: o.display_name || undefined };
  }
  if (spec[0] === "COMFY_DYNAMICGROUP_V3") {
    return { name, kind: "group", label: o.group_name || o.display_name || undefined };
  }
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
  // widgetType picks the widget class when the raw type isn't usable directly
  // (multi-type specs like "FLOAT,INT" or STRING with a custom widget)
  const type = o.widgetType ?? spec[0];
  const opts = comboOptions(type, o);
  if (opts) {
    return { name, kind: "combo", label: o.display_name || undefined, options: opts, defaultValue: o.default };
  }
  if (type === "BOOLEAN") {
    return { name, kind: "boolean", label: o.display_name || undefined, defaultValue: !!o.default };
  }
  if (type === "INT" || type === "FLOAT") {
    return {
      name,
      kind: "number",
      label: o.display_name || undefined,
      min: o.min,
      max: o.max,
      step: o.step ?? (type === "INT" ? 1 : 0.1),
      intOnly: type === "INT",
      control: !!o.control_after_generate,
      defaultValue: o.default ?? 0,
    };
  }
  if (type === "STRING") {
    return { name, kind: "text", label: o.display_name || undefined, multiline: !!o.multiline, defaultValue: o.default ?? "" };
  }
  if (RAW_WIDGET_TYPES.has(type)) {
    return { name, kind: "raw", label: o.display_name || undefined, defaultValue: o.default };
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

/* Subgraph nodes expose their boundary inputs as widgets. The widget spec comes
   from the inner input each boundary feeds; dotted names descend through the
   dynamic-combo options tree. */
function findInputSpec(classDef: any, name: string): any[] | null {
  const parts = name.split(".");
  let dict: any = classDef?.input;
  let spec: any[] | null = null;
  for (let i = 0; i < parts.length; i++) {
    const found = dict?.required?.[parts[i]] ?? dict?.optional?.[parts[i]];
    if (!Array.isArray(found)) return null;
    spec = found;
    if (i + 1 < parts.length) {
      let nextDict: any = null;
      for (const o of found[1]?.options || []) {
        if (o?.inputs?.required?.[parts[i + 1]] || o?.inputs?.optional?.[parts[i + 1]]) {
          nextDict = o.inputs;
          break;
        }
      }
      if (!nextDict) return null;
      dict = nextDict;
    }
  }
  return spec;
}

export function subgraphWidgetSlots(sub: SubgraphDef, objectInfo: Record<string, any>, node?: GraphNode): WidgetSlot[] {
  const inputId = sub.inputNode?.id ?? -10;
  const innerById = new Map(sub.nodes.map((n) => [Number(n.id), n]));
  const out: WidgetSlot[] = [];
  (sub.inputs || []).forEach((boundary, i) => {
    // the placeholder marks each input that is a widget with a widget ref;
    // entries without one are plain sockets. old graphs list no entries at
    // all and fall back to type classification.
    const entry = (node?.inputs || []).find((inp) => inp.name === boundary.name);
    if (entry && !(entry.widget && typeof entry.widget === "object")) return;
    const link = (sub.links || []).find((l) => l.origin_id === inputId && l.origin_slot === i);
    const target = link ? innerById.get(Number(link.target_id)) : undefined;
    const innerInput = target && link ? (target.inputs || [])[link.target_slot] : undefined;
    const spec = target && innerInput ? findInputSpec(objectInfo[target.type], innerInput.name) : null;
    // boundaries can feed inner sockets (switch branches, prompt inputs); the
    // boundary's own declared type still decides whether it has a widget
    const slot = (spec && slotFor(boundary.name, spec)) || slotFor(boundary.name, [boundary.type, {}]);
    if (!slot) return;
    slot.label = boundary.label || slot.label || boundary.name;
    out.push(slot);
  });
  return out;
}

/* ---------- widget serialization order ---------- */

export interface ResolvedWidget {
  slot: WidgetSlot;
  index: number;
  key: string;
}

/* Mirror the frontend's widgets_values layout: widget values are positional,
   dynamic-combo sub-widgets (dotted names) follow their combo recursively,
   widgets flagged control_after_generate consume an extra value right after
   them. Falls back to the legacy trailing control value written by older app
   versions (also used by PrimitiveX nodes for their "fixed" toggle). */
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
  const walk = (slot: WidgetSlot, prefix: string) => {
    const key = prefix ? `${prefix}.${slot.name}` : slot.name;
    if (slot.kind === "autogrow" || slot.kind === "group") {
      items.push({ slot, index: -1, key });
      return;
    }
    if (slot.sub) {
      const index = take();
      items.push({ slot, index, key });
      const selected = index >= 0 ? raw[index] : undefined;
      const option = slot.sub.find((s) => s.key === String(selected));
      for (const sub of option?.slots || []) walk(sub, key);
      return;
    }
    items.push({ slot, index: take(), key });
    if (slot.control && i < raw.length && (raw[i] == null || CONTROL_MODES.includes(raw[i]))) {
      control = typeof raw[i] === "string" ? raw[i] : "fixed";
      controlIndex = i++;
    }
  };
  for (const slot of slots) walk(slot, "");
  const hasSeed = slots.some((s) => s.control || s.name === "seed" || s.name === "noise_seed");
  const hasTail = hasSeed || /^Primitive/.test(node.type);
  if (hasTail && control === null && controlIndex < 0 && i < raw.length && raw.length === items.length + 1 && (raw[i] == null || (typeof raw[i] === "string" && CONTROL_MODES.includes(raw[i])))) {
    control = typeof raw[i] === "string" ? raw[i] : "fixed";
    controlIndex = i;
  }
  return { items, control: control ?? "fixed", controlIndex };
}

/* Positional span of a dynamic-combo option subtree given the current raw
   values after the combo (selected nested options follow their stored keys). */
export function dynamicSpan(slot: WidgetSlot, key: string, raw: any[], start: number): number {
  const option = slot.sub?.find((s) => s.key === key);
  let j = start;
  for (const sub of option?.slots || []) {
    if (sub.sub) j += 1 + dynamicSpan(sub, String(raw[j] ?? ""), raw, j + 1);
    else j += 1;
  }
  return j - start;
}

const leafDefault = (s: WidgetSlot) =>
  s.defaultValue ?? (s.kind === "boolean" ? false : s.kind === "combo" ? s.options?.[0] ?? "" : s.kind === "text" || s.kind === "raw" ? "" : 0);

/* Positional values an option contributes when freshly selected (nested combos
   fall back to their first option). */
export function dynamicDefaults(slot: WidgetSlot, key: string): any[] {
  const option = slot.sub?.find((s) => s.key === key);
  const out: any[] = [];
  for (const sub of option?.slots || []) {
    if (sub.sub) {
      const k = sub.options?.[0] ?? "";
      out.push(k, ...dynamicDefaults(sub, k));
    } else {
      out.push(leafDefault(sub));
    }
  }
  return out;
}

/* Same as dynamicDefaults but keyed by dotted name, for widgets_values_named. */
export function dynamicNamedDefaults(slot: WidgetSlot, key: string, prefix = ""): Record<string, any> {
  const out: Record<string, any> = {};
  const option = slot.sub?.find((s) => s.key === key);
  for (const sub of option?.slots || []) {
    const k = prefix ? `${prefix}.${sub.name}` : sub.name;
    if (sub.sub) {
      const first = sub.options?.[0] ?? "";
      out[k] = first;
      Object.assign(out, dynamicNamedDefaults(sub, first, k));
    } else {
      out[k] = leafDefault(sub);
    }
  }
  return out;
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
  for (const { slot, index, key } of items) {
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
    values[key] = v;
  }
  return { values, control, loras };
}

/* All dotted names a slot tree can produce, including every dynamic-combo
   option (the graph itself says which one is selected). */
function possibleNames(slots: WidgetSlot[]): Set<string> {
  const names = new Set<string>();
  const walk = (slot: WidgetSlot, prefix: string) => {
    const key = prefix ? `${prefix}.${slot.name}` : slot.name;
    names.add(key);
    for (const o of slot.sub || []) for (const sub of o.slots) walk(sub, key);
  };
  for (const s of slots) walk(s, "");
  return names;
}

export function namedValues(node: GraphNode, slots: WidgetSlot[]): Record<string, any> {
  const out: Record<string, any> = {};
  const rec = node.widgets_values_named || {};
  const names = possibleNames(slots);
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

  // litegraph slot type matching (LiteGraph.isValidConnection)
  const isValidConn = (a: any, b: any): boolean => {
    if (a === b) return true;
    if (a == null || b == null || a === "" || b === "") return false;
    for (const x of String(a).split(",")) {
      for (const y of String(b).split(",")) {
        if (x === y || x === "*" || y === "*") return true;
      }
    }
    return false;
  };

  // frontend ExecutableNodeDTO._getBypassSlotIndex: which input a bypassed
  // node forwards to for output slot given the consumer's type
  const bypassSlotIndex = (n: GraphNode, slot: number, type: any): number => {
    const ins = n.inputs || [];
    if (type === "*" || type === "") return ins.length > slot ? slot : 0;
    const outputType = (n.outputs || [])[slot]?.type;
    const opposite = ins[slot];
    if (opposite && isValidConn(opposite.type, outputType) && isValidConn(opposite.type, type)) return slot;
    const exact = ins.findIndex((i) => i.type === type);
    if (exact !== -1) return exact;
    return ins.findIndex((i) => isValidConn(i.type, outputType) && isValidConn(i.type, type));
  };

  // follow Reroute/PrimitiveNode chains and bypassed/muted nodes back to the
  // source; returns [nodeId, slot], a widget value, or undefined when the
  // connection is dropped (muted node or bypass without a matching input)
  const resolveReroute = (nodeMap: Map<string, GraphNode>, startId: string | number, slot: number, type?: any): any => {
    let cur = nodeMap.get(String(startId));
    let curSlot = slot;
    let curType = type;
    for (let depth = 0; depth < 64 && cur; depth++) {
      if (cur.mode === 2) return undefined;
      if (cur.mode === 4) {
        const idx = bypassSlotIndex(cur, curSlot, curType);
        if (idx < 0) return undefined;
        const bin = (cur.inputs || [])[idx];
        if (!bin || bin.link == null) return undefined;
        const bl = linkById.get(bin.link);
        if (!bl) return undefined;
        cur = nodeMap.get(String(bl[1]));
        curSlot = bl[2];
        curType = bin.type;
        continue;
      }
      if (!REROUTE_TYPES.has(cur.type) && cur.type !== "PrimitiveNode") break;
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
    if (!cur || cur.mode === 2) return undefined;
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
  const redirectVal = new Map<string, any>();

  const resolveLink = (srcId: string | number, srcSlot: number, type?: any): any => {
    const r = resolveReroute(nodeMap, srcId, srcSlot, type);
    if (Array.isArray(r)) {
      const pushKey = `${r[0]}:${r[1]}`;
      const hit = redirect.get(pushKey);
      if (hit) return hit;
      const value = redirectVal.get(pushKey);
      if (value !== undefined) return value;
    }
    return r;
  };

  const isOff = (n: GraphNode) => n.mode === 2 || n.mode === 4 || bypassed.has(n.id) || bypassed.has(String(n.id));

  interface SubCtx {
    node: GraphNode;
    sub: SubgraphDef;
    idMap: Map<number, string>;
    innerById: Map<number, GraphNode>;
    inputId: number;
    phInputs: Map<string, any>;
    unresolved: Set<number>;
  }
  const contexts: SubCtx[] = [];
  for (const node of wf.nodes) {
    if (isOff(node) || !subgraphs.has(node.type)) continue;
    const sub = subgraphs.get(node.type)!;
    for (const inner of sub.nodes) {
      if (inner.mode === 2 || inner.mode === 4) continue;
      if (subgraphs.has(inner.type)) {
        errors.push({ nodeId: node.id, message: "Nested subgraphs are not supported" });
      } else if (!NOTE_TYPES.has(inner.type) && !REROUTE_TYPES.has(inner.type) && inner.type !== "PrimitiveNode" && objectInfo && !objectInfo[inner.type] && Number(inner.id) >= 0) {
        errors.push({ nodeId: node.id, message: `Unknown node type in subgraph: ${inner.type}` });
      }
    }
    const idMap = new Map<number, string>();
    const innerById = new Map<number, GraphNode>();
    for (const inner of sub.nodes) {
      if (inner.id === -10 || inner.id === -20) continue;
      innerById.set(Number(inner.id), inner);
      idMap.set(Number(inner.id), String(nextId++));
    }
    contexts.push({ node, sub, idMap, innerById, inputId: sub.inputNode?.id ?? -10, phInputs: new Map(), unresolved: new Set() });
  }

  // follow inner Reroute/PrimitiveNode chains and bypassed nodes back to a
  // source; boundary inputs resolve to the placeholder's widget value
  const resolveInnerOf = (ctx: SubCtx) => {
    const { sub, idMap, innerById, inputId, phInputs } = ctx;
    const fromBoundary = (slot: number): any => {
      const bIn = (sub.inputs || [])[slot];
      return bIn && phInputs.has(bIn.name) ? phInputs.get(bIn.name) : undefined;
    };
    return (originId: number, originSlot: number, type?: any): any => {
      let oid = originId;
      let oslot = originSlot;
      let otype = type;
      for (let depth = 0; depth < 64; depth++) {
        const on = innerById.get(oid);
        if (!on) return undefined;
        if (on.mode === 2) return undefined;
        if (on.mode === 4) {
          const idx = bypassSlotIndex(on, oslot, otype);
          if (idx < 0) return undefined;
          const bin = (on.inputs || [])[idx];
          if (!bin || bin.link == null) return undefined;
          const bl = sub.links.find((x) => x.id === bin.link);
          if (!bl) return undefined;
          if (bl.origin_id === inputId) return fromBoundary(bl.origin_slot);
          oid = bl.origin_id;
          oslot = bl.origin_slot;
          otype = bin.type;
          continue;
        }
        if (on.type === "PrimitiveNode") {
          return Array.isArray(on.widgets_values) ? on.widgets_values[0] : undefined;
        }
        if (!REROUTE_TYPES.has(on.type)) {
          const mapped = idMap.get(oid);
          return mapped ? [mapped, oslot] : undefined;
        }
        const rin = (on.inputs || []).find((x) => x.link != null);
        if (!rin?.link) return Array.isArray(on.widgets_values) ? on.widgets_values[0] : undefined;
        const rl = sub.links.find((x) => x.id === rin.link);
        if (!rl) return undefined;
        if (rl.origin_id === inputId) return fromBoundary(rl.origin_slot);
        oid = rl.origin_id;
        oslot = rl.origin_slot;
      }
      return undefined;
    };
  };

  // placeholder boundary values: positional from widgets_values, overridden
  // by outer links / named values. Rounds let chained subgraph instances
  // resolve each other's boundary outputs regardless of node order.
  for (let round = 0; round < 4; round++) {
    let changed = false;
    for (const ctx of contexts) {
      const { node, sub } = ctx;
      const before = ctx.phInputs.size;
      const phVals = Array.isArray(node.widgets_values) ? (node.widgets_values as any[]) : [];
      const named = node.widgets_values_named || {};
      const namedRec =
        typeof node.widgets_values === "object" && !Array.isArray(node.widgets_values)
          ? (node.widgets_values as Record<string, any>)
          : {};
      // named values are authoritative; positional is the legacy fallback
      for (const { slot, index, key } of resolveWidgets(node, subgraphWidgetSlots(sub, objectInfo, node)).items) {
        const nv = named[key] ?? namedRec[key];
        if (nv !== undefined) ctx.phInputs.set(slot.name, nv);
        else if (index >= 0 && phVals[index] !== undefined) ctx.phInputs.set(slot.name, phVals[index]);
      }
      for (const inp of node.inputs || []) {
        const bIn = (sub.inputs || []).find((b) => b.name === inp.name);
        if (!bIn) continue;
        if (inp.link != null) {
          const link = linkById.get(inp.link);
          if (link) {
            const v = resolveLink(link[1], link[2], bIn.type);
            if (v !== undefined) ctx.phInputs.set(bIn.name, v);
          }
        } else if (inp.widget && !ctx.phInputs.has(bIn.name)) {
          const v = named[inp.widget.name] ?? namedRec[inp.widget.name];
          if (v !== undefined) ctx.phInputs.set(bIn.name, v);
        }
      }
      if (ctx.phInputs.size !== before) changed = true;
      // boundary outputs: sub link into -20 with target_slot = placeholder output slot
      const resolveInner = resolveInnerOf(ctx);
      const outNames = (node.outputs || []).map((o) => o.name);
      for (const sl of sub.links) {
        if (sl.target_id !== -20) continue;
        const src = resolveInner(sl.origin_id, sl.origin_slot, (node.outputs || [])[sl.target_slot]?.type);
        const keys = [`${node.id}:${sl.target_slot}`, outNames[sl.target_slot] !== undefined ? `${node.id}:${outNames[sl.target_slot]}` : null];
        if (Array.isArray(src)) {
          ctx.unresolved.delete(sl.target_slot);
          for (const key of keys) if (key) redirect.set(key, src as [string, number]);
        } else if (src !== undefined) {
          ctx.unresolved.delete(sl.target_slot);
          for (const key of keys) if (key) redirectVal.set(key, src);
        } else {
          ctx.unresolved.add(sl.target_slot);
        }
      }
    }
    if (!changed) break;
  }
  for (const ctx of contexts) {
    for (const slot of ctx.unresolved) {
      errors.push({ nodeId: ctx.node.id, message: `Subgraph output ${slot} has no source` });
    }
  }

  // emit the inner nodes of every expanded instance
  for (const ctx of contexts) {
    const { sub, idMap, phInputs } = ctx;
    const resolveInner = resolveInnerOf(ctx);
    for (const inner of sub.nodes) {
      if (inner.id === -10 || inner.id === -20) continue;
      if (inner.mode === 2 || inner.mode === 4) continue;
      if (NOTE_TYPES.has(inner.type)) continue;
      if (REROUTE_TYPES.has(inner.type) || inner.type === "PrimitiveNode") continue;
      if (subgraphs.has(inner.type)) continue; // nested, reported above
      const nid = idMap.get(Number(inner.id))!;
      const inputs: Record<string, any> = {};
      const innerDef = objectInfo?.[inner.type];
      const innerSlots = innerDef ? widgetSlots(innerDef) : [];
      const innerCtrl = (inner.widgets_values_named || {}).control_after_generate;
      if (Array.isArray(inner.widgets_values)) {
        const { values, control, loras } = mapPositional(inner, innerSlots);
        Object.assign(inputs, values);
        const ctrl = typeof innerCtrl === "string" ? innerCtrl : control;
        if (ctrl !== "fixed" && ("seed" in inputs || "noise_seed" in inputs)) inputs.control_after_generate = ctrl;
        loras.forEach((l, i) => {
          if (l.on && l.lora) {
            inputs[`lora_${i + 1}`] = { on: true, lora: l.lora, strength: l.strength };
          }
        });
      }
      // named values are authoritative; positional is the legacy fallback
      Object.assign(inputs, namedValues(inner, innerSlots));
      if (!Array.isArray(inner.widgets_values) && typeof innerCtrl === "string" && innerCtrl !== "fixed" && ("seed" in inputs || "noise_seed" in inputs)) {
        inputs.control_after_generate = innerCtrl;
      }
      for (const inp of inner.inputs || []) {
        if (inp.link == null) continue;
        const sl = sub.links.find((x) => x.id === inp.link);
        if (!sl) continue;
        if (sl.origin_id === ctx.inputId) {
          const bIn = (sub.inputs || [])[sl.origin_slot] || (sub.inputs || []).find((b) => (b.linkIds || []).includes(sl.id));
          if (bIn && phInputs.has(bIn.name)) inputs[inp.name] = phInputs.get(bIn.name);
        } else {
          const src = resolveInner(sl.origin_id, sl.origin_slot, inp.type);
          if (src !== undefined) inputs[inp.name] = src;
        }
      }
      applySeedControl(inputs);
      emit(nid, inner.type, inputs);
    }
  }

  /* Phase 2 — regular nodes. */
  for (const node of wf.nodes) {
    if (isOff(node)) continue;
    if (NOTE_TYPES.has(node.type)) continue;
    if (REROUTE_TYPES.has(node.type) || node.type === "PrimitiveNode") continue;
    if (subgraphs.has(node.type)) continue; // expanded in phase 1

    const classDef = objectInfo?.[node.type];
    const slots = classDef ? widgetSlots(classDef) : [];
    const inputs: Record<string, any> = {};
    const namedCtrl = (node.widgets_values_named || {}).control_after_generate;
    if (Array.isArray(node.widgets_values)) {
      const { values, control, loras } = mapPositional(node, slots);
      Object.assign(inputs, values);
      const ctrl = typeof namedCtrl === "string" ? namedCtrl : control;
      if (ctrl !== "fixed" && ("seed" in inputs || "noise_seed" in inputs)) inputs.control_after_generate = ctrl;
      loras.forEach((l, i) => {
        if (l.on && l.lora) {
          inputs[`lora_${i + 1}`] = { on: true, lora: l.lora, strength: l.strength };
        }
      });
    }
    // named values are authoritative; positional is the legacy fallback
    Object.assign(inputs, namedValues(node, slots));
    if (!Array.isArray(node.widgets_values) && typeof namedCtrl === "string" && namedCtrl !== "fixed" && ("seed" in inputs || "noise_seed" in inputs)) {
      inputs.control_after_generate = namedCtrl;
    }
    for (const inp of node.inputs || []) {
      if (inp.link == null) continue;
      const link = linkById.get(inp.link);
      if (!link) continue;
      const resolved = resolveLink(link[1], link[2], inp.type);
      if (resolved !== undefined) inputs[inp.name] = resolved;
    }
    applySeedControl(inputs);
    emit(String(node.id), node.type, inputs);
  }

  // frontend parity: drop inputs whose source node was not emitted
  for (const n of Object.values(prompt)) {
    for (const [key, v] of Object.entries(n.inputs)) {
      if (Array.isArray(v) && v.length === 2 && typeof v[0] === "string" && !prompt[v[0]]) {
        delete n.inputs[key];
      }
    }
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
