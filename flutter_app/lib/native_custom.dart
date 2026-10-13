import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import 'api_client.dart';
import 'edge_frost.dart';
import 'graph.dart';
import 'lazy_theme.dart';
import 'native_downloads.dart';
import 'ui_kit.dart';

/// Native port of the next-app Custom page: load any user/template/pasted
/// workflow, edit node widgets from /object_info, queue it, watch outputs.
/// Plus the server drawer (stats, unload, restart).
class NativeCustomPage extends StatefulWidget {
  final String endpoint;
  final bool isDark;
  final VoidCallback onToggleTheme;
  const NativeCustomPage({
    super.key,
    required this.endpoint,
    required this.isDark,
    required this.onToggleTheme,
  });

  @override
  State<NativeCustomPage> createState() => _NativeCustomPageState();
}

class _GItem {
  final String filename;
  final String subfolder;
  final String type;
  final bool video;
  final String wf;
  final String nodeId;
  const _GItem(this.filename, this.subfolder, this.type, this.video, this.wf, this.nodeId);
}

class _Recent {
  final String name;
  final Map<String, dynamic> source;
  final String? path;
  final int at;
  const _Recent(this.name, this.source, this.path, this.at);
  Map<String, dynamic> toJson() => {'name': name, 'source': source, 'path': path, 'at': at};
  static _Recent fromJson(Map<String, dynamic> j) => _Recent(
      '${j['name'] ?? ''}',
      (j['source'] is Map) ? Map<String, dynamic>.from(j['source']) : <String, dynamic>{},
      j['path']?.toString(),
      (j['at'] as num?)?.toInt() ?? 0);
}

class _NativeCustomPageState extends State<NativeCustomPage> {
  late LazyApi _api;
  Map<String, dynamic>? _objectInfo;
  int _objectInfoAt = 0;

  Graph? _wf;
  Map<String, dynamic>? _wfRaw;
  Map<String, dynamic>? _wfApi;
  String _wfName = '';
  Map<String, dynamic>? _source;
  Set<String> _bypassed = {};
  Map<String, bool> _collapsed = {};
  String _search = '';
  Map<String, List<String>> _nodeErrors = {};
  final List<_GItem> _gallery = [];
  List<_Recent> _recent = [];
  String _jobState = 'Idle';
  double? _progress;
  String? _promptId;
  StreamSubscription<Map<String, dynamic>>? _wsSub;
  Timer? _pollTimer;

  /// Persistent text controllers per node/slot: recreating them on every
  /// build (every keystroke triggers setState) yanks the cursor to the end
  /// and makes mid-text editing impossible. Cleared on workflow load.
  final Map<String, TextEditingController> _ctrls = {};

  TextEditingController _ctrlFor(String key, String text) {
    final existing = _ctrls[key];
    if (existing != null) {
      // Adopt external changes (model switch, reload); keystroke writes
      // already match, so typing never jumps.
      if (existing.text != text) existing.text = text;
      return existing;
    }
    final c = TextEditingController(text: text);
    _ctrls[key] = c;
    return c;
  }

  String? _menuView; // null = closed; menu|recent|myworkflows|templates|paste|server
  List<dynamic> _userFiles = [];
  Map<String, dynamic> _templates = {};
  final TextEditingController _pasteCtrl = TextEditingController();
  final TextEditingController _queryCtrl = TextEditingController();
  Map<String, dynamic>? _stats;
  bool _restartArmed = false;
  bool _restarting = false;
  String? _unloading;

  @override
  void initState() {
    super.initState();
    _api = LazyApi(widget.endpoint);
    _boot();
  }

  @override
  void didUpdateWidget(covariant NativeCustomPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.endpoint != widget.endpoint) {
      _api.close();
      _api = LazyApi(widget.endpoint);
      _boot();
    }
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    _pollTimer?.cancel();
    _api.close();
    _pasteCtrl.dispose();
    _queryCtrl.dispose();
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _boot() async {
    _objectInfoFn();
    final p = await SharedPreferences.getInstance();
    try {
      final raw = p.getString('lazycomfy.native.custom.recent');
      if (raw != null && raw.isNotEmpty) {
        final l = json.decode(raw);
        if (l is List) {
          _recent = l.whereType<Map>().map((e) => _Recent.fromJson(Map<String, dynamic>.from(e))).toList();
        }
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<Map<String, dynamic>> _objectInfoFn({bool force = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && _objectInfo != null && now - _objectInfoAt < 60000) return _objectInfo!;
    try {
      final info = await _api.objectInfo();
      if (!mounted) return info;
      setState(() {
        _objectInfo = info;
        _objectInfoAt = now;
      });
      return info;
    } catch (_) {
      return _objectInfo ?? const {};
    }
  }

  void _pushRecent(String name, Map<String, dynamic> src, String? path) async {
    final next = [
      _Recent(name, src, path, DateTime.now().millisecondsSinceEpoch),
      ..._recent.where((r) => !(r.name == name && r.path == path))
    ].take(20).toList();
    setState(() => _recent = next);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          'lazycomfy.native.custom.recent', json.encode(next.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  Future<void> _setWorkflow(dynamic obj, String name, Map<String, dynamic> src) async {
    if (isGraphFormat(obj)) {
      final g = Graph.fromJson(Map<String, dynamic>.from(obj));
      final byp = <String>{};
      for (final n in g.nodes) {
        if (n.mode == 4) byp.add('${n.id}');
      }
      final info = await _objectInfoFn().catchError((_) => <String, dynamic>{});
      if (!mounted) return;
      for (final c in _ctrls.values) {
        c.dispose();
      }
      _ctrls.clear();
      setState(() {
        _wf = g;
        _wfRaw = Map<String, dynamic>.from(obj);
        _wfApi = null;
        _bypassed = byp;
        _collapsed = {};
        _wfName = name;
        _source = src;
        _nodeErrors = {};
        _menuView = null;
        _revalidate(g, info);
      });
      _pushRecent(name, src, src['path']?.toString());
      _snack('Workflow loaded.', ok: true);
    } else if (isApiFormat(obj)) {
      final a = json.decode(json.encode(obj)) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _wf = null;
        _wfApi = a;
        _bypassed = {};
        _collapsed = {};
        _wfName = name;
        _source = src;
        _nodeErrors = {};
        _menuView = null;
      });
      _pushRecent(name, src, src['path']?.toString());
      _snack('API-format workflow loaded (run only).', ok: true);
    } else {
      _snack('Unrecognized workflow format.');
    }
  }

  void _revalidate(Graph? g, Map<String, dynamic>? info) {
    final errs = <String, List<String>>{};
    if (g != null && info != null) {
      for (final n in g.nodes) {
        if (noteTypes.contains(n.type)) continue;
        if (!info.containsKey(n.type)) {
          errs['${n.id}'] = ['Unknown node type on backend: ${n.type}'];
        }
      }
    }
    _nodeErrors = errs;
  }

  void _unfocus() => FocusManager.instance.primaryFocus?.unfocus();

  Future<void> _run() async {
    _unfocus();
    Map<String, dynamic> promptObj;
    try {
      final info = await _objectInfoFn();
      if (_wfApi != null) {
        promptObj = _wfApi!;
      } else if (_wf != null) {
        final res = buildPrompt(_wf!, _bypassed, info);
        if (res.errors.isNotEmpty) {
          final map = <String, List<String>>{};
          for (final e in res.errors) {
            final k = '${e.nodeId}';
            map[k] = [...(map[k] ?? []), e.message];
          }
          setState(() => _nodeErrors = map);
          _snack(res.errors.map((e) => 'node ${e.nodeId}: ${e.message}').join('\n'));
          return;
        }
        promptObj = res.prompt;
      } else {
        _snack('Load a workflow first.');
        return;
      }
    } catch (e) {
      _snack(e is ApiException ? e.message : 'Cannot queue.');
      return;
    }
    setState(() {
      _jobState = 'Queueing ${_wfName.isNotEmpty ? _wfName : 'workflow'}…';
      _progress = 0;
    });
    try {
      final clientId = await getClientId();
      final extra = {
        'custom_workflow': {'name': _wfName, 'source': _source?['type']}
      };
      if (_wfRaw != null) extra['extra_pnginfo'] = {'workflow': _wfRaw};
      final id = await _api.submitPrompt(promptObj, clientId, extra);
      if (!mounted) return;
      setState(() {
        _promptId = id;
        _jobState = 'Running…';
      });
      _watch(id, clientId);
    } catch (e) {
      if (!mounted) return;
      setState(() => _jobState = 'Error');
      _snack(e is ApiException ? e.message : 'Queue failed.');
    }
  }

  void _watch(String id, String clientId) {
    _wsSub?.cancel();
    _pollTimer?.cancel();
    _wsSub = _api.comfyWs(clientId).listen((msg) {
      if (!mounted || _promptId != id) return;
      final data = msg['data'];
      if (data is! Map) return;
      if (data['prompt_id'] != null && data['prompt_id'] != id) return;
      final type = msg['type'];
      if (type == 'progress' && data['max'] is num && (data['max'] as num) > 0) {
        final v = (data['value'] as num).toDouble();
        final mx = (data['max'] as num).toDouble();
        setState(() {
          _progress = (v / mx).clamp(0.0, 1.0);
          _jobState = 'Sampling ${v.toInt()} / ${mx.toInt()}';
        });
      } else if (type == 'executing') {
        if (data['node'] != null) {
          setState(() => _jobState = 'Node ${data['node']}…');
        } else {
          _finish(id);
        }
      } else if (type == 'executed' || type == 'execution_success') {
        _finish(id);
      } else if (type == 'execution_error') {
        _fail('Run failed.');
      } else if (type == 'execution_interrupted') {
        _fail('Run cancelled.', cancelled: true);
      }
    }, onError: (_) {});
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _finish(id));
  }

  Future<void> _finish(String id) async {
    if (_promptId != id || !mounted) return;
    Map<String, dynamic>? entry;
    try {
      entry = await _api.promptHistory(id);
    } catch (_) {
      return;
    }
    if (entry == null) return;
    final completed = (entry['status'] is Map) && entry['status']['completed'] == true;
    if (!completed) return;
    if (!mounted || _promptId != id) return;
    final ok = (entry['status'] is Map) && entry['status']['status_str'] == 'success';
    _wsSub?.cancel();
    _pollTimer?.cancel();
    setState(() {
      _promptId = null;
      _progress = null;
      _jobState = ok ? 'Done' : 'Error';
    });
    if (!ok) {
      _snack('${(entry['status'] is Map) ? entry['status']['status_str'] : 'error'}');
      return;
    }
    final outs = <_GItem>[];
    final outputs = (entry['outputs'] is Map) ? Map<String, dynamic>.from(entry['outputs']) : const {};
    for (final e in outputs.entries) {
      final nodeOut = (e.value is Map) ? Map<String, dynamic>.from(e.value) : const {};
      for (final kind in ['images', 'gifs', 'videos']) {
        final arr = nodeOut[kind];
        if (arr is! List) continue;
        for (final f in arr.whereType<Map>()) {
          if (f['filename'] == null) continue;
          outs.add(_GItem('${f['filename']}', '${f['subfolder'] ?? ''}',
              '${f['type'] ?? 'output'}', kind != 'images', _wfName, '${e.key}'));
        }
      }
    }
    setState(() => _gallery.insertAll(0, outs.reversed.toList()));
    _snack('Run finished.', ok: true);
  }

  void _fail(String msg, {bool cancelled = false}) {
    _wsSub?.cancel();
    _pollTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _promptId = null;
      _progress = null;
      _jobState = cancelled ? 'Cancelled' : 'Error';
    });
    _snack(msg);
  }

  Future<void> _cancel() async {
    setState(() => _jobState = 'Cancelling…');
    try {
      await _api.interrupt();
    } catch (_) {}
  }

  void _snack(String msg, {bool ok = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: ok ? const Color(0xFF14532D) : null,
    ));
  }

  Future<void> _saveImage(_GItem g) async {
    try {
      final uri = Uri.parse(_api.viewUrl(filename: g.filename, subfolder: g.subfolder, type: g.type));
      final res = await http.get(uri).timeout(const Duration(minutes: 5));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final saved =
          await FilePicker.platform.saveFile(fileName: g.filename, bytes: res.bodyBytes);
      if (!mounted) return;
      _snack(saved == null ? 'Download cancelled.' : 'Saved: $saved', ok: saved != null);
    } catch (_) {
      _snack('Download failed. Check the connection and retry.');
    }
  }

  void _openDownloads() {
    _unfocus();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NativeDownloadsPage(endpoint: widget.endpoint, onChanged: () {}),
      ),
    );
  }

  // ---------- menu data ----------

  Future<void> _loadUserFiles() async {
    try {
      final f = await _api.userWorkflows();
      if (!mounted) return;
      setState(() => _userFiles = f);
    } catch (e) {
      _snack(e is ApiException ? e.message : 'Load failed.');
    }
  }

  Future<void> _loadTemplates() async {
    try {
      final t = await _api.workflowTemplates();
      if (!mounted) return;
      setState(() => _templates = t);
    } catch (e) {
      _snack(e is ApiException ? e.message : 'Load failed.');
    }
  }

  Future<void> _loadStats() async {
    try {
      final s = await _api.systemStats();
      if (!mounted) return;
      setState(() => _stats = s);
    } catch (_) {}
  }

  Future<void> _unloadModels(String scope) async {
    setState(() => _unloading = scope);
    try {
      await _api.unloadModels(scope);
      _snack(scope == 'vram' ? 'VRAM models unloaded.' : 'All models unloaded.', ok: true);
      _loadStats();
    } catch (e) {
      _snack(e is ApiException ? e.message : 'Unload failed.');
    } finally {
      if (mounted) setState(() => _unloading = null);
    }
  }

  Future<void> _restart() async {
    if (!_restartArmed) {
      setState(() => _restartArmed = true);
      Future.delayed(const Duration(seconds: 5), () {
        if (mounted) setState(() => _restartArmed = false);
      });
      return;
    }
    setState(() {
      _restartArmed = false;
      _restarting = true;
    });
    try {
      await _api.restartComfy();
      final t0 = DateTime.now();
      while (DateTime.now().difference(t0).inSeconds < 90) {
        await Future.delayed(const Duration(seconds: 2));
        try {
          await _api.systemStats();
          if (!mounted) return;
          _snack('ComfyUI is back.', ok: true);
          break;
        } catch (_) {}
      }
    } catch (e) {
      _snack(e is ApiException ? e.message : 'Restart failed.');
    } finally {
      if (mounted) setState(() => _restarting = false);
    }
  }

  // ---------- node editing ----------

  void _updateNode(String id, void Function(GraphNode) fn) {
    setState(() {
      final g = _wf;
      if (g == null) return;
      final t = g.nodes.firstWhere((n) => '${n.id}' == id,
          orElse: () => GraphNode(id: id, type: ''));
      if (!g.nodes.contains(t)) return;
      fn(t);
      _revalidate(g, _objectInfo);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.lazy;
    final mq = MediaQuery.paddingOf(context);
    const headerH = 42.0;
    final nodeCount = _wf != null
        ? _wf!.nodes.where((n) => !noteTypes.contains(n.type)).length
        : (_wfApi != null ? _wfApi!.length : 0);
    final visible = (_wf?.nodes ?? []).where((n) {
      final q = _search.trim().toLowerCase();
      if (q.isEmpty) return true;
      return (n.title.isNotEmpty ? n.title : n.type).toLowerCase().contains(q) ||
          '${n.id}' == _search.trim();
    }).toList();
    return Scaffold(
      backgroundColor: c.bg,
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: () => _objectInfoFn(force: true).then((_) {}),
            child: ListView(
              padding: EdgeInsets.fromLTRB(16, mq.top + headerH + 12, 16, mq.bottom + 24),
              children: [
                Row(children: [
                  UiGhostBtn('☰  MENU', () => setState(() => _menuView = 'menu')),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _wfName.isNotEmpty ? '$_wfName · $nodeCount nodes' : 'no workflow',
                      overflow: TextOverflow.ellipsis,
                      style: fmono(10.5, c.muted2),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                if (_wf == null && _wfApi == null)
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      border: Border.all(color: c.border, style: BorderStyle.solid),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(children: [
                      Text('No workflow loaded.',
                          style: TextStyle(fontSize: 13, color: c.ink)),
                      const SizedBox(height: 8),
                      UiGhostBtn('OPEN MENU', () => setState(() => _menuView = 'menu')),
                    ]),
                  ),
                if (_wf != null || _wfApi != null) ...[
                  TextField(
                    onChanged: (v) => setState(() => _search = v),
                    style: TextStyle(color: c.ink, fontSize: 13),
                    decoration: const InputDecoration(hintText: 'Search nodes…'),
                  ),
                  const SizedBox(height: 8),
                  if (_wfApi != null) _apiCard(),
                  for (final n in visible) _nodeCard(n),
                  if (_wf != null && visible.isEmpty)
                    Text('No matches — try a different search.',
                        style: TextStyle(fontSize: 12.5, color: c.muted)),
                ],
                const SizedBox(height: 4),
                uiCard(context, [
                  Row(children: [
                    Expanded(child: uiSection(context, 'Run', noPad: true)),
                    Expanded(
                      child: Text(_jobState,
                          textAlign: TextAlign.right,
                          style: disp(16, FontWeight.w700, c.ink)),
                    ),
                  ]),
                  if (_progress != null) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: _progress == 0 ? null : _progress,
                        minHeight: 4,
                        valueColor: AlwaysStoppedAnimation<Color>(c.accent),
                        backgroundColor: c.accentSoft,
                      ),
                    ),
                  ],
                  if (_wf != null || _wfApi != null) ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                        child: UiPrimaryBtn(
                          _promptId != null ? _jobState.toUpperCase() : 'Run workflow',
                          _promptId != null ? null : _run,
                        ),
                      ),
                      if (_promptId != null) ...[
                        const SizedBox(width: 8),
                        UiDangerBtn('CANCEL', _cancel),
                      ],
                    ]),
                  ],
                ]),
                uiCard(context, [
                  uiSection(context, 'Outputs${_gallery.isNotEmpty ? ' (${_gallery.length})' : ''}'),
                  if (_gallery.isEmpty)
                    Text('Nothing yet — queue a workflow to see results here.',
                        style: TextStyle(fontSize: 12.5, color: c.muted)),
                  GridView.count(
                    crossAxisCount: 2,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [for (final g in _gallery) _gTile(g)],
                  ),
                ]),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: EdgeShade(inset: mq.top + headerH, color: c.bg),
          ),
          Positioned(
            top: mq.top,
            left: 16,
            right: 16,
            child: SizedBox(
              height: headerH,
              child: Row(children: [
                UiBrand(dark: context.isDark),
                const Spacer(),
                _syncDot(),
                const SizedBox(width: 8),
                UiHeadBtn(Icons.download_rounded, 'Model downloads', _openDownloads),
                const SizedBox(width: 8),
                UiHeadBtn(
                  widget.isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                  widget.isDark ? 'Switch to light mode' : 'Switch to dark mode',
                  widget.onToggleTheme,
                ),
              ]),
            ),
          ),
          if (_menuView != null)
            _menuSheet(),
        ],
      ),
    );
  }

  Widget _syncDot() {
    final c = context.lazy;
    final dot = _errorSync() ? c.err : c.ok;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 8, height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: dot)),
      const SizedBox(width: 6),
      Text(_errorSync() ? 'OFFLINE' : 'SYNCED', style: fmono(10, c.muted2, ls: 0.06)),
    ]);
  }

  bool _errorSync() => false;

  Widget _apiCard() {
    final c = context.lazy;
    final rows = _wfApi!.entries.take(60).toList();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('API-format prompt · ${_wfApi!.length} ops',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.ink)),
        Text('Loaded as a raw prompt dict — editing is disabled, run only.',
            style: TextStyle(fontSize: 12.5, color: c.muted)),
        const SizedBox(height: 6),
        for (final e in rows)
          Text.rich(TextSpan(children: [
            TextSpan(
                text: '${e.key} ',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 10.5, color: c.muted2)),
            TextSpan(
                text: '${(e.value is Map) ? (e.value as Map)['class_type'] : ''}',
                style: TextStyle(fontSize: 10.5, color: c.muted2)),
          ])),
      ]),
    );
  }

  Widget _nodeCard(GraphNode node) {
    final c = context.lazy;
    final nid = '${node.id}';
    if (noteTypes.contains(node.type)) {
      final text = (node.widgetsValues is List && (node.widgetsValues as List).isNotEmpty)
          ? '${(node.widgetsValues as List).first ?? ''}'
          : '';
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: c.bgCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('📝 ${node.title.isNotEmpty ? node.title : 'Note'}',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.ink)),
          Text(text.length > 2000 ? text.substring(0, 2000) : text,
              style: TextStyle(fontSize: 12.5, color: c.muted)),
        ]),
      );
    }
    final classDef = (_objectInfo != null && _objectInfo![node.type] is Map)
        ? Map<String, dynamic>.from(_objectInfo![node.type] as Map)
        : null;
    final slots = widgetSlots(classDef);
    final collapsed = _collapsed[nid] ?? false;
    final bypassed = _bypassed.contains(nid);
    final errs = _nodeErrors[nid] ?? const [];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: c.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Opacity(
        opacity: bypassed ? 0.55 : 1,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            GestureDetector(
              onTap: () => setState(() => _collapsed[nid] = !collapsed),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Text(collapsed ? '▶' : '▼', style: TextStyle(fontSize: 12, color: c.muted2)),
              ),
            ),
            Expanded(
              child: Text(node.title.isNotEmpty ? node.title : node.type,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.ink)),
            ),
            Text('#$nid', style: fmono(10.5, c.muted2)),
            if (errs.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text('● ${errs.length}', style: TextStyle(fontSize: 10, color: c.err)),
              ),
            if (classDef == null && _objectInfo != null)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text('BACKEND ISSUE', style: fmono(10, c.warn, ls: 0.06)),
              ),
            GestureDetector(
              onTap: () => setState(() {
                final next = Set<String>.from(_bypassed);
                if (next.contains(nid)) {
                  next.remove(nid);
                } else {
                  next.add(nid);
                }
                _bypassed = next;
              }),
              child: Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  border: Border.all(color: bypassed ? c.warn : c.border),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(bypassed ? 'BYPASS ON' : 'BYPASS',
                    style: fmono(10, c.muted2, w: FontWeight.w600, ls: 0.06)),
              ),
            ),
          ]),
          if (errs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(errs.join('; '), style: TextStyle(fontSize: 11, color: c.err)),
            ),
          if (!collapsed) ...[
            const SizedBox(height: 8),
            _slotEditors(node, slots),
            for (final i in (node.inputs ?? []))
              if (i is Map && i['link'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${i['name']} ← link #${i['link']}',
                      style: fmono(10.5, c.muted2)),
                ),
          ],
        ]),
      ),
    );
  }

  /// Positional slot editors, mirroring the web slotIndices walk (linked
  /// slots skipped, seed-control tail spliced out).
  Widget _slotEditors(GraphNode node, List<WidgetSlot> slots) {
    final linked = <String>{};
    for (final i in node.inputs ?? []) {
      if (i is Map && i['link'] != null) linked.add('${i['name']}');
    }
    final raw = (node.widgetsValues is List) ? List<dynamic>.from(node.widgetsValues) : <dynamic>[];
    var count = raw.length;
    final seedIdx = slots.indexWhere((s) => s.name == 'seed' || s.name == 'noise_seed');
    String control = 'fixed';
    if (seedIdx >= 0 && raw.length == slots.length + 1) {
      final tail = raw[slots.length];
      if (tail == null || tail is String) {
        control = tail is String ? tail : 'fixed';
        count = raw.length - 1;
      }
    }
    while (raw.length < count) {
      raw.add(null);
    }
    var vi = 0;
    final widgets = <Widget>[];
    for (final slot in slots) {
      if (linked.contains(slot.name)) continue;
      final index = vi < count ? vi : -1;
      vi++;
      dynamic cur;
      if (slot.kind == 'seed' && index < 0) {
        cur = null;
      } else if (index >= 0) {
        cur = raw[index];
      } else if (node.widgetsValuesNamed != null) {
        cur = node.widgetsValuesNamed![slot.name];
      }
      final named = node.widgetsValues is! List;
      widgets.add(_slotEditor(node, slot, index, cur, named, control, (v) => control = v));
      widgets.add(const SizedBox(height: 8));
    }
    if (widgets.isNotEmpty) widgets.removeLast();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widgets);
  }

  void _writePositional(GraphNode node, List<WidgetSlot> slots, int index, dynamic value) {
    _updateNode('${node.id}', (n) {
      var arr = (n.widgetsValues is List) ? List<dynamic>.from(n.widgetsValues) : <dynamic>[];
      // Preserve a seed-control tail while splicing values.
      dynamic tail;
      final seedIdx = slots.indexWhere((s) => s.name == 'seed' || s.name == 'noise_seed');
      if (seedIdx >= 0 && arr.length == slots.length + 1) {
        final t = arr[slots.length];
        if (t == null || t is String) tail = t;
      }
      final linked = <String>{};
      for (final i in n.inputs ?? []) {
        if (i is Map && i['link'] != null) linked.add('${i['name']}');
      }
      var vi = 0;
      var target = -1;
      for (final s in slots) {
        if (linked.contains(s.name)) continue;
        if (vi == index) {
          target = vi;
          break;
        }
        vi++;
      }
      while (arr.length <= target) {
        arr.add(null);
      }
      if (target >= 0) arr[target] = value;
      if (tail != null || (seedIdx >= 0 && arr.length == slots.length + 1)) {
        while (arr.length < slots.length + 1) {
          arr.add(null);
        }
        if (tail != null) arr[slots.length] = tail;
      }
      n = _withValues(n, arr);
      _replaceNode(n);
    });
  }

  GraphNode _withValues(GraphNode n, List<dynamic> arr) => GraphNode(
        id: n.id,
        type: n.type,
        title: n.title,
        mode: n.mode,
        inputs: n.inputs,
        outputs: n.outputs,
        widgetsValues: arr,
        widgetsValuesNamed: n.widgetsValuesNamed,
        links: n.links,
      );

  void _replaceNode(GraphNode n) {
    final g = _wf;
    if (g == null) return;
    final i = g.nodes.indexWhere((x) => '${x.id}' == '${n.id}');
    if (i < 0) return;
    g.nodes[i] = n;
  }

  void _writeNamed(GraphNode node, String name, dynamic value) {
    _updateNode('${node.id}', (n) {
      final rec = Map<String, dynamic>.from(n.widgetsValuesNamed ?? {});
      rec[name] = value;
      _replaceNode(GraphNode(
        id: n.id,
        type: n.type,
        title: n.title,
        mode: n.mode,
        inputs: n.inputs,
        outputs: n.outputs,
        widgetsValues: n.widgetsValues,
        widgetsValuesNamed: rec,
        links: n.links,
      ));
    });
  }

  void _writeControl(GraphNode node, List<WidgetSlot> slots, String value) {
    _updateNode('${node.id}', (n) {
      var arr = (n.widgetsValues is List) ? List<dynamic>.from(n.widgetsValues) : <dynamic>[];
      while (arr.length < slots.length) {
        arr.add(null);
      }
      if (arr.length == slots.length) {
        if (value != 'fixed') arr.add(value);
      } else {
        arr[slots.length] = value == 'fixed' ? null : value;
      }
      _replaceNode(_withValues(n, arr));
    });
  }

  Widget _slotEditor(GraphNode node, WidgetSlot slot, int index, dynamic cur, bool named,
      String control, ValueChanged<String> onControl) {
    if (slot.kind == 'combo') {
      final options = slot.options ?? const [];
      final missing = cur != null && !options.contains('$cur');
      return _labeled(slot.name, UiSelect(
        value: cur == null ? null : '$cur',
        items: {
          if (missing) '$cur': '⚠ $cur (missing)',
          for (final o in options) o: o,
        },
        hint: '',
        sheetTitle: slot.name,
        onChanged: (v) {
          if (v == null) return;
          if (index >= 0) {
            _writePositional(node, _slotsOf(node), index, v);
          } else {
            _writeNamed(node, slot.name, v);
          }
        },
      ));
    }
    if (slot.kind == 'boolean') {
      return Row(children: [
        Switch(
          value: cur == true,
          activeThumbColor: context.lazy.accent,
          onChanged: (v) {
            if (index >= 0) {
              _writePositional(node, _slotsOf(node), index, v);
            } else {
              _writeNamed(node, slot.name, v);
            }
          },
        ),
        const SizedBox(width: 10),
        Text(slot.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ]);
    }
    if (slot.kind == 'number' || slot.kind == 'seed') {
      return _labeled(
        slot.name,
        Row(children: [
          Expanded(
            child: _numField(
              node,
              cur,
              slot,
              (v) {
                dynamic out = v;
                if (slot.intOnly) out = int.tryParse(v) ?? 0;
                if (index >= 0) {
                  _writePositional(node, _slotsOf(node), index, out);
                } else {
                  _writeNamed(node, slot.name, out);
                }
              },
            ),
          ),
          if (slot.kind == 'seed') ...[
            const SizedBox(width: 6),
            SizedBox(
              width: 150,
              child: UiSelect(
                value: control,
                items: {for (final m in controlModes) m: m},
                hint: 'fixed',
                sheetTitle: 'Seed control',
                onChanged: (v) {
                  if (v == null) return;
                  _writeControl(node, _slotsOf(node), v);
                  onControl(v);
                },
              ),
            ),
          ],
        ]),
      );
    }
    final str = cur == null ? '' : '$cur';
    if (slot.kind == 'image' || isImageLike(slot.name, cur)) {
      return _labeled(
        slot.name,
        Row(children: [
          Expanded(
            child: _strField(node, slot.name, str, (v) {
              if (index >= 0) {
                _writePositional(node, _slotsOf(node), index, v);
              } else {
                _writeNamed(node, slot.name, v);
              }
            }, hint: 'filename'),
          ),
          const SizedBox(width: 6),
          UiGhostBtn('⇪', () => _uploadFor(node, slot, index)),
        ]),
      );
    }
    if (str.length > 60 || str.contains('\n') || (slot.multiline)) {
      return _labeled(
        slot.name,
        TextField(
          controller: _ctrlFor('${node.id}:${slot.name}:area', str),
          onChanged: (v) {
            if (index >= 0) {
              _writePositional(node, _slotsOf(node), index, v);
            } else {
              _writeNamed(node, slot.name, v);
            }
          },
          maxLines: 3,
          minLines: 1,
          style: TextStyle(color: context.lazy.ink, fontSize: 13),
          decoration: const InputDecoration(),
        ),
      );
    }
    return _labeled(
      slot.name,
      _strField(node, slot.name, str, (v) {
        if (index >= 0) {
          _writePositional(node, _slotsOf(node), index, v);
        } else {
          _writeNamed(node, slot.name, v);
        }
      }),
    );
  }

  List<WidgetSlot> _slotsOf(GraphNode node) {
    final classDef = (_objectInfo != null && _objectInfo![node.type] is Map)
        ? Map<String, dynamic>.from(_objectInfo![node.type] as Map)
        : null;
    return widgetSlots(classDef);
  }

  Widget _labeled(String label, Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        uiField(context, label),
        child,
      ]),
    );
  }

  Widget _numField(GraphNode node, dynamic cur, WidgetSlot slot, ValueChanged<String> onChanged) {
    return TextField(
      controller: _ctrlFor('${node.id}:${slot.name}:num', cur == null ? '' : '$cur'),
      onChanged: onChanged,
      keyboardType: TextInputType.numberWithOptions(
          signed: (slot.min is num && (slot.min as num) < 0), decimal: !slot.intOnly),
      style: TextStyle(color: context.lazy.ink, fontSize: 13),
      decoration: const InputDecoration(),
    );
  }

  Widget _strField(GraphNode node, String slotName, String str, ValueChanged<String> onChanged,
      {String? hint}) {
    return TextField(
      controller: _ctrlFor('${node.id}:$slotName:str', str),
      onChanged: onChanged,
      autocorrect: false,
      enableSuggestions: false,
      style: TextStyle(color: context.lazy.ink, fontSize: 13),
      decoration: InputDecoration(hintText: hint),
    );
  }

  Future<void> _uploadFor(GraphNode node, WidgetSlot slot, int index) async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'mp4', 'mov', 'webm'],
        withData: true,
      );
      if (res == null || res.files.isEmpty) return;
      final f = res.files.first;
      List<int>? bytes = f.bytes;
      if ((bytes == null || bytes.isEmpty) && f.path != null) {
        try {
          bytes = await File(f.path!).readAsBytes();
        } catch (_) {}
      }
      if (bytes == null || bytes.isEmpty) return;
      final up = await _api.uploadImage(bytes, f.name);
      final v = '${up['subfolder']!.isNotEmpty ? '${up['subfolder']}/' : ''}${up['name']}';
      if (index >= 0) {
        _writePositional(node, _slotsOf(node), index, v);
      } else {
        _writeNamed(node, slot.name, v);
      }
      _snack('Uploaded ${up['name']}', ok: true);
    } catch (e) {
      _snack(e is ApiException ? e.message : 'Upload failed.');
    }
  }

  Widget _gTile(_GItem g) {
    return GestureDetector(
      onTap: () => _viewImage(g),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AspectRatio(
          aspectRatio: 1,
          child: g.video
              ? Container(
                  color: context.lazy.bgSoft,
                  child: const Icon(Icons.movie_outlined),
                )
              : CachedNetworkImage(
                  imageUrl: _api.thumbUrl(
                      filename: g.filename, subfolder: g.subfolder, type: g.type),
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(color: context.lazy.bgSoft),
                  errorWidget: (_, __, ___) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      setState(() => _gallery.removeWhere((e) =>
                          e.filename == g.filename && e.subfolder == g.subfolder));
                    });
                    return Container(color: context.lazy.bgSoft);
                  },
                ),
        ),
      ),
    );
  }

  void _viewImage(_GItem g) {
    final c = context.lazy;
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: c.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: g.video
                ? _MiniPlayer(
                    url: _api.viewUrl(
                        filename: g.filename, subfolder: g.subfolder, type: g.type))
                : CachedNetworkImage(
                    imageUrl: _api.viewUrl(
                        filename: g.filename, subfolder: g.subfolder, type: g.type),
                    fit: BoxFit.contain,
                    errorWidget: (_, __, ___) => const Padding(
                      padding: EdgeInsets.all(32),
                      child: Icon(Icons.broken_image_outlined),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(child: UiGhostBtn('CLOSE', () => Navigator.pop(context))),
              const SizedBox(width: 8),
              Expanded(
                child: UiPrimaryBtn('SAVE', () {
                  Navigator.pop(context);
                  _saveImage(g);
                }),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
  // ---------- menu sheet ----------

  Widget _menuSheet() {
    final view = _menuView ?? 'menu';
    return Positioned.fill(
      child: Stack(children: [
        GestureDetector(onTap: () => setState(() => _menuView = null)),
        Positioned(
          top: 0,
          bottom: 0,
          left: 0,
          child: Container(
            width: 380 > MediaQuery.sizeOf(context).width * 0.92
                ? MediaQuery.sizeOf(context).width * 0.92
                : 380,
            decoration: BoxDecoration(
              color: context.lazy.bgCard,
              border: Border(right: BorderSide(color: context.lazy.border)),
            ),
            child: SafeArea(
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: Row(children: [
                    if (view == 'menu')
                      UiIconCircle(Icons.close_rounded, 'Close menu',
                          () => setState(() => _menuView = null))
                    else
                      UiGhostBtn('← BACK', () => setState(() => _menuView = 'menu')),
                    const SizedBox(width: 8),
                    Text(_menuTitle(view), style: disp(16, FontWeight.w700, context.lazy.ink)),
                  ]),
                ),
                Expanded(child: SingleChildScrollView(child: _menuBody(view))),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  String _menuTitle(String view) {
    switch (view) {
      case 'recent':
        return 'Recent';
      case 'myworkflows':
        return 'My Workflows';
      case 'templates':
        return 'Templates';
      case 'paste':
        return 'Paste JSON';
      case 'server':
        return 'Server';
      default:
        return 'Menu';
    }
  }

  Widget _menuBody(String view) {
    switch (view) {
      case 'menu':
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            uiField(context, 'Server'),
            UiGhostBtn('SERVER STATS & RESTART', () {
              setState(() => _menuView = 'server');
              _loadStats();
            }),
            const SizedBox(height: 12),
            uiField(context, 'Load workflow'),
            UiGhostBtn('RECENT', () => setState(() => _menuView = 'recent')),
            const SizedBox(height: 6),
            UiGhostBtn('MY WORKFLOWS', () {
              setState(() => _menuView = 'myworkflows');
              _loadUserFiles();
            }),
            const SizedBox(height: 6),
            UiGhostBtn('TEMPLATES', () {
              setState(() => _menuView = 'templates');
              _loadTemplates();
            }),
            const SizedBox(height: 6),
            UiGhostBtn('PASTE JSON', () => setState(() => _menuView = 'paste')),
          ]),
        );
      case 'recent':
        if (_recent.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Nothing yet — loaded workflows appear here.',
                style: TextStyle(fontSize: 12.5, color: context.lazy.muted)),
          );
        }
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final r in _recent)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: UiGhostBtn('${r.name} · ${fmtTimeAgo(r.at)}',
                        () => _loadRecent(r)),
                  ),
              ]),
        );
      case 'myworkflows':
        final files = _userFiles
            .where((f) =>
                f is Map && ('${f['name'] ?? ''}'.endsWith('.json')))
            .toList();
        if (files.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text('No saved workflows yet.',
                style: TextStyle(fontSize: 12.5, color: context.lazy.muted)),
          );
        }
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final f in files)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(children: [
                      Expanded(child: Builder(builder: (ctx) {
                        final m = f as Map;
                        final rel = '${m['path'] ?? ''}'
                            .replaceFirst(RegExp(r'^workflows/'), '');
                        return UiGhostBtn('${m['name'] ?? m['path'] ?? ''}',
                            () => _loadUserFile(rel));
                      })),
                      const SizedBox(width: 6),
                      UiDangerBtn('🗑', () => _deleteUserFile(Map<String, dynamic>.from(f as Map))),
                    ]),
                  ),
              ]),
        );
      case 'templates':
        if (_templates.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Loading…', style: TextStyle(fontSize: 12.5, color: context.lazy.muted)),
          );
        }
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final mod in _templates.keys)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(mod,
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: context.lazy.ink3)),
                          const SizedBox(height: 4),
                          for (final n in ((_templates[mod] is List)
                              ? List<dynamic>.from(_templates[mod])
                              : const []))
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: UiGhostBtn('→ $n', () => _loadTemplate(mod, '$n')),
                            ),
                        ]),
                  ),
              ]),
        );
      case 'paste':
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              controller: _pasteCtrl,
              maxLines: 10,
              style: TextStyle(color: context.lazy.ink, fontSize: 12),
              decoration: const InputDecoration(hintText: '{"nodes": …} or {"1": {"class_type": …}}'),
            ),
            const SizedBox(height: 8),
            UiPrimaryBtn('Load workflow', () {
              try {
                final obj = json.decode(_pasteCtrl.text);
                _setWorkflow(obj, 'pasted workflow', {'type': 'paste'});
              } catch (e) {
                _snack('Invalid JSON.');
              }
            }),
          ]),
        );
      case 'server':
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_stats == null)
              Text('Loading…', style: TextStyle(fontSize: 12.5, color: context.lazy.muted)),
            if (_stats != null) ..._statRows(),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: UiGhostBtn(
                    _unloading == 'all' ? 'UNLOADING…' : 'UNLOAD ALL MODELS',
                    _unloading != null ? () {} : () => _unloadModels('all')),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: UiGhostBtn(
                    _unloading == 'vram' ? 'UNLOADING…' : 'UNLOAD VRAM ONLY',
                    _unloading != null ? () {} : () => _unloadModels('vram')),
              ),
            ]),
            const SizedBox(height: 6),
            UiDangerBtn(
                _restarting
                    ? 'RESTARTING COMFYUI…'
                    : (_restartArmed ? 'TAP AGAIN TO CONFIRM RESTART' : 'RESTART COMFYUI'),
                _restarting ? () {} : _restart),
          ]),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  List<Widget> _statRows() {
    final s = _stats!;
    final sys = (s['system'] is Map) ? Map<String, dynamic>.from(s['system']) : const {};
    String gb(dynamic v) {
      if (v is! num || v <= 0) return '?';
      return '${(v / 1073741824).toStringAsFixed(1)} GB';
    }

    String ram = '?';
    if (sys['ram_total'] is num) {
      final used = (sys['ram_total'] as num) - ((sys['ram_free'] as num?) ?? 0);
      ram = '${gb(used)} / ${gb(sys['ram_total'])}';
    }
    final rows = <Widget>[
      _kv('ComfyUI', '${sys['comfyui_version'] ?? '?'}'),
      _kv('OS', '${sys['os'] ?? '?'}'),
      _kv('RAM used', ram),
    ];
    final devs = (s['devices'] is List) ? s['devices'] : const [];
    for (final d in devs.whereType<Map>()) {
      String vram = 'n/a';
      if (d['vram_total'] is num) {
        final used = (d['vram_total'] as num) - ((d['vram_free'] as num?) ?? 0);
        vram = '${gb(used)} / ${gb(d['vram_total'])}';
      }
      rows.add(_kv('${d['name'] ?? 'GPU'} VRAM', vram));
    }
    return rows;
  }

  Widget _kv(String k, String v) {
    final c = context.lazy;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(children: [
        SizedBox(
            width: 110,
            child: Text(k, style: TextStyle(fontSize: 13, color: c.muted))),
        Expanded(
            child: Text(v,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: c.ink))),
      ]),
    );
  }

  Future<void> _loadRecent(_Recent r) async {
    try {
      if (r.source['type'] == 'user' && (r.path ?? '').isNotEmpty) {
        await _loadUserFile(r.path!);
      } else if (r.source['type'] == 'template') {
        final obj = await _api.workflowTemplate(
            '${r.source['module']}', '${r.source['name']}');
        if (!mounted) return;
        await _setWorkflow(obj, r.name, Map<String, dynamic>.from(r.source));
      } else {
        _snack('Local copies cannot be reloaded — load from disk again.');
      }
    } catch (e) {
      _snack(e is ApiException ? e.message : 'Load failed.');
    }
  }

  Future<void> _loadUserFile(String rel) async {
    try {
      final obj = await _api.userWorkflowGet(rel);
      final name = rel.split('/').last;
      if (!mounted) return;
      await _setWorkflow(obj, name, {'type': 'user', 'path': rel});
    } catch (e) {
      _snack(e is ApiException ? e.message : 'Load failed.');
    }
  }

  Future<void> _deleteUserFile(Map f) async {
    final rel = '${f['path'] ?? ''}'.replaceFirst(RegExp(r'^workflows/'), '');
    try {
      await _api.userWorkflowDelete(rel);
      if (!mounted) return;
      setState(() => _userFiles.removeWhere((x) => x == f));
      _snack('Deleted.', ok: true);
    } catch (e) {
      _snack(e is ApiException ? e.message : 'Delete failed.');
    }
  }

  Future<void> _loadTemplate(String mod, String name) async {
    try {
      final obj = await _api.workflowTemplate(mod, name);
      if (!mounted) return;
      await _setWorkflow(obj, name, {'type': 'template', 'module': mod, 'name': name});
    } catch (e) {
      _snack(e is ApiException ? e.message : 'Load failed.');
    }
  }
}

/// Small looping player for custom-page video outputs.
class _MiniPlayer extends StatefulWidget {
  final String url;
  const _MiniPlayer({required this.url});

  @override
  State<_MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<_MiniPlayer> {
  VideoPlayerController? _ctrl;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    final c = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    c.initialize().then((_) {
      if (!mounted) return;
      c.setLooping(true);
      c.play();
      setState(() => _ctrl = c);
    }).catchError((_) {
      if (mounted) setState(() => _failed = true);
    });
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return const SizedBox(
        height: 200,
        child: Center(child: Icon(Icons.broken_image_outlined)),
      );
    }
    final c = _ctrl;
    if (c == null) {
      return const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return AspectRatio(
      aspectRatio: c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
      child: VideoPlayer(c),
    );
  }
}
