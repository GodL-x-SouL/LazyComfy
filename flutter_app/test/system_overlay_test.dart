import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilecomfy/lazy_theme.dart';
import 'package:mobilecomfy/main.dart';

void main() {
  test('light app theme uses opaque white system zones (matches solid topbar/body)', () {
    final style = lazySystemOverlayStyle(false);
    expect(style.statusBarIconBrightness, Brightness.dark);
    expect(style.statusBarBrightness, Brightness.light);
    expect(style.statusBarColor, Colors.white);
    expect(style.systemNavigationBarColor, Colors.white);
    expect(style.systemNavigationBarIconBrightness, Brightness.dark);
    expect(style.systemStatusBarContrastEnforced, false);
    expect(style.systemNavigationBarContrastEnforced, false);
  });

  test('dark app theme paints both system zones #171717 (topbar card color)', () {
    final style = lazySystemOverlayStyle(true);
    expect(style.statusBarIconBrightness, Brightness.light);
    expect(style.statusBarBrightness, Brightness.dark);
    expect(style.statusBarColor, const Color(0xFF171717));
    expect(style.systemNavigationBarColor, const Color(0xFF171717));
    expect(style.systemNavigationBarIconBrightness, Brightness.light);
  });

  test('built themes carry the matching app-bar overlay style', () {
    final light = buildLazyTheme(LazyColors.light, Brightness.light);
    final dark = buildLazyTheme(LazyColors.dark, Brightness.dark);
    expect(light.appBarTheme.systemOverlayStyle?.statusBarIconBrightness,
        Brightness.dark);
    expect(dark.appBarTheme.systemOverlayStyle?.statusBarIconBrightness,
        Brightness.light);
  });

  test('web theme messages parse to the matching ThemeMode', () {
    expect(parseThemeModeMessage('dark'), ThemeMode.dark);
    expect(parseThemeModeMessage(' Dark '), ThemeMode.dark);
    expect(parseThemeModeMessage('light'), ThemeMode.light);
    expect(parseThemeModeMessage('anything-else'), ThemeMode.light);
  });
}
