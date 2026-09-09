import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'lazy_theme.dart';

const _endpointKey = 'mobilecomfy.backend_url.v1';
const _themeKey = 'lazycomfy.theme';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Android edge-to-edge: status + gesture areas are transparent. All inset
  // handling lives in Flutter widgets (SafeArea around the WebView), so it
  // applies to every /lazycomfy page with zero per-page patching.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const MobileComfyApp());
}

String normalizeBackendUrl(String value) {
  var raw = value.trim();
  if (raw.isEmpty) {
    throw const BackendUrlException('Enter a ComfyUI backend URL to continue.');
  }
  if (!raw.contains('://')) raw = 'http://$raw';
  Uri uri;
  try {
    uri = Uri.parse(raw);
  } catch (_) {
    throw const BackendUrlException('That does not look like a valid URL.');
  }
  if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
    throw const BackendUrlException(
      'Use an HTTP or HTTPS URL, for example https://your-tunnel.example.com.',
    );
  }
  if (uri.userInfo.isNotEmpty) {
    throw const BackendUrlException('URLs with embedded usernames or passwords are not supported.');
  }
  var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  final lowerPath = path.toLowerCase();
  if (!lowerPath.endsWith('/lazycomfy')) {
    path = path.isEmpty ? '/lazycomfy' : '$path/lazycomfy';
  } else {
    path = '${path.substring(0, path.length - '/lazycomfy'.length)}/lazycomfy';
  }
  return Uri(
    scheme: uri.scheme,
    userInfo: uri.userInfo,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: path,
  ).toString();
}

class BackendUrlException implements Exception {
  final String message;
  const BackendUrlException(this.message);
  @override
  String toString() => message;
}

Future<void> probeBackend(String endpoint) async {
  final uri = Uri.parse('$endpoint/api/config');
  try {
    final response = await http.get(uri).timeout(const Duration(seconds: 8));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BackendUrlException('The server answered with HTTP ${response.statusCode}. Check that this is the ComfyUI tunnel URL.');
    }
  } on BackendUrlException {
    rethrow;
  } on TimeoutException {
    throw const BackendUrlException('The connection timed out. Confirm ComfyUI and the tunnel are running.');
  } catch (_) {
    throw const BackendUrlException('Could not reach the backend. Confirm the URL, ComfyUI, and tunnel.');
  }
}

// ── App ──

/// Parses a theme message posted by the WebView (`ThemeMode` JS channel).
/// Anything that is not exactly "dark" falls back to light.
ThemeMode parseThemeModeMessage(String message) =>
    message.trim().toLowerCase() == 'dark' ? ThemeMode.dark : ThemeMode.light;

class MobileComfyApp extends StatefulWidget {
  const MobileComfyApp({super.key});
  @override
  State<MobileComfyApp> createState() => _MobileComfyAppState();
}

class _MobileComfyAppState extends State<MobileComfyApp> {
  ThemeMode _mode = ThemeMode.light;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_themeKey);
    if (!mounted) return;
    setState(() => _mode = raw == 'dark' ? ThemeMode.dark : ThemeMode.light);
  }

  Future<void> _toggleTheme() async {
    await _setTheme(_mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);
  }

  /// Single entry point for every theme change (gate button or WebView page):
  /// rebuilds — so the root AnnotatedRegion flips the status bar icons —
  /// and persists the choice.
  Future<void> _setTheme(ThemeMode next) async {
    if (next == _mode) return;
    setState(() => _mode = next);
    final p = await SharedPreferences.getInstance();
    await p.setString(_themeKey, next == ThemeMode.dark ? 'dark' : 'light');
  }

  @override
  Widget build(BuildContext context) {
    final isDark = _mode == ThemeMode.dark;
    return MaterialApp(
      title: 'MobileComfy',
      debugShowCheckedModeBanner: false,
      theme: buildLazyTheme(LazyColors.light, Brightness.light),
      darkTheme: buildLazyTheme(LazyColors.dark, Brightness.dark),
      themeMode: _mode,
      // Declarative overlay follows the *app* theme (not the system theme):
      // AnnotatedRegion is owned by the widget tree, so unlike an imperative
      // SystemChrome call it cannot be silently restored/overwritten by the
      // framework (edge-to-edge + WebView platform view on Android 15+).
      home: AnnotatedRegion<SystemUiOverlayStyle>(
        value: lazySystemOverlayStyle(isDark),
        child: AppRoot(
          themeMode: _mode,
          onToggleTheme: _toggleTheme,
          onThemeChanged: _setTheme,
        ),
      ),
    );
  }
}

class AppRoot extends StatefulWidget {
  final ThemeMode themeMode;
  final VoidCallback onToggleTheme;
  final ValueChanged<ThemeMode> onThemeChanged;
  const AppRoot({super.key, required this.themeMode, required this.onToggleTheme, required this.onThemeChanged});
  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  String? _endpoint;
  String _initialUrl = '';
  String? _error;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString(_endpointKey)?.trim() ?? '';
    if (saved.isEmpty) return;
    try {
      final normalized = normalizeBackendUrl(saved);
      await probeBackend(normalized);
      if (!mounted) return;
      setState(() {
        _endpoint = normalized;
        _initialUrl = normalized;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initialUrl = saved;
        _error = e is BackendUrlException ? e.message : 'Could not connect. Check the URL.';
      });
    }
  }

  Future<void> _connect(String entered) async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final normalized = normalizeBackendUrl(entered);
      await probeBackend(normalized);
      final p = await SharedPreferences.getInstance();
      await p.setString(_endpointKey, normalized);
      if (!mounted) return;
      setState(() {
        _endpoint = normalized;
        _initialUrl = normalized;
        _checking = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = e is BackendUrlException ? e.message : 'Could not connect. Check the URL.';
      });
    }
  }

  /// Back to the setup gate. `_initialUrl` already holds the last working
  /// URL, so the field stays prefilled.
  void _changeBackend() {
    setState(() {
      _endpoint = null;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ep = _endpoint;
    if (ep != null) {
      return BackendShell(
        key: ValueKey(ep),
        endpoint: ep,
        onChangeBackend: _changeBackend,
        themeMode: widget.themeMode,
        onToggleTheme: widget.onToggleTheme,
        onThemeChanged: widget.onThemeChanged,
      );
    }
    return BackendGate(
      initialUrl: _initialUrl,
      busy: _checking,
      error: _error,
      onConnect: _connect,
      themeMode: widget.themeMode,
      onToggleTheme: widget.onToggleTheme,
    );
  }
}

// ── Backend gate: URL field + Connect ──

class BackendGate extends StatefulWidget {
  final String initialUrl;
  final bool busy;
  final String? error;
  final ValueChanged<String> onConnect;
  final ThemeMode themeMode;
  final VoidCallback onToggleTheme;
  const BackendGate({
    super.key,
    required this.initialUrl,
    required this.busy,
    required this.error,
    required this.onConnect,
    required this.themeMode,
    required this.onToggleTheme,
  });
  @override
  State<BackendGate> createState() => _BackendGateState();
}

class _BackendGateState extends State<BackendGate> {
  late final TextEditingController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialUrl);
  }

  @override
  void didUpdateWidget(covariant BackendGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialUrl != widget.initialUrl && widget.initialUrl != _ctrl.text) {
      _ctrl.text = widget.initialUrl;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() => widget.onConnect(_ctrl.text);

  @override
  Widget build(BuildContext context) {
    final c = context.lazy;
    final isDark = context.isDark;
    return Scaffold(
      backgroundColor: c.bg,
      body: Stack(
        children: [
          // subtle radial accent like web body — light only; dark is pure #000000
          if (!isDark)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.9),
                    radius: 1.1,
                    colors: [c.accent.withValues(alpha: 0.10), Colors.transparent],
                    stops: const [0.0, 0.62],
                  ),
                ),
              ),
            ),
          // theme toggle — minimal, top-right only
          Positioned(
            top: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: _ThemeIconBtn(
                  isDark: isDark,
                  onPressed: widget.onToggleTheme,
                ),
              ),
            ),
          ),
          // center card
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 48, 20, 20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Container(
                  decoration: BoxDecoration(
                    color: c.bgCard,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: c.border),
                    boxShadow: [BoxShadow(color: c.shadow, blurRadius: 16, offset: const Offset(0, 4))],
                  ),
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'BACKEND URL',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.2,
                          color: c.accentDeep,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _ctrl,
                        enabled: !widget.busy,
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.go,
                        autocorrect: false,
                        enableSuggestions: false,
                        style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: c.ink),
                        onSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          hintText: 'https://your-tunnel.example.com',
                          hintStyle: TextStyle(color: c.muted3, fontSize: 12),
                          prefixIcon: Icon(Icons.link_rounded, size: 18, color: c.muted2),
                        ),
                      ),
                      if (widget.error != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: c.err.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: c.err.withValues(alpha: 0.35)),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.error_outline_rounded, size: 16, color: c.err),
                              const SizedBox(width: 8),
                              Expanded(child: Text(widget.error!, style: TextStyle(color: c.err, fontSize: 12, height: 1.35))),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      SizedBox(
                        height: 44,
                        child: FilledButton(
                          onPressed: widget.busy ? null : _submit,
                          style: FilledButton.styleFrom(
                            backgroundColor: c.accent,
                            foregroundColor: isDark ? const Color(0xFF171717) : Colors.white,
                            disabledBackgroundColor: c.bgSoft,
                            disabledForegroundColor: c.muted4,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                            textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, fontWeight: FontWeight.w600, letterSpacing: 1.2),
                          ),
                          child: widget.busy
                              ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: c.muted4))
                              : const Text('CONNECT'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThemeIconBtn extends StatelessWidget {
  final bool isDark;
  final VoidCallback onPressed;
  const _ThemeIconBtn({required this.isDark, required this.onPressed});
  @override
  Widget build(BuildContext context) {
    final c = context.lazy;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: c.bgCard,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.border),
        ),
        child: Icon(isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined, size: 15, color: c.muted2),
      ),
    );
  }
}

// ── WebView shell ──
//
// System insets (status bar, gesture pill, notches) are handled ONCE here
// with SafeArea: the WebView viewport itself excludes those zones, so no web
// element on ANY /lazycomfy page can ever sit underneath system UI — and no
// per-page JavaScript or CSS patching is needed, now or for future pages.
// Reaching Setup again is the Android system back button (PopScope below),
// which is page-agnostic by construction.

class BackendShell extends StatefulWidget {
  final String endpoint;
  final VoidCallback onChangeBackend;
  final ThemeMode themeMode;
  final VoidCallback onToggleTheme;
  final ValueChanged<ThemeMode> onThemeChanged;
  const BackendShell({super.key, required this.endpoint, required this.onChangeBackend, required this.themeMode, required this.onToggleTheme, required this.onThemeChanged});
  @override
  State<BackendShell> createState() => _BackendShellState();
}

class _BackendShellState extends State<BackendShell> {
  late final WebViewController _ctrl;
  bool _pageFinished = false;
  String? _error;

  /// One static override for every /lazycomfy page (no per-page logic):
  /// flattens the glass topbar to a solid card so the opaque status zone
  /// always matches it pixel-for-pixel, whatever scrolls underneath.
  static const _topbarFlattenCss =
      '.topbar{backdrop-filter:none !important;-webkit-backdrop-filter:none !important;background:var(--bg-card) !important;}';

  @override
  void initState() {
    super.initState();
    _ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel('ThemeMode', onMessageReceived: _onThemeMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) async {
            if (!mounted) return;
            setState(() => _pageFinished = true);
            await _syncTheme();
            await _flattenTopbar();
          },
          onWebResourceError: (e) {
            if (!mounted || _pageFinished) return;
            final isMain = (e as dynamic).isForMainFrame ?? true;
            if (!isMain) return;
            setState(() => _error = e.description);
          },
        ),
      );
    _initFilePicker();
  }

  @override
  void didUpdateWidget(covariant BackendShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.themeMode != widget.themeMode && _pageFinished) {
      _syncTheme();
    }
  }

  /// Web page toggled its theme (moon/sun button): adopt it so the native
  /// status bar icons flip live. Guarded — Flutter's own push back to the
  /// page uses raw JS (not applyTheme), so this cannot echo-loop.
  void _onThemeMessage(JavaScriptMessage message) {
    final mode = parseThemeModeMessage(message.message);
    if (mode != widget.themeMode) widget.onThemeChanged(mode);
  }

  Future<void> _syncTheme() async {
    final t = widget.themeMode == ThemeMode.dark ? 'dark' : 'light';
    try {
      await _ctrl.runJavaScript('try{localStorage.setItem("lazycomfy.theme","$t");document.documentElement.dataset.theme="$t"}catch(e){}');
    } catch (_) {}
  }

  Future<void> _flattenTopbar() async {
    try {
      await _ctrl.runJavaScript(
        "(function(){var s=document.getElementById('lcFlatTopbar');"
        "if(!s){s=document.createElement('style');s.id='lcFlatTopbar';document.head.appendChild(s);}"
        "s.textContent='$_topbarFlattenCss';})();",
      );
    } catch (_) {}
  }

  Future<void> _initFilePicker() async {
    if (!Platform.isAndroid || _ctrl.platform is! AndroidWebViewController) {
      await _ctrl.loadRequest(Uri.parse(widget.endpoint));
      return;
    }
    final ac = _ctrl.platform as AndroidWebViewController;
    await ac.setOnShowFileSelector((p) async {
      if (p.mode == FileSelectorMode.save) return [];
      final res = await FilePicker.platform.pickFiles(
        allowMultiple: p.mode == FileSelectorMode.openMultiple,
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
      );
      return res?.files.map((f) => f.path).whereType<String>().toList() ?? [];
    });
    await _ctrl.loadRequest(Uri.parse(widget.endpoint));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.themeMode == ThemeMode.dark;
    // NOTE: no SystemChrome call here — the root AnnotatedRegion in
    // MobileComfyApp owns the overlay style (see above). Imperative calls
    // during build get overwritten by the framework, which caused light
    // mode to keep light (invisible) status bar icons.
    final Widget web = _error == null
        ? WebViewWidget(controller: _ctrl)
        : _ErrorView(details: _error!, onRetry: () async => _ctrl.reload(), onChangeBackend: widget.onChangeBackend);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _ctrl.canGoBack()) {
          await _ctrl.goBack();
          return;
        }
        widget.onChangeBackend();
      },
      child: Scaffold(
        // Android 15+ enforces transparent system bars (statusBarColor /
        // navigationBarColor are ignored), so the zones show whatever is
        // behind them. Paint the Scaffold itself #171717 (dark) so the
        // SafeArea insets framing the WebView carry the topbar card color
        // on every page. Light stays white throughout.
        backgroundColor: isDark ? const Color(0xFF171717) : Colors.white,
        body: SafeArea(child: web),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String details;
  final VoidCallback onRetry;
  final VoidCallback onChangeBackend;
  const _ErrorView({required this.details, required this.onRetry, required this.onChangeBackend});
  @override
  Widget build(BuildContext context) {
    final c = context.lazy;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(color: c.err.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(16), border: Border.all(color: c.err.withValues(alpha: 0.25))),
            child: Icon(Icons.cloud_off_rounded, color: c.err, size: 28),
          ),
          const SizedBox(height: 16),
          Text('Backend unavailable', style: TextStyle(color: c.ink, fontWeight: FontWeight.w700, fontSize: 18)),
          const SizedBox(height: 8),
          Text(details, textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: 12, height: 1.4)),
          const SizedBox(height: 20),
          SizedBox(width: double.infinity, child: FilledButton(onPressed: onRetry, child: const Text('TRY AGAIN'))),
          const SizedBox(height: 8),
          TextButton(onPressed: onChangeBackend, child: const Text('CHANGE BACKEND')),
        ]),
      ),
    );
  }
}
