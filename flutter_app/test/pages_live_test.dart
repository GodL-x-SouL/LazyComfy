import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilecomfy/lazy_theme.dart';
import 'package:mobilecomfy/native_custom.dart';
import 'package:mobilecomfy/native_forge.dart';
import 'package:mobilecomfy/native_images.dart';
import 'package:mobilecomfy/native_upscale.dart';
import 'package:mobilecomfy/native_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Boots every page against the LOCAL server (real models/dirs/history
/// shapes) to catch data-driven build crashes — the kind that shows as a
/// grey screen in release. Skips gracefully when the server is down.
Future<void> _pumpLive(WidgetTester t, Widget page) async {
  SharedPreferences.setMockInitialValues({});
  await t.pumpWidget(MaterialApp(
    theme: buildLazyTheme(LazyColors.dark, Brightness.dark),
    home: Scaffold(body: page),
  ));
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(seconds: 1));
  }
}

void main() {
  const ep = 'http://127.0.0.1:8188/lazycomfy';

  testWidgets('live images', (t) async {
    await _pumpLive(
        t, NativeImagesPage(endpoint: ep, isDark: true, onToggleTheme: () {}));
    expect(find.byType(NativeImagesPage), findsOneWidget);
  });

  testWidgets('live video', (t) async {
    await _pumpLive(t, NativeVideoPage(endpoint: 'http://127.0.0.1:8188/lazycomfy', isDark: true, onToggleTheme: () {}));
    expect(find.byType(NativeVideoPage), findsOneWidget);
  });

  testWidgets('live upscale', (t) async {
    await _pumpLive(t, NativeUpscalePage(endpoint: 'http://127.0.0.1:8188/lazycomfy', isDark: true, onToggleTheme: () {}));
    expect(find.byType(NativeUpscalePage), findsOneWidget);
  });

  testWidgets('live forge', (t) async {
    await _pumpLive(t, NativeForgePage(endpoint: 'http://127.0.0.1:8188/lazycomfy', isDark: true, onToggleTheme: () {}));
    expect(find.byType(NativeForgePage), findsOneWidget);
  });

  testWidgets('live custom', (t) async {
    await _pumpLive(t, NativeCustomPage(endpoint: 'http://127.0.0.1:8188/lazycomfy', isDark: true, onToggleTheme: () {}));
    expect(find.byType(NativeCustomPage), findsOneWidget);
  });
}
