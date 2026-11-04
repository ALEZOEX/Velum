import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velum/client.dart';
import 'package:velum/main.dart';

class TestClient extends VelumClient {
  TestClient(Directory directory) : super(directory: directory);
  int toggleCalls = 0;
  int reconnectCalls = 0;
  @override
  Future<void> toggle() async {
    toggleCalls++;
  }

  @override
  Future<void> reconnect() async {
    reconnectCalls++;
  }

  @override
  Future<void> refreshLogs() async {}
  @override
  Future<void> toggleFavorite(int index) async {
    final profile = profiles[index];
    profiles[index] = profile.copyWith(favorite: !profile.favorite);
    notifyListeners();
  }
}

void main() {
  late Directory directory;
  late TestClient client;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('velum-ui-test-');
    client = TestClient(directory);
  });
  tearDown(() async {
    client.dispose();
    await directory.delete(recursive: true);
  });

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(800, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(VelumApp(client: client, initialize: false));
  }

  testWidgets('Dark Arena power button uses client action', (tester) async {
    client.settings['theme'] = 'dark';
    client.profiles.add(
      const Profile('hy2://test@192.0.2.1:443', 'Test', id: 'test'),
    );
    await mount(tester, size: const Size(480, 900));
    expect(
      Theme.of(tester.element(find.byKey(const ValueKey('arena-power'))))
          .brightness,
      Brightness.dark,
    );
    await tester.tap(find.byKey(const ValueKey('arena-power')));
    await tester.pump();
    expect(client.toggleCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Empty connection requires profile and explains import', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('Нет серверов'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('arena-power')));
    await tester.pumpAndSettle();
    expect(find.text('Провайдер'), findsOneWidget);
    expect(find.text('Сканировать'), findsOneWidget);
    expect(client.toggleCalls, 0);
  });

  testWidgets('All six screens fit real laptop window', (tester) async {
    client.profiles.add(
      const Profile(
        'hy2://secret@192.0.2.1:443#Test',
        'Тестовый сервер',
        id: 'test',
      ),
    );
    await mount(tester, size: const Size(668, 858));
    for (final index in [0, 1, 3, 5]) {
      await tester.tap(find.byKey(ValueKey('nav-$index')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: pages[index].$1);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Narrow window keeps dock and routing reachable', (tester) async {
    await mount(tester, size: const Size(480, 900));
    await tester.tap(find.byKey(const ValueKey('nav-3')));
    await tester.pumpAndSettle();
    expect(find.text('Профили маршрутизации'), findsWidgets);
    await tester.drag(find.byType(ListView).last, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Search filters servers and profile actions change favorites', (
    tester,
  ) async {
    client.profiles.addAll(const [
      Profile('hy2://secret@192.0.2.1:443#Alpha', 'Alpha', id: 'alpha'),
      Profile('hy2://secret@192.0.2.2:443#Beta', 'Beta', id: 'beta'),
    ]);
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('nav-1')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Поиск серверов...'),
      'Alpha',
    );
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((w) => w is Text && w.data == 'Alpha'),
      findsOneWidget,
    );
    expect(find.text('Beta'), findsNothing);
    await tester.tap(find.byTooltip('Параметры сервера и QR'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byTooltip('В избранное'),
      ),
    );
    await tester.pumpAndSettle();
    expect(client.profiles.first.favorite, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Running core is not presented as verified connection', (
    tester,
  ) async {
    client.profiles.add(
      const Profile(
        'hy2://secret@192.0.2.1:443#Test',
        'Тестовый сервер',
        id: 'test',
      ),
    );
    client.state = 'running';
    client.mode = 'proxy';
    await mount(tester);
    expect(find.textContaining('Ядро'), findsWidgets);
    expect(find.text('Соединение проверено'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('arena-power')));
    await tester.pump();
    expect(client.toggleCalls, 1);
  });
}
