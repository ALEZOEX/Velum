import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velum/client.dart';
import 'package:velum/exit_dialogs.dart';
import 'package:velum/tray_service.dart';

void main() {
  late Directory directory;
  late VelumClient client;
  late GlobalKey<NavigatorState> navigator;
  late ExitDialogs dialogs;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('velum-exit-dialog-');
    client = VelumClient(directory: directory);
    navigator = GlobalKey<NavigatorState>();
    dialogs = ExitDialogs(navigator, client);
  });
  tearDown(() async {
    await client.shutdown();
    client.dispose();
    await directory.delete(recursive: true);
  });
  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      home: const Scaffold(body: Text('Velum')),
    ),
  );

  testWidgets(
    'protection warning requires explicit approval and supports cancellation',
    (tester) async {
      await mount(tester);
      final confirmation = dialogs.confirmProtectionLoss();
      await tester.pumpAndSettle();
      expect(find.textContaining('прямое соединение'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(await confirmation, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('service warning says that system service stays running', (
    tester,
  ) async {
    client.status = {'serviceMode': 'systemd'};
    await mount(tester);
    final confirmation = dialogs.confirmProtectionLoss();
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Системная служба продолжит работу'),
      findsOneWidget,
    );
    await tester.tap(find.text('Выйти'));
    await tester.pumpAndSettle();
    expect(await confirmation, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
  for (final entry in {
    'Повторить восстановление': ExitFailureAction.retry,
    'Отменить выход': ExitFailureAction.cancel,
    'Выйти несмотря на предупреждение': ExitFailureAction.force,
  }.entries) {
    testWidgets('cleanup error exposes explicit decision: ${entry.key}', (
      tester,
    ) async {
      await mount(tester);
      final decision = dialogs.cleanupFailed(
        const FormatException('mock restore failure'),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('mock restore failure'), findsOneWidget);
      expect(find.textContaining('журнал восстановления'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Безопасный выход не завершён'), findsOneWidget);
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();
      expect(await decision, entry.value);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
