import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velum/client.dart';
import 'package:velum/main.dart';
import 'package:velum/network_mode_control.dart';

class ModeClient extends VelumClient {
  ModeClient() : super(directory: Directory.systemTemp);
  @override
  Future<void> saveSettings(Map<String, dynamic> value) async {
    settings.addAll(value);
    notifyListeners();
  }

  @override
  Future<LinuxServiceState> checkLinuxServiceState() async =>
      LinuxServiceState.notInstalled;
}

void main() {
  Future<void> mount(WidgetTester tester, ModeClient client) async {
    tester.view.physicalSize = const Size(480, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NetworkModeControl(client: client)),
      ),
    );
  }

  testWidgets(
    'Running proxy shows system traffic warning and actual endpoint',
    (tester) async {
      final client = ModeClient()
        ..state = 'running'
        ..mode = 'proxy'
        ..status = {
          'tunAllowed': false,
          'verified': true,
          'proxy': '127.0.0.1:2080',
        };
      await mount(tester, client);
      expect(
        find.textContaining('Системный трафик не перенаправляется'),
        findsOneWidget,
      );
      expect(find.text('SOCKS5 / HTTP: 127.0.0.1:2080'), findsOneWidget);
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byKey(const ValueKey('network-mode-picker')),
            )
            .onChanged,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
      client.dispose();
    },
  );
  testWidgets(
    'TUN selection requires capability and persists configured mode when available',
    (tester) async {
      final client = ModeClient()..state = 'disconnected';
      await mount(tester, client);
      var picker = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('network-mode-picker')),
      );
      expect(
        picker.items!.singleWhere((item) => item.value == 'tun').enabled,
        false,
      );
      expect(find.text('Как включить VPN для всей системы'), findsOneWidget);
      client.status = {'tunAllowed': true};
      client.notifyListeners();
      await tester.pumpAndSettle();
      picker = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('network-mode-picker')),
      );
      expect(
        picker.items!.singleWhere((item) => item.value == 'tun').enabled,
        true,
      );
      await tester.tap(find.byKey(const ValueKey('network-mode-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Весь трафик · TUN').last);
      await tester.pumpAndSettle();
      expect(client.settings['mode'], 'tun');
      expect(find.text('Системный туннель TUN'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      client.dispose();
    },
  );
  testWidgets('Main connection mode explanation fits a narrow desktop', (
    tester,
  ) async {
    final client = ModeClient()..state = 'disconnected';
    client.profiles.add(
      const Profile(
        'vless://00000000-0000-4000-8000-000000000001@192.0.2.1:443',
        'Test',
        id: 'test',
      ),
    );
    tester.view.physicalSize = const Size(480, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(VelumApp(client: client, initialize: false));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('network-mode-status')), findsOneWidget);
    expect(
      find.textContaining('Системный трафик не перенаправляется'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    client.dispose();
  });
  testWidgets('Service management dialog shows Linux states', (tester) async {
    final client = ModeClient()..state = 'disconnected';
    await mount(tester, client);
    await tester.tap(find.text('Как включить VPN для всей системы'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('службой'), findsWidgets);
    expect(find.text('Закрыть'), findsOneWidget);
    await tester.tap(find.text('Закрыть'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    client.dispose();
  });
}
