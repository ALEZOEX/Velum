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
      _alloc = stdlib
          .lookupFunction<
            ffi.Pointer<ffi.Void> Function(ffi.Uint32, ffi.IntPtr),
            ffi.Pointer<ffi.Void> Function(int, int)
          >('GlobalAlloc');
      _free = stdlib
          .lookupFunction<
            ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>),
            ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)
          >('GlobalFree');
    } else {
      _alloc = (flags, bytes) {
        final mallocFn = stdlib
            .lookupFunction<
              ffi.Pointer<ffi.Void> Function(ffi.IntPtr),
              ffi.Pointer<ffi.Void> Function(int)
            >('malloc');
        final ptr = mallocFn(bytes);
        final u8 = ptr.cast<ffi.Uint8>();
        for (var i = 0; i < bytes; i++) {
          u8[i] = 0;
        }
        return ptr;
      };
      _free = stdlib
          .lookupFunction<
            ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>),
            ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)
          >('free');
    }
  }

  late final ffi.Pointer<ffi.Void> Function(int, int) _alloc;
  late final ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>) _free;

  int currentFlags = WinINetConstants.proxyTypeDirect;
  String? currentServer = '';
  String? currentBypass = '';
  String? currentPacUrl = '';

  @override
  int get lastError => 5;
  int? failOption;
  bool ignoreWrite = false;
  Map<String, dynamic> get snapshot => {
    'flags': currentFlags,
    'server': currentServer,
    'bypass': currentBypass,
    'pacUrl': currentPacUrl,
  };

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
    if (dwOption == failOption) return 0;
    if (ignoreWrite) return 1;
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

  ffi.Pointer<ffi.Uint16> _toUtf16(String? str) {
    if (str == null) return ffi.nullptr;
    final units = str.codeUnits;
    final ptr = globalAlloc(
      WinINetConstants.gptr,
      (units.length + 1) * 2,
    ).cast<ffi.Uint16>();
    for (var i = 0; i < units.length; i++) {
      ptr[i] = units[i];
    }
    ptr[units.length] = 0;
    return ptr;
  }

  String? _fromUtf16(ffi.Pointer<ffi.Uint16> ptr) {
    if (ptr.address == 0) return null;
    final codeUnits = <int>[];
    var i = 0;
    while (ptr[i] != 0) {
      codeUnits.add(ptr[i]);
      i++;
    }
    return String.fromCharCodes(codeUnits);
  }
}

Map<String, dynamic> clone(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

class FakeLinuxProxy {
  FakeLinuxProxy({this.kde = false, bool empty = false, bool absent = false}) {
    if (kde) {
      fields = {
        'ProxyType': '0',
        'httpProxy': empty ? '' : 'http://old-http:8001',
        'httpsProxy': empty ? '' : 'http://old-https:8002',
        'socksProxy': absent
            ? null
            : empty
            ? ''
            : 'socks://old-socks:8003',
        'NoProxyFor': '',
        'Proxy Config Script': null,
        'ReversedException': 'false',
      };
    } else {
      Map<String, dynamic> field(
        dynamic value,
        String type, {
        bool unset = false,
      }) => {'value': value, 'user': unset ? null : value, 'type': type};
      fields = {
        'mode': field('none', 's'),
        'autoconfig-url': field('https://corp.example/proxy.pac', 's'),
        'ignore-hosts': field(<String>[], 'as', unset: absent),
        'use-same-proxy': field(false, 'b', unset: absent),
        'http/enabled': field(false, 'b'),
        'http/host': field(empty ? '' : 'old-http', 's'),
        'http/port': field(empty ? 0 : 8001, 'i'),
        'https/host': field(empty ? '' : 'old-https', 's', unset: absent),
        'https/port': field(empty ? 0 : 8002, 'i', unset: absent),
        'socks/host': field(empty ? '' : 'old-socks', 's'),
        'socks/port': field(empty ? 0 : 8003, 'i'),
      };
    }
    defaults = clone(fields);
  }
  final bool kde;
  late Map<String, dynamic> fields;
  late Map<String, dynamic> defaults;
  final inherited = <String, String>{};
  String? failKey;
  bool failRead = false;
  bool missingCommand = false;
  bool ignoreWrites = false;
  int writes = 0;
  int notifications = 0;
  Future<ProcessResult> run(
    String command,
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    if (missingCommand) throw ProcessException(command, args, 'not found', 2);
    if (command == 'python3') {
      if (failRead) {
        return ProcessResult(1, 1, '', 'GSettings schema not found');
      }
      return ProcessResult(1, 0, jsonEncode(fields), '');
    }
    if (command.startsWith('kreadconfig')) {
      final key = args[args.indexOf('--key') + 1];
      final effective = args[args.indexOf('--file') + 1] == 'kioslaverc';
      final value = fields[key] ?? (effective ? inherited[key] : null);
      return ProcessResult(
        1,
        0,
        '${value ?? args[args.indexOf('--default') + 1]}\n',
        '',
      );
    }
    if (command == 'qdbus' || command == 'dbus-send') {
      notifications++;
      return ProcessResult(1, 0, '', '');
    }
    String key;
    if (command == 'gsettings') {
      final parts = args[1].split('.');
      key = parts.last == 'proxy' ? args[2] : '${parts.last}/${args[2]}';
    } else if (command.startsWith('kwriteconfig')) {
      key = args[args.indexOf('--key') + 1];
    } else {
      throw StateError('Unexpected executable: $command');
    }
    writes++;
    if (key == failKey) {
      return ProcessResult(1, 1, '', 'mock write denied: $key');
    }
    if (!ignoreWrites) {
      if (kde) {
        fields[key] = args.contains('--delete') ? null : args.last;
      } else if (args.first == 'reset') {
        fields[key] = {
          ...Map<String, dynamic>.from(defaults[key] as Map),
          'user': null,
        };
      } else {
        final value = jsonDecode(args.last);
        fields[key] = {
          ...Map<String, dynamic>.from(fields[key] as Map),
          'user': value,
          'value': value,
        };
      }
    }
    return ProcessResult(1, 0, '', '');
  }

  SystemProxyManager manager(Directory directory) => kde
      ? KdeSystemProxyManager(configDirectory: directory, runner: run)
      : GSettingsProxyManager(
          configDirectory: directory,
          baseSchema: 'org.gnome.system.proxy',
          desktopName: 'GNOME',
          runner: run,
        );
}

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('velum-proxy-test-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  const host = '127.0.0.1';
  const port = 2080;
  Future<void> enable(SystemProxyManager manager) =>
      manager.enable(host: host, port: port);
  Future<void> restore(SystemProxyManager manager) =>
      manager.restore(host: host, port: port);
  Future<bool> recover(SystemProxyManager manager) =>
      manager.recoverIfOrphaned(host: host, port: port);
  Matcher conflict() => isA<SystemProxyConflictException>().having(
    (e) => e.status,
    'status',
    SystemProxyStatus.conflict,
  );

  test('model preserves null, empty, false, zero and PAC', () {
    const config = SystemProxyConfig(
      enabled: false,
      host: '',
      port: 0,
      autoDetect: true,
      pacUrl: 'https://corp.example/pac',
      raw: {'absent': null, 'empty': '', 'disabled': false, 'zero': 0},
    );
    expect(
      SystemProxyConfig.fromJson(config.toJson()).toJson(),
      config.toJson(),
    );
  });
  for (final kde in [false, true]) {
    final backend = kde ? 'KDE' : 'GSettings';
    group(backend, () {
      for (final variant in ['different', 'empty', 'absent']) {
        test('exact round-trip of $variant HTTP/HTTPS/SOCKS', () async {
          final os = FakeLinuxProxy(
            kde: kde,
            empty: variant == 'empty',
            absent: variant == 'absent',
          );
          final original = clone(os.fields);
          final manager = os.manager(directory);
          await enable(manager);
          await restore(manager);
          expect(os.fields, original);
          expect(await manager.backupFile.exists(), isFalse);
          final count = os.writes;
          await restore(manager);
          expect(os.writes, count);
        });
      }
      test('original PAC is restored', () async {
        final os = FakeLinuxProxy(kde: kde);
        if (kde) {
          os.fields['ProxyType'] = '2';
          os.fields['Proxy Config Script'] =
              'https://corp.example/original.pac';
        } else {
          os.fields['mode'] = {'type': 's', 'user': 'auto', 'value': 'auto'};
        }
        final original = clone(os.fields);
        final manager = os.manager(directory);
        await enable(manager);
        await restore(manager);
        expect(os.fields, original);
      });
      test('repeated apply preserves original and session', () async {
        final os = FakeLinuxProxy(kde: kde);
        final original = clone(os.fields);
        final manager = os.manager(directory);
        await enable(manager);
        final first =
            jsonDecode(await manager.backupFile.readAsString()) as Map;
        await enable(manager);
        final second =
            jsonDecode(await manager.backupFile.readAsString()) as Map;
        expect(second['id'], first['id']);
        expect(second['original'], first['original']);
        await restore(manager);
        expect(os.fields, original);
      });
      test(
        'partial restore retains backup and resumes after restart',
        () async {
          final os = FakeLinuxProxy(kde: kde);
          final original = clone(os.fields);
          final manager = os.manager(directory);
          await enable(manager);
          os.failKey = kde ? 'httpsProxy' : 'https/host';
          await expectLater(
            restore(manager),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                contains('mock write denied'),
              ),
            ),
          );
          expect(await manager.backupFile.exists(), isTrue);
          expect(os.fields, isNot(original));
          expect(
            kde ? os.fields['httpProxy'] : os.fields['http/host'],
            kde ? original['httpProxy'] : original['http/host'],
          );
          expect(await manager.getStatus(host, port), SystemProxyStatus.error);
          os.failKey = null;
          final restarted = os.manager(directory);
          expect(await recover(restarted), isTrue);
          expect(os.fields, original);
          expect(await restarted.backupFile.exists(), isFalse);
        },
      );
      test('partial apply recovers after restart', () async {
        final os = FakeLinuxProxy(kde: kde);
        final original = clone(os.fields);
        final manager = os.manager(directory);
        os.failKey = kde ? 'httpsProxy' : 'https/host';
        await expectLater(enable(manager), throwsFormatException);
        expect(await manager.backupFile.exists(), isTrue);
        os.failKey = null;
        expect(await recover(os.manager(directory)), isTrue);
        expect(os.fields, original);
      });
      test('silent write failure is rejected by readback', () async {
        final os = FakeLinuxProxy(kde: kde)..ignoreWrites = true;
        final manager = os.manager(directory);
        await expectLater(enable(manager), throwsFormatException);
        expect(await manager.backupFile.exists(), isTrue);
      });
      test('restore without backup makes zero OS writes', () async {
        final os = FakeLinuxProxy(kde: kde);
        final original = clone(os.fields);
        await restore(os.manager(directory));
        expect(os.writes, 0);
        expect(os.notifications, 0);
        expect(os.fields, original);
      });
      for (final change in ['disabled', 'PAC', 'HTTPS', 'exceptions']) {
        test(
          'foreign $change preserves settings and backup as conflict',
          () async {
            final os = FakeLinuxProxy(kde: kde);
            final manager = os.manager(directory);
            await enable(manager);
            if (kde) {
              switch (change) {
                case 'disabled':
                  os.fields['ProxyType'] = '0';
                case 'PAC':
                  os.fields['ProxyType'] = '2';
                  os.fields['Proxy Config Script'] =
                      'https://foreign.example/pac';
                case 'HTTPS':
                  os.fields['httpsProxy'] = 'http://foreign:8080';
                case 'exceptions':
                  os.fields['NoProxyFor'] = 'private.example';
              }
            } else {
              final key = switch (change) {
                'disabled' => 'mode',
                'PAC' => 'autoconfig-url',
                'HTTPS' => 'https/host',
                _ => 'ignore-hosts',
              };
              final dynamic value = change == 'disabled'
                  ? 'none'
                  : change == 'exceptions'
                  ? ['foreign.example']
                  : 'foreign.example';
              os.fields[key] = {
                ...Map<String, dynamic>.from(os.fields[key] as Map),
                'value': value,
                'user': value,
              };
            }
            final foreign = clone(os.fields);
            final backup = await manager.backupFile.readAsString();
            final writes = os.writes;
            await expectLater(restore(manager), throwsA(conflict()));
            await expectLater(
              recover(os.manager(directory)),
              throwsA(conflict()),
            );
            await expectLater(enable(manager), throwsA(conflict()));
            expect(
              await manager.getStatus(host, port),
              SystemProxyStatus.conflict,
            );
            expect(os.fields, foreign);
            expect(os.writes, writes);
            expect(await manager.backupFile.readAsString(), backup);
          },
        );
      }
      test('missing executable keeps backup and returns error', () async {
        final os = FakeLinuxProxy(kde: kde);
        final manager = os.manager(directory);
        await enable(manager);
        os.missingCommand = true;
        await expectLater(
          restore(manager),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('not found'),
            ),
          ),
        );
        expect(await manager.backupFile.exists(), isTrue);
      });
    }, skip: !Platform.isLinux);
  }
  test('KDE removes a created override and restores inherited HTTPS', () async {
    final os = FakeLinuxProxy(kde: true);
    os.fields['httpsProxy'] = null;
    os.inherited['httpsProxy'] = 'http://system-default:8888';
    final original = clone(os.fields);
    final manager = os.manager(directory);
    await enable(manager);
    await restore(manager);
    expect(os.fields, original);
    expect(
      (await manager.readCurrentConfig()).raw['effective']['httpsProxy'],
      'http://system-default:8888',
    );
  }, skip: !Platform.isLinux);

  test('KDE restores a completely absent user configuration', () async {
    final os = FakeLinuxProxy(kde: true);
    os.fields.updateAll((key, value) => null);
    final original = clone(os.fields);
    final manager = os.manager(directory);
    await enable(manager);
    await restore(manager);
    expect(os.fields, original);
  }, skip: !Platform.isLinux);
  test('GSettings restores all absent user overrides', () async {
    final os = FakeLinuxProxy();
    for (final field in os.fields.values) {
      (field as Map)['user'] = null;
    }
    final original = clone(os.fields);
    final manager = os.manager(directory);
    await enable(manager);
    await restore(manager);
    expect(os.fields, original);
  }, skip: !Platform.isLinux);

  test('missing GSettings schema aborts before writes', () async {
    final os = FakeLinuxProxy()..failRead = true;
    final manager = os.manager(directory);
    await expectLater(
      enable(manager),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('schema not found'),
        ),
      ),
    );
    expect(os.writes, 0);
    expect(await manager.backupFile.exists(), isFalse);
  }, skip: !Platform.isLinux);
  group('Windows', () {
    late MockWinINetApi api;
    late WindowsSystemProxyManager manager;
    setUp(() {
      api = MockWinINetApi();
      manager = WindowsSystemProxyManager(configDirectory: directory, api: api);
    });
    for (final flags in [4, 8, 12]) {
      test('original PAC/AutoDetect flags $flags round-trip', () async {
        api.currentFlags = flags;
        api.currentServer = 'http=http:81;https=https:82;socks=socks:83';
        api.currentPacUrl = 'https://corp.example/pac';
        api.currentBypass = '*.internal;<local>';
        final original = Map<String, dynamic>.from(api.snapshot);
        await enable(manager);
        expect(api.currentFlags, WinINetConstants.proxyTypeProxy);
        await restore(manager);
        expect(api.snapshot, original);
        expect(await manager.backupFile.exists(), isFalse);
      });
    }
    for (final absent in [false, true]) {
      test(
        'Windows ${absent ? 'absent' : 'empty'} strings round-trip',
        () async {
          api.currentServer = absent ? null : '';
          api.currentBypass = absent ? null : '';
          api.currentPacUrl = absent ? null : '';
          final original = Map<String, dynamic>.from(api.snapshot);
          await enable(manager);
          await restore(manager);
          expect(api.snapshot, original);
        },
      );
    }
    for (final option in [75, 39, 37]) {
      test(
        'API failure $option retains backup and Windows error code',
        () async {
          final original = Map<String, dynamic>.from(api.snapshot);
          await enable(manager);
          api.failOption = option;
          await expectLater(
            restore(manager),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                contains('ошибка Windows 5'),
              ),
            ),
          );
          expect(await manager.backupFile.exists(), isTrue);
          expect(await manager.getStatus(host, port), SystemProxyStatus.error);
          api.failOption = null;
          expect(
            await recover(
              WindowsSystemProxyManager(configDirectory: directory, api: api),
            ),
            isTrue,
          );
          expect(api.snapshot, original);
          expect(await manager.backupFile.exists(), isFalse);
        },
      );
    }
    test('silent restore failure is rejected', () async {
      await enable(manager);
      api.ignoreWrite = true;
      await expectLater(restore(manager), throwsFormatException);
      expect(await manager.backupFile.exists(), isTrue);
    });
    test('failed apply retains original and recovers', () async {
      final original = Map<String, dynamic>.from(api.snapshot);
      api.failOption = 75;
      await expectLater(enable(manager), throwsFormatException);
      expect(await manager.backupFile.exists(), isTrue);
      api.failOption = null;
      expect(await recover(manager), isTrue);
      expect(api.snapshot, original);
    });
    for (final foreign in [
      'disabled',
      'PAC',
      'AutoDetect',
      'HTTPS',
      'bypass',
    ]) {
      test('foreign $foreign blocks restore and force', () async {
        await enable(manager);
        switch (foreign) {
          case 'disabled':
            api.currentFlags = 1;
          case 'PAC':
            api.currentFlags |= 4;
            api.currentPacUrl = 'https://foreign.example/pac';
          case 'AutoDetect':
            api.currentFlags |= 8;
          case 'HTTPS':
            api.currentServer = 'http=$host:$port;https=foreign:8080';
          case 'bypass':
            api.currentBypass = 'foreign.example';
        }
        final snapshot = Map<String, dynamic>.from(api.snapshot);
        final count = api.setCount;
        await expectLater(
          manager.restore(host: host, port: port, force: true),
          throwsA(conflict()),
        );
        await expectLater(recover(manager), throwsA(conflict()));
        expect(await manager.getStatus(host, port), SystemProxyStatus.conflict);
        expect(api.snapshot, snapshot);
        expect(api.setCount, count);
        expect(await manager.backupFile.exists(), isTrue);
      });
    }
    test(
      'no backup and repeated restore make zero additional writes',
      () async {
        await restore(manager);
        expect(api.setCount, 0);
        await enable(manager);
        await restore(manager);
        final count = api.setCount;
        await restore(manager);
        expect(api.setCount, count);
      },
    );
    test('repeated apply preserves original snapshot', () async {
      final original = Map<String, dynamic>.from(api.snapshot);
      await enable(manager);
      final first = jsonDecode(await manager.backupFile.readAsString()) as Map;
      await enable(manager);
      final second = jsonDecode(await manager.backupFile.readAsString()) as Map;
      expect(second['original'], first['original']);
      expect(second['id'], first['id']);
      await restore(manager);
      expect(api.snapshot, original);
    });
    test('crash recovery preserves live active session', () async {
      await enable(manager);
      final count = api.setCount;
      expect(
        await manager.recoverIfOrphaned(
          host: host,
          port: port,
          isVpnRunning: true,
          isProxyInboundActive: true,
          userWantsProxy: true,
        ),
        isFalse,
      );
      expect(api.setCount, count);
      expect(await manager.backupFile.exists(), isTrue);
    });
    for (final backup in ['{', '{"enabled":false}']) {
      test(
        'legacy or corrupt backup is retained without OS writes: $backup',
        () async {
          await manager.backupFile.writeAsString(backup);
          await expectLater(restore(manager), throwsFormatException);
          expect(api.setCount, 0);
          expect(await manager.backupFile.readAsString(), backup);
        },
      );
    }
  });
  test('GUI retains a restore error and reports error status', () async {
    final api = MockWinINetApi();
    final manager = WindowsSystemProxyManager(
      configDirectory: directory,
      api: api,
    );
    final client = VelumClient(directory: directory, proxyManager: manager)
      ..state = 'running'
      ..mode = 'proxy';
    try {
      await client.setSystemProxyEnabled(true);
      api.failOption = 75;
      await client.setSystemProxyEnabled(false);
      expect(client.message, contains('ошибка Windows 5'));
      expect(client.systemProxyStatus, SystemProxyStatus.error);
      expect(await manager.backupFile.exists(), isTrue);
    } finally {
      client.dispose();
    }
  });

  test(
    'production Gio reader distinguishes absent and explicit default in memory',
    () async {
      String? script;
      final manager = GSettingsProxyManager(
        configDirectory: directory,
        baseSchema: 'org.velum.AuditProxy',
        desktopName: 'Test',
        runner: (cmd, args, {environment}) async {
          script = args[1];
          return ProcessResult(1, 0, '{}', '');
        },
      );
      await manager.readCurrentConfig();
      await File('${directory.path}/org.velum.gschema.xml')
          .writeAsString('''<schemalist>
      <schema id="org.velum.AuditProxy" path="/org/velum/audit-proxy/">
        <key name="mode" type="s"><default>'none'</default></key>
        <key name="enabled" type="b"><default>false</default></key>
        <key name="ignore-hosts" type="as"><default>[]</default></key>
        <child name="http" schema="org.velum.AuditProxy.http"/>
      </schema>
      <schema id="org.velum.AuditProxy.http" path="/org/velum/audit-proxy/http/">
        <key name="host" type="s"><default>''</default></key>
        <key name="port" type="i"><default>0</default></key>
      </schema></schemalist>''');
      final compiled = await Process.run('glib-compile-schemas', [
        directory.path,
      ]);
      expect(compiled.exitCode, 0, reason: compiled.stderr.toString());
      final environment = {
        'GSETTINGS_BACKEND': 'memory',
        'GSETTINGS_SCHEMA_DIR': directory.path,
      };
      Future<Map<String, dynamic>> snapshot(String source) async {
        final result = await Process.run('python3', [
          '-c',
          source,
          'org.velum.AuditProxy',
        ], environment: environment);
        expect(result.exitCode, 0, reason: result.stderr.toString());
        return jsonDecode(result.stdout.toString()) as Map<String, dynamic>;
      }

      final initial = await snapshot(script!);
      expect(initial['enabled'], {'type': 'b', 'value': false, 'user': null});
      expect(initial['http/host'], {'type': 's', 'value': '', 'user': null});
      expect(initial['http/port'], {'type': 'i', 'value': 0, 'user': null});
      expect(initial['ignore-hosts'], {
        'type': 'as',
        'value': [],
        'user': null,
      });
      final overridden = script!.replaceFirst(
        "visit(new(sys.argv[1].encode()))",
        "settings = new(sys.argv[1].encode())\n"
            "    bind(gio, 'g_settings_set_boolean', c.c_int, ptr, text, c.c_int)(settings, b'enabled', 0)\n"
            "    visit(settings)",
      );
      expect((await snapshot(overridden))['enabled'], {
        'type': 'b',
        'value': false,
        'user': false,
      });
    },
    skip: !Platform.isLinux,
  );

  test('Cinnamon discovery selects its own schema', () async {
    final manager = await createSystemProxyManager(
      configDirectory: directory,
      environment: {'XDG_CURRENT_DESKTOP': 'X-Cinnamon'},
      runner: (cmd, args, {environment}) async => ProcessResult(
        1,
        0,
        cmd == 'gsettings' ? 'org.cinnamon.system.proxy\n' : '',
        '',
      ),
    );
    expect(manager, isA<GSettingsProxyManager>());
    expect(
      (manager as GSettingsProxyManager).baseSchema,
      'org.cinnamon.system.proxy',
    );
  }, skip: !Platform.isLinux);
  test('KDE discovery without tools is unsupported', () async {
    final manager = await createSystemProxyManager(
      configDirectory: directory,
      environment: {'XDG_CURRENT_DESKTOP': 'KDE'},
      runner: (cmd, args, {environment}) async =>
          ProcessResult(1, 1, '', 'not found'),
    );
    expect(manager.isSupported, isFalse);
  }, skip: !Platform.isLinux);
}
