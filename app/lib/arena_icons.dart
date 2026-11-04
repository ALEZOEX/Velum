import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class ArenaGlyph extends StatelessWidget {
  const ArenaGlyph(this.name, {super.key, this.size = 16, this.color});
  final String name;
  final double size;
  final Color? color;
  @override
  Widget build(BuildContext context) => Center(
    widthFactor: 1,
    heightFactor: 1,
    child: SizedBox(
      width: size,
      height: size,
      child: SvgPicture.asset(
        'assets/icons/$name.svg',
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(
          color ?? IconTheme.of(context).color ?? Colors.white,
          BlendMode.srcIn,
        ),
      ),
    ),
  );
}

Widget arenaSmallButton(
  String glyph,
  String tooltip,
  VoidCallback? onTap, {
  bool acid = false,
  double size = 36,
}) => SizedBox(
  width: size,
  height: size,
  child: Builder(
    builder: (context) {
      final color = Theme.of(context).colorScheme;
      return IconButton(
        onPressed: onTap,
        tooltip: tooltip,
        iconSize: 16,
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          backgroundColor: acid
              ? color.primary.withValues(alpha: .14)
              : const Color(0xa61a0e31),
          foregroundColor: acid ? color.primary : const Color(0xffd8ccf0),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: acid
                  ? color.primary.withValues(alpha: .45)
                  : const Color(0x38a855f7),
            ),
          ),
        ),
        icon: ArenaGlyph(
          glyph,
          color: acid ? color.primary : const Color(0xffd8ccf0),
        ),
      );
    },
  ),
);
