// ignore_for_file: implementation_imports, deprecated_member_use
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tray_manager/src/menu.dart' as tm;
import 'package:tray_manager/src/tray_listener.dart' as tm;
import 'package:velum/client.dart';
import 'package:velum/tray_service.dart';

class MockTrayManagerAdapter implements TrayManagerAdapter {
  MockTrayManagerAdapter({this.supported = true});

  final bool supported;

  @override
  bool get isSupported => supported;

  int destroyCalls = 0;
  int setIconCalls = 0;
  int setMenuCalls = 0;
  String currentIcon = '';
  String currentTooltip = '';
  tm.Menu? currentMenu;
  final List<tm.TrayListener> listeners = [];

  @override
  Future<void> destroy() async {
    destroyCalls++;
  }

  @override
  Future<void> setIcon(String iconPath) async {
    setIconCalls++;
    currentIcon = iconPath;
  }

  @override
  Future<void> setToolTip(String toolTip) async {
    currentTooltip = toolTip;
  }

  @override
  Future<void> setContextMenu(tm.Menu menu) async {
    setMenuCalls++;
    currentMenu = menu;
  }

  @override
  void addListener(tm.TrayListener listener) {
    listeners.add(listener);
  }

  @override
  void removeListener(tm.TrayListener listener) {
    listeners.remove(listener);
  }
}

class MockWindowActionAdapter implements WindowActionAdapter {
  int showCalls = 0;
  int hideCalls = 0;
  int closeCalls = 0;
  bool visible = true;
  bool hideOnClose = false;

  @override
  Future<void> show() async {
    showCalls++;
    visible = true;
  }

  @override
  Future<void> hide() async {
    hideCalls++;
    visible = false;
  }

  @override
  Future<void> close() async {
    closeCalls++;
    visible = false;
  }

  @override
  Future<bool> isVisible() async => visible;

  @override
  Future<void> setHideOnClose(bool enable) async {
    hideOnClose = enable;
  }
}

void main() {
  late Directory tempDir;
  late VelumClient client;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('velum-tray-test-');
    client = VelumClient(directory: tempDir);
  });

  tearDown(() async {
    client.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('VelumTrayService Initialization & Availability', () {
    test('initializes and configures tray when supported', () async {
      final mockTray = MockTrayManagerAdapter(supported: true);
      final mockWindow = MockWindowActionAdapter();

      final service = VelumTrayService(
        client: client,
        trayAdapter: mockTray,
        windowAdapter: mockWindow,
      );

      await service.initialize();

      expect(service.isSupported, isTrue);
      expect(mockTray.listeners.contains(service), isTrue);
      expect(mockTray.currentIcon, contains('tray_disconnected.png'));
      expect(mockTray.currentTooltip, anyOf(contains('Отключено'), contains('Служба офлайн')));
      expect(mockWindow.hideOnClose, isTrue); // default minimizeToTray is true

      service.dispose();
      expect(mockTray.listeners.contains(service), isFalse);
      expect(mockTray.destroyCalls, 1);
    });

    test('gracefully handles environment without tray (e.g. Hyprland without panel)', () async {
      final mockTray = MockTrayManagerAdapter(supported: false);
      final mockWindow = MockWindowActionAdapter();

      final service = VelumTrayService(
        client: client,
        trayAdapter: mockTray,
        windowAdapter: mockWindow,
      );

      await service.initialize();

      expect(service.isSupported, isFalse);
      expect(mockTray.listeners, isEmpty);
      // Window close interception must be disabled if tray is absent
      expect(mockWindow.hideOnClose, isFalse);

      service.dispose();
    });
  });

  group('Tray Context Menu & Status Synchronization', () {
    test('menu items reflect disconnected, connecting, running, and error states', () async {
      final mockTray = MockTrayManagerAdapter(supported: true);
      final mockWindow = MockWindowActionAdapter();

      final service = VelumTrayService(
        client: client,
        trayAdapter: mockTray,
        windowAdapter: mockWindow,
      );
      await service.initialize();

      // 1. Disconnected state
      client.state = 'disconnected';
      await service.updateTray(force: true);

      var menu = mockTray.currentMenu!;
      expect(menu.items!.any((i) => i.key == 'open'), isTrue);
      expect(menu.items!.firstWhere((i) => i.key == 'toggle').label, 'Подключиться');
      expect(menu.items!.firstWhere((i) => i.key == 'status').label, 'Статус: Отключено');
      expect(mockTray.currentIcon, contains('tray_disconnected.png'));

      // 2. Connecting state
      client.state = 'connecting';
      await service.updateTray(force: true);
      menu = mockTray.currentMenu!;
      expect(menu.items!.firstWhere((i) => i.key == 'status').label, 'Статус: Подключение...');
      expect(mockTray.currentIcon, contains('tray_connecting.png'));

      // 3. Running state with active profile
      client.state = 'running';
      client.status['activeProfile'] = 'NL Amsterdam #1';
      await service.updateTray(force: true);
      menu = mockTray.currentMenu!;
      expect(menu.items!.firstWhere((i) => i.key == 'toggle').label, 'Отключиться');
      expect(menu.items!.firstWhere((i) => i.key == 'server').label, contains('NL Amsterdam #1'));
      expect(menu.items!.firstWhere((i) => i.key == 'status').label, 'Статус: Подключено');
      expect(mockTray.currentIcon, contains('tray_running.png'));

      // 4. Error state
      client.state = 'error';
      await service.updateTray(force: true);
      expect(mockTray.currentIcon, contains('tray_error.png'));
      expect(mockTray.currentTooltip, contains('Ошибка'));

      service.dispose();
    });

    test('does not spam native calls when only traffic statistics tick', () async {
      final mockTray = MockTrayManagerAdapter(supported: true);
      final mockWindow = MockWindowActionAdapter();

      final service = VelumTrayService(
        client: client,
        trayAdapter: mockTray,
        windowAdapter: mockWindow,
      );
      await service.initialize();

      final initialSetMenuCalls = mockTray.setMenuCalls;
      final initialSetIconCalls = mockTray.setIconCalls;

      // Simulate client telemetry tick without state change
      client.status['uploadTotal'] = 1048576;
      client.status['downloadTotal'] = 5242880;
      client.notifyListeners();

      // Allow microtask queue to process
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(mockTray.setMenuCalls, initialSetMenuCalls);
      expect(mockTray.setIconCalls, initialSetIconCalls);

      service.dispose();
    });
  });

  group('Window Close & Tray Click Actions', () {
    test('left click on tray icon restores window', () async {
      final mockTray = MockTrayManagerAdapter(supported: true);
      final mockWindow = MockWindowActionAdapter()..visible = false;

      final service = VelumTrayService(
        client: client,
        trayAdapter: mockTray,
        windowAdapter: mockWindow,
      );
      await service.initialize();

      service.onTrayIconMouseDown();
      await Future<void>.delayed(Duration.zero);

      expect(mockWindow.showCalls, 1);
      expect(mockWindow.visible, isTrue);

      service.dispose();
    });

    test('handleWindowClose hides window when minimizeToTray is enabled and tray is supported', () async {
      final mockTray = MockTrayManagerAdapter(supported: true);
      final mockWindow = MockWindowActionAdapter()..visible = true;

      final service = VelumTrayService(
        client: client,
        trayAdapter: mockTray,
        windowAdapter: mockWindow,
      );
      await service.initialize();

      await service.handleWindowClose();

      expect(mockWindow.hideCalls, 1);
      expect(mockWindow.closeCalls, 0);
      expect(mockWindow.visible, isFalse);

      service.dispose();
    });

    test('handleWindowClose does not hide window when tray is unsupported', () async {
      final mockTray = MockTrayManagerAdapter(supported: false);
      final mockWindow = MockWindowActionAdapter()..visible = true;

      final service = VelumTrayService(
        client: client,
        trayAdapter: mockTray,
        windowAdapter: mockWindow,
      );
      await service.initialize();

      await service.hideWindow();
      // Should not hide window into non-existent tray
      expect(mockWindow.hideCalls, 0);

      service.dispose();
    });

    test('menu items dispatch open and toggle actions', () async {
      final mockTray = MockTrayManagerAdapter(supported: true);
      final mockWindow = MockWindowActionAdapter()..visible = false;

      final service = VelumTrayService(
        client: client,
        trayAdapter: mockTray,
        windowAdapter: mockWindow,
      );
      await service.initialize();

      // Open item
      service.onTrayMenuItemClick(tm.MenuItem(key: 'open', label: 'Открыть Velum'));
      await Future<void>.delayed(Duration.zero);
      expect(mockWindow.showCalls, 1);

      service.dispose();
    });
  });
}
