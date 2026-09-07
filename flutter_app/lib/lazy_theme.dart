import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// System UI overlay (Android status/nav icons) for the given app brightness.
/// Light app background -> dark icons; dark app background -> light icons.
/// Declared centrally so the app bar theme and the root [AnnotatedRegion]
/// always agree (imperative `SystemChrome` calls inside `build()` get
/// overwritten by the framework, which is why light mode kept light icons).
SystemUiOverlayStyle lazySystemOverlayStyle(bool isDark) => SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarContrastEnforced: false,
    );

/// LazyComfy design tokens — 1:1 mapping to web/index.html :root variables.
/// Light and dark (AMOLED) are defined to match the CSS exactly.
@immutable
class LazyColors extends ThemeExtension<LazyColors> {
  final Color bg;
  final Color bgSoft;
  final Color bgCard;
  final Color border;
  final Color borderSoft;
  final Color ink;
  final Color ink2;
  final Color ink3;
  final Color muted;
  final Color muted2;
  final Color muted3;
  final Color muted4;
  final Color accent;
  final Color accentDeep;
  final Color accentSoft;
  final Color accentHover;
  final Color accentTint;
  final Color accent2;
  final Color ok;
  final Color warn;
  final Color err;
  final Color ring;
  final Color shadow;

  const LazyColors({
    required this.bg,
    required this.bgSoft,
    required this.bgCard,
    required this.border,
    required this.borderSoft,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.muted,
    required this.muted2,
    required this.muted3,
    required this.muted4,
    required this.accent,
    required this.accentDeep,
    required this.accentSoft,
    required this.accentHover,
    required this.accentTint,
    required this.accent2,
    required this.ok,
    required this.warn,
    required this.err,
    required this.ring,
    required this.shadow,
  });

  static const light = LazyColors(
    bg: Color(0xFFFFFFFF),
    bgSoft: Color(0xFFF3F4F6),
    bgCard: Color(0xFFFFFFFF),
    border: Color(0xFFCCCCCC),
    borderSoft: Color(0xFFE5E5E5),
    ink: Color(0xFF171717),
    ink2: Color(0xFF252525),
    ink3: Color(0xFF313131),
    muted: Color(0xFF4B5563),
    muted2: Color(0xFF6B7280),
    muted3: Color(0xFF9CA3AF),
    muted4: Color(0xFFC1C6CF),
    accent: Color(0xFF784CD9),
    accentDeep: Color(0xFF663AC7),
    accentSoft: Color(0xFFDCCEFB),
    accentHover: Color(0xFF663AC7),
    accentTint: Color(0xFFF5F2FA),
    accent2: Color(0xFFA380F3),
    ok: Color(0xFF16A34A),
    warn: Color(0xFFB45309),
    err: Color(0xFFB91C1C),
    ring: Color(0x29784CD9),
    shadow: Color(0x14171717),
  );

  static const dark = LazyColors(
    bg: Color(0xFF000000),
    bgSoft: Color(0xFF0F0F0F),
    bgCard: Color(0xFF171717),
    border: Color(0xFF4A4A4A),
    borderSoft: Color(0xFF313131),
    ink: Color(0xFFE1E1E1),
    ink2: Color(0xFFC6C6CC),
    ink3: Color(0xFFA2A2AA),
    muted: Color(0xFFB0B0B7),
    muted2: Color(0xFF8E8E96),
    muted3: Color(0xFF6E6E76),
    muted4: Color(0xFF53535A),
    accent: Color(0xFFA380F3),
    accentDeep: Color(0xFFC0A6FA),
    accentSoft: Color(0xFF251B3F),
    accentHover: Color(0xFFB490FF),
    accentTint: Color(0xFF1D1633),
    accent2: Color(0xFFA380F3),
    ok: Color(0xFF34D399),
    warn: Color(0xFFFBBF24),
    err: Color(0xFFF87171),
    ring: Color(0x40A380F3),
    shadow: Color(0x99000000),
  );

  @override
  LazyColors copyWith({
    Color? bg,
    Color? bgSoft,
    Color? bgCard,
    Color? border,
    Color? borderSoft,
    Color? ink,
    Color? ink2,
    Color? ink3,
    Color? muted,
    Color? muted2,
    Color? muted3,
    Color? muted4,
    Color? accent,
    Color? accentDeep,
    Color? accentSoft,
    Color? accentHover,
    Color? accentTint,
    Color? accent2,
    Color? ok,
    Color? warn,
    Color? err,
    Color? ring,
    Color? shadow,
  }) {
    return LazyColors(
      bg: bg ?? this.bg,
      bgSoft: bgSoft ?? this.bgSoft,
      bgCard: bgCard ?? this.bgCard,
      border: border ?? this.border,
      borderSoft: borderSoft ?? this.borderSoft,
      ink: ink ?? this.ink,
      ink2: ink2 ?? this.ink2,
      ink3: ink3 ?? this.ink3,
      muted: muted ?? this.muted,
      muted2: muted2 ?? this.muted2,
      muted3: muted3 ?? this.muted3,
      muted4: muted4 ?? this.muted4,
      accent: accent ?? this.accent,
      accentDeep: accentDeep ?? this.accentDeep,
      accentSoft: accentSoft ?? this.accentSoft,
      accentHover: accentHover ?? this.accentHover,
      accentTint: accentTint ?? this.accentTint,
      accent2: accent2 ?? this.accent2,
      ok: ok ?? this.ok,
      warn: warn ?? this.warn,
      err: err ?? this.err,
      ring: ring ?? this.ring,
      shadow: shadow ?? this.shadow,
    );
  }

  @override
  LazyColors lerp(ThemeExtension<LazyColors>? other, double t) {
    if (other is! LazyColors) return this;
    return LazyColors(
      bg: Color.lerp(bg, other.bg, t)!,
      bgSoft: Color.lerp(bgSoft, other.bgSoft, t)!,
      bgCard: Color.lerp(bgCard, other.bgCard, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderSoft: Color.lerp(borderSoft, other.borderSoft, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      ink2: Color.lerp(ink2, other.ink2, t)!,
      ink3: Color.lerp(ink3, other.ink3, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      muted2: Color.lerp(muted2, other.muted2, t)!,
      muted3: Color.lerp(muted3, other.muted3, t)!,
      muted4: Color.lerp(muted4, other.muted4, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentDeep: Color.lerp(accentDeep, other.accentDeep, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      accentHover: Color.lerp(accentHover, other.accentHover, t)!,
      accentTint: Color.lerp(accentTint, other.accentTint, t)!,
      accent2: Color.lerp(accent2, other.accent2, t)!,
      ok: Color.lerp(ok, other.ok, t)!,
      warn: Color.lerp(warn, other.warn, t)!,
      err: Color.lerp(err, other.err, t)!,
      ring: Color.lerp(ring, other.ring, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
    );
  }
}

extension LazyContext on BuildContext {
  LazyColors get lazy => Theme.of(this).extension<LazyColors>()!;
  bool get isDark => Theme.of(this).brightness == Brightness.dark;
}

ThemeData buildLazyTheme(LazyColors c, Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final baseScheme = ColorScheme.fromSeed(
    seedColor: c.accent,
    brightness: brightness,
    primary: c.accent,
    surface: c.bgCard,
    error: c.err,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: baseScheme.copyWith(
      primary: c.accent,
      onPrimary: isDark ? c.ink : Colors.white,
      secondary: c.accentDeep,
      surface: c.bgCard,
      onSurface: c.ink,
      error: c.err,
      outline: c.border,
      outlineVariant: c.borderSoft,
      surfaceContainerLowest: c.bg,
      surfaceContainer: c.bgSoft,
    ),
    extensions: <ThemeExtension<dynamic>>[c],
    scaffoldBackgroundColor: c.bg,
    appBarTheme: AppBarTheme(
      backgroundColor: c.bgCard.withValues(alpha: 0.86),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: c.ink,
      centerTitle: false,
      systemOverlayStyle: lazySystemOverlayStyle(isDark),
    ),
    textTheme: _buildTextTheme(c, brightness),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.bgCard,
      contentPadding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      hintStyle: TextStyle(color: c.muted3, fontSize: 12, fontWeight: FontWeight.w400),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: c.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: c.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: c.accent, width: 1.2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: c.err),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: c.err, width: 1.2),
      ),
      labelStyle: TextStyle(
        fontFamily: 'monospace',
        fontSize: 10,
        fontWeight: FontWeight.w500,
        letterSpacing: 1.2,
        color: c.muted2,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: isDark ? c.bgCard : Colors.white,
        disabledBackgroundColor: c.bgSoft,
        disabledForegroundColor: c.muted4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        textStyle: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
        elevation: 0,
        shadowColor: Colors.transparent,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.muted2,
        side: BorderSide(color: c.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 10,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.6,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.accent,
        textStyle: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 10.5,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        backgroundColor: c.bgCard,
        foregroundColor: c.muted2,
        side: BorderSide(color: c.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    cardTheme: CardThemeData(
      color: c.bgCard,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shadowColor: c.shadow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
    ),
    dividerTheme: DividerThemeData(color: c.borderSoft, thickness: 1, space: 1),
    chipTheme: ChipThemeData(
      backgroundColor: c.accentSoft,
      selectedColor: c.accentSoft,
      secondaryLabelStyle: TextStyle(color: c.accentDeep),
      labelStyle: const TextStyle(fontFamily: 'monospace', fontSize: 9),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(99),
        side: BorderSide(color: c.accentSoft),
      ),
      side: BorderSide(color: c.accentSoft),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.hovered)) return c.muted3;
        return c.border;
      }),
      trackColor: WidgetStateProperty.all(c.bgSoft),
      radius: const Radius.circular(5),
      thickness: WidgetStateProperty.all(10),
      thumbVisibility: WidgetStateProperty.all(false),
    ),
  );
}

TextTheme _buildTextTheme(LazyColors c, Brightness brightness) {
  return TextTheme(
    headlineMedium: TextStyle(color: c.ink, fontWeight: FontWeight.w700, letterSpacing: -0.5, fontSize: 28),
    titleLarge: TextStyle(color: c.ink, fontWeight: FontWeight.w700, fontSize: 20),
    titleMedium: TextStyle(color: c.ink, fontWeight: FontWeight.w600, fontSize: 16),
    titleSmall: TextStyle(color: c.ink2, fontWeight: FontWeight.w600, fontSize: 14),
    bodyLarge: TextStyle(color: c.ink, fontWeight: FontWeight.w300, fontSize: 14, height: 1.45),
    bodyMedium: TextStyle(color: c.muted, fontWeight: FontWeight.w300, fontSize: 13, height: 1.55),
    bodySmall: TextStyle(color: c.muted2, fontWeight: FontWeight.w300, fontSize: 11.5, height: 1.35),
    labelLarge: TextStyle(
      fontFamily: 'monospace',
      color: c.muted2,
      fontWeight: FontWeight.w600,
      fontSize: 11.5,
      letterSpacing: 1.2,
    ),
    labelSmall: TextStyle(
      fontFamily: 'monospace',
      color: c.muted2,
      fontWeight: FontWeight.w500,
      fontSize: 10,
      letterSpacing: 1.2,
    ),
  );
}
