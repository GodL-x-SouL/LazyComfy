import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'lazy_theme.dart';

/// Shared web-parity primitives, hand-matched to next-app globals.css.
/// Extracted from the Images/Downloads pages so every native page speaks
/// the same visual language: 16px cards, display section titles, tinted
/// 40px selects, seg pills, ghost buttons, mono hints.
///
/// Leaf widgets only: all state and data come in as parameters, so pages
/// stay in charge of their own logic.

class UiImg {
  final String filename;
  final String subfolder;
  final String type;
  const UiImg(this.filename, this.subfolder, this.type);
  String get key {
    final sub = subfolder.isNotEmpty ? '$subfolder/' : '';
    return '$type/$sub$filename';
  }
}

/// The brand bolt from the web header (shared ZAP_PATH, 64-unit viewBox).
class ZapPainter extends CustomPainter {
  final Color color;
  ZapPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 64;
    final p = Path()
      ..moveTo(38 * s, 8 * s)
      ..lineTo(20 * s, 36 * s)
      ..lineTo(31 * s, 36 * s)
      ..lineTo(27 * s, 56 * s)
      ..lineTo(45 * s, 28 * s)
      ..lineTo(34 * s, 28 * s)
      ..close();
    canvas.drawPath(p, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant ZapPainter old) => old.color != color;
}

/// Frosted-glass fill: blur(22) under a translucent tint, clipped round.
/// The site's .glass-pill recipe for sticky chrome.
class Glass extends StatelessWidget {
  final Widget child;
  final bool circle;
  final bool dark;
  const Glass({super.key, required this.child, required this.dark, this.circle = false});

  @override
  Widget build(BuildContext context) {
    final tint = dark ? const Color(0x700D0D11) : const Color(0x8CFFFFFF);
    final inner = BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
      child: Container(color: tint, child: child),
    );
    if (circle) return ClipOval(child: inner);
    return ClipRRect(borderRadius: BorderRadius.circular(999), child: inner);
  }
}

/// group-label: display 16/700. noPad for inline (run row) use.
Widget uiSection(BuildContext context, String text, {bool noPad = false}) {
  return Padding(
    padding: EdgeInsets.only(bottom: noPad ? 0 : 2),
    child: Text(text, style: disp(16, FontWeight.w700, context.lazy.ink)),
  );
}

/// field > label: 13/600 ink-2.
Widget uiField(BuildContext context, String text) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text,
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.lazy.ink2)),
  );
}

/// note text: 12.5px muted.
Widget uiNote(BuildContext context, String text) {
  return Text(text, style: TextStyle(fontSize: 12.5, color: context.lazy.muted));
}

/// mono hint: 10.5px muted-2.
Widget uiHint(BuildContext context, String text) {
  return Text(text, style: fmono(10.5, context.lazy.muted2));
}

Widget uiCard(BuildContext context, List<Widget> children) {
  final c = context.lazy;
  return Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: c.bgCard,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: c.border),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
  );
}

Widget uiTextField(
  BuildContext context,
  TextEditingController ctrl,
  String hint, {
  int maxLines = 1,
  bool number = false,
  bool decimal = true,
}) {
  return TextField(
    controller: ctrl,
    maxLines: number ? 1 : maxLines,
    minLines: number ? 1 : null,
    keyboardType: number ? TextInputType.numberWithOptions(signed: false, decimal: decimal) : null,
    style: TextStyle(color: context.lazy.ink, fontSize: 13),
    decoration: InputDecoration(hintText: hint),
  );
}

/// Web .select-trigger + bottom-sheet options (.select-option look).
/// The sheet header shows the FIELD title, never the value.
class UiSelect extends StatelessWidget {
  final String? value;
  final Map<String, String> items;
  final String hint;
  final String sheetTitle;
  final ValueChanged<String?> onChanged;
  final Map<String, String>? hints;
  final bool missingAsError;
  const UiSelect({
    super.key,
    required this.value,
    required this.items,
    required this.hint,
    required this.sheetTitle,
    required this.onChanged,
    this.hints,
    this.missingAsError = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.lazy;
    final safe = (value != null && items.containsKey(value)) ? value : null;
    final shown = safe != null ? items[safe]! : hint;
    final err = missingAsError && safe != null;
    return GestureDetector(
      onTap: () {
        FocusManager.instance.primaryFocus?.unfocus();
        _openOptions(context, sheetTitle, items, hints, safe, onChanged);
      },
      child: Container(
        constraints: const BoxConstraints(minHeight: 40),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: c.accentTint,
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          Expanded(
            child: Text(
              shown,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13.5, color: err ? c.err : (safe != null ? c.ink : c.muted2)),
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.expand_more_rounded, size: 18, color: c.muted2),
        ]),
      ),
    );
  }

  static void _openOptions(
    BuildContext context,
    String title,
    Map<String, String> items,
    Map<String, String>? hints,
    String? current,
    ValueChanged<String?> onChanged,
  ) {
    final c = context.lazy;
    showModalBottomSheet(
      context: context,
      backgroundColor: c.bgCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text(title,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.ink)),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
              children: [
                for (final e in items.entries)
                  GestureDetector(
                    onTap: () {
                      Navigator.pop(context);
                      onChanged(e.key);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: e.key == current ? c.accentSoft : Colors.transparent,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(
                              e.value,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: e.key == current ? FontWeight.w600 : FontWeight.w400,
                                color: e.key == current ? c.ink : c.ink2,
                              ),
                            ),
                            if ((hints?[e.key] ?? '').isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  hints![e.key]!,
                                  overflow: TextOverflow.ellipsis,
                                  style: fmono(11, c.muted),
                                ),
                              ),
                          ]),
                        ),
                        if (e.key == current)
                          Text('✓',
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w700, color: c.ink)),
                      ]),
                    ),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

/// Web .seg: tint track, accent active pill.
class UiSeg extends StatelessWidget {
  final List<String> options;
  final String value;
  final Map<String, String> labels;
  final ValueChanged<String> onChanged;
  final bool compact;
  const UiSeg({
    super.key,
    required this.options,
    required this.value,
    required this.labels,
    required this.onChanged,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.lazy;
    final dark = context.isDark;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.accentTint,
        border: Border.all(color: c.borderSoft),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
        children: [
          for (final o in options)
            (compact
                ? GestureDetector(
                    onTap: () => onChanged(o),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: o == value ? c.accent : Colors.transparent,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        labels[o] ?? o,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: o == value
                              ? (dark ? const Color(0xFF09090B) : const Color(0xFFFFFFFF))
                              : c.ink3,
                        ),
                      ),
                    ),
                  )
                : Expanded(
                    child: GestureDetector(
                      onTap: () {
                        FocusManager.instance.primaryFocus?.unfocus();
                        onChanged(o);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          color: o == value ? c.accent : Colors.transparent,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          labels[o] ?? o,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: o == value
                                ? (dark ? const Color(0xFF09090B) : const Color(0xFFFFFFFF))
                                : c.ink3,
                          ),
                        ),
                      ),
                    ),
                  )),
        ],
      ),
    );
  }
}

/// Web .act-btn ghost pill. Fixed 34px height so grids are exact.
class UiPill extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  const UiPill(this.text, this.onTap, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.lazy;
    return GestureDetector(
      onTap: () {
        FocusManager.instance.primaryFocus?.unfocus();
        onTap();
      },
      child: Container(
        height: 34,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: fmono(12, c.ink2, w: FontWeight.w600),
        ),
      ),
    );
  }
}

/// Web .btn-primary: full-width pill, 13/700 display. Danger mode turns
/// the same button into the run cancel (red fill), so Generate/Upscale
/// morph in place instead of growing a second button over the progress.
class UiPrimaryBtn extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;
  final bool danger;
  const UiPrimaryBtn(this.text, this.onTap, {super.key, this.danger = false});

  @override
  Widget build(BuildContext context) {
    final c = context.lazy;
    final dark = context.isDark;
    final enabled = onTap != null;
    final fill = danger ? c.err : c.accent;
    final edge = danger ? c.err : (enabled ? c.accent : c.border);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        decoration: BoxDecoration(
          color: enabled ? fill : c.accentSoft,
          border: Border.all(color: edge),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: disp(
            13,
            FontWeight.w700,
            enabled
                ? (danger
                    ? const Color(0xFFFFFFFF)
                    : (dark ? const Color(0xFF09090B) : const Color(0xFFFFFFFF)))
                : c.muted2,
          ),
        ),
      ),
    );
  }
}

/// Web ghost button (mono 12/600 pill).
class UiGhostBtn extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  const UiGhostBtn(this.text, this.onTap, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.lazy;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: fmono(12, c.ink2, w: FontWeight.w600),
        ),
      ),
    );
  }
}

/// Danger outline pill (cancel, clear, delete).
class UiDangerBtn extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  const UiDangerBtn(this.text, this.onTap, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.lazy;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          border: Border.all(color: c.err),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: fmono(12, c.err, w: FontWeight.w600),
        ),
      ),
    );
  }
}

/// 32px bordered circle (web icon-circle).
class UiIconCircle extends StatelessWidget {
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  const UiIconCircle(this.icon, this.tip, this.onTap, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.lazy;
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: c.border),
          ),
          child: Icon(icon, size: 14, color: c.ink2),
        ),
      ),
    );
  }
}

/// 42px circle: same height as the brand pill. Frosted glass inside,
/// like the site header chrome.
class UiHeadBtn extends StatelessWidget {
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  const UiHeadBtn(this.icon, this.tip, this.onTap, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.lazy;
    final dark = context.isDark;
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: c.border),
          ),
          child: Glass(
            dark: dark,
            circle: true,
            child: SizedBox(
              width: 42,
              height: 42,
              child: Icon(icon, size: 17, color: c.ink2),
            ),
          ),
        ),
      ),
    );
  }
}

/// Web range input look: thin track, small thumb, no value bubble.
class UiSlider extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final int divisions;
  const UiSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 5,
    this.divisions = 100,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.lazy;
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: c.accent,
        inactiveTrackColor: c.accentSoft,
        thumbColor: c.accent,
        overlayColor: c.accent.withValues(alpha: 0.15),
        trackHeight: 2,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      ),
      child: Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        onChanged: onChanged,
      ),
    );
  }
}

/// Red error banner card. Tappable when an action is supplied.
class UiErrBanner extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;
  const UiErrBanner(this.text, {super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.lazy;
    final box = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.err.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.err.withValues(alpha: 0.35)),
      ),
      child: Text(text, style: TextStyle(color: c.err, fontSize: 12.5, height: 1.35)),
    );
    if (onTap == null) return box;
    return GestureDetector(onTap: onTap, child: box);
  }
}

/// Compact number: 1.00 -> "1", 0.50 -> "0.5".
String trimNum(double v) {
  var s = v.toStringAsFixed(2);
  if (s.contains('.')) {
    s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }
  return s;
}

/// Input/preview image at its natural ratio (the web <img> has no fixed
/// height). Resolves dimensions once, then locks an AspectRatio — no crop,
/// no fixed box. With [lockAspect] the zone itself is fixed (e.g. square)
/// and the image letterboxes inside — same placement for every ratio.
class UiRatioImage extends StatefulWidget {
  final String url;
  final double fallbackHeight;
  final double? lockAspect;
  const UiRatioImage({super.key, required this.url, this.fallbackHeight = 160, this.lockAspect});

  @override
  State<UiRatioImage> createState() => _UiRatioImageState();
}

class _UiRatioImageState extends State<UiRatioImage> {
  double? _aspect;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant UiRatioImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // New selection reuses this state: drop the old ratio and resolve
    // the new file, or the preview keeps the previous image's shape.
    if (oldWidget.url != widget.url) {
      _aspect = null;
      _failed = false;
      _resolve();
    }
  }

  void _resolve() {
    if (widget.lockAspect != null) return;
    final url = widget.url;
    CachedNetworkImageProvider(url).resolve(const ImageConfiguration()).addListener(
      ImageStreamListener((info, _) {
        if (!mounted || widget.url != url) return;
        final w = info.image.width.toDouble();
        final h = info.image.height.toDouble();
        if (w > 0 && h > 0) setState(() => _aspect = w / h);
      }, onError: (_, __) {
        if (mounted && widget.url == url) setState(() => _failed = true);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lock = widget.lockAspect;
    if (lock != null) {
      return AspectRatio(
        aspectRatio: lock,
        child: CachedNetworkImage(
          imageUrl: widget.url,
          fit: BoxFit.contain,
          placeholder: (_, __) => Container(color: context.lazy.bgSoft),
          errorWidget: (_, __, ___) => const Icon(Icons.broken_image_outlined),
        ),
      );
    }
    if (_failed) {
      return SizedBox(
          height: widget.fallbackHeight,
          child: const Center(child: Icon(Icons.broken_image_outlined)));
    }
    if (_aspect == null) {
      return Container(height: widget.fallbackHeight, color: context.lazy.bgSoft);
    }
    return AspectRatio(
      aspectRatio: _aspect!,
      child: CachedNetworkImage(
        imageUrl: widget.url,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => SizedBox(
            height: widget.fallbackHeight, child: const Icon(Icons.broken_image_outlined)),
      ),
    );
  }
}
/// Brand pill (zap + name), frosted like the site header.
class UiBrand extends StatelessWidget {
  final bool dark;
  const UiBrand({super.key, required this.dark});

  @override
  Widget build(BuildContext context) {
    final c = context.lazy;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Glass(
        dark: dark,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 15, 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dark ? const Color(0xFFFFFFFF) : const Color(0xFF09090B),
              ),
              child: Center(
                child: CustomPaint(
                  painter: ZapPainter(dark ? const Color(0xFF09090B) : const Color(0xFFFFFFFF)),
                  size: const Size(22, 22),
                ),
              ),
            ),
            const SizedBox(width: 9),
            Text('LazyComfy', style: disp(17, FontWeight.w700, c.ink)),
          ]),
        ),
      ),
    );
  }
}

/// App-styled notification: card surface, hairline border, status dot —
/// the same language as the cards, replacing the raw Material bars.
void showUiSnack(BuildContext context, String msg, {bool ok = false}) {
  final c = context.lazy;
  final dot = ok ? c.ok : c.warn;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: c.bgCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: ok ? c.ok.withValues(alpha: 0.5) : c.border),
        ),
        // Floating bars dock above the bottom nav on their own; the margin
        // only needs side clearance, not extra bottom lift.
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        duration: const Duration(seconds: 3),
        content: Row(children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(msg,
                style: TextStyle(fontSize: 12.5, height: 1.35, color: c.ink)),
          ),
        ]),
      ),
    );
}

/// Download/cancel circle chip shared by the downloads window and the
/// Forge file rows: download arrow idle, ✕ while active.
class UiDlCircle extends StatelessWidget {
  final bool busy;
  final VoidCallback onTap;
  final double size;
  const UiDlCircle({required this.busy, required this.onTap, this.size = 40, super.key});

  @override
  Widget build(BuildContext context) {
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
}

/// Friendly label for a ComfyUI node class, for the run progress line.
/// Known loader/encode/decode classes get plain words; anything else
/// falls back to the registry display name, then spaced CamelCase.
String nodeDisplayName(String classType, [String? displayName]) {
  if (displayName != null && displayName.isNotEmpty && displayName != classType) {
    return displayName;
  }
  switch (classType) {
    case 'KSampler':
    case 'KSamplerAdvanced':
    case 'SamplerCustom':
    case 'SamplerCustomAdvanced':
      return 'Sampling';
    case 'CheckpointLoaderSimple':
    case 'CheckpointLoader':
    case 'UNETLoader':
    case 'UnetLoaderGGUF':
      return 'Loading model';
    case 'CLIPLoader':
    case 'QuadrupleCLIPLoader':
    case 'CLIPLoaderGGUF':
    case 'DualCLIPLoader':
    case 'DualCLIPLoaderGGUF':
      return 'Loading text encoder';
    case 'VAELoader':
      return 'Loading VAE';
    case 'LoraLoader':
    case 'LoraLoaderModelOnly':
      return 'Loading LoRA';
    case 'ControlNetLoader':
    case 'DiffControlNetLoader':
      return 'Loading ControlNet';
    case 'UpscaleModelLoader':
      return 'Loading upscaler';
    case 'CLIPTextEncode':
    case 'CLIPTextEncodeFlux':
    case 'TextEncodeQwenImage21':
      return 'Encoding prompt';
    case 'EmptyLatentImage':
    case 'EmptySD3LatentImage':
    case 'EmptyHunyuanLatentVideo':
    case 'EmptyMochiLatentVideo':
    case 'EmptyLTXVLatentVideo':
      return 'Preparing canvas';
    case 'LoadImage':
      return 'Loading image';
    case 'LoadVideo':
    case 'LoadVideoUpload':
      return 'Loading video';
    case 'ImageScaleBy':
      return 'Scaling';
    case 'VAEDecode':
    case 'VAEDecodeTiled':
      return 'Decoding image';
    case 'VAEEncode':
    case 'VAEEncodeTiled':
      return 'Encoding image';
    case 'ImageUpscaleWithModel':
      return 'Upscaling';
    case 'SaveImage':
    case 'SaveVideo':
    case 'SaveAnimatedWEBP':
    case 'SaveWEBM':
    case 'SaveAnimatedPNG':
      return 'Saving';
  }
  return classType
      .replaceAllMapped(
          RegExp(r'(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])'),
          (_) => ' ')
      .trim();
}
