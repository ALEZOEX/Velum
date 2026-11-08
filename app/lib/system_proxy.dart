import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math';

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

class SystemProxyConflictException extends FormatException {
  const SystemProxyConflictException([
    super.message = 'Настройки прокси изменены вне Velum. Автоматическое восстановление отменено; резервная копия сохранена.',
  ]);
  SystemProxyStatus get status => SystemProxyStatus.conflict;
}

bool _equal(dynamic a, dynamic b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && _equal(a[key], b[key]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        List.generate(a.length, (i) => i).every((i) => _equal(a[i], b[i]));
  }
  return a == b;
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
      exceptions:
          (json['exceptions'] as List<dynamic>?)
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
  int get lastError;
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

    _queryOption = wininet
        .lookupFunction<
          ffi.Int32 Function(
            ffi.IntPtr,
            ffi.Uint32,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Uint32>,
          ),
          int Function(int, int, ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint32>)
        >('InternetQueryOptionW');

    _setOption = wininet
        .lookupFunction<
          ffi.Int32 Function(
            ffi.IntPtr,
            ffi.Uint32,
            ffi.Pointer<ffi.Void>,
            ffi.Uint32,
          ),
          int Function(int, int, ffi.Pointer<ffi.Void>, int)
        >('InternetSetOptionW');

    _getLastError = kernel32
        .lookupFunction<ffi.Uint32 Function(), int Function()>('GetLastError');

    _globalAlloc = kernel32
        .lookupFunction<
          ffi.Pointer<ffi.Void> Function(ffi.Uint32, ffi.IntPtr),
          ffi.Pointer<ffi.Void> Function(int, int)
        >('GlobalAlloc');

    _globalFree = kernel32
        .lookupFunction<
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>),
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)
        >('GlobalFree');
  }

  int _lastError = 0;
  @override
  int get lastError => _lastError;
  late final int Function() _getLastError;

  late final int Function(
    int,
    int,
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Uint32>,
  )
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
  ) {
    final result = _queryOption(
      hInternet,
      dwOption,
      lpBuffer,
      lpdwBufferLength,
    );
    _lastError = result == 0 ? _getLastError() : 0;
    return result;
  }

  @override
  int setOption(
    int hInternet,
    int dwOption,
    ffi.Pointer<ffi.Void> lpBuffer,
    int dwBufferLength,
  ) {
    final result = _setOption(hInternet, dwOption, lpBuffer, dwBufferLength);
    _lastError = result == 0 ? _getLastError() : 0;
    return result;
  }

  @override
  ffi.Pointer<ffi.Void> globalAlloc(int uFlags, int dwBytes) =>
      _globalAlloc(uFlags, dwBytes);

  @override
  ffi.Pointer<ffi.Void> globalFree(ffi.Pointer<ffi.Void> hMem) =>
      _globalFree(hMem);
}

/// Abstract base class for platform-specific system proxy managers.
abstract class SystemProxyManager {
  SystemProxyManager({required this.configDirectory, ProcessRunner? runner})
    : runner = runner ?? Process.run;

  final Directory configDirectory;
  final ProcessRunner runner;

  File get backupFile => File('${configDirectory.path}/proxy_backup.json');

  /// Human-readable name of the platform/desktop environment backend.
  String get environmentName;

  /// Whether the current OS and desktop environment can be configured.
  bool get isSupported;

  /// Detailed reason when unsupported.
  String get unsupportedReason => '';

  bool _operationFailed = false;

  Future<Map<String, dynamic>?> _session() async {
    if (!await backupFile.exists()) return null;
    final data = jsonDecode(await backupFile.readAsString());
    if (data is! Map<String, dynamic> ||
        data['version'] != 2 ||
        data['backend'] != environmentName ||
        data['original'] is! Map ||
        data['applied'] is! Map ||
        data['id'] is! String) {
      throw const SystemProxyConflictException(
        'Резервная копия не содержит полного журнала владения для этого окружения. '
        'Автоматическая запись настроек отменена; копия сохранена.',
      );
    }
    return data;
  }

  Future<void> _saveSession(Map<String, dynamic> session) async {
    await configDirectory.create(recursive: true);
    final temporary = File(
      '${backupFile.path}.${Random.secure().nextInt(1 << 32)}.tmp',
    );
    try {
      await temporary.writeAsString(jsonEncode(session), flush: true);
      await temporary.rename(backupFile.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  bool _same(SystemProxyConfig a, SystemProxyConfig b) =>
      a.desktopEnvironment == b.desktopEnvironment && _equal(a.raw, b.raw);

  SystemProxyConfig _config(dynamic value) =>
      SystemProxyConfig.fromJson(Map<String, dynamic>.from(value as Map));

  bool _owned(Map<String, dynamic> session, SystemProxyConfig current) {
    final pending = session['pending'];
    if (pending is Map) {
      return _same(current, _config(pending['before'])) ||
          _same(current, _config(pending['after']));
    }
    return _same(current, _config(session['applied']));
  }

  Future<SystemProxyStatus> getStatus(String host, int port) async {
    if (!isSupported) return SystemProxyStatus.unsupported;
    try {
      final current = await readCurrentConfig();
      final session = await _session();
      if (session != null && !_owned(session, current)) {
        return SystemProxyStatus.conflict;
      }
      if (_operationFailed ||
          (session != null && session['phase'] != 'active')) {
        return SystemProxyStatus.error;
      }
      if (!current.enabled) return SystemProxyStatus.disabled;
      return current.matches(host, port)
          ? SystemProxyStatus.enabled
          : SystemProxyStatus.conflict;
    } on SystemProxyConflictException {
      return SystemProxyStatus.conflict;
    } catch (_) {
      return SystemProxyStatus.error;
    }
  }

  Future<SystemProxyConfig> readCurrentConfig();
  Future<void> applyPlatformProxy({
    required String host,
    required int port,
    List<String> exceptions = const [],
  });
  Future<void> restorePlatformProxy(SystemProxyConfig backup);
  Future<void> disablePlatformProxy();

  /// A write-ahead record bounds recovery to the exact before/after states of
  /// one OS write. Unrecognised partial writes must be resolved as conflicts.
  Future<void> changeRaw(
    Map<String, dynamic> raw,
    Future<void> Function() write,
  ) async {
    final session = await _session();
    if (session == null) {
      throw StateError('Изменение прокси требует активного журнала владения.');
    }
    final before = await readCurrentConfig();
    if (!_owned(session, before)) throw const SystemProxyConflictException();
    final after = SystemProxyConfig.fromJson({...before.toJson(), 'raw': raw});
    session['pending'] = {'before': before.toJson(), 'after': after.toJson()};
    await _saveSession(session);
    try {
      await write();
      final actual = await readCurrentConfig();
      if (!_same(actual, after)) {
        throw const FormatException(
          'ОС не подтвердила записанные настройки прокси.',
        );
      }
      session['applied'] = actual.toJson();
      session.remove('pending');
      await _saveSession(session);
    } catch (_) {
      _operationFailed = true;
      // Keep the write-ahead record even when the API reports failure after
      // changing settings. Recovery will compare both recorded states.
      rethrow;
    }
  }

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
    if (!isSupported) throw UnsupportedError(unsupportedReason);
    var session = await _session();
    final current = await readCurrentConfig();
    if (session == null) {
      session = {
        'version': 2,
        'backend': environmentName,
        'id':
            '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}',
        'original': current.toJson(),
        'applied': current.toJson(),
        'phase': 'applying',
      };
      await _saveSession(session);
    } else if (!_owned(session, current)) {
      throw const SystemProxyConflictException();
    }
    _operationFailed = false;
    try {
      await applyPlatformProxy(host: host, port: port, exceptions: exceptions);
      session = (await _session())!;
      session['phase'] = 'active';
      await _saveSession(session);
    } catch (_) {
      _operationFailed = true;
      rethrow;
    }
  }

  Future<void> restore({
    required String host,
    required int port,
    bool force = false,
  }) async {
    if (!isSupported) return;
    final session = await _session();
    // A caller's force flag never substitutes for proof of ownership.
    if (session == null) return;
    final current = await readCurrentConfig();
    if (!_owned(session, current)) throw const SystemProxyConflictException();
    _operationFailed = false;
    session['phase'] = 'restoring';
    await _saveSession(session);
    try {
      final original = _config(session['original']);
      await restorePlatformProxy(original);
      final actual = await readCurrentConfig();
      if (!_same(actual, original)) {
        throw const FormatException(
          'Исходные настройки прокси восстановлены не полностью. Копия сохранена.',
        );
      }
      await backupFile.delete();
    } catch (_) {
      _operationFailed = true;
      rethrow;
    }
  }

  Future<bool> recoverIfOrphaned({
    required String host,
    required int port,
    bool isVpnRunning = false,
    bool isProxyInboundActive = false,
    bool userWantsProxy = false,
  }) async {
    if (!isSupported || !await backupFile.exists()) return false;
    final session = (await _session())!;
    final current = await readCurrentConfig();
    if (!_owned(session, current)) throw const SystemProxyConflictException();
    if (session['phase'] == 'active' &&
        isVpnRunning &&
        userWantsProxy &&
        isProxyInboundActive) {
      return false;
    }
    await restore(host: host, port: port);
    return true;
  }

  Future<ProcessResult> checkedRun(String command, List<String> args) async {
    try {
      final result = await runner(command, args);
      if (result.exitCode != 0) {
        throw ProcessException(
          command,
          args,
          result.stderr.toString().trim(),
          result.exitCode,
        );
      }
      return result;
    } on ProcessException catch (error) {
      throw FormatException(
        'Ошибка $command: ${error.message} (код ${error.errorCode}).',
      );
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
      'WinINet API is only available natively on Windows.',
    );
  }

  @override
  String get environmentName => 'Windows WinINet API';

  @override
  bool get isSupported => Platform.isWindows || _customApi != null;

  ffi.Pointer<ffi.Void> _allocate(int bytes) {
    final ptr = api.globalAlloc(WinINetConstants.gptr, bytes);
    if (ptr == ffi.nullptr) {
      throw const FormatException('WinINet: недостаточно памяти.');
    }
    return ptr;
  }

  @override
  Future<SystemProxyConfig> readCurrentConfig() async {
    final allocations = <ffi.Pointer<ffi.Void>>[];
    ffi.Pointer<ffi.Void> allocate(int size) {
      final ptr = _allocate(size);
      allocations.add(ptr);
      return ptr;
    }

    ffi.Pointer<InternetPerConnOption>? options;
    try {
      final listMem = allocate(ffi.sizeOf<InternetPerConnOptionList>());
      options = allocate(ffi.sizeOf<InternetPerConnOption>() * 4)
          .cast<InternetPerConnOption>();
      final length = allocate(4).cast<ffi.Uint32>();
      length.value = ffi.sizeOf<InternetPerConnOptionList>();
      final list = listMem.cast<InternetPerConnOptionList>().ref;
      list.dwSize = length.value;
      list.pszConnection = ffi.nullptr;
      list.dwOptionCount = 4;
      list.pOptions = options;
      final ids = [
        WinINetConstants.internetPerConnFlags,
        WinINetConstants.internetPerConnProxyServer,
        WinINetConstants.internetPerConnProxyBypass,
        WinINetConstants.internetPerConnAutoconfigUrl,
      ];
      for (var i = 0; i < ids.length; i++) {
        options[i].dwOption = ids[i];
      }
      if (api.queryOption(
            0,
            WinINetConstants.internetOptionPerConnectionOption,
            listMem,
            length,
          ) ==
          0) {
        throw FormatException(
          'InternetQueryOptionW: ошибка Windows ${api.lastError}.',
        );
      }
      final flags = options[0].value.dwValue;
      final server = _readUtf16(options[1].value.pszValue);
      final bypass = _readUtf16(options[2].value.pszValue);
      final pac = _readUtf16(options[3].value.pszValue);
      final match = RegExp(r'(?:https?=|socks=)?([^:;]+):(\d+)')
          .firstMatch(server ?? '');
      return SystemProxyConfig(
        enabled: flags & WinINetConstants.proxyTypeProxy != 0,
        host: match?.group(1) ?? '',
        port: int.tryParse(match?.group(2) ?? '') ?? 0,
        exceptions: (bypass ?? '')
            .split(';')
            .where((s) => s.isNotEmpty)
            .toList(),
        desktopEnvironment: environmentName,
        autoDetect: flags & WinINetConstants.proxyTypeAutoDetect != 0,
        pacUrl: pac ?? '',
        raw: {
          'flags': flags,
          'server': server,
          'bypass': bypass,
          'pacUrl': pac,
        },
      );
    } finally {
      if (options != null) {
        for (var i = 1; i < 4; i++) {
          final ptr = options[i].value.pszValue;
          if (ptr != ffi.nullptr) api.globalFree(ptr.cast());
        }
      }
      for (final ptr in allocations.reversed) {
        api.globalFree(ptr);
      }
    }
  }

  void _setOption(int option, ffi.Pointer<ffi.Void> buffer, int size) {
    if (api.setOption(0, option, buffer, size) == 0) {
      throw FormatException(
        'InternetSetOptionW($option): ошибка Windows ${api.lastError}.',
      );
    }
  }

  Future<void> _writeRaw(Map<String, dynamic> raw) async {
    await changeRaw(raw, () async {
      final allocations = <ffi.Pointer<ffi.Void>>[];
      ffi.Pointer<ffi.Void> allocate(int size) {
        final ptr = _allocate(size);
        allocations.add(ptr);
        return ptr;
      }

      try {
        final listMem = allocate(ffi.sizeOf<InternetPerConnOptionList>());
        final options = allocate(ffi.sizeOf<InternetPerConnOption>() * 4)
            .cast<InternetPerConnOption>();
        final list = listMem.cast<InternetPerConnOptionList>().ref;
        list.dwSize = ffi.sizeOf<InternetPerConnOptionList>();
        list.pszConnection = ffi.nullptr;
        list.dwOptionCount = 4;
        list.pOptions = options;
        options[0].dwOption = WinINetConstants.internetPerConnFlags;
        options[0].value.dwValue = raw['flags'] as int;
        final keys = ['server', 'bypass', 'pacUrl'];
        final ids = [
          WinINetConstants.internetPerConnProxyServer,
          WinINetConstants.internetPerConnProxyBypass,
          WinINetConstants.internetPerConnAutoconfigUrl,
        ];
        for (var i = 0; i < keys.length; i++) {
          options[i + 1].dwOption = ids[i];
          final value = raw[keys[i]] as String?;
          if (value == null) {
            options[i + 1].value.pszValue = ffi.nullptr;
          } else {
            final ptr = allocate((value.length + 1) * 2).cast<ffi.Uint16>();
            for (var j = 0; j < value.length; j++) {
              ptr[j] = value.codeUnitAt(j);
            }
            ptr[value.length] = 0;
            options[i + 1].value.pszValue = ptr;
          }
        }
        _setOption(
          WinINetConstants.internetOptionPerConnectionOption,
          listMem,
          list.dwSize,
        );
        _setOption(
          WinINetConstants.internetOptionSettingsChanged,
          ffi.nullptr,
          0,
        );
        _setOption(WinINetConstants.internetOptionRefresh, ffi.nullptr, 0);
      } finally {
        for (final ptr in allocations.reversed) {
          api.globalFree(ptr);
        }
      }
    });
  }

  @override
  Future<void> applyPlatformProxy({
    required String host,
    required int port,
    List<String> exceptions = const [],
  }) async {
    final current = await readCurrentConfig();
    await _writeRaw({
      ...current.raw,
      'flags': WinINetConstants.proxyTypeProxy,
      'server': '$host:$port',
      'bypass': exceptions.join(';'),
    });
  }

  @override
  Future<void> restorePlatformProxy(SystemProxyConfig backup) =>
      _writeRaw(backup.raw);

  @override
  Future<void> disablePlatformProxy() async {
    final current = await readCurrentConfig();
    var flags =
        (current.raw['flags'] as int) & ~WinINetConstants.proxyTypeProxy;
    if (flags == 0) flags = WinINetConstants.proxyTypeDirect;
    await _writeRaw({...current.raw, 'flags': flags});
  }

  String? _readUtf16(ffi.Pointer<ffi.Uint16> ptr) {
    if (ptr == ffi.nullptr) return null;
    final units = <int>[];
    for (var i = 0; ptr[i] != 0; i++) {
      units.add(ptr[i]);
    }
    return String.fromCharCodes(units);
  }
}

String _variantLiteral(dynamic value) {
  if (value is String) return jsonEncode(value);
  if (value is bool || value is num) return value.toString();
  if (value is List) return '[${value.map(_variantLiteral).join(', ')}]';
  throw const FormatException('Неподдерживаемое значение GSettings.');
}

// gsettings get only reports effective values. Gio additionally distinguishes an
// absent user override from an explicitly stored empty/false/default value.
// This read-only helper uses the same GLib libraries as the desktop, without
// requiring the optional PyGObject package or hard-coded dconf schema paths.
const _gsettingsSnapshot = r'''import ctypes as c, ctypes.util, json, sys
try:
    gio = c.CDLL(ctypes.util.find_library('gio-2.0'))
    glib = c.CDLL(ctypes.util.find_library('glib-2.0'))
    obj = c.CDLL(ctypes.util.find_library('gobject-2.0'))
    def bind(lib, name, restype, *args):
        fn = getattr(lib, name); fn.restype = restype; fn.argtypes = list(args); return fn
    ptr, text = c.c_void_p, c.c_char_p
    source = bind(gio, 'g_settings_schema_source_get_default', ptr)()
    lookup = bind(gio, 'g_settings_schema_source_lookup', ptr, ptr, text, c.c_int)
    schema = lookup(source, sys.argv[1].encode(), 1) if source else None
    if not schema: raise ValueError('GSettings schema not found: ' + sys.argv[1])
    bind(gio, 'g_settings_schema_unref', None, ptr)(schema)
    new = bind(gio, 'g_settings_new', ptr, text)
    get = bind(gio, 'g_settings_get_value', ptr, ptr, text)
    user = bind(gio, 'g_settings_get_user_value', ptr, ptr, text)
    keys = bind(gio, 'g_settings_list_keys', ptr, ptr)
    children = bind(gio, 'g_settings_list_children', ptr, ptr)
    child = bind(gio, 'g_settings_get_child', ptr, ptr, text)
    kind = bind(glib, 'g_variant_get_type_string', text, ptr)
    unref = bind(glib, 'g_variant_unref', None, ptr)
    freev = bind(glib, 'g_strfreev', None, ptr)
    unobj = bind(obj, 'g_object_unref', None, ptr)
    def names(p):
        try:
            v = c.cast(p, c.POINTER(text)); i = 0; out = []
            while v[i]: out.append(v[i].decode()); i += 1
            return out
        finally: freev(p)
    def unpack(v):
        t = kind(v).decode()
        if t == 's': return bind(glib, 'g_variant_get_string', text, ptr, ptr)(v, None).decode()
        if t == 'b': return bool(bind(glib, 'g_variant_get_boolean', c.c_int, ptr)(v))
        if t in ('i', 'u'):
            return bind(glib, 'g_variant_get_' + ('int32' if t == 'i' else 'uint32'), c.c_int32 if t == 'i' else c.c_uint32, ptr)(v)
        if t == 'as':
            n = bind(glib, 'g_variant_n_children', c.c_size_t, ptr)(v)
            at = bind(glib, 'g_variant_get_child_value', ptr, ptr, c.c_size_t)
            out = []
            for i in range(n):
                item = at(v, i)
                try: out.append(unpack(item))
                finally: unref(item)
            return out
        raise ValueError('Unsupported GSettings type: ' + t)
    result = {}
    def visit(settings, prefix=''):
        try:
            for key in names(keys(settings)):
                effective, override = get(settings, key.encode()), user(settings, key.encode())
                try:
                    result[prefix + key] = {'type': kind(effective).decode(), 'value': unpack(effective), 'user': unpack(override) if override else None}
                finally:
                    unref(effective)
                    if override: unref(override)
            for name in names(children(settings)):
                visit(child(settings, name.encode()), prefix + name + '/')
        finally: unobj(settings)
    visit(new(sys.argv[1].encode()))
    print(json.dumps(result))
except Exception as error:
    print(str(error), file=sys.stderr); sys.exit(1)
''';

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

  @override
  String get environmentName => '$desktopName ($baseSchema)';
  @override
  bool get isSupported => Platform.isLinux;

  @override
  Future<SystemProxyConfig> readCurrentConfig() async {
    final result = await checkedRun('python3', [
      '-c',
      _gsettingsSnapshot,
      baseSchema,
    ]);
    final fields = jsonDecode(result.stdout.toString()) as Map<String, dynamic>;
    dynamic value(String key) => (fields[key] as Map?)?['value'];
    return SystemProxyConfig(
      enabled: value('mode') == 'manual',
      host: value('http/host') as String? ?? '',
      port: value('http/port') as int? ?? 0,
      pacUrl: value('autoconfig-url') as String? ?? '',
      exceptions: (value('ignore-hosts') as List?)?.cast<String>() ?? const [],
      desktopEnvironment: environmentName,
      raw: fields,
    );
  }

  Future<void> _writeField(String key, Map<String, dynamic> field) async {
    final current = await readCurrentConfig();
    if (_equal(current.raw[key], field)) return;
    final path = key.split('/');
    final schema = [baseSchema, ...path.take(path.length - 1)].join('.');
    final user = field['user'];
    await changeRaw({...current.raw, key: field}, () async {
      await checkedRun(
        'gsettings',
        user == null
            ? ['reset', schema, path.last]
            : ['set', schema, path.last, _variantLiteral(user)],
      );
    });
  }

  @override
  Future<void> applyPlatformProxy({
    required String host,
    required int port,
    List<String> exceptions = const [],
  }) async {
    final current = await readCurrentConfig();
    final values = <String, dynamic>{
      'http/host': host,
      'http/port': port,
      'https/host': host,
      'https/port': port,
      'socks/host': host,
      'socks/port': port,
      'ignore-hosts': exceptions,
      'mode': 'manual',
    };
    for (final entry in values.entries) {
      final old = current.raw[entry.key];
      if (old is! Map) {
        throw FormatException('Нет настройки GSettings ${entry.key}.');
      }
      await _writeField(entry.key, {
        ...Map<String, dynamic>.from(old),
        'user': entry.value,
        'value': entry.value,
      });
    }
  }

  @override
  Future<void> restorePlatformProxy(SystemProxyConfig backup) async {
    for (final entry in backup.raw.entries) {
      await _writeField(
        entry.key,
        Map<String, dynamic>.from(entry.value as Map),
      );
    }
  }

  @override
  Future<void> disablePlatformProxy() async {
    final current = await readCurrentConfig();
    await _writeField('mode', {
      ...Map<String, dynamic>.from(current.raw['mode'] as Map),
      'user': 'none',
      'value': 'none',
    });
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
    this.configFile,
  });

  final String kwriteTool;
  final String kreadTool;
  final String? configFile;
  String get _userFile =>
      configFile ??
      '${Platform.environment['XDG_CONFIG_HOME'] ?? '${Platform.environment['HOME']}/.config'}/kioslaverc';

  @override
  String get environmentName => 'KDE Plasma';

  @override
  bool get isSupported => Platform.isLinux;

  static const _keys = [
    'ProxyType',
    'httpProxy',
    'httpsProxy',
    'socksProxy',
    'NoProxyFor',
    'Proxy Config Script',
    'ReversedException',
  ];
  List<String> _args(String key, {bool effective = false}) => [
    '--file',
    effective ? 'kioslaverc' : _userFile,
    '--group',
    'Proxy Settings',
    '--key',
    key,
  ];

  @override
  Future<SystemProxyConfig> readCurrentConfig() async {
    final fields = <String, dynamic>{};
    final effective = <String, dynamic>{};
    final absent = '__velum_absent_${Random.secure().nextInt(1 << 32)}__';
    for (final key in _keys) {
      for (final inherited in [false, true]) {
        final result = await checkedRun(kreadTool, [
          ..._args(key, effective: inherited),
          '--default',
          absent,
        ]);
        final output = result.stdout.toString().replaceFirst(
          RegExp(r'\r?\n$'),
          '',
        );
        (inherited ? effective : fields)[key] = output == absent
            ? null
            : output;
      }
    }
    final uri = Uri.tryParse(effective['httpProxy'] as String? ?? '');
    return SystemProxyConfig(
      enabled: effective['ProxyType'] == '1',
      host: uri?.host ?? '',
      port: uri?.port ?? 0,
      exceptions: (effective['NoProxyFor'] as String? ?? '').split(','),
      pacUrl: effective['Proxy Config Script'] as String? ?? '',
      desktopEnvironment: environmentName,
      raw: {'file': _userFile, 'user': fields, 'effective': effective},
    );
  }

  Future<void> _writeField(
    String key,
    String? value, {
    String? inherited,
  }) async {
    final current = await readCurrentConfig();
    final user = Map<String, dynamic>.from(current.raw['user'] as Map);
    final effective = Map<String, dynamic>.from(
      current.raw['effective'] as Map,
    );
    final targetEffective = value ?? inherited;
    if (user[key] == value && effective[key] == targetEffective) return;
    await changeRaw(
      {
        ...current.raw,
        'user': {...user, key: value},
        'effective': {...effective, key: targetEffective},
      },
      () async {
        await checkedRun(kwriteTool, [
          ..._args(key),
          if (value == null)
            '--delete'
          else ...[
            '--type',
            'string',
            '--',
            value,
          ],
        ]);
      },
    );
  }

  @override
  Future<void> applyPlatformProxy({
    required String host,
    required int port,
    List<String> exceptions = const [],
  }) async {
    final values = {
      'httpProxy': 'http://$host:$port',
      'httpsProxy': 'http://$host:$port',
      'socksProxy': 'socks://$host:$port',
      'NoProxyFor': exceptions.join(','),
      'ProxyType': '1',
    };
    for (final entry in values.entries) {
      await _writeField(entry.key, entry.value);
    }
    await _notifyKde();
  }

  @override
  Future<void> restorePlatformProxy(SystemProxyConfig backup) async {
    final user = Map<String, dynamic>.from(backup.raw['user'] as Map);
    final effective = Map<String, dynamic>.from(backup.raw['effective'] as Map);
    for (final key in _keys) {
      if (!user.containsKey(key) || !effective.containsKey(key)) {
        throw FormatException('Резервная копия KDE не содержит $key.');
      }
      await _writeField(
        key,
        user[key] as String?,
        inherited: effective[key] as String?,
      );
    }
    await _notifyKde();
  }

  @override
  Future<void> disablePlatformProxy() async {
    await _writeField('ProxyType', '0');
    await _notifyKde();
  }

  Future<void> _notifyKde() async {
    try {
      await checkedRun('qdbus', [
        'org.kde.KIO.Scheduler',
        '/KIO/Scheduler',
        'reparseSlaveConfiguration',
        '',
      ]);
    } on FormatException {
      await checkedRun('dbus-send', [
        '--type=signal',
        '/KIO/Scheduler',
        'org.kde.KIO.Scheduler.reparseSlaveConfiguration',
        'string:""',
      ]);
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
    final isGnomeFamily =
        desktop.contains('GNOME') ||
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
