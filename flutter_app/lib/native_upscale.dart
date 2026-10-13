import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'edge_frost.dart';
import 'lazy_theme.dart';
import 'native_downloads.dart';
import 'ui_kit.dart';

/// Native port of the next-app Upscale page (SeedVR2): pick an image from
/// the server input dir (or upload), choose unet + VAE, run tiled upscale
/// with progress, show result with meta/saved lines, unload VRAM models.
class NativeUpscalePage extends StatefulWidget {
  final String endpoint;
  final bool isDark;
  final VoidCallback onToggleTheme;
  const NativeUpscalePage({
    super.key,
    required this.endpoint,
    required this.isDark,
    required this.onToggleTheme,
  });

  @override
  State<NativeUpscalePage> createState() => _NativeUpscalePageState();
}

class _UpResult {
  final String filename;
  final String subfolder;
  final String type;
  const _UpResult(this.filename, this.subfolder, this.type);
}

class _NativeUpscalePageState extends State<NativeUpscalePage> {
  late LazyApi _api;
  bool _syncing = true;
  String? _error;

  List<dynamic> _unets = [];
  List<dynamic> _vaes = [];
  String _inDir = '';
  List<dynamic> _images = [];
  int _selIdx = 0;
  String _unet = '';
  String _vae = '';

  late final TextEditingController _scaleCtrl;
  late final TextEditingController _seedCtrl;
  late final TextEditingController _tileCtrl;
  late final TextEditingController _overlapCtrl;
  late final TextEditingController _outDirCtrl;
  String _color = 'none';

  bool _busy = false;
  bool _unloading = false;
  String _serverInputDir = '';
  String? _promptId;
  String _jobState = 'Idle';
  double? _progress;
  _UpResult? _result;
  String _meta = '';
  String _savedLine = '';
  String _blackWarn = '';
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _api = LazyApi(widget.endpoint);
    _scaleCtrl = TextEditingController(text: '4');
    _seedCtrl = TextEditingController(text: '0');
    _tileCtrl = TextEditingController(text: '512');
    _overlapCtrl = TextEditingController(text: '128');
    _outDirCtrl = TextEditingController();
    _boot();
  }

  @override
  void didUpdateWidget(covariant NativeUpscalePage oldWidget) {
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
    _scaleCtrl.dispose();
    _seedCtrl.dispose();
    _tileCtrl.dispose();
    _overlapCtrl.dispose();
    _outDirCtrl.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    final p = await SharedPreferences.getInstance();
    _scaleCtrl.text = p.getString('lazycomfy.native.upscale.scale') ?? '4';
    _color = p.getString('lazycomfy.native.upscale.color') ?? 'none';
    _outDirCtrl.text = p.getString('lazycomfy.native.upscale.outdir') ?? '';
    await _sync();
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
      final cfg = await _step('upscale', _api.upscaleConfig);
      final unets = (cfg['unets'] is List) ? List<dynamic>.from(cfg['unets']) : const [];
      final vaes = (cfg['vaes'] is List) ? List<dynamic>.from(cfg['vaes']) : const [];
      final inputDir = '${cfg['input_dir'] ?? ''}';
      final p = await SharedPreferences.getInstance();
      final dir = (p.getString('lazycomfy.native.upscale.indir') ?? '').isNotEmpty
          ? p.getString('lazycomfy.native.upscale.indir')!
          : inputDir;
      final listed = await _step('images', () => _api.upscaleImages(dir));
      if (!mounted) return;
      setState(() {
        _unets = unets;
        _vaes = vaes;
        _serverInputDir = inputDir;
        _inDir = '${listed['dir'] ?? dir}';
        _images = (listed['images'] is List) ? List<dynamic>.from(listed['images']) : const [];
        if (_selIdx >= _images.length) _selIdx = 0;
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

  Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('lazycomfy.native.upscale.scale', _scaleCtrl.text);
    await p.setString('lazycomfy.native.upscale.color', _color);
    await p.setString('lazycomfy.native.upscale.outdir', _outDirCtrl.text);
    await p.setString('lazycomfy.native.upscale.indir', _inDir);
  }

  /// Only SeedVR2-specific VAEs belong in the menu (seedvr* / ema*).
  /// Anything else is a foreign VAE the workflow cannot use.
  List<String> get _seedvrVaes {
    final out = <String>[];
    for (final v in _vaes) {
      final n = '$v';
      final low = n.toLowerCase();
      if (low.contains('seedvr') || low.startsWith('ema')) out.add(n);
    }
    return out;
  }

  /// Missing models for the banner + disabled start, mirroring the web
  /// err-banner copy.
  List<String> _missing() {
    final miss = <String>[];
    if (_unet.isEmpty || !_unets.map((e) => '$e').contains(_unet)) {
      miss.add('SeedVR2 model');
    }
    if (_vae.isEmpty || !_seedvrVaes.contains(_vae)) miss.add('VAE');
    return miss;
  }

  void _openDownloads() {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NativeDownloadsPage(endpoint: widget.endpoint, onChanged: _sync),
      ),
    );
  }

  String _fmtSize(dynamic bytes) {
    if (bytes is! num || bytes <= 0) return '';
    final mb = bytes / 1048576;
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.toStringAsFixed(1)} MB';
  }
  Future<void> _upload() async {
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
      final up = await _api.uploadImage(bytes, f.name);
      if (!mounted) return;
      var dir = _inDir;
      final rawSub = up['subfolder'];
      final sub = (rawSub is String && rawSub.isNotEmpty ? rawSub : 'lazycomfy')
          .replaceAll(RegExp(r'^/+|/+$'), '');
      if (_serverInputDir.isNotEmpty) {
        final root = _serverInputDir.replaceAll(RegExp(r'/+$'), '');
        dir = '$root/$sub';
      }
      await _scanDir(dir);
      if (!mounted) return;
      final upName = '${up['name']}';
      final idx = _images.indexWhere((i) {
        if (i is! Map) return false;
        final p = '${i['path']}';
        final n = '${i['name']}';
        return p.endsWith('/$upName') || n == upName;
      });
      setState(() => _selIdx = idx >= 0 ? idx : 0);
      _snack('Image uploaded: ${up['name']}', ok: true);
    } catch (e) {
      _snack(e is ApiException ? e.message : 'Upload failed.');
    }
  }

  Future<void> _scanDir(String dir) async {
    try {
      final listed = await _api.upscaleImages(dir);
      if (!mounted) return;
      setState(() {
        _inDir = '${listed['dir'] ?? dir}';
        _images = (listed['images'] is List) ? List<dynamic>.from(listed['images']) : const [];
        if (_selIdx >= _images.length) _selIdx = 0;
      });
    } catch (e) {
      _snack(e is ApiException ? e.message : 'Scan failed.');
    }
  }

  int _clamp(String v, int lo, int hi) {
    final n = int.tryParse(v);
    if (n == null) return lo;
    return n.clamp(lo, hi);
  }

  Future<void> _start() async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_images.isEmpty || _selIdx >= _images.length) {
      _snack('Pick an image first.');
      return;
    }
    final miss = _missing();
    if (miss.isNotEmpty) {
      _snack('Missing: ${miss.join(', ')}.');
      return;
    }
    final img = _images[_selIdx] as Map;
    setState(() {
      _busy = true;
      _result = null;
      _meta = '';
      _savedLine = '';
      _blackWarn = '';
      _jobState = 'Submitted — waiting for the queue…';
      _progress = 8;
    });
    try {
      final clientId = await getClientId();
      final id = await _api.upscaleGenerate({
        'unet': _unet,
        'vae': _vae,
        'image': '${img['path']}',
        'scale': double.tryParse(_scaleCtrl.text) ?? 4.0,
        'tile_size': _clamp(_tileCtrl.text, 64, 4096),
        'tile_overlap': _clamp(_overlapCtrl.text, 0, 4096),
        'color': _color,
        'seed': _clamp(_seedCtrl.text, 1, 9007199254740991),
        'out_dir': _outDirCtrl.text.trim(),
        'client_id': clientId,
      });
      if (!mounted) return;
      setState(() => _promptId = id);
      _persist();
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) => _poll());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _jobState = 'Failed to start';
      });
      _snack(e is ApiException ? e.message : 'Queue failed.');
    }
  }

  Future<void> _poll() async {
    final id = _promptId;
    if (id == null) {
      _pollTimer?.cancel();
      return;
    }
    Map<String, dynamic> r;
    try {
      r = await _api.upscaleResult(id);
    } catch (e) {
      _pollTimer?.cancel();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _jobState = 'Polling failed';
      });
      _snack(e is ApiException ? e.message : 'Poll failed.');
      return;
    }
    if (!mounted || _promptId != id) return;
    if (r['status'] == 'running') {
      setState(() {
        _jobState = 'Upscaling (tiled)…';
        _progress = 45;
      });
      return;
    }
    _pollTimer?.cancel();
    setState(() => _busy = false);
    if (r['status'] == 'success') {
      setState(() {
        _progress = 100;
        _jobState = 'Done';
      });
      _showResult(r);
    } else if (r['status'] == 'error') {
      final err = r['error'];
      setState(() {
        _progress = null;
        _jobState = 'Failed';
      });
      _snack('Upscale failed: ${(err is Map ? err['message'] ?? err['type'] : err) ?? 'unknown error'}');
      if ('${r['error_hint'] ?? ''}'.isNotEmpty) _snack('${r['error_hint']}');
    } else {
      setState(() {
        _progress = null;
        _jobState = 'Unknown status';
      });
    }
  }

  void _showResult(Map<String, dynamic> r) {
    final outs = (r['outputs'] is List) ? r['outputs'] : const [];
    if (outs.isNotEmpty && outs.first is Map) {
      final o = outs.first as Map;
      setState(() => _result = _UpResult(
          '${o['filename']}', '${o['subfolder'] ?? ''}', '${o['type'] ?? 'output'}'));
    }
    setState(() {
      _meta = 'SeedVR2 · $_unet · VAE $_vae · ${_scaleCtrl.text}x · tiles ${_tileCtrl.text}px · color $_color';
      if (r['saved_dir'] != null) {
        if (r['saved_error'] != null) {
          _savedLine = 'Custom save folder: ${r['saved_error']}';
        } else if (r['saved'] is List && (r['saved'] as List).isNotEmpty) {
          _savedLine = 'Saved to: ${(r['saved'] as List).join(', ')}';
        } else {
          _savedLine = 'Custom save folder has no matching output file.';
        }
      } else {
        _savedLine = 'Saved in the ComfyUI output folder.';
      }
      _blackWarn = r['black_output'] == true
          ? '${r['black_hint'] ?? 'Output came out all black — possible NaN in the VAE decode.'}'
          : '';
    });
  }

  Future<void> _unload() async {
    setState(() => _unloading = true);
    try {
      await _api.unloadModels('all');
      if (!mounted) return;
      _snack('VRAM models unloaded.', ok: true);
    } catch (e) {
      if (!mounted) return;
      _snack(e is ApiException ? e.message : 'Unload failed.');
    } finally {
      if (mounted) setState(() => _unloading = false);
    }
  }

  Future<void> _save() async {
    final r = _result;
    if (r == null) return;
    try {
      final uri = Uri.parse(_api.viewUrl(filename: r.filename, subfolder: r.subfolder, type: r.type));
      final res = await http.get(uri).timeout(const Duration(minutes: 5));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final saved =
          await FilePicker.platform.saveFile(fileName: r.filename, bytes: res.bodyBytes);
      if (!mounted) return;
      _snack(saved == null ? 'Download cancelled.' : 'Saved: $saved', ok: saved != null);
    } catch (_) {
      _snack('Download failed. Check the connection and retry.');
    }
  }

  void _snack(String msg, {bool ok = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: ok ? const Color(0xFF14532D) : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.lazy;
    final mq = MediaQuery.paddingOf(context);
    const headerH = 42.0;
    final sel = (_images.isNotEmpty && _selIdx < _images.length)
        ? Map<String, dynamic>.from(_images[_selIdx] as Map)
        : null;
    return Scaffold(
      backgroundColor: c.bg,
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _sync,
            child: ListView(
              padding: EdgeInsets.fromLTRB(16, mq.top + headerH + 12, 16, mq.bottom + 24),
              children: [
                _pageHeader('Upscale'),
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
                  uiSection(context, 'Image'),
                  UiSelect(
                    value: _images.isEmpty ? null : '$_selIdx',
                    items: {
                      for (int i = 0; i < _images.length; i++)
                        if (_images[i] is Map)
                          '$i': '${(_images[i] as Map)['name']} · ${_fmtSize((_images[i] as Map)['size'])}',
                    },
                    hint: _images.isEmpty ? 'No images found' : 'Choose image',
                    sheetTitle: 'Image',
                    onChanged: (v) {
                      FocusManager.instance.primaryFocus?.unfocus();
                      setState(() => _selIdx = int.tryParse(v ?? '') ?? 0);
                    },
                  ),
                  const SizedBox(height: 6),
                  Text('Uploaded images join the ComfyUI input folder automatically.',
                      style: TextStyle(fontSize: 12.5, color: c.muted)),
                  if (sel != null) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: UiRatioImage(
                        url: _api.upscalePreviewUrl('${sel['path']}'),
                        fallbackHeight: 200,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(child: UiGhostBtn('UPLOAD IMAGE', _upload)),
                    const SizedBox(width: 8),
                    Expanded(child: UiGhostBtn('RESCAN FOLDER', () => _scanDir(_inDir))),
                  ]),
                  if (_inDir.isNotEmpty) ...[
                    Text(_inDir, overflow: TextOverflow.ellipsis, style: fmono(10.5, c.muted2)),
                  ],
                ]),
                uiCard(context, [
                  uiSection(context, 'Model'),
                  if (_missing().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: UiErrBanner(
                        'SeedVR2 model or VAE is missing — download them from the Model downloads window.',
                        onTap: _openDownloads,
                      ),
                    ),
                  uiField(context, 'SeedVR2 model'),
                  UiSelect(
                    value: _unet.isEmpty ? null : _unet,
                    items: {for (final u in _unets) '$u': '$u'},
                    hint: _syncing
                        ? 'Loading…'
                        : (_unets.isEmpty ? 'No SeedVR2 model found' : 'Choose model'),
                    sheetTitle: 'SeedVR2 model',
                    onChanged: (v) => setState(() => _unet = v ?? ''),
                  ),
                  const SizedBox(height: 10),
                  uiField(context, 'VAE'),
                  UiSelect(
                    value: _vae.isEmpty ? null : _vae,
                    items: {for (final v in _seedvrVaes) v: v},
                    hint: _syncing
                        ? 'Loading…'
                        : (_seedvrVaes.isEmpty ? 'No SeedVR VAE found' : 'Choose VAE'),
                    sheetTitle: 'VAE',
                    onChanged: (v) => setState(() => _vae = v ?? ''),
                  ),
                  const SizedBox(height: 6),
                  Text('SeedVR2 uses no text encoder — only the diffusion model and its VAE.',
                      style: TextStyle(fontSize: 12.5, color: c.muted)),
                ]),
                uiCard(context, [
                  uiSection(context, 'Settings'),
                  Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        uiField(context, 'Scale'),
                        UiSelect(
                          value: _scaleCtrl.text,
                          items: const {'2': '2x', '4': '4x'},
                          hint: '4x',
                          sheetTitle: 'Scale',
                          onChanged: (v) => setState(() => _scaleCtrl.text = v ?? '4'),
                        ),
                      ]),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        uiField(context, 'Seed'),
                        uiTextField(context, _seedCtrl, '0', number: true, decimal: false),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        uiField(context, 'Tile size'),
                        uiTextField(context, _tileCtrl, '512', number: true, decimal: false),
                      ]),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        uiField(context, 'Tile overlap'),
                        uiTextField(context, _overlapCtrl, '128', number: true, decimal: false),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  uiField(context, 'Color correction'),
                  UiSelect(
                    value: _color,
                    items: const {
                      'none': 'None (official default)',
                      'wavelet': 'Wavelet',
                      'lab': 'LAB (can produce black output)',
                      'adain': 'AdaIN',
                    },
                    hint: 'None (official default)',
                    sheetTitle: 'Color correction',
                    onChanged: (v) => setState(() => _color = v ?? 'none'),
                  ),
                  const SizedBox(height: 10),
                  uiField(context, 'Output folder (optional)'),
                  uiTextField(context, _outDirCtrl, 'ComfyUI output folder'),
                ]),
                uiCard(context, [
                  Row(children: [
                    Expanded(child: uiSection(context, _jobState, noPad: true)),
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
                  const SizedBox(height: 12),
                  UiPrimaryBtn(
                      'Upscale', (_busy || _missing().isNotEmpty) ? null : _start),
                ]),
                uiCard(context, [
                  uiSection(context, 'Models'),
                  Text('Free VRAM taken by diffusion models before loading a heavy model.',
                      style: TextStyle(fontSize: 12.5, color: c.muted)),
                  const SizedBox(height: 8),
                  UiGhostBtn(
                      _unloading ? 'UNLOADING…' : 'UNLOAD VRAM MODELS',
                      _unloading ? () {} : _unload),
                ]),
                if (_result != null)
                  uiCard(context, [
                    uiSection(context, 'Result'),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: UiRatioImage(
                        url: _api.viewUrl(
                            filename: _result!.filename,
                            subfolder: _result!.subfolder,
                            type: _result!.type),
                        fallbackHeight: 200,
                      ),
                    ),
                    if (_meta.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(_meta, style: fmono(11, c.ink3)),
                    ],
                    if (_savedLine.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(_savedLine, style: TextStyle(fontSize: 12.5, color: c.muted)),
                    ],
                    if (_blackWarn.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(_blackWarn, style: TextStyle(fontSize: 12.5, color: c.warn)),
                    ],
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(child: UiGhostBtn('SAVE', _save)),
                    ]),
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
}
