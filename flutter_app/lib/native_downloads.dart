import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'ui_kit.dart';
import 'edge_frost.dart';
import 'lazy_theme.dart';

/// Native port of the web download modal: catalog model files with progress,
/// custom file URL → any folder, custom LoRA URL → loras.
///
/// Polls the catalog every second while open; when the last active task
/// settles, [onChanged] fires so the caller refreshes its file lists
/// (same contract as the web modal).
class NativeDownloadsPage extends StatefulWidget {
  final String endpoint;
  final VoidCallback onChanged;
  const NativeDownloadsPage({super.key, required this.endpoint, required this.onChanged});

  @override
  State<NativeDownloadsPage> createState() => _NativeDownloadsPageState();
}

class _NativeDownloadsPageState extends State<NativeDownloadsPage> {
  late final LazyApi _api;
  Map<String, dynamic>? _catalog;
  final Map<String, String> _modelNames = {};
  List<String> _folders = const ['loras'];
  String _folder = 'loras';
  String _downloader = 'huggingface';
  final TextEditingController _urlCtrl = TextEditingController();
  final TextEditingController _loraCtrl = TextEditingController();
  Timer? _timer;
  bool _wasBusy = false;
  // Optimistic entries so tap feedback (✕ + bar) is instant even before
  // the 1s poll returns server truth. Keyed by item_id; dropped as soon as
  // a server task with the same id shows up.
  final Map<String, Map<String, dynamic>> _local = {};

  static const _busy = {'starting', 'downloading', 'cancelling'};

  @override
  void initState() {
    super.initState();
    _api = LazyApi(widget.endpoint);
    _loadDl();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _api.close();
    _urlCtrl.dispose();
    _loraCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadDl() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _downloader = p.getString('lazycomfy.downloader') ?? 'huggingface');
  }

  Future<void> _setDl(String v) async {
    setState(() => _downloader = v);
    final p = await SharedPreferences.getInstance();
    await p.setString('lazycomfy.downloader', v);
  }

  Future<void> _refresh() async {
    try {
      final c = await _api.catalog();
      if (!mounted) return;
      setState(() => _catalog = c);
    } catch (_) {}
    try {
      final f = await _api.folders();
      if (!mounted) return;
      setState(() {
        _folders = f;
        if (!_folders.contains(_folder)) _folder = 'loras';
      });
    } catch (_) {}
    try {
      final ms = await _api.models();
      if (!mounted) return;
      setState(() {
        for (final m in ms) {
          if (m is Map) _modelNames['${m['id']}'] = '${m['name'] ?? m['id']}';
        }
      });
    } catch (_) {}
  }

  Future<void> _poll() async {
    Map<String, dynamic>? c;
    try {
      c = await _api.catalog();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final tasks = (c['tasks'] is List) ? List<dynamic>.from(c['tasks']) : const [];
    final isBusy = tasks.any((t) => t is Map && _busy.contains(t['status']));
    final seen = <String>{};
    for (final t in tasks) {
      if (t is Map) seen.add('${t['item_id']}');
    }
    setState(() {
      _catalog = c;
      _local.removeWhere((k, _) => seen.contains(k));
    });
    if (_wasBusy && !isBusy) widget.onChanged();
    _wasBusy = isBusy;
  }

  Map<String, dynamic>? _findItem(String itemId) {
    final items = (_catalog?['items'] is List) ? List<dynamic>.from(_catalog!['items']) : const [];
    for (final it in items) {
      if (it is Map && '${it['id']}' == itemId) return Map<String, dynamic>.from(it);
    }
    return null;
  }

  Future<void> _start(String itemId) async {
    final it = _findItem(itemId);
    setState(() => _local[itemId] = {
          'id': 'local',
          'item_id': itemId,
          'target_name': '${it?['target_name'] ?? itemId}',
          'status': 'starting',
          'downloaded': 0,
          'total': 0,
          'downloader': _downloader,
        });
    try {
      await _api.startDownload(itemId, _downloader);
      _refresh();
      _poll();
    } catch (e) {
      if (mounted) setState(() => _local.remove(itemId));
      _snack(e is ApiException ? e.message : 'Download failed.');
    }
  }

  Future<void> _customFile() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    try {
      await _api.startGenericDownload(url, _folder, _downloader);
      _urlCtrl.clear();
      _snack('Download to $_folder started.', ok: true);
      _refresh();
      _poll();
    } catch (e) {
      _snack(e is ApiException ? e.message : 'Download failed.');
    }
  }

  Future<void> _customLora() async {
    final url = _loraCtrl.text.trim();
    if (url.isEmpty) return;
    try {
      await _api.startLoraDownload(url, _downloader);
      _loraCtrl.clear();
      _snack('LoRA download started.', ok: true);
      _refresh();
      _poll();
    } catch (e) {
      _snack(e is ApiException ? e.message : 'Download failed.');
    }
  }

  void _snack(String msg, {bool ok = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: ok ? const Color(0xFF14532D) : null,
    ));
  }

  String _size(dynamic bytes) {
    if (bytes is! num || bytes <= 0) return '';
    return ' · ${(bytes / 1073741824).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.lazy;
    final mq = MediaQuery.paddingOf(context);
    final items = (_catalog?['items'] is List) ? List<dynamic>.from(_catalog!['items']) : const [];
    final tasks = (_catalog?['tasks'] is List) ? List<dynamic>.from(_catalog!['tasks']) : const [];
    final customTasks = tasks
        .where((t) => t is Map && '${t['item_id'] ?? ''}'.startsWith('custom:'))
        .toList()
      ..sort((a, b) => ((b as Map)['created_at'] ?? 0).compareTo((a as Map)['created_at'] ?? 0));
    final byModel = <String, List<dynamic>>{};
    for (final it in items) {
      if (it is! Map) continue;
      byModel.putIfAbsent('${it['model_id']}', () => []).add(it);
    }
    const pinned = ['qwen_image_2_1_turbo', 'z_image_turbo'];
    final ordered = byModel.keys.toList()
      ..sort((a, b) {
        final pa = pinned.indexOf(a);
        final pb = pinned.indexOf(b);
        if (pa >= 0 || pb >= 0) return (pa < 0 ? 99 : pa) - (pb < 0 ? 99 : pb);
        return a.compareTo(b);
      });

    String prettyModel(String mid) {
      if (_modelNames.containsKey(mid)) return _modelNames[mid]!;
      return mid.replaceAll('_', ' ').split(' ').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');
    }

    Map<String, dynamic>? taskFor(String itemId) {
      for (final t in tasks) {
        if (t is Map && t['item_id'] == itemId) return Map<String, dynamic>.from(t);
      }
      final local = _local[itemId];
      if (local != null) return Map<String, dynamic>.from(local);
      return null;
    }
    return Scaffold(
      backgroundColor: c.bg,
      // Sticky shell like the site: fixed 40px header block, full-bleed
      // list below it, frost floating between so scrolled rows melt under.
      body: Stack(
        children: [
          ListView(
            padding: EdgeInsets.fromLTRB(16, mq.top + 40 + 12, 16, mq.bottom + 24),
            children: [
              uiCard(context, [
                uiField(context, 'Custom file URL → any folder'),
                Row(children: [
                  Expanded(child: uiTextField(context, _urlCtrl, 'https://…/file.safetensors')),
                  const SizedBox(width: 8),
                  _miniSelect(_folder, _folders, (v) => setState(() => _folder = v ?? 'loras')),
                ]),
                const SizedBox(height: 8),
                UiGhostBtn('Download file', _customFile),
              ]),
              uiCard(context, [
                uiField(context, 'Custom LoRA URL (→ loras)'),
                Row(children: [
                  Expanded(child: uiTextField(context, _loraCtrl, 'https://…')),
                  const SizedBox(width: 8),
                  UiGhostBtn('Download', _customLora),
                ]),
              ]),
              if (customTasks.isNotEmpty)
                uiCard(context, [
                  uiSection(context, 'Custom downloads'),
                  for (final t in customTasks) _taskRow(t as Map),
                ]),
              for (final mid in ordered)
                uiCard(context, [
                  uiSection(context, 
                      '${prettyModel(mid)} · ${byModel[mid]!.where((g) => (g as Map)['present'] == true).length}/${byModel[mid]!.length} installed'),
                  for (final it in byModel[mid]!) _itemRow(it as Map, taskFor('${it['id']}')),
                ]),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: EdgeFrost(top: true, inset: mq.top + 40, fade: 32),
          ),
          Positioned(
            top: mq.top,
            left: 16,
            right: 16,
            child: SizedBox(
              height: 40,
              child: Row(children: [
                UiIconCircle(Icons.arrow_back_rounded, 'Back', () => Navigator.pop(context)),
                const SizedBox(width: 10),
                Text('Model downloads', style: disp(16, FontWeight.w700, c.ink)),
                const Spacer(),
                UiSeg(options: const ['huggingface', 'aria2c'], value: _downloader, labels: const {'huggingface': 'HF Hub', 'aria2c': 'aria2c'}, onChanged: _setDl, compact: true),
              ]),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: EdgeFrost(top: false, inset: mq.bottom, fade: 48),
          ),
        ],
      ),
    );
  }
  Widget _itemRow(Map it, Map? task) {
    final c = context.lazy;
    // Installed means on disk — independent of any (possibly finished)
    // task row. GET only when missing AND idle. Progress while active.
    final present = it['present'] == true;
    final active = task != null && _busy.contains(task['status']);
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
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${it['label'] ?? it['id']}',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.ink)),
              const SizedBox(height: 2),
              Text('${it['target_name'] ?? ''}${_size(it['size'])}',
                  style: fmono(10.5, c.muted2)),
              if ('${it['note'] ?? ''}'.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text('${it['note']}', style: TextStyle(fontSize: 12.5, color: c.muted)),
              ],
            ]),
          ),
          const SizedBox(width: 8),
          if (present)
            Text('INSTALLED ✓', style: fmono(10, c.ok, ls: 0.06)),
          if (!present && !active)
            _dlCircle(busy: false, onTap: () => _start('${it['id']}')),
          if (!present && active)
            _dlCircle(busy: true, onTap: () async {
              try {
                await _api.cancelDownload('${task['id']}');
              } catch (_) {}
            }),
        ]),
        if (active) ...[
          const SizedBox(height: 8),
          _taskProgress(task),
        ],
      ]),
    );
  }

  /// Download/cancel circle chip: download arrow idle, ✕ while active.
  Widget _dlCircle({required bool busy, required VoidCallback onTap, double size = 40}) {
    final c = context.lazy;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: busy ? c.err : c.border),
        ),
        child: Icon(
          busy ? Icons.close_rounded : Icons.download_rounded,
          size: size * 0.45,
          color: busy ? c.err : c.ink2,
        ),
      ),
    );
  }

  Widget _taskRow(Map task) {
    final total = (task['total'] is num) ? (task['total'] as num).toDouble() : 0.0;
    final got = (task['downloaded'] is num) ? (task['downloaded'] as num).toDouble() : 0.0;
    final pct = total > 0 ? (got / total * 100).round() : 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: context.lazy.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${task['target_name'] ?? task['item_id'] ?? 'download'}',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.lazy.ink)),
        const SizedBox(height: 6),
        _taskProgress(task),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('${_mb(got)} / ${_mb(total)} · $pct% · ${task['downloader'] == 'aria2c' ? 'aria2c' : 'HF'} · ${task['status'] ?? ''}',
              style: fmono(10.5, Colors.grey)),
        ),
      ]),
    );
  }

  Widget _taskProgress(Map task) {
    final c = context.lazy;
    final total = (task['total'] is num) ? (task['total'] as num).toDouble() : 0.0;
    final got = (task['downloaded'] is num) ? (task['downloaded'] as num).toDouble() : 0.0;
    final v = total > 0 ? (got / total).clamp(0.0, 1.0) : null;
    // Single cancel affordance lives in the circle chip beside the title;
    // the bar below is full-width with no second ✕.
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: LinearProgressIndicator(
        value: v,
        minHeight: 4,
        valueColor: AlwaysStoppedAnimation<Color>(c.accent),
        backgroundColor: c.accentSoft,
      ),
    );
  }

  String _mb(double bytes) {
    if (bytes <= 0) return '0 MB';
    return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  }

  Widget _miniSelect(String value, List<String> options, ValueChanged<String?> onChanged) {
    final c = context.lazy;
    return GestureDetector(
      onTap: () {
        showModalBottomSheet(
          context: context,
          backgroundColor: c.bgCard,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          builder: (_) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 16),
              children: [
                for (final o in options)
                  GestureDetector(
                    onTap: () {
                      Navigator.pop(context);
                      onChanged(o);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: o == value ? c.accentSoft : Colors.transparent,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Text(o,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: o == value ? FontWeight.w600 : FontWeight.w400,
                            color: o == value ? c.ink : c.ink2,
                          )),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: c.accentTint,
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(value, style: TextStyle(fontSize: 12, color: c.ink)),
          const SizedBox(width: 4),
          Icon(Icons.expand_more_rounded, size: 16, color: c.muted2),
        ]),
      ),
    );
  }
}
