/// Port of next-app custom-graph.ts: workflow-graph models, widget-slot
/// inference from /object_info, positional/named value mapping, and the
/// two-phase prompt builder (subgraph expansion + regular nodes with
/// reroute resolution and seed-control handling).
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
        if (widgetsValuesNamed != null) 'widgets_values_named': widgetsValuesNamed,
      };

  factory GraphNode.fromJson(Map<String, dynamic> j) => GraphNode(
        id: j['id'],
        type: '${j['type'] ?? ''}',
        title: '${j['title'] ?? ''}',
        mode: (j['mode'] is num) ? (j['mode'] as num).toInt() : null,
        inputs: (j['inputs'] is List) ? List<dynamic>.from(j['inputs']) : null,
        outputs: (j['outputs'] is List) ? List<dynamic>.from(j['outputs']) : null,
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
            : (widgetsValues is Map ? Map<String, dynamic>.from(widgetsValues) : widgetsValues),
        widgetsValuesNamed:
            widgetsValuesNamed == null ? null : Map<String, dynamic>.from(widgetsValuesNamed!),
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

bool isGraphFormat(dynamic obj) =>
    obj is Map && obj['nodes'] is List;

bool isApiFormat(dynamic obj) {
  if (obj is! Map || obj.isEmpty) return false;
  return obj.values.every((v) =>
      v is Map && v['class_type'] is String);
}

class WidgetSlot {
  final String name;
  final String kind; // combo | boolean | number | text | image | seed
  final List<String>? options;
  final num? min;
  final num? max;
  final num? step;
  final bool multiline;
  final bool intOnly;
  const WidgetSlot({
    required this.name,
    required this.kind,
    this.options,
    this.min,
    this.max,
    this.step,
    this.multiline = false,
    this.intOnly = false,
  });
}

List<String>? _comboOptions(List<dynamic> spec) {
  final t = spec[0];
  if (t is List) {
    if (t.isNotEmpty && t[0] == 'COMBO') {
      final o = (spec.length > 1 && spec[1] is Map) ? (spec[1] as Map)['options'] : null;
      return (o is List) ? o.map((e) => '$e').toList() : <String>[];
    }
    return t.map((e) => '$e').toList();
  }
  return null;
}

List<WidgetSlot> widgetSlots(Map<String, dynamic>? classDef) {
  final slots = <WidgetSlot>[];
  final input = classDef?['input'];
  if (input is! Map) return slots;
  for (final section in ['required', 'optional']) {
    final group = input[section];
    if (group is! Map) continue;
    for (final name in group.keys) {
      final spec = group[name];
      if (spec is! List || spec.isEmpty) continue;
      final opts = _comboOptions(spec);
      final o = (spec.length > 1 && spec[1] is Map)
          ? Map<String, dynamic>.from(spec[1] as Map)
          : <String, dynamic>{};
      final sname = '$name';
      if (opts != null) {
        slots.add(WidgetSlot(name: sname, kind: 'combo', options: opts));
      } else if (spec[0] == 'BOOLEAN') {
        slots.add(WidgetSlot(name: sname, kind: 'boolean'));
      } else if (spec[0] == 'INT' || spec[0] == 'FLOAT') {
        slots.add(WidgetSlot(
          name: sname,
          kind: spec[0] == 'INT' &&
                  (sname == 'seed' || sname == 'noise_seed')
              ? 'seed'
              : 'number',
          min: o['min'] is num ? o['min'] as num : null,
          max: o['max'] is num ? o['max'] as num : null,
          step: o['step'] is num
              ? o['step'] as num
              : (spec[0] == 'INT' ? 1 : 0.1),
          intOnly: spec[0] == 'INT',
        ));
      } else if (spec[0] == 'STRING') {
        slots.add(WidgetSlot(name: sname, kind: 'text', multiline: o['multiline'] == true));
      } else if (spec[0] == 'IMAGE') {
        slots.add(WidgetSlot(name: sname, kind: 'image'));
      }
    }
  }
  return slots;
}

bool isImageLike(String name, dynamic value) {
  if (name == 'image') return true;
  return value is String &&
      RegExp(r'\.(png|jpe?g|webp|mp4|webm|mov|mkv)$', caseSensitive: false).hasMatch(value);
}

class PositionalMap {
  final Map<String, dynamic> values;
  final String control;
  final List<Map<String, dynamic>> loras;
  const PositionalMap(this.values, this.control, this.loras);
}

PositionalMap mapPositional(GraphNode node, List<WidgetSlot> slots, Set<String> linkedNames) {
  final raw = (node.widgetsValues is List) ? List<dynamic>.from(node.widgetsValues) : <dynamic>[];
  final values = <String, dynamic>{};
  String? control;
  final loras = <Map<String, dynamic>>[];
  final seedIdx = slots.indexWhere((s) => s.name == 'seed' || s.name == 'noise_seed');
  if (seedIdx >= 0 && raw.length == slots.length + 1) {
    final tail = raw[slots.length];
    if (tail == null || tail is String) {
      control = tail is String ? tail : 'fixed';
      raw.removeLast();
    }
  }
  var vi = 0;
  for (final slot in slots) {
    if (linkedNames.contains(slot.name)) continue;
    final v = vi < raw.length ? raw[vi] : null;
    vi++;
    if (v is Map && v['lora'] is String && ('${v['lora']}'.isNotEmpty)) {
      loras.add({
        'on': v['on'] == true,
        'lora': '${v['lora']}',
        'strength': (v['strength'] is num) ? (v['strength'] as num).toDouble() : 0.0,
        if (v['strengthTwo'] != null) 'strengthTwo': v['strengthTwo'],
      });
      continue;
    }
    values[slot.name] = v;
  }
  return PositionalMap(values, control ?? 'fixed', loras);
}

Map<String, dynamic> namedValues(GraphNode node, List<WidgetSlot> slots) {
  final out = <String, dynamic>{};
  final names = slots.map((s) => s.name).toSet();
  final rec = node.widgetsValuesNamed ?? const {};
  for (final e in rec.entries) {
    if (RegExp(r'^videopreview', caseSensitive: false).hasMatch(e.key)) continue;
    if (names.contains(e.key)) out[e.key] = e.value;
  }
  final wv = node.widgetsValues;
  if (wv is Map) {
    for (final e in wv.entries) {
      if (RegExp(r'^videopreview', caseSensitive: false).hasMatch('${e.key}')) continue;
      if (names.contains('${e.key}') && !out.containsKey('${e.key}')) {
        out['${e.key}'] = e.value;
      }
    }
  }
  return out;
}

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

BuildResult buildPrompt(Graph wf, Set<String> bypassed, Map<String, dynamic>? objectInfo) {
  final errors = <BuildError>[];
  final prompt = <String, dynamic>{};
  final linkById = <int, dynamic>{};
  for (final l in wf.links) {
    if (l is List && l.isNotEmpty && l[0] is int) linkById[l[0] as int] = l;
  }

  var maxId = 0;
  for (final n in wf.nodes) {
    final v = n.id is num
        ? (n.id as num).toInt()
        : int.tryParse('${n.id}') ?? 0;
    if (v > maxId) maxId = v;
  }
  var nextId = maxId + 1;

  final subgraphs = <String, dynamic>{};
  for (final s in wf.subgraphs ?? []) {
    if (s is Map && s['id'] != null) subgraphs['${s['id']}'] = s;
  }

  final nodeMap = <String, GraphNode>{};
  for (final n in wf.nodes) {
    nodeMap[n.key] = n;
  }

  void emit(String id, String classType, Map<String, dynamic> inputs) {
    prompt[id] = {'class_type': classType, 'inputs': inputs};
  }

  dynamic resolveReroute(Map<String, GraphNode> map, dynamic startId, int slot) {
    GraphNode? cur = map['$startId'];
    for (var depth = 0; depth < 64 && cur != null && rerouteTypes.contains(cur.type); depth++) {
      Map<String, dynamic>? inp;
      for (final i in cur.inputs ?? []) {
        if (i is Map && i['link'] != null) {
          inp = Map<String, dynamic>.from(i);
          break;
        }
      }
      if (inp == null || inp['link'] == null) {
        final vals = cur.widgetsValues is List ? List<dynamic>.from(cur.widgetsValues) : [];
        return vals.isNotEmpty ? vals[0] : null;
      }
      final link = linkById[inp['link'] as int];
      if (link == null) return null;
      cur = map['${link[1]}'];
    }
    if (cur == null) return null;
    return ['${cur.id}', slot];
  }

  void applySeedControl(Map<String, dynamic> inputs) {
    for (final key in ['seed', 'noise_seed']) {
      if (!inputs.containsKey(key)) continue;
      final ctrl = inputs['control_after_generate'];
      inputs.remove('control_after_generate');
      final base = int.tryParse('${inputs[key]}') ?? 0;
      if (ctrl == 'randomize') {
        inputs[key] = DateTime.now().millisecondsSinceEpoch % 1125899906842528;
      } else if (ctrl == 'increment') {
        inputs[key] = base + 1;
      } else if (ctrl == 'decrement') {
        inputs[key] = base > 0 ? base - 1 : 0;
      }
    }
  }

  bool skipped(GraphNode node) =>
      node.mode == 4 || bypassed.contains(node.id) || bypassed.contains('${node.id}');

  /* Phase 1 — subgraph expansion (single level). */
  final redirect = <String, List<dynamic>>{};
  for (final node in wf.nodes) {
    if (skipped(node)) continue;
    if (!subgraphs.containsKey(node.type)) continue;
    final sub = Map<String, dynamic>.from(subgraphs[node.type] as Map);
    for (final inner in (sub['nodes'] as List? ?? [])) {
      if (inner is! Map) continue;
      if (subgraphs.containsKey('${inner['type']}')) {
        errors.add(BuildError(node.id, 'Nested subgraphs are not supported'));
      } else if (!rerouteTypes.contains('${inner['type']}') &&
          objectInfo != null &&
          !(objectInfo.containsKey('${inner['type']}')) &&
          (inner['id'] is num ? (inner['id'] as num) >= 0 : true)) {
        errors.add(BuildError(node.id, 'Unknown node type in subgraph: ${inner['type']}'));
      }
    }
    final idMap = <int, String>{};
    for (final inner in (sub['nodes'] as List? ?? [])) {
      if (inner is! Map) continue;
      if (inner['id'] == -10 || inner['id'] == -20) continue;
      idMap[(inner['id'] as num).toInt()] = '${nextId++}';
    }
    final named = node.widgetsValuesNamed ?? const {};
    final namedRec = (node.widgetsValues is Map)
        ? Map<String, dynamic>.from(node.widgetsValues as Map)
        : <String, dynamic>{};
    final phInputs = <String, dynamic>{};
    for (final inp in node.inputs ?? []) {
      if (inp is! Map) continue;
      Map<String, dynamic>? bIn;
      for (final b in (sub['inputs'] as List? ?? [])) {
        if (b is Map && '${b['name']}' == '${inp['name']}') {
          bIn = Map<String, dynamic>.from(b);
          break;
        }
      }
      if (bIn == null) continue;
      if (inp['link'] != null) {
        final link = linkById[inp['link'] as int];
        if (link != null) {
          phInputs[bIn['name']] = resolveReroute(nodeMap, link[1], (link[2] as num?)?.toInt() ?? 0);
        }
      } else if (inp['widget'] is Map) {
        final wname = '${(inp['widget'] as Map)['name']}';
        final v = named[wname] ?? namedRec[wname];
        if (v != null) phInputs[bIn['name']] = v;
      }
    }
    for (final inner in (sub['nodes'] as List? ?? [])) {
      if (inner is! Map) continue;
      if (inner['id'] == -10 || inner['id'] == -20) continue;
      final nid = idMap[(inner['id'] as num).toInt()]!;
      final inputs = <String, dynamic>{};
      for (final inp in (inner['inputs'] as List? ?? [])) {
        if (inp is! Map) continue;
        if (inp['link'] != null) {
          Map<String, dynamic>? sl;
          for (final x in (sub['links'] as List? ?? [])) {
            if (x is Map && x['id'] == inp['link']) {
              sl = Map<String, dynamic>.from(x);
              break;
            }
          }
          if (sl == null) continue;
          if (sl['origin_id'] == -10) {
            Map<String, dynamic>? found;
            for (final b in (sub['inputs'] as List? ?? [])) {
              if (b is! Map) continue;
              final ids = b['linkIds'];
              if ((ids is List && ids.contains(sl['id'])) || b['linkId'] == sl['id']) {
                found = Map<String, dynamic>.from(b);
                break;
              }
            }
            found ??= ((sub['inputs'] as List?)?.isNotEmpty == true &&
                    sl['origin_slot'] is int &&
                    (sl['origin_slot'] as int) < (sub['inputs'] as List).length)
                ? Map<String, dynamic>.from(
                    (sub['inputs'] as List)[sl['origin_slot'] as int] as Map)
                : null;
            found ??= ((sub['inputs'] as List?)?.isNotEmpty == true)
                ? Map<String, dynamic>.from((sub['inputs'] as List).first as Map)
                : null;
            if (found != null && phInputs.containsKey(found['name'])) {
              inputs['${inp['name']}'] = phInputs[found['name']];
            }
          } else {
            final src = idMap[(sl['origin_id'] as num?)?.toInt() ?? -999];
            if (src != null) {
              inputs['${inp['name']}'] = [src, sl['origin_slot']];
            }
          }
        } else if (inp['widget'] is Map) {
          final vals = inner['widgets_values'] is List
              ? List<dynamic>.from(inner['widgets_values'])
              : [];
          final siblings = ((inner['inputs'] as List?) ?? [])
              .where((x) => x is Map && x['widget'] != null && x['link'] == null)
              .toList();
          final wi = siblings.indexOf(inp);
          if (wi >= 0 && wi < vals.length) {
            inputs['${(inp['widget'] as Map)['name']}'] = vals[wi];
          }
        }
      }
      applySeedControl(inputs);
      emit(nid, '${inner['type']}', inputs);
    }
    final outNames = (node.outputs ?? [])
        .whereType<Map>()
        .map((o) => '${o['name'] ?? ''}')
        .toList();
    for (final sl in (sub['links'] as List? ?? [])) {
      if (sl is! Map || sl['target_id'] != -20) continue;
      final src = idMap[(sl['origin_id'] as num?)?.toInt() ?? -999];
      if (src == null) {
        errors.add(BuildError(node.id, 'Subgraph output ${sl['target_slot']} has no source'));
        continue;
      }
      final slot = (sl['target_slot'] as num?)?.toInt() ?? 0;
      final key = (slot < outNames.length) ? '${node.id}:${outNames[slot]}' : '${node.id}:$slot';
      redirect['${node.id}:$slot'] = [src, sl['origin_slot']];
      redirect[key] = [src, sl['origin_slot']];
    }
  }

  dynamic resolveLink(dynamic srcId, int srcSlot) {
    final r = resolveReroute(nodeMap, srcId, srcSlot);
    if (r is List && r.length == 2) {
      final hit = redirect['${r[0]}:${r[1]}'];
      if (hit != null) return hit;
    }
    return r;
  }

  /* Phase 2 — regular nodes. */
  for (final node in wf.nodes) {
    if (skipped(node)) continue;
    if (noteTypes.contains(node.type)) continue;
    if (rerouteTypes.contains(node.type)) continue;
    if (subgraphs.containsKey(node.type)) continue;

    final classDef =
        (objectInfo != null && objectInfo[node.type] is Map)
            ? Map<String, dynamic>.from(objectInfo[node.type] as Map)
            : null;
    final slots = widgetSlots(classDef);
    final linked = <String>{};
    for (final i in node.inputs ?? []) {
      if (i is Map && i['link'] != null) linked.add('${i['name']}');
    }
    final inputs = <String, dynamic>{};
    if (node.widgetsValues is List) {
      final pm = mapPositional(node, slots, linked);
      inputs.addAll(pm.values);
      if (pm.control.isNotEmpty && pm.control != 'fixed') {
        inputs['control_after_generate'] = pm.control;
      }
      var li = 0;
      for (final l in pm.loras) {
        if (l['on'] == true && '${l['lora']}'.isNotEmpty) {
          inputs['lora_${li + 1}'] = {
            'on': true,
            'lora': l['lora'],
            'strength': l['strength'],
          };
        }
        li++;
      }
    } else {
      inputs.addAll(namedValues(node, slots));
    }
    for (final inp in node.inputs ?? []) {
      if (inp is! Map || inp['link'] == null) continue;
      final link = linkById[inp['link'] as int];
      if (link == null) continue;
      final resolved = resolveLink(link[1], (link[2] as num?)?.toInt() ?? 0);
      if (resolved != null) inputs['${inp['name']}'] = resolved;
    }
    applySeedControl(inputs);
    emit('${node.id}', node.type, inputs);
  }

  return BuildResult(prompt, errors);
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
