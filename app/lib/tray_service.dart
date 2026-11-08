// ignore_for_file: implementation_imports, deprecated_member_use
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:tray_manager/src/menu.dart' as tm;
import 'package:tray_manager/src/tray_listener.dart' as tm;
import 'package:tray_manager/src/tray_manager.dart' as tm;

import 'client.dart';

/// Abstract interface for Tray Manager operations to enable deterministic unit testing.
abstract class TrayManagerAdapter {
  bool get isSupported;
  Future<bool> isAvailable();
  Future<void> destroy();
  Future<void> setIcon(String iconPath);
  Future<void> setToolTip(String toolTip);
  Future<void> setContextMenu(tm.Menu menu);
  void addListener(tm.TrayListener listener);
  void removeListener(tm.TrayListener listener);
}

/// Default adapter delegating to the real [tm.TrayManager.instance].
class RealTrayManagerAdapter implements TrayManagerAdapter {
  const RealTrayManagerAdapter();

  @override
  bool get isSupported {
    try {
      return tm.TrayManager.instance.isSupported;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> isAvailable() async {
    if (!isSupported) return false;
    if (Platform.isLinux) {
      for (final service in [
        'org.kde.StatusNotifierWatcher',
        'com.canonical.StatusNotifierWatcher',
      ]) {
        try {
          final result = await Process.run('gdbus', [
            'call',
            '--session',
            '--timeout',
            '1',
            '--dest',
            service,
            '--object-path',
            '/StatusNotifierWatcher',
            '--method',
            'org.freedesktop.DBus.Properties.Get',
            service,
            'IsStatusNotifierHostRegistered',
          ]);
          if (result.exitCode != 0 ||
              !RegExp(r'\btrue\b').hasMatch(result.stdout.toString())) {
            continue;
          }
          final registered = await Process.run('gdbus', [
            'call',
            '--session',
            '--timeout',
            '1',
            '--dest',
            service,
            '--object-path',
            '/StatusNotifierWatcher',
            '--method',
            'org.freedesktop.DBus.Properties.Get',
            service,
            'RegisteredStatusNotifierItems',
          ]);
          if (registered.exitCode == 0 &&
              registered.stdout.toString().contains(
                'org.kde.StatusNotifierItem-$pid-',
              )) {
            return true;
          }
        } catch (_) {}
      }
      return false;
    }
    if (Platform.isWindows) {
      try {
        return tm.TrayManager.instance.trayIcon?.isVisible() ?? false;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  @override
  Future<void> destroy() => tm.TrayManager.instance.destroy();

  @override
  Future<void> setIcon(String iconPath) =>
      tm.TrayManager.instance.setIcon(iconPath);

  @override
  Future<void> setToolTip(String toolTip) =>
      tm.TrayManager.instance.setToolTip(toolTip);

  @override
  Future<void> setContextMenu(tm.Menu menu) =>
      tm.TrayManager.instance.setContextMenu(menu);

  @override
  void addListener(tm.TrayListener listener) =>
      tm.TrayManager.instance.addListener(listener);

  @override
  void removeListener(tm.TrayListener listener) =>
      tm.TrayManager.instance.removeListener(listener);
}

/// Abstract interface for native window operations (hide, show, close, isVisible).
abstract class WindowActionAdapter {
  Future<void> show();
  Future<void> hide();
  Future<void> close();
  Future<bool> isVisible();
  void setCloseRequestHandler(Future<void> Function()? handler);
}

/// Platform channel adapter using the "velum/window" channel.
class MethodChannelWindowAdapter implements WindowActionAdapter {
  const MethodChannelWindowAdapter();
  static const _channel = MethodChannel('velum/window');

  @override
  Future<void> show() => _channel.invokeMethod<void>('show');
  @override
  Future<void> hide() => _channel.invokeMethod<void>('hide');
  @override
  Future<void> close() async {
    try {
      await _channel.invokeMethod<void>('closeConfirmed');
    } on PlatformException catch (error) {
      if (error.code != 'window') rethrow; // Already destroyed is idempotent.
    }
  }

  @override
  Future<bool> isVisible() async =>
      await _channel.invokeMethod<bool>('isVisible') ?? false;
  @override
  void setCloseRequestHandler(Future<void> Function()? handler) {
    _channel.setMethodCallHandler(
      handler == null
          ? null
          : (call) async {
              if (call.method != 'closeRequested') {
                throw MissingPluginException();
              }
              await handler();
            },
    );
  }
}

enum ExitFailureAction { retry, cancel, force }

abstract class ExitInteraction {
  Future<bool> confirmProtectionLoss();
  Future<ExitFailureAction> cleanupFailed(Object error);
}

/// Service managing the system tray icon, context menu, and application lifecycle.
class VelumTrayService with tm.TrayListener {
  VelumTrayService({
    required this.client,
    this.trayAdapter = const RealTrayManagerAdapter(),
    this.windowAdapter = const MethodChannelWindowAdapter(),
    this.exitInteraction,
  });

  final VelumClient client;
  final TrayManagerAdapter trayAdapter;
  final WindowActionAdapter windowAdapter;
  ExitInteraction? exitInteraction;
  Future<void>? _closeRequest;
  Future<void>? _trayDestruction;
  Future<void> _trayWork = Future<void>.value();
  bool _exitRequested = false;
  bool _exiting = false;
  bool _closed = false;

  bool _initialized = false;
  bool _disposed = false;
  bool _traySupported = false;
  bool _trayRegistered = false;

  bool get isSupported => _traySupported;

  // Cached state to prevent redundant system / D-Bus calls on statistics ticks
  String _cachedState = '';
  String _cachedActiveProfile = '';
  int _cachedProfilesCount = -1;
  bool _cachedBusy = false;

  /// Initializes the tray icon, listeners, and window close-interception settings.
  Future<void> initialize() async {
    if (_disposed || _initialized) return;
    _initialized = true;
    windowAdapter.setCloseRequestHandler(handleWindowClose);
    client.addListener(_onClientChanged);
    try {
      _traySupported = trayAdapter.isSupported;
    } catch (_) {
      _traySupported = false;
    }
    if (!_traySupported) return;
    trayAdapter.addListener(this);
    _trayRegistered = true;
    await updateTray(force: true);
  }

  void _onClientChanged() {
    if (_disposed || !_initialized || _exiting || _closed) return;

    // Only update native tray menu/icon if functional state or connection status changed
    if (client.state != _cachedState ||
        client.activeProfile != _cachedActiveProfile ||
        client.profiles.length != _cachedProfilesCount ||
        client.busy != _cachedBusy) {
      unawaited(updateTray());
    }
  }

  /// Refreshes the tray icon and context menu.
  Future<void> updateTray({bool force = false}) {
    if (_exiting || _closed || _disposed) return _trayWork;
    _trayWork = _trayWork.then((_) => _updateTray(force: force));
    return _trayWork;
  }

  Future<void> _updateTray({bool force = false}) async {
    if (!_traySupported || _disposed || _exiting || _closed) return;

    final currentState = client.state;
    final currentProfile = client.activeProfile;
    final count = client.profiles.length;
    final busy = client.busy;

    if (!force &&
        currentState == _cachedState &&
        currentProfile == _cachedActiveProfile &&
        count == _cachedProfilesCount &&
        busy == _cachedBusy) {
      return;
    }

    _cachedState = currentState;
    _cachedActiveProfile = currentProfile;
    _cachedProfilesCount = count;
    _cachedBusy = busy;

    // 1. Set Status Icon
    final iconPath = _iconForState(currentState);
    try {
      await trayAdapter.setIcon(iconPath);
      await trayAdapter.setToolTip('Velum — ${_statusLabel(currentState)}');
    } catch (_) {
      _traySupported = false;
      return;
    }
    if (_exiting || _closed || _disposed) return;

    // 2. Build Context Menu
    final menu = buildMenu();
    try {
      await trayAdapter.setContextMenu(menu);
    } catch (_) {}
  }

  String _iconForState(String state) {
    switch (state) {
      case 'running':
        return 'assets/tray/tray_running.png';
      case 'connecting':
      case 'reconnecting':
        return 'assets/tray/tray_connecting.png';
      case 'error':
      case 'failed':
        return 'assets/tray/tray_error.png';
      case 'disconnected':
      case 'offline':
      default:
        return 'assets/tray/tray_disconnected.png';
    }
  }

  String _statusLabel(String state) {
    switch (state) {
      case 'running':
        return 'Подключено';
      case 'connecting':
        return 'Подключение...';
      case 'reconnecting':
        return 'Переподключение...';
      case 'error':
      case 'failed':
        return 'Ошибка';
      case 'disconnected':
        return 'Отключено';
      case 'offline':
        return 'Служба офлайн';
      default:
        return state;
    }
  }

  /// Builds the context menu representation from the current client state.
  tm.Menu buildMenu() {
    final running = client.state == 'running';
    final hasProfiles = client.profiles.isNotEmpty;
    final activeServerName = client.activeProfile.isNotEmpty
        ? client.activeProfile
        : (hasProfiles ? client.profiles[client.selected].name : 'Не выбран');

    final toggleLabel = running ? 'Отключиться' : 'Подключиться';

    return tm.Menu(
      items: [
        tm.MenuItem(key: 'open', label: 'Открыть Velum'),
        tm.MenuItem(
          key: 'toggle',
          label: toggleLabel,
          disabled: !hasProfiles || client.busy,
        ),
        tm.MenuItem.separator(),
        tm.MenuItem(
          key: 'server',
          label: 'Сервер: $activeServerName',
          disabled: true,
        ),
        tm.MenuItem(
          key: 'status',
          label: 'Статус: ${_statusLabel(client.state)}',
          disabled: true,
        ),
        tm.MenuItem.separator(),
        tm.MenuItem(key: 'exit', label: 'Выход'),
      ],
    );
  }

  // --- TrayListener Callbacks ---

  @override
  void onTrayIconMouseDown() {
    unawaited(showWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    // On Windows, right click triggers popup context menu automatically or via native API
  }

  @override
  void onTrayMenuItemClick(tm.MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        unawaited(showWindow());
        break;
      case 'toggle':
        unawaited(client.toggle());
        break;
      case 'exit':
        unawaited(exitApplication());
        break;
    }
  }

  // --- Window and Lifecycle Actions ---

  /// Shows the main GUI window and brings it to the foreground.
  Future<void> showWindow() async {
    await windowAdapter.show();
  }

  /// Hides the main GUI window to the system tray.
  Future<void> hideWindow() async {
    if (await _canHide()) {
      await windowAdapter.hide();
    } else {
      // If tray is unavailable, do not leave window unrecoverable; keep visible.
    }
  }

  Future<bool> _canHide() async {
    if (!_initialized || !_traySupported || _trayDestruction != null) {
      return false;
    }
    try {
      return await trayAdapter.isAvailable();
    } catch (_) {
      return false;
    }
  }

  Future<void> handleWindowClose() => _requestClose(exit: false);
  Future<void> exitApplication() => _requestClose(exit: true);

  Future<void> _requestClose({required bool exit}) {
    if (_disposed || _closed) return Future<void>.value();
    if (exit) _exitRequested = true;
    return _closeRequest ??= _processClose().whenComplete(() {
      _closeRequest = null;
      _exitRequested = false;
    });
  }

  Future<void> _showBestEffort() async {
    try {
      await windowAdapter.show();
    } catch (_) {}
  }

  Future<void> _processClose() async {
    if (!_exitRequested &&
        client.settings['minimizeToTray'] == true &&
        await _canHide()) {
      if (!_exitRequested && !_disposed) {
        try {
          await windowAdapter.hide();
          if (!_exitRequested) return;
        } catch (_) {
          /* Continue with a visible, controlled exit. */
        }
      }
    }
    await _showBestEffort();
    if (_disposed) return;
    final interaction = exitInteraction;
    // No ready UI delegate means no implicit consent to lose protection.
    if (client.protectionMayBeActive &&
        (interaction == null || !await interaction.confirmProtectionLoss())) {
      return;
    }
    if (_disposed) return;
    _exiting = true;
    var retry = false;
    var force = false;
    while (!_disposed) {
      try {
        if (!force) await client.prepareForExit(retry: retry);
        await client.finishExit(force: force);
        try {
          await _destroyTrayOnce();
        } catch (_) {
          if (!force) rethrow;
        }
        await windowAdapter.close();
        _closed = true;
        windowAdapter.setCloseRequestHandler(null);
        return;
      } catch (error) {
        if (_disposed) return;
        await _showBestEffort();
        final decision = interaction == null
            ? ExitFailureAction.cancel
            : await interaction.cleanupFailed(error);
        if (decision == ExitFailureAction.cancel) {
          await client.cancelExit();
          _exiting = false;
          if (_trayDestruction != null) _traySupported = false;
          await updateTray(force: true);
          return;
        }
        force = decision == ExitFailureAction.force;
        retry = decision == ExitFailureAction.retry;
      }
    }
  }

  Future<void> _destroyTrayOnce() => _trayDestruction ??= () async {
    await _trayWork;
    if (_trayRegistered) await trayAdapter.destroy();
  }();

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    windowAdapter.setCloseRequestHandler(null);
    client.removeListener(_onClientChanged);
    trayAdapter.removeListener(this);
    unawaited(_destroyTrayOnce().catchError((Object _) {}));
  }
}
