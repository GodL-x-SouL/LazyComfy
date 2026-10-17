import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import 'api_client.dart';
import 'edge_frost.dart';
import 'lazy_theme.dart';
import 'native_downloads.dart';
import 'ui_kit.dart';

/// Native port of the next-app Video page (MiniMax H3 / LTX 2.5):
/// t2i + i2v, file pickers, LoRA stack, progress over the ComfyUI socket,
/// gallery with in-app playback.
class NativeVideoPage extends StatefulWidget {
  final String endpoint;
  final bool isDark;
  final VoidCallback onToggleTheme;
  const NativeVideoPage({
    super.key,
    required this.endpoint,
    required this.isDark,
    required this.onToggleTheme,
  });

  @override
  State<NativeVideoPage> createState() => _NativeVideoPageState();
}

class _VJob {
  final List<UiImg> videos;
  final String modelId;
  final String mode;
  final String prompt;
  final Map<String, dynamic> params;
  final String promptId;
  const _VJob({
    required this.videos,
    required this.modelId,
    required this.mode,
    required this.prompt,
    required this.params,
    required this.promptId,
  });
}

class _NativeVideoPageState extends State<NativeVideoPage> {
  late LazyApi _api;
  bool _syncing = true;
  String? _error;

  List<dynamic> _models = [];
  Map<String, dynamic> _dirs = {};
  List<dynamic> _inputLib = [];
  String _modelId = '';
  String _mode = 't2i';
  Map<String, String> _fileSel = {};
  final Map<String, Map<String, String>> _filesByModel = {};
  String _lora = '';
  List<Map<String, dynamic>> _loraStack = [];
  UiImg? _input;

  late final TextEditingController _promptCtrl;
  late final TextEditingController _wCtrl;
  late final TextEditingController _hCtrl;
  late final TextEditingController _lenCtrl;
  late final TextEditingController _fpsCtrl;
  late final TextEditingController _stepsCtrl;
  late final TextEditingController _seedCtrl;
  late final TextEditingController _loraStrCtrl;
  String _sampler = '';
  String _scheduler = '';

  String? _promptId;
  String _jobState = 'Idle';
  double? _progress;
  _VJob? _current;
  List<dynamic> _history = [];
  int _queueN = 0;
  final Set<String> _dead = {};
  StreamSubscription<Map<String, dynamic>>? _wsSub;
  Timer? _pollTimer;
  Timer? _idleTimer;
  // Node id → class_type for the running prompt (+ registry display
  // names), so progress names the node instead of printing its number.
  Map<String, String> _nodeTypes = {};
  Map<String, String> _nodeNames = {};

  Map<String, dynamic>? get _model {
    for (final m in _models) {
      if (m is Map && m['id'] == _modelId) return Map<String, dynamic>.from(m);
    }
    return null;
  }

  bool _dirHas(String dir, String name) {
    final v = _dirs[dir];
    return v is List && v.map((e) => '$e').contains(name);
  }

  List<String> _missing() {
    final m = _model;
    if (m == null || m['files'] is! List) return [];
    return (m['files'] as List).whereType<Map>().where((f) {
      final sel = _fileSel['${f['kind']}'];
      final want = (sel != null && sel.isNotEmpty) ? sel : '${f['name']}';
      return !_dirHas('${f['dir']}', want);
    }).map((f) => '${f['label']}').toList();
  }

  void _unfocus() => FocusManager.instance.primaryFocus?.unfocus();

  @override
  void initState() {
    super.initState();
    _api = LazyApi(widget.endpoint);
    _promptCtrl = TextEditingController();
    _wCtrl = TextEditingController();
    _hCtrl = TextEditingController();
    _lenCtrl = TextEditingController();
    _fpsCtrl = TextEditingController();
    _stepsCtrl = TextEditingController();
    _seedCtrl = TextEditingController();
    _loraStrCtrl = TextEditingController(text: '1');
    _boot();
    _idleTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && _promptId == null) _syncHistory();
    });
  }

  @override
  void didUpdateWidget(covariant NativeVideoPage oldWidget) {
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
    _idleTimer?.cancel();
    _api.close();
    _promptCtrl.dispose();
    _wCtrl.dispose();
    _hCtrl.dispose();
    _lenCtrl.dispose();
    _fpsCtrl.dispose();
    _stepsCtrl.dispose();
    _seedCtrl.dispose();
    _loraStrCtrl.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    final p = await SharedPreferences.getInstance();
    List<dynamic> models = const [];
    Map<String, dynamic> dirs = const {};
    try {
      final raw = p.getString('lazycomfy.native.cache.video_models');
      if (raw != null && raw.isNotEmpty) {
        final d = json.decode(raw);
        if (d is List) models = d;
      }
    } catch (_) {}
    try {
      final raw = p.getString('lazycomfy.native.cache.dirs');
      if (raw != null && raw.isNotEmpty) {
        final d = json.decode(raw);
        if (d is Map) dirs = Map<String, dynamic>.from(d);
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _models = models;
      _dirs = dirs;
      _promptCtrl.text = p.getString('lazycomfy.native.video.prompt') ?? '';
      final saved = p.getString('lazycomfy.native.video.model') ?? '';
      if (_models.any((m) => m is Map && m['id'] == saved)) _modelId = saved;
      _applyModelDefaults();
      _restoreState(p);
    });
    await _sync();
  }

  /// Overlay persisted picks/fields over the model defaults (boot only).
  void _restoreState(SharedPreferences p) {
    final m = _model;
    if (m == null) return;
    final modes = List<String>.from(m['modes'] ?? ['t2i']);
    final savedMode = p.getString('lazycomfy.native.video.mode') ?? '';
    if (savedMode.isNotEmpty && modes.contains(savedMode)) _mode = savedMode;
    try {
      final raw = p.getString('lazycomfy.native.video.files');
      if (raw != null && raw.isNotEmpty) {
        final d = json.decode(raw);
        if (d is Map) {
          if (d.isNotEmpty && d.values.every((v) => v is String)) {
            // legacy flat map: applies to this boot's model only
            _filesByModel[_modelId] = d.map((k, v) => MapEntry('$k', '$v'));
          } else {
            for (final e in d.entries) {
              final v = e.value;
              if (v is Map) _filesByModel['${e.key}'] = v.map((k, x) => MapEntry('$k', '$x'));
            }
          }
          _fileSel = Map<String, String>.from(_filesByModel[_modelId] ?? {});
        }
      }
    } catch (_) {}
    _lora = p.getString('lazycomfy.native.video.lora') ?? '';
    try {
      final raw = p.getString('lazycomfy.native.video.lora_stack');
      if (raw != null && raw.isNotEmpty) {
        final d = json.decode(raw);
        if (d is List) {
          _loraStack = [
            for (final s in d)
              if (s is Map)
                {'name': '${s['name'] ?? ''}', 'strength': (s['strength'] as num?)?.toDouble() ?? 1.0}
          ];
        }
      }
    } catch (_) {}
    try {
      final raw = p.getString('lazycomfy.native.video.fields');
      if (raw != null && raw.isNotEmpty) {
        final d = json.decode(raw);
        if (d is Map) {
          void set(TextEditingController c, String k) {
            final v = d[k];
            if (v is String && v.isNotEmpty) c.text = v;
          }

          set(_wCtrl, 'w');
          set(_hCtrl, 'h');
          set(_lenCtrl, 'len');
          set(_fpsCtrl, 'fps');
          set(_stepsCtrl, 'steps');
          set(_seedCtrl, 'seed');
          set(_loraStrCtrl, 'loraStr');
          if (d['sampler'] is String) _sampler = d['sampler'];
          if (d['scheduler'] is String) _scheduler = d['scheduler'];
        }
      }
    } catch (_) {}
    _validatePicks();
  }

  /// Drop picks whose file vanished from the fresh dir listing; keep
  /// everything else. Unknown (empty) listings keep the pick.
  void _validatePicks() {
    final m = _model;
    if (m == null) return;
    for (final f in (m['files'] as List? ?? []).whereType<Map>()) {
      final kind = '${f['kind']}';
      final sel = _fileSel[kind];
      if (sel == null || sel.isEmpty) continue;
      final names = _dirNames('${f['dir']}');
      if (names.isNotEmpty && !names.contains(sel)) _fileSel.remove(kind);
    }
    final loras = _dirNames('loras');
    if (loras.isNotEmpty) {
      if (_lora.isNotEmpty && !loras.contains(_lora)) _lora = '';
      _loraStack.removeWhere(
          (s) => '${s['name']}'.isNotEmpty && !loras.contains('${s['name']}'));
    }
  }

  Future<T> _step<T>(String name, Future<T> Function() fn) async {
    try {
      return await fn();
    } on ApiException catch (e) {
      throw ApiException('$name: ${e.message}');
    } catch (e) {
      throw ApiException('$name: $e');
    }
  }

  Future<void> _sync() async {
    setState(() {
      _syncing = true;
      _error = null;
    });
    try {
      final cfg = await _step('video', _api.videoConfig);
      final models = (cfg['models'] is List) ? List<dynamic>.from(cfg['models']) : const [];
      final dirs = await _step('files', _api.fileDirs);
      final hist = await _step('history', () => _api.videoHistory(12));
      List<dynamic> inputs = const [];
      try {
        inputs = await _api.inputImages();
      } catch (_) {}
      int queueN = 0;
      try {
        queueN = await _api.videoQueue();
      } catch (_) {}
      if (!mounted) return;
      final p = await SharedPreferences.getInstance();
      try {
        await p.setString('lazycomfy.native.cache.video_models', json.encode(models));
        await p.setString('lazycomfy.native.cache.dirs', json.encode(dirs));
      } catch (_) {}
      setState(() {
        _models = models;
        _dirs = Map<String, dynamic>.from(dirs);
        _history = _liveJobs(hist);
        _inputLib = inputs;
        _queueN = queueN;
        if (_models.isNotEmpty && _model == null) {
          _modelId = ((_models.first as Map)['id'] as String?) ?? '';
          // Fresh model pick: full reset to its defaults.
          _applyModelDefaults();
        } else if (_model != null) {
          // Same model still here: keep the user's picks/fields, only
          // drop files that vanished server-side.
          _validatePicks();
        }
        _syncing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _syncing = false;
        _error = e is ApiException ? e.message : 'Sync failed: $e';
      });
    }
  }

  List<dynamic> _liveJobs(List<dynamic> hist) {
    final out = <dynamic>[];
    for (final j in hist) {
      if (j is! Map) continue;
      final vids = _jobMedia(j);
      if (vids.isEmpty) continue;
      final copy = Map<String, dynamic>.from(j);
      out.add(copy);
    }
    return out;
  }

  List<UiImg> _jobMedia(Map j) {
    final out = <UiImg>[];
    for (final key in ['videos', 'outputs', 'images', 'gifs']) {
      final arr = j[key];
      if (arr is! List) continue;
      for (final o in arr.whereType<Map>()) {
        if (o['filename'] == null) continue;
        final im = UiImg('${o['filename']}', '${o['subfolder'] ?? ''}',
            '${o['type'] ?? 'output'}');
        if (!_dead.contains(im.key) && !out.any((e) => e.key == im.key)) {
          out.add(im);
        }
      }
    }
    return out;
  }

  Future<void> _syncHistory() async {
    try {
      final hist = await _api.videoHistory(12);
      if (!mounted) return;
      setState(() => _history = _liveJobs(hist));
    } catch (_) {}
  }

  void _applyModelDefaults() {
    final m = _model;
    if (m == null) return;
    final modes = List<String>.from(m['modes'] ?? ['t2i']);
    if (!modes.contains(_mode)) _mode = modes.first;
    final d = Map<String, dynamic>.from(m['defaults'] ?? {});
    _wCtrl.text = '${d['width'] ?? 1280}';
    _hCtrl.text = '${d['height'] ?? 736}';
    _lenCtrl.text = '${d['length'] ?? 97}';
    _fpsCtrl.text = '${d['fps'] ?? 24}';
    _stepsCtrl.text = '${d['steps'] ?? 8}';
    _sampler = '${d['sampler'] ?? ''}';
    _scheduler = '${d['scheduler'] ?? ''}';
    _fileSel = Map<String, String>.from(_filesByModel[_modelId] ?? {});
    _lora = '';
    _loraStack = [];
  }

  List<String> _dirNames(String dir) {
    final v = _dirs[dir];
    if (v is List) return v.map((e) => '$e').toList();
    return const [];
  }

  Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('lazycomfy.native.video.model', _modelId);
    await p.setString('lazycomfy.native.video.prompt', _promptCtrl.text);
    await p.setString('lazycomfy.native.video.mode', _mode);
    _filesByModel[_modelId] = Map<String, String>.from(_fileSel);
    await p.setString('lazycomfy.native.video.files', json.encode(_filesByModel));
    await p.setString('lazycomfy.native.video.lora', _lora);
    await p.setString('lazycomfy.native.video.lora_stack', json.encode(_loraStack));
    await p.setString('lazycomfy.native.video.fields', json.encode({
      'w': _wCtrl.text,
      'h': _hCtrl.text,
      'len': _lenCtrl.text,
      'fps': _fpsCtrl.text,
      'steps': _stepsCtrl.text,
      'seed': _seedCtrl.text,
      'loraStr': _loraStrCtrl.text,
      'sampler': _sampler,
      'scheduler': _scheduler,
    }));
  }

  /// Save context whenever the page hides so nothing is lost.
  @override
  void deactivate() {
    _persist();
    super.deactivate();
  }

  void _openDownloads() {
    _unfocus();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NativeDownloadsPage(endpoint: widget.endpoint, onChanged: _sync),
      ),
    );
  }

  Future<void> _pickInput() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
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
      if (bytes == null || bytes.isEmpty) {
        _snack('Could not read that image.');
        return;
      }
      setState(() => _jobState = 'Uploading…');
      final up = await _api.uploadImage(bytes, f.name);
      if (!mounted) return;
      setState(() {
        _input = UiImg(up['name']!, up['subfolder']!, 'input');
        _jobState = 'Idle';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _jobState = 'Idle');
      _snack(e is ApiException ? e.message : 'Pick failed.');
    }
  }

  Future<void> _generate() async {
    _unfocus();
    final m = _model;
    if (m == null) {
      _snack('Pick a model first.');
      return;
    }
    if (_mode == 't2i' && _promptCtrl.text.trim().isEmpty) {
      _snack('Describe your video first.');
      return;
    }
    if (_mode == 'i2i' && _input == null) {
      _snack('Pick an input image first.');
      return;
    }
    final miss = _missing();
    if (miss.isNotEmpty) {
      _snack('Missing: ${miss.join(', ')}.');
      return;
    }
    setState(() {
      _jobState = 'Queueing…';
      _progress = 0;
      _error = null;
    });
    try {
      final clientId = await getClientId();
      final d = Map<String, dynamic>.from(m['defaults'] ?? {});
      final l = Map<String, dynamic>.from(m['limits'] ?? {});
      int cl(String v, int lo, int hi, int dflt) {
        final n = int.tryParse(v);
        if (n == null) return dflt;
        return n.clamp(lo, hi);
      }

      final body = <String, dynamic>{
        'model_id': _modelId,
        'mode': _mode,
        'prompt': _promptCtrl.text,
        'width': cl(_wCtrl.text, (l['width_min'] as int?) ?? 32, (l['width_max'] as int?) ?? 2048,
            (d['width'] as int?) ?? 1280),
        'height': cl(_hCtrl.text, (l['height_min'] as int?) ?? 32,
            (l['height_max'] as int?) ?? 2048, (d['height'] as int?) ?? 736),
        'length': cl(_lenCtrl.text, (l['length_min'] as int?) ?? 5,
            (l['length_max'] as int?) ?? 361, (d['length'] as int?) ?? 97),
        'fps': cl(_fpsCtrl.text, 1, 60, (d['fps'] as int?) ?? 24),
        'steps': cl(_stepsCtrl.text, (l['steps_min'] as int?) ?? 1,
            (l['steps_max'] as int?) ?? 50, (d['steps'] as int?) ?? 8),
        'sampler': _sampler.isNotEmpty ? _sampler : '${d['sampler'] ?? ''}',
        'scheduler': _scheduler.isNotEmpty ? _scheduler : '${d['scheduler'] ?? ''}',
        'client_id': clientId,
      };
      final seed = int.tryParse(_seedCtrl.text.trim());
      body['seed'] = seed ??
          (DateTime.now().millisecondsSinceEpoch % 9007199254740991);
      final files = <String, String>{};
      for (final f in (m['files'] as List? ?? [])) {
        if (f is! Map) continue;
        final sel = _fileSel['${f['kind']}'];
        if (sel != null && sel.isNotEmpty) files['${f['kind']}'] = sel;
      }
      if (files.isNotEmpty) body['files'] = files;
      final loras = <Map<String, dynamic>>[];
      if (_lora.isNotEmpty) {
        loras.add({'name': _lora, 'strength': double.tryParse(_loraStrCtrl.text) ?? 1.0});
      }
      for (final s in _loraStack) {
        if ('${s['name']}'.isNotEmpty) {
          loras.add({'name': '${s['name']}', 'strength': (s['strength'] as num?)?.toDouble() ?? 1.0});
        }
      }
      if (loras.isNotEmpty) body['loras'] = loras;
      if (_mode == 'i2i' && _input != null) {
        body['image'] = {'name': _input!.filename, 'subfolder': _input!.subfolder};
      }
      final id = await _api.videoGenerate(body);
      if (!mounted) return;
      setState(() {
        _promptId = id;
        _jobState = 'Running…';
      });
      _persist();
      try {
        _queueN = await _api.videoQueue();
        if (mounted) setState(() {});
      } catch (_) {}
      _watch(id, clientId);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _jobState = 'Error';
        _progress = null;
      });
      _snack(e is ApiException ? e.message : 'Queue failed.');
    }
  }

  void _watch(String id, String clientId) {
    _wsSub?.cancel();
    _pollTimer?.cancel();
    _nodeTypes = {};
    _nodeNames = {};
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
      } else if (type == 'executing' && data['node'] != null) {
        final nodeId = '${data['node']}';
        setState(() => _jobState = 'Working…');
        _resolveNode(id, nodeId);
      } else if (type == 'executed' || type == 'execution_success') {
        _finish(id);
      } else if (type == 'execution_error') {
        _fail('Run failed.');
      } else if (type == 'execution_interrupted') {
        _fail('Run cancelled.', cancelled: true);
      }
    }, onError: (_) {});
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _finish(id));
  }

  /// Names the executing node: node id → class_type from the running
  /// queue entry, then registry display name / friendly word. Silent on
  /// any failure — the 'Working…' label simply stays.
  Future<void> _resolveNode(String id, String nodeId) async {
    try {
      if (_nodeTypes.isEmpty) {
        final types = await _api.runningNodeTypes(id);
        if (!mounted || _promptId != id) return;
        _nodeTypes = types;
        _nodeNames = await _api.objectDisplayNames();
        if (!mounted || _promptId != id) return;
      }
      final cls = _nodeTypes[nodeId];
      if (cls == null || cls.isEmpty) return;
      if (!mounted || _promptId != id) return;
      setState(() => _jobState = '${nodeDisplayName(cls, _nodeNames[cls])}…');
    } catch (_) {}
  }

  Future<void> _finish(String id) async {
    if (_promptId != id || !mounted) return;
    Map<String, dynamic> r;
    try {
      r = await _api.videoResult(id);
    } catch (_) {
      return;
    }
    if (!mounted || _promptId != id) return;
    final status = r['status'];
    if (status == 'success') {
      final vids = _resultMedia(r);
      if (vids.isEmpty) return;
      _wsSub?.cancel();
      _pollTimer?.cancel();
      final meta = (r['meta'] is Map) ? Map<String, dynamic>.from(r['meta']) : <String, dynamic>{};
      final job = _VJob(
        videos: vids,
        modelId: '${meta['model_id'] ?? _modelId}',
        mode: '${meta['mode'] ?? _mode}',
        prompt: '${meta['prompt'] ?? _promptCtrl.text}',
        params: (meta['params'] is Map)
            ? Map<String, dynamic>.from(meta['params'])
            : <String, dynamic>{},
        promptId: id,
      );
      setState(() {
        _promptId = null;
        _progress = null;
        _jobState = 'Done';
        _current = job;
      });
      _snack('Run finished — tap the result to view it.', ok: true);
      _syncHistory();
    } else if (status == 'error') {
      final err = r['error'];
      _fail(err is Map ? '${err['message'] ?? err['type'] ?? 'Failed'}' : 'Run failed.');
    }
  }

  List<UiImg> _resultMedia(Map<String, dynamic> r) {
    for (final key in ['videos', 'outputs', 'images', 'gifs']) {
      final arr = r[key];
      if (arr is! List) continue;
      final out = arr.whereType<Map>().where((o) => o['filename'] != null).map((o) =>
          UiImg('${o['filename']}', '${o['subfolder'] ?? ''}', '${o['type'] ?? 'output'}')).toList();
      if (out.isNotEmpty) return out;
    }
    return const [];
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
    final id = _promptId;
    if (id == null) return;
    setState(() => _jobState = 'Cancelling…');
    try {
      await _api.videoCancel(id);
    } catch (_) {}
  }

  void _snack(String msg, {bool ok = false}) {
    if (!mounted) return;
    showUiSnack(context, msg, ok: ok);
  }

  Future<void> _save(UiImg v) async {
    try {
      final uri = Uri.parse(_api.viewUrl(filename: v.filename, subfolder: v.subfolder, type: v.type));
      final res = await http.get(uri).timeout(const Duration(minutes: 10));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final saved = await FilePicker.platform.saveFile(fileName: v.filename, bytes: res.bodyBytes);
      if (!mounted) return;
      _snack(saved == null ? 'Download cancelled.' : 'Saved: $saved', ok: saved != null);
    } catch (_) {
      _snack('Download failed. Check the connection and retry.');
    }
  }

  Future<void> _deleteJobVideo(_VJob job, UiImg v) async {
    try {
      await _api.deleteMedia(filename: v.filename, subfolder: v.subfolder, type: v.type);
      _snack('Video deleted.', ok: true);
    } catch (e) {
      _snack(e is ApiException ? e.message : 'Delete failed.');
      return;
    }
    if (!mounted) return;
    setState(() => _dead.add(v.key));
    final rest = job.videos.where((im) => im.key != v.key).toList();
    Navigator.pop(context);
    if (rest.isEmpty) {
      if (_current?.promptId == job.promptId) setState(() => _current = null);
    } else {
      _viewJob(_VJob(
          videos: rest,
          modelId: job.modelId,
          mode: job.mode,
          prompt: job.prompt,
          params: job.params,
          promptId: job.promptId));
    }
    _syncHistory();
  }

  void _viewJob(_VJob job) {
    showDialog(
      context: context,
      builder: (dlg) {
        final c = Theme.of(dlg).extension<LazyColors>()!;
        var idx = 0;
        return StatefulBuilder(
          builder: (dlg2, setDlg) {
            final v = job.videos[idx.clamp(0, job.videos.length - 1)];
            // Explicit ✕ over the preview corner: no hunting for
            // outside-tap to dismiss.
            return Dialog(
              backgroundColor: c.bgCard,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                  child: Stack(children: [
                    // GIFs/stills sometimes arrive as "videos" (LTX previews,
                    // image fallbacks): ExoPlayer cannot play those, so they
                    // render as plain images instead of a dead player.
                    if (isPlayableVideo(v.filename))
                      _Player(url: _api.viewUrl(filename: v.filename, subfolder: v.subfolder, type: v.type))
                    else
                      CachedNetworkImage(
                        imageUrl: _api.viewUrl(filename: v.filename, subfolder: v.subfolder, type: v.type),
                        fit: BoxFit.contain,
                        errorWidget: (_, __, ___) => const Padding(
                          padding: EdgeInsets.all(32),
                          child: Icon(Icons.broken_image_outlined),
                        ),
                      ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: uiCloseChip(() => Navigator.pop(context)),
                    ),
                  ]),
                ),
                if (job.videos.length > 1)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Row(children: [
                      for (int i = 0; i < job.videos.length; i++)
                        Padding(
                          padding: EdgeInsets.only(right: i + 1 < job.videos.length ? 6 : 0),
                          child: GestureDetector(
                            onTap: () => setDlg(() => idx = i),
                            child: Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: i == idx ? c.accent : c.border,
                                    width: i == idx ? 2 : 1),
                                color: c.bgSoft,
                              ),
                              child: const Icon(Icons.movie_outlined, size: 20),
                            ),
                          ),
                        ),
                    ]),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Text(_metaLine(job), style: fmono(11, c.ink3)),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    UiGhostBtn('Download', () {
                      Navigator.pop(context);
                      _save(v);
                    }),
                    UiGhostBtn('Copy prompt', () {
                      Clipboard.setData(ClipboardData(text: job.prompt));
                      Navigator.pop(context);
                      _snack('Prompt copied.', ok: true);
                    }),
                    UiDangerBtn('Delete', () => _confirmDelete(job, v)),
                  ]),
                ),
              ]),
            );
          },
        );
      },
    );
  }

  void _confirmDelete(_VJob job, UiImg v) {
    final c = context.lazy;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: c.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
        contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
        actionsPadding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        title: Text('Delete video?', style: disp(19, FontWeight.w700, c.ink)),
        content: Text(v.filename, style: TextStyle(fontSize: 13.5, color: c.muted)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
            child: Text('Keep', style: TextStyle(color: c.ink2, fontSize: 15)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteJobVideo(job, v);
            },
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
            child: Text('Delete', style: TextStyle(color: c.err, fontSize: 15)),
          ),
        ],
      ),
    );
  }

  String _metaLine(_VJob job) {
    var name = job.modelId;
    for (final m in _models) {
      if (m is Map && '${m['id']}' == job.modelId) {
        name = '${m['name'] ?? name}';
        break;
      }
    }
    final p = job.params;
    var meta = '$name · ${job.mode == 'i2i' ? 'img2vid' : 'text2vid'}';
    if (p['width'] != null && p['height'] != null) meta += ' · ${p['width']}×${p['height']}';
    if (p['length'] != null) meta += ' · ${p['length']}f';
    if (p['fps'] != null) meta += ' · ${p['fps']}fps';
    if (p['steps'] != null) meta += ' · ${p['steps']} steps';
    if (p['seed'] != null) meta += ' · seed ${p['seed']}';
    return meta;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.lazy;
    final mq = MediaQuery.paddingOf(context);
    final m = _model;
    final miss = _missing();
    final canRun = _promptId == null && !(_syncing && _models.isEmpty) && miss.isEmpty;
    const headerH = 42.0;
    return Scaffold(
      backgroundColor: c.bg,
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _sync,
            child: ListView(
              padding: EdgeInsets.fromLTRB(16, mq.top + headerH + 12, 16, mq.bottom + 24),
              children: [
                _pageHeader('Video'),
                const SizedBox(height: 12),
                if (_error != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: c.err.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: c.err.withValues(alpha: 0.35)),
                    ),
                    child: Text(_error!, style: TextStyle(color: c.err, fontSize: 12)),
                  ),
                uiCard(context, [
                  uiSection(context, 'Model'),
                  UiSelect(
                    value: _modelId.isEmpty ? null : _modelId,
                    items: {for (final x in _models) if (x is Map) '${x['id']}': '${x['name'] ?? x['id']}'},
                    hints: {for (final x in _models) if (x is Map) '${x['id']}': _modelHint(x)},
                    hint: _models.isEmpty ? 'Loading…' : 'Select a model…',
                    sheetTitle: 'Pick a model',
                    onChanged: (v) {
                      if (v == null) return;
                      FocusManager.instance.primaryFocus?.unfocus();
                      setState(() {
                        _modelId = v;
                        _applyModelDefaults();
                      });
                      _persist();
                    },
                  ),
                  if ((m?['family'] ?? '') != '') ...[
                    const SizedBox(height: 6),
                    Text('${m!['family']}', style: TextStyle(fontSize: 12.5, color: c.muted)),
                  ],
                  if ((m?['tagline'] ?? '') != '' && (m?['family'] ?? '') == '') ...[
                    const SizedBox(height: 6),
                    Text('${m!['tagline']}', style: TextStyle(fontSize: 12.5, color: c.muted)),
                  ],
                  if (m != null && (m['modes'] as List? ?? []).length > 1) ...[
                    const SizedBox(height: 10),
                    UiSeg(
                      options: List<String>.from(m['modes']),
                      value: _mode,
                      labels: const {'t2i': 'Text to video', 'i2i': 'Image to video'},
                      onChanged: (v) {
                        FocusManager.instance.primaryFocus?.unfocus();
                        setState(() => _mode = v);
                      },
                    ),
                  ],
                  if (miss.isNotEmpty && m != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: UiErrBanner(
                        'Missing files: ${miss.join(', ')} — download them from Models.',
                        onTap: _openDownloads,
                      ),
                    ),
                ]),
                uiCard(context, [
                  uiSection(context, 'Prompt'),
                  uiTextField(context, _promptCtrl, 'Describe your video…', maxLines: 4),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('${_promptCtrl.text.length} chars', style: fmono(10.5, c.muted2)),
                  ),
                  if (_mode == 'i2i') ...[
                    const SizedBox(height: 10),
                    uiField(context, 'Input image'),
                    _inputDrop(),
                    const SizedBox(height: 10),
                    uiField(context, 'Or pick from input folder'),
                    UiSelect(
                      value: null,
                      items: {
                        '': _inputLib.isEmpty ? 'No images…' : 'Choose an image…',
                        for (final x in _inputLib)
                          if (x is Map)
                            _libKey(x): _libKey(x),
                      },
                      hint: 'Choose an image…',
                      sheetTitle: 'Or pick from input folder',
                      onChanged: (v) {
                        if (v == null || v.isEmpty) return;
                        final found = _inputLib.whereType<Map>().firstWhere(
                              (x) => _libKey(x) == v,
                              orElse: () => <String, dynamic>{},
                            );
                        if (found.isNotEmpty) {
                          setState(() => _input = UiImg('${found['name']}',
                              '${found['subfolder'] ?? ''}', 'input'));
                        }
                      },
                    ),
                  ],
                ]),
                if (m != null)
                  uiCard(context, [
                    uiSection(context, 'Files & LoRA'),
                    for (final f in (m['files'] as List? ?? []))
                      if (f is Map) ...[
                        uiField(context, '${f['label'] ?? f['kind']}'),
                        _fileSelect(f),
                        const SizedBox(height: 10),
                      ],
                    uiField(context, 'LoRA (optional)'),
                    UiSelect(
                      value: _lora.isEmpty ? '' : _lora,
                      items: {'': 'None', for (final n in _dirNames('loras')) n: n},
                      hint: 'None',
                      sheetTitle: 'LoRA (optional)',
                      onChanged: (v) => setState(() => _lora = (v == null || v.isEmpty) ? '' : v),
                    ),
                    if (_lora.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      uiField(context,
                          'LoRA strength (${trimNum(double.tryParse(_loraStrCtrl.text) ?? 1)})'),
                      UiSlider(
                        value: (double.tryParse(_loraStrCtrl.text) ?? 1).clamp(0.0, 5.0),
                        onChanged: (v) => setState(() => _loraStrCtrl.text = trimNum(v)),
                      ),
                    ],
                    for (int i = 0; i < _loraStack.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(children: [
                          Expanded(
                            child: UiSelect(
                              value: '${_loraStack[i]['name']}'.isEmpty
                                  ? ''
                                  : '${_loraStack[i]['name']}',
                              items: {
                                '': 'None',
                                for (final n in _dirNames('loras')) n: n,
                              },
                              hint: 'None',
                              sheetTitle: 'LoRA (optional)',
                              onChanged: (v) => setState(() => _loraStack[i] = {
                                    'name': v ?? '',
                                    'strength': _loraStack[i]['strength']
                                  }),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: UiSlider(
                              value: ((_loraStack[i]['strength'] as num?)?.toDouble() ?? 1)
                                  .clamp(0.0, 5.0),
                              onChanged: (v) => setState(() => _loraStack[i] = {
                                    'name': _loraStack[i]['name'],
                                    'strength': double.parse(v.toStringAsFixed(2)),
                                  }),
                            ),
                          ),
                          GestureDetector(
                            onTap: () => setState(() => _loraStack.removeAt(i)),
                            child: Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: Text('✕', style: TextStyle(fontSize: 14, color: c.muted2)),
                            ),
                          ),
                        ]),
                      ),
                      if (_loraStack.length < 4)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: UiGhostBtn('+ LoRA',
                              () => setState(() => _loraStack.add({'name': '', 'strength': 1.0}))),
                        ),
                  ]),
                if (m != null)
                  uiCard(context, [
                    uiSection(context, 'Settings'),
                    Row(children: [
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              uiField(context, 'Width'),
                              uiTextField(context, _wCtrl, 'W', number: true),
                            ]),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              uiField(context, 'Height'),
                              uiTextField(context, _hCtrl, 'H', number: true),
                            ]),
                      ),
                    ]),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              uiField(context, 'Length (frames)'),
                              uiTextField(context, _lenCtrl, '97', number: true, decimal: false),
                            ]),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              uiField(context, 'FPS'),
                              uiTextField(context, _fpsCtrl, '24', number: true, decimal: false),
                            ]),
                      ),
                    ]),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                        flex: 2,
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              uiField(context, 'Steps'),
                              uiTextField(context, _stepsCtrl, 'Steps', number: true, decimal: false),
                            ]),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 5,
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              uiField(context,
                                  'Seed${_seedCtrl.text.trim().isEmpty ? ' (random)' : ''}'),
                              Row(children: [
                                Expanded(
                                    child: uiTextField(context, _seedCtrl, 'random', number: true)),
                                const SizedBox(width: 8),
                                GestureDetector(
                                  onTap: () => setState(() => _seedCtrl.text =
                                      '${DateTime.now().millisecondsSinceEpoch % 9007199254740991}'),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 11),
                                    decoration: BoxDecoration(
                                      border: Border.all(color: c.border),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Icon(Icons.casino_outlined, size: 16, color: c.ink2),
                                  ),
                                ),
                              ]),
                            ]),
                      ),
                    ]),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              uiField(context, 'Sampler'),
                              UiSelect(
                                value: _sampler.isEmpty ? null : _sampler,
                                items: {
                                  for (final s in (m['options']?['samplers'] as List? ?? []))
                                    '$s': '$s',
                                },
                                hint: 'Sampler',
                                sheetTitle: 'Sampler',
                                onChanged: (v) => setState(() => _sampler = v ?? ''),
                              ),
                            ]),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              uiField(context, 'Scheduler'),
                              UiSelect(
                                value: _scheduler.isEmpty ? null : _scheduler,
                                items: {
                                  for (final s in (m['options']?['schedulers'] as List? ?? []))
                                    '$s': '$s',
                                },
                                hint: 'Scheduler',
                                sheetTitle: 'Scheduler',
                                onChanged: (v) => setState(() => _scheduler = v ?? ''),
                              ),
                            ]),
                      ),
                    ]),
                  ]),
                uiCard(context, [
                  uiSection(context, _jobState, noPad: true),
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
                  const SizedBox(height: 12),
                  // One button: Generate idle, Cancel (red) while running.
                  if (_promptId != null)
                    UiPrimaryBtn('Cancel', _cancel, danger: true)
                  else
                    UiPrimaryBtn(
                      'Generate',
                      canRun ? _generate : null,
                    ),
                  if (_queueN > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('$_queueN queued', style: fmono(10, c.muted2, ls: 0.06)),
                    ),
                ]),
                const SizedBox(height: 4),
                uiCard(context, [
                  uiSection(context, _current != null ? 'Result' : 'Recent'),
                  if (_current != null) ...[
                    _resultBox(),
                    const SizedBox(height: 12),
                    uiSection(context, 'Recent'),
                  ],
                  _jobTiles(),
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
            child: SizedBox(height: headerH, child: _header()),
          ),
        ],
      ),
    );
  }

  String _modelHint(Map x) {
    final files = (x['files'] is List) ? List<dynamic>.from(x['files']) : const [];
    final missing = files.whereType<Map>().where((f) {
      final sel = _fileSel['${f['kind']}'];
      return !_dirHas('${f['dir']}', (sel != null && sel.isNotEmpty) ? sel : '${f['name']}');
    }).map((f) => '${f['label']}');
    if (missing.isNotEmpty) return 'Missing: ${missing.join(', ')}';
    return '${x['family'] ?? x['tagline'] ?? ''}';
  }

  /// Shared sticky header: frosted brand + sync dot + downloads shortcut.
  Widget _header() {
    final c = context.lazy;
    final dark = context.isDark;
    final dot = _error != null ? c.err : (_syncing ? c.warn : c.ok);
    final dotLabel = _error != null ? 'OFFLINE' : (_syncing ? 'SYNCING' : 'SYNCED');
    return Row(children: [
      UiBrand(dark: dark),
      const Spacer(),
      Container(width: 8, height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: dot)),
      const SizedBox(width: 6),
      Text(dotLabel, style: fmono(10, c.muted2, ls: 0.06)),
      const SizedBox(width: 8),
      UiHeadBtn(Icons.download_rounded, 'Model downloads', _openDownloads),
      const SizedBox(width: 8),
      UiHeadBtn(
        widget.isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
        widget.isDark ? 'Switch to light mode' : 'Switch to dark mode',
        widget.onToggleTheme,
      ),
    ]);
  }

  Widget _pageHeader(String title) {
    final c = context.lazy;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(title, style: disp(16, FontWeight.w700, c.ink)),
    );
  }

  String _libKey(Map x) {
    final sub = '${x['subfolder'] ?? ''}';
    return '${sub.isNotEmpty ? '$sub/' : ''}${x['name']}';
  }

  Widget _inputDrop() {
    if (_input != null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: CachedNetworkImage(
            imageUrl: _api.viewUrl(
                filename: _input!.filename, subfolder: _input!.subfolder, type: 'input'),
            height: 160,
            width: double.infinity,
            fit: BoxFit.cover,
            errorWidget: (_, __, ___) =>
                const SizedBox(height: 160, child: Icon(Icons.broken_image_outlined)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(_input!.filename,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: context.lazy.muted)),
        ),
        Row(children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: UiGhostBtn('Add image', _pickInput),
            ),
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: UiDangerBtn('Clear', () => setState(() => _input = null)),
          ),
        ]),
      ]);
    }
    return GestureDetector(
      onTap: _pickInput,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 12),
        decoration: BoxDecoration(
          border: Border.all(color: context.lazy.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Text('Click or pick an image here (PNG / JPEG / WebP)',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: context.lazy.muted)),
        ),
      ),
    );
  }

  Widget _fileSelect(Map f) {
    final kind = '${f['kind']}';
    final defName = '${f['name'] ?? ''}';
    final names = _dirNames('${f['dir']}');
    final sel = _fileSel[kind] ?? '';
    final items = <String, String>{
      '': 'Template default — $defName',
      for (final n in names) n: n + (n == defName ? ' (default)' : ''),
    };
    final missingPick = sel.isNotEmpty && !names.contains(sel);
    if (missingPick) items[sel] = '$sel (missing)';
    return UiSelect(
      value: sel,
      items: items,
      hint: 'Choose file',
      sheetTitle: '${f['label'] ?? f['kind']}',
      missingAsError: missingPick,
      onChanged: (v) => setState(() {
        if (v == null || v.isEmpty) {
          _fileSel.remove(kind);
        } else {
          _fileSel[kind] = v;
        }
      }),
    );
  }

  Widget _resultBox() {
    final c = context.lazy;
    final v = _current!.videos.first;
    return GestureDetector(
      onTap: () => _current != null ? _viewJob(_current!) : null,
      child: Container(
        constraints: const BoxConstraints(minHeight: 200),
        decoration: BoxDecoration(
          color: c.accentTint,
          border: Border.all(color: c.borderSoft),
          borderRadius: BorderRadius.circular(16),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (isPlayableVideo(v.filename))
                _VideoThumb(
                    url: _api.viewUrl(filename: v.filename, subfolder: v.subfolder, type: v.type))
              else
                CachedNetworkImage(
                  imageUrl: _api.thumbUrl(
                      filename: v.filename, subfolder: v.subfolder, type: v.type),
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) => const SizedBox(
                    height: 200,
                    child: Center(child: Icon(Icons.movie_outlined, size: 40)),
                  ),
                ),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 28),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _jobTiles() {
    final tiles = <Widget>[];
    for (final job in _history) {
      if (job is! Map) continue;
      final vids = _jobMedia(job);
      if (vids.isEmpty) continue;
      var modName = '${job['model_id'] ?? 'output'}';
      for (final m in _models) {
        if (m is Map && '${m['id']}' == '${job['model_id']}') {
          modName = '${m['name'] ?? modName}';
          break;
        }
      }
      tiles.add(_jobTile(vids.first, modName, _jobViewOf(job)));
    }
    if (tiles.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
            child: Text('No generations yet',
                style: TextStyle(color: context.lazy.muted2, fontSize: 12))),
      );
    }
    return GridView.count(
      crossAxisCount: 2,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: tiles,
    );
  }

  _VJob _jobViewOf(Map job) {
    final vids = _jobMedia(job);
    final meta = (job['meta'] is Map) ? Map<String, dynamic>.from(job['meta']) : <String, dynamic>{};
    return _VJob(
      videos: vids,
      modelId: '${job['model_id'] ?? meta['model_id'] ?? ''}',
      mode: '${job['mode'] ?? meta['mode'] ?? 't2i'}',
      prompt: '${job['prompt'] ?? meta['prompt'] ?? ''}',
      params: (job['params'] is Map)
          ? Map<String, dynamic>.from(job['params'])
          : ((meta['params'] is Map)
              ? Map<String, dynamic>.from(meta['params'])
              : <String, dynamic>{}),
      promptId: '${job['prompt_id'] ?? ''}',
    );
  }

  Widget _jobTile(UiImg v, String badge, _VJob job) {
    return GestureDetector(
      onTap: () => _viewJob(job),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AspectRatio(
          aspectRatio: 1,
          child: Stack(fit: StackFit.expand, children: [
            if (isPlayableVideo(v.filename))
              _VideoThumb(
                  url: _api.viewUrl(filename: v.filename, subfolder: v.subfolder, type: v.type))
            else
              CachedNetworkImage(
                imageUrl: _api.thumbUrl(filename: v.filename, subfolder: v.subfolder, type: v.type),
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => Container(
                  color: context.lazy.bgSoft,
                  child: const Icon(Icons.movie_outlined),
                ),
              ),
            const Center(
              child: Icon(Icons.play_circle_outline_rounded, color: Colors.white70, size: 32),
            ),
            Positioned(
              left: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(badge,
                    overflow: TextOverflow.ellipsis,
                    style: fmono(9, Colors.white, ls: 0.06)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// True for containers ExoPlayer handles. Everything else that lands in
/// a "videos" list (gif previews, still fallbacks) must render as image.
bool isPlayableVideo(String filename) {
  final ext = filename.split('.').last.toLowerCase();
  return const {'mp4', 'webm', 'mkv', '3gp', 'mov', 'm4v'}.contains(ext);
}

/// Tile/result thumbnail for a real video: initializes just far enough
/// to show the first frame (paused — no autoplay, no loop, no audio).
/// Falls back to the movie icon when the file will not open. Needed
/// because the thumb endpoint only serves stills, so video tiles would
/// otherwise always render empty.
class _VideoThumb extends StatefulWidget {
  final String url;
  const _VideoThumb({required this.url});

  @override
  State<_VideoThumb> createState() => _VideoThumbState();
}

class _VideoThumbState extends State<_VideoThumb> {
  VideoPlayerController? _ctrl;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(covariant _VideoThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _ctrl?.dispose();
      _ctrl = null;
      _ready = false;
      _open();
    }
  }

  void _open() {
    final c = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _ctrl = c;
    c.initialize().then((_) {
      if (!mounted) return;
      setState(() => _ready = true);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _ctrl;
    if (!_ready || c == null) {
      return Container(
        color: context.lazy.bgSoft,
        child: const Center(child: Icon(Icons.movie_outlined, size: 32)),
      );
    }
    final size = c.value.size;
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: size.width == 0 ? 16 : size.width,
        height: size.height == 0 ? 9 : size.height,
        child: VideoPlayer(c),
      ),
    );
  }
}

/// Video player dialog content: controller lifecycle owned here.
class _Player extends StatefulWidget {  final String url;
  const _Player({required this.url});

  @override
  State<_Player> createState() => _PlayerState();
}

class _PlayerState extends State<_Player> {
  late VideoPlayerController _ctrl;
  bool _ready = false;
  bool _failed = false;
  Timer? _timeout;

  /// ExoPlayer cannot play stills/GIFs: those render as images instead.
  /// The dialog picks the right widget via [isPlayableVideo].
  @override
  void initState() {
    super.initState();
    _ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.url), httpHeaders: const {})
      ..initialize().then((_) {
        if (!mounted) return;
        _timeout?.cancel();
        setState(() => _ready = true);
        _ctrl.setLooping(true);
        _ctrl.play();
      }).catchError((_) {
        if (mounted) setState(() => _failed = true);
      });
    // A hung init (error page with 200, stalled tunnel) used to spin
    // forever; fail visibly instead.
    _timeout = Timer(const Duration(seconds: 15), () {
      if (mounted && !_ready && !_failed) setState(() => _failed = true);
    });
  }

  @override
  void didUpdateWidget(covariant _Player oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _ctrl.pause();
      _ctrl.dispose();
      _timeout?.cancel();
      _ready = false;
      _failed = false;
      _ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.url))
        ..initialize().then((_) {
          if (!mounted) return;
          _timeout?.cancel();
          setState(() => _ready = true);
          _ctrl.setLooping(true);
          _ctrl.play();
        }).catchError((_) {
          if (mounted) setState(() => _failed = true);
        });
      _timeout = Timer(const Duration(seconds: 15), () {
        if (mounted && !_ready && !_failed) setState(() => _failed = true);
      });
    }
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _ctrl.dispose();
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
    if (!_ready) {
      return const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return GestureDetector(
      onTap: () => setState(() => _ctrl.value.isPlaying ? _ctrl.pause() : _ctrl.play()),
      child: AspectRatio(
        aspectRatio: _ctrl.value.aspectRatio == 0 ? 16 / 9 : _ctrl.value.aspectRatio,
        child: VideoPlayer(_ctrl),
      ),
    );
  }
}
