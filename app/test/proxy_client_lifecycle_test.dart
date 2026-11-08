import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:velum/client.dart';

class ControlledProxy extends SystemProxyManager {
  ControlledProxy(Directory directory) : super(configDirectory: directory);
  static const original = {
    'mode': 'auto',
    'http': 'corporate:80',
    'https': 'secure:443',
    'socks': '',
  };
  Map<String, dynamic> actual = {...original};
  Completer<void>? applyGate;
  Completer<void>? restoreGate;
  Completer<void>? recoveryGate;
  final applyStarted = Completer<void>();
  final restoreStarted = Completer<void>();
  final recoveryStarted = Completer<void>();
  final applyFinished = Completer<void>();
  int applies = 0;
  int restores = 0;
  int recoveries = 0;
  int mutations = 0;
  int maxMutations = 0;
  bool failRestore = false;
  @override
  bool get isSupported => true;
  @override
  String get environmentName => 'Controlled memory proxy';
  @override
  Future<SystemProxyConfig> readCurrentConfig() async => SystemProxyConfig(
    enabled: actual['mode'] == 'manual',
    host: '127.0.0.1',
    port: 2080,
    desktopEnvironment: environmentName,
    raw: jsonDecode(jsonEncode(actual)),
  );
  Future<void> _mutate(Future<void> Function() body) async {
    mutations++;
    if (mutations > maxMutations) maxMutations = mutations;
    try {
      await body();
    } finally {
      mutations--;
    }
  }

  @override
  Future<void> applyPlatformProxy({
    required String host,
    required int port,
    List<String> exceptions = const [],
  }) => _mutate(() async {
    applies++;
    final target = {
      'mode': 'manual',
      'http': '$host:$port',
      'https': '$host:$port',
      'socks': '$host:$port',
    };
    await changeRaw(target, () async {
      if (!applyStarted.isCompleted) applyStarted.complete();
      if (applyGate != null) await applyGate!.future;
      actual = target;
    });
    if (!applyFinished.isCompleted) applyFinished.complete();
  });
  @override
  Future<void> restorePlatformProxy(SystemProxyConfig backup) =>
      _mutate(() async {
        restores++;
        if (!restoreStarted.isCompleted) restoreStarted.complete();
        if (restoreGate != null) await restoreGate!.future;
        if (failRestore) {
          throw const FormatException('controlled restore failure');
        }
        await changeRaw(backup.raw, () async {
          actual = {...backup.raw};
        });
      });
  @override
  Future<void> disablePlatformProxy() =>
      throw StateError('No blind disable allowed');
  @override
  Future<bool> recoverIfOrphaned({
    required String host,
    required int port,
    bool isVpnRunning = false,
    bool isProxyInboundActive = false,
    bool userWantsProxy = false,
  }) async {
    recoveries++;
    if (!recoveryStarted.isCompleted) recoveryStarted.complete();
    if (recoveryGate != null) await recoveryGate!.future;
    return super.recoverIfOrphaned(
      host: host,
      port: port,
      isVpnRunning: isVpnRunning,
      isProxyInboundActive: isProxyInboundActive,
      userWantsProxy: userWantsProxy,
    );
  }
}

class ControlledDaemon {
  String state = 'running';
  String serviceMode = 'systemd';
  bool listener = true;
  bool offline = false;
  int polls = 0;
  int disconnects = 0;
  Completer<Map<String, dynamic>>? pollGate;
  final pollStarted = Completer<void>();
  Completer<Map<String, dynamic>>? connectGate;
  final connectStarted = Completer<void>();
  Future<Map<String, dynamic>> request(
    String path,
    Map<String, dynamic>? body,
  ) async {
    if (path == 'status') {
      polls++;
      if (!pollStarted.isCompleted) pollStarted.complete();
      if (pollGate != null) return pollGate!.future;
      if (offline) throw const SocketException('controlled API outage');
    }
    if (path == 'connect') {
      if (!connectStarted.isCompleted) connectStarted.complete();
      if (connectGate != null) return connectGate!.future;
      state = 'running';
      listener = true;
    }
    if (path == 'disconnect') {
      disconnects++;
      state = 'disconnected';
      listener = false;
    }
    return {
      'state': state,
      'mode': 'proxy',
      'proxy': '127.0.0.1:2080',
      'serviceMode': serviceMode,
      'error': '',
    };
  }

  Future<bool> probe(int port) async => listener;
}

void main() {
  late Directory directory;
  late ControlledProxy proxy;
  late ControlledDaemon daemon;
  late VelumClient client;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('velum-proxy-lifecycle-');
    proxy = ControlledProxy(directory);
    daemon = ControlledDaemon();
    client = VelumClient(
      directory: directory,
      proxyManager: proxy,
      daemonRequest: daemon.request,
      proxyListenerProbe: daemon.probe,
    );
    client.settings['systemProxy'] = true;
    await client.importText('hy2://test@192.0.2.1:443#Fixture');
  });
  tearDown(() async {
    for (final gate in [
      proxy.applyGate,
      proxy.restoreGate,
      proxy.recoveryGate,
    ]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    for (final gate in [daemon.connectGate, daemon.pollGate]) {
      if (gate != null && !gate.isCompleted) {
        gate.complete({
          'state': 'disconnected',
          'mode': 'proxy',
          'serviceMode': 'systemd',
        });
      }
    }
    await client.shutdown();
    client.dispose();
    await directory.delete(recursive: true);
  });

  Future<void> startProxy() async {
    await client.refresh();
    expect(proxy.actual['mode'], 'manual');
  }

  test(
    'Connect -> Disconnect before apply finishes restores original settings',
    () async {
      proxy.applyGate = Completer<void>();
      await client.reconnect();
      await proxy.applyStarted.future;
      await client.disconnect();
      proxy.applyGate!.complete();
      await client.proxyIdle;
      expect(client.state, 'disconnected');
      expect(proxy.actual, ControlledProxy.original);
      expect(proxy.maxMutations, 1);
      expect(await proxy.backupFile.exists(), isFalse);
    },
  );

  test(
    'Disconnect -> Connect before restore finishes ends at latest proxy intent',
    () async {
      await startProxy();
      proxy.restoreGate = Completer<void>();
      await client.disconnect();
      await proxy.restoreStarted.future;
      await client.reconnect();
      proxy.restoreGate!.complete();
      await client.proxyIdle;
      expect(client.state, 'running');
      expect(proxy.actual, {
        'mode': 'manual',
        'http': '127.0.0.1:2080',
        'https': '127.0.0.1:2080',
        'socks': '127.0.0.1:2080',
      });
      expect(proxy.maxMutations, 1);
      expect(await proxy.backupFile.exists(), isTrue);
    },
  );

  test('rapid proxy on -> off cannot be overwritten by late apply', () async {
    client.state = 'running';
    client.mode = 'proxy';
    proxy.applyGate = Completer<void>();
    final on = client.setSystemProxyEnabled(true);
    await proxy.applyStarted.future;
    final off = client.setSystemProxyEnabled(false);
    proxy.applyGate!.complete();
    await Future.wait([on, off]);
    expect(client.settings['systemProxy'], isFalse);
    expect(proxy.actual, ControlledProxy.original);
    expect(proxy.maxMutations, 1);
  });

  test('rapid proxy off -> on cannot be overwritten by late restore', () async {
    await startProxy();
    proxy.restoreGate = Completer<void>();
    final off = client.setSystemProxyEnabled(false);
    await proxy.restoreStarted.future;
    final on = client.setSystemProxyEnabled(true);
    proxy.restoreGate!.complete();
    await Future.wait([off, on]);
    expect(client.settings['systemProxy'], isTrue);
    expect(proxy.actual['mode'], 'manual');
    expect(proxy.actual['https'], '127.0.0.1:2080');
    expect(proxy.maxMutations, 1);
  });

  test('Crash Recovery and Connect share one serial queue', () async {
    await proxy.enable(host: '127.0.0.1', port: 2080);
    proxy.recoveryGate = Completer<void>();
    final initial = client.initialize();
    await proxy.recoveryStarted.future;
    final appliesBefore = proxy.applies;
    await client.reconnect();
    expect(proxy.applies, appliesBefore);
    proxy.recoveryGate!.complete();
    await initial;
    await client.proxyIdle;
    expect(proxy.actual['mode'], 'manual');
    expect(proxy.recoveries, 1);
    expect(proxy.maxMutations, 1);
    final backup = jsonDecode(await proxy.backupFile.readAsString()) as Map;
    expect(backup['original']['raw'], ControlledProxy.original);
  });

  test('API outage with dead listener restores owned proxy', () async {
    await startProxy();
    daemon.offline = true;
    daemon.listener = false;
    await client.refresh();
    expect(client.state, 'offline');
    expect(proxy.actual, ControlledProxy.original);
    expect(await proxy.backupFile.exists(), isFalse);
  });

  test(
    'temporary API outage preserves proxy while listener is alive',
    () async {
      await startProxy();
      final active = {...proxy.actual};
      daemon.offline = true;
      await client.refresh();
      expect(client.state, 'offline');
      expect(proxy.actual, active);
      expect(proxy.restores, 0);
      expect(await proxy.backupFile.exists(), isTrue);
      daemon.offline = false;
      await client.refresh();
      expect(client.state, 'running');
      expect(proxy.actual, active);
    },
  );

  test('listener disappearing later triggers restore despite unchanged offline state', () async {
    await startProxy();
    daemon.offline = true;
    await client.refresh();
    expect(proxy.actual['mode'], 'manual');
    daemon.listener = false;
    await client.refresh();
    expect(proxy.actual, ControlledProxy.original);
    expect(proxy.restores, 1);
  });

  test(
    'failed outage restore keeps backup, error and does not retry forever',
    () async {
      await startProxy();
      proxy.failRestore = true;
      daemon.offline = true;
      daemon.listener = false;
      await client.refresh();
      expect(proxy.actual['mode'], 'manual');
      expect(await proxy.backupFile.exists(), isTrue);
      expect(client.systemProxyStatus, SystemProxyStatus.error);
      expect(client.message, contains('controlled restore failure'));
      for (var i = 0; i < 5; i++) {
        await client.refresh();
      }
      expect(proxy.restores, 1);
      expect(client.message, contains('controlled restore failure'));
      // A new confirmed daemon state permits one new attempt.
      proxy.failRestore = false;
      daemon.offline = false;
      daemon.state = 'disconnected';
      await client.refresh();
      expect(proxy.actual, ControlledProxy.original);
      expect(await proxy.backupFile.exists(), isFalse);
    },
  );

  test('foreign proxy update during restore is a conflict and is never overwritten', () async {
    await startProxy();
    proxy.restoreGate = Completer<void>();
    daemon.offline = true;
    daemon.listener = false;
    final outage = client.refresh();
    await proxy.restoreStarted.future;
    proxy.actual = {...ControlledProxy.original, 'https': 'foreign:8080'};
    final foreign = {...proxy.actual};
    proxy.restoreGate!.complete();
    await outage;
    expect(client.systemProxyStatus, SystemProxyStatus.conflict);
    expect(proxy.actual, foreign);
    expect(await proxy.backupFile.exists(), isTrue);
  });

  test('repeated and concurrent initialize performs recovery and initial poll once', () async {
    final first = client.initialize();
    final second = client.initialize();
    expect(identical(first, second), isTrue);
    await Future.wait([first, second]);
    await client.initialize();
    expect(daemon.polls, 1);
    expect(proxy.recoveries, 1);
    expect(proxy.applies, 1);
    expect(proxy.actual['mode'], 'manual');
  });

  test('dispose drains pending apply before final restore without late notifications', () async {
    var notifications = 0;
    client.addListener(() => notifications++);
    proxy.applyGate = Completer<void>();
    await client.reconnect();
    await proxy.applyStarted.future;
    client.dispose();
    final before = notifications;
    final closing = client.shutdown();
    proxy.applyGate!.complete();
    await closing;
    expect(proxy.actual, ControlledProxy.original);
    expect(proxy.maxMutations, 1);
    expect(notifications, before);
    final applies = proxy.applies;
    await client.refresh();
    await client.setSystemProxyEnabled(true);
    expect(proxy.applies, applies);
  });

  test(
    'many API errors preserve a live listener and do not duplicate writes',
    () async {
      await startProxy();
      daemon.offline = true;
      final active = {...proxy.actual};
      for (var i = 0; i < 8; i++) {
        await client.refresh();
      }
      expect(proxy.actual, active);
      expect(proxy.applies, 1);
      expect(proxy.restores, 0);
    },
  );

  test('explicit Disconnect survives an unfinished Connect response', () async {
    daemon.state = 'disconnected';
    daemon.listener = false;
    daemon.connectGate = Completer<Map<String, dynamic>>();
    final connecting = client.reconnect();
    await daemon.connectStarted.future;
    final disconnecting = client.disconnect();
    daemon.connectGate!.complete({
      'state': 'running',
      'mode': 'proxy',
      'serviceMode': 'systemd',
      'proxy': '127.0.0.1:2080',
    });
    await Future.wait([connecting, disconnecting]);
    await client.proxyIdle;
    expect(client.state, 'disconnected');
    expect(proxy.actual, ControlledProxy.original);
    expect(proxy.applies, 0);
  });

  test('late status poll cannot resurrect a disconnected proxy', () async {
    await startProxy();
    daemon.pollGate = Completer<Map<String, dynamic>>();
    final polling = client.refresh();
    // An explicit command changes the daemon generation before its response.
    await client.disconnect();
    daemon.pollGate!.complete({
      'state': 'running',
      'mode': 'proxy',
      'serviceMode': 'systemd',
      'proxy': '127.0.0.1:2080',
    });
    await polling;
    await client.proxyIdle;
    expect(client.state, 'disconnected');
    expect(proxy.actual, ControlledProxy.original);
  });

  test(
    'connecting -> offline -> disconnected uses the same reconciliation',
    () async {
      await proxy.enable(host: '127.0.0.1', port: 2080);
      daemon.state = 'connecting';
      await client.refresh();
      expect(proxy.actual['mode'], 'manual');
      daemon.offline = true;
      daemon.listener = false;
      await client.refresh();
      expect(proxy.actual, ControlledProxy.original);
      daemon.offline = false;
      daemon.state = 'disconnected';
      await client.refresh();
      expect(proxy.actual, ControlledProxy.original);
    },
  );
  test('closing a service-managed session restores proxy but keeps daemon autonomous', () async {
    await startProxy();
    await client.shutdown(disconnectConsole: true);
    expect(proxy.actual, ControlledProxy.original);
    expect(daemon.state, 'running');
    expect(daemon.disconnects, 0);
  });

  test(
    'a failed probe does not poison the queue for a later explicit action',
    () async {
      await startProxy();
      final broken = VelumClient(
        directory: directory,
        proxyManager: proxy,
        daemonRequest: daemon.request,
        proxyListenerProbe: (_) async =>
            throw const SocketException('probe failed'),
      );
      try {
        broken.settings['systemProxy'] = true;
        await broken.refresh();
        expect(broken.systemProxyStatus, SystemProxyStatus.error);
        expect(proxy.actual['mode'], 'manual');
      } finally {
        await broken.shutdown();
        broken.dispose();
      }
      await client.setSystemProxyEnabled(false);
      expect(proxy.actual, ControlledProxy.original);
    },
  );
  test('shutdown during initial API request rejects late startup and further initialization', () async {
    daemon.pollGate = Completer<Map<String, dynamic>>();
    final initializing = client.initialize();
    await daemon.pollStarted.future;
    final closing = client.shutdown();
    daemon.pollGate!.complete({
      'state': 'running',
      'mode': 'proxy',
      'serviceMode': 'systemd',
    });
    await Future.wait([initializing, closing]);
    await client.initialize();
    await client.refresh();
    expect(daemon.polls, 1);
    expect(proxy.applies, 0);
    expect(proxy.actual, ControlledProxy.original);
    expect(await proxy.backupFile.exists(), isFalse);
  });
  test('orderly application exit disconnects an owned console session after draining proxy', () async {
    daemon.serviceMode = 'console';
    await startProxy();
    await client.shutdown(disconnectConsole: true);
    expect(proxy.actual, ControlledProxy.original);
    expect(daemon.disconnects, 1);
    expect(daemon.state, 'disconnected');
  });
}
