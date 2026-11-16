// Opt-in native-window/SNI harness. Never initializes the daemon or VPN client.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:velum/client.dart';
import 'package:velum/tray_service.dart';

void main() {
  if (!Platform.isLinux || Platform.environment['VELUM_TRAY_SMOKE'] != '1') {
    throw StateError('Use scripts/test-linux-tray.sh in a Hyprland session.');
  }
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: Text('Velum F9 isolated tray test — no VPN')),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(checkTray()));
}

Future<void> until(
  Future<bool> Function() predicate,
  String description,
) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < const Duration(seconds: 12)) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('Timed out: $description');
}

Future<void> checkTray() async {
  final directory = Directory(Platform.environment['VELUM_TRAY_SMOKE_DIR']!);
  final result = File('${directory.path}/results.json');
  final client = VelumClient(directory: directory);
  const tray = RealTrayManagerAdapter();
  const window = MethodChannelWindowAdapter();
  final service = VelumTrayService(client: client);
  Process? panel;
  final panelLogs = <StreamSubscription<List<int>>>[];
  final checks = <String>[];
  Object? failure;
  Future<bool> compositorMapped() async {
    final response = await Process.run('hyprctl', ['-j', 'clients']);
    if (response.exitCode != 0) {
      throw StateError('Cannot query Hyprland clients');
    }
    // Inspect only our PID; do not log or retain other windows' metadata.
    return (jsonDecode(response.stdout.toString()) as List).any(
      (entry) => entry['pid'] == pid && entry['mapped'] == true,
    );
  }

  Future<bool> visible() async =>
      await window.isVisible() && await compositorMapped();
  Future<void> hidden() => until(
    () async => !await window.isVisible() && !await compositorMapped(),
    'GTK window unmapped in Hyprland',
  );
  void pass(String message) {
    checks.add(message);
    stdout.writeln('PASS: $message');
  }

  Future<void> startPanel() async {
    final process = await Process.start('waybar', [
      '-c',
      '${directory.path}/waybar.json',
      '-s',
      '${directory.path}/waybar.css',
    ]);
    panel = process;
    for (final stream in [process.stdout, process.stderr]) {
      panelLogs.add(
        stream.listen(
          (bytes) => stdout.write(utf8.decode(bytes, allowMalformed: true)),
        ),
      );
    }
    await until(() async {
      final response = await Process.run('gdbus', [
        'call',
        '--session',
        '--timeout',
        '1',
        '--dest',
        'org.kde.StatusNotifierWatcher',
        '--object-path',
        '/StatusNotifierWatcher',
        '--method',
        'org.freedesktop.DBus.Properties.Get',
        'org.kde.StatusNotifierWatcher',
        'IsStatusNotifierHostRegistered',
      ]);
      return response.exitCode == 0 &&
          response.stdout.toString().contains('true');
    }, 'test Waybar host registration');
  }

  Future<void> stopPanel() async {
    final process = panel;
    if (process == null) return;
    panel = null;
    process.kill(ProcessSignal.sigterm); // This harness's child PID only.
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
  }

  try {
    await window.show();
    await until(visible, 'initial GTK window mapped in Hyprland');
    await service.initialize();
    await service.hideWindow();
    if (!await visible()) throw StateError('Hidden with no SNI host');
    pass('Hyprland without panel: actual GTK window stays visible');

    await startPanel();
    await service.hideWindow();
    await hidden();
    if (!await tray.isAvailable()) {
      throw StateError('Panel appeared but window could not safely hide');
    }
    pass('Late Waybar: real SNI item registered and actual GTK window hidden');

    await stopPanel();
    await until(visible, 'window recovery after test panel exit');
    pass('Hidden GTK window automatically restored after Waybar exit');

    await startPanel();
    await service.hideWindow();
    await hidden();
    if (!await tray.isAvailable()) {
      throw StateError('Returning panel did not restore hide capability');
    }
    pass('Returning Waybar: item reregistered and window hidden again');

    await tray.destroy(); // Lose only this test GUI's SNI registration.
    await until(visible, 'window recovery after SNI item removal');
    pass('Lost real SNI item: actual GTK window automatically restored');

    await service.hideWindow();
    await hidden();
    if (!await tray.isAvailable()) {
      throw StateError('Item removal did not permit safe registration retry');
    }
    service.dispose();
    await until(visible, 'window recovery after observer disposal');
    pass('Dispose while hidden: actual GTK window restored');
  } catch (error, stack) {
    failure = error;
    stderr.writeln('$error\n$stack');
  } finally {
    service.dispose();
    client.dispose();
    await stopPanel();
    for (final subscription in panelLogs) {
      await subscription.cancel();
    }
    await result.writeAsString(
      jsonEncode({
        'passed': failure == null,
        'checks': checks,
        if (failure != null) 'error': failure.toString(),
        'desktop': Platform.environment['XDG_CURRENT_DESKTOP'],
        'vpnInitialized': false,
      }),
    );
    await window.close();
  }
}
