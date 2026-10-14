import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'edge_frost.dart';
import 'lazy_theme.dart';
import 'native_downloads.dart';
import 'ui_kit.dart';

/// Native port of the next-app Images page: same cards, labels, selects,
/// seg control, pills and buttons — hand-matched to globals.css.
/// (Verified against headless 390px screenshots of the real pages.)
///
/// Static-first like the web app: cached models/file lists paint instantly,
/// then sync when the server answers. Talks to the same /lazycomfy/api/*
/// endpoints + ComfyUI /ws progress socket, so no server change is needed.
class NativeImagesPage extends StatefulWidget {
  final String endpoint;
  final bool isDark;
  final VoidCallback onToggleTheme;
  const NativeImagesPage({
    super.key,
    required this.endpoint,
    required this.isDark,
    required this.onToggleTheme,
  });

  @override
  State<NativeImagesPage> createState() => _NativeImagesPageState();
}

/// A finished job for the result card / gallery / viewer.
class _JobView {
  final List<UiImg> images;
  final String modelId;
  final String mode;
  final String prompt;
  final Map<String, dynamic> params;
  final String promptId;
  const _JobView({
    required this.images,
    required this.modelId,
    required this.mode,
    required this.prompt,
    required this.params,
    required this.promptId,
  });
}

class _NativeImagesPageState extends State<NativeImagesPage> {
  late LazyApi _api;
  bool _syncing = true;
  String? _error;

  List<dynamic> _models = [];
  Map<String, dynamic> _dirs = {};
  List<dynamic> _inputLib = [];
  String _modelId = '';
  String _mode = 't2i';
  Map<String, String> _fileSel = {};
  String _lora = '';
  List<Map<String, dynamic>> _loraStack = [];
  final List<UiImg> _inputs = [];
  int _queueN = 0;
  Map<String, dynamic> _sysInfo = {};
  final Set<String> _dead = {};

  late final TextEditingController _promptCtrl;
  late final TextEditingController _negCtrl;
  late final TextEditingController _wCtrl;
  late final TextEditingController _hCtrl;
  late final TextEditingController _stepsCtrl;
  late final TextEditingController _cfgCtrl;
  late final TextEditingController _seedCtrl;
  late final TextEditingController _batchCtrl;
  late final TextEditingController _denoiseCtrl;
  late final TextEditingController _qwenResCtrl;
  late final TextEditingController _loraStrCtrl;
  String _sampler = '';
  String _scheduler = '';
  String _preset = '';
  bool _enhance = false;

  String? _promptId;
  String _jobState = 'Idle';
  double? _progress;
  _JobView? _current;
  List<dynamic> _history = [];
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

  int get _maxN {
    final n = int.tryParse('${_model?['max_images'] ?? ''}');
    if (n == null) return 1;
    return n.clamp(1, 10);
  }

  bool get _isQwen21 => _modelId == 'qwen_image_2_1' || _modelId == 'qwen_image_2_1_turbo';

  List<dynamic> get _presetOpts {
    final o = _model?['options'];
    if (o is Map && o['presets'] is Map && (o['presets'] as Map)['options'] is List) {
      return List<dynamic>.from((o['presets'] as Map)['options']);
    }
    return const [];
  }

  bool _dirHas(String dir, String name) => _dirNames(dir).contains(name);

  /// Labels of required files not satisfied by selection-or-default.
  List<String> _missing() {
    final m = _model;
    if (m == null || m['files'] is! List) return [];
    return (m['files'] as List).whereType<Map>().where((f) {
      final sel = _fileSel['${f['kind']}'];
      return !_dirHas('${f['dir']}', (sel != null && sel.isNotEmpty) ? sel : '${f['name']}');
    }).map((f) => '${f['label']}').toList();
  }

  void _unfocus() => FocusManager.instance.primaryFocus?.unfocus();

  @override
  void initState() {
    super.initState();
    _api = LazyApi(widget.endpoint);
    _promptCtrl = TextEditingController();
    _negCtrl = TextEditingController();
    _wCtrl = TextEditingController();
    _hCtrl = TextEditingController();
    _stepsCtrl = TextEditingController();
    _cfgCtrl = TextEditingController();
    _seedCtrl = TextEditingController();
    _batchCtrl = TextEditingController(text: '1');
    _denoiseCtrl = TextEditingController(text: '0.5');
    _qwenResCtrl = TextEditingController();
    _loraStrCtrl = TextEditingController(text: '1');
    _boot();
    // Occasional gallery refresh while idle (web re-polls on socket
    // events; native has no always-on socket, so poll gently instead).
    _idleTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && _promptId == null) _syncHistory();
    });
  }

  @override
  void didUpdateWidget(covariant NativeImagesPage oldWidget) {
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
    _negCtrl.dispose();
    _wCtrl.dispose();
    _hCtrl.dispose();
    _stepsCtrl.dispose();
    _cfgCtrl.dispose();
    _seedCtrl.dispose();
    _batchCtrl.dispose();
    _denoiseCtrl.dispose();
    _qwenResCtrl.dispose();
    _loraStrCtrl.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    // Static part first: last-known payloads paint with zero network.
    final p = await SharedPreferences.getInstance();
    List<dynamic> models = const [];
    Map<String, dynamic> dirs = const {};
    try {
      final raw = p.getString('lazycomfy.native.cache.models');
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
      _promptCtrl.text = p.getString('lazycomfy.native.images.prompt') ?? '';
      final savedModel = p.getString('lazycomfy.native.images.model') ?? '';
      if (_models.any((m) => m is Map && m['id'] == savedModel)) _modelId = savedModel;
      _applyModelDefaults();
      _restoreState(p);
    });
    await _sync();
  }

  /// Overlay persisted picks/fields over the model defaults (boot only).
  /// _sync() afterwards keeps them — it only resets on a model change.
  void _restoreState(SharedPreferences p) {
    final m = _model;
    if (m == null) return;
    final modes = List<String>.from(m['modes'] ?? ['t2i']);
    final savedMode = p.getString('lazycomfy.native.images.mode') ?? '';
    if (savedMode.isNotEmpty && modes.contains(savedMode)) _mode = savedMode;
    try {
      final raw = p.getString('lazycomfy.native.images.files');
      if (raw != null && raw.isNotEmpty) {
        final d = json.decode(raw);
        if (d is Map) _fileSel = {for (final e in d.entries) '${e.key}': '${e.value}'};
      }
    } catch (_) {}
    _lora = p.getString('lazycomfy.native.images.lora') ?? '';
    try {
      final raw = p.getString('lazycomfy.native.images.lora_stack');
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
    _preset = p.getString('lazycomfy.native.images.preset') ?? '';
    _enhance = p.getBool('lazycomfy.native.images.enhance') ?? false;
    try {
      final raw = p.getString('lazycomfy.native.images.fields');
      if (raw != null && raw.isNotEmpty) {
        final d = json.decode(raw);
        if (d is Map) {
          void set(TextEditingController c, String k) {
            final v = d[k];
            if (v is String && v.isNotEmpty) c.text = v;
          }

          set(_wCtrl, 'w');
          set(_hCtrl, 'h');
          set(_stepsCtrl, 'steps');
          set(_cfgCtrl, 'cfg');
          set(_seedCtrl, 'seed');
          set(_batchCtrl, 'batch');
          set(_denoiseCtrl, 'denoise');
          set(_qwenResCtrl, 'qwenRes');
          set(_loraStrCtrl, 'loraStr');
          set(_negCtrl, 'neg');
          if (d['sampler'] is String) _sampler = d['sampler'];
          if (d['scheduler'] is String) _scheduler = d['scheduler'];
        }
      }
    } catch (_) {}
    _validatePicks();
  }

  /// Drop picks whose file vanished from the fresh dir listing; keep
  /// everything else. Unknown (empty) listings keep the pick — a blip
  /// must not wipe the user's selection.
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

  /// One named step of the sync: the banner names the failing call and
  /// carries the real reason instead of a flat "sync failed".
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
      final models = await _step('models', _api.models);
      final dirs = await _step('files', _api.fileDirs);
      final hist = await _step('history', () => _api.history(12));
      List<dynamic> inputs = const [];
      try {
        inputs = await _api.inputImages();
      } catch (_) {}
      int queueN = 0;
      try {
        queueN = await _api.queueRemaining();
      } catch (_) {}
      Map<String, dynamic> sys = const {};
      try {
        sys = await _api.config();
      } catch (_) {}
      if (!mounted) return;
      final p = await SharedPreferences.getInstance();
      try {
        await p.setString('lazycomfy.native.cache.models', json.encode(models));
        await p.setString('lazycomfy.native.cache.dirs', json.encode(dirs));
      } catch (_) {}
      setState(() {
        _models = models;
        _dirs = Map<String, dynamic>.from(dirs);
        _history = _liveJobs(hist);
        _inputLib = inputs;
        _queueN = queueN;
        _sysInfo = sys;
        if (_models.isNotEmpty && _model == null) {
          final first = _models.firstWhere(
            (m) => m is Map && m['id'] == 'qwen_image_2_1_turbo',
            orElse: () => _models.first,
          );
          final firstId = first is Map ? '${first['id'] ?? ''}' : '';
          if (firstId.isNotEmpty && firstId != 'null') _modelId = firstId;
          // Fresh model pick: full reset to its defaults.
          _applyModelDefaults();
        } else if (_model != null) {
          // Same model still here: keep the user's picks/fields, only
          // drop files that vanished server-side (new downloads appear
          // in the menus without wiping the selection).
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

  /// History minus dead files (mirrors the web `deleted` filter).
  List<dynamic> _liveJobs(List<dynamic> hist) {
    final out = <dynamic>[];
    for (final j in hist) {
      if (j is! Map || j['images'] is! List) continue;
      final imgs = (j['images'] as List).whereType<Map>().where((o) {
        if (o['filename'] == null) return false;
        final im = UiImg('${o['filename']}', '${o['subfolder'] ?? ''}', '${o['type'] ?? 'output'}');
        return !_dead.contains(im.key);
      }).toList();
      if (imgs.isEmpty) continue;
      final copy = Map<String, dynamic>.from(j);
      copy['images'] = imgs;
      out.add(copy);
    }
    return out;
  }

  Future<void> _syncHistory() async {
    try {
      final hist = await _api.history(12);
      if (!mounted) return;
      setState(() => _history = _liveJobs(hist));
    } catch (_) {}
  }

  /// Reset size/sampler/file selections to the model's defaults.
  void _applyModelDefaults() {
    final m = _model;
    if (m == null) return;
    final modes = List<String>.from(m['modes'] ?? ['t2i']);
    if (!modes.contains(_mode)) _mode = modes.first;
    final d = Map<String, dynamic>.from(m['defaults'] ?? {});
    final l = Map<String, dynamic>.from(m['limits'] ?? {});
    _wCtrl.text = '${d['width'] ?? l['width_max'] ?? 1024}';
    _hCtrl.text = '${d['height'] ?? l['height_max'] ?? 1024}';
    _stepsCtrl.text = '${d['steps'] ?? 8}';
    _cfgCtrl.text = '${d['cfg'] ?? 1}';
    _sampler = '${d['sampler'] ?? ''}';
    _scheduler = '${d['scheduler'] ?? ''}';
    _fileSel = {};
    _lora = '';
    _loraStack = [];
    _preset = '';
    _enhance = false;
  }

  List<String> _dirNames(String dir) {
    final v = _dirs[dir];
    if (v is List) return v.map((e) => '$e').toList();
    return const [];
  }

  Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('lazycomfy.native.images.model', _modelId);
    await p.setString('lazycomfy.native.images.prompt', _promptCtrl.text);
    await p.setString('lazycomfy.native.images.mode', _mode);
    await p.setString('lazycomfy.native.images.files', json.encode(_fileSel));
    await p.setString('lazycomfy.native.images.lora', _lora);
    await p.setString('lazycomfy.native.images.lora_stack', json.encode(_loraStack));
    await p.setString('lazycomfy.native.images.preset', _preset);
    await p.setBool('lazycomfy.native.images.enhance', _enhance);
    await p.setString('lazycomfy.native.images.fields', json.encode({
      'w': _wCtrl.text,
      'h': _hCtrl.text,
      'steps': _stepsCtrl.text,
      'cfg': _cfgCtrl.text,
      'seed': _seedCtrl.text,
      'batch': _batchCtrl.text,
      'denoise': _denoiseCtrl.text,
      'qwenRes': _qwenResCtrl.text,
      'loraStr': _loraStrCtrl.text,
      'sampler': _sampler,
      'scheduler': _scheduler,
      'neg': _negCtrl.text,
    }));
  }

  /// Save context whenever the page hides (tab switch, downloads push,
  /// app background) so nothing is lost between visits.
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
    if (_inputs.length >= _maxN) {
      _snack('Maximum $_maxN image${_maxN == 1 ? '' : 's'}.');
      return;
    }
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
        _inputs.add(UiImg(up['name']!, up['subfolder']!, 'input'));
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
      _snack('Describe your image first.');
      return;
    }
    if (_mode == 'i2i' && _inputs.isEmpty) {
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
      final body = <String, dynamic>{
        'model_id': _modelId,
        'mode': _mode,
        'prompt': _promptCtrl.text,
        'width': int.tryParse(_wCtrl.text) ?? 1024,
        'height': int.tryParse(_hCtrl.text) ?? 1024,
        'steps': int.tryParse(_stepsCtrl.text) ?? 8,
        'cfg': double.tryParse(_cfgCtrl.text) ?? 1.0,
        'batch': int.tryParse(_batchCtrl.text) ?? 1,
        'client_id': clientId,
      };
      final seed = int.tryParse(_seedCtrl.text.trim());
      if (seed != null) body['seed'] = seed;
      if ((m['supports_negative'] ?? false) == true && _negCtrl.text.trim().isNotEmpty) {
        body['negative_prompt'] = _negCtrl.text;
      }
      if (_sampler.isNotEmpty) body['sampler'] = _sampler;
      if (_scheduler.isNotEmpty) body['scheduler'] = _scheduler;
      if (_preset.isNotEmpty) body['preset'] = _preset;
      if (_enhance && m['pe'] != null) body['enhance'] = true;
      if (_mode == 'i2i') {
        if (_isQwen21) {
          body['resolution'] = int.tryParse(_qwenResCtrl.text) ?? (d['resolution'] as int? ?? 1024);
        } else {
          body['denoise'] = double.tryParse(_denoiseCtrl.text) ?? 0.5;
        }
      }
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
      if (_mode == 'i2i' && _inputs.isNotEmpty) {
        body['image'] = {'name': _inputs.first.filename, 'subfolder': _inputs.first.subfolder};
        if (_maxN > 1) {
          body['images'] = [
            for (final im in _inputs) {'name': im.filename, 'subfolder': im.subfolder}
          ];
        }
      }
      final id = await _api.generate(body);
      if (!mounted) return;
      setState(() {
        _promptId = id;
        _jobState = 'Running…';
      });
      _persist();
      try {
        _queueN = await _api.queueRemaining();
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
    // Live step counts over the socket; the 2s result poll is the backstop
    // that actually completes the job if the socket drops.
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
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _finish(id));
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
      r = await _api.result(id);
    } catch (_) {
      return;
    }
    if (!mounted || _promptId != id) return;
    final status = r['status'];
    if (status == 'success') {
      final outs = (r['outputs'] as List? ?? []);
      final imgs = outs
          .whereType<Map>()
          .where((o) => o['filename'] != null)
          .map((o) => UiImg('${o['filename']}', '${o['subfolder'] ?? ''}', '${o['type'] ?? 'output'}'))
          .toList();
      _wsSub?.cancel();
      _pollTimer?.cancel();
      final meta = (r['meta'] is Map) ? Map<String, dynamic>.from(r['meta']) : <String, dynamic>{};
      final params = (meta['params'] is Map) ? Map<String, dynamic>.from(meta['params']) : <String, dynamic>{};
      final job = _JobView(
        images: imgs,
        modelId: '${meta['model_id'] ?? _modelId}',
        mode: '${meta['mode'] ?? _mode}',
        prompt: '${meta['prompt'] ?? _promptCtrl.text}',
        params: params,
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
      _fail('${r['error'] ?? 'Run failed.'}');
    }
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
      await _api.cancel(id);
    } catch (_) {}
  }

  void _snack(String msg, {bool ok = false}) {
    if (!mounted) return;
    showUiSnack(context, msg, ok: ok);
  }

  Future<void> _save(UiImg img) async {
    try {
      final uri = Uri.parse(_api.viewUrl(filename: img.filename, subfolder: img.subfolder, type: img.type));
      final res = await http.get(uri).timeout(const Duration(minutes: 5));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final saved = await FilePicker.platform.saveFile(fileName: img.filename, bytes: res.bodyBytes);
      if (!mounted) return;
      _snack(saved == null ? 'Download cancelled.' : 'Saved: $saved', ok: saved != null);
    } catch (_) {
      _snack('Download failed. Check the connection and retry.');
    }
  }

  Future<void> _deleteJobImage(_JobView job, UiImg img) async {
    try {
      await _api.deleteMedia(filename: img.filename, subfolder: img.subfolder, type: img.type);
      _snack('Image deleted.', ok: true);
    } catch (e) {
      _snack(e is ApiException ? e.message : 'Delete failed.');
      return;
    }
    if (!mounted) return;
    setState(() => _dead.add(img.key));
    final rest = job.images.where((im) => im.key != img.key).toList();
    Navigator.pop(context);
    if (rest.isEmpty) {
      if (_current?.promptId == job.promptId) setState(() => _current = null);
    } else {
      _viewJob(_JobView(
        images: rest,
        modelId: job.modelId,
        mode: job.mode,
        prompt: job.prompt,
        params: job.params,
        promptId: job.promptId,
      ));
    }
    _syncHistory();
  }

  /// Reuse settings: model reset-to-defaults first, params applied over.
  void _reuse(_JobView job) {
    Navigator.pop(context);
    final m = _models.whereType<Map>().firstWhere(
          (x) => '${x['id']}' == job.modelId,
          orElse: () => <String, dynamic>{},
        );
    setState(() {
      if (m.isNotEmpty) {
        _modelId = job.modelId;
        _applyModelDefaults();
      }
      if (job.mode == 'i2i' || job.mode == 't2i') _mode = job.mode;
      _promptCtrl.text = job.prompt;
      final p = job.params;
      if (p['width'] != null) _wCtrl.text = '${p['width']}';
      if (p['height'] != null) _hCtrl.text = '${p['height']}';
      if (p['steps'] != null) _stepsCtrl.text = '${p['steps']}';
      if (p['cfg'] != null) _cfgCtrl.text = '${p['cfg']}';
      if (p['sampler'] is String) _sampler = p['sampler'];
      if (p['scheduler'] is String) _scheduler = p['scheduler'];
      if (p['seed'] != null) _seedCtrl.text = '${p['seed']}';
      if (p['batch'] != null) _batchCtrl.text = '${p['batch']}';
      if (p['denoise'] != null) _denoiseCtrl.text = '${p['denoise']}';
      if (p['enhance'] == true) _enhance = true;
      if (p['files'] is Map) {
        _fileSel = {
          for (final e in (p['files'] as Map).entries) '${e.key}': '${e.value}',
        };
      }
      final rawLoras = p['loras'];
      if (rawLoras is List && rawLoras.isNotEmpty) {
        final first = rawLoras.first;
        if (first is Map) {
          _lora = '${first['name'] ?? ''}';
          final st = (first['strength'] as num?)?.toDouble();
          if (st != null) _loraStrCtrl.text = trimNum(st);
        }
        _loraStack = [
          for (final s in rawLoras.skip(1))
            if (s is Map)
              {
                'name': '${s['name'] ?? ''}',
                'strength': (s['strength'] as num?)?.toDouble() ?? 1.0,
              },
        ];
      }
    });
    _persist();
    _snack('Settings loaded.', ok: true);
  }

  void _toI2I(_JobView job) {
    final m = _model;
    if (m == null) return;
    if (!(m['modes'] is List && (m['modes'] as List).contains('i2i'))) {
      _snack('${m['name'] ?? _modelId} is text-to-image only.');
      return;
    }
    if (job.images.isEmpty) return;
    Navigator.pop(context);
    final first = job.images.first;
    setState(() {
      _mode = 'i2i';
      _inputs
        ..clear()
        ..add(UiImg(first.filename, first.subfolder, first.type));
    });
    _snack('Loaded as img2img input.', ok: true);
  }

  void _openFull(UiImg img) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          body: Stack(children: [
            Center(
              child: InteractiveViewer(
                child: CachedNetworkImage(
                  imageUrl: _api.viewUrl(filename: img.filename, subfolder: img.subfolder, type: img.type),
                  fit: BoxFit.contain,
                  errorWidget: (_, __, ___) => const Icon(Icons.broken_image_outlined,
                      color: Colors.grey, size: 48),
                ),
              ),
            ),
            Positioned(
              top: MediaQuery.paddingOf(context).top + 8,
              left: 8,
              child: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded, color: Colors.white),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  void _viewJob(_JobView job) {
    var idx = 0;
    showDialog(
      context: context,
      builder: (dlg) {
        final c = Theme.of(dlg).extension<LazyColors>()!;
        return StatefulBuilder(
          builder: (dlg2, setDlg) {
            final img = job.images[idx.clamp(0, job.images.length - 1)];
            void open() {
              Navigator.pop(context);
              _openFull(img);
            }
            // Explicit ✕ over the preview corner: no hunting for
            // outside-tap to dismiss.
            return Dialog(
              backgroundColor: c.bgCard,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                  child: Container(
                    color: c.bgSoft,
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: Stack(children: [
                        Positioned.fill(
                          child: GestureDetector(
                            onTap: open,
                            behavior: HitTestBehavior.opaque,
                            child: CachedNetworkImage(
                              imageUrl: _api.viewUrl(
                                  filename: img.filename, subfolder: img.subfolder, type: img.type),
                              fit: BoxFit.contain,
                              errorWidget: (_, __, ___) => const Padding(
                                padding: EdgeInsets.all(32),
                                child: Icon(Icons.broken_image_outlined),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 8,
                          right: 8,
                          child: uiCloseChip(() => Navigator.pop(context)),
                        ),
                      ]),
                    ),
                  ),
                ),
                if (job.images.length > 1)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Row(
                      children: [
                        for (int i = 0; i < job.images.length; i++)
                          Padding(
                            padding: EdgeInsets.only(right: i + 1 < job.images.length ? 6 : 0),
                            child: GestureDetector(
                              onTap: () => setDlg(() => idx = i),
                              child: Container(
                                width: 52,
                                height: 52,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: i == idx ? c.accent : c.border,
                                    width: i == idx ? 2 : 1,
                                  ),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(7),
                                  child: CachedNetworkImage(
                                    imageUrl: _api.thumbUrl(
                                        filename: job.images[i].filename,
                                        subfolder: job.images[i].subfolder,
                                        type: job.images[i].type),
                                    fit: BoxFit.cover,
                                    errorWidget: (_, __, ___) =>
                                        const Icon(Icons.broken_image_outlined, size: 20),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Text(
                    _metaLine(job),
                    style: fmono(11, c.ink3),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  // Fixed 2-column grid: identical placement for every
                  // aspect ratio, no wrap reflow.
                  child: GridView.count(
                    crossAxisCount: 2,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 3.4,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      UiGhostBtn('Open', open),
                      UiGhostBtn('Download', () {
                        Navigator.pop(context);
                        _save(img);
                      }),
                      UiGhostBtn('Reuse settings', () => _reuse(job)),
                      UiGhostBtn('To img2img', () => _toI2I(job)),
                      UiGhostBtn('Copy prompt', () {
                        Clipboard.setData(ClipboardData(text: job.prompt));
                        Navigator.pop(context);
                        _snack('Prompt copied.', ok: true);
                      }),
                      UiDangerBtn('Delete', () => _confirmDelete(job, img)),
                    ],
                  ),
                ),
              ]),
            );
          },
        );
      },
    );
  }

  void _confirmDelete(_JobView job, UiImg img) {
    final c = context.lazy;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: c.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
        contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
        actionsPadding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        title: Text('Delete image?', style: disp(19, FontWeight.w700, c.ink)),
        content: Text(img.filename, style: TextStyle(fontSize: 13.5, color: c.muted)),
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
              _deleteJobImage(job, img);
            },
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
            child: Text('Delete', style: TextStyle(color: c.err, fontSize: 15)),
          ),
        ],
      ),
    );
  }

  String _metaLine(_JobView job) {
    final m = _models.whereType<Map>().firstWhere(
          (x) => '${x['id']}' == job.modelId,
          orElse: () => <String, dynamic>{},
        );
    final name = m.isNotEmpty ? '${m['name'] ?? job.modelId}' : job.modelId;
    final p = job.params;
    var meta = '$name · ${job.mode == 'i2i' ? 'img2img' : 'text2img'}';
    if (p['width'] != null && p['height'] != null) meta += ' · ${p['width']}×${p['height']}';
    if (p['steps'] != null) meta += ' · ${p['steps']} steps';
    if (p['cfg'] != null) meta += ' · guidance ${p['cfg']}';
    if (p['sampler'] != null) meta += ' · ${p['sampler']}';
    if (p['enhance'] == true) meta += ' · +PE';
    if (p['loras'] is List && (p['loras'] as List).isNotEmpty) {
      meta += ' · LoRA ${(p['loras'] as List).whereType<Map>().map((x) => '${x['name'] ?? ''}'.replaceAll(RegExp(r'\.safetensors$', caseSensitive: false), '') + (x['strength'] != null ? ' ×${x['strength']}' : '')).join(', ')}';
    }
    if (p['seed'] != null) meta += ' · seed ${p['seed']}';
    if (job.mode == 'i2i' && p['denoise'] != null) {
      meta += ' · strength ${(((p['denoise'] as num?)?.toDouble() ?? 0) * 100).round()}%';
    }
    return meta;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.lazy;
    final mq = MediaQuery.paddingOf(context);
    final m = _model;
    final miss = _missing();
    final opts = m?['options'];
    final aspects = (opts is Map && opts['aspects'] is List) ? List<dynamic>.from(opts['aspects']) : const [];
    final cfgVisible = (opts is Map) ? (opts['cfg_visible'] ?? true) == true : true;
    final schedFixed = (opts is Map) ? (opts['scheduler_fixed'] ?? false) == true : false;
    final canRun = _promptId == null && !(_syncing && _models.isEmpty) && miss.isEmpty;
    final dev = (_sysInfo['device'] is Map) ? _sysInfo['device'] as Map : const {};
    // Sticky shell like the site: fixed 42px header block (brand row),
    // full-bleed list starting below it, frost floating between the list
    // and the header so scrolled content melts under it.
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
                  _pageHeader('Images'),
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
                      hints: {
                        for (final x in _models)
                          if (x is Map) '${x['id']}': _modelHint(x),
                      },
                      hint: _models.isEmpty ? 'Loading…' : 'Select a model…',
                      sheetTitle: 'Pick a model',
                      onChanged: (v) {
                        if (v == null) return;
                        _unfocus();
                        setState(() {
                          _modelId = v;
                          _applyModelDefaults();
                        });
                        _persist();
                      },
                    ),
                    if ((m?['family'] ?? '') != '') ...[
                      const SizedBox(height: 6),
                      Text('${m!['family']}',
                          style: TextStyle(fontSize: 12.5, color: c.muted)),
                    ],
                    if (m != null && (m['modes'] as List? ?? []).length > 1) ...[
                      const SizedBox(height: 10),
                      UiSeg(
                        options: List<String>.from(m['modes']),
                        value: _mode,
                        labels: const {'t2i': 'Text to image', 'i2i': 'Image to image'},
                        onChanged: (v) {
                          _unfocus();
                          setState(() => _mode = v);
                        },
                      ),
                    ],
                    if (miss.isNotEmpty && m != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: GestureDetector(
                          onTap: _openDownloads,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              color: c.err.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: c.err.withValues(alpha: 0.35)),
                            ),
                            child: Text(
                              'Missing files: ${miss.join(', ')} — download them from Models.',
                              style: TextStyle(color: c.err, fontSize: 12.5, height: 1.35),
                            ),
                          ),
                        ),
                      ),
                  ]),
                  uiCard(context, [
                    uiSection(context, 'Prompt'),
                    uiTextField(context, _promptCtrl, 'Describe your image…', maxLines: 4),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('${_promptCtrl.text.length} chars',
                          style: fmono(10.5, c.muted2)),
                    ),
                    if ((m?['supports_negative'] ?? false) == true) ...[
                      const SizedBox(height: 10),
                      uiField(context, 'Negative prompt'),
                      uiTextField(context, _negCtrl, 'What to avoid…', maxLines: 2),
                    ],
                    if (_mode == 'i2i') ...[
                      const SizedBox(height: 10),
                      uiField(context, 'Input images (${_inputs.length}/$_maxN)'),
                      _inputDrop(),
                      const SizedBox(height: 10),
                      uiField(context, 'Or pick from input folder'),
                      UiSelect(
                        value: null,
                        items: {
                          '': _inputLib.isEmpty ? 'No images…' : 'Choose an image…',
                          for (final x in _inputLib)
                            if (x is Map)
                              '${(x['subfolder'] ?? '') != '' ? '${x['subfolder']}/' : ''}${x['name']}':
                                  '${(x['subfolder'] ?? '') != '' ? '${x['subfolder']}/' : ''}${x['name']}',
                        },
                        hint: 'Choose an image…',
                        sheetTitle: 'Or pick from input folder',
                        onChanged: (v) {
                          if (v == null || v.isEmpty) return;
                          final found = _inputLib.whereType<Map>().firstWhere(
                                (x) =>
                                    '${(x['subfolder'] ?? '') != '' ? '${x['subfolder']}/' : ''}${x['name']}' ==
                                    v,
                                orElse: () => <String, dynamic>{},
                              );
                          if (found.isNotEmpty && _inputs.length < _maxN) {
                            setState(() => _inputs.add(
                                UiImg('${found['name']}', '${found['subfolder'] ?? ''}', 'input')));
                          }
                        },
                      ),
                      if (_maxN > 1)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text('${_inputs.length} / $_maxN images · the first image is the edit target.',
                              style: TextStyle(fontSize: 12.5, color: c.muted)),
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
                                value: ('${_loraStack[i]['name']}'.isEmpty) ? '' : '${_loraStack[i]['name']}',
                                items: {
                                  '': 'None',
                                  for (final n in _dirNames('loras')) n: n,
                                },
                                hint: 'None',
                                sheetTitle: 'LoRA (optional)',
                                onChanged: (v) => setState(() =>
                                    _loraStack[i] = {'name': v ?? '', 'strength': _loraStack[i]['strength']}),
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
                            SizedBox(
                              width: 40,
                              child: Text('${_loraStack[i]['strength']}',
                                  textAlign: TextAlign.right,
                                  style: fmono(10.5, c.muted2)),
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
                      if (_mode == 't2i') ...[
                        Row(children: [
                          Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [uiField(context, 'Width'), uiTextField(context, _wCtrl, 'W', number: true)]),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [uiField(context, 'Height'), uiTextField(context, _hCtrl, 'H', number: true)]),
                          ),
                        ]),
                        if (aspects.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          // Fixed-height pills in a Wrap: sizes to content
                          // exactly, so no phantom space can appear.
                          LayoutBuilder(builder: (_, cons) {
                            final w = (cons.maxWidth - 12) / 3;
                            return Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final a in aspects)
                                  if (a is Map)
                                    SizedBox(
                                      width: w,
                                      child: UiPill('${a['label']}', () {
                                        _unfocus();
                                        setState(() {
                                          _wCtrl.text = '${a['width']}';
                                          _hCtrl.text = '${a['height']}';
                                        });
                                      }),
                                    ),
                              ],
                            );
                          }),
                        ],
                        const SizedBox(height: 10),
                      ],
                      // Seeds run long; steps fits in 2 digits. Weight the
                      // row 2:5 so long seeds are fully visible.
                      Row(children: [
                        Expanded(
                          flex: 2,
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [uiField(context, 'Steps'), uiTextField(context, _stepsCtrl, 'Steps', number: true)]),
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
                                  Expanded(child: uiTextField(context, _seedCtrl, 'random', number: true)),
                                  const SizedBox(width: 8),
                                  _diceBtn(),
                                ]),
                              ]),
                        ),
                      ]),
                      const SizedBox(height: 10),
                      if (cfgVisible || _mode == 't2i')
                        Row(children: [
                          if (cfgVisible)
                            Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    uiField(context, 'Guidance (CFG)'),
                                    uiTextField(context, _cfgCtrl, 'CFG', number: true),
                                  ]),
                            ),
                          if (cfgVisible && _mode == 't2i') const SizedBox(width: 10),
                          if (_mode == 't2i')
                            Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [uiField(context, 'Batch'), uiTextField(context, _batchCtrl, '1', number: true)]),
                            ),
                        ]),
                      if (!cfgVisible)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text('Guidance is fixed at ${m['defaults']?['cfg']} for this model.',
                              style: TextStyle(fontSize: 12.5, color: c.muted)),
                        ),
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
                        if (!schedFixed) ...[
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
                        ],
                      ]),
                      if (schedFixed)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text('Schedule is fixed for this model.',
                              style: TextStyle(fontSize: 12.5, color: c.muted)),
                        ),
                      if (_presetOpts.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        uiField(context, 
                            '${(m['options']?['presets'] is Map ? (m['options']?['presets'] as Map)['label'] : null) ?? 'Preset'}'),
                        UiSelect(
                          value: _preset,
                          items: {
                            '': 'Custom · manual steps',
                            for (final o in _presetOpts)
                              if (o is Map) '${o['id']}': '${o['label']}',
                          },
                          hint: 'Custom · manual steps',
                          sheetTitle: 'Preset',
                          onChanged: (v) {
                            setState(() {
                              _preset = v ?? '';
                              final o = _presetOpts.whereType<Map>().firstWhere(
                                    (x) => '${x['id']}' == _preset,
                                    orElse: () => <String, dynamic>{},
                                  );
                              if (o['steps'] != null) _stepsCtrl.text = '${o['steps']}';
                            });
                          },
                        ),
                      ],
                      if (m['pe'] != null) ...[
                        const SizedBox(height: 10),
                        Row(children: [
                          Switch(
                            value: _enhance,
                            activeThumbColor: c.accent,
                            onChanged: (v) => setState(() => _enhance = v),
                          ),
                          const SizedBox(width: 10),
                          Text('Enhance prompt (+PE)',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.ink)),
                        ]),
                      ],
                      if (_mode == 'i2i' && !_isQwen21) ...[
                        const SizedBox(height: 10),
                        uiField(context, 
                            'Strength (${(((double.tryParse(_denoiseCtrl.text) ?? 0) * 100).round())}%)'),
                        UiSlider(
                          min: 0.05,
                          max: 1,
                          divisions: 19,
                          value: (double.tryParse(_denoiseCtrl.text) ?? 0.5).clamp(0.05, 1.0),
                          onChanged: (v) => setState(() => _denoiseCtrl.text = v.toStringAsFixed(2)),
                        ),
                      ],
                      if (_mode == 'i2i' && _isQwen21) ...[
                        const SizedBox(height: 10),
                        uiField(context, 'Reference resolution'),
                        uiTextField(context, _qwenResCtrl,
                            '${(m['defaults'] is Map ? (m['defaults'] as Map)['resolution'] : null) ?? 1024}',
                            number: true),
                      ],
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
                      UiPrimaryBtn('Generate', canRun ? _generate : null),
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
                  if (_sysInfo.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Center(
                        child: Text(
                          'LazyComfy ${_sysInfo['lazycomfy_version'] ?? ''} · ComfyUI ${_sysInfo['comfyui_version'] ?? '?'} · ${dev['name'] ?? dev['type'] ?? ''}',
                          textAlign: TextAlign.center,
                          style: fmono(10.5, c.muted2),
                        ),
                      ),
                    ),
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
              child: _header(),
            ),
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

  Widget _inputDrop() {
    if (_inputs.isEmpty) {      return GestureDetector(
        onTap: _pickInput,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 12),
          decoration: BoxDecoration(
            border: Border.all(color: context.lazy.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(
            child: Text('Click or pick images here (PNG / JPEG / WebP)',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: context.lazy.muted)),
          ),
        ),
      );
    }
    final first = _inputs.first;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: UiRatioImage(
          url: _api.viewUrl(filename: first.filename, subfolder: first.subfolder, type: 'input'),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(first.filename,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: context.lazy.muted)),
      ),
      if (_inputs.length > 1)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (int i = 1; i < _inputs.length; i++)
                Stack(clipBehavior: Clip.none, children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(
                      imageUrl: _api.viewUrl(
                          filename: _inputs[i].filename,
                          subfolder: _inputs[i].subfolder,
                          type: 'input'),
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => const SizedBox(
                          width: 72, height: 72, child: Icon(Icons.broken_image_outlined)),
                    ),
                  ),
                  Positioned(
                    top: -8,
                    right: -8,
                    child: GestureDetector(
                      onTap: () => setState(() => _inputs.removeAt(i)),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        decoration: BoxDecoration(
                          color: context.lazy.bgCard,
                          border: Border.all(color: context.lazy.border),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text('✕', style: TextStyle(fontSize: 11, color: context.lazy.muted2)),
                      ),
                    ),
                  ),
                ]),
              if (_inputs.length < _maxN)
                GestureDetector(
                  onTap: _pickInput,
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      border: Border.all(color: context.lazy.border),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.add_rounded, color: context.lazy.muted2),
                  ),
                ),
            ],
          ),
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
          child: UiDangerBtn('Clear images', () => setState(_inputs.clear)),
        ),
      ]),
    ]);
  }

  /// Shell-top mirror: frosted brand pill left, backend dot + downloads +
  /// theme toggle right. Glass like the site (.glass-pill: translucent tint
  /// over blur(22)), so scrolled content melts behind the sticky chrome.
  Widget _pageHeader(String title) {
    final c = context.lazy;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(title, style: disp(16, FontWeight.w700, c.ink)),
    );
  }

  Widget _header() {    final c = context.lazy;
    final dark = widget.isDark;
    final dot = _error != null ? c.err : (_syncing ? c.warn : c.ok);
    final dotLabel = _error != null ? 'OFFLINE' : (_syncing ? 'SYNCING' : 'SYNCED');
    return Row(children: [
      UiBrand(dark: dark),
      const Spacer(),
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
      ),
      const SizedBox(width: 6),
      Text(dotLabel, style: fmono(10, c.muted2, ls: 0.06)),
      const SizedBox(width: 8),
      UiHeadBtn(Icons.download_rounded, 'Model downloads', _openDownloads),
      const SizedBox(width: 8),
      UiHeadBtn(
        dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
        dark ? 'Switch to light mode' : 'Switch to dark mode',
        widget.onToggleTheme,
      ),
    ]);
  }

  /// Dice sits with the seed input (web: seed field + 🎲 side by side),
  /// never floating in the CFG/Batch row.
  Widget _diceBtn() {
    final c = context.lazy;
    return GestureDetector(
      onTap: () => setState(() =>
          _seedCtrl.text = '${DateTime.now().millisecondsSinceEpoch % 9007199254740991}'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 11),
        decoration: BoxDecoration(
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Icon(Icons.casino_outlined, size: 16, color: c.ink2),
      ),
    );
  }

  /// Result card: current image or the placeholder, like the web view box.
  Widget _resultBox() {
    final c = context.lazy;
    final img = _current!.images.first;
    return GestureDetector(
      onTap: () => _viewJob(_current!),
      child: Container(
        constraints: const BoxConstraints(minHeight: 200),
        decoration: BoxDecoration(
          color: c.accentTint,
          border: Border.all(color: c.borderSoft),
          borderRadius: BorderRadius.circular(16),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: CachedNetworkImage(
            imageUrl: _api.viewUrl(filename: img.filename, subfolder: img.subfolder, type: img.type),
            fit: BoxFit.contain,
            placeholder: (_, __) => const SizedBox(height: 200),
            errorWidget: (_, __, ___) => const SizedBox(
              height: 200,
              child: Center(child: Icon(Icons.broken_image_outlined)),
            ),
          ),
        ),
      ),
    );
  }

  /// One tile per job with the model-name badge, like .g-item + .g-badge.
  /// Tiles whose file is gone (deleted on the server) drop out instead of
  /// showing a broken-image box.
  Widget _jobTiles() {
    final tiles = <Widget>[];
    for (final job in _history) {
      if (job is! Map || job['images'] is! List) continue;
      final imgs = (job['images'] as List).whereType<Map>().where((o) {
        if (o['filename'] == null) return false;
        return !_dead.contains(UiImg('${o['filename']}', '${o['subfolder'] ?? ''}',
                '${o['type'] ?? 'output'}')
            .key);
      }).toList();
      if (imgs.isEmpty) continue;
      final o = imgs.first;
      final img = UiImg('${o['filename']}', '${o['subfolder'] ?? ''}', '${o['type'] ?? 'output'}');
      var modName = '${job['model_id'] ?? 'output'}';
      for (final m in _models) {
        if (m is Map && '${m['id']}' == '${job['model_id']}') {
          modName = '${m['name'] ?? modName}';
          break;
        }
      }
      tiles.add(_jobTile(img, modName, _jobViewOf(job)));
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

  _JobView _jobViewOf(Map job) {
    final imgs = ((job['images'] as List?) ?? []).whereType<Map>().where((o) {
      if (o['filename'] == null) return false;
      return !_dead.contains(
          UiImg('${o['filename']}', '${o['subfolder'] ?? ''}', '${o['type'] ?? 'output'}').key);
    }).map((o) => UiImg('${o['filename']}', '${o['subfolder'] ?? ''}', '${o['type'] ?? 'output'}')).toList();
    final meta = (job['meta'] is Map) ? Map<String, dynamic>.from(job['meta']) : <String, dynamic>{};
    return _JobView(
      images: imgs,
      modelId: '${job['model_id'] ?? meta['model_id'] ?? ''}',
      mode: '${job['mode'] ?? meta['mode'] ?? 't2i'}',
      prompt: '${job['prompt'] ?? meta['prompt'] ?? ''}',
      params: (job['params'] is Map)
          ? Map<String, dynamic>.from(job['params'])
          : ((meta['params'] is Map) ? Map<String, dynamic>.from(meta['params']) : <String, dynamic>{}),
      promptId: '${job['prompt_id'] ?? ''}',
    );
  }

  Widget _jobTile(UiImg img, String badge, _JobView job) {
    return GestureDetector(
      onTap: () => _viewJob(job),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AspectRatio(
          aspectRatio: 1,
          child: Stack(fit: StackFit.expand, children: [
            CachedNetworkImage(
              imageUrl:
                  _api.thumbUrl(filename: img.filename, subfolder: img.subfolder, type: img.type),
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(color: context.lazy.bgSoft),
              errorWidget: (_, __, ___) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _dead.add(img.key)) setState(() {});
                });
                return Container(color: context.lazy.bgSoft);
              },
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

  /// File select: `Template default — name` empty option, `(default)` suffix
  /// on the template file, err styling for a missing explicit pick.
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
}
