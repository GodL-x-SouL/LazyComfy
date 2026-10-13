import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'lazy_theme.dart';
import 'native_custom.dart';
import 'native_forge.dart';
import 'native_images.dart';
import 'native_upscale.dart';
import 'native_video.dart';

const _endpointKey = 'mobilecomfy.backend_url.v1';
const _themeKey = 'lazycomfy.theme';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Android edge-to-edge: status + gesture areas are transparent. All inset
  // handling lives in Flutter widgets, so content never sits under system UI.
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
  // Endpoint is the API root (/lazycomfy), never the app page. Users often
  // paste the browser URL with /app (or an already-doubled /app/lazycomfy
  // from an older normalize): collapse to the first /lazycomfy, since the
  // API client builds every call under it. Without this, the SPA fallback
  // answers API paths with index.html (200) and every sync fails on HTML
  // instead of JSON.
  final idx = lowerPath.indexOf('/lazycomfy');
  if (idx >= 0) {
    path = '${path.substring(0, idx)}/lazycomfy';
  } else {
    path = path.isEmpty ? '/lazycomfy' : '$path/lazycomfy';
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

  /// Single entry point for every theme change (gate + native header):
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
      // framework.
      home: AnnotatedRegion<SystemUiOverlayStyle>(
        value: lazySystemOverlayStyle(isDark),
        child: AppRoot(
          themeMode: _mode,
          onToggleTheme: _toggleTheme,
        ),
      ),
    );
  }
}

class AppRoot extends StatefulWidget {
  final ThemeMode themeMode;
  final VoidCallback onToggleTheme;
  const AppRoot({super.key, required this.themeMode, required this.onToggleTheme});
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
                          fontFamily: GoogleFonts.dmMono().fontFamily,
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
                        style: TextStyle(fontFamily: GoogleFonts.dmMono().fontFamily, fontSize: 12, color: c.ink),
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
                            textStyle: TextStyle(fontFamily: GoogleFonts.dmMono().fontFamily, fontSize: 11.5, fontWeight: FontWeight.w600, letterSpacing: 1.2),
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

// ── Backend shell: native UI only ──
//
// The app is a native client for one specific task (the Images flow plus
// its model downloads). The LazyComfy web UI stays available through the
// phone browser — nothing in this app embeds it anymore, so there is no
// WebView, no JS bridge, and no per-page web patching.

class BackendShell extends StatelessWidget {
  final String endpoint;
  final VoidCallback onChangeBackend;
  final ThemeMode themeMode;
  final VoidCallback onToggleTheme;
  const BackendShell({
    super.key,
    required this.endpoint,
    required this.onChangeBackend,
    required this.themeMode,
    required this.onToggleTheme,
  });

  @override
  Widget build(BuildContext context) {
    return _TabsShell(
      key: ValueKey(endpoint),
      endpoint: endpoint,
      onChangeBackend: onChangeBackend,
      isDark: themeMode == ThemeMode.dark,
      onToggleTheme: onToggleTheme,
    );
  }
}

/// Bottom-tab shell over the five native pages. IndexedStack keeps every
/// page alive so switching tabs never loses state or reloads the server.
class _TabsShell extends StatefulWidget {
  final String endpoint;
  final VoidCallback onChangeBackend;
  final bool isDark;
  final VoidCallback onToggleTheme;
  const _TabsShell({
    super.key,
    required this.endpoint,
    required this.onChangeBackend,
    required this.isDark,
    required this.onToggleTheme,
  });

  @override
  State<_TabsShell> createState() => _TabsShellState();
}

class _TabsShellState extends State<_TabsShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final c = context.lazy;
    // Android back button returns to Setup (backend gate).
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onChangeBackend();
      },
      child: Scaffold(
        backgroundColor: widget.isDark ? const Color(0xFF171717) : Colors.white,
        body: IndexedStack(
          index: _tab,
          children: [
            NativeImagesPage(
              endpoint: widget.endpoint,
              isDark: widget.isDark,
              onToggleTheme: widget.onToggleTheme,
            ),
            NativeVideoPage(
              endpoint: widget.endpoint,
              isDark: widget.isDark,
              onToggleTheme: widget.onToggleTheme,
            ),
            NativeUpscalePage(
              endpoint: widget.endpoint,
              isDark: widget.isDark,
              onToggleTheme: widget.onToggleTheme,
            ),
            NativeForgePage(
              endpoint: widget.endpoint,
              isDark: widget.isDark,
              onToggleTheme: widget.onToggleTheme,
            ),
            NativeCustomPage(
              endpoint: widget.endpoint,
              isDark: widget.isDark,
              onToggleTheme: widget.onToggleTheme,
            ),
          ],
        ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _tab,
          onTap: (i) => setState(() => _tab = i),
          type: BottomNavigationBarType.fixed,
          backgroundColor: c.bgCard,
          selectedItemColor: c.ink,
          unselectedItemColor: c.muted2,
          selectedFontSize: 10,
          unselectedFontSize: 10,
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.image_outlined), label: 'Images'),
            BottomNavigationBarItem(icon: Icon(Icons.movie_outlined), label: 'Video'),
            BottomNavigationBarItem(icon: Icon(Icons.arrow_upward_rounded), label: 'Upscale'),
            BottomNavigationBarItem(icon: Icon(Icons.auto_awesome_outlined), label: 'Forge'),
            BottomNavigationBarItem(icon: Icon(Icons.tune_rounded), label: 'Custom'),
          ],
        ),
      ),
    );
  }
}
