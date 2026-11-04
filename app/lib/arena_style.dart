import 'dart:math' as math;

import 'package:flutter/material.dart';

ThemeData arenaTheme(
  Brightness brightness, {
  String themeId = 'velum-acid-violet',
}) {
  final dark = brightness == Brightness.dark;
  var scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xffa855f7),
        brightness: brightness,
      ).copyWith(
        primary: dark ? const Color(0xffb8ff14) : const Color(0xff4b6500),
        onPrimary: dark ? const Color(0xff182000) : Colors.white,
        secondary: dark ? const Color(0xffc591ff) : const Color(0xff7435a8),
        secondaryContainer: dark
            ? const Color(0xff30203f)
            : const Color(0xffeddbff),
        surface: dark ? const Color(0xff0b0616) : const Color(0xfffaf6ff),
        surfaceContainerLowest: dark ? const Color(0xff160e25) : Colors.white,
        surfaceContainerLow: dark
            ? const Color(0xff1b112c)
            : const Color(0xfff0e8f7),
        outlineVariant: dark
            ? const Color(0xff3a294f)
            : const Color(0xffd6c5e2),
        onSurface: dark ? const Color(0xfff5efff) : const Color(0xff24132f),
        onSurfaceVariant: dark
            ? const Color(0xffb8a8cb)
            : const Color(0xff645071),
      );
  final palette = switch (themeId) {
    'hyper-amethyst' => [
      const Color(0xffccff00),
      const Color(0xff9333ea),
      const Color(0xff0e0520),
      const Color(0xff190b36),
    ],
    'cyber-orchid' => [
      const Color(0xff80ff72),
      const Color(0xffd946ef),
      const Color(0xff0d0618),
      const Color(0xff1a0b2b),
    ],
    'acid-matrix' => [
      const Color(0xffa3ff12),
      const Color(0xff8b5cf6),
      const Color(0xff080910),
      const Color(0xff101220),
    ],
    'incy-emerald' => [
      const Color(0xff9ef01a),
      const Color(0xff4ade80),
      const Color(0xff08120a),
      const Color(0xff0b140d),
    ],
    _ => [
      const Color(0xffb8ff14),
      const Color(0xffa855f7),
      const Color(0xff0b0616),
      const Color(0xff130a24),
    ],
  };
  if (dark) {
    scheme = scheme.copyWith(
      primary: palette[0],
      secondary: palette[1],
      surface: palette[2],
      surfaceContainerLow: palette[3],
    );
  }
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'ArenaSans',
    textTheme: ThemeData(brightness: brightness).textTheme
        .apply(fontFamily: 'ArenaSans'),
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLowest,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      contentPadding: const EdgeInsets.all(16),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    chipTheme: ChipThemeData(
      side: BorderSide(color: scheme.outlineVariant),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}

class ArenaBackdrop extends StatelessWidget {
  const ArenaBackdrop({
    super.key,
    this.patternId = 'topography',
    this.intensity = 68,
    this.connected = false,
  });
  final String patternId;
  final int intensity;
  final bool connected;
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(
      painter: _ArenaPattern(
        Theme.of(context).colorScheme,
        patternId,
        intensity,
        connected,
      ),
    ),
  );
}

class _ArenaPattern extends CustomPainter {
  const _ArenaPattern(
    this.colors,
    this.pattern,
    this.intensity,
    this.connected,
  );
  final ColorScheme colors;
  final String pattern;
  final int intensity;
  final bool connected;
  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-.7, -1),
          radius: 1.25,
          colors: [
            colors.surfaceContainerLow,
            colors.surface,
            const Color(0xff05020a),
          ],
          stops: const [0, .62, 1],
        ).createShader(bounds),
    );
    final glow = Paint()
      ..color = colors.secondary.withValues(alpha: .22)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 125);
    canvas.drawCircle(const Offset(148, 116), 260, glow);
    glow.color = (connected ? colors.primary : colors.secondary).withValues(
      alpha: .14,
    );
    canvas.drawCircle(Offset(size.width - 134, size.height - 118), 230, glow);
    if (pattern != 'aurora-clean' && !_drawComposition(canvas, size)) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.15
        ..color = colors.secondary.withValues(alpha: intensity / 100 * .35);
      for (
        var y = 0.0;
        y < size.height;
        y += pattern == 'topography' ? 180 : 96
      ) {
        for (
          var x = 0.0;
          x < size.width;
          x += pattern == 'topography' ? 180 : 96
        ) {
          canvas.save();
          canvas.translate(x, y);
          if (pattern == 'topography') {
            canvas.drawPath(
              Path()
                ..moveTo(0, 36)
                ..cubicTo(45, 10, 90, 62, 180, 36)
                ..moveTo(0, 90)
                ..cubicTo(55, 62, 115, 118, 180, 90)
                ..moveTo(0, 144)
                ..cubicTo(48, 168, 122, 118, 180, 144),
              paint,
            );
            for (var a = 0.0; a < math.pi * 2; a += .25) {
              canvas.drawArc(
                Rect.fromCircle(center: Offset(90, 90), radius: 34),
                a,
                .11,
                false,
                paint..strokeWidth = .9,
              );
            }
            canvas.drawCircle(
              const Offset(90, 90),
              2.2,
              Paint()
                ..color = colors.primary.withValues(
                  alpha: intensity / 100 * .35,
                ),
            );
          } else if (pattern == 'dot-constellation') {
            for (var dy = 4.0; dy < 96; dy += 32) {
              for (var dx = 4.0; dx < 96; dx += 32) {
                canvas.drawCircle(
                  Offset(dx, dy),
                  1.35,
                  paint..style = PaintingStyle.fill,
                );
              }
            }
          } else if (pattern == 'hex-grid') {
            canvas.drawPath(
              Path()
                ..moveTo(28, 0)
                ..lineTo(56, 16)
                ..lineTo(56, 48)
                ..lineTo(28, 64)
                ..lineTo(0, 48)
                ..lineTo(0, 16)
                ..close(),
              paint,
            );
          } else if (pattern == 'rings') {
            for (final radius in [12.0, 24.0, 36.0]) {
              canvas.drawCircle(const Offset(48, 48), radius, paint);
            }
          } else if (pattern == 'diamonds') {
            canvas.drawPath(
              Path()
                ..moveTo(48, 8)
                ..lineTo(88, 48)
                ..lineTo(48, 88)
                ..lineTo(8, 48)
                ..close(),
              paint,
            );
            canvas.drawPath(
              Path()
                ..moveTo(48, 24)
                ..lineTo(72, 48)
                ..lineTo(48, 72)
                ..lineTo(24, 48)
                ..close(),
              paint,
            );
          } else if (pattern == 'triangles') {
            canvas.drawPath(
              Path()
                ..moveTo(48, 10)
                ..lineTo(88, 82)
                ..lineTo(8, 82)
                ..close(),
              paint,
            );
            canvas.drawPath(
              Path()
                ..moveTo(48, 70)
                ..lineTo(25, 30)
                ..lineTo(71, 30)
                ..close(),
              paint,
            );
          } else if (pattern == 'crosses') {
            for (var dy = 16.0; dy < 96; dy += 32) {
              for (var dx = 16.0; dx < 96; dx += 32) {
                canvas.drawLine(Offset(dx - 6, dy), Offset(dx + 6, dy), paint);
                canvas.drawLine(Offset(dx, dy - 6), Offset(dx, dy + 6), paint);
              }
            }
          } else {
            canvas.drawPath(
              Path()
                ..moveTo(0, 24)
                ..lineTo(32, 24)
                ..lineTo(48, 40)
                ..lineTo(96, 40)
                ..moveTo(24, 96)
                ..lineTo(24, 64)
                ..lineTo(44, 44)
                ..moveTo(72, 0)
                ..lineTo(72, 24)
                ..lineTo(88, 40),
              paint,
            );
          }
          canvas.restore();
        }
      }
    }
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, 1),
      Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.transparent,
            colors.secondary,
            colors.primary,
            Colors.transparent,
          ],
          stops: const [.05, .38, .68, .95],
        ).createShader(bounds)
        ..color = Colors.white.withValues(alpha: .65),
    );
  }

  bool _drawComposition(Canvas canvas, Size size) {
    if (!const {
      'orbital',
      'silk',
      'prism',
      'starmap',
      'bloom',
      'interference',
    }.contains(pattern)) {
      return false;
    }
    final alpha = intensity.clamp(0, 100) / 100;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = colors.secondary.withValues(alpha: .30 * alpha);
    final accent = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = colors.primary.withValues(alpha: .24 * alpha);
    final center = Offset(size.width * .53, size.height * .48);
    final span = math.max(size.width, size.height);
    if (pattern == 'orbital') {
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(-.35);
      for (var i = 0; i < 8; i++) {
        final radius = span * (.19 + i * .065);
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset.zero,
            width: radius * 2,
            height: radius * .68,
          ),
          i % 3 == 0 ? accent : line,
        );
        final angle = i * 2.37;
        canvas.drawCircle(
          Offset(math.cos(angle) * radius, math.sin(angle) * radius * .34),
          2.1,
          Paint()..color = colors.primary.withValues(alpha: .48 * alpha),
        );
      }
      canvas.restore();
    } else if (pattern == 'silk') {
      for (var band = 0; band < 18; band++) {
        final path = Path();
        for (var x = 0.0; x <= size.width + 8; x += 8) {
          final y =
              size.height * .16 +
              band * 24 +
              math.sin(x / 190 + band * .12) * 58 +
              math.sin(x / 83 + band * .08) * 12;
          if (x == 0) {
            path.moveTo(x, y);
          } else {
            path.lineTo(x, y);
          }
        }
        canvas.drawPath(path, band % 6 == 0 ? accent : line);
      }
    } else if (pattern == 'prism') {
      for (var i = 0; i < 9; i++) {
        final offset = i * 52.0;
        final path = Path()
          ..moveTo(-80 + offset, size.height)
          ..lineTo(size.width * .52 + offset * .25, size.height * .12)
          ..lineTo(size.width + 80 - offset * .5, size.height * .72);
        canvas.drawPath(path, i % 3 == 0 ? accent : line);
      }
    } else if (pattern == 'starmap') {
      final points = <Offset>[];
      for (var i = 0; i < 46; i++) {
        final x = ((i * 137 + 41) % 997) / 997 * size.width;
        final y = ((i * 263 + 73) % 991) / 991 * size.height;
        points.add(Offset(x, y));
      }
      for (var i = 0; i < points.length; i++) {
        for (var j = i + 1; j < points.length; j++) {
          final d = (points[i] - points[j]).distance;
          if (d > 20 && d < 105 && (i + j) % 3 == 0) {
            canvas.drawLine(
              points[i],
              points[j],
              line..color = colors.secondary.withValues(alpha: .16 * alpha),
            );
          }
        }
        canvas.drawCircle(
          points[i],
          i % 5 == 0 ? 2.2 : 1.2,
          Paint()
            ..color = (i % 5 == 0 ? colors.primary : colors.secondary)
                .withValues(alpha: .48 * alpha),
        );
      }
    } else if (pattern == 'bloom') {
      canvas.save();
      canvas.translate(center.dx, center.dy);
      final radius = math.min(size.width, size.height) * .42;
      for (var petal = 0; petal < 12; petal++) {
        canvas.save();
        canvas.rotate(petal * math.pi / 6);
        for (var layer = 0; layer < 4; layer++) {
          final r = radius * (.55 + layer * .15);
          final path = Path()
            ..moveTo(0, 0)
            ..cubicTo(r * .28, -r * .28, r * .3, -r * .76, 0, -r)
            ..cubicTo(-r * .3, -r * .76, -r * .28, -r * .28, 0, 0);
          canvas.drawPath(path, layer == 3 ? accent : line);
        }
        canvas.restore();
      }
      canvas.restore();
    } else {
      for (final origin in [
        Offset(size.width * .18, size.height * .33),
        Offset(size.width * .82, size.height * .68),
      ]) {
        for (var radius = 45.0; radius < span * 1.1; radius += 24) {
          canvas.drawCircle(origin, radius, radius % 72 < 1 ? accent : line);
        }
      }
    }
    return true;
  }

  @override
  bool shouldRepaint(_ArenaPattern old) =>
      old.colors != colors ||
      old.pattern != pattern ||
      old.intensity != intensity ||
      old.connected != connected;
}

class ArenaPowerButton extends StatelessWidget {
  const ArenaPowerButton({
    super.key,
    required this.running,
    required this.busy,
    required this.onPressed,
  });
  final bool running;
  final bool busy;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = running ? scheme.primary : scheme.secondary;
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: running ? 'Отключить соединение' : 'Включить соединение',
      child: SizedBox(
        width: 148,
        height: 148,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: accent.withValues(alpha: .25)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Material(
              color: accent.withValues(alpha: .14),
              shape: CircleBorder(
                side: BorderSide(
                  color: accent.withValues(alpha: onPressed == null ? .25 : .8),
                  width: 2,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onPressed,
                child: Center(
                  child: busy
                      ? const SizedBox(
                          width: 34,
                          height: 34,
                          child: CircularProgressIndicator(strokeWidth: 3),
                        )
                      : Icon(
                          Icons.power_settings_new_rounded,
                          size: 52,
                          color: onPressed == null
                              ? scheme.onSurfaceVariant
                              : accent,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
