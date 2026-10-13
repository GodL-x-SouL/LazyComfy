import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Backend error surfaced as an exception message.
class ApiException implements Exception {
  final String message;
  final int? status;
  const ApiException(this.message, [this.status]);
  @override
  String toString() => message;
}

/// Thin client for the LazyComfy JSON API + ComfyUI core endpoints.
///
/// `endpoint` is the normalized base (https://host/lazycomfy, no trailing
/// slash). Same-origin rules as the web app: /lazycomfy/api/* lives under
/// the endpoint, while /view and /ws live at the tunnel root.
class LazyApi {
  final String endpoint;
  final http.Client _http;

  LazyApi(this.endpoint, [http.Client? client]) : _http = client ?? http.Client();

  void close() => _http.close();

  Uri _api(String path, [Map<String, String>? query]) {
    final base = Uri.parse(endpoint);
    return base.replace(
      path: '${base.path}/api/$path',
      queryParameters: query,
    );
  }

  /// Tunnel root (scheme + host), for ComfyUI core paths (/view, /ws).
  Uri get _root {
    final base = Uri.parse(endpoint);
    return Uri(scheme: base.scheme, host: base.host, port: base.hasPort ? base.port : null);
  }

  /// Image bytes (or thumb) for a /view-style file reference.
  String viewUrl({required String filename, String subfolder = '', String type = 'output'}) {
    return _root.replace(path: '/view', queryParameters: {
      'filename': filename,
      if (subfolder.isNotEmpty) 'subfolder': subfolder,
      'type': type,
    }).toString();
  }

  /// Downscaled JPEG preview (server-side, memory-only, s = 64..512).
  String thumbUrl({required String filename, String subfolder = '', String type = 'output', int size = 256}) {
    final base = Uri.parse(endpoint);
    return base.replace(path: '${base.path}/api/thumb', queryParameters: {
      'filename': filename,
      if (subfolder.isNotEmpty) 'subfolder': subfolder,
      'type': type,
      's': '$size',
    }).toString();
  }

  /// ComfyUI progress socket (/ws?clientId=), same as the web app's WsHub.
  /// Emits decoded {type, data} maps; caller filters by prompt_id.
  Stream<Map<String, dynamic>> comfyWs(String clientId) {
    final root = _root;
    final uri = Uri(
      scheme: root.scheme == 'https' ? 'wss' : 'ws',
      host: root.host,
      port: root.hasPort ? root.port : null,
      path: '/ws',
      queryParameters: {'clientId': clientId},
    );
    final ch = WebSocketChannel.connect(uri);
    return ch.stream.where((m) => m != null).map((m) {
      try {
        final d = json.decode(m as String);
        if (d is Map<String, dynamic>) return d;
      } catch (_) {}
      return const <String, dynamic>{};
    });
  }

  Future<Map<String, dynamic>> _get(String path, [Map<String, String>? query]) async {
    http.Response res;
    try {
      res = await _http
          .get(_api(path, query), headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw const ApiException('The connection timed out. Confirm ComfyUI and the tunnel are running.');
    } catch (e) {
      throw ApiException('Could not reach the backend ($e). Confirm the URL, ComfyUI, and tunnel.');
    }
    return _decode(res, path);
  }

  Future<dynamic> _post(String path, Object? body) async {
    http.Response res;
    try {
      res = await _http
          .post(_api(path),
              headers: const {'Content-Type': 'application/json', 'Accept': 'application/json'},
              body: json.encode(body ?? {}))
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw const ApiException('The connection timed out. Confirm ComfyUI and the tunnel are running.');
    } catch (e) {
      throw ApiException('Could not reach the backend ($e). Confirm the URL, ComfyUI, and tunnel.');
    }
    return _decode(res, path);
  }

  dynamic _decode(http.Response res, String path) {
    dynamic data;
    try {
      data = json.decode(res.body);
    } catch (_) {
      data = null;
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(_errMessage(data) ?? 'The server answered with HTTP ${res.statusCode}.', res.statusCode);
    }
    // The server answering an API path with the app shell (HTML) instead of
    // JSON means the request never reached the JSON route: stale backend,
    // duplicate custom-node copies, or a middlebox answering for it. Say so
    // directly instead of a generic parse failure.
    final contentType = res.headers['content-type'] ?? '';
    final trimmed = res.body.trimLeft().toLowerCase();
    if (contentType.contains('text/html') || trimmed.startsWith('<!doctype') || trimmed.startsWith('<html')) {
      throw ApiException(
          'GET /lazycomfy/api/$path returned the app page instead of JSON. '
          'Pull the latest LazyComfy on the server and restart ComfyUI.');
    }
    // A 200 with an empty/non-JSON body must fail loudly here. Returning
    // null lets callers crash on data['x'] with a shapeless TypeError that
    // surfaces as a useless "sync failed" three layers up.
    if (data is! Map<String, dynamic>) {
      throw ApiException(
          'Bad response from the server (HTTP ${res.statusCode}, ${_preview(res.body)}).', res.statusCode);
    }
    if (data['error'] != null) {
      // Backend error envelope (string or {message}).
      throw ApiException(_errMessage(data['error']) ?? 'Request failed.', res.statusCode);
    }
    return data;
  }

  String _preview(String body) {
    final s = body.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (s.isEmpty) return 'empty body';
    return s.length > 80 ? '${s.substring(0, 80)}…' : s;
  }

  String? _errMessage(dynamic err) {
    if (err == null) return null;
    if (err is String) return err;
    if (err is Map) {
      final m = err['message'] ?? err['error'];
      if (m is String && m.isNotEmpty) return m;
    }
    return null;
  }

  Future<Map<String, dynamic>> config() async => Map<String, dynamic>.from(await _get('config'));
  Future<List<dynamic>> models() async => List<dynamic>.from((await _get('models'))['models'] ?? []);
  Future<Map<String, dynamic>> fileDirs() async =>
      Map<String, dynamic>.from((await _get('files'))['dirs'] ?? {});
  Future<List<String>> folders() async {
    final d = await _get('folders');
    final f = d['folders'];
    if (f is List && f.isNotEmpty) return f.map((e) => '$e').toList();
    return const ['loras'];
  }

  Future<Map<String, dynamic>> catalog() async =>
      Map<String, dynamic>.from(await _get('catalog'));
  Future<void> startDownload(String itemId, String downloader) async {
    await _post('download', {'item_id': itemId, 'downloader': downloader});
  }

  Future<void> cancelDownload(String taskId) async {
    await _post('download/cancel/$taskId', {});
  }

  Future<void> startLoraDownload(String url, String downloader) async {
    await _post('lora/download', {'url': url, 'downloader': downloader});
  }

  Future<void> startGenericDownload(String url, String targetDir, String downloader) async {
    await _post('generic/download', {'url': url, 'target_dir': targetDir, 'downloader': downloader});
  }

  Future<Map<String, dynamic>> videoConfig() async =>
      Map<String, dynamic>.from(await _get('video/config'));
  Future<String> videoGenerate(Map<String, dynamic> body) async {
    final d = await _post('video/generate', body);
    final id = d['prompt_id'];
    if (id is! String || id.isEmpty) throw const ApiException('Queue failed: no prompt id.');
    return id;
  }

  Future<Map<String, dynamic>> videoResult(String promptId) async =>
      Map<String, dynamic>.from(await _get('video/result/$promptId'));
  Future<List<dynamic>> videoHistory([int limit = 10]) async =>
      List<dynamic>.from((await _get('video/history', {'limit': '$limit'}))['jobs'] ?? []);
  Future<int> videoQueue() async {
    final d = await _get('video/queue');
    final n = d['queue_remaining'];
    return n is int ? n : 0;
  }

  Future<void> videoCancel(String promptId) async {
    await _post('video/cancel/$promptId', {});
  }

  Future<void> unloadModels(String scope) async {
    await _post('upscale/unload', {'scope': scope});
  }

  Future<Map<String, dynamic>> upscaleConfig() async =>
      Map<String, dynamic>.from(await _get('upscale/config'));
  Future<Map<String, dynamic>> upscaleImages(String dir) async =>
      Map<String, dynamic>.from(await _get('upscale/images', {'dir': dir}));
  String upscalePreviewUrl(String path) {
    final base = Uri.parse(endpoint);
    return base.replace(
        path: '${base.path}/api/upscale/preview',
        queryParameters: {'path': path}).toString();
  }

  Future<String> upscaleGenerate(Map<String, dynamic> body) async {
    final d = await _post('upscale/generate', body);
    final id = d['prompt_id'];
    if (id is! String || id.isEmpty) throw const ApiException('Queue failed: no prompt id.');
    return id;
  }

  Future<Map<String, dynamic>> upscaleResult(String promptId) async =>
      Map<String, dynamic>.from(await _get('upscale/result/$promptId'));

  // ---- Custom workflows: ComfyUI core endpoints (tunnel root) ----

  Uri _core(String path, [Map<String, String>? query]) {
    return _root.replace(path: path.startsWith('/') ? path : '/$path', queryParameters: query);
  }

  Future<dynamic> _coreGet(String path, [Map<String, String>? query]) async {
    http.Response res;
    try {
      res = await _http
          .get(_core(path, query), headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw const ApiException('The connection timed out.');
    } catch (e) {
      throw ApiException('Could not reach the backend ($e).');
    }
    dynamic data;
    try {
      data = json.decode(res.body);
    } catch (_) {
      data = null;
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(_errMessage(data) ?? 'HTTP ${res.statusCode}.', res.statusCode);
    }
    return data;
  }

  Future<dynamic> _corePost(String path, Object? body) async {
    http.Response res;
    try {
      res = await _http
          .post(_core(path),
              headers: const {'Content-Type': 'application/json', 'Accept': 'application/json'},
              body: json.encode(body ?? {}))
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw const ApiException('The connection timed out.');
    } catch (e) {
      throw ApiException('Could not reach the backend ($e).');
    }
    dynamic data;
    try {
      data = json.decode(res.body);
    } catch (_) {
      data = null;
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(_errMessage(data) ?? 'HTTP ${res.statusCode}.', res.statusCode);
    }
    if (data is Map && data['error'] != null) {
      throw ApiException(_errMessage(data['error']) ?? 'Request failed.');
    }
    return data;
  }

  Future<Map<String, dynamic>> objectInfo() async {
    final d = await _coreGet('/object_info');
    return (d is Map) ? Map<String, dynamic>.from(d) : const {};
  }

  Future<String> submitPrompt(
      Map<String, dynamic> prompt, String clientId, Map<String, dynamic>? extraData) async {
    final d = await _corePost(
        '/prompt', {'prompt': prompt, 'client_id': clientId, 'extra_data': extraData ?? {}});
    final id = (d is Map) ? d['prompt_id'] : null;
    if (id is! String || id.isEmpty) throw const ApiException('Queue failed: no prompt id.');
    return id;
  }

  Future<Map<String, dynamic>?> promptHistory(String promptId) async {
    final d = await _coreGet('/history/$promptId');
    if (d is Map && d[promptId] is Map) {
      return Map<String, dynamic>.from(d[promptId] as Map);
    }
    return null;
  }

  Future<void> interrupt() async {
    await _corePost('/interrupt', {});
  }

  Future<Map<String, dynamic>> systemStats() async {
    final d = await _coreGet('/system_stats');
    return (d is Map) ? Map<String, dynamic>.from(d) : const {};
  }

  Future<void> freeMemory() async {
    await _corePost('/free', {'unload_models': true, 'free_memory': true});
  }

  Future<void> restartComfy() async {
    await _post('restart', {'confirm': true});
  }

  Future<List<dynamic>> userWorkflows() async {
    try {
      final d = await _coreGet('/api/v2/userdata', {'path': 'workflows'});
      if (d is List) return List<dynamic>.from(d);
      if (d is Map && d['files'] is List) return List<dynamic>.from(d['files']);
    } catch (_) {}
    return const [];
  }

  Future<dynamic> userWorkflowGet(String rel) async =>
      await _coreGet('/api/userdata/workflows/$rel', {'t': '${DateTime.now().millisecondsSinceEpoch}'});

  Future<void> userWorkflowSave(String rel, Object obj, bool overwrite) async {
    final uri = _core('/api/userdata/workflows/$rel',
        {'overwrite': overwrite ? 'true' : 'false'});
    final res = await _http
        .post(uri,
            headers: const {'Content-Type': 'application/json'},
            body: json.encode(obj))
        .timeout(const Duration(seconds: 30));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException('Save failed (HTTP ${res.statusCode}).');
    }
  }

  Future<void> userWorkflowDelete(String rel) async {
    final res = await _http
        .delete(_core('/api/userdata/workflows/$rel'))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException('Delete failed (HTTP ${res.statusCode}).');
    }
  }

  Future<Map<String, dynamic>> workflowTemplates() async {
    final d = await _coreGet('/api/workflow_templates');
    return (d is Map) ? Map<String, dynamic>.from(d) : const {};
  }

  Future<dynamic> workflowTemplate(String mod, String name) async {
    final n = name.endsWith('.json') ? name : '$name.json';
    return await _coreGet('/api/workflow_templates/$mod/$n');
  }

  Future<Map<String, dynamic>> llmConfig() async =>
      Map<String, dynamic>.from(await _get('llm/config'));
  Future<Map<String, dynamic>> llmStatus() async {
    try {
      return Map<String, dynamic>.from(await _get('llm/status'));
    } catch (_) {
      return const {};
    }
  }

  Future<void> llmLoad(String model, String mmproj, int contextLength) async {
    await _post('llm/load', {'model': model, 'mmproj': mmproj, 'context_length': contextLength});
  }

  Future<void> llmUnload() async {
    await _post('llm/unload', {});
  }

  Future<void> llmInstall() async {
    await _post('llm/install', {});
  }

  Future<Map<String, dynamic>> llmSearch(String query) async =>
      Map<String, dynamic>.from(await _post('llm/search', {'query': query}));
  Future<dynamic> llmFiles(String repoId) async =>
      await _post('llm/files', {'repo_id': repoId});
  Future<void> llmDownload(String url, String name) async {
    await _post('llm/download', {'url': url, 'name': name});
  }

  Future<void> llmCancelDownload(String taskId) async {
    await _post('llm/download/cancel/$taskId', {});
  }

  /// SSE text stream for prompt-forge generation. Calls onEvent for each
  /// decoded {type, ...} frame (chunk/done/error). Throws ApiException on
  /// HTTP or envelope errors.
  Future<void> llmGenerate(
    Map<String, dynamic> body,
    void Function(Map<String, dynamic>) onEvent,
  ) async {
    final base = Uri.parse(endpoint);
    final uri = base.replace(path: '${base.path}/api/llm/generate');
    final req = http.Request('POST', uri)
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'text/event-stream'
      ..body = json.encode(body);
    http.StreamedResponse res;
    try {
      res = await _http.send(req).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw const ApiException('The connection timed out.');
    } catch (e) {
      throw ApiException('Could not reach the backend ($e).');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final text = await res.stream.bytesToString();
      dynamic data;
      try {
        data = json.decode(text);
      } catch (_) {}
      final msg = (data is Map)
          ? ((data['error'] is Map ? data['error']['message'] : data['error']) ?? 'HTTP ${res.statusCode}')
          : 'HTTP ${res.statusCode}';
      throw ApiException('$msg');
    }
    var buf = '';
    await for (final chunk in res.stream.transform(const Utf8Decoder(allowMalformed: true))) {
      buf += chunk;
      var idx = buf.indexOf('\n\n');
      while (idx >= 0) {
        final ev = buf.substring(0, idx);
        buf = buf.substring(idx + 2);
        for (final line in ev.split('\n')) {
          final t = line.trim();
          if (!t.startsWith('data:')) continue;
          final payload = t.substring(5).trim();
          if (payload.isEmpty) continue;
          try {
            final d = json.decode(payload);
            if (d is Map<String, dynamic>) onEvent(d);
          } catch (_) {}
        }
        idx = buf.indexOf('\n\n');
      }
    }
  }
  Future<List<dynamic>> history([int limit = 12]) async =>
      List<dynamic>.from((await _get('history', {'limit': '$limit'}))['jobs'] ?? []);
  Future<Map<String, dynamic>> result(String promptId) async =>
      Map<String, dynamic>.from(await _get('result/$promptId'));
  Future<int> queueRemaining() async {
    final d = await _get('queue');
    final n = d['queue_remaining'];
    return n is int ? n : 0;
  }

  Future<String> generate(Map<String, dynamic> body) async {
    final d = await _post('generate', body);
    final id = d['prompt_id'];
    if (id is! String || id.isEmpty) throw const ApiException('Queue failed: no prompt id.');
    return id;
  }

  Future<void> cancel(String promptId) async {
    await _post('cancel/$promptId', {});
  }

  Future<void> deleteMedia({required String filename, String subfolder = '', String type = 'output'}) async {
    await _post('delete', {'filename': filename, 'subfolder': subfolder, 'type': type});
  }

  /// Upload raw bytes as a ComfyUI input image (goes to input/lazycomfy).
  /// Returns (name, subfolder) for the generate `image` param. The part
  /// carries a real image MIME (the server validates content, not the
  /// extension — octet-stream gets rejected even for a real .png).
  Future<Map<String, String>> uploadImage(List<int> bytes, String filename) async {
    final base = Uri.parse(endpoint);
    final uri = base.replace(path: '${base.path}/api/upload');
    final ext = filename.split('.').last.toLowerCase();
    final mime = switch (ext) {
      'png' => MediaType('image', 'png'),
      'jpg' || 'jpeg' => MediaType('image', 'jpeg'),
      'webp' => MediaType('image', 'webp'),
      _ => MediaType('image', 'png'),
    };
    final req = http.MultipartRequest('POST', uri)
      ..files.add(http.MultipartFile.fromBytes('image', bytes,
          filename: filename, contentType: mime));
    http.StreamedResponse res;
    try {
      res = await _http.send(req).timeout(const Duration(minutes: 2));
    } on TimeoutException {
      throw const ApiException('Upload timed out. Check the connection and retry.');
    } catch (_) {
      throw const ApiException('Upload failed. Check the connection and retry.');
    }
    final body = await res.stream.bytesToString();
    dynamic data;
    try {
      data = json.decode(body);
    } catch (_) {
      data = null;
    }
    if (res.statusCode < 200 || res.statusCode >= 300 || (data is Map && data['error'] != null)) {
      throw ApiException(_errMessage(data is Map ? data['error'] : null) ?? 'Upload failed (HTTP ${res.statusCode}).');
    }
    if (data is! Map || data['name'] == null) throw const ApiException('Upload failed: bad response.');
    return {
      'name': '${data['name']}',
      'subfolder': '${data['subfolder'] ?? 'lazycomfy'}',
    };
  }

  Future<List<dynamic>> inputImages() async {
    final d = await _get('input/images');
    final imgs = d['images'];
    if (imgs is List) return List<dynamic>.from(imgs);
    return const [];
  }
}

/// Stable per-install client id for the ComfyUI progress socket.
/// Mirrors the web app's localStorage id (lazycomfy- + 8 chars).
Future<String> getClientId() async {
  const key = 'lazycomfy.clientId.v1';
  final p = await SharedPreferences.getInstance();
  var id = p.getString(key);
  if (id == null || id.isEmpty) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    id = 'lazycomfy-${List.generate(8, (_) => chars[r.nextInt(chars.length)]).join()}';
    await p.setString(key, id);
  }
  return id;
}
