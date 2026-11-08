import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

/// Current status of the system proxy relative to Velum.
enum SystemProxyStatus {
  /// System proxy is actively pointing to Velum's local inbound.
  enabled,

  /// System proxy is disabled or pointing to direct connection.
  disabled,

  /// System proxy points to a third-party server or unexpected address.
  conflict,

  /// The current desktop environment or OS does not support standard system proxy configuration.
  unsupported,

  /// An error occurred while inspecting or configuring the system proxy.
  error,
}

/// Represents the platform-agnostic system proxy configuration.
class SystemProxyConfig {
  const SystemProxyConfig({
    required this.enabled,
    required this.host,
    required this.port,
    this.exceptions = const [],
    this.desktopEnvironment = '',
    this.autoDetect = false,
    this.pacUrl = '',
    this.raw = const {},
  });

  factory SystemProxyConfig.fromJson(Map<String, dynamic> json) {
    return SystemProxyConfig(
      enabled: json['enabled'] as bool? ?? false,
      host: json['host'] as String? ?? '127.0.0.1',
      port: json['port'] as int? ?? 2080,
      exceptions: (json['exceptions'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      desktopEnvironment: json['desktopEnvironment'] as String? ?? '',
      autoDetect: json['autoDetect'] as bool? ?? false,
      pacUrl: json['pacUrl'] as String? ?? '',
      raw: (json['raw'] as Map<String, dynamic>?) ?? const {},
    );
  }

  final bool enabled;
  final String host;
  final int port;
  final List<String> exceptions;
  final String desktopEnvironment;
  final bool autoDetect;
  final String pacUrl;
  final Map<String, dynamic> raw;

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'host': host,
        'port': port,
        'exceptions': exceptions,
        'desktopEnvironment': desktopEnvironment,
        'autoDetect': autoDetect,
        'pacUrl': pacUrl,
        'raw': raw,
      };

  /// Checks whether this config matches the specified host and port.
  bool matches(String targetHost, int targetPort) {
    if (!enabled) return false;
    final normalizedHost = host.trim().toLowerCase();
    final normalizedTarget = targetHost.trim().toLowerCase();
    return (normalizedHost == normalizedTarget ||
            (normalizedHost == 'localhost' &&
                (normalizedTarget == '127.0.0.1' ||
                    normalizedTarget == 'localhost')) ||
            (normalizedHost == '127.0.0.1' &&
                (normalizedTarget == 'localhost' ||
                    normalizedTarget == '127.0.0.1'))) &&
        port == targetPort;
  }
}

/// Custom process runner definition for dependency injection and mocking.
typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
});

/// Windows WinINet per-connection option union and structures for dart:ffi.
final class InternetPerConnOptionValue extends ffi.Union {
  @ffi.Uint32()
  external int dwValue;

  external ffi.Pointer<ffi.Uint16> pszValue;
}

final class InternetPerConnOption extends ffi.Struct {
  @ffi.Uint32()
  external int dwOption;

  external InternetPerConnOptionValue value;
}

final class InternetPerConnOptionList extends ffi.Struct {
  @ffi.Uint32()
  external int dwSize;

  external ffi.Pointer<ffi.Uint16> pszConnection;

  @ffi.Uint32()
  external int dwOptionCount;

  @ffi.Uint32()
  external int dwOptionError;

  external ffi.Pointer<InternetPerConnOption> pOptions;
}

/// WinINet and Win32 constants from Windows SDK.
abstract final class WinINetConstants {
  static const int internetOptionPerConnectionOption = 75;
  static const int internetOptionSettingsChanged = 39;
  static const int internetOptionRefresh = 37;

  static const int internetPerConnFlags = 1;
  static const int internetPerConnProxyServer = 2;
  static const int internetPerConnProxyBypass = 3;
  static const int internetPerConnAutoconfigUrl = 4;
  static const int internetPerConnAutodiscoveryFlags = 5;

  static const int proxyTypeDirect = 0x00000001;
  static const int proxyTypeProxy = 0x00000002;
  static const int proxyTypeAutoProxyUrl = 0x00000004;
  static const int proxyTypeAutoDetect = 0x00000008;

  static const int gptr = 0x0040; // GMEM_FIXED | GMEM_ZEROINIT
}

/// Abstract WinINet API interface for testing and platform abstraction.
abstract class WinINetApi {
  int queryOption(
    int hInternet,
    int dwOption,
    ffi.Pointer<ffi.Void> lpBuffer,
    ffi.Pointer<ffi.Uint32> lpdwBufferLength,
  );

  int setOption(
    int hInternet,
    int dwOption,
    ffi.Pointer<ffi.Void> lpBuffer,
    int dwBufferLength,
  );

  ffi.Pointer<ffi.Void> globalAlloc(int uFlags, int dwBytes);

  ffi.Pointer<ffi.Void> globalFree(ffi.Pointer<ffi.Void> hMem);
}

/// Native WinINet API implementation using wininet.dll and kernel32.dll.
class NativeWinINetApi implements WinINetApi {
  NativeWinINetApi() {
    final wininet = ffi.DynamicLibrary.open('wininet.dll');
    final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');

    _queryOption = wininet.lookupFunction<
        ffi.Int32 Function(ffi.IntPtr, ffi.Uint32, ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Uint32>),
        int Function(int, int, ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint32>)>(
      'InternetQueryOptionW',
    );

    _setOption = wininet.lookupFunction<
        ffi.Int32 Function(
            ffi.IntPtr, ffi.Uint32, ffi.Pointer<ffi.Void>, ffi.Uint32),
        int Function(int, int, ffi.Pointer<ffi.Void>, int)>(
      'InternetSetOptionW',
    );

    _globalAlloc = kernel32.lookupFunction<
        ffi.Pointer<ffi.Void> Function(ffi.Uint32, ffi.IntPtr),
        ffi.Pointer<ffi.Void> Function(int, int)>(
      'GlobalAlloc',
    );

    _globalFree = kernel32.lookupFunction<
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>),
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)>(
      'GlobalFree',
    );
  }

  late final int Function(
          int, int, ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint32>)
      _queryOption;
  late final int Function(int, int, ffi.Pointer<ffi.Void>, int) _setOption;
  late final ffi.Pointer<ffi.Void> Function(int, int) _globalAlloc;
  late final ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>) _globalFree;

  @override
  int queryOption(
    int hInternet,
    int dwOption,
    ffi.Pointer<ffi.Void> lpBuffer,
    ffi.Pointer<ffi.Uint32> lpdwBufferLength,
  ) =>
      _queryOption(hInternet, dwOption, lpBuffer, lpdwBufferLength);

  @override
  int setOption(
    int hInternet,
    int dwOption,
    ffi.Pointer<ffi.Void> lpBuffer,
    int dwBufferLength,
  ) =>
      _setOption(hInternet, dwOption, lpBuffer, dwBufferLength);

  @override
  ffi.Pointer<ffi.Void> globalAlloc(int uFlags, int dwBytes) =>
      _globalAlloc(uFlags, dwBytes);

  @override
  ffi.Pointer<ffi.Void> globalFree(ffi.Pointer<ffi.Void> hMem) =>
      _globalFree(hMem);
}

/// Abstract base class for platform-specific system proxy managers.
abstract class SystemProxyManager {
  SystemProxyManager({
    required this.configDirectory,
    ProcessRunner? runner,
  }) : runner = runner ?? Process.run;

  final Directory configDirectory;
  final ProcessRunner runner;

  File get backupFile => File('${configDirectory.path}/proxy_backup.json');

  /// Human-readable name of the platform/desktop environment backend.
  String get environmentName;

  /// Whether the current OS and desktop environment can be configured.
  bool get isSupported;

  /// Detailed reason when unsupported.
  String get unsupportedReason => '';

  /// Inspects the current system proxy status for the given local proxy server.
  Future<SystemProxyStatus> getStatus(String host, int port) async {
    if (!isSupported) return SystemProxyStatus.unsupported;
    try {
      final current = await readCurrentConfig();
      if (!current.enabled) {
        return SystemProxyStatus.disabled;
      }
      if (current.matches(host, port)) {
        return SystemProxyStatus.enabled;
      }
      return SystemProxyStatus.conflict;
    } catch (_) {
      return SystemProxyStatus.error;
    }
  }

  /// Reads the current system proxy settings from the platform.
  Future<SystemProxyConfig> readCurrentConfig();

  /// Applies the proxy settings to the system for the current user.
  Future<void> applyPlatformProxy({
    required String host,
    required int port,
    List<String> exceptions = const [],
  });

  /// Restores the previously saved system proxy settings to the platform.
  Future<void> restorePlatformProxy(SystemProxyConfig backup);

  /// Disables system proxy on the platform.
  Future<void> disablePlatformProxy();

  /// Safely saves a backup of current configuration before applying Velum proxy.
  /// Preserves the user's true pre-Velum original configuration.
  Future<void> saveBackupIfNeeded() async {
    if (!await backupFile.exists()) {
      final current = await readCurrentConfig();
      await configDirectory.create(recursive: true);
      await backupFile.writeAsString(jsonEncode(current.toJson()), flush: true);
    }
  }

  /// Enables system proxy pointing to Velum, saving backup first.
  Future<void> enable({
    required String host,
    required int port,
    List<String> exceptions = const [
      'localhost',
      '127.*',
      '10.*',
      '172.16.*',
      '172.17.*',
      '172.18.*',
      '172.19.*',
      '172.20.*',
      '172.21.*',
      '172.22.*',
      '172.23.*',
      '172.24.*',
      '172.25.*',
      '172.26.*',
      '172.27.*',
      '172.28.*',
      '172.29.*',
      '172.30.*',
      '172.31.*',
      '192.168.*',
      '<local>',
    ],
  }) async {
    if (!isSupported) {
      throw UnsupportedError(unsupportedReason);
    }
    await saveBackupIfNeeded();
    await applyPlatformProxy(host: host, port: port, exceptions: exceptions);
  }

  /// Restores proxy settings from backup, checking for third-party conflicts.
  Future<void> restore({
    required String host,
    required int port,
    bool force = false,
  }) async {
    if (!isSupported) return;

    SystemProxyConfig? backup;
    if (await backupFile.exists()) {
      try {
        final content = await backupFile.readAsString();
        backup = SystemProxyConfig.fromJson(
          jsonDecode(content) as Map<String, dynamic>,
        );
      } catch (_) {
        backup = null;
      }
    }

    if (!force) {
      final current = await readCurrentConfig();
      if (current.enabled && !current.matches(host, port)) {
        throw const FormatException(
          'Настройки системного прокси были изменены другой программой. Восстановление отменено во избежание конфликта.',
        );
      }
    }

    if (backup != null) {
      await restorePlatformProxy(backup);
    } else {
      await disablePlatformProxy();
    }

    if (await backupFile.exists()) {
      try {
        await backupFile.delete();
      } catch (_) {}
    }
  }

  /// Crash recovery: safely checks if an orphaned system proxy should be restored.
  ///
  /// Criteria:
  /// 1. Does not blindly restore on the presence of proxy_backup.json alone.
  /// 2. If the current configuration in the OS does NOT match Velum (host/port),
  ///    foreign/user settings are NEVER overwritten; the stale backup is purged.
  /// 3. If VPN is already active, user wants system proxy, and local inbound is listening
  ///    (e.g. GUI relaunch while daemon continues running), it does NOT restore.
  /// 4. Restores only when the system is confirmed pointing to Velum, but the VPN
  ///    or local proxy inbound is inactive (a true unrecovered crash).
  Future<bool> recoverIfOrphaned({
    required String host,
    required int port,
    bool isVpnRunning = false,
    bool isProxyInboundActive = false,
    bool userWantsProxy = false,
  }) async {
    if (!isSupported || !await backupFile.exists()) {
      return false;
    }
    try {
      final current = await readCurrentConfig();
      // If OS is no longer pointing to Velum, do not touch settings.
      if (!current.matches(host, port)) {
        await backupFile.delete();
        return false;
      }

      // If VPN is running and local inbound proxy is alive and user intended to use proxy,
      // this is a live ongoing session (e.g. GUI reopened while daemon was running).
      if (isVpnRunning && userWantsProxy && isProxyInboundActive) {
        return false;
      }

      // True orphaned proxy: system points to Velum's port, but VPN or inbound is dead.
      await restore(host: host, port: port, force: true);
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// System proxy manager for Windows using the official WinINet Windows API
/// (InternetQueryOption, InternetSetOption with INTERNET_OPTION_PER_CONNECTION_OPTION).
///
/// Modifies user settings only. WinHTTP is never touched.
class WindowsSystemProxyManager extends SystemProxyManager {
  WindowsSystemProxyManager({
    required super.configDirectory,
    super.runner,
    WinINetApi? api,
  }) : _customApi = api;

  final WinINetApi? _customApi;
  WinINetApi? _nativeApi;

  WinINetApi get api {
    final custom = _customApi;
    if (custom != null) return custom;
    if (Platform.isWindows) {
      _nativeApi ??= NativeWinINetApi();
      return _nativeApi!;
    }
    throw UnsupportedError(
        'WinINet API is only available natively on Windows.');
  }

  @override
  String get environmentName => 'Windows WinINet API';

  @override
  bool get isSupported => Platform.isWindows || _customApi != null;

  @override
  Future<SystemProxyConfig> readCurrentConfig() async {
    final winApi = api;
    final listSize = ffi.sizeOf<InternetPerConnOptionList>();
    final optSize = ffi.sizeOf<InternetPerConnOption>();

    final pListMem = winApi.globalAlloc(WinINetConstants.gptr, listSize);
    final pOptionsMem = winApi.globalAlloc(WinINetConstants.gptr, optSize * 4);
    final pLenMem = winApi.globalAlloc(WinINetConstants.gptr, ffi.sizeOf<ffi.Uint32>());

    try {
      final pList = pListMem.cast<InternetPerConnOptionList>();
      final pOptions = pOptionsMem.cast<InternetPerConnOption>();
      final pLen = pLenMem.cast<ffi.Uint32>();

      pLen.value = listSize;
      pList.ref.dwSize = listSize;
      pList.ref.pszConnection = ffi.nullptr; // NULL indicates LAN / default connection
      pList.ref.dwOptionCount = 4;
      pList.ref.dwOptionError = 0;
      pList.ref.pOptions = pOptions;

      pOptions[0].dwOption = WinINetConstants.internetPerConnFlags;
      pOptions[1].dwOption = WinINetConstants.internetPerConnProxyServer;
      pOptions[2].dwOption = WinINetConstants.internetPerConnProxyBypass;
      pOptions[3].dwOption = WinINetConstants.internetPerConnAutoconfigUrl;

      final res = winApi.queryOption(
        0,
        WinINetConstants.internetOptionPerConnectionOption,
        pListMem,
        pLen,
      );

      if (res == 0) {
        throw const ProcessException(
          'wininet.dll',
          ['InternetQueryOptionW'],
          'Не удалось запросить текущие параметры прокси WinINet.',
        );
      }

      final flags = pOptions[0].value.dwValue;
      final server = _readUtf16AndFree(pOptions[1].value.pszValue, winApi);
      final bypass = _readUtf16AndFree(pOptions[2].value.pszValue, winApi);
      final pacUrl = _readUtf16AndFree(pOptions[3].value.pszValue, winApi);

      final hasProxy = (flags & WinINetConstants.proxyTypeProxy) != 0;
      final autoDetect = (flags & WinINetConstants.proxyTypeAutoDetect) != 0;
      final hasPac = (flags & WinINetConstants.proxyTypeAutoProxyUrl) != 0;

      var host = '127.0.0.1';
      var port = 2080;
      if (server.isNotEmpty) {
        final uriMatch = RegExp(r'(?:https?=|socks=)?([^:;]+):(\d+)').firstMatch(server);
        if (uriMatch != null) {
          host = uriMatch.group(1) ?? '127.0.0.1';
          port = int.tryParse(uriMatch.group(2) ?? '2080') ?? 2080;
        }
      }

      final exceptionsList = bypass
          .split(';')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();

      return SystemProxyConfig(
        enabled: hasProxy,
        host: host,
        port: port,
        exceptions: exceptionsList,
        desktopEnvironment: environmentName,
        autoDetect: autoDetect,
        pacUrl: pacUrl,
        raw: {
          'flags': flags,
          'server': server,
          'bypass': bypass,
          'pacUrl': pacUrl,
          'autoDetect': autoDetect,
          'autoProxyUrl': hasPac,
        },
      );
    } finally {
      winApi.globalFree(pOptionsMem);
      winApi.globalFree(pListMem);
      winApi.globalFree(pLenMem);
    }
  }

  @override
  Future<void> applyPlatformProxy({
    required String host,
    required int port,
    List<String> exceptions = const [],
  }) async {
    final winApi = api;

    // Windows WinINet proxy evaluation rule:
    // If PROXY_TYPE_AUTO_PROXY_URL (PAC) or PROXY_TYPE_AUTO_DETECT (WPAD) is set,
    // WinINet evaluates PAC/WPAD first and bypasses the manual proxy server for any
    // matched rules. To strictly guarantee that system and browser traffic routes
    // through Velum's manual proxy (127.0.0.1:2080), flags are set to PROXY_TYPE_PROXY.
    // The user's original flags, PAC URL, and WPAD settings are preserved in backup
    // and restored upon disconnect.
    const newFlags = WinINetConstants.proxyTypeProxy;

    final proxyServer = '$host:$port';
    final overrideList = exceptions.isEmpty
        ? 'localhost;127.*;10.*;172.16.*;192.168.*;<local>'
        : exceptions.join(';');

    final listSize = ffi.sizeOf<InternetPerConnOptionList>();
    final optSize = ffi.sizeOf<InternetPerConnOption>();

    final pListMem = winApi.globalAlloc(WinINetConstants.gptr, listSize);
    final pOptionsMem = winApi.globalAlloc(WinINetConstants.gptr, optSize * 3);

    ffi.Pointer<ffi.Uint16>? pServerUtf16;
    ffi.Pointer<ffi.Uint16>? pBypassUtf16;

    try {
      final pList = pListMem.cast<InternetPerConnOptionList>();
      final pOptions = pOptionsMem.cast<InternetPerConnOption>();

      pServerUtf16 = _allocUtf16(proxyServer, winApi);
      pBypassUtf16 = _allocUtf16(overrideList, winApi);

      pList.ref.dwSize = listSize;
      pList.ref.pszConnection = ffi.nullptr;
      pList.ref.dwOptionCount = 3;
      pList.ref.dwOptionError = 0;
      pList.ref.pOptions = pOptions;

      pOptions[0].dwOption = WinINetConstants.internetPerConnFlags;
      pOptions[0].value.dwValue = newFlags;

      pOptions[1].dwOption = WinINetConstants.internetPerConnProxyServer;
      pOptions[1].value.pszValue = pServerUtf16;

      pOptions[2].dwOption = WinINetConstants.internetPerConnProxyBypass;
      pOptions[2].value.pszValue = pBypassUtf16;

      final res = winApi.setOption(
        0,
        WinINetConstants.internetOptionPerConnectionOption,
        pListMem,
        listSize,
      );

      if (res == 0) {
        throw const ProcessException(
          'wininet.dll',
          ['InternetSetOptionW'],
          'Не удалось применить параметры прокси через WinINet API.',
        );
      }

      _notifySettingsChanged(winApi);
    } finally {
      if (pServerUtf16 != null) winApi.globalFree(pServerUtf16.cast());
      if (pBypassUtf16 != null) winApi.globalFree(pBypassUtf16.cast());
      winApi.globalFree(pOptionsMem);
      winApi.globalFree(pListMem);
    }
  }

  @override
  Future<void> restorePlatformProxy(SystemProxyConfig backup) async {
    final winApi = api;
    final prevFlags = backup.raw['flags'] as int? ??
        (backup.enabled
            ? WinINetConstants.proxyTypeProxy
            : WinINetConstants.proxyTypeDirect);
    final prevServer = backup.raw['server'] as String? ?? (backup.enabled ? '${backup.host}:${backup.port}' : '');
    final prevBypass = backup.raw['bypass'] as String? ?? backup.exceptions.join(';');
    final prevPac = backup.raw['pacUrl'] as String? ?? backup.pacUrl;

    final listSize = ffi.sizeOf<InternetPerConnOptionList>();
    final optSize = ffi.sizeOf<InternetPerConnOption>();

    final pListMem = winApi.globalAlloc(WinINetConstants.gptr, listSize);
    final pOptionsMem = winApi.globalAlloc(WinINetConstants.gptr, optSize * 4);

    ffi.Pointer<ffi.Uint16>? pServerUtf16;
    ffi.Pointer<ffi.Uint16>? pBypassUtf16;
    ffi.Pointer<ffi.Uint16>? pPacUtf16;

    try {
      final pList = pListMem.cast<InternetPerConnOptionList>();
      final pOptions = pOptionsMem.cast<InternetPerConnOption>();

      pServerUtf16 = _allocUtf16(prevServer, winApi);
      pBypassUtf16 = _allocUtf16(prevBypass, winApi);
      pPacUtf16 = _allocUtf16(prevPac, winApi);

      pList.ref.dwSize = listSize;
      pList.ref.pszConnection = ffi.nullptr;
      pList.ref.dwOptionCount = 4;
      pList.ref.dwOptionError = 0;
      pList.ref.pOptions = pOptions;

      pOptions[0].dwOption = WinINetConstants.internetPerConnFlags;
      pOptions[0].value.dwValue = prevFlags;

      pOptions[1].dwOption = WinINetConstants.internetPerConnProxyServer;
      pOptions[1].value.pszValue = pServerUtf16;

      pOptions[2].dwOption = WinINetConstants.internetPerConnProxyBypass;
      pOptions[2].value.pszValue = pBypassUtf16;

      pOptions[3].dwOption = WinINetConstants.internetPerConnAutoconfigUrl;
      pOptions[3].value.pszValue = pPacUtf16;

      winApi.setOption(
        0,
        WinINetConstants.internetOptionPerConnectionOption,
        pListMem,
        listSize,
      );

      _notifySettingsChanged(winApi);
    } finally {
      if (pServerUtf16 != null) winApi.globalFree(pServerUtf16.cast());
      if (pBypassUtf16 != null) winApi.globalFree(pBypassUtf16.cast());
      if (pPacUtf16 != null) winApi.globalFree(pPacUtf16.cast());
      winApi.globalFree(pOptionsMem);
      winApi.globalFree(pListMem);
    }
  }

  @override
  Future<void> disablePlatformProxy() async {
    final winApi = api;
    final current = await readCurrentConfig();

    var flags = current.raw['flags'] as int? ?? WinINetConstants.proxyTypeDirect;
    flags &= ~WinINetConstants.proxyTypeProxy;
    if (flags == 0) flags = WinINetConstants.proxyTypeDirect;

    final listSize = ffi.sizeOf<InternetPerConnOptionList>();
    final optSize = ffi.sizeOf<InternetPerConnOption>();

    final pListMem = winApi.globalAlloc(WinINetConstants.gptr, listSize);
    final pOptionsMem = winApi.globalAlloc(WinINetConstants.gptr, optSize);

    try {
      final pList = pListMem.cast<InternetPerConnOptionList>();
      final pOptions = pOptionsMem.cast<InternetPerConnOption>();

      pList.ref.dwSize = listSize;
      pList.ref.pszConnection = ffi.nullptr;
      pList.ref.dwOptionCount = 1;
      pList.ref.dwOptionError = 0;
      pList.ref.pOptions = pOptions;

      pOptions[0].dwOption = WinINetConstants.internetPerConnFlags;
      pOptions[0].value.dwValue = flags;

      winApi.setOption(
        0,
        WinINetConstants.internetOptionPerConnectionOption,
        pListMem,
        listSize,
      );

      _notifySettingsChanged(winApi);
    } finally {
      winApi.globalFree(pOptionsMem);
      winApi.globalFree(pListMem);
    }
  }

  void _notifySettingsChanged(WinINetApi winApi) {
    winApi.setOption(
      0,
      WinINetConstants.internetOptionSettingsChanged,
      ffi.nullptr,
      0,
    );
    winApi.setOption(
      0,
      WinINetConstants.internetOptionRefresh,
      ffi.nullptr,
      0,
    );
  }

  ffi.Pointer<ffi.Uint16> _allocUtf16(String str, WinINetApi winApi) {
    final units = str.codeUnits;
    final ptr = winApi
        .globalAlloc(WinINetConstants.gptr, (units.length + 1) * 2)
        .cast<ffi.Uint16>();
    for (var i = 0; i < units.length; i++) {
      ptr[i] = units[i];
    }
    ptr[units.length] = 0;
    return ptr;
  }

  String _readUtf16AndFree(ffi.Pointer<ffi.Uint16> ptr, WinINetApi winApi) {
    if (ptr.address == 0) return '';
    final codeUnits = <int>[];
    var i = 0;
    while (ptr[i] != 0) {
      codeUnits.add(ptr[i]);
      i++;
    }
    // According to Microsoft WinINet documentation, strings returned by
    // InternetQueryOption in INTERNET_PER_CONN_OPTION are allocated by the system
    // via GlobalAlloc and must be released by the caller with GlobalFree.
    winApi.globalFree(ptr.cast<ffi.Void>());
    return String.fromCharCodes(codeUnits);
  }
}

/// Generic GSettings proxy manager supporting GNOME, Cinnamon, MATE, and Budgie.
class GSettingsProxyManager extends SystemProxyManager {
  GSettingsProxyManager({
    required super.configDirectory,
    required this.baseSchema,
    required this.desktopName,
    super.runner,
  });

  final String baseSchema;
  final String desktopName;

  String get _schemaHttp => '$baseSchema.http';
  String get _schemaHttps => '$baseSchema.https';
  String get _schemaSocks => '$baseSchema.socks';

  @override
  String get environmentName => desktopName;

  @override
  bool get isSupported => Platform.isLinux;

  @override
  Future<SystemProxyConfig> readCurrentConfig() async {
    final modeRes = await runner('gsettings', ['get', baseSchema, 'mode']);
    final modeStr = modeRes.stdout.toString().trim().replaceAll("'", '');
    final enabled = modeStr == 'manual';

    final hostRes = await runner('gsettings', ['get', _schemaHttp, 'host']);
    final hostStr = hostRes.stdout.toString().trim().replaceAll("'", '');

    final portRes = await runner('gsettings', ['get', _schemaHttp, 'port']);
    final portNum = int.tryParse(portRes.stdout.toString().trim()) ?? 2080;

    final ignoreRes =
        await runner('gsettings', ['get', baseSchema, 'ignore-hosts']);
    final ignoreRaw = ignoreRes.stdout.toString().trim();
    final exceptions = <String>[];
    try {
      final parsed = jsonDecode(ignoreRaw.replaceAll("'", '"'));
      if (parsed is List) {
        exceptions.addAll(parsed.map((e) => e.toString()));
      }
    } catch (_) {}

    return SystemProxyConfig(
      enabled: enabled,
      host: hostStr.isEmpty ? '127.0.0.1' : hostStr,
      port: portNum,
      exceptions: exceptions,
      desktopEnvironment: environmentName,
      raw: {
        'mode': modeStr,
        'httpHost': hostStr,
        'httpPort': portNum,
        'ignoreHosts': ignoreRaw,
      },
    );
  }

  @override
  Future<void> applyPlatformProxy({
    required String host,
    required int port,
    List<String> exceptions = const [],
  }) async {
    await runner('gsettings', ['set', _schemaHttp, 'host', host]);
    await runner('gsettings', ['set', _schemaHttp, 'port', port.toString()]);
    await runner('gsettings', ['set', _schemaHttps, 'host', host]);
    await runner('gsettings', ['set', _schemaHttps, 'port', port.toString()]);
    await runner('gsettings', ['set', _schemaSocks, 'host', host]);
    await runner('gsettings', ['set', _schemaSocks, 'port', port.toString()]);

    final ignoreList = exceptions.isEmpty
        ? "['localhost', '127.0.0.0/8', '::1', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']"
        : "[${exceptions.map((e) => "'$e'").join(', ')}]";

    await runner('gsettings', ['set', baseSchema, 'ignore-hosts', ignoreList]);
    await runner('gsettings', ['set', baseSchema, 'mode', 'manual']);
  }

  @override
  Future<void> restorePlatformProxy(SystemProxyConfig backup) async {
    final mode = (backup.raw['mode'] as String?) ?? (backup.enabled ? 'manual' : 'none');
    final prevHost = (backup.raw['httpHost'] as String?) ?? backup.host;
    final prevPort = (backup.raw['httpPort'] as int?) ?? backup.port;
    final ignoreHosts = (backup.raw['ignoreHosts'] as String?) ?? "['localhost', '127.0.0.0/8', '::1']";

    await runner('gsettings', ['set', _schemaHttp, 'host', prevHost]);
    await runner('gsettings', ['set', _schemaHttp, 'port', prevPort.toString()]);
    await runner('gsettings', ['set', _schemaHttps, 'host', prevHost]);
    await runner('gsettings', ['set', _schemaHttps, 'port', prevPort.toString()]);
    await runner('gsettings', ['set', _schemaSocks, 'host', prevHost]);
    await runner('gsettings', ['set', _schemaSocks, 'port', prevPort.toString()]);
    await runner('gsettings', ['set', baseSchema, 'ignore-hosts', ignoreHosts]);
    await runner('gsettings', ['set', baseSchema, 'mode', mode]);
  }

  @override
  Future<void> disablePlatformProxy() async {
    await runner('gsettings', ['set', baseSchema, 'mode', 'none']);
  }
}

/// Backwards compatibility alias for GNOME desktop.
typedef GnomeSystemProxyManager = GSettingsProxyManager;

/// System proxy manager for KDE Plasma desktop environment using kwriteconfig / kioslaverc.
class KdeSystemProxyManager extends SystemProxyManager {
  KdeSystemProxyManager({
    required super.configDirectory,
    super.runner,
    this.kwriteTool = 'kwriteconfig6',
    this.kreadTool = 'kreadconfig6',
  });

  final String kwriteTool;
  final String kreadTool;

  @override
  String get environmentName => 'KDE Plasma';

  @override
  bool get isSupported => Platform.isLinux;

  @override
  Future<SystemProxyConfig> readCurrentConfig() async {
    final typeRes = await runner(kreadTool, [
      '--file',
      'kioslaverc',
      '--group',
      'Proxy Settings',
      '--key',
      'ProxyType',
    ]);
    final proxyType = int.tryParse(typeRes.stdout.toString().trim()) ?? 0;
    // KDE: ProxyType 1 = Manual proxy; 0 = Direct / No proxy.
    final enabled = (proxyType == 1);

    final httpRes = await runner(kreadTool, [
      '--file',
      'kioslaverc',
      '--group',
      'Proxy Settings',
      '--key',
      'httpProxy',
    ]);
    final httpProxy = httpRes.stdout.toString().trim();
    var host = '127.0.0.1';
    var port = 2080;
    if (httpProxy.isNotEmpty) {
      final uri = Uri.tryParse(httpProxy.startsWith('http') ? httpProxy : 'http://$httpProxy');
      if (uri != null) {
        host = uri.host.isNotEmpty ? uri.host : '127.0.0.1';
        port = uri.port != 0 ? uri.port : 2080;
      }
    }

    final noProxyRes = await runner(kreadTool, [
      '--file',
      'kioslaverc',
      '--group',
      'Proxy Settings',
      '--key',
      'NoProxyFor',
    ]);
    final exceptions = noProxyRes.stdout
        .toString()
        .trim()
        .split(RegExp(r'[,;]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    return SystemProxyConfig(
      enabled: enabled,
      host: host,
      port: port,
      exceptions: exceptions,
      desktopEnvironment: environmentName,
      raw: {
        'ProxyType': proxyType,
        'httpProxy': httpProxy,
        'NoProxyFor': exceptions.join(','),
      },
    );
  }

  @override
  Future<void> applyPlatformProxy({
    required String host,
    required int port,
    List<String> exceptions = const [],
  }) async {
    final httpUrl = 'http://$host:$port';
    final socksUrl = 'socks://$host:$port';
    final noProxy = exceptions.isEmpty
        ? 'localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16'
        : exceptions.join(',');

    await runner(kwriteTool, [
      '--file',
      'kioslaverc',
      '--group',
      'Proxy Settings',
      '--key',
      'ProxyType',
      '1',
    ]);
    await runner(kwriteTool, [
      '--file',
      'kioslaverc',
      '--group',
      'Proxy Settings',
      '--key',
      'httpProxy',
      httpUrl,
    ]);
    await runner(kwriteTool, [
      '--file',
      'kioslaverc',
      '--group',
      'Proxy Settings',
      '--key',
      'httpsProxy',
      httpUrl,
    ]);
    await runner(kwriteTool, [
      '--file',
      'kioslaverc',
      '--group',
      'Proxy Settings',
      '--key',
      'socksProxy',
      socksUrl,
    ]);
    await runner(kwriteTool, [
      '--file',
      'kioslaverc',
      '--group',
      'Proxy Settings',
      '--key',
      'NoProxyFor',
      noProxy,
    ]);

    await _notifyKde();
  }

  @override
  Future<void> restorePlatformProxy(SystemProxyConfig backup) async {
    final proxyType = (backup.raw['ProxyType'] as int?) ?? (backup.enabled ? 1 : 0);
    final prevHttp = (backup.raw['httpProxy'] as String?) ?? (backup.enabled ? 'http://${backup.host}:${backup.port}' : '');
    final prevNoProxy = (backup.raw['NoProxyFor'] as String?) ?? backup.exceptions.join(',');

    await runner(kwriteTool, [
      '--file',
      'kioslaverc',
      '--group',
      'Proxy Settings',
      '--key',
      'ProxyType',
      proxyType.toString(),
    ]);
    if (prevHttp.isNotEmpty) {
      await runner(kwriteTool, [
        '--file',
        'kioslaverc',
        '--group',
        'Proxy Settings',
        '--key',
        'httpProxy',
        prevHttp,
      ]);
    }
    await runner(kwriteTool, [
      '--file',
      'kioslaverc',
      '--group',
      'Proxy Settings',
      '--key',
      'NoProxyFor',
      prevNoProxy,
    ]);

    await _notifyKde();
  }

  @override
  Future<void> disablePlatformProxy() async {
    await runner(kwriteTool, [
      '--file',
      'kioslaverc',
      '--group',
      'Proxy Settings',
      '--key',
      'ProxyType',
      '0',
    ]);
    await _notifyKde();
  }

  Future<void> _notifyKde() async {
    try {
      await runner('qdbus', [
        'org.kde.KIO.Scheduler',
        '/KIO/Scheduler',
        'reparseSlaveConfiguration',
        '',
      ]);
    } catch (_) {
      try {
        await runner('dbus-send', [
          '--type=signal',
          '/KIO/Scheduler',
          'org.kde.KIO.Scheduler.reparseSlaveConfiguration',
          'string:""',
        ]);
      } catch (_) {}
    }
  }
}

/// Fallback manager for desktop environments without a unified system proxy mechanism.
class UnsupportedSystemProxyManager extends SystemProxyManager {
  UnsupportedSystemProxyManager({
    required super.configDirectory,
    required this.reason,
    this.detectedEnv = 'Unknown',
  });

  final String reason;
  final String detectedEnv;

  @override
  String get environmentName => 'Неподдерживаемое окружение ($detectedEnv)';

  @override
  bool get isSupported => false;

  @override
  String get unsupportedReason => reason;

  @override
  Future<SystemProxyConfig> readCurrentConfig() async {
    return SystemProxyConfig(
      enabled: false,
      host: '127.0.0.1',
      port: 2080,
      desktopEnvironment: detectedEnv,
    );
  }

  @override
  Future<void> applyPlatformProxy({
    required String host,
    required int port,
    List<String> exceptions = const [],
  }) async {
    throw UnsupportedError(unsupportedReason);
  }

  @override
  Future<void> restorePlatformProxy(SystemProxyConfig backup) async {}

  @override
  Future<void> disablePlatformProxy() async {}
}

/// Factory function to discover and instantiate the correct system proxy backend.
Future<SystemProxyManager> createSystemProxyManager({
  required Directory configDirectory,
  ProcessRunner? runner,
  WinINetApi? winApi,
  Map<String, String>? environment,
}) async {
  final run = runner ?? Process.run;
  final env = environment ?? Platform.environment;

  if (Platform.isWindows || winApi != null) {
    return WindowsSystemProxyManager(
      configDirectory: configDirectory,
      runner: run,
      api: winApi,
    );
  }

  if (Platform.isLinux) {
    final rawDesktop =
        env['XDG_CURRENT_DESKTOP'] ?? env['DESKTOP_SESSION'] ?? '';
    final desktop = rawDesktop.toUpperCase();

    // Probe available GSettings schemas first
    final availableSchemas = <String>{};
    try {
      final schemasRes = await run('gsettings', ['list-schemas']);
      if (schemasRes.exitCode == 0) {
        availableSchemas.addAll(
          LineSplitter.split(schemasRes.stdout.toString()).map((s) => s.trim()),
        );
      }
    } catch (_) {}

    // 1. Cinnamon
    if (desktop.contains('CINNAMON')) {
      if (availableSchemas.contains('org.cinnamon.system.proxy')) {
        return GSettingsProxyManager(
          configDirectory: configDirectory,
          baseSchema: 'org.cinnamon.system.proxy',
          desktopName: 'Cinnamon Desktop',
          runner: run,
        );
      } else if (availableSchemas.contains('org.gnome.system.proxy')) {
        return GSettingsProxyManager(
          configDirectory: configDirectory,
          baseSchema: 'org.gnome.system.proxy',
          desktopName: 'Cinnamon Desktop (GNOME backend)',
          runner: run,
        );
      } else {
        return UnsupportedSystemProxyManager(
          configDirectory: configDirectory,
          detectedEnv: 'Cinnamon',
          reason:
              'Схемы org.cinnamon.system.proxy и org.gnome.system.proxy не найдены в gsettings. '
              'Управление системным прокси недоступно.',
        );
      }
    }

    // 2. MATE
    if (desktop.contains('MATE')) {
      if (availableSchemas.contains('org.mate.system.proxy')) {
        return GSettingsProxyManager(
          configDirectory: configDirectory,
          baseSchema: 'org.mate.system.proxy',
          desktopName: 'MATE Desktop',
          runner: run,
        );
      } else if (availableSchemas.contains('org.gnome.system.proxy')) {
        return GSettingsProxyManager(
          configDirectory: configDirectory,
          baseSchema: 'org.gnome.system.proxy',
          desktopName: 'MATE Desktop (GNOME fallback)',
          runner: run,
        );
      } else {
        return UnsupportedSystemProxyManager(
          configDirectory: configDirectory,
          detectedEnv: 'MATE',
          reason:
              'Схема org.mate.system.proxy не найдена в gsettings. '
              'Управление системным прокси недоступно.',
        );
      }
    }

    // 3. GNOME / Budgie / Unity
    final isGnomeFamily = desktop.contains('GNOME') ||
        desktop.contains('BUDGIE') ||
        desktop.contains('UNITY');
    if (isGnomeFamily) {
      if (availableSchemas.contains('org.gnome.system.proxy')) {
        final name = desktop.contains('BUDGIE')
            ? 'Budgie Desktop'
            : (desktop.contains('UNITY') ? 'Unity Desktop' : 'GNOME Desktop');
        return GSettingsProxyManager(
          configDirectory: configDirectory,
          baseSchema: 'org.gnome.system.proxy',
          desktopName: name,
          runner: run,
        );
      } else {
        return UnsupportedSystemProxyManager(
          configDirectory: configDirectory,
          detectedEnv: 'GNOME / Budgie',
          reason:
              'Схема org.gnome.system.proxy не найдена в gsettings. '
              'Управление системным прокси недоступно.',
        );
      }
    }

    // 4. KDE Plasma
    final isKde = desktop.contains('KDE') || desktop.contains('PLASMA');
    if (isKde) {
      var writeTool = 'kwriteconfig6';
      var readTool = 'kreadconfig6';
      var hasTools = false;
      try {
        final w6 = await run('which', ['kwriteconfig6']);
        if (w6.exitCode == 0) {
          hasTools = true;
        } else {
          final w5 = await run('which', ['kwriteconfig5']);
          if (w5.exitCode == 0) {
            writeTool = 'kwriteconfig5';
            readTool = 'kreadconfig5';
            hasTools = true;
          }
        }
      } catch (_) {}

      if (!hasTools) {
        return UnsupportedSystemProxyManager(
          configDirectory: configDirectory,
          detectedEnv: 'KDE Plasma',
          reason:
              'В окружении KDE Plasma не найдены утилиты kwriteconfig6 или kwriteconfig5 (пакет kde-cli-tools). '
              'Управление системным прокси недоступно.',
        );
      }

      return KdeSystemProxyManager(
        configDirectory: configDirectory,
        runner: run,
        kwriteTool: writeTool,
        kreadTool: readTool,
      );
    }

    // 5. Fallback for generic desktop with org.gnome.system.proxy available
    if (availableSchemas.contains('org.gnome.system.proxy')) {
      return GSettingsProxyManager(
        configDirectory: configDirectory,
        baseSchema: 'org.gnome.system.proxy',
        desktopName: desktop.isNotEmpty ? desktop : 'Freedesktop Generic',
        runner: run,
      );
    }

    // 6. Hyprland, Sway, i3, wlroots, tiling WMs, headless
    final envName = rawDesktop.isNotEmpty ? rawDesktop : 'Tiling / Headless';
    return UnsupportedSystemProxyManager(
      configDirectory: configDirectory,
      detectedEnv: envName,
      reason:
          'Окружение $envName не предоставляет стандартного API системного прокси. '
          'Установка переменных окружения не влияет на уже запущенные процессы и приложения. '
          'Используйте системную службу TUN для направления трафика всей системы, либо укажите 127.0.0.1:2080 в настройках конкретного браузера.',
    );
  }

  return UnsupportedSystemProxyManager(
    configDirectory: configDirectory,
    detectedEnv: Platform.operatingSystem,
    reason:
        'Платформа ${Platform.operatingSystem} в настоящее время не поддерживает общесистемное управление прокси в Velum.',
  );
}
