// ignore_for_file: deprecated_member_use, implementation_imports
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tray_manager/src/menu.dart' as tm;
import 'package:velum/client.dart';
import 'package:velum/main.dart';
import 'package:flutter/widgets.dart';
import 'package:velum/tray_service.dart';

// Reuse the controlled, memory-only OS/daemon fixtures from the F6-F7 tests.
import 'proxy_client_lifecycle_test.dart'
    show ControlledProxy, ControlledDaemon;
import 'tray_service_test.dart'
    show MockTrayManagerAdapter, MockWindowActionAdapter;

class TestExitClient extends VelumClient {
  TestExitClient(
    Directory directory,
    ControlledProxy proxy,
    ControlledDaemon daemon,
  ) : super(
        directory: directory,
        proxyManager: proxy,
        daemonRequest: daemon.request,
        proxyListenerProbe: daemon.probe,
      );
  int prepares = 0;
  int finishes = 0;
  int cancels = 0;
  final prepareStarted = Completer<void>();
  @override
  Future<void> prepareForExit({bool retry = false}) {
    prepares++;
    if (!prepareStarted.isCompleted) prepareStarted.complete();
    return super.prepareForExit(retry: retry);
  }

  @override
  Future<void> finishExit({bool force = false}) {
    finishes++;
    return super.finishExit(force: force);
  }

  @override
  Future<void> cancelExit() {
    cancels++;
    return super.cancelExit();
  }
}

class TestExitInteraction implements ExitInteraction {
  bool confirm = true;
  int confirmations = 0;
  int failures = 0;
  Future<ExitFailureAction> Function(Object)? failure;
  @override
  Future<bool> confirmProtectionLoss() async {
    confirmations++;
    return confirm;
  }

  @override
  Future<ExitFailureAction> cleanupFailed(Object error) async {
    failures++;
    return failure == null ? ExitFailureAction.cancel : await failure!(error);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late ControlledProxy proxy;
  late ControlledDaemon daemon;
  late TestExitClient client;
  late MockTrayManagerAdapter tray;
  late MockWindowActionAdapter window;
  late TestExitInteraction interaction;
  late VelumTrayService service;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('velum-close-test-');
    proxy = ControlledProxy(directory);
    daemon = ControlledDaemon();
    client = TestExitClient(directory, proxy, daemon);
    client.settings['systemProxy'] = true;
    client.settings['minimizeToTray'] = false;
    await client.importText('hy2://fixture@192.0.2.1:443#Fixture');
    tray = MockTrayManagerAdapter(supported: true);
    window = MockWindowActionAdapter();
    interaction = TestExitInteraction();
    service = VelumTrayService(
      client: client,
      trayAdapter: tray,
      windowAdapter: window,
      exitInteraction: interaction,
    );
    await service.initialize();
  });
  tearDown(() async {
    for (final gate in [
      proxy.applyGate,
      proxy.restoreGate,
      proxy.recoveryGate,
    ]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    if (daemon.connectGate != null && !daemon.connectGate!.isCompleted) {
      daemon.connectGate!.complete({
        'state': 'disconnected',
        'mode': 'proxy',
        'serviceMode': 'systemd',
      });
    }
    service.dispose();
    await client.shutdown();
    client.dispose();
    await directory.delete(recursive: true);
  });
  Future<void> active() async {
    await client.refresh();
    expect(proxy.actual['mode'], 'manual');
  }

  test('only explicit confirmation authorizes native destruction', () async {
    const channel = MethodChannel('velum/window');
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await const MethodChannelWindowAdapter().close();
    expect(calls, ['closeConfirmed']);
  });

  test('native channel close request waits for proxy cleanup before native confirmation', () async {
    await active();
    service.dispose();
    const channel = MethodChannel('velum/window');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'closeConfirmed') {
        expect(proxy.actual, ControlledProxy.original);
        expect(await proxy.backupFile.exists(), isFalse);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    service = VelumTrayService(
      client: client,
      trayAdapter: MockTrayManagerAdapter(supported: false),
      windowAdapter: const MethodChannelWindowAdapter(),
      exitInteraction: interaction,
    );
    await service.initialize();
    final response = Completer<void>();
    messenger.handlePlatformMessage(
      'velum/window',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('closeRequested'),
      ),
      (_) => response.complete(),
    );
    await response.future;
    expect(calls.where((method) => method == 'closeConfirmed'), hasLength(1));
    expect(client.prepares, 1);
  });

  test('tray Exit and repeated X share one cleanup and one destroy', () async {
    await active();
    proxy.restoreGate = Completer<void>();
    service.onTrayMenuItemClick(tm.MenuItem(key: 'exit', label: 'Выход'));
    await proxy.restoreStarted.future;
    final repeated = service.handleWindowClose();
    final repeatedExit = service.exitApplication();
    expect(client.prepares, 1);
    expect(interaction.confirmations, 1);
    expect(window.closeCalls, 0);
    expect(tray.destroyCalls, 0);
    proxy.restoreGate!.complete();
    await Future.wait([repeated, repeatedExit]);
    expect(window.closeCalls, 1);
    expect(proxy.restores, 1);
    expect(tray.destroyCalls, 1);
    service.dispose();
    await Future<void>.value();
    expect(tray.destroyCalls, 1);
  });

  test('working tray hides X without touching VPN or proxy', () async {
    await active();
    client.settings['minimizeToTray'] = true;
    final protected = {...proxy.actual};
    await window.closeRequest!();
    expect(window.hideCalls, 1);
    expect(client.prepares, 0);
    expect(proxy.actual, protected);
    expect(daemon.disconnects, 0);
    expect(interaction.confirmations, 0);
  });

  test(
    'platform support without a live tray host does not permit hiding',
    () async {
      await active();
      client.settings['minimizeToTray'] = true;
      tray.hostAvailable = false;
      await service.handleWindowClose();
      expect(window.hideCalls, 0);
      expect(window.closeCalls, 1);
      expect(proxy.actual, ControlledProxy.original);
    },
  );

  test('tray Exit always exits even when minimizeToTray is enabled', () async {
    await active();
    client.settings['minimizeToTray'] = true;
    await service.exitApplication();
    expect(window.hideCalls, 0);
    expect(window.closeCalls, 1);
    expect(proxy.actual, ControlledProxy.original);
  });

  test('Alt+F4 during pending apply waits then restores', () async {
    proxy.applyGate = Completer<void>();
    await client.reconnect();
    await proxy.applyStarted.future;
    final closing = window.closeRequest!();
    await client.prepareStarted.future;
    expect(window.closeCalls, 0);
    proxy.applyGate!.complete();
    await closing;
    expect(proxy.actual, ControlledProxy.original);
    expect(proxy.maxMutations, 1);
    expect(window.closeCalls, 1);
  });

  test('close during pending Connect rejects late running response', () async {
    daemon.state = 'disconnected';
    daemon.listener = false;
    daemon.connectGate = Completer<Map<String, dynamic>>();
    final connecting = client.reconnect();
    await daemon.connectStarted.future;
    final closing = service.handleWindowClose();
    await client.prepareStarted.future;
    daemon.connectGate!.complete({
      'state': 'running',
      'mode': 'proxy',
      'serviceMode': 'systemd',
    });
    await Future.wait([connecting, closing]);
    expect(proxy.applies, 0);
    expect(proxy.actual, ControlledProxy.original);
    expect(window.closeCalls, 1);
    expect(daemon.disconnects, 0);
  });

  test(
    'exit during Disconnect joins pending restore without a second mutation',
    () async {
      await active();
      proxy.restoreGate = Completer<void>();
      await client.disconnect();
      await proxy.restoreStarted.future;
      final closing = service.handleWindowClose();
      await client.prepareStarted.future;
      proxy.restoreGate!.complete();
      await closing;
      expect(proxy.actual, ControlledProxy.original);
      expect(proxy.restores, 1);
      expect(window.closeCalls, 1);
    },
  );

  test('restoration failure retries only after explicit user action', () async {
    await active();
    proxy.failRestore = true;
    interaction.failure = (error) async {
      expect(window.closeCalls, 0);
      expect(tray.destroyCalls, 0);
      expect(await proxy.backupFile.exists(), isTrue);
      proxy.failRestore = false;
      return ExitFailureAction.retry;
    };
    await service.exitApplication();
    expect(interaction.failures, 1);
    expect(proxy.restores, 2);
    expect(proxy.actual, ControlledProxy.original);
    expect(window.closeCalls, 1);
    expect(tray.destroyCalls, 1);
  });

  test(
    'cancel after failed cleanup keeps GUI usable and reconciles protection',
    () async {
      await active();
      proxy.failRestore = true;
      interaction.failure = (_) async => ExitFailureAction.cancel;
      await service.exitApplication();
      expect(window.closeCalls, 0);
      expect(tray.destroyCalls, 0);
      expect(client.cancels, 1);
      expect(proxy.actual['mode'], 'manual');
      expect(daemon.disconnects, 0);
      proxy.failRestore = false;
      await client.setSystemProxyEnabled(false);
      expect(proxy.actual, ControlledProxy.original);
    },
  );

  test('cancel protection warning performs no cleanup', () async {
    await active();
    interaction.confirm = false;
    await service.exitApplication();
    expect(client.prepares, 0);
    expect(window.closeCalls, 0);
    expect(proxy.actual['mode'], 'manual');
    expect(tray.destroyCalls, 0);
  });

  test('explicit force exit preserves the failed recovery journal', () async {
    await active();
    proxy.failRestore = true;
    interaction.failure = (_) async => ExitFailureAction.force;
    await service.exitApplication();
    expect(window.closeCalls, 1);
    expect(proxy.actual['mode'], 'manual');
    expect(await proxy.backupFile.exists(), isTrue);
    final record = jsonDecode(await proxy.backupFile.readAsString()) as Map;
    expect(record['original']['raw'], ControlledProxy.original);
  });

  test('local console core is disconnected once after proxy cleanup', () async {
    daemon.serviceMode = 'console';
    await active();
    await service.exitApplication();
    await service.exitApplication();
    expect(daemon.disconnects, 1);
    expect(proxy.actual, ControlledProxy.original);
    expect(window.closeCalls, 1);
  });

  for (final mode in ['systemd', 'windows-service']) {
    test('$mode daemon continues running after GUI exit', () async {
      daemon.serviceMode = mode;
      await active();
      await service.exitApplication();
      expect(daemon.disconnects, 0);
      expect(daemon.state, 'running');
      expect(window.closeCalls, 1);
    });
  }

  test(
    'unavailable console daemon requires a decision instead of silent exit',
    () async {
      daemon.serviceMode = 'console';
      await active();
      daemon.offline = true;
      interaction.failure = (_) async => ExitFailureAction.cancel;
      await service.exitApplication();
      expect(interaction.failures, 1);
      expect(window.closeCalls, 0);
      expect(tray.destroyCalls, 0);
      expect(client.cancels, 1);
    },
  );

  test('no tray support still installs a native close handler', () async {
    service.dispose();
    service = VelumTrayService(
      client: client,
      trayAdapter: MockTrayManagerAdapter(supported: false),
      windowAdapter: window,
      exitInteraction: interaction,
    );
    await service.initialize();
    expect(window.closeRequest, isNotNull);
    await window.closeRequest!();
    expect(window.hideCalls, 0);
    expect(window.closeCalls, 1);
  });

  test(
    'already destroyed native window is an idempotent confirmation',
    () async {
      const channel = MethodChannel('velum/window');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(
          code: 'window',
          message: 'window is not available',
        ),
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await const MethodChannelWindowAdapter().close();
    },
  );
  testWidgets('Flutter titlebar X enters the same close controller', (
    tester,
  ) async {
    await tester.pumpWidget(
      VelumApp(client: client, initialize: false, trayService: service),
    );
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('close'));
      await client.prepareStarted.future;
      expect(client.prepares, 1);
      await service.exitApplication();
    });
    expect(window.closeCalls, 1);
    expect(tray.destroyCalls, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
