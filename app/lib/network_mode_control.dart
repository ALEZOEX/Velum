import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'client.dart';

/// Selects the configured network mode and explains its actual system effect.
class NetworkModeControl extends StatelessWidget {
  const NetworkModeControl({
    super.key,
    required this.client,
    this.compact = false,
  });
  final VelumClient client;
  final bool compact;

  Future<void> _change(BuildContext context, String? mode) async {
    if (mode == null || client.busy || client.state == 'running') return;
    if (mode == 'tun' && !client.tunAllowed) return;
    try {
      await client.saveSettings({'mode': mode});
    } on FormatException catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось сохранить режим подключения.'),
          ),
        );
      }
    }
  }

  void _help(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => _ServiceManagementDialog(client: client),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: client,
    builder: (context, _) {
      final running = client.state == 'running';
      final configured = client.settings['mode'] == 'tun' ? 'tun' : 'proxy';
      final effective = running && client.mode.isNotEmpty
          ? client.mode
          : configured;
      final colors = Theme.of(context).colorScheme;
      final picker = DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: const ValueKey('network-mode-picker'),
          value: configured,
          isDense: true,
          isExpanded: true,
          style: TextStyle(
            fontFamily: 'ArenaSans',
            fontSize: 12,
            color: colors.onSurface,
          ),
          items: [
            const DropdownMenuItem(
              value: 'proxy',
              child: Text(
                'Локальный прокси',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            DropdownMenuItem(
              value: 'tun',
              enabled: client.tunAllowed,
              child: Text(
                client.tunAllowed ? 'Весь трафик · TUN' : 'TUN · нужна служба',
              ),
            ),
          ],
          onChanged: client.busy || running
              ? null
              : (value) => _change(context, value),
        ),
      );
      if (compact) return SizedBox(width: 156, child: picker);
      return Container(
        key: const ValueKey('network-mode-status'),
        margin: const EdgeInsets.only(top: 12, bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLowest.withValues(alpha: .86),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  effective == 'tun' ? Icons.alt_route : Icons.cable,
                  size: 18,
                  color: colors.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    effective == 'tun'
                        ? 'Системный туннель TUN'
                        : 'Локальный прокси',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(child: picker),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              effective == 'tun'
                  ? !client.tunAllowed
                        ? 'Текущая служба не может включить TUN. Установите системную службу Velum, чтобы направлять трафик всей системы.'
                        : running
                        ? 'Трафик системы направляется в TUN с учётом ваших правил маршрутизации.'
                        : 'После подключения трафик системы будет направлен в TUN с учётом правил маршрутизации.'
                  : client.settings['systemProxy'] == true &&
                          client.systemProxyStatus == SystemProxyStatus.enabled
                      ? (running
                          ? 'Системный прокси активен и VPN подключен. Трафик системы и браузеров направляется в Velum.'
                          : 'Системный прокси применен в ОС, но VPN отключен. Для доступа к сайтам запустите соединение.')
                      : 'Системный трафик не перенаправляется. Этот режим работает только для приложений, настроенных на прокси Velum, либо включите системный прокси.',
              style: TextStyle(
                fontSize: 12,
                color: colors.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            if (effective == 'proxy') ...[
              const SizedBox(height: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLow.withValues(alpha: .6),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: colors.outlineVariant.withValues(alpha: .5)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          client.systemProxyStatus == SystemProxyStatus.enabled
                              ? Icons.language
                              : (client.systemProxyStatus ==
                                      SystemProxyStatus.conflict
                                  ? Icons.warning_amber_rounded
                                  : Icons.language),
                          size: 16,
                          color: client.systemProxyStatus ==
                                  SystemProxyStatus.enabled
                              ? colors.primary
                              : (client.systemProxyStatus ==
                                      SystemProxyStatus.conflict
                                  ? Colors.amber
                                  : colors.onSurfaceVariant),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                !client.systemProxySupported
                                    ? 'Системный прокси: не поддерживается (${client.systemProxyEnvironment})'
                                    : client.systemProxyStatus ==
                                            SystemProxyStatus.enabled
                                        ? 'Системный прокси: применен в ОС'
                                        : client.systemProxyStatus ==
                                                SystemProxyStatus.conflict
                                            ? 'Системный прокси: конфликт в ОС'
                                            : 'Системный прокси: выключен в ОС',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: client.systemProxyStatus ==
                                          SystemProxyStatus.enabled
                                      ? colors.primary
                                      : (client.systemProxyStatus ==
                                              SystemProxyStatus.conflict
                                          ? Colors.amber
                                          : colors.onSurface),
                                ),
                              ),
                              if (client.systemProxyStatus ==
                                      SystemProxyStatus.enabled &&
                                  !running)
                                Text(
                                  'ОС направляет трафик на порт 2080, но VPN не запущен',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.amber.shade700,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (client.systemProxySupported)
                          Switch(
                            value: client.settings['systemProxy'] == true,
                            onChanged: (val) =>
                                client.setSystemProxyEnabled(val),
                          ),
                      ],
                    ),
                    const Divider(height: 12, thickness: 0.5),
                    Row(
                      children: [
                        Icon(
                          client.proxyInboundActive
                              ? Icons.sensors
                              : Icons.sensors_off_outlined,
                          size: 15,
                          color: client.proxyInboundActive
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Локальный прокси: ${client.proxyInboundActive ? "активен (127.0.0.1:${client.settings['proxyPort'] ?? 2080})" : "остановлен"}',
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(
                          running ? Icons.vpn_lock : Icons.vpn_lock_outlined,
                          size: 15,
                          color: running
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            running
                                ? 'VPN-соединение: установлено (${client.activeProfile.isNotEmpty ? client.activeProfile : "активно"})'
                                : 'VPN-соединение: отключено',
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            if (effective == 'proxy' && running)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(
                  'SOCKS5 / HTTP: ${client.status['proxy'] ?? '127.0.0.1:${client.settings['proxyPort'] ?? 2080}'}',
                  style: const TextStyle(fontSize: 12, fontFamily: 'ArenaMono'),
                ),
              ),
            if (running)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Для смены режима сначала отключите соединение.',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            if (!client.tunAllowed)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => _help(context),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.only(top: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'Как включить VPN для всей системы',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class _ServiceManagementDialog extends StatefulWidget {
  const _ServiceManagementDialog({required this.client});
  final VelumClient client;

  @override
  State<_ServiceManagementDialog> createState() =>
      _ServiceManagementDialogState();
}

class _ServiceManagementDialogState extends State<_ServiceManagementDialog> {
  VelumClient get client => widget.client;
  LinuxServiceState? _linuxState;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (Platform.isLinux) {
      _checkLinux();
    }
  }

  Future<void> _checkLinux() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final s = await client.checkLinuxServiceState();
    if (mounted) {
      setState(() {
        _linuxState = s;
        _loading = false;
      });
    }
  }

  Future<void> _runAction(
    Future<void> Function() action,
    String successMessage,
  ) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await action();
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(successMessage)),
      );
    } on FormatException catch (e) {
      if (e.message == 'trusted-installer-required') {
        if (mounted) {
          setState(() {
            _loading = false;
            _error =
                'В целях безопасности Linux запрещает повышение привилегий для файлов из пользовательского каталога.\n\n'
                'Выполните первоначальную установку в доверенный каталог /usr/local/lib/velum:\n'
                'sudo ./scripts/install-linux-service.sh\n\n'
                'После этого управление службой будет доступно прямо из интерфейса.';
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = e.message;
          });
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Не удалось выполнить операцию управления службой.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (Platform.isWindows) {
      return AlertDialog(
        title: const Text('Системный туннель TUN (Windows)'),
        content: const Text(
          'Для перенаправления трафика всей системы Velum устанавливает службу Windows. '
          'Потребуется подтверждение UAC. Служба запускает sing-box и TUN, '
          'а интерфейс продолжает работать без постоянных прав администратора.\n\n'
          'Если служба уже установлена, проверьте, что она запущена и собрана с поддержкой TUN. '
          'Обновить или удалить её можно командами:\n'
          'velumd.exe --service install --tun\n'
          'velumd.exe --service uninstall',
        ),
        actions: [
          FilledButton(
            onPressed: () => _runAction(
              () => client.installWindowsService(),
              'Служба Velum установлена и запущена.',
            ),
            child: const Text('Установить службу'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      );
    }

    // Linux layout
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.shield_outlined, size: 22, color: colors.primary),
          const SizedBox(width: 8),
          const Expanded(child: Text('Управление службой Linux')),
          if (_loading)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildStatusHeader(colors),
            const SizedBox(height: 12),
            _buildStatusDescription(colors),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.errorContainer.withValues(alpha: .35),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: colors.error.withValues(alpha: .5)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _error!,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onErrorContainer,
                        height: 1.4,
                      ),
                    ),
                    if (_error!.contains('sudo ./scripts/install-linux-service.sh'))
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            await Clipboard.setData(
                              const ClipboardData(
                                text: 'sudo ./scripts/install-linux-service.sh',
                              ),
                            );
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Команда скопирована в буфер.'),
                                ),
                              );
                            }
                          },
                          icon: const Icon(Icons.copy, size: 14),
                          label: const Text('Скопировать команду'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: _buildActions(),
    );
  }

  Widget _buildStatusHeader(ColorScheme colors) {
    final (icon, color, text) = switch (_linuxState) {
      LinuxServiceState.running => (
        Icons.check_circle_outline,
        const Color(0xff4ade80),
        'Служба активна: TUN готов',
      ),
      LinuxServiceState.installedStopped => (
        Icons.pause_circle_outline,
        const Color(0xfffbbf24),
        'Служба установлена, но остановлена',
      ),
      LinuxServiceState.unavailable => (
        Icons.error_outline,
        const Color(0xfffb7185),
        'Служба активна, но API недоступен',
      ),
      LinuxServiceState.notInstalled => (
        Icons.info_outline,
        const Color(0xff94a3b8),
        'Служба не установлена',
      ),
      LinuxServiceState.checkError => (
        Icons.warning_amber_outlined,
        const Color(0xfff87171),
        'Ошибка проверки systemd',
      ),
      null => (
        Icons.sync,
        colors.onSurfaceVariant,
        'Проверка состояния службы...',
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: .4)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusDescription(ColorScheme colors) => switch (_linuxState) {
    LinuxServiceState.running => const Text(
      'Системная служба velum.service запущена и готова направлять сетевой трафик через интерфейс TUN.',
      style: TextStyle(fontSize: 12, height: 1.4),
    ),
    LinuxServiceState.installedStopped => const Text(
      'Служба зарегистрирована в systemd, но сейчас остановлена. '
      'Нажмите «Запустить службу» для старта без необходимости открывать терминал.',
      style: TextStyle(fontSize: 12, height: 1.4),
    ),
    LinuxServiceState.unavailable => const Text(
      'Процесс службы активен в systemd, но REST API на 127.0.0.1:27841 не отвечает. '
      'Попробуйте перезапустить службу.',
      style: TextStyle(fontSize: 12, height: 1.4),
    ),
    LinuxServiceState.notInstalled => const Text(
      'Для создания виртуального интерфейса velum0 (TUN) и перенаправления системного трафика '
      'требуется системная служба Velum с правами CAP_NET_ADMIN.\n\n'
      'Локальный прокси-режим (SOCKS5/HTTP на порту 2080) остаётся доступным и без службы.',
      style: TextStyle(fontSize: 12, height: 1.4),
    ),
    LinuxServiceState.checkError => const Text(
      'Не удалось получить статус от systemd. Проверьте, что systemd работает '
      'в качестве системы инициализации ОС.',
      style: TextStyle(fontSize: 12, height: 1.4),
    ),
    null => const SizedBox.shrink(),
  };

  List<Widget> _buildActions() {
    if (_linuxState == null) {
      return [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
      ];
    }

    final actions = <Widget>[];

    switch (_linuxState!) {
      case LinuxServiceState.installedStopped:
        actions.add(
          FilledButton.icon(
            onPressed: _loading
                ? null
                : () => _runAction(
                      () => client.startLinuxService(),
                      'Служба Velum запущена. Режим TUN доступен.',
                    ),
            icon: const Icon(Icons.play_arrow, size: 16),
            label: const Text('Запустить службу'),
          ),
        );
        actions.add(
          TextButton(
            onPressed: _loading
                ? null
                : () => _runAction(
                      () => client.uninstallLinuxService(),
                      'Служба Velum удалена из системы.',
                    ),
            child: const Text('Удалить службу'),
          ),
        );
        break;

      case LinuxServiceState.running:
        actions.add(
          OutlinedButton.icon(
            onPressed: _loading
                ? null
                : () => _runAction(
                      () => client.stopLinuxService(),
                      'Служба Velum остановлена.',
                    ),
            icon: const Icon(Icons.stop, size: 16),
            label: const Text('Остановить службу'),
          ),
        );
        break;

      case LinuxServiceState.unavailable:
        actions.add(
          FilledButton.icon(
            onPressed: _loading
                ? null
                : () => _runAction(
                      () => client.startLinuxService(),
                      'Служба перезапущена.',
                    ),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Перезапустить службу'),
          ),
        );
        break;

      case LinuxServiceState.notInstalled:
        actions.add(
          FilledButton.icon(
            onPressed: _loading
                ? null
                : () => _runAction(
                      () => client.installLinuxService(),
                      'Служба Velum установлена и запущена.',
                    ),
            icon: const Icon(Icons.download, size: 16),
            label: const Text('Установить службу'),
          ),
        );
        actions.add(
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(
                const ClipboardData(
                  text: 'sudo ./scripts/install-linux-service.sh',
                ),
              );
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Команда скопирована.')),
                );
              }
            },
            icon: const Icon(Icons.copy, size: 14),
            label: const Text('Скопировать команду'),
          ),
        );
        break;

      case LinuxServiceState.checkError:
        actions.add(
          TextButton.icon(
            onPressed: _loading ? null : _checkLinux,
            icon: const Icon(Icons.refresh, size: 14),
            label: const Text('Повторить проверку'),
          ),
        );
        break;
    }

    actions.add(
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Закрыть'),
      ),
    );

    return actions;
  }
}
