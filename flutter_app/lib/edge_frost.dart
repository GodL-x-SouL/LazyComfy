import 'package:flutter/material.dart';

/// Gradual color shade for the top system zone: page background opaque at
/// the screen edge melting to transparent over [fade] — the same gradual
/// ramp idea as a blur gradient, but in solid color (black in dark mode,
/// white in light, i.e. whatever [color] is passed, usually the page bg).
/// Content scrolling underneath fades out instead of sliding under a hard
/// bar, with zero GPU filter cost.
class EdgeShade extends StatelessWidget {
  final double inset;
  final double fade;
  final Color color;

  const EdgeShade({
    super.key,
    required this.inset,
    required this.color,
    this.fade = 32,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        height: inset + fade,
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color, color.withValues(alpha: 0)],
          ),
        ),
      ),
    );
  }
}
