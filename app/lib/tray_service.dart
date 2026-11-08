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
  Future<void> setHideOnClose(bool enable);
}

/// Platform channel adapter using the "velum/window" channel.
class MethodChannelWindowAdapter implements WindowActionAdapter {
  const MethodChannelWindowAdapter();
  static const _channel = MethodChannel('velum/window');

  @override
  Future<void> show() async {
    try {
      await _channel.invokeMethod<void>('show');
    } catch (_) {}
  }

  @override
  Future<void> hide() async {
    try {
      await _channel.invokeMethod<void>('hide');
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    try {
      await _channel.invokeMethod<void>('close');
    } on MissingPluginException {
      await SystemNavigator.pop();
    } catch (_) {}
  }

  @override
  Future<bool> isVisible() async {
    try {
      final res = await _channel.invokeMethod<bool>('isVisible');
      return res ?? true;
    } catch (_) {
      return true;
    }
  }

  @override
  Future<void> setHideOnClose(bool enable) async {
    try {
      await _channel.invokeMethod<void>('setHideOnClose', enable);
    } catch (_) {}
  }
}

/// Service managing the system tray icon, context menu, and application lifecycle.
class VelumTrayService with tm.TrayListener {
  VelumTrayService({
    required this.client,
    this.trayAdapter = const RealTrayManagerAdapter(),
    this.windowAdapter = const MethodChannelWindowAdapter(),
  });

  final VelumClient client;
  final TrayManagerAdapter trayAdapter;
  final WindowActionAdapter windowAdapter;

  bool _initialized = false;
  bool _disposed = false;
  bool _traySupported = false;

  bool get isSupported => _traySupported;

  // Cached state to prevent redundant system / D-Bus calls on statistics ticks
  String _cachedState = '';
  String _cachedActiveProfile = '';
  int _cachedProfilesCount = -1;
  bool _cachedBusy = false;

  /// Initializes the tray icon, listeners, and window close-interception settings.
  Future<void> initialize() async {
    if (_disposed || _initialized) return;

    if (!Platform.isLinux && !Platform.isWindows && !Platform.isMacOS) {
      _traySupported = false;
      return;
    }

    try {
      _traySupported = trayAdapter.isSupported;
    } catch (_) {
      _traySupported = false;
    }

    if (!_traySupported) {
      // In Wayland / Hyprland without compatible SNI or headless environments,
      // window must not be minimized into a non-existent tray.
      await windowAdapter.setHideOnClose(false);
      return;
    }

    _initialized = true;
    trayAdapter.addListener(this);

    // Sync window close behavior with user preference
    final minimizeToTray = client.settings['minimizeToTray'] == true;
    await windowAdapter.setHideOnClose(minimizeToTray);

    client.addListener(_onClientChanged);
    await updateTray(force: true);
  }

  void _onClientChanged() {
    if (_disposed || !_initialized) return;

    // Check if close behavior setting was updated in settings
    final minimizeToTray = client.settings['minimizeToTray'] == true;
    windowAdapter.setHideOnClose(minimizeToTray);

    // Only update native tray menu/icon if functional state or connection status changed
    if (client.state != _cachedState ||
        client.activeProfile != _cachedActiveProfile ||
        client.profiles.length != _cachedProfilesCount ||
        client.busy != _cachedBusy) {
      unawaited(updateTray());
    }
  }

  /// Refreshes the tray icon and context menu.
  Future<void> updateTray({bool force = false}) async {
    if (!_traySupported || _disposed) return;

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
    } catch (_) {}

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
        tm.MenuItem(
          key: 'open',
          label: 'Открыть Velum',
        ),
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
        tm.MenuItem(
          key: 'exit',
          label: 'Выход',
        ),
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
    if (_traySupported) {
      await windowAdapter.hide();
    } else {
      // If tray is unavailable, do not leave window unrecoverable; keep visible.
    }
  }

  /// Intercepts window close action according to user preference and tray availability.
  Future<void> handleWindowClose() async {
    final minimizeToTray = client.settings['minimizeToTray'] == true;
    if (_traySupported && minimizeToTray) {
      await hideWindow();
    } else {
      await exitApplication();
    }
  }

  /// Completely terminates the application and cleans up resources.
  Future<void> exitApplication() async {
    // Direct restoration here would race an apply already in flight.
    await client.shutdown(disconnectConsole: true);

    // 3. Destroy tray icon
    try {
      await trayAdapter.destroy();
    } catch (_) {}

    // 4. Close window and exit process
    await windowAdapter.close();
    exit(0);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    client.removeListener(_onClientChanged);
    if (_traySupported) {
      trayAdapter.removeListener(this);
      unawaited(trayAdapter.destroy());
    }
  }
}
