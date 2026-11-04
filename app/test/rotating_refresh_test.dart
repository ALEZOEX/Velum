import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velum/rotating_refresh.dart';

void main() {
  testWidgets('Refresh rotates during request and resets after completion', (
    tester,
  ) async {
    Future<void> show(bool active) => tester.pumpWidget(
      MaterialApp(
        home: RotatingRefresh(active: active, child: const Icon(Icons.refresh)),
      ),
    );
    await show(false);
    expect(
      tester
          .widget<RotationTransition>(find.byType(RotationTransition))
          .turns
          .value,
      0,
    );
    await show(true);
    await tester.pump(const Duration(milliseconds: 225));
    expect(
      tester
          .widget<RotationTransition>(find.byType(RotationTransition))
          .turns
          .value,
      greaterThan(0),
    );
    await show(false);
    await tester.pump(const Duration(milliseconds: 225));
    expect(
      tester
          .widget<RotationTransition>(find.byType(RotationTransition))
          .turns
          .value,
      0,
    );
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
