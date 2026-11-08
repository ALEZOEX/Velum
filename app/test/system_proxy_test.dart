import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:velum/client.dart';

/// Test mock implementation of WinINetApi that simulates Windows API memory and structures.
class MockWinINetApi implements WinINetApi {
  MockWinINetApi() {
    final stdlib = Platform.isWindows
        ? ffi.DynamicLibrary.open('kernel32.dll')
        : ffi.DynamicLibrary.process();

    if (Platform.isWindows) {
      _alloc = stdlib.lookupFunction<
          ffi.Pointer<ffi.Void> Function(ffi.Uint32, ffi.IntPtr),
          ffi.Pointer<ffi.Void> Function(int, int)>('GlobalAlloc');
      _free = stdlib.lookupFunction<
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>),
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)>('GlobalFree');
    } else {
      _alloc = (flags, bytes) {
        final mallocFn = stdlib.lookupFunction<
            ffi.Pointer<ffi.Void> Function(ffi.IntPtr),
            ffi.Pointer<ffi.Void> Function(int)>('malloc');
        final ptr = mallocFn(bytes);
        final u8 = ptr.cast<ffi.Uint8>();
        for (var i = 0; i < bytes; i++) {
          u8[i] = 0;
        }
        return ptr;
      };
      _free = stdlib.lookupFunction<
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>),
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)>('free');
    }
  }

  late final ffi.Pointer<ffi.Void> Function(int, int) _alloc;
  late final ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>) _free;

  int currentFlags = WinINetConstants.proxyTypeDirect;
  String currentServer = '';
  String currentBypass = '';
  String currentPacUrl = '';

  final List<int> setOptionCalls = [];
  int queryCount = 0;
  int setCount = 0;

  @override
  ffi.Pointer<ffi.Void> globalAlloc(int uFlags, int dwBytes) =>
      _alloc(uFlags, dwBytes);

  @override
  ffi.Pointer<ffi.Void> globalFree(ffi.Pointer<ffi.Void> hMem) => _free(hMem);

  @override
  int queryOption(
    int hInternet,
    int dwOption,
    ffi.Pointer<ffi.Void> lpBuffer,
    ffi.Pointer<ffi.Uint32> lpdwBufferLength,
  ) {
    queryCount++;
    if (dwOption == WinINetConstants.internetOptionPerConnectionOption) {
      final pList = lpBuffer.cast<InternetPerConnOptionList>();
      final pOptions = pList.ref.pOptions;
      final count = pList.ref.dwOptionCount;
      for (var i = 0; i < count; i++) {
        final opt = pOptions[i];
        switch (opt.dwOption) {
          case WinINetConstants.internetPerConnFlags:
            opt.value.dwValue = currentFlags;
            break;
          case WinINetConstants.internetPerConnProxyServer:
            opt.value.pszValue = _toUtf16(currentServer);
            break;
          case WinINetConstants.internetPerConnProxyBypass:
            opt.value.pszValue = _toUtf16(currentBypass);
            break;
          case WinINetConstants.internetPerConnAutoconfigUrl:
            opt.value.pszValue = _toUtf16(currentPacUrl);
            break;
        }
      }
      return 1;
    }
    return 0;
  }

  @override
  int setOption(
    int hInternet,
    int dwOption,
    ffi.Pointer<ffi.Void> lpBuffer,
    int dwBufferLength,
  ) {
    setCount++;
    setOptionCalls.add(dwOption);
    if (dwOption == WinINetConstants.internetOptionPerConnectionOption) {
      final pList = lpBuffer.cast<InternetPerConnOptionList>();
      final pOptions = pList.ref.pOptions;
      final count = pList.ref.dwOptionCount;
      for (var i = 0; i < count; i++) {
        final opt = pOptions[i];
        switch (opt.dwOption) {
          case WinINetConstants.internetPerConnFlags:
            currentFlags = opt.value.dwValue;
            break;
          case WinINetConstants.internetPerConnProxyServer:
            currentServer = _fromUtf16(opt.value.pszValue);
            break;
          case WinINetConstants.internetPerConnProxyBypass:
            currentBypass = _fromUtf16(opt.value.pszValue);
            break;
          case WinINetConstants.internetPerConnAutoconfigUrl:
            currentPacUrl = _fromUtf16(opt.value.pszValue);
            break;
        }
      }
      return 1;
    }
    return 1;
  }

  ffi.Pointer<ffi.Uint16> _toUtf16(String str) {
    if (str.isEmpty) return ffi.nullptr;
    final units = str.codeUnits;
    final ptr = globalAlloc(0, (units.length + 1) * 2).cast<ffi.Uint16>();
    for (var i = 0; i < units.length; i++) {
      ptr[i] = units[i];
    }
    ptr[units.length] = 0;
    return ptr;
  }

  String _fromUtf16(ffi.Pointer<ffi.Uint16> ptr) {
    if (ptr.address == 0) return '';
    final codeUnits = <int>[];
    var i = 0;
    while (ptr[i] != 0) {
      codeUnits.add(ptr[i]);
      i++;
    }
    return String.fromCharCodes(codeUnits);
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('velum-proxy-test-');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('SystemProxyConfig model', () {
    test('serialization round-trip with pac and autodetect', () {
      const config = SystemProxyConfig(
        enabled: true,
        host: '127.0.0.1',
        port: 2080,
        exceptions: ['localhost', '127.*'],
        desktopEnvironment: 'Windows WinINet API',
        autoDetect: true,
        pacUrl: 'http://corp.internal/wpad.dat',
        raw: {'flags': 10},
      );

      final json = config.toJson();
      final restored = SystemProxyConfig.fromJson(json);

      expect(restored.enabled, isTrue);
      expect(restored.host, '127.0.0.1');
      expect(restored.port, 2080);
      expect(restored.exceptions, ['localhost', '127.*']);
      expect(restored.desktopEnvironment, 'Windows WinINet API');
      expect(restored.autoDetect, isTrue);
      expect(restored.pacUrl, 'http://corp.internal/wpad.dat');
      expect(restored.raw['flags'], 10);
    });

    test('matches validation', () {
      const active = SystemProxyConfig(
        enabled: true,
        host: '127.0.0.1',
        port: 2080,
      );
      expect(active.matches('127.0.0.1', 2080), isTrue);
      expect(active.matches('localhost', 2080), isTrue);
      expect(active.matches('127.0.0.1', 8080), isFalse);
      expect(active.matches('192.168.1.1', 2080), isFalse);

      const disabled = SystemProxyConfig(
        enabled: false,
        host: '127.0.0.1',
        port: 2080,
      );
      expect(disabled.matches('127.0.0.1', 2080), isFalse);
    });
  });

  group('WindowsSystemProxyManager with WinINet API', () {
    test('queries WinINet per-connection options and parses flags', () async {
      final mockApi = MockWinINetApi()
        ..currentFlags = WinINetConstants.proxyTypeProxy |
            WinINetConstants.proxyTypeAutoDetect
        ..currentServer = '127.0.0.1:2080'
        ..currentBypass = 'localhost;127.*;<local>'
        ..currentPacUrl = 'http://127.0.0.1/proxy.pac';

      final manager = WindowsSystemProxyManager(
        configDirectory: tempDir,
        api: mockApi,
      );

      final status = await manager.getStatus('127.0.0.1', 2080);
      expect(status, SystemProxyStatus.enabled);

      final config = await manager.readCurrentConfig();
      expect(config.enabled, isTrue);
      expect(config.host, '127.0.0.1');
      expect(config.port, 2080);
      expect(config.autoDetect, isTrue);
      expect(config.pacUrl, 'http://127.0.0.1/proxy.pac');
      expect(config.exceptions, contains('localhost'));
    });

    test('enables proxy via InternetSetOption and sets flags strictly to PROXY_TYPE_PROXY', () async {
      final mockApi = MockWinINetApi()
        ..currentFlags = WinINetConstants.proxyTypeAutoDetect; // User had auto-detect enabled

      final manager = WindowsSystemProxyManager(
        configDirectory: tempDir,
        api: mockApi,
      );

      await manager.enable(host: '127.0.0.1', port: 2080);

      // Verify backup was created storing original flags and autoDetect state
      expect(await manager.backupFile.exists(), isTrue);
      final backup = jsonDecode(await manager.backupFile.readAsString());
      expect(backup['enabled'], isFalse);
      expect(backup['autoDetect'], isTrue);

      // CRITICAL: WinINet flags during active Velum proxy must be strictly PROXY_TYPE_PROXY
      // so that Windows/browsers do not evaluate PAC/WPAD first and bypass Velum.
      expect(
        mockApi.currentFlags,
        WinINetConstants.proxyTypeProxy,
      );
      expect(mockApi.currentServer, '127.0.0.1:2080');

      // Verify notification options were dispatched
      expect(
        mockApi.setOptionCalls,
        contains(WinINetConstants.internetOptionSettingsChanged),
      );
      expect(
        mockApi.setOptionCalls,
        contains(WinINetConstants.internetOptionRefresh),
      );

      // Verify restoring restores original flags including autoDetect
      await manager.restore(host: '127.0.0.1', port: 2080);
      expect(mockApi.currentFlags, WinINetConstants.proxyTypeAutoDetect);
    });

    test('restores original settings and disables proxy cleanly', () async {
      final mockApi = MockWinINetApi()
        ..currentFlags = WinINetConstants.proxyTypeDirect;

      final manager = WindowsSystemProxyManager(
        configDirectory: tempDir,
        api: mockApi,
      );

      await manager.enable(host: '127.0.0.1', port: 2080);
      expect(mockApi.currentServer, '127.0.0.1:2080');

      await manager.restore(host: '127.0.0.1', port: 2080);
      expect(
        (mockApi.currentFlags & WinINetConstants.proxyTypeProxy) != 0,
        isFalse,
      );
      expect(await manager.backupFile.exists(), isFalse);
    });

    test('detects third-party conflict and aborts non-forced restore', () async {
      final mockApi = MockWinINetApi()
        ..currentFlags = WinINetConstants.proxyTypeProxy
        ..currentServer = 'foreign-corporate-proxy:8080';

      final manager = WindowsSystemProxyManager(
        configDirectory: tempDir,
        api: mockApi,
      );

      await manager.backupFile.writeAsString(jsonEncode(
        const SystemProxyConfig(enabled: false, host: '127.0.0.1', port: 2080).toJson(),
      ));

      expect(
        () => manager.restore(host: '127.0.0.1', port: 2080, force: false),
        throwsFormatException,
      );
      // Foreign proxy remains untouched
      expect(mockApi.currentServer, 'foreign-corporate-proxy:8080');
      expect(await manager.backupFile.exists(), isTrue);
    });
  });

  group('GSettingsProxyManager (GNOME, Cinnamon, MATE, Budgie)', () {
    test('supports custom base schemas with verified existence', () async {
      final setValues = <String, String>{};

      final mateManager = GSettingsProxyManager(
        configDirectory: tempDir,
        baseSchema: 'org.mate.system.proxy',
        desktopName: 'MATE Desktop',
        runner: (cmd, args, {environment}) async {
          if (args[0] == 'get') {
            final key = args.last;
            if (key == 'mode') return ProcessResult(1, 0, "'none'", '');
            if (key == 'host') return ProcessResult(2, 0, "''", '');
            if (key == 'port') return ProcessResult(3, 0, '0', '');
            if (key == 'ignore-hosts') return ProcessResult(4, 0, '[]', '');
          }
          if (args[0] == 'set') {
            setValues[args[1]] = args.last;
            return ProcessResult(5, 0, '', '');
          }
          return ProcessResult(99, 0, '', '');
        },
      );

      expect(mateManager.environmentName, 'MATE Desktop');
      await mateManager.enable(host: '127.0.0.1', port: 2080);

      expect(setValues['org.mate.system.proxy.http'], '2080');
      expect(setValues['org.mate.system.proxy'], 'manual');
    });
  });

  group('Desktop Discovery via createSystemProxyManager', () {
    test('selects Cinnamon specific schema if available', () async {
      final manager = await createSystemProxyManager(
        configDirectory: tempDir,
        environment: {'XDG_CURRENT_DESKTOP': 'X-Cinnamon'},
        runner: (cmd, args, {environment}) async {
          if (cmd == 'gsettings' && args[0] == 'list-schemas') {
            return ProcessResult(
              1,
              0,
              'org.cinnamon.system.proxy\norg.gnome.system.proxy\n',
              '',
            );
          }
          return ProcessResult(2, 0, '', '');
        },
      );

      expect(manager, isA<GSettingsProxyManager>());
      expect((manager as GSettingsProxyManager).baseSchema, 'org.cinnamon.system.proxy');
    });

    test('marks KDE as unsupported when kwriteconfig tools are missing', () async {
      final manager = await createSystemProxyManager(
        configDirectory: tempDir,
        environment: {'XDG_CURRENT_DESKTOP': 'KDE'},
        runner: (cmd, args, {environment}) async {
          if (cmd == 'which') {
            return ProcessResult(1, 1, '', 'not found');
          }
          return ProcessResult(2, 0, '', '');
        },
      );

      expect(manager.isSupported, isFalse);
      expect(manager, isA<UnsupportedSystemProxyManager>());
      expect(manager.unsupportedReason, contains('kde-cli-tools'));
    });

    test('marks Hyprland / Sway as unsupported with explicit guidance', () async {
      final manager = await createSystemProxyManager(
        configDirectory: tempDir,
        environment: {'XDG_CURRENT_DESKTOP': 'Hyprland'},
        runner: (cmd, args, {environment}) async {
          return ProcessResult(1, 1, '', '');
        },
      );

      expect(manager.isSupported, isFalse);
      expect(manager.unsupportedReason, contains('Hyprland'));
    });
  });

  group('Crash Recovery (recoverIfOrphaned)', () {
    test('does NOT recover if active VPN session is running with live inbound', () async {
      final mockApi = MockWinINetApi()
        ..currentFlags = WinINetConstants.proxyTypeProxy
        ..currentServer = '127.0.0.1:2080';

      final manager = WindowsSystemProxyManager(
        configDirectory: tempDir,
        api: mockApi,
      );

      await manager.backupFile.writeAsString(jsonEncode(
        const SystemProxyConfig(enabled: false, host: '127.0.0.1', port: 2080).toJson(),
      ));

      // GUI reopened while daemon is actively serving VPN traffic
      final recovered = await manager.recoverIfOrphaned(
        host: '127.0.0.1',
        port: 2080,
        isVpnRunning: true,
        isProxyInboundActive: true,
        userWantsProxy: true,
      );

      expect(recovered, isFalse);
      // Must not reset live settings
      expect(mockApi.currentServer, '127.0.0.1:2080');
      // Backup preserved for eventual normal disconnect
      expect(await manager.backupFile.exists(), isTrue);
    });

    test('recovers orphaned proxy when VPN or inbound listener is inactive', () async {
      final mockApi = MockWinINetApi()
        ..currentFlags = WinINetConstants.proxyTypeProxy
        ..currentServer = '127.0.0.1:2080';

      final manager = WindowsSystemProxyManager(
        configDirectory: tempDir,
        api: mockApi,
      );

      await manager.backupFile.writeAsString(jsonEncode(
        const SystemProxyConfig(enabled: false, host: '127.0.0.1', port: 2080).toJson(),
      ));

      // Daemon crashed, VPN is off, port is dead
      final recovered = await manager.recoverIfOrphaned(
        host: '127.0.0.1',
        port: 2080,
        isVpnRunning: false,
        isProxyInboundActive: false,
        userWantsProxy: true,
      );

      expect(recovered, isTrue);
      // Cleaned up to direct connection
      expect(
        (mockApi.currentFlags & WinINetConstants.proxyTypeProxy) != 0,
        isFalse,
      );
      expect(await manager.backupFile.exists(), isFalse);
    });

    test('cleans stale backup without modifying OS if current proxy does not point to Velum', () async {
      final mockApi = MockWinINetApi()
        ..currentFlags = WinINetConstants.proxyTypeProxy
        ..currentServer = 'corporate.proxy:8080';

      final manager = WindowsSystemProxyManager(
        configDirectory: tempDir,
        api: mockApi,
      );

      await manager.backupFile.writeAsString(jsonEncode(
        const SystemProxyConfig(enabled: false, host: '127.0.0.1', port: 2080).toJson(),
      ));

      final recovered = await manager.recoverIfOrphaned(
        host: '127.0.0.1',
        port: 2080,
        isVpnRunning: false,
        isProxyInboundActive: false,
        userWantsProxy: true,
      );

      expect(recovered, isFalse);
      expect(mockApi.currentServer, 'corporate.proxy:8080');
      expect(await manager.backupFile.exists(), isFalse);
    });
  });
}
