import 'package:flutter/material.dart';

import 'client.dart';
import 'tray_service.dart';

class ExitDialogs implements ExitInteraction {
  ExitDialogs(this.navigatorKey, this.client);
  final GlobalKey<NavigatorState> navigatorKey;
  final VelumClient client;

  @override
  Future<bool> confirmProtectionLoss() async {
    final context = navigatorKey.currentContext;
    if (context == null) return false;
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => PopScope(
            canPop: false,
            child: AlertDialog(
              title: const Text('Завершить Velum?'),
              content: Text(
                client.managedByService
                    ? 'Системная служба продолжит работу. Настройки системного прокси '
                          'будут восстановлены; путь трафика отдельных приложений может измениться.'
                    : 'Локальное соединение будет отключено, а настройки системного прокси '
                          'восстановлены. Приложения могут перейти на прямое соединение.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Выйти'),
                ),
              ],
            ),
          ),
        ) ??
        false;
  }

  @override
  Future<ExitFailureAction> cleanupFailed(Object error) async {
    final context = navigatorKey.currentContext;
    if (context == null) return ExitFailureAction.cancel;
    return await showDialog<ExitFailureAction>(
          context: context,
          barrierDismissible: false,
          builder: (context) => PopScope(
            canPop: false,
            child: AlertDialog(
              title: const Text('Безопасный выход не завершён'),
              content: Text(
                '$error\n\nПри выходе настройки сети могут остаться '
                'изменёнными или соединение может продолжить работу. '
                'Незавершённый журнал восстановления будет сохранён для следующего запуска.',
              ),
              actions: [
                TextButton(
                  onPressed: () =>
                      Navigator.pop(context, ExitFailureAction.cancel),
                  child: const Text('Отменить выход'),
                ),
                TextButton(
                  onPressed: () =>
                      Navigator.pop(context, ExitFailureAction.force),
                  child: const Text('Выйти несмотря на предупреждение'),
                ),
                FilledButton(
                  onPressed: () =>
                      Navigator.pop(context, ExitFailureAction.retry),
                  child: const Text('Повторить восстановление'),
                ),
              ],
            ),
          ),
        ) ??
        ExitFailureAction.cancel;
  }
}
