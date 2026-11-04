import 'package:flutter/material.dart';

class RotatingRefresh extends StatefulWidget {
  const RotatingRefresh({super.key, required this.active, required this.child});
  final bool active;
  final Widget child;
  @override
  State<RotatingRefresh> createState() => _RotatingRefreshState();
}

class _RotatingRefreshState extends State<RotatingRefresh>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  @override
  void initState() {
    super.initState();
    if (widget.active) controller.repeat();
  }

  @override
  void didUpdateWidget(RotatingRefresh oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      controller.repeat();
    }
    if (!widget.active && oldWidget.active) {
      controller.stop();
      controller.value = 0;
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: widget.active,
    label: widget.active ? 'Подписка обновляется' : null,
    child: RotationTransition(turns: controller, child: widget.child),
  );
}
