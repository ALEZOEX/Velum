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

  testWidgets('Empty connection requires profile and explains import', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('Сервер не выбран'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Подключить'),
    );
    expect(button.onPressed, isNull);
    await tester.tap(find.text('Добавить сервер'));
    await tester.pumpAndSettle();
    expect(find.text('Ссылка, подписка или список серверов'), findsOneWidget);
    expect(find.text('Из файла'), findsOneWidget);
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
    for (var index = 0; index < pages.length; index++) {
      await tester.tap(find.byKey(ValueKey('nav-$index')));
      await tester.pumpAndSettle();
      expect(find.text(pages[index].$1), findsOneWidget);
      expect(tester.takeException(), isNull, reason: pages[index].$1);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Narrow window uses drawer and routing remains reachable', (
    tester,
  ) async {
    await mount(tester, size: const Size(480, 900));
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-3')));
    await tester.pumpAndSettle();
    expect(find.text('Режим маршрутизации'), findsOneWidget);
    await tester.drag(find.byType(ListView).last, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Сохранить исключения'), findsOneWidget);
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
      find.widgetWithText(TextField, 'Найти сервер'),
      'Alpha',
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byType(ListTile), matching: find.text('Alpha')),
      findsOneWidget,
    );
    expect(find.text('Beta'), findsNothing);
    await tester.tap(find.byTooltip('Действия с сервером'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('В избранное'));
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
    expect(find.text('Ядро запущено'), findsOneWidget);
    expect(find.text('Соединение проверено'), findsNothing);
    await tester.tap(find.text('Отключить'));
    await tester.pump();
    expect(client.toggleCalls, 1);
  });
}
