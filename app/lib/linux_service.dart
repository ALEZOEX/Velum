import 'dart:io';

typedef LinuxCommandRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// Resolves only explicit, trusted service entry points before Polkit executes
/// them. The privileged installer independently validates files and their data.
class LinuxServiceController {
  LinuxServiceController({
    LinuxCommandRunner? runner,
    Future<bool> Function(String)? exists,
    String? executable,
  }) : _runner = runner ?? _run,
       _exists = exists ?? ((name) => File(name).exists()),
       _executable = executable ?? Platform.resolvedExecutable;

  static const installedDirectory = '/usr/local/lib/velum';
  final LinuxCommandRunner _runner;
  final Future<bool> Function(String) _exists;
  final String _executable;

  static Future<ProcessResult> _run(
    String executable,
    List<String> arguments,
  ) => Process.run(
    executable,
    arguments,
    environment: {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LC_ALL': 'C'},
  );

  static String _parent(String name) {
    final separator = name.lastIndexOf('/');
    return separator <= 0 ? '/' : name.substring(0, separator);
  }

  static String _join(String folder, String name) =>
      folder == '/' ? '/$name' : '$folder/$name';

  Future<void> _checkTrustedFile(String name, {bool executable = true}) async {
    if (!name.startsWith('/') ||
        name
            .split('/')
            .skip(1)
            .any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const FormatException('Путь службы должен быть абсолютным.');
    }
    final components = name.split('/');
    var current = '/';
    for (final component in components.skip(1)) {
      current = _join(current, component);
      // stat without -L reports symlinks rather than following the final entry.
      // Each parent is checked separately before the next component is read.
      final result = await _runner('/usr/bin/stat', [
        '--format=%u %f %h',
        '--',
        current,
      ]);
      final fields = result.stdout.toString().trim().split(RegExp(r'\s+'));
      final owner = fields.isNotEmpty ? int.tryParse(fields[0]) : null;
      final mode = fields.length > 1
          ? int.tryParse(fields[1], radix: 16)
          : null;
      final links = fields.length > 2 ? int.tryParse(fields[2]) : null;
      final last = current == name;
      if (result.exitCode != 0 ||
          owner != 0 ||
          mode == null ||
          (mode & 0x12) != 0 ||
          (mode & 0xf000) != (last ? 0x8000 : 0x4000) ||
          (last && ((executable && (mode & 0x49) == 0) || links != 1))) {
        throw FormatException(
          'Небезопасный путь службы: $current. Требуются обычные файлы root '
          'и каталоги без записи для других пользователей; ссылки запрещены.',
        );
      }
    }
  }

  Future<ProcessResult> _privileged(List<String> command) async {
    await _checkTrustedFile(command.first);
    await _checkTrustedFile(
      _join(_parent(command.first), 'linux_service_installer.py'),
    );
    try {
      return await _runner('/usr/bin/pkexec', command);
    } on ProcessException catch (error) {
      throw FormatException('Ошибка запуска Polkit: ${error.message}');
    }
  }

  Future<ProcessResult> control(String action) async {
    if (!['start', 'stop', 'restart', 'status', 'uninstall'].contains(action)) {
      throw const FormatException('Неизвестное действие службы.');
    }
    return _privileged(['$installedDirectory/velum-service-control', action]);
  }

  Future<ProcessResult> install({required String tokenFile}) async {
    if (!tokenFile.startsWith('/')) {
      throw const FormatException('Путь токена должен быть абсолютным.');
    }
    final installed = '$installedDirectory/velum-service-control';
    if (await _exists(installed) &&
        await _exists('$installedDirectory/linux_service_installer.py')) {
      return _privileged([installed, 'install', '--token-file', tokenFile]);
    }
    // A root-owned source checkout may be used by a development GUI. Walk from
    // its executable, never from cwd, HOME or an environment-provided PATH.
    var folder = _parent(_executable);
    while (true) {
      final candidate = _join(folder, 'scripts/install-linux-service.sh');
      if (await _exists(candidate)) {
        await _checkTrustedFile(_join(folder, 'bin/velumd'));
        await _checkTrustedFile(_join(folder, 'bin/sing-box'));
        await _checkTrustedFile(
          _join(folder, 'scripts/uninstall-linux-service.sh'),
        );
        await _checkTrustedFile(
          _join(folder, 'packaging/linux/velum-service-control'),
        );
        await _checkTrustedFile(
          _join(folder, 'packaging/linux/app.velum.service.policy'),
          executable: false,
        );
        if (await _exists(_join(folder, 'bin/xray'))) {
          await _checkTrustedFile(_join(folder, 'bin/xray'));
        }
        return _privileged([candidate, '--token-file', tokenFile]);
      }
      final parent = _parent(folder);
      if (parent == folder) break;
      folder = parent;
    }
    throw const FormatException('trusted-installer-required');
  }
}
