import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Lean frosted edge for the system zones (status bar top, gesture/nav
/// bottom). Three thin BackdropFilter bands — strongest at the screen edge.
///
/// Pure blur, no opaque scrim: an opaque gradient cap reads as a solid
/// strip, which defeats the point. The page behind is the same background
/// color, so the edge melts seamlessly and only scrolled content frosts.
/// Deliberately NOT the 16-layer stack: every band is a full-width GPU
/// saveLayer recomposited each frame.
class EdgeFrost extends StatelessWidget {
  final bool top;
  final double inset;
  final double fade;

  const EdgeFrost({
    super.key,
    required this.top,
    required this.inset,
    this.fade = 40,
  });

  static const _sigmas = <double>[2.0, 1.0, 0.4];

  @override
  Widget build(BuildContext context) {
    final ordered = top ? _sigmas : _sigmas.reversed.toList();
    return IgnorePointer(
      child: SizedBox(
        height: inset + fade,
        width: double.infinity,
        child: Column(
          children: [
            for (final sigma in ordered)
              Expanded(
                child: ClipRect(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
