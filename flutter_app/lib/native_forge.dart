import 'dart:async';
import 'dart:convert';

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

/// Native port of the next-app Prompt Forge page (llama.cpp):
/// backend install, GGUF load/unload, engine status, enhance/caption/edit
/// streaming generation, and the HuggingFace GGUF downloader.
class NativeForgePage extends StatefulWidget {
  final String endpoint;
  final bool isDark;
  final VoidCallback onToggleTheme;
  const NativeForgePage({
    super.key,
    required this.endpoint,
    required this.isDark,
    required this.onToggleTheme,
  });

  @override
  State<NativeForgePage> createState() => _NativeForgePageState();
}

class _NativeForgePageState extends State<NativeForgePage> {
  late LazyApi _api;
  bool _syncing = true;
  String? _error;

  Map<String, dynamic> _cfg = {};
  Map<String, dynamic> _status = {};
  List<dynamic> _models = [];
  List<dynamic> _mmprojs = [];
  String _model = '';
  String _mmproj = 'Auto-Detect';
  bool _installing = false;
  bool _loading = false;

  late final TextEditingController _ctxCtrl;
  late final TextEditingController _tempCtrl;
  late final TextEditingController _maxTokCtrl;
  late final TextEditingController _topPCtrl;
  late final TextEditingController _promptCtrl;
  late final TextEditingController _editCtrl;
  late final TextEditingController _queryCtrl;
  String _mode = 'enhance';
  String _imageData = '';
  String _imageName = '';
  // Server image folder (upscale-style) for caption/edit: empty box =
  // default ComfyUI input folder, set box = custom folder, cleared box =
  // revert. _imgSrc tracks where the current image came from so a reload
  // can restore server picks (device bytes do not survive restarts).
  late final TextEditingController _imgDirCtrl;
  String _imgDir = '';
  List<dynamic> _imgLib = [];
  int _imgSel = -1;
  bool _scanningImg = false;
  String _imgSrc = '';

  bool _generating = false;
  String _output = '';
  String _genStatus = 'Idle';
  bool _searching = false;
  List<dynamic> _repos = [];
  final Map<String, bool> _openRepos = {};
  final Map<String, dynamic> _repoFiles = {};
  Timer? _pollTimer;

  bool get _backendPresent => _cfg['backend_present'] == true;
  bool get _alive {
    final s = _status['status'];
    return s == 'running' || s == 'loading';
  }

  @override
  void initState() {
    super.initState();
    _api = LazyApi(widget.endpoint);
    _ctxCtrl = TextEditingController(text: '2048');
    _tempCtrl = TextEditingController(text: '0.7');
    _maxTokCtrl = TextEditingController(text: '512');
    _topPCtrl = TextEditingController(text: '0.9');
    _promptCtrl = TextEditingController();
    _editCtrl = TextEditingController();
    _queryCtrl = TextEditingController();
    _imgDirCtrl = TextEditingController();
    _imgDirCtrl.addListener(_onImgDirChanged);
    _boot();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted && !_generating) _refresh();
    });
  }

  @override
  void didUpdateWidget(covariant NativeForgePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.endpoint != widget.endpoint) {
      _api.close();
      _api = LazyApi(widget.endpoint);
      _boot();
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _api.close();
    _ctxCtrl.dispose();
    _tempCtrl.dispose();
    _maxTokCtrl.dispose();
    _topPCtrl.dispose();
    _promptCtrl.dispose();
    _editCtrl.dispose();
    _queryCtrl.dispose();
    _imgDirCtrl.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    final p = await SharedPreferences.getInstance();
    _mode = p.getString('lazycomfy.native.forge.mode') ?? 'enhance';
    if (!['enhance', 'caption', 'edit'].contains(_mode)) _mode = 'enhance';
    _promptCtrl.text = p.getString('lazycomfy.native.forge.prompt') ?? '';
    _editCtrl.text = p.getString('lazycomfy.native.forge.edit') ?? '';
    _model = p.getString('lazycomfy.native.forge.model') ?? '';
    _mmproj = p.getString('lazycomfy.native.forge.mmproj') ?? 'Auto-Detect';
    _imgDirCtrl.text = p.getString('lazycomfy.native.forge.imgdir') ?? '';
    _imgSrc = p.getString('lazycomfy.native.forge.imgsrc') ?? '';
    _imageName = p.getString('lazycomfy.native.forge.imgname') ?? '';
    await _refresh(isBoot: true);
    await _scanImgDir();
    // Reload-safe server pick: re-fetch the same file's bytes.
    if (_imgSrc == 'server' && _imageName.isNotEmpty) {
      final hit = _imgLib.indexWhere(
          (e) => e is Map && '${e['name']}' == _imageName);
      if (hit >= 0) {
        await _fetchServerImage(hit, quiet: true);
      } else {
        _imgSrc = '';
        _imageName = '';
      }
    } else if (_imgSrc != 'server') {
      // Device bytes never survive a restart; drop the stale name.
      _imageData = '';
      if (_imgSrc == 'device') {
        _imgSrc = '';
        _imageName = '';
      }
    }
  }

  /// Clearing the box reverts to the default input folder.
  void _onImgDirChanged() {
    if (_imgDirCtrl.text.trim().isEmpty && !_scanningImg && _imgDir.isNotEmpty) {
      _scanImgDir();
    }
  }

  Future<void> _scanImgDir() async {
    if (_scanningImg) return;
    if (mounted) setState(() => _scanningImg = true);
    try {
      final box = _imgDirCtrl.text.trim();
      Map<String, dynamic> listed;
      try {
        listed = await _api.upscaleImages(box);
      } on ApiException catch (e) {
        // Stale custom path (other machine / recycled runtime): fall back
        // to the default input folder instead of failing.
        if (e.status == 400 && box.isNotEmpty) {
          listed = await _api.upscaleImages('');
          _imgDirCtrl.text = '';
        } else {
          rethrow;
        }
      }
      if (!mounted) return;
      setState(() {
        _imgDir = '${listed['dir'] ?? box}';
        _imgLib = (listed['images'] is List) ? List<dynamic>.from(listed['images']) : const [];
        _imgSel = -1;
        _scanningImg = false;
      });
      _persist();
    } catch (e) {
      if (!mounted) return;
      setState(() => _scanningImg = false);
      _snack(e is ApiException ? e.message : 'Scan failed.');
    } finally {
      _scanningImg = false;
    }
  }

  /// Pull a server-folder image down and use it as the task image.
  Future<void> _fetchServerImage(int i, {bool quiet = false}) async {
    if (i < 0 || i >= _imgLib.length || _imgLib[i] is! Map) return;
    final m = _imgLib[i] as Map;
    if (mounted) setState(() => _imgSel = i);
    try {
      final uri = Uri.parse(_api.upscalePreviewUrl('${m['path']}'));
      final res = await http.get(uri).timeout(const Duration(minutes: 2));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
        throw Exception('HTTP ${res.statusCode}');
      }
      if (res.bodyBytes.length > 11 * 1024 * 1024) {
        if (!quiet) _snack('Image too large (max ~11 MB).');
        return;
      }
      final name = '${m['name'] ?? 'image.png'}';
      final ext = name.split('.').last.toLowerCase();
      final mime = ext == 'png' ? 'image/png' : (ext == 'webp' ? 'image/webp' : 'image/jpeg');
      if (!mounted) return;
      setState(() {
        _imageData = 'data:$mime;base64,${base64Encode(res.bodyBytes)}';
        _imageName = name;
        _imgSrc = 'server';
      });
      _persist();
    } catch (e) {
      if (!quiet) _snack(e is ApiException ? e.message : 'Load failed.');
    }
  }

  String _imgLabel(Map m) {
    final size = _fmtSize(m['size']);
    return '${m['name'] ?? ''}${size.isEmpty ? '' : ' · $size'}';
  }

  Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('lazycomfy.native.forge.mode', _mode);
    await p.setString('lazycomfy.native.forge.prompt', _promptCtrl.text);
    await p.setString('lazycomfy.native.forge.edit', _editCtrl.text);
    await p.setString('lazycomfy.native.forge.model', _model);
    await p.setString('lazycomfy.native.forge.mmproj', _mmproj);
    await p.setString('lazycomfy.native.forge.imgdir', _imgDirCtrl.text);
    await p.setString('lazycomfy.native.forge.imgsrc', _imgSrc);
    await p.setString('lazycomfy.native.forge.imgname', _imageName);
  }

  /// Save context whenever the page hides so nothing is lost.
  @override
  void deactivate() {
    _persist();
    super.deactivate();
  }

  Future<void> _refresh({bool isBoot = false}) async {
    if (isBoot) setState(() => _syncing = true);
    try {
      final cfg = await _api.llmConfig();
      final status = await _api.llmStatus();
      if (!mounted) return;
      setState(() {
        _cfg = cfg;
        _status = status;
        _syncing = false;
        _error = null;
        final ms = (cfg['models'] is List) ? List<dynamic>.from(cfg['models']) : const [];
        _models = ms;
        _mmprojs = (cfg['mmprojs'] is List) ? List<dynamic>.from(cfg['mmprojs']) : const [];
        // Keep the user's picks; only fall back when the list is fresh
        // (non-empty) and the pick is actually gone. An empty list is a
        // blip, never a reason to wipe the selection.
        if (_models.isNotEmpty &&
            (_model.isEmpty || !_models.any((m) => m is Map && '${m['name']}' == _model))) {
          _model = '${(_models.first as Map)['name']}';
        }
        if (_mmproj != 'Auto-Detect' &&
            _mmprojs.isNotEmpty &&
            !_mmprojs.any((m) => m is Map && '${m['name']}' == _mmproj)) {
          _mmproj = 'Auto-Detect';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _syncing = false;
        if (isBoot) _error = e is ApiException ? e.message : 'Sync failed: $e';
      });
    }
  }

  void _openDownloads() {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NativeDownloadsPage(endpoint: widget.endpoint, onChanged: _refresh),
      ),
    );
  }

  Future<void> _install() async {
    setState(() => _installing = true);
    try {
      await _api.llmInstall();
    } catch (e) {
      _snack(e is ApiException ? e.message : 'Install failed.');
    } finally {
      if (mounted) setState(() => _installing = false);
      _refresh();
    }
  }

  Future<void> _toggleLoad() async {
    if (_alive) {
      try {
        await _api.llmUnload();
        _snack('Model unloaded.', ok: true);
      } catch (e) {
        _snack(e is ApiException ? e.message : 'Unload failed.');
      }
      _refresh();
      return;
    }
    if (_model.isEmpty) {
      _snack('Select a GGUF model first.');
      return;
    }
    setState(() => _loading = true);
    try {
      await _api.llmLoad(_model, _mmproj, int.tryParse(_ctxCtrl.text) ?? 2048);
      _snack('Model loaded.', ok: true);
    } catch (e) {
      _snack(e is ApiException ? e.message : 'Load failed.');
    } finally {
      if (mounted) setState(() => _loading = false);
      _refresh();
    }
  }

  Future<void> _pickImage() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
        withData: true,
      );
      if (res == null || res.files.isEmpty) return;
      final f = res.files.first;
      final bytes = f.bytes;
      if (bytes == null || bytes.isEmpty) return;
      if (bytes.length > 11 * 1024 * 1024) {
        _snack('Image too large (max ~11 MB).');
        return;
      }
      final ext = f.name.split('.').last.toLowerCase();
      final mime = ext == 'png'
          ? 'image/png'
          : (ext == 'webp' ? 'image/webp' : 'image/jpeg');
      setState(() {
        _imageData = 'data:$mime;base64,${base64Encode(bytes)}';
        _imageName = f.name;
        _imgSrc = 'device';
      });
      _persist();
    } catch (_) {
      _snack('Pick failed.');
    }
  }

  Future<void> _generate() async {
    if (_generating) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (_model.isEmpty) {
      _snack('Select a GGUF model first.');
      return;
    }
    if (_mode != 'caption' && _promptCtrl.text.trim().isEmpty && _editCtrl.text.trim().isEmpty) {
      _snack('Enter a prompt first.');
      return;
    }
    if (_mode != 'enhance' && _imageData.isEmpty) {
      _snack('Pick an image first.');
      return;
    }
    setState(() {
      _generating = true;
      _output = '';
      _genStatus = 'Starting…';
    });
    try {
      await _api.llmGenerate({
        'mode': _mode,
        'model': _model,
        'mmproj': _mmproj,
        'context_length': int.tryParse(_ctxCtrl.text) ?? 2048,
        'temperature': double.tryParse(_tempCtrl.text) ?? 0.7,
        'max_tokens': int.tryParse(_maxTokCtrl.text) ?? 512,
        'top_p': double.tryParse(_topPCtrl.text) ?? 0.9,
        'prompt': _promptCtrl.text,
        'edit_prompt': _editCtrl.text,
        'image': _imageData,
      }, (ev) {
        if (!mounted) return;
        final type = ev['type'];
        if (type == 'chunk') {
          setState(() {
            _output += '${ev['text'] ?? ''}';
            final s = ev['stats'];
            _genStatus = s is Map
                ? '${s['eval_tokens'] ?? 0} tokens · ${((s['tokens_sec'] as num?)?.toDouble() ?? 0).toStringAsFixed(1)} t/s · ${((s['elapsed_time'] as num?)?.toDouble() ?? 0).toStringAsFixed(1)}s'
                : 'Generating…';
          });
        } else if (type == 'done') {
          final s = (ev['stats'] is Map) ? ev['stats'] as Map : const {};
          setState(() {
            _genStatus =
                'Done · ${s['eval_tokens'] ?? 0} tokens · ${((s['tokens_sec'] as num?)?.toDouble() ?? 0).toStringAsFixed(1)} t/s · ${((s['elapsed_time'] as num?)?.toDouble() ?? 0).toStringAsFixed(1)}s';
          });
        } else if (type == 'error') {
          setState(() => _genStatus = 'Error: ${ev['message'] ?? 'unknown'}');
          _snack('${ev['message'] ?? 'Generation error'}');
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _genStatus = 'Error: ${e is ApiException ? e.message : e}');
      _snack(e is ApiException ? e.message : 'Generate failed.');
    } finally {
      if (mounted) setState(() => _generating = false);
      _persist();
    }
  }

  Future<void> _search() async {
    final q = _queryCtrl.text.trim();
    if (q.isEmpty || _searching) return;
    setState(() => _searching = true);
    try {
      final d = await _api.llmSearch(q);
      if (!mounted) return;
      final repos = d['repos'];
      setState(() => _repos = repos is List ? List<dynamic>.from(repos) : const []);
    } catch (e) {
      _snack(e is ApiException ? e.message : 'Search failed.');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _toggleFiles(String repoId) async {
    final open = !(_openRepos[repoId] ?? false);
    setState(() => _openRepos[repoId] = open);
    if (!open || _repoFiles.containsKey(repoId)) return;
    try {
      final d = await _api.llmFiles(repoId);
      if (!mounted) return;
      setState(() => _repoFiles[repoId] = d);
    } catch (e) {
      _snack(e is ApiException ? e.message : 'Files failed.');
    }
  }

  Future<void> _downloadFile(String url, String name) async {
    try {
      await _api.llmDownload(url, name);
      _snack('Downloading $name.', ok: true);
    } catch (e) {
      _snack(e is ApiException ? e.message : 'Download failed.');
    }
    _refresh();
  }

  void _snack(String msg, {bool ok = false}) {
    if (!mounted) return;
    showUiSnack(context, msg, ok: ok);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.lazy;
    final mq = MediaQuery.paddingOf(context);
    const headerH = 42.0;
    final running = _status['status'] == 'running';
    final loading = _status['status'] == 'loading';
    final alive = running || loading;
    final install = (_cfg['install'] is Map)
        ? Map<String, dynamic>.from(_cfg['install'])
        : const {};
    final installRunning = install['status'] == 'running' || install['status'] == 'extracting';
    final gpuLayers = (_status['gpu_layers'] as num?)?.toInt() ?? 0;
    final totalLayers = (_status['total_layers'] as num?)?.toInt() ?? 0;
    final tasks = (_cfg['tasks'] is List) ? List<dynamic>.from(_cfg['tasks']) : const [];
    final activeTasks =
        tasks.where((t) => t is Map && {'starting', 'downloading', 'cancelling'}.contains(t['status'])).toList();
    return Scaffold(
      backgroundColor: c.bg,
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: EdgeInsets.fromLTRB(16, mq.top + headerH + 12, 16, mq.bottom + 24),
              children: [
                _pageHeader('Forge'),
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
                  if ('${_cfg['models_dir_error'] ?? ''}'.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: UiErrBanner('${_cfg['models_dir_error']}'),
                    ),
                  uiField(context, 'GGUF model'),
                  UiSelect(
                    value: _model.isEmpty ? null : _model,
                    items: {
                      for (final m in _models)
                        if (m is Map)
                          '${m['name']}': '${m['name']} (${m['size_gb'] ?? '?'} GB)',
                    },
                    hint: _models.isEmpty ? 'No models downloaded' : 'Select a model…',
                    sheetTitle: 'GGUF model',
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => _model = v);
                      _persist();
                    },
                  ),
                  const SizedBox(height: 10),
                  uiField(context, 'Vision projector (mmproj)'),
                  UiSelect(
                    value: _mmproj,
                    items: {
                      'Auto-Detect': 'Auto-Detect Projector',
                      'None': 'None (Text-only)',
                      for (final m in _mmprojs)
                        if (m is Map)
                          '${m['name']}': '${m['name']} (${m['size_gb'] ?? '?'} GB)',
                    },
                    hint: 'Auto-Detect Projector',
                    sheetTitle: 'Vision projector',
                    onChanged: (v) {
                      setState(() => _mmproj = (v == null || v.isEmpty) ? 'Auto-Detect' : v);
                      _persist();
                    },
                  ),
                  const SizedBox(height: 6),
                  Text('Models without a matching mmproj still work for text-only modes.',
                      style: TextStyle(fontSize: 12.5, color: c.muted)),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        uiField(context, 'Context length'),
                        uiTextField(context, _ctxCtrl, '2048', number: true, decimal: false),
                      ]),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        uiField(context, 'Temperature'),
                        uiTextField(context, _tempCtrl, '0.7', number: true),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        uiField(context, 'Max tokens'),
                        uiTextField(context, _maxTokCtrl, '512', number: true, decimal: false),
                      ]),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        uiField(context, 'Top-P'),
                        uiTextField(context, _topPCtrl, '0.9', number: true),
                      ]),
                    ),
                  ]),
                  if (!_backendPresent) ...[
                    const SizedBox(height: 10),
                    if (installRunning)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: ((install['progress'] as num?)?.toDouble() ?? 0) / 100,
                          minHeight: 4,
                          valueColor: AlwaysStoppedAnimation<Color>(c.accent),
                          backgroundColor: c.accentSoft,
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        installRunning
                            ? '${install['stage'] ?? 'installing…'}'
                            : '${install['error'] ?? ''}'.isNotEmpty
                                ? ''
                                : 'Backend not installed — tap Install to download.',
                        style: fmono(10.5, c.muted2),
                      ),
                    ),
                    if ('${install['error'] ?? ''}'.isNotEmpty && !installRunning)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('${install['error']}', style: TextStyle(color: c.err, fontSize: 12)),
                      ),
                    if (!installRunning)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: UiGhostBtn(
                            'INSTALL BACKEND', _installing ? () {} : _install),
                      ),
                  ],
                  const SizedBox(height: 8),
                  UiPrimaryBtn(
                    loading
                        ? 'Loading Model…'
                        : alive
                            ? 'Unload Model'
                            : 'Load Model',
                    (loading ||
                            _loading ||
                            (!alive && !(_models.isNotEmpty && !_generating)))
                        ? null
                        : _toggleLoad,
                  ),
                ]),
                uiCard(context, [
                  uiSection(context, 'Engine'),
                  if (!_backendPresent)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: UiErrBanner(
                          'llama.cpp backend is not installed — tap Install backend above to download it.'),
                    ),
                  _kv('State',
                      alive
                          ? '${_status['model']}${(_status['mmproj'] ?? '') != '' ? ' · ${_status['mmproj']}' : ''}'
                          : 'Unloaded — no model in memory'),
                  _kv('Mode',
                      gpuLayers > 0 ? 'GPU $gpuLayers/$totalLayers layers' : 'CPU'),
                  if ('${_status['placement_note'] ?? ''}'.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('GPU offload failed, running on CPU: ${_status['placement_note']}',
                          style: TextStyle(fontSize: 12.5, color: c.muted)),
                    ),
                  if ('${_status['log_tail'] ?? ''}'.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Container(
                        height: 120,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: c.bgSoft,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: c.borderSoft),
                        ),
                        child: SingleChildScrollView(
                          child: Text('${_status['log_tail']}',
                              style: fmono(10, c.ink3)),
                        ),
                      ),
                    ),
                ]),
                uiCard(context, [
                  uiSection(context, 'Task'),
                  UiSeg(
                    options: const ['enhance', 'caption', 'edit'],
                    value: _mode,
                    labels: const {
                      'enhance': 'Enhance Prompt',
                      'caption': 'Image Caption',
                      'edit': 'Image Edit'
                    },
                    onChanged: (v) {
                      FocusManager.instance.primaryFocus?.unfocus();
                      setState(() => _mode = v);
                      _persist();
                    },
                  ),
                  const SizedBox(height: 10),
                  uiField(context,
                      _mode == 'caption' ? 'Instruction (optional)' : 'Prompt to enhance'),
                  uiTextField(
                      context,
                      _promptCtrl,
                      _mode == 'caption'
                          ? 'Describe this image in detail.'
                          : 'A cat on a rooftop at sunset…',
                      maxLines: 4),
                  if (_mode == 'edit') ...[
                    const SizedBox(height: 10),
                    uiField(context, 'Edit instruction'),
                    uiTextField(context, _editCtrl,
                        'Change the background to a forest, keep the cat…',
                        maxLines: 3),
                  ],
                  if (_mode != 'enhance') ...[
                    const SizedBox(height: 10),
                    uiField(context, 'Image folder (server)'),
                    Row(children: [
                      Expanded(
                        child: uiTextField(context, _imgDirCtrl,
                            'Leave empty for the ComfyUI input folder'),
                      ),
                      const SizedBox(width: 8),
                      UiGhostBtn(_scanningImg ? 'SCANNING…' : 'RESCAN',
                          _scanningImg ? () {} : _scanImgDir),
                    ]),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                          _imgDir.isEmpty
                              ? 'Scanning…'
                              : 'Folder: $_imgDir · ${_imgLib.length} image${_imgLib.length == 1 ? '' : 's'}',
                          style: fmono(10.5, c.muted2)),
                    ),
                    const SizedBox(height: 8),
                    UiSelect(
                      value: (_imgSel >= 0 && _imgSel < _imgLib.length) ? '$_imgSel' : null,
                      items: {
                        for (int i = 0; i < _imgLib.length; i++)
                          if (_imgLib[i] is Map) '$i': _imgLabel(_imgLib[i] as Map),
                      },
                      hint: _imgLib.isEmpty ? 'No images found' : 'Choose a server image…',
                      sheetTitle: 'Server image',
                      onChanged: (v) {
                        final i = int.tryParse(v ?? '');
                        if (i != null) _fetchServerImage(i);
                      },
                    ),
                    const SizedBox(height: 10),
                    uiField(context, 'Or upload from device'),
                    _imageDrop(),
                  ],
                  const SizedBox(height: 10),
                  UiPrimaryBtn('Generate', _generating ? null : _generate),
                ]),
                uiCard(context, [
                  uiSection(context, 'Output'),
                  Container(
                    constraints: const BoxConstraints(minHeight: 140),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: c.accentTint,
                      border: Border.all(color: c.border),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SelectableText(
                      _output.isEmpty ? 'Generated text appears here…' : _output,
                      style: TextStyle(
                          fontSize: 13,
                          color: _output.isEmpty ? c.muted3 : c.ink,
                          height: 1.5),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(children: [
                    Expanded(
                        child: Text(_genStatus, style: fmono(10.5, c.muted2))),
                    UiGhostBtn('COPY', _output.trim().isEmpty
                        ? () {}
                        : () {
                            Clipboard.setData(ClipboardData(text: _output));
                            _snack('Copied to clipboard.', ok: true);
                          }),
                  ]),
                ]),
                uiCard(context, [
                  uiSection(context, 'Model downloader'),
                  Text(
                      'Search HuggingFace for GGUF repos — view files and download them straight into ComfyUI/models/llm_gguf.',
                      style: TextStyle(fontSize: 12.5, color: c.muted)),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: uiTextField(context, _queryCtrl,
                          'e.g. Qwen 3 4b vl, SmolVLM, Llama 3.2'),
                    ),
                    const SizedBox(width: 8),
                    UiGhostBtn('SEARCH', _searching ? () {} : _search),
                  ]),
                  const SizedBox(height: 10),
                  // Active GGUF downloads: progress + cancel above the
                  // searched list (same row style as the downloads window).
                  for (final t in activeTasks)
                    if (t is Map)
                      Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                                child: uiTaskRow(context, t, source: 'HF')),
                            const SizedBox(width: 8),
                            UiDlCircle(busy: true, onTap: () async {
                              try {
                                await _api.llmCancelDownload('${t['id']}');
                              } catch (_) {}
                            }),
                          ]),
                  for (final r in _repos)
                    if (r is Map) _repoRow(r, activeTasks),
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
        ],
      ),
    );
  }

  Widget _repoRow(Map r, List<dynamic> activeTasks) {
    final c = context.lazy;
    final id = '${r['id']}';
    final open = _openRepos[id] ?? false;
    final files = (_repoFiles[id] is Map) ? (_repoFiles[id] as Map)['files'] : null;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Text(id,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.ink)),
          ),
          Text(
              '${r['gated'] == true ? 'Gated · ' : ''}↓ ${_fmtNum(r['downloads'])} · ★ ${_fmtNum(r['likes'])}',
              style: fmono(10.5, c.muted2)),
          const SizedBox(width: 8),
          UiGhostBtn(open ? 'HIDE FILES' : 'VIEW FILES', () => _toggleFiles(id)),
        ]),
        if (open) ...[
          const SizedBox(height: 8),
          if (files == null)
            Text('Loading files…', style: TextStyle(fontSize: 12.5, color: c.muted)),
          if (files is List)
            for (final f in files)
              if (f is Map) _repoFileRow(id, f, activeTasks),
        ],
      ]),
    );
  }

  Widget _repoFileRow(String repoId, Map f, List<dynamic> activeTasks) {
    final url = '${f['url'] ?? ''}';
    final name = '${f['name'] ?? url.split('/').last}';
    Map? task;
    for (final t in activeTasks) {
      if (t is Map && '${t['url'] ?? ''}' == url) task = t;
    }
    final busy = task != null;
    final size = _fmtSize(f['size']);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        Expanded(
          child: Text(name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: context.lazy.ink2)),
        ),
        if (size.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(size, style: fmono(10.5, context.lazy.muted2)),
          ),
        busy
            ? UiDlCircle(busy: true, onTap: () async {
                try {
                  await _api.llmCancelDownload('${task!['id']}');
                } catch (_) {}
              })
            : UiDlCircle(busy: false, onTap: () => _downloadFile(url, name)),
      ]),
    );
  }

  String _fmtNum(dynamic v) {
    if (v is! num) return '0';
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
    return '$v';
  }

  String _fmtSize(dynamic bytes) {
    if (bytes is! num || bytes <= 0) return '';
    final mb = bytes / 1048576;
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.toStringAsFixed(1)} MB';
  }

  Widget _pageHeader(String title) {
    final c = context.lazy;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(title, style: disp(16, FontWeight.w700, c.ink)),
    );
  }

  Widget _syncDot() {
    final c = context.lazy;
    final dot = _error != null ? c.err : (_syncing ? c.warn : c.ok);
    final label = _error != null ? 'OFFLINE' : (_syncing ? 'SYNCING' : 'SYNCED');
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 8, height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: dot)),
      const SizedBox(width: 6),
      Text(label, style: fmono(10, c.muted2, ls: 0.06)),
    ]);
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

  Widget _imageDrop() {
    if (_imageData.isNotEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            base64Decode(_imageData.split(',').last),
            height: 160,
            width: double.infinity,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) =>
                const SizedBox(height: 160, child: Icon(Icons.broken_image_outlined)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(_imageName,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: context.lazy.muted)),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: UiDangerBtn('Remove', () {
            setState(() {
              _imageData = '';
              _imageName = '';
              _imgSrc = '';
            });
            _persist();
          }),
        ),
      ]);
    }
    return GestureDetector(
      onTap: _pickImage,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 12),
        decoration: BoxDecoration(
          border: Border.all(color: context.lazy.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Click or pick an image here',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: context.lazy.ink2)),
            const SizedBox(height: 2),
            Text('PNG / JPEG, up to ~11 MB', style: fmono(10.5, context.lazy.muted2)),
          ]),
        ),
      ),
    );
  }
}
