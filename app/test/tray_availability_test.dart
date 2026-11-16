import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:velum/client.dart';
import 'package:velum/tray_service.dart';

import 'tray_service_test.dart'
    show MockTrayManagerAdapter, MockWindowActionAdapter;

class TrayOnlyClient extends VelumClient {
  TrayOnlyClient(Directory directory) : super(directory: directory);
  int exits = 0;
  @override
  Future<void> prepareForExit({bool retry = false}) async {}
  @override
  Future<void> finishExit({bool force = false}) async {
    exits++;
  }
}

class ControlledTray extends MockTrayManagerAdapter {
  bool registered = false;
  bool probeError = false;
  bool iconError = false;
  bool destroyError = false;
  int checks = 0;
  int pendingChecks = 0;
  int maxPendingChecks = 0;
  Future<bool> Function()? probe;
  @override
  Future<bool> isAvailable() async {
    checks++;
    pendingChecks++;
    if (pendingChecks > maxPendingChecks) maxPendingChecks = pendingChecks;
    try {
      if (probeError) throw StateError('D-Bus unavailable');
      return probe == null ? hostAvailable && registered : await probe!();
    } finally {
      pendingChecks--;
    }
  }

  @override
  Future<void> setIcon(String iconPath) async {
    if (iconError) throw StateError('transient icon failure');
    await super.setIcon(iconPath);
    registered = hostAvailable;
  }

  @override
  Future<void> destroy() async {
    if (destroyError) throw StateError('transient reset failure');
    registered = false;
    await super.destroy();
  }
}

class ControlledWindow extends MockWindowActionAdapter {
  Future<void> Function()? hiding;
  void Function()? hidden;
  bool showError = false;
  Future<void> Function()? showing;
  Future<bool> Function()? visibilityProbe;
  @override
  Future<bool> isVisible() async =>
      visibilityProbe == null ? visible : await visibilityProbe!();
  @override
  Future<void> hide() async {
    await hiding?.call();
    await super.hide();
    hidden?.call();
  }

  @override
  Future<void> show() async {
    await showing?.call();
    if (showError) throw StateError('native show temporarily failed');
    await super.show();
  }
}

class ManualTrayTimer implements Timer {
  ManualTrayTimer(this.callback);
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;
  @override
  void cancel() => isActive = false;
  void fire() {
    if (!isActive) return;
    isActive = false;
    tick++;
    callback();
  }
}

class TrayClock {
  final timers = <ManualTrayTimer>[];
  int get active => timers.where((timer) => timer.isActive).length;
  Timer schedule(Duration interval, void Function() callback) {
    expect(interval, const Duration(seconds: 1));
    final timer = ManualTrayTimer(callback);
    timers.add(timer);
    return timer;
  }

  void fire() => timers.firstWhere((timer) => timer.isActive).fire();
}

// One event turn drains the immediate mock futures; races use explicit gates.
Future<void> flushMicrotasks() => Future<void>.delayed(Duration.zero);

void main() {
  late Directory directory;
  late TrayOnlyClient client;
  late ControlledTray tray;
  late ControlledWindow window;
  late TrayClock clock;
  late VelumTrayService service;
  VelumTrayService createService({bool watchTray = true}) => VelumTrayService(
    client: client,
    trayAdapter: tray,
    windowAdapter: window,
    watchTray: watchTray,
    scheduleTrayCheck: clock.schedule,
  );
  setUp(() {
    directory = Directory.systemTemp.createTempSync('velum-tray-loss-');
    client = TrayOnlyClient(directory)..settings['minimizeToTray'] = true;
    tray = ControlledTray();
    window = ControlledWindow();
    clock = TrayClock();
    service = createService();
  });
  tearDown(() {
    service.dispose();
    client.dispose();
    directory.deleteSync(recursive: true);
  });

  test('absent tray at startup keeps the window accessible', () async {
    tray.hostAvailable = false;
    await service.initialize();
    await service.hideWindow();
    expect(window.visible, isTrue);
    expect(window.hideCalls, 0);
    expect(clock.active, 0);
  });
  test('late panel appearance reregisters on the next hide request', () async {
    tray.hostAvailable = false;
    await service.initialize();
    expect(tray.registered, isFalse);
    tray.hostAvailable = true;
    await service.hideWindow();
    expect(tray.registered, isTrue);
    expect(window.visible, isFalse);
    expect(clock.active, 1);
    expect(tray.listeners, [service]);
  });
  test('tray disappears before preflight: no hide', () async {
    await service.initialize();
    tray.hostAvailable = false;
    await service.hideWindow();
    expect(window.visible, isTrue);
    expect(window.hideCalls, 0);
    expect(clock.active, 0);
  });
  test(
    'loss between preflight and native hide reveals without exiting',
    () async {
      await service.initialize();
      window.hidden = () => tray.hostAvailable = false;
      await service.handleWindowClose();
      expect(window.hideCalls, 1);
      expect(window.visible, isTrue);
      expect(window.closeCalls, 0);
      expect(client.exits, 0);
      expect(clock.active, 0);
    },
  );
  test('loss immediately after hiding restores on bounded poll', () async {
    await service.initialize();
    await service.hideWindow();
    tray.hostAvailable = false;
    clock.fire();
    await flushMicrotasks();
    expect(window.visible, isTrue);
    expect(window.showCalls, 1);
    expect(clock.active, 0);
  });
  test(
    'loss of item registration after several healthy polls restores window',
    () async {
      await service.initialize();
      await service.hideWindow();
      for (var i = 0; i < 3; i++) {
        clock.fire();
        await flushMicrotasks();
        expect(window.visible, isFalse);
        expect(clock.active, 1);
      }
      tray.registered = false;
      clock.fire();
      await flushMicrotasks();
      expect(window.visible, isTrue);
      expect(clock.active, 0);
    },
  );
  test('returning panel permits another hide without restarting', () async {
    await service.initialize();
    await service.hideWindow();
    tray.hostAvailable = false;
    tray.registered = false;
    clock.fire();
    await flushMicrotasks();
    expect(window.visible, isTrue);
    tray.hostAvailable = true;
    await service.hideWindow();
    expect(tray.registered, isTrue);
    expect(window.visible, isFalse);
    expect(window.hideCalls, 2);
    expect(clock.active, 1);
  });
  test('concurrent requests and telemetry keep one observer', () async {
    await service.initialize();
    final started = Completer<void>();
    final gate = Completer<bool>();
    tray.probe = () {
      started.complete();
      return gate.future;
    };
    final requests = [
      service.hideWindow(),
      service.hideWindow(),
      service.hideWindow(),
    ];
    await started.future;
    tray.probe = null;
    gate.complete(true);
    await Future.wait(requests);
    expect(window.hideCalls, 1);
    expect(clock.active, 1);
    final checks = tray.checks;
    for (var i = 0; i < 10; i++) {
      client.status['uploadTotal'] = i;
      client.notifyListeners();
    }
    await flushMicrotasks();
    expect(tray.checks, checks);
    expect(clock.active, 1);
    expect(tray.maxPendingChecks, 1);
  });
  test('show supersedes an in-flight hide preflight', () async {
    await service.initialize();
    final started = Completer<void>();
    final gate = Completer<bool>();
    tray.probe = () {
      started.complete();
      return gate.future;
    };
    final hiding = service.hideWindow();
    await started.future;
    await service.showWindow();
    tray.probe = null;
    gate.complete(true);
    await hiding;
    expect(window.visible, isTrue);
    expect(window.hideCalls, 0);
    expect(clock.active, 0);
  });
  test('native hide completes before concurrent show', () async {
    await service.initialize();
    final started = Completer<void>();
    final gate = Completer<void>();
    window.hiding = () {
      started.complete();
      return gate.future;
    };
    final hiding = service.hideWindow();
    await started.future;
    final showing = service.showWindow();
    gate.complete();
    await Future.wait([hiding, showing]);
    expect(window.visible, isTrue);
    expect(window.showCalls, 1);
    expect(clock.active, 0);
  });
  test('hide during pending show keeps recovery armed', () async {
    await service.initialize();
    await service.hideWindow();
    final started = Completer<void>();
    final gate = Completer<void>();
    window.showing = () {
      started.complete();
      return gate.future;
    };
    final showing = service.showWindow();
    await started.future;
    final hiding = service.hideWindow();
    await flushMicrotasks();
    window.showing = null;
    gate.complete();
    await Future.wait([showing, hiding]);
    expect(window.visible, isFalse);
    expect(clock.active, 1);
    tray.hostAvailable = false;
    clock.fire();
    await flushMicrotasks();
    expect(window.visible, isTrue);
  });

  test('old poll cannot reveal a newer hidden session', () async {
    await service.initialize();
    await service.hideWindow();
    final started = Completer<void>();
    final gate = Completer<bool>();
    tray.probe = () {
      started.complete();
      return gate.future;
    };
    clock.fire();
    await started.future;
    await service.showWindow();
    tray.probe = null;
    final hiding = service.hideWindow();
    await flushMicrotasks();
    gate.complete(false);
    await hiding;
    expect(window.visible, isFalse);
    expect(window.showCalls, 1);
    expect(clock.active, 1);
  });
  test('stale visibility snapshot cannot stop a newer hide observer', () async {
    await service.initialize();
    await service.hideWindow();
    window.visible = true;
    final started = Completer<void>();
    final gate = Completer<bool>();
    window.visibilityProbe = () {
      started.complete();
      return gate.future;
    };
    clock.fire();
    await started.future;
    final hiding = service.hideWindow();
    await flushMicrotasks();
    window.visibilityProbe = null;
    gate.complete(true);
    await hiding;
    expect(window.visible, isFalse);
    expect(clock.active, 1);
  });

  test(
    'failed new preflight while hidden reveals instead of dropping observer',
    () async {
      await service.initialize();
      await service.hideWindow();
      tray.probeError = true;
      await service.hideWindow();
      expect(window.visible, isTrue);
      expect(clock.active, 0);
      expect(client.exits, 0);
    },
  );

  test('dispose cancels observer and reveals owned hidden window', () async {
    await service.initialize();
    await service.hideWindow();
    final timer = clock.timers.last;
    service.dispose();
    await flushMicrotasks();
    expect(clock.active, 0);
    expect(window.visible, isTrue);
    expect(tray.listeners, isEmpty);
    final checks = tray.checks;
    timer.fire();
    await service.initialize();
    await flushMicrotasks();
    expect(tray.checks, checks);
    expect(tray.destroyCalls, 1);
  });
  test('dispose during poll ignores late results', () async {
    await service.initialize();
    await service.hideWindow();
    final started = Completer<void>();
    final gate = Completer<bool>();
    tray.probe = () {
      started.complete();
      return gate.future;
    };
    clock.fire();
    await started.future;
    service.dispose();
    gate.complete(false);
    await flushMicrotasks();
    expect(window.visible, isTrue);
    expect(window.showCalls, 1);
    expect(clock.active, 0);
  });
  test('dispose during native hide reveals after completion', () async {
    await service.initialize();
    final started = Completer<void>();
    final gate = Completer<void>();
    window.hiding = () {
      started.complete();
      return gate.future;
    };
    final hiding = service.hideWindow();
    await started.future;
    service.dispose();
    gate.complete();
    await hiding;
    await flushMicrotasks();
    expect(window.visible, isTrue);
    expect(clock.active, 0);
  });
  test('D-Bus error reveals without exiting or changing VPN state', () async {
    client.state = 'running';
    final status = Map<String, dynamic>.of(client.status);
    await service.initialize();
    await service.hideWindow();
    tray.probeError = true;
    clock.fire();
    await flushMicrotasks();
    expect(window.visible, isTrue);
    expect(window.closeCalls, 0);
    expect(client.exits, 0);
    expect(client.state, 'running');
    expect(client.status, status);
    expect(clock.active, 0);
  });
  test('failed native reveal retries on later bounded tick', () async {
    await service.initialize();
    await service.hideWindow();
    window.showError = true;
    tray.hostAvailable = false;
    clock.fire();
    await flushMicrotasks();
    expect(window.visible, isFalse);
    expect(clock.active, 1);
    window.showError = false;
    clock.fire();
    await flushMicrotasks();
    expect(window.visible, isTrue);
    expect(clock.active, 0);
  });
  test('transient icon/reset failure permits later recovery', () async {
    tray.iconError = true;
    await service.initialize();
    tray.iconError = false;
    tray.destroyError = true;
    await service.hideWindow();
    expect(window.visible, isTrue);
    tray.destroyError = false;
    await service.hideWindow();
    expect(window.visible, isFalse);
    expect(clock.active, 1);
  });
  test('reinitialization has no duplicate listeners or timers', () async {
    await service.initialize();
    await service.initialize();
    await service.hideWindow();
    await service.initialize();
    expect(tray.listeners, [service]);
    expect(clock.active, 1);
    await service.showWindow();
    service.dispose();
    await flushMicrotasks();
    service = createService();
    await service.initialize();
    await service.hideWindow();
    expect(tray.listeners, [service]);
    expect(clock.active, 1);
  });
  test('external window reveal stops background probes', () async {
    await service.initialize();
    await service.hideWindow();
    final checks = tray.checks;
    window.visible = true;
    clock.fire();
    await flushMicrotasks();
    expect(tray.checks, checks);
    expect(clock.active, 0);
  });

  test('exit stops observer before native destruction', () async {
    await service.initialize();
    await service.hideWindow();
    await service.exitApplication();
    expect(clock.active, 0);
    expect(window.closeCalls, 1);
    expect(tray.destroyCalls, 1);
    expect(client.exits, 1);
    service.dispose();
    await flushMicrotasks();
    expect(window.showCalls, 1);
    expect(tray.destroyCalls, 1);
  });
  test('Windows path retains one-time check without Linux polling', () async {
    service.dispose();
    service = createService(watchTray: false);
    await service.initialize();
    await service.hideWindow();
    expect(tray.checks, 1);
    expect(window.visible, isFalse);
    expect(clock.active, 0);
    await service.showWindow();
    expect(window.visible, isTrue);
  });
}
