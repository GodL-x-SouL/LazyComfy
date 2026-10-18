/// Port of next-app custom-graph.ts: workflow-graph models, widget-slot
/// inference from /object_info, subgraph boundary widgets, positional/named
/// value mapping, and the two-phase prompt builder (subgraph expansion +
/// regular nodes with reroute/bypass resolution and seed-control handling).
library;

/// Graph-format node as stored in .json workflow files.
class GraphNode {
  final dynamic id;
  final String type;
  final String title;
  final int? mode;
  final List<dynamic>? inputs;
  final List<dynamic>? outputs;
  final dynamic widgetsValues;
  final Map<String, dynamic>? widgetsValuesNamed;
  final List<dynamic>? links;

  GraphNode({
    required this.id,
    required this.type,
    this.title = '',
    this.mode,
    this.inputs,
    this.outputs,
    this.widgetsValues,
    this.widgetsValuesNamed,
    this.links,
  });

  String get key => '$id';

  /// Serialize back to graph-format JSON (mirrors fromJson keys) so an
  /// edited workflow — widget values included — round-trips through
  /// persistence and reloads identically.
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        if (title.isNotEmpty) 'title': title,
        if (mode != null) 'mode': mode,
        if (inputs != null) 'inputs': inputs,
        if (outputs != null) 'outputs': outputs,
        if (links != null) 'links': links,
        if (widgetsValues != null) 'widgets_values': widgetsValues,
        if (widgetsValuesNamed != null)
          'widgets_values_named': widgetsValuesNamed,
      };

  factory GraphNode.fromJson(Map<String, dynamic> j) => GraphNode(
        id: j['id'],
        type: '${j['type'] ?? ''}',
        title: '${j['title'] ?? ''}',
        mode: (j['mode'] is num) ? (j['mode'] as num).toInt() : null,
        inputs: (j['inputs'] is List) ? List<dynamic>.from(j['inputs']) : null,
        outputs:
            (j['outputs'] is List) ? List<dynamic>.from(j['outputs']) : null,
        widgetsValues: j['widgets_values'],
        widgetsValuesNamed: (j['widgets_values_named'] is Map)
            ? Map<String, dynamic>.from(j['widgets_values_named'])
            : null,
        links: (j['links'] is List) ? List<dynamic>.from(j['links']) : null,
      );

  GraphNode copy() => GraphNode(
        id: id,
        type: type,
        title: title,
        mode: mode,
        inputs: inputs
            ?.map((e) => e is Map ? Map<String, dynamic>.from(e) : e)
            .toList(),
        outputs: outputs,
        widgetsValues: widgetsValues is List
            ? List<dynamic>.from(widgetsValues)
            : (widgetsValues is Map
                ? Map<String, dynamic>.from(widgetsValues)
                : widgetsValues),
        widgetsValuesNamed: widgetsValuesNamed == null
            ? null
            : Map<String, dynamic>.from(widgetsValuesNamed!),
        links: links,
      );
}

class Graph {
  final List<GraphNode> nodes;
  final List<dynamic> links;
  final List<dynamic>? subgraphs;

  Graph({required this.nodes, required this.links, this.subgraphs});

  factory Graph.fromJson(Map<String, dynamic> j) {
    List<dynamic>? defs;
    final d = j['definitions'];
    if (d is Map && d['subgraphs'] is List) {
      defs = List<dynamic>.from(d['subgraphs']);
    } else if (d is List) {
      defs = List<dynamic>.from(d);
    }
    return Graph(
      nodes: ((j['nodes'] as List?) ?? [])
          .whereType<Map>()
          .map((n) => GraphNode.fromJson(Map<String, dynamic>.from(n)))
          .toList(),
      links: (j['links'] is List) ? List<dynamic>.from(j['links']) : const [],
      subgraphs: defs,
    );
  }

  /// Current nodes back to graph-format JSON for persistence. Subgraph
  /// definitions ride along separately (see the persist envelope).
  Map<String, dynamic> toJson() => {
        'nodes': [for (final n in nodes) n.toJson()],
        'links': links,
      };
}

const noteTypes = {'Note', 'MarkdownNote'};
const rerouteTypes = {'Reroute'};
const controlModes = ['fixed', 'increment', 'decrement', 'randomize'];

bool isGraphFormat(dynamic obj) => obj is Map && obj['nodes'] is List;

bool isApiFormat(dynamic obj) {
  if (obj is! Map || obj.isEmpty) return false;
  return obj.values.every((v) => v is Map && v['class_type'] is String);
}

/* ---------- widget slots from object_info ---------- */

class SubSlot {
  final String key;
  final List<WidgetSlot> slots;
  const SubSlot(this.key, this.slots);
}

class WidgetSlot {
  final String name;
  final String kind; // combo | boolean | number | text | raw | autogrow | group
  final String? label;
  final List<String>? options;
  final num? min;
  final num? max;
  final num? step;
  final bool multiline;
  final bool intOnly;
  final bool control;
  final dynamic defaultValue;
  final List<SubSlot>? sub;
  const WidgetSlot({
    required this.name,
    required this.kind,
    this.label,
    this.options,
    this.min,
    this.max,
    this.step,
    this.multiline = false,
    this.intOnly = false,
    this.control = false,
    this.defaultValue,
    this.sub,
  });

  WidgetSlot withLabel(String? l) => WidgetSlot(
        name: name,
        kind: kind,
        label: l,
        options: options,
        min: min,
        max: max,
        step: step,
        multiline: multiline,
        intOnly: intOnly,
        control: control,
        defaultValue: defaultValue,
        sub: sub,
      );
}

/* Widget-capable ComfyType types that have a widget UI in the frontend even
   though they aren't primitive inputs. */
const _rawWidgetTypes = {
  'COLOR',
  'COLORS',
  'BOUNDING_BOX',
  'BOUNDING_BOXES',
  'IMAGECOMPARE',
  'CURVE',
  'COMPOSITOR',
  'PAINTER',
  'GALLERIA',
  'CHART',
  'MARKDOWN',
  'TEXTAREA',
  'RANGE',
  'VIDEO_EDIT',
  'RESOLUTION_PREVIEW',
  'AUDIO_RECORD',
  'LOAD_3D',
};

Map<String, dynamic> _opts(List<dynamic> spec) =>
    (spec.length > 1 && spec[1] is Map)
        ? Map<String, dynamic>.from(spec[1] as Map)
        : <String, dynamic>{};

String? _labelOf(Map<String, dynamic> o) =>
    o['display_name'] == null ? null : '${o['display_name']}';

List<String>? _comboOptions(dynamic type, Map<String, dynamic> o) {
  if (type == 'COMBO') {
    final options = o['options'];
    return options is List ? options.map((e) => '$e').toList() : <String>[];
  }
  if (type is List) return type.map((e) => '$e').toList();
  return null;
}

List<WidgetSlot> _subSlots(dynamic inputs) {
  final out = <WidgetSlot>[];
  if (inputs is! Map) return out;
  for (final section in ['required', 'optional']) {
    final group = inputs[section];
    if (group is! Map) continue;
    for (final entry in group.entries) {
      final spec = entry.value;
      if (spec is! List) continue;
      final slot = slotFor('${entry.key}', spec);
      if (slot != null) out.add(slot);
    }
  }
  return out;
}

WidgetSlot? slotFor(String name, List<dynamic> spec) {
  final o = _opts(spec);
  if (o['forceInput'] == true) return null;
  final rawType = spec.isEmpty ? null : spec[0];
  if (rawType == 'COMFY_AUTOGROW_V3') {
    return WidgetSlot(name: name, kind: 'autogrow', label: _labelOf(o));
  }
  if (rawType == 'COMFY_DYNAMICGROUP_V3') {
    final label = o['group_name'] ?? o['display_name'];
    return WidgetSlot(
        name: name, kind: 'group', label: label == null ? null : '$label');
  }
  if (rawType == 'COMFY_DYNAMICCOMBO_V3') {
    final options = (o['options'] is List)
        ? (o['options'] as List).whereType<Map>().toList()
        : const <Map>[];
    return WidgetSlot(
      name: name,
      kind: 'combo',
      label: _labelOf(o),
      options: [for (final x in options) '${x['key']}'],
      sub: [
        for (final x in options) SubSlot('${x['key']}', _subSlots(x['inputs'])),
      ],
    );
  }
  // widgetType picks the widget class when the raw type isn't usable directly
  // (multi-type specs like "FLOAT,INT" or STRING with a custom widget).
  final type = o['widgetType'] ?? rawType;
  final opts = _comboOptions(type, o);
  if (opts != null) {
    return WidgetSlot(
        name: name,
        kind: 'combo',
        label: _labelOf(o),
        options: opts,
        defaultValue: o['default']);
  }
  if (type == 'BOOLEAN') {
    return WidgetSlot(
        name: name,
        kind: 'boolean',
        label: _labelOf(o),
        defaultValue: o['default'] == true);
  }
  if (type == 'INT' || type == 'FLOAT') {
    return WidgetSlot(
      name: name,
      kind: 'number',
      label: _labelOf(o),
      min: o['min'] is num ? o['min'] as num : null,
      max: o['max'] is num ? o['max'] as num : null,
      step: o['step'] is num ? o['step'] as num : (type == 'INT' ? 1 : 0.1),
      intOnly: type == 'INT',
      control: o['control_after_generate'] == true,
      defaultValue: o['default'] ?? 0,
    );
  }
  if (type == 'STRING') {
    return WidgetSlot(
        name: name,
        kind: 'text',
        label: _labelOf(o),
        multiline: o['multiline'] == true,
        defaultValue: o['default'] ?? '');
  }
  if (_rawWidgetTypes.contains(type)) {
    return WidgetSlot(
        name: name,
        kind: 'raw',
        label: _labelOf(o),
        defaultValue: o['default']);
  }
  return null;
}

/* Widget-capable inputs follow the frontend's rules: forceInput stays a
   socket, socket-only types (IMAGE, MODEL, …) are not widgets, files use a
   combo spec with image_upload. */
List<WidgetSlot> widgetSlots(Map<String, dynamic>? classDef) {
  final slots = <WidgetSlot>[];
  final input = classDef?['input'];
  if (input is! Map) return slots;
  for (final section in ['required', 'optional']) {
    final group = input[section];
    if (group is! Map) continue;
    for (final entry in group.entries) {
      final spec = entry.value;
      if (spec is! List) continue;
      final slot = slotFor('${entry.key}', spec);
      if (slot != null) slots.add(slot);
    }
  }
  return slots;
}

bool isImageLike(String name, dynamic value) {
  if (name == 'image') return true;
  return value is String &&
      RegExp(r'\.(png|jpe?g|webp|mp4|webm|mov|mkv)$', caseSensitive: false)
          .hasMatch(value);
}

/* Subgraph nodes expose their boundary inputs as widgets. The widget spec
   comes from the inner input each boundary feeds; dotted names descend through
   the dynamic-combo options tree. */
List<dynamic>? _findInputSpec(dynamic classDef, String name) {
  final parts = name.split('.');
  dynamic dict = classDef is Map ? classDef['input'] : null;
  List<dynamic>? spec;
  for (var i = 0; i < parts.length; i++) {
    dynamic found;
    if (dict is Map) {
      found = (dict['required'] is Map
              ? (dict['required'] as Map)[parts[i]]
              : null) ??
          (dict['optional'] is Map
              ? (dict['optional'] as Map)[parts[i]]
              : null);
    }
    if (found is! List) return null;
    spec = found;
    if (i + 1 < parts.length) {
      Map? next;
      final options = (found.length > 1 && found[1] is Map)
          ? (found[1] as Map)['options']
          : null;
      if (options is List) {
        for (final o in options) {
          if (o is! Map) continue;
          final inputs = o['inputs'];
          if (inputs is! Map) continue;
          final has = (inputs['required'] is Map &&
                  (inputs['required'] as Map).containsKey(parts[i + 1])) ||
              (inputs['optional'] is Map &&
                  (inputs['optional'] as Map).containsKey(parts[i + 1]));
          if (has) {
            next = inputs;
            break;
          }
        }
      }
      if (next == null) return null;
      dict = next;
    }
  }
  return spec;
}

List<WidgetSlot> subgraphWidgetSlots(Map<String, dynamic> sub,
    Map<String, dynamic> objectInfo, GraphNode? node) {
  final inputNode = sub['inputNode'];
  final inputId = (inputNode is Map && inputNode['id'] is num)
      ? (inputNode['id'] as num).toInt()
      : -10;
  final innerById = <int, Map<String, dynamic>>{};
  for (final n in (sub['nodes'] as List? ?? [])) {
    if (n is Map && n['id'] is num) {
      innerById[(n['id'] as num).toInt()] = Map<String, dynamic>.from(n);
    }
  }
  final boundaries = (sub['inputs'] as List? ?? []).whereType<Map>().toList();
  final subLinks = (sub['links'] as List? ?? []).whereType<Map>().toList();
  final out = <WidgetSlot>[];
  for (var i = 0; i < boundaries.length; i++) {
    final boundary = Map<String, dynamic>.from(boundaries[i]);
    final name = '${boundary['name']}';
    // The placeholder marks each input that is a widget with a widget ref;
    // entries without one are plain sockets. Old graphs list no entries at
    // all and fall back to type classification.
    Map? entry;
    for (final inp in node?.inputs ?? const []) {
      if (inp is Map && '${inp['name']}' == name) {
        entry = inp;
        break;
      }
    }
    if (entry != null && entry['widget'] is! Map) continue;
    Map? link;
    for (final l in subLinks) {
      if (l['origin_id'] == inputId && l['origin_slot'] == i) {
        link = l;
        break;
      }
    }
    Map<String, dynamic>? target;
    Map? innerInput;
    if (link != null && link['target_id'] is num) {
      target = innerById[(link['target_id'] as num).toInt()];
      final ins = target?['inputs'];
      final slot = link['target_slot'];
      if (ins is List && slot is num) {
        final idx = slot.toInt();
        if (idx >= 0 && idx < ins.length && ins[idx] is Map) {
          innerInput = ins[idx] as Map;
        }
      }
    }
    final spec = (target != null && innerInput != null)
        ? _findInputSpec(
            objectInfo['${target['type']}'], '${innerInput['name']}')
        : null;
    // Boundaries can feed inner sockets (switch branches, prompt inputs); the
    // boundary's own declared type still decides whether it has a widget.
    var slot = (spec != null) ? slotFor(name, spec) : null;
    slot ??= slotFor(name, <dynamic>[boundary['type'], <String, dynamic>{}]);
    if (slot == null) continue;
    final boundaryLabel = boundary['label'];
    slot = slot.withLabel((boundaryLabel != null && '$boundaryLabel'.isNotEmpty)
        ? '$boundaryLabel'
        : (slot.label ?? name));
    out.add(slot);
  }
  return out;
}

/* ---------- widget serialization order ---------- */

class ResolvedWidget {
  final WidgetSlot slot;
  final int index;
  final String key;
  const ResolvedWidget(this.slot, this.index, this.key);
}

class ResolvedWidgets {
  final List<ResolvedWidget> items;
  final String control;
  final int controlIndex;
  const ResolvedWidgets(this.items, this.control, this.controlIndex);
}

SubSlot? _optionFor(WidgetSlot slot, String key) {
  for (final s in slot.sub ?? const <SubSlot>[]) {
    if (s.key == key) return s;
  }
  return null;
}

/* Mirror the frontend's widgets_values layout: widget values are positional,
   dynamic-combo sub-widgets (dotted names) follow their combo recursively,
   widgets flagged control_after_generate consume an extra value right after
   them. Falls back to the legacy trailing control value written by older app
   versions (also used by PrimitiveX nodes for their "fixed" toggle). */
ResolvedWidgets resolveWidgets(GraphNode node, List<WidgetSlot> slots) {
  final raw = node.widgetsValues is List
      ? List<dynamic>.from(node.widgetsValues as List)
      : <dynamic>[];
  final items = <ResolvedWidget>[];
  var i = 0;
  String? control;
  var controlIndex = -1;

  int take() => i < raw.length ? i++ : -1;

  void walk(WidgetSlot slot, String prefix) {
    final key = prefix.isEmpty ? slot.name : '$prefix.${slot.name}';
    if (slot.kind == 'autogrow' || slot.kind == 'group') {
      items.add(ResolvedWidget(slot, -1, key));
      return;
    }
    if (slot.sub != null) {
      final index = take();
      items.add(ResolvedWidget(slot, index, key));
      final selected = index >= 0 ? '${raw[index]}' : '';
      final option = _optionFor(slot, selected);
      for (final sub in option?.slots ?? const <WidgetSlot>[]) {
        walk(sub, key);
      }
      return;
    }
    items.add(ResolvedWidget(slot, take(), key));
    if (slot.control &&
        i < raw.length &&
        (raw[i] == null ||
            (raw[i] is String && controlModes.contains(raw[i])))) {
      control = raw[i] is String ? raw[i] as String : 'fixed';
      controlIndex = i++;
    }
  }

  for (final slot in slots) {
    walk(slot, '');
  }
  final hasSeed =
      slots.any((s) => s.control || s.name == 'seed' || s.name == 'noise_seed');
  final hasTail = hasSeed || node.type.startsWith('Primitive');
  if (hasTail &&
      control == null &&
      controlIndex < 0 &&
      i < raw.length &&
      raw.length == items.length + 1 &&
      (raw[i] == null || (raw[i] is String && controlModes.contains(raw[i])))) {
    control = raw[i] is String ? raw[i] as String : 'fixed';
    controlIndex = i;
  }
  return ResolvedWidgets(items, control ?? 'fixed', controlIndex);
}

/* Positional span of a dynamic-combo option subtree given the current raw
   values after the combo (selected nested options follow their stored keys). */
int dynamicSpan(WidgetSlot slot, String key, List<dynamic> raw, int start) {
  final option = _optionFor(slot, key);
  var j = start;
  for (final sub in option?.slots ?? const <WidgetSlot>[]) {
    if (sub.sub != null) {
      final k = j < raw.length ? '${raw[j] ?? ''}' : '';
      j += 1 + dynamicSpan(sub, k, raw, j + 1);
    } else {
      j += 1;
    }
  }
  return j - start;
}

dynamic _leafDefault(WidgetSlot s) =>
    s.defaultValue ??
    (s.kind == 'boolean'
        ? false
        : s.kind == 'combo'
            ? (s.options?.isNotEmpty == true ? s.options!.first : '')
            : (s.kind == 'text' || s.kind == 'raw' ? '' : 0));

/* Positional values an option contributes when freshly selected (nested combos
   fall back to their first option). */
List<dynamic> dynamicDefaults(WidgetSlot slot, String key) {
  final option = _optionFor(slot, key);
  final out = <dynamic>[];
  for (final sub in option?.slots ?? const <WidgetSlot>[]) {
    if (sub.sub != null) {
      final k = (sub.options?.isNotEmpty == true) ? sub.options!.first : '';
      out.add(k);
      out.addAll(dynamicDefaults(sub, k));
    } else {
      out.add(_leafDefault(sub));
    }
  }
  return out;
}

/* Same as dynamicDefaults but keyed by dotted name, for widgets_values_named. */
Map<String, dynamic> dynamicNamedDefaults(WidgetSlot slot, String key,
    [String prefix = '']) {
  final out = <String, dynamic>{};
  final option = _optionFor(slot, key);
  for (final sub in option?.slots ?? const <WidgetSlot>[]) {
    final k = prefix.isEmpty ? sub.name : '$prefix.${sub.name}';
    if (sub.sub != null) {
      final first = (sub.options?.isNotEmpty == true) ? sub.options!.first : '';
      out[k] = first;
      out.addAll(dynamicNamedDefaults(sub, first, k));
    } else {
      out[k] = _leafDefault(sub);
    }
  }
  return out;
}

class PositionalMap {
  final Map<String, dynamic> values;
  final String control;
  final List<Map<String, dynamic>> loras;
  const PositionalMap(this.values, this.control, this.loras);
}

/* Positional values → per-slot values, following the original mapping rules:
   linked widgets still consume their positional value (a link overrides it at
   build time); LoRA-stack dicts are detected by shape. */
PositionalMap mapPositional(GraphNode node, List<WidgetSlot> slots) {
  final raw = node.widgetsValues is List
      ? List<dynamic>.from(node.widgetsValues as List)
      : <dynamic>[];
  final values = <String, dynamic>{};
  final loras = <Map<String, dynamic>>[];
  final resolved = resolveWidgets(node, slots);
  for (final item in resolved.items) {
    if (item.index < 0) continue;
    final v = raw[item.index];
    if (v is Map && v['lora'] is String && '${v['lora']}'.isNotEmpty) {
      loras.add({
        'on': v['on'] == true,
        'lora': '${v['lora']}',
        'strength':
            (v['strength'] is num) ? (v['strength'] as num).toDouble() : 0.0,
        if (v['strengthTwo'] != null) 'strengthTwo': v['strengthTwo'],
      });
      continue;
    }
    values[item.key] = v;
  }
  return PositionalMap(values, resolved.control, loras);
}

/* All dotted names a slot tree can produce, including every dynamic-combo
   option (the graph itself says which one is selected). */
Set<String> _possibleNames(List<WidgetSlot> slots) {
  final names = <String>{};
  void walk(WidgetSlot slot, String prefix) {
    final key = prefix.isEmpty ? slot.name : '$prefix.${slot.name}';
    names.add(key);
    for (final o in slot.sub ?? const <SubSlot>[]) {
      for (final sub in o.slots) {
        walk(sub, key);
      }
    }
  }

  for (final s in slots) {
    walk(s, '');
  }
  return names;
}

Map<String, dynamic> namedValues(GraphNode node, List<WidgetSlot> slots) {
  final out = <String, dynamic>{};
  final rec = node.widgetsValuesNamed ?? const <String, dynamic>{};
  final names = _possibleNames(slots);
  for (final e in rec.entries) {
    if (RegExp(r'^videopreview', caseSensitive: false).hasMatch(e.key)) {
      continue;
    }
    if (names.contains(e.key)) out[e.key] = e.value;
  }
  final wv = node.widgetsValues;
  if (wv is Map) {
    for (final e in wv.entries) {
      final k = '${e.key}';
      if (RegExp(r'^videopreview', caseSensitive: false).hasMatch(k)) continue;
      if (names.contains(k) && !out.containsKey(k)) out[k] = e.value;
    }
  }
  return out;
}

/* ---------- prompt building ---------- */

class BuildError {
  final dynamic nodeId;
  final String message;
  const BuildError(this.nodeId, this.message);
}

class BuildResult {
  final Map<String, dynamic> prompt;
  final List<BuildError> errors;
  const BuildResult(this.prompt, this.errors);
}

int? _intOf(dynamic v) =>
    v is num ? v.toInt() : int.tryParse(v == null ? '' : '$v');

BuildResult buildPrompt(
    Graph wf, Set<String> bypassed, Map<String, dynamic>? objectInfo) {
  final errors = <BuildError>[];
  final prompt = <String, dynamic>{};
  final linkById = <int, dynamic>{};
  for (final l in wf.links) {
    final id = (l is List && l.isNotEmpty) ? _intOf(l[0]) : null;
    if (id != null) linkById[id] = l;
  }

  var maxId = 0;
  for (final n in wf.nodes) {
    final v = _intOf(n.id) ?? 0;
    if (v > maxId) maxId = v;
  }
  var nextId = maxId + 1;

  final subgraphs = <String, Map<String, dynamic>>{};
  for (final s in wf.subgraphs ?? []) {
    if (s is Map && s['id'] != null) {
      subgraphs['${s['id']}'] = Map<String, dynamic>.from(s);
    }
  }

  void emit(String id, String classType, Map<String, dynamic> inputs) {
    prompt[id] = {'class_type': classType, 'inputs': inputs};
  }

  // litegraph slot type matching (LiteGraph.isValidConnection)
  bool isValidConn(dynamic a, dynamic b) {
    if (a == b) return true;
    if (a == null || b == null || a == '' || b == '') return false;
    for (final x in '$a'.split(',')) {
      for (final y in '$b'.split(',')) {
        if (x == y || x == '*' || y == '*') return true;
      }
    }
    return false;
  }

  // frontend ExecutableNodeDTO._getBypassSlotIndex: which input a bypassed
  // node forwards to for output slot given the consumer's type
  int bypassSlotIndex(GraphNode n, int slot, dynamic type) {
    final ins = n.inputs ?? const <dynamic>[];
    if (type == '*' || type == '') {
      return ins.length > slot ? slot : 0;
    }
    final outs = n.outputs ?? const <dynamic>[];
    final outputType = (slot < outs.length && outs[slot] is Map)
        ? (outs[slot] as Map)['type']
        : null;
    if (slot < ins.length && ins[slot] is Map) {
      final opposite = ins[slot] as Map;
      if (isValidConn(opposite['type'], outputType) &&
          isValidConn(opposite['type'], type)) {
        return slot;
      }
    }
    for (var i = 0; i < ins.length; i++) {
      if (ins[i] is Map && (ins[i] as Map)['type'] == type) return i;
    }
    for (var i = 0; i < ins.length; i++) {
      final t = ins[i] is Map ? (ins[i] as Map)['type'] : null;
      if (isValidConn(t, outputType) && isValidConn(t, type)) return i;
    }
    return -1;
  }

  final nodeMap = <String, GraphNode>{};
  for (final n in wf.nodes) {
    nodeMap[n.key] = n;
  }

  // follow Reroute/PrimitiveNode chains and bypassed/muted nodes back to the
  // source; returns [nodeId, slot], a widget value, or null when the
  // connection is dropped (muted node or bypass without a matching input)
  dynamic resolveReroute(dynamic startId, int slot, dynamic type) {
    GraphNode? cur = nodeMap['$startId'];
    var curSlot = slot;
    dynamic curType = type;
    for (var depth = 0; depth < 64 && cur != null; depth++) {
      if (cur.mode == 2) return null;
      if (cur.mode == 4) {
        final idx = bypassSlotIndex(cur, curSlot, curType);
        if (idx < 0) return null;
        final ins = cur.inputs ?? const <dynamic>[];
        if (idx >= ins.length || ins[idx] is! Map) return null;
        final bin = ins[idx] as Map;
        if (bin['link'] == null) return null;
        final bl = linkById[_intOf(bin['link'])];
        if (bl == null) return null;
        cur = nodeMap['${bl[1]}'];
        curSlot = _intOf(bl[2]) ?? 0;
        curType = bin['type'];
        continue;
      }
      if (!rerouteTypes.contains(cur.type) && cur.type != 'PrimitiveNode') {
        break;
      }
      Map? inp;
      for (final i in cur.inputs ?? const <dynamic>[]) {
        if (i is Map && i['link'] != null) {
          inp = i;
          break;
        }
      }
      if (inp == null || inp['link'] == null) {
        final vals = cur.widgetsValues is List
            ? List<dynamic>.from(cur.widgetsValues as List)
            : <dynamic>[];
        return vals.isNotEmpty ? vals[0] : null;
      }
      final link = linkById[_intOf(inp['link'])];
      if (link == null) return null;
      cur = nodeMap['${link[1]}'];
      curSlot = _intOf(link[2]) ?? 0;
    }
    if (cur == null || cur.mode == 2) return null;
    return ['${cur.id}', curSlot];
  }

  void applySeedControl(Map<String, dynamic> inputs) {
    for (final key in ['seed', 'noise_seed']) {
      if (!inputs.containsKey(key)) continue;
      final ctrl = inputs['control_after_generate'];
      inputs.remove('control_after_generate');
      final base = _intOf(inputs[key]) ?? 0;
      if (ctrl == 'randomize') {
        inputs[key] = DateTime.now().millisecondsSinceEpoch % 1125899906842528;
      } else if (ctrl == 'increment') {
        inputs[key] = base + 1;
      } else if (ctrl == 'decrement') {
        inputs[key] = base > 0 ? base - 1 : 0;
      }
    }
  }

  bool isOff(GraphNode n) =>
      n.mode == 2 ||
      n.mode == 4 ||
      bypassed.contains(n.id) ||
      bypassed.contains('${n.id}');

  /* Phase 1 — expand subgraph placeholders (single level), record redirects
     from placeholder outputs to the inner nodes driving each boundary output. */
  final redirect = <String, List<dynamic>>{};
  final redirectVal = <String, dynamic>{};

  dynamic resolveLink(dynamic srcId, int srcSlot, [dynamic type]) {
    final r = resolveReroute(srcId, srcSlot, type);
    if (r is List && r.length == 2) {
      final pushKey = '${r[0]}:${r[1]}';
      if (redirect.containsKey(pushKey)) return redirect[pushKey];
      if (redirectVal.containsKey(pushKey)) return redirectVal[pushKey];
    }
    return r;
  }

  final contexts = <_SubCtx>[];
  for (final node in wf.nodes) {
    if (isOff(node) || !subgraphs.containsKey(node.type)) continue;
    final sub = subgraphs[node.type]!;
    final innerNodes = (sub['nodes'] as List? ?? []).whereType<Map>().toList();
    for (final inner in innerNodes) {
      final mode = inner['mode'];
      if (mode == 2 || mode == 4) continue;
      final type = '${inner['type']}';
      if (subgraphs.containsKey(type)) {
        errors.add(BuildError(node.id, 'Nested subgraphs are not supported'));
      } else if (!noteTypes.contains(type) &&
          !rerouteTypes.contains(type) &&
          type != 'PrimitiveNode' &&
          objectInfo != null &&
          !objectInfo.containsKey(type) &&
          ((_intOf(inner['id']) ?? -1) >= 0)) {
        errors.add(BuildError(node.id, 'Unknown node type in subgraph: $type'));
      }
    }
    final idMap = <int, String>{};
    final innerById = <int, Map<String, dynamic>>{};
    for (final inner in innerNodes) {
      final id = _intOf(inner['id']);
      if (id == null || id == -10 || id == -20) continue;
      innerById[id] = Map<String, dynamic>.from(inner);
      idMap[id] = '${nextId++}';
    }
    final inputNode = sub['inputNode'];
    contexts.add(_SubCtx(
      node: node,
      sub: sub,
      idMap: idMap,
      innerById: innerById,
      inputId: (inputNode is Map && inputNode['id'] is num)
          ? (inputNode['id'] as num).toInt()
          : -10,
    ));
  }

  // follow inner Reroute/PrimitiveNode chains and bypassed nodes back to a
  // source; boundary inputs resolve to the placeholder's widget value
  dynamic Function(int, int, dynamic) resolveInnerOf(_SubCtx ctx) {
    final sub = ctx.sub;
    final subLinks = (sub['links'] as List? ?? []).whereType<Map>().toList();
    final boundaries = (sub['inputs'] as List? ?? []).whereType<Map>().toList();

    dynamic fromBoundary(int slot) {
      if (slot < 0 || slot >= boundaries.length) return null;
      final bIn = boundaries[slot];
      return ctx.phInputs.containsKey('${bIn['name']}')
          ? ctx.phInputs['${bIn['name']}']
          : null;
    }

    return (int originId, int originSlot, dynamic type) {
      var oid = originId;
      var oslot = originSlot;
      dynamic otype = type;
      for (var depth = 0; depth < 64; depth++) {
        final on = ctx.innerById[oid];
        if (on == null) return null;
        if (on['mode'] == 2) return null;
        if (on['mode'] == 4) {
          final idx = bypassSlotIndex(GraphNode.fromJson(on), oslot, otype);
          if (idx < 0) return null;
          final ins = (on['inputs'] as List? ?? []).whereType<Map>().toList();
          if (idx >= ins.length) return null;
          final bin = ins[idx];
          if (bin['link'] == null) return null;
          Map? bl;
          for (final x in subLinks) {
            if (x['id'] == bin['link']) {
              bl = x;
              break;
            }
          }
          if (bl == null) return null;
          if (bl['origin_id'] == ctx.inputId) {
            return fromBoundary(_intOf(bl['origin_slot']) ?? 0);
          }
          oid = _intOf(bl['origin_id']) ?? -999;
          oslot = _intOf(bl['origin_slot']) ?? 0;
          otype = bin['type'];
          continue;
        }
        if (on['type'] == 'PrimitiveNode') {
          final vals = on['widgets_values'];
          return (vals is List && vals.isNotEmpty) ? vals[0] : null;
        }
        if (!rerouteTypes.contains('${on['type']}')) {
          final mapped = ctx.idMap[oid];
          return mapped == null ? null : [mapped, oslot];
        }
        Map? rin;
        for (final x in (on['inputs'] as List? ?? [])) {
          if (x is Map && x['link'] != null) {
            rin = x;
            break;
          }
        }
        if (rin == null || rin['link'] == null) {
          final vals = on['widgets_values'];
          return (vals is List && vals.isNotEmpty) ? vals[0] : null;
        }
        Map? rl;
        for (final x in subLinks) {
          if (x['id'] == rin['link']) {
            rl = x;
            break;
          }
        }
        if (rl == null) return null;
        if (rl['origin_id'] == ctx.inputId) {
          return fromBoundary(_intOf(rl['origin_slot']) ?? 0);
        }
        oid = _intOf(rl['origin_id']) ?? -999;
        oslot = _intOf(rl['origin_slot']) ?? 0;
      }
      return null;
    };
  }

  // placeholder boundary values: positional from widgets_values, overridden
  // by outer links / named values. Rounds let chained subgraph instances
  // resolve each other's boundary outputs regardless of node order.
  for (var round = 0; round < 4; round++) {
    var changed = false;
    for (final ctx in contexts) {
      final node = ctx.node;
      final sub = ctx.sub;
      final before = ctx.phInputs.length;
      final phVals = node.widgetsValues is List
          ? List<dynamic>.from(node.widgetsValues as List)
          : <dynamic>[];
      final named = node.widgetsValuesNamed ?? const <String, dynamic>{};
      final namedRec = node.widgetsValues is Map
          ? Map<String, dynamic>.from(node.widgetsValues as Map)
          : <String, dynamic>{};
      final slots = subgraphWidgetSlots(sub, objectInfo ?? const {}, node);
      for (final item in resolveWidgets(node, slots).items) {
        // named values are authoritative; positional is the legacy fallback
        if (named.containsKey(item.key) || namedRec.containsKey(item.key)) {
          ctx.phInputs[item.slot.name] = named.containsKey(item.key)
              ? named[item.key]
              : namedRec[item.key];
        } else if (item.index >= 0 &&
            item.index < phVals.length &&
            phVals[item.index] != null) {
          ctx.phInputs[item.slot.name] = phVals[item.index];
        }
      }
      final boundaries =
          (sub['inputs'] as List? ?? []).whereType<Map>().toList();
      for (final inp in node.inputs ?? const <dynamic>[]) {
        if (inp is! Map) continue;
        Map? bIn;
        for (final b in boundaries) {
          if ('${b['name']}' == '${inp['name']}') {
            bIn = b;
            break;
          }
        }
        if (bIn == null) continue;
        final bName = '${bIn['name']}';
        if (inp['link'] != null) {
          final link = linkById[_intOf(inp['link'])];
          if (link != null) {
            final v = resolveLink(link[1], _intOf(link[2]) ?? 0, bIn['type']);
            if (v != null) ctx.phInputs[bName] = v;
          }
        } else if (inp['widget'] is Map && !ctx.phInputs.containsKey(bName)) {
          final wname = '${(inp['widget'] as Map)['name']}';
          if (named.containsKey(wname) || namedRec.containsKey(wname)) {
            ctx.phInputs[bName] =
                named.containsKey(wname) ? named[wname] : namedRec[wname];
          }
        }
      }
      if (ctx.phInputs.length != before) changed = true;
      // boundary outputs: sub link into -20 with target_slot = placeholder
      // output slot
      final resolveInner = resolveInnerOf(ctx);
      final outNames = (node.outputs ?? const <dynamic>[])
          .whereType<Map>()
          .map((o) => '${o['name'] ?? ''}')
          .toList();
      for (final sl in (sub['links'] as List? ?? []).whereType<Map>()) {
        if (sl['target_id'] != -20) continue;
        final targetSlot = _intOf(sl['target_slot']) ?? 0;
        final outType = (node.outputs != null &&
                targetSlot < node.outputs!.length &&
                node.outputs![targetSlot] is Map)
            ? (node.outputs![targetSlot] as Map)['type']
            : null;
        final src = resolveInner(_intOf(sl['origin_id']) ?? -999,
            _intOf(sl['origin_slot']) ?? 0, outType);
        final keys = [
          '${node.id}:$targetSlot',
          if (targetSlot < outNames.length)
            '${node.id}:${outNames[targetSlot]}',
        ];
        if (src is List && src.length == 2) {
          ctx.unresolved.remove(targetSlot);
          for (final k in keys) {
            redirect[k] = src;
          }
        } else if (src != null) {
          ctx.unresolved.remove(targetSlot);
          for (final k in keys) {
            redirectVal[k] = src;
          }
        } else {
          ctx.unresolved.add(targetSlot);
        }
      }
    }
    if (!changed) break;
  }
  for (final ctx in contexts) {
    for (final slot in ctx.unresolved) {
      errors
          .add(BuildError(ctx.node.id, 'Subgraph output $slot has no source'));
    }
  }

  // emit the inner nodes of every expanded instance
  for (final ctx in contexts) {
    final sub = ctx.sub;
    final resolveInner = resolveInnerOf(ctx);
    final boundaries = (sub['inputs'] as List? ?? []).whereType<Map>().toList();
    final subLinks = (sub['links'] as List? ?? []).whereType<Map>().toList();
    for (final inner in (sub['nodes'] as List? ?? []).whereType<Map>()) {
      final innerId = _intOf(inner['id']);
      if (innerId == null || innerId == -10 || innerId == -20) continue;
      if (inner['mode'] == 2 || inner['mode'] == 4) continue;
      final type = '${inner['type']}';
      if (noteTypes.contains(type)) continue;
      if (rerouteTypes.contains(type) || type == 'PrimitiveNode') continue;
      if (subgraphs.containsKey(type)) continue; // nested, reported above
      final nid = ctx.idMap[innerId]!;
      final inputs = <String, dynamic>{};
      final innerDef = (objectInfo != null && objectInfo[type] is Map)
          ? Map<String, dynamic>.from(objectInfo[type] as Map)
          : null;
      final innerSlots = widgetSlots(innerDef);
      final named = inner['widgets_values_named'] is Map
          ? Map<String, dynamic>.from(inner['widgets_values_named'] as Map)
          : const <String, dynamic>{};
      final innerCtrl = named['control_after_generate'];
      final innerNode = GraphNode.fromJson(Map<String, dynamic>.from(inner));
      if (inner['widgets_values'] is List) {
        final pm = mapPositional(innerNode, innerSlots);
        inputs.addAll(pm.values);
        final ctrl = innerCtrl is String ? innerCtrl : pm.control;
        if (ctrl != 'fixed' &&
            (inputs.containsKey('seed') || inputs.containsKey('noise_seed'))) {
          inputs['control_after_generate'] = ctrl;
        }
        for (var i = 0; i < pm.loras.length; i++) {
          final l = pm.loras[i];
          if (l['on'] == true && '${l['lora']}'.isNotEmpty) {
            inputs['lora_${i + 1}'] = {
              'on': true,
              'lora': l['lora'],
              'strength': l['strength'],
            };
          }
        }
      }
      // named values are authoritative; positional is the legacy fallback
      inputs.addAll(namedValues(innerNode, innerSlots));
      if (inner['widgets_values'] is! List &&
          innerCtrl is String &&
          innerCtrl != 'fixed' &&
          (inputs.containsKey('seed') || inputs.containsKey('noise_seed'))) {
        inputs['control_after_generate'] = innerCtrl;
      }
      for (final inp in (inner['inputs'] as List? ?? []).whereType<Map>()) {
        if (inp['link'] == null) continue;
        Map? sl;
        for (final x in subLinks) {
          if (x['id'] == inp['link']) {
            sl = x;
            break;
          }
        }
        if (sl == null) continue;
        if (sl['origin_id'] == ctx.inputId) {
          Map? bIn;
          final oSlot = _intOf(sl['origin_slot']) ?? 0;
          if (oSlot >= 0 && oSlot < boundaries.length) {
            bIn = boundaries[oSlot];
          } else {
            for (final b in boundaries) {
              final ids = b['linkIds'];
              if (ids is List && ids.contains(sl['id'])) {
                bIn = b;
                break;
              }
            }
          }
          if (bIn != null && ctx.phInputs.containsKey('${bIn['name']}')) {
            inputs['${inp['name']}'] = ctx.phInputs['${bIn['name']}'];
          }
        } else {
          final src = resolveInner(_intOf(sl['origin_id']) ?? -999,
              _intOf(sl['origin_slot']) ?? 0, inp['type']);
          if (src != null) inputs['${inp['name']}'] = src;
        }
      }
      applySeedControl(inputs);
      emit(nid, type, inputs);
    }
  }

  /* Phase 2 — regular nodes. */
  for (final node in wf.nodes) {
    if (isOff(node)) continue;
    if (noteTypes.contains(node.type)) continue;
    if (rerouteTypes.contains(node.type) || node.type == 'PrimitiveNode') {
      continue;
    }
    if (subgraphs.containsKey(node.type)) continue;

    final classDef = (objectInfo != null && objectInfo[node.type] is Map)
        ? Map<String, dynamic>.from(objectInfo[node.type] as Map)
        : null;
    final slots = widgetSlots(classDef);
    final inputs = <String, dynamic>{};
    final namedCtrl = (node.widgetsValuesNamed ??
        const <String, dynamic>{})['control_after_generate'];
    if (node.widgetsValues is List) {
      final pm = mapPositional(node, slots);
      inputs.addAll(pm.values);
      final ctrl = namedCtrl is String ? namedCtrl : pm.control;
      if (ctrl != 'fixed' &&
          (inputs.containsKey('seed') || inputs.containsKey('noise_seed'))) {
        inputs['control_after_generate'] = ctrl;
      }
      for (var i = 0; i < pm.loras.length; i++) {
        final l = pm.loras[i];
        if (l['on'] == true && '${l['lora']}'.isNotEmpty) {
          inputs['lora_${i + 1}'] = {
            'on': true,
            'lora': l['lora'],
            'strength': l['strength'],
          };
        }
      }
    }
    // named values are authoritative; positional is the legacy fallback
    inputs.addAll(namedValues(node, slots));
    if (node.widgetsValues is! List &&
        namedCtrl is String &&
        namedCtrl != 'fixed' &&
        (inputs.containsKey('seed') || inputs.containsKey('noise_seed'))) {
      inputs['control_after_generate'] = namedCtrl;
    }
    for (final inp in node.inputs ?? const <dynamic>[]) {
      if (inp is! Map || inp['link'] == null) continue;
      final link = linkById[_intOf(inp['link'])];
      if (link == null) continue;
      final resolved = resolveLink(link[1], _intOf(link[2]) ?? 0, inp['type']);
      if (resolved != null) inputs['${inp['name']}'] = resolved;
    }
    applySeedControl(inputs);
    emit('${node.id}', node.type, inputs);
  }

  // frontend parity: drop inputs whose source node was not emitted
  for (final n in prompt.values) {
    final inputs = (n as Map)['inputs'];
    if (inputs is! Map) continue;
    inputs.removeWhere((key, v) =>
        v is List &&
        v.length == 2 &&
        v[0] is String &&
        !prompt.containsKey(v[0]));
  }

  return BuildResult(prompt, errors);
}

class _SubCtx {
  final GraphNode node;
  final Map<String, dynamic> sub;
  final Map<int, String> idMap;
  final Map<int, Map<String, dynamic>> innerById;
  final int inputId;
  final Map<String, dynamic> phInputs = {};
  final Set<int> unresolved = {};
  _SubCtx({
    required this.node,
    required this.sub,
    required this.idMap,
    required this.innerById,
    required this.inputId,
  });
}

String cleanFileName(String name) {
  var n = (name.isEmpty ? 'workflow' : name)
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\.json$', caseSensitive: false), '');
  return '$n.json';
}

String fmtTimeAgo(int at) {
  final s = DateTime.now().millisecondsSinceEpoch ~/ 1000 - at;
  final v = s < 0 ? 0 : s;
  if (v < 60) return '${v}s ago';
  if (v < 3600) return '${v ~/ 60}m ago';
  if (v < 86400) return '${v ~/ 3600}h ago';
  return '${v ~/ 86400}d ago';
}
