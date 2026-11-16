import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:velum/linux_service.dart';

void main() {
  late List<List<String>> calls;
  late Set<String> files;
  String? unsafePath;
  String unsafeStat = '1000 81ed 1';
  late LinuxServiceController controller;

  setUp(() {
    calls = [];
    unsafePath = null;
    unsafeStat = '1000 81ed 1';
    files = {
      '/usr/local/lib/velum/velum-service-control',
      '/usr/local/lib/velum/linux_service_installer.py',
    };
    controller = LinuxServiceController(
      executable: '/opt/velum/app/build/linux/x64/release/bundle/velum',
      exists: (name) async => files.contains(name),
      runner: (executable, arguments) async {
        calls.add([executable, ...arguments]);
        if (executable == '/usr/bin/stat') {
          final name = arguments.last;
          final regular =
              name.endsWith('.sh') ||
              name.endsWith('.py') ||
              name.endsWith('.policy') ||
              [
                'velumd',
                'sing-box',
                'xray',
                'velum-service-control',
              ].contains(name.split('/').last);
          return ProcessResult(
            1,
            0,
            name == unsafePath
                ? unsafeStat
                : '0 ${regular ? '81ed' : '41ed'} ${regular ? '1' : '2'}',
            '',
          );
        }
        expect(executable, '/usr/bin/pkexec');
        return ProcessResult(1, 0, '', '');
      },
    );
  });

  test(
    'installed GUI reinstall passes exact custom token and no USER or bin-dir',
    () async {
      await controller.install(tokenFile: '/home/gui/custom/token');
      expect(calls.last, [
        '/usr/bin/pkexec',
        '/usr/local/lib/velum/velum-service-control',
        'install',
        '--token-file',
        '/home/gui/custom/token',
      ]);
      expect(calls.any((call) => call.contains('which')), isFalse);
    },
  );

  test('trusted repository is found relative to executable', () async {
    files.clear();
    files.add('/opt/velum/scripts/install-linux-service.sh');
    await controller.install(tokenFile: '/home/gui/custom/token');
    expect(calls.last[1], '/opt/velum/scripts/install-linux-service.sh');
    expect(calls.any((call) => call.last == '/opt/velum/bin/sing-box'), isTrue);
  });

  test(
    'untrusted repository removal script is rejected before Polkit',
    () async {
      files.clear();
      files.add('/opt/velum/scripts/install-linux-service.sh');
      unsafePath = '/opt/velum/scripts/uninstall-linux-service.sh';
      await expectLater(
        controller.install(tokenFile: '/home/gui/token'),
        throwsFormatException,
      );
      expect(calls.any((call) => call.first == '/usr/bin/pkexec'), isFalse);
    },
  );

  test('missing trusted installer keeps bootstrap explicit', () async {
    files.clear();
    await expectLater(
      controller.install(tokenFile: '/home/gui/token'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'trusted-installer-required',
        ),
      ),
    );
    expect(calls, isEmpty);
  });

  for (final value in ['1000 41ed 2', '0 41ff 2', '0 a1ff 1']) {
    test('untrusted ancestor is rejected before Polkit: $value', () async {
      unsafePath = '/usr/local/lib/velum';
      unsafeStat = value;
      await expectLater(
        controller.install(tokenFile: '/home/gui/token'),
        throwsFormatException,
      );
      expect(calls.any((call) => call.first == '/usr/bin/pkexec'), isFalse);
    });
  }

  for (final value in ['1000 81ed 1', '0 81ff 1', '0 a1ff 1', '0 81ed 2']) {
    test('untrusted executable is rejected before Polkit: $value', () async {
      unsafePath = '/usr/local/lib/velum/velum-service-control';
      unsafeStat = value;
      await expectLater(
        controller.install(tokenFile: '/home/gui/token'),
        throwsFormatException,
      );
      expect(calls.any((call) => call.first == '/usr/bin/pkexec'), isFalse);
    });
  }

  test(
    'uninstall always uses checked helper without destructive fallback',
    () async {
      await controller.control('uninstall');
      expect(calls.last, [
        '/usr/bin/pkexec',
        '/usr/local/lib/velum/velum-service-control',
        'uninstall',
      ]);
      expect(
        calls.any(
          (call) =>
              call.last == '/usr/local/lib/velum/linux_service_installer.py',
        ),
        isTrue,
      );
    },
  );

  test('helper validation failure prevents control operation', () async {
    unsafePath = '/usr/local/lib/velum/linux_service_installer.py';
    await expectLater(controller.control('start'), throwsFormatException);
    expect(calls.any((call) => call.first == '/usr/bin/pkexec'), isFalse);
  });
}
