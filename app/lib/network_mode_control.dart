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

  Future<void> _install(BuildContext context) async {
    try {
      await client.installWindowsService();
      if (!context.mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Служба Velum установлена и запущена.')),
      );
    } on FormatException catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось установить службу Velum.')),
      );
    }
  }

  void _help(BuildContext context) {
    final windows = Platform.isWindows;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Системный туннель TUN'),
        content: Text(
          windows
              ? 'Для перенаправления трафика всей системы Velum устанавливает службу Windows. '
                    'Потребуется подтверждение UAC. Служба запускает sing-box и TUN, '
                    'а интерфейс продолжает работать без постоянных прав администратора.\n\n'
                    'Если служба уже установлена, проверьте, что она запущена и собрана с поддержкой TUN. '
                    'Обновить или удалить её можно командами:\n'
                    'velumd.exe --service install --tun\n'
                    'velumd.exe --service uninstall'
              : 'Для перенаправления трафика всей системы установите системную службу Velum с поддержкой TUN. В каталоге проекта выполните:\n\nsudo ./scripts/install-linux-service.sh\n\nПосле установки служба должна сообщить, что TUN доступен. Прокси-режим сам по себе не меняет маршруты системы.',
        ),
        actions: [
          if (windows)
            FilledButton(
              onPressed: () => _install(context),
              child: const Text('Установить службу'),
            )
          else
            TextButton(
              onPressed: () async {
                await Clipboard.setData(
                  const ClipboardData(
                    text: 'sudo ./scripts/install-linux-service.sh',
                  ),
                );
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Скопировать команду'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
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
                  : 'Системный трафик не перенаправляется. Этот режим работает только для приложений, настроенных на прокси Velum.',
              style: TextStyle(
                fontSize: 12,
                color: colors.onSurfaceVariant,
                height: 1.5,
              ),
            ),
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
