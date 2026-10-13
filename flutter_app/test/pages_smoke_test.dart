import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilecomfy/lazy_theme.dart';
import 'package:mobilecomfy/native_custom.dart';
import 'package:mobilecomfy/native_forge.dart';
import 'package:mobilecomfy/native_images.dart';
import 'package:mobilecomfy/native_upscale.dart';
import 'package:mobilecomfy/native_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Build-smoke tests: in release mode a build-time exception shows as a
/// grey screen with no stack. Pumping each page against an unreachable
/// endpoint exercises the full build (cached/empty states + error banner)
/// and surfaces the exception here instead.
Future<void> _pumpPage(WidgetTester t, Widget page) async {
  SharedPreferences.setMockInitialValues({});
  await t.pumpWidget(MaterialApp(
    theme: buildLazyTheme(LazyColors.dark, Brightness.dark),
    home: Scaffold(body: page),
  ));
  await t.pump();
  await t.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('images page builds', (t) async {
    await _pumpPage(
        t,
        NativeImagesPage(
            endpoint: 'http://127.0.0.1:9', isDark: true, onToggleTheme: () {}));
    expect(find.byType(NativeImagesPage), findsOneWidget);
  });

  testWidgets('video page builds', (t) async {
    await _pumpPage(t, NativeVideoPage(endpoint: 'http://127.0.0.1:9', isDark: true, onToggleTheme: () {}));
    expect(find.byType(NativeVideoPage), findsOneWidget);
  });

  testWidgets('upscale page builds', (t) async {
    await _pumpPage(t, NativeUpscalePage(endpoint: 'http://127.0.0.1:9', isDark: true, onToggleTheme: () {}));
    expect(find.byType(NativeUpscalePage), findsOneWidget);
  });

  testWidgets('forge page builds', (t) async {
    await _pumpPage(t, NativeForgePage(endpoint: 'http://127.0.0.1:9', isDark: true, onToggleTheme: () {}));
    expect(find.byType(NativeForgePage), findsOneWidget);
  });

  testWidgets('custom page builds', (t) async {
    await _pumpPage(t, NativeCustomPage(endpoint: 'http://127.0.0.1:9', isDark: true, onToggleTheme: () {}));
    expect(find.byType(NativeCustomPage), findsOneWidget);
  });
}
