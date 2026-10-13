import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

/// Display face (web --display / Space Grotesk): section titles, buttons,
/// seg, brand, job state.
TextStyle disp(double size, FontWeight w, Color c) => GoogleFonts.spaceGrotesk(
      fontSize: size,
      fontWeight: w,
      color: c,
      letterSpacing: -size * 0.01,
    );

/// Mono face (web --mono / DM Mono): pills, hints, meta, badges, labels.
TextStyle fmono(double size, Color c, {FontWeight w = FontWeight.w400, double ls = 0}) =>
    GoogleFonts.dmMono(fontSize: size, fontWeight: w, color: c, letterSpacing: ls);

/// System UI overlay (Android status/nav zones).
/// Both zones are OPAQUE and carry the topbar card color #171717
/// (white in light mode), so the frame matches the topbar exactly.
SystemUiOverlayStyle lazySystemOverlayStyle(bool isDark) => SystemUiOverlayStyle(
      statusBarColor: isDark ? const Color(0xFF171717) : Colors.white,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarColor: isDark ? const Color(0xFF171717) : Colors.white,
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
    bg: Color(0xFFF4F4F5),
    bgSoft: Color(0xFFECECEE),
    bgCard: Color(0xFFFFFFFF),
    border: Color(0xFFE6E6E9),
    borderSoft: Color(0xFFF0F0F2),
    ink: Color(0xFF121215),
    ink2: Color(0xFF333338),
    ink3: Color(0xFF5B5B63),
    muted: Color(0xFF8A8A93),
    muted2: Color(0xFFB9B9C0),
    muted3: Color(0xFFD4D4D8),
    muted4: Color(0xFFE4E4E7),
    accent: Color(0xFF09090B),
    accentDeep: Color(0xFF09090B),
    accentSoft: Color(0xFFEFEFF1),
    accentHover: Color(0xFF27272A),
    accentTint: Color(0xFFF7F7F8),
    accent2: Color(0xFF09090B),
    ok: Color(0xFF16A34A),
    warn: Color(0xFFB45309),
    err: Color(0xFFB91C1C),
    ring: Color(0x2E09090B),
    shadow: Color(0x1A09090B),
  );

  static const dark = LazyColors(
    bg: Color(0xFF08080A),
    bgSoft: Color(0xFF101014),
    bgCard: Color(0xFF101014),
    border: Color(0xFF1E1E22),
    borderSoft: Color(0xFF16161A),
    ink: Color(0xFFF5F5F4),
    ink2: Color(0xFFD7D7DB),
    ink3: Color(0xFFA1A1AA),
    muted: Color(0xFF71717A),
    muted2: Color(0xFF52525B),
    muted3: Color(0xFF3F3F46),
    muted4: Color(0xFF27272A),
    accent: Color(0xFFFFFFFF),
    accentDeep: Color(0xFFFFFFFF),
    accentSoft: Color(0xFF1E1E22),
    accentHover: Color(0xFFE4E4E7),
    accentTint: Color(0xFF141417),
    accent2: Color(0xFFFFFFFF),
    ok: Color(0xFF4ADE80),
    warn: Color(0xFFFBBF24),
    err: Color(0xFFF87171),
    ring: Color(0x38FFFFFF),
    shadow: Color(0x73000000),
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
    fontFamily: GoogleFonts.manrope().fontFamily,
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
      fillColor: c.accentTint,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      hintStyle: TextStyle(color: c.muted3, fontSize: 12, fontWeight: FontWeight.w400),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.ring, width: 1.2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.err),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: c.err, width: 1.2),
      ),
      labelStyle: TextStyle(
        fontFamily: GoogleFonts.dmMono().fontFamily,
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
        textStyle: TextStyle(
          fontFamily: GoogleFonts.dmMono().fontFamily,
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
        textStyle: TextStyle(
          fontFamily: GoogleFonts.dmMono().fontFamily,
          fontSize: 10,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.6,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.accent,
        textStyle: TextStyle(
          fontFamily: GoogleFonts.dmMono().fontFamily,
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
      labelStyle: TextStyle(fontFamily: GoogleFonts.dmMono().fontFamily, fontSize: 9),
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
  final base = TextTheme(
    headlineMedium: TextStyle(color: c.ink, fontWeight: FontWeight.w700, letterSpacing: -0.5, fontSize: 28),
    titleLarge: TextStyle(color: c.ink, fontWeight: FontWeight.w700, fontSize: 20),
    titleMedium: TextStyle(color: c.ink, fontWeight: FontWeight.w600, fontSize: 16),
    titleSmall: TextStyle(color: c.ink2, fontWeight: FontWeight.w600, fontSize: 14),
    bodyLarge: TextStyle(color: c.ink, fontWeight: FontWeight.w300, fontSize: 14, height: 1.45),
    bodyMedium: TextStyle(color: c.muted, fontWeight: FontWeight.w300, fontSize: 13, height: 1.55),
    bodySmall: TextStyle(color: c.muted2, fontWeight: FontWeight.w300, fontSize: 11.5, height: 1.35),
    labelLarge: TextStyle(
      color: c.muted2,
      fontWeight: FontWeight.w600,
      fontSize: 11.5,
      letterSpacing: 1.2,
    ),
    labelSmall: TextStyle(
      color: c.muted2,
      fontWeight: FontWeight.w500,
      fontSize: 10,
      letterSpacing: 1.2,
    ),
  );
  // Body voice is Manrope (set as the app fontFamily above); labels speak
  // DM Mono — same pairing as the site.
  return base.copyWith(
    labelLarge: GoogleFonts.dmMono(textStyle: base.labelLarge!),
    labelSmall: GoogleFonts.dmMono(textStyle: base.labelSmall!),
  );
}
