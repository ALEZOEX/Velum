import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'client.dart';
import 'arena_icons.dart';
import 'rotating_refresh.dart';
import 'network_mode_control.dart';

/// Connection screen translated from Arena's ConnectionView and PowerOrb.
class ArenaConnection extends StatefulWidget {
  const ArenaConnection({
    super.key,
    required this.client,
    required this.onImport,
    required this.onSubscriptions,
    required this.onInspect,
    this.onQr,
    this.onOpenUrl,
  });
  final VelumClient client;
  final VoidCallback onImport;
  final VoidCallback onSubscriptions;
  final ValueChanged<int> onInspect;
  final VoidCallback? onQr;
  final ValueChanged<String>? onOpenUrl;
  @override
  State<ArenaConnection> createState() => _ArenaConnectionState();
}

class _ArenaConnectionState extends State<ArenaConnection> {
  VelumClient get client => widget.client;
  String? provider;
  bool collapsed = false;
  String sort = 'none';
  Color get acid => Theme.of(context).colorScheme.primary;
  Color get muted => Theme.of(context).colorScheme.onSurfaceVariant;
  bool get running => client.state == 'running';
  Profile? get selected => client.profiles.isEmpty
      ? null
      : client.profiles[client.selected.clamp(0, client.profiles.length - 1)];
  Future<void> perform(Future<void> Function() callback) async {
    try {
      await callback();
    } on FormatException catch (error) {
      if (mounted) note(error.message);
    } catch (_) {
      if (mounted) {
        note('Не удалось выполнить действие. Проверьте соединение со службой.');
      }
    }
  }

  void note(String value) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));
  Widget label(
    String text, {
    double size = 12,
    Color? color,
    FontWeight weight = FontWeight.w500,
  }) => Text(
    text,
    style: TextStyle(fontSize: size, color: color, fontWeight: weight),
  );
  BoxDecoration decoration({bool selected = false, double radius = 24}) =>
      BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest
            .withValues(alpha: .86),
        gradient: selected
            ? LinearGradient(
                colors: [
                  const Color(0xffa855f7).withValues(alpha: .20),
                  acid.withValues(alpha: .10),
                ],
              )
            : null,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: selected
              ? acid.withValues(alpha: .35)
              : const Color(0xffa855f7).withValues(alpha: .22),
        ),
      );
  Widget smallButton(
    IconData icon,
    String tooltip,
    VoidCallback? callback, {
    bool highlighted = false,
    bool rotating = false,
  }) => SizedBox(
    width: 32,
    height: 32,
    child: IconButton(
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      onPressed: callback,
      style: IconButton.styleFrom(
        backgroundColor: Colors.white.withValues(alpha: .05),
        side: BorderSide(color: Colors.white.withValues(alpha: .10)),
      ),
      icon: RotatingRefresh(
        active: rotating,
        child: ArenaGlyph(
          _glyphName(icon),
          size: 15,
          color: highlighted ? acid : muted,
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: client,
    builder: (context, _) {
      final standalone = client.profiles
          .where((p) => p.subscriptionId == null)
          .toList();
      final providerExists = client.subscriptions.any((s) => s.id == provider);
      final current = providerExists
          ? client.subscriptions.firstWhere((s) => s.id == provider)
          : standalone.isEmpty && client.subscriptions.isNotEmpty
          ? client.subscriptions.first
          : null;
      final visible = client.profiles
          .where((p) => p.subscriptionId == current?.id)
          .toList();
      if (sort == 'name') visible.sort((a, b) => a.name.compareTo(b.name));
      if (sort == 'ping') {
        visible.sort(
          (a, b) => (a.latencyMs ?? 999999).compareTo(b.latencyMs ?? 999999),
        );
      }
      return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 112),
            children: [
              _orb(),
              NetworkModeControl(client: client),
              if (client.message.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    client.message,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (client.profiles.isEmpty && client.subscriptions.isEmpty)
                _empty()
              else ...[
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    label(
                      'ТЕКУЩИЙ ПРОВАЙДЕР',
                      size: 11,
                      color: muted,
                      weight: FontWeight.w700,
                    ),
                    if (client.subscriptions.length > 1 ||
                        (client.subscriptions.isNotEmpty &&
                            standalone.isNotEmpty))
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final sub in client.subscriptions)
                            _providerPill(
                              sub.title,
                              current?.id == sub.id,
                              () => setState(() => provider = sub.id),
                            ),
                          if (standalone.isNotEmpty)
                            _providerPill(
                              'Мои серверы',
                              current == null,
                              () => setState(() => provider = null),
                            ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  decoration: decoration(),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () =>
                                  setState(() => collapsed = !collapsed),
                              child: Row(
                                children: [
                                  ArenaGlyph(
                                    collapsed ? 'ChevronRight' : 'ChevronDown',
                                    size: 16,
                                    color: muted,
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      current?.title ?? 'Мои серверы',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  if (current == null) ...[
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: acid.withValues(alpha: .18),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: label(
                                        '${visible.length}',
                                        color: acid,
                                        size: 11,
                                        weight: FontWeight.w800,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          if (current != null) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: .05),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: .10),
                                ),
                                borderRadius: BorderRadius.circular(30),
                              ),
                              child: label(
                                '${current.intervalMinutes ~/ 60}ч',
                                size: 11,
                                color: muted,
                              ),
                            ),
                            const SizedBox(width: 6),
                            smallButton(
                              Icons.refresh,
                              'Обновить подписку',
                              client.updatingSubscriptions.contains(current.id)
                                  ? null
                                  : () => perform(
                                      () =>
                                          client.updateSubscription(current.id),
                                    ),
                              rotating: client.updatingSubscriptions.contains(
                                current.id,
                              ),
                            ),
                          ] else
                            smallButton(
                              Icons.delete_outline,
                              'Очистить мои серверы',
                              client.busy || running
                                  ? null
                                  : () => _clearStandalone(visible),
                            ),
                          const SizedBox(width: 6),
                          if (current == null) ...[
                            smallButton(
                              Icons.swap_vert,
                              'Сортировка',
                              () => setState(
                                () => sort = sort == 'none'
                                    ? 'ping'
                                    : sort == 'ping'
                                    ? 'name'
                                    : 'none',
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          smallButton(
                            Icons.bolt,
                            'Проверить пинг (TCP)',
                            client.pinging
                                ? null
                                : () => perform(
                                    () => client.pingProfiles(
                                      visible.map(client.indexOf).toList(),
                                    ),
                                  ),
                            highlighted: true,
                          ),
                          const SizedBox(width: 6),
                          smallButton(
                            Icons.settings_outlined,
                            'Настройки подписки',
                            current == null
                                ? widget.onSubscriptions
                                : () => _providerSettings(current),
                          ),
                        ],
                      ),
                      if (current != null) ..._metadata(current),
                      if (!collapsed) ...[
                        const SizedBox(height: 14),
                        for (final profile in visible)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _server(profile),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _action(
                      'Добавить',
                      Icons.add,
                      widget.onImport,
                      primary: true,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _action(
                      'Вставить',
                      Icons.content_paste_outlined,
                      () => perform(() async {
                        final data = await Clipboard.getData(
                          Clipboard.kTextPlain,
                        );
                        if (data?.text == null || data!.text!.trim().isEmpty) {
                          if (mounted) note('Буфер обмена пуст');
                          return;
                        }
                        await client.importText(data.text!);
                      }),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 44,
                    child: Tooltip(
                      message: 'Сканировать QR-код',
                      child: _action(
                        '',
                        Icons.qr_code_scanner,
                        widget.onQr ??
                            () => note(
                              'Сканирование QR пока недоступно в этой сборке',
                            ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
  Widget _providerPill(String title, bool active, VoidCallback callback) =>
      InkWell(
        onTap: callback,
        borderRadius: BorderRadius.circular(30),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: active
                ? acid.withValues(alpha: .14)
                : Colors.white.withValues(alpha: .04),
            border: Border.all(
              color: active
                  ? acid.withValues(alpha: .35)
                  : Colors.white.withValues(alpha: .10),
            ),
            borderRadius: BorderRadius.circular(30),
          ),
          child: label(
            title,
            size: 11,
            color: active ? acid : muted,
            weight: FontWeight.w600,
          ),
        ),
      );
  Widget _action(
    String title,
    IconData icon,
    VoidCallback callback, {
    bool primary = false,
  }) => Container(
    decoration: decoration(selected: primary, radius: 16),
    child: TextButton(
      onPressed: callback,
      style: TextButton.styleFrom(
        foregroundColor: primary
            ? acid
            : Theme.of(context).colorScheme.onSurface,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ArenaGlyph(_glyphName(icon), size: 16),
          if (title.isNotEmpty) ...[
            const SizedBox(width: 8),
            label(title, weight: FontWeight.w700),
          ],
        ],
      ),
    ),
  );
  Widget _empty() => Column(
    children: [
      const SizedBox(height: 8),
      Container(
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: decoration(radius: 16),
        child: Column(
          children: [
            _summary(
              'Статус:',
              client.state == 'offline' ? 'Служба недоступна' : 'Не подключено',
            ),
            Divider(height: 1, color: Colors.white.withValues(alpha: .06)),
            _summary(
              'Тип подключения:',
              client.settings['mode'] == 'tun'
                  ? 'TUN'
                  : 'SOCKS5 :${client.settings['proxyPort'] ?? 2080}',
            ),
          ],
        ),
      ),
      const SizedBox(height: 24),
      Icon(
        Icons.folder_open_outlined,
        size: 64,
        color: muted.withValues(alpha: .35),
      ),
      const SizedBox(height: 8),
      label('Нет серверов', size: 16, weight: FontWeight.w700),
      const SizedBox(height: 4),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
        child: Text(
          'Вставьте ссылку на провайдера или конфигурацию сервера',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, height: 1.6, color: muted),
        ),
      ),
    ],
  );
  Widget _summary(String title, String value) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    child: Row(
      children: [
        label(title, color: muted),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
  List<Widget> _metadata(Subscription subscription) {
    final total = subscription.total;
    final used = (subscription.upload ?? 0) + (subscription.download ?? 0);
    final hasLinks =
        subscription.supportUrl != null || subscription.webpageUrl != null;
    return [
      if (subscription.expires != null || total != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            children: [
              if (subscription.expires != null) ...[
                label(
                  subscription.expires!.isBefore(DateTime.now())
                      ? 'Срок истёк'
                      : 'Осталось ${subscription.expires!.difference(DateTime.now()).inDays + 1} дн.',
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    height: 6,
                    child: ColoredBox(
                      color: Colors.white.withValues(alpha: .08),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          heightFactor: 1,
                          widthFactor: total != null && total > 0
                              ? (used / total).clamp(.04, 1)
                              : .04,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [const Color(0xffa855f7), acid],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (total != null) ...[
                const SizedBox(width: 12),
                Text(
                  '${_bytes(used)} / ${_bytes(total)}',
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'ArenaMono',
                    color: muted,
                  ),
                ),
              ],
            ],
          ),
        ),
      if (subscription.announceText?.isNotEmpty == true)
        Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xffa855f7).withValues(alpha: .10),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: const Color(0xffa855f7).withValues(alpha: .20),
            ),
          ),
          child: Text(
            subscription.announceText!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurface
                  .withValues(alpha: .9),
            ),
          ),
        ),
      if (subscription.error.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            subscription.error,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontSize: 12,
            ),
          ),
        ),
      if (hasLinks || subscription.lastUpdated != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            children: [
              if (hasLinks)
                Flexible(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      if (subscription.supportUrl != null)
                        _supportLink(
                          'Поддержка',
                          'HelpCircle',
                          true,
                          subscription.supportUrl!,
                        ),
                      if (subscription.webpageUrl != null)
                        _supportLink(
                          'Сайт',
                          'Globe',
                          false,
                          subscription.webpageUrl!,
                        ),
                    ],
                  ),
                ),
              const Spacer(),
              if (subscription.lastUpdated != null)
                Text(
                  '${_date(subscription.lastUpdated!)} · ${client.profiles.where((p) => p.subscriptionId == subscription.id).length} ▤',
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'ArenaMono',
                    color: muted.withValues(alpha: .65),
                  ),
                ),
            ],
          ),
        ),
    ];
  }

  Widget _supportLink(String title, String glyph, bool highlight, String url) =>
      InkWell(
        onTap: () => _openUrl(url),
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: highlight
                ? acid.withValues(alpha: .10)
                : const Color(0xffa855f7).withValues(alpha: .15),
            border: Border.all(
              color: highlight
                  ? acid.withValues(alpha: .30)
                  : const Color(0xffa855f7).withValues(alpha: .30),
            ),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ArenaGlyph(glyph, size: 14, color: highlight ? acid : muted),
              const SizedBox(width: 6),
              label(
                title,
                color: highlight
                    ? acid
                    : Theme.of(context).colorScheme.onSurface,
                weight: FontWeight.w600,
              ),
            ],
          ),
        ),
      );

  Widget _server(Profile profile) {
    final isSelected = selected?.id == profile.id;
    final uri = Uri.tryParse(profile.uri);
    final transport = uri?.queryParameters['type'] ?? 'TCP';
    final secure = uri?.queryParameters['security'] ?? '';
    final flow = (uri?.queryParameters['flow'] ?? '').contains('vision')
        ? 'VISION'
        : '';
    final pings = client.profiles
        .where(
          (p) =>
              p.subscriptionId == profile.subscriptionId && p.latencyMs != null,
        )
        .map((p) => p.latencyMs!)
        .toList();
    final fastest =
        profile.latencyMs != null &&
        pings.isNotEmpty &&
        profile.latencyMs == pings.reduce(math.min);
    return Container(
      decoration: decoration(selected: isSelected, radius: 16),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: client.busy || running
              ? null
              : () => perform(() => client.select(client.indexOf(profile))),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: decoration(selected: isSelected, radius: 12),
                  child: Center(child: _flag(profile.name)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (fastest) ...[
                            const ArenaGlyph(
                              'Zap',
                              size: 14,
                              color: Color(0xfffacc15),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Expanded(
                            child: Text(
                              profile.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: acid.withValues(alpha: .18),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: label(
                              profile.protocol,
                              size: 10,
                              color: acid,
                              weight: FontWeight.w800,
                            ),
                          ),
                          label(
                            '· ${[transport, secure, flow].where((x) => x.isNotEmpty).join(' · ').toUpperCase()}',
                            size: 11,
                            color: muted,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (profile.latencyMs != null) ...[
                  const SizedBox(width: 8),
                  label('${profile.latencyMs} мс', size: 12, color: acid),
                ],
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    tooltip: 'Параметры сервера',
                    padding: EdgeInsets.zero,
                    icon: ArenaGlyph('MoreHorizontal', size: 18, color: muted),
                    onPressed: () => widget.onInspect(client.indexOf(profile)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openUrl(String url) {
    if (widget.onOpenUrl != null) {
      widget.onOpenUrl!(url);
    } else {
      perform(() async {
        await Clipboard.setData(ClipboardData(text: url));
        if (mounted) note('Ссылка скопирована');
      });
    }
  }

  Widget _flag(String name) {
    final normalized = name.toLowerCase();
    final country =
        normalized.contains('финлян') ||
            normalized.contains('finland') ||
            normalized.contains('🇫🇮')
        ? 'fi'
        : normalized.contains('герман') ||
              normalized.contains('germany') ||
              normalized.contains('🇩🇪')
        ? 'de'
        : normalized.contains('нидерланд') ||
              normalized.contains('netherlands') ||
              normalized.contains('🇳🇱')
        ? 'nl'
        : normalized.contains('швец') ||
              normalized.contains('sweden') ||
              normalized.contains('🇸🇪')
        ? 'se'
        : '';
    if (country.isEmpty) return ArenaGlyph('Globe', size: 20, color: muted);
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: CustomPaint(
        size: const Size(22, 16),
        painter: _FlagPainter(country),
      ),
    );
  }

  Future<void> _clearStandalone(List<Profile> profiles) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Очистить мои серверы?'),
        content: const Text(
          'Будут удалены отдельно добавленные профили. Подписки сохранятся.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await perform(() async {
      for (final profile in profiles) {
        final index = client.indexOf(profile);
        if (index >= 0) await client.remove(index);
      }
    });
  }

  Future<void> _providerSettings(Subscription subscription) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              subscription.title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Пинг'),
              trailing: const Text('TCP'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Интервал обновления'),
              trailing: DropdownButton<int>(
                value: subscription.intervalMinutes,
                items: {subscription.intervalMinutes, 60, 120, 360, 720, 1440}
                    .toList()
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text('${value ~/ 60}ч'),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) {
                    Navigator.pop(context);
                    perform(
                      () => client.configureSubscription(
                        subscription.id,
                        intervalMinutes: value,
                      ),
                    );
                  }
                },
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.copy, size: 18),
              title: const Text('Скопировать ссылку'),
              onTap: () {
                Navigator.pop(context);
                perform(
                  () =>
                      Clipboard.setData(ClipboardData(text: subscription.url)),
                );
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.settings_outlined, size: 18),
              title: const Text('Управление подпиской'),
              onTap: () {
                Navigator.pop(context);
                widget.onSubscriptions();
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _orb() => Column(
    children: [
      const SizedBox(height: 4),
      if (running) ...[
        Wrap(
          spacing: 24,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            label('↑ ${_bytes(client.uploadRate)}/с', color: acid),
            label(_duration(client.uptimeSeconds)),
            label('↓ ${_bytes(client.downloadRate)}/с', color: acid),
          ],
        ),
        const SizedBox(height: 12),
      ],
      SizedBox(
        width: 192,
        height: 192,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: const Size.square(192),
              painter: _OrbRings(
                running ? acid : Theme.of(context).colorScheme.secondary,
                running,
              ),
            ),
            Container(
              width: 144,
              height: 144,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  center: const Alignment(-.3, -.45),
                  colors: [
                    running
                        ? acid.withValues(alpha: .22)
                        : const Color(0xffa855f7).withValues(alpha: .20),
                    Theme.of(context).colorScheme.surfaceContainerLowest,
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .52),
                    offset: const Offset(0, 14),
                    blurRadius: 34,
                  ),
                ],
                border: Border.all(
                  color: running
                      ? acid
                      : const Color(0xffa855f7).withValues(alpha: .32),
                  width: 1.5,
                ),
              ),
              child: Material(
                color: Colors.transparent,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  key: const ValueKey('arena-power'),
                  customBorder: const CircleBorder(),
                  onTap: client.busy
                      ? null
                      : selected == null
                      ? widget.onImport
                      : () => perform(client.toggle),
                  child: Center(
                    child: client.busy
                        ? SizedBox(
                            width: 42,
                            height: 42,
                            child: CircularProgressIndicator(
                              color: acid,
                              strokeWidth: 3,
                            ),
                          )
                        : ArenaGlyph(
                            running && client.mode == 'tun' && client.verified
                                ? 'Shield'
                                : 'Power',
                            size: running ? 64 : 60,
                            color: running ? acid : const Color(0xffcfc3ea),
                          ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      Text(
        client.busy
            ? 'Подключение...'
            : running
            ? selected?.name ?? 'Ядро запущено'
            : 'Нажмите для подключения',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: .4,
          color: running ? acid : Theme.of(context).colorScheme.onSurface,
        ),
      ),
      if (running) ...[
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: client.busy
                  ? null
                  : () => perform(client.checkConnection),
              icon: const Icon(Icons.monitor_heart_outlined, size: 16),
              label: const Text('Проверить'),
              style: OutlinedButton.styleFrom(
                foregroundColor: acid,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                textStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 12),
            if (client.latencyMs != null)
              label('${client.latencyMs} мс', color: acid),
            const Spacer(),
            Flexible(
              child: label(
                client.verified ? 'Соединение проверено' : 'Ядро запущено',
                size: 11,
                color: muted,
              ),
            ),
          ],
        ),
      ],
      const SizedBox(height: 8),
    ],
  );
}

String _bytes(int? value) {
  if (value == null) return '—';
  if (value < 1024) return '$value Б';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(0)} КБ';
  if (value < 1024 * 1024 * 1024) {
    return '${(value / 1024 / 1024).toStringAsFixed(1)} МБ';
  }
  return '${(value / 1024 / 1024 / 1024).toStringAsFixed(1)} ГБ';
}

String _duration(int value) =>
    '${(value ~/ 3600).toString().padLeft(2, '0')}:${(value ~/ 60 % 60).toString().padLeft(2, '0')}:${(value % 60).toString().padLeft(2, '0')}';
String _date(DateTime value) =>
    '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

class _OrbRings extends CustomPainter {
  const _OrbRings(this.accent, this.running);
  final Color accent;
  final bool running;
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..color = accent.withValues(alpha: running ? .9 : .30);
    canvas.drawCircle(center, size.width * .46, paint);
    paint
      ..strokeWidth = 1.4
      ..color = accent.withValues(alpha: running ? .45 : .18);
    final rect = Rect.fromCircle(center: center, radius: size.width * .415);
    for (var angle = 0.0; angle < 2 * math.pi; angle += .64) {
      canvas.drawArc(rect, angle, .36, false, paint);
    }
  }

  @override
  bool shouldRepaint(_OrbRings oldDelegate) =>
      oldDelegate.accent != accent || oldDelegate.running != running;
}

String _glyphName(IconData icon) => switch (icon) {
  Icons.refresh => 'RefreshCw',
  Icons.bolt => 'Zap',
  Icons.settings_outlined => 'Settings',
  Icons.delete_outline => 'Trash2',
  Icons.swap_vert => 'ArrowDownUp',
  Icons.add => 'Plus',
  Icons.content_paste_outlined => 'ClipboardPaste',
  Icons.qr_code_scanner => 'ScanLine',
  _ => 'Globe',
};

class _FlagPainter extends CustomPainter {
  const _FlagPainter(this.country);
  final String country;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    if (country == 'fi' || country == 'se') {
      paint.color = country == 'fi' ? Colors.white : const Color(0xff006aa7);
      canvas.drawRect(Offset.zero & size, paint);
      paint.color = country == 'fi'
          ? const Color(0xff003580)
          : const Color(0xfffecc00);
      canvas.drawRect(
        Rect.fromLTWH(size.width * .30, 0, size.width * .18, size.height),
        paint,
      );
      canvas.drawRect(
        Rect.fromLTWH(0, size.height * .40, size.width, size.height * .20),
        paint,
      );
    } else {
      final colors = country == 'de'
          ? [
              const Color(0xff101010),
              const Color(0xffdd0000),
              const Color(0xffffce00),
            ]
          : [const Color(0xffae1c28), Colors.white, const Color(0xff21468b)];
      for (var i = 0; i < 3; i++) {
        paint.color = colors[i];
        canvas.drawRect(
          Rect.fromLTWH(0, i * size.height / 3, size.width, size.height / 3),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_FlagPainter oldDelegate) =>
      oldDelegate.country != country;
}
