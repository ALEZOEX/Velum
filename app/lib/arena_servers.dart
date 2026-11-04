import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'client.dart';
import 'arena_icons.dart';
import 'rotating_refresh.dart';

class ArenaServers extends StatefulWidget {
  const ArenaServers({
    super.key,
    required this.client,
    required this.onImport,
    required this.onInspect,
    required this.onSubscriptions,
    this.onQr,
  });
  final VelumClient client;
  final VoidCallback onImport, onSubscriptions;
  final ValueChanged<int> onInspect;
  final VoidCallback? onQr;
  @override
  State<ArenaServers> createState() => _ArenaServersState();
}

class _ArenaServersState extends State<ArenaServers> {
  String query = '', filter = 'Все', sort = 'none';
  final collapsed = <String>{};
  VelumClient get client => widget.client;
  Future<void> act(Future<void> Function() fn) async {
    try {
      await fn();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e is FormatException ? e.message : 'Действие не выполнено.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: client,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final list = client.profiles.indexed
          .where(
            (e) =>
                (filter == 'Все' ||
                    (filter == 'Избранное'
                        ? e.$2.favorite
                        : e.$2.protocol == filter)) &&
                '${e.$2.name} ${e.$2.server} ${e.$2.protocol}'
                    .toLowerCase()
                    .contains(query.toLowerCase()),
          )
          .toList();
      if (sort == 'name') list.sort((a, b) => a.$2.name.compareTo(b.$2.name));
      if (sort == 'ping') {
        list.sort(
          (a, b) =>
              (a.$2.latencyMs ?? 999999).compareTo(b.$2.latencyMs ?? 999999),
        );
      }
      final groups = <(String, String, List<(int, Profile)>)>[
        for (final sub in client.subscriptions)
          (
            sub.id,
            sub.title,
            list.where((e) => e.$2.subscriptionId == sub.id).toList(),
          ),
        if (client.profiles.any((p) => p.subscriptionId == null))
          (
            'standalone',
            'Мои серверы',
            list.where((e) => e.$2.subscriptionId == null).toList(),
          ),
      ];
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 112),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Серверы',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          '${client.profiles.length} серверов · ${client.subscriptions.length} подписок',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (client.profiles.isNotEmpty)
                    arenaSmallButton(
                      'ArrowDownUp',
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
                  arenaSmallButton(
                    'RefreshCw',
                    'Обновить все подписки',
                    client.busy
                        ? null
                        : () => act(client.updateAllSubscriptions),
                  ),
                  const SizedBox(width: 6),
                  arenaSmallButton(
                    'Zap',
                    'Проверить пинг всех серверов',
                    client.pinging ? null : () => act(client.pingProfiles),
                    acid: true,
                  ),
                  const SizedBox(width: 6),
                  arenaSmallButton(
                    'Plus',
                    'Добавить провайдера или сервер',
                    widget.onImport,
                    acid: true,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 38,
                child: TextField(
                  onChanged: (v) => setState(() => query = v),
                  style: const TextStyle(fontSize: 12),
                  decoration: const InputDecoration(
                    hintText: 'Поиск серверов...',
                    prefixIconConstraints: BoxConstraints.tightFor(
                      width: 40,
                      height: 38,
                    ),
                    prefixIcon: Padding(
                      padding: EdgeInsets.all(11),
                      child: ArenaGlyph('Search'),
                    ),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
              if (client.profiles.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 4),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final value in [
                          'Все',
                          'Избранное',
                          'VLESS',
                          'HYSTERIA2',
                          'AMNEZIAWG',
                          'WIREGUARD',
                          'TROJAN',
                          'VMESS',
                          'SS',
                          'SOCKS5',
                        ])
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text(
                                value,
                                style: const TextStyle(fontSize: 12),
                              ),
                              selected: filter == value,
                              onSelected: (_) => setState(() => filter = value),
                              showCheckmark: false,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              selectedColor: colors.primary,
                              labelStyle: TextStyle(
                                color: filter == value
                                    ? colors.onPrimary
                                    : colors.onSurface,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 0,
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              if (client.profiles.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 80),
                  child: Column(
                    children: [
                      ArenaGlyph(
                        'FolderOpen',
                        size: 80,
                        color: colors.secondary.withValues(alpha: .22),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Нет серверов',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Вставьте ссылку на подписку или\nконфигурацию сервера',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              for (final group in groups.where(
                (g) => g.$3.isNotEmpty || query.isEmpty && filter == 'Все',
              ))
                _group(group),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _footerButton(
                      'Добавить',
                      'Plus',
                      widget.onImport,
                      primary: true,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _footerButton(
                      'Вставить',
                      'ClipboardPaste',
                      () => act(() async {
                        final text = await Clipboard.getData('text/plain');
                        if (text?.text?.trim().isNotEmpty ?? false) {
                          await client.importText(text!.text!);
                        }
                      }),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 44,
                    child: _footerButton(
                      '',
                      'ScanLine',
                      widget.onQr ??
                          () => ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Сканирование QR пока недоступно в этой сборке',
                              ),
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
  Widget _group((String, String, List<(int, Profile)>) group) {
    final colors = Theme.of(context).colorScheme;
    final matching = client.subscriptions.where((sub) => sub.id == group.$1);
    final sub = matching.isEmpty ? null : matching.first;
    final used = (sub?.upload ?? 0) + (sub?.download ?? 0);
    final total = sub?.total;
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xc71a0e31),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0x38a855f7)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => setState(() {
                    if (!collapsed.add(group.$1)) {
                      collapsed.remove(group.$1);
                    }
                  }),
                  child: Row(
                    children: [
                      ArenaGlyph(
                        collapsed.contains(group.$1)
                            ? 'ChevronRight'
                            : 'ChevronDown',
                        size: 16,
                        color: colors.secondary,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          group.$2,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        height: 20,
                        constraints: const BoxConstraints(minWidth: 20),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: colors.primary.withValues(alpha: .18),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '${group.$3.length}',
                          style: TextStyle(
                            color: colors.primary,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (sub != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .05),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: .10),
                    ),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${sub.intervalMinutes ~/ 60}ч',
                    style: TextStyle(
                      fontSize: 10,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _roundButton(
                  'RefreshCw',
                  'Обновить подписку',
                  client.updatingSubscriptions.contains(sub.id)
                      ? null
                      : () => act(() => client.updateSubscription(sub.id)),
                  rotating: client.updatingSubscriptions.contains(sub.id),
                ),
                const SizedBox(width: 6),
              ],
              _roundButton(
                'Zap',
                'Проверить пинг (TCP)',
                client.pinging
                    ? null
                    : () => act(
                        () => client.pingProfiles(
                          group.$3.map((entry) => entry.$1).toList(),
                        ),
                      ),
                highlighted: true,
              ),
              const SizedBox(width: 6),
              _roundButton(
                'Settings',
                'Настройки подписок',
                widget.onSubscriptions,
              ),
            ],
          ),
          if (total != null && total > 0)
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Row(
                children: [
                  Text(
                    '${_bytes(used)} / ${_bytes(total)}',
                    style: TextStyle(
                      fontSize: 10,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${(used / total * 100).round()}%',
                    style: TextStyle(
                      fontSize: 10,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          if (!collapsed.contains(group.$1)) ...[
            const SizedBox(height: 4),
            for (final entry in group.$3)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _serverRow(entry),
              ),
          ],
        ],
      ),
    );
  }

  Widget _roundButton(
    String icon,
    String tooltip,
    VoidCallback? callback, {
    bool highlighted = false,
    bool rotating = false,
  }) => SizedBox(
    width: 32,
    height: 32,
    child: IconButton(
      tooltip: tooltip,
      onPressed: callback,
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        backgroundColor: Colors.white.withValues(alpha: .05),
        side: BorderSide(color: Colors.white.withValues(alpha: .10)),
      ),
      icon: RotatingRefresh(
        active: rotating,
        child: ArenaGlyph(
          icon,
          size: 14,
          color: highlighted
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.onSurface,
        ),
      ),
    ),
  );
  Widget _serverRow((int, Profile) entry) {
    final colors = Theme.of(context).colorScheme;
    final profile = entry.$2;
    final chosen = entry.$1 == client.selected;
    final protocol = profile.protocol;
    final badgeColor = switch (protocol) {
      'HYSTERIA2' => const Color(0xffe9d5ff),
      'TROJAN' => const Color(0xff7dd3fc),
      'AMNEZIAWG' => const Color(0xff6ee7b7),
      _ => colors.primary,
    };
    final uri = Uri.tryParse(profile.uri);
    final transport = (uri?.queryParameters['type'] ?? 'TCP').toUpperCase();
    final security = (uri?.queryParameters['security'] ?? '').toUpperCase();
    final flow = (uri?.queryParameters['flow'] ?? '').contains('vision')
        ? 'VISION'
        : '';
    return Container(
      height: 64,
      decoration: BoxDecoration(
        gradient: chosen
            ? LinearGradient(
                colors: [
                  const Color(0xffa855f7).withValues(alpha: .20),
                  colors.primary.withValues(alpha: .10),
                ],
              )
            : null,
        color: chosen ? null : const Color(0xcc0d061a),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: chosen
              ? colors.primary.withValues(alpha: .45)
              : const Color(0x12ffffff),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: client.busy || client.state == 'running'
              ? null
              : () => act(() => client.select(entry.$1)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xff180c30),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: chosen
                          ? colors.primary.withValues(alpha: .40)
                          : const Color(0x24a855f7),
                    ),
                  ),
                  child: Center(child: _flag(profile.name)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.25,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: badgeColor.withValues(alpha: .18),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              protocol,
                              style: TextStyle(
                                fontSize: 10,
                                height: 1,
                                fontWeight: FontWeight.w800,
                                color: badgeColor,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '· ${[transport, security, flow].where((part) => part.isNotEmpty).join(' · ')}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (profile.latencyMs != null)
                  Text(
                    '${profile.latencyMs} мс',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: colors.primary,
                    ),
                  ),
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    tooltip: profile.favorite
                        ? 'Убрать из избранного'
                        : 'В избранное',
                    padding: EdgeInsets.zero,
                    onPressed: client.busy
                        ? null
                        : () => act(() => client.toggleFavorite(entry.$1)),
                    icon: profile.favorite
                        ? const Icon(
                            Icons.star,
                            size: 16,
                            color: Color(0xfffacc15),
                          )
                        : ArenaGlyph(
                            'Star',
                            size: 16,
                            color: colors.onSurfaceVariant,
                          ),
                  ),
                ),
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    tooltip: 'Параметры сервера и QR',
                    padding: EdgeInsets.zero,
                    onPressed: () => widget.onInspect(entry.$1),
                    icon: ArenaGlyph(
                      'MoreHorizontal',
                      size: 16,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _footerButton(
    String title,
    String glyph,
    VoidCallback callback, {
    bool primary = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      height: 42,
      decoration: BoxDecoration(
        gradient: primary
            ? LinearGradient(
                colors: [
                  const Color(0xffa855f7).withValues(alpha: .22),
                  colors.primary.withValues(alpha: .14),
                ],
              )
            : null,
        color: primary ? null : const Color(0xcc170c2e),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: primary
              ? colors.primary.withValues(alpha: .40)
              : const Color(0x38a855f7),
        ),
      ),
      child: TextButton(
        onPressed: callback,
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          foregroundColor: primary ? colors.primary : colors.onSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ArenaGlyph(glyph, size: 16),
            if (title.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
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
    if (country.isEmpty) {
      return ArenaGlyph(
        'Globe',
        size: 20,
        color: Theme.of(context).colorScheme.secondary,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: CustomPaint(
        size: const Size(22, 16),
        painter: _FlagPainter(country),
      ),
    );
  }
}

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

String _bytes(int value) => value >= 1024 * 1024 * 1024
    ? '${(value / 1024 / 1024 / 1024).toStringAsFixed(value % (1024 * 1024 * 1024) == 0 ? 0 : 1)} ГБ'
    : value >= 1024 * 1024
    ? '${(value / 1024 / 1024).toStringAsFixed(1)} МБ'
    : '${(value / 1024).toStringAsFixed(0)} КБ';
