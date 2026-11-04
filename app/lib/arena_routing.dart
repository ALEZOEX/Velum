import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'client.dart';
import 'arena_icons.dart';

/// Arena's routing screen backed by Velum's actual saved rules.
class ArenaRouting extends StatefulWidget {
  const ArenaRouting({
    super.key,
    required this.client,
    required this.onBack,
    required this.advancedRules,
  });
  final VelumClient client;
  final VoidCallback onBack;
  final Widget advancedRules;
  @override
  State<ArenaRouting> createState() => _ArenaRoutingState();
}

class _ArenaRoutingState extends State<ArenaRouting> {
  VelumClient get client => widget.client;
  ColorScheme get colors => Theme.of(context).colorScheme;
  bool get enabled => client.settings['routeMode'] == 'rules';
  bool get locked => client.busy || client.state == 'running';
  List<Map<String, dynamic>> get rules => (client.settings['rules'] as List)
      .whereType<Map>()
      .map((v) => Map<String, dynamic>.from(v))
      .toList();
  bool importOpen = false;
  bool advanced = false;
  String? error;
  final importText = TextEditingController();
  @override
  void initState() {
    super.initState();
    client.addListener(refresh);
  }

  @override
  void dispose() {
    client.removeListener(refresh);
    importText.dispose();
    super.dispose();
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  Future<void> save(Map<String, dynamic> patch) async {
    try {
      await client.saveSettings(patch);
      if (mounted) setState(() => error = null);
    } on FormatException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Не удалось сохранить настройки маршрутизации.');
      }
    }
  }

  int count(String action) => rules.where((r) => r['action'] == action).length;
  bool get lanSelected =>
      enabled &&
      rules.length == 3 &&
      rules.every(
        (r) =>
            r['type'] == 'cidr' &&
            r['action'] == 'direct' &&
            [
              '10.0.0.0/8',
              '172.16.0.0/12',
              '192.168.0.0/16',
            ].contains(r['value']),
      );
  String get profileName => !enabled
      ? 'Весь трафик через прокси'
      : lanSelected
      ? 'Bypass LAN'
      : 'Пользовательский';

  Widget panel(
    Widget child, {
    bool accent = false,
    EdgeInsets padding = const EdgeInsets.all(16),
  }) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: accent
          ? null
          : colors.surfaceContainerLowest.withValues(alpha: .9),
      gradient: accent
          ? LinearGradient(
              colors: [
                colors.secondary.withValues(alpha: .24),
                colors.primary.withValues(alpha: .15),
              ],
            )
          : null,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(
        color: accent
            ? colors.primary.withValues(alpha: .4)
            : colors.outlineVariant,
      ),
    ),
    child: child,
  );
  Widget caption(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        color: colors.onSurfaceVariant,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: .8,
      ),
    ),
  );
  String glyph(IconData icon) => switch (icon) {
    Icons.arrow_back => 'ArrowLeft',
    Icons.copy_outlined => 'Copy',
    Icons.edit_outlined => 'Edit3',
    Icons.add => 'Plus',
    Icons.download_outlined => 'Download',
    Icons.restart_alt => 'RotateCcw',
    _ => 'GitBranch',
  };
  Widget tinyButton(IconData icon, String tooltip, VoidCallback? callback) =>
      IconButton(
        tooltip: tooltip,
        onPressed: callback,
        icon: ArenaGlyph(glyph(icon), size: 15),
        style: IconButton.styleFrom(
          minimumSize: const Size(32, 32),
          padding: const EdgeInsets.all(6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          side: BorderSide(color: colors.outlineVariant),
        ),
      );
  Widget category(String title, int value, Color tint) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: .10),
        border: Border.all(color: tint.withValues(alpha: .25)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(title, style: TextStyle(color: tint, fontSize: 11)),
          Text(
            '$value',
            style: TextStyle(
              color: tint,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> copyProfile() async {
    await Clipboard.setData(
      ClipboardData(
        text: const JsonEncoder.withIndent('  ').convert({
          'format': 'velum-routing',
          'routeMode': client.settings['routeMode'],
          'rules': rules,
        }),
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Профиль скопирован в формате Velum JSON'),
        ),
      );
    }
  }

  Future<void> importProfile() async {
    try {
      final value = jsonDecode(importText.text);
      if (value is! Map ||
          value['format'] != 'velum-routing' ||
          value['rules'] is! List ||
          !['global', 'rules'].contains(value['routeMode'])) {
        throw const FormatException(
          'Используйте JSON маршрутизации Velum. Форматы INCY и geo-базы пока не поддерживаются.',
        );
      }
      await client.saveSettings({
        'routeMode': value['routeMode'],
        'rules': value['rules'],
      });
      if (mounted) {
        setState(() {
          importOpen = false;
          error = null;
          importText.clear();
        });
      }
    } on FormatException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Импорт не выполнен. Проверьте формат JSON.');
      }
    }
  }

  Future<void> openEditor() async {
    final inputs = <String, TextEditingController>{
      for (final action in ['direct', 'proxy', 'block'])
        for (final type in ['domain', 'cidr'])
          '$action-$type': TextEditingController(
            text: rules
                .where((r) => r['action'] == action && r['type'] == type)
                .map((r) => r['value'])
                .join('\n'),
          ),
      'dns': TextEditingController(text: client.settings['dns'] as String),
      'directDns': TextEditingController(
        text: client.settings['directDns'] as String,
      ),
    };
    String? editorError;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, redraw) => Dialog(
          insetPadding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 576,
              maxHeight: MediaQuery.sizeOf(context).height * .88,
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Профиль маршрутизации',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Закрыть',
                        onPressed: () => Navigator.pop(context),
                        icon: const ArenaGlyph('X', size: 18),
                      ),
                    ],
                  ),
                  const Divider(),
                  const SizedBox(height: 16),
                  Flexible(
                    child: SingleChildScrollView(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          Widget field(
                            String title,
                            String key, {
                            String? hint,
                            Color? color,
                            int lines = 3,
                          }) => Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                title,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: color ?? colors.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 4),
                              TextField(
                                controller: inputs[key],
                                minLines: lines,
                                maxLines: lines + 2,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'ArenaMono',
                                ),
                                decoration: InputDecoration(
                                  hintText: hint,
                                  contentPadding: const EdgeInsets.all(10),
                                ),
                              ),
                            ],
                          );
                          final fields = <Widget>[
                            field(
                              'Прямой доступ — Домены (по одному на строку)',
                              'direct-domain',
                              hint: 'vk.com',
                              color: const Color(0xff6ee7b7),
                            ),
                            field(
                              'Прямой доступ — IP / Подсети',
                              'direct-cidr',
                              hint: '192.168.0.0/16',
                              color: const Color(0xff6ee7b7),
                            ),
                            field(
                              'Через прокси — Домены',
                              'proxy-domain',
                              hint: 'youtube.com\ndiscord.com',
                              color: const Color(0xffd8b4fe),
                            ),
                            field(
                              'Через прокси — IP / Подсети',
                              'proxy-cidr',
                              hint: '149.154.160.0/20',
                              color: const Color(0xffd8b4fe),
                            ),
                            field(
                              'Блокировка — Домены',
                              'block-domain',
                              color: const Color(0xfffda4af),
                              lines: 2,
                            ),
                            field(
                              'Блокировка — IP / Подсети',
                              'block-cidr',
                              hint: '0.0.0.0/32',
                              color: const Color(0xfffda4af),
                              lines: 2,
                            ),
                            field('Remote DNS (DoH / IP)', 'dns', lines: 1),
                            field('Domestic DNS (IP)', 'directDns', lines: 1),
                          ];
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                'Название профиля (Name)',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              TextFormField(
                                initialValue: 'Пользовательский',
                                enabled: false,
                                style: const TextStyle(fontSize: 12),
                              ),
                              const SizedBox(height: 14),
                              Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          'GlobalProxy',
                                          style: TextStyle(fontSize: 12),
                                        ),
                                        const SizedBox(height: 4),
                                        DropdownButtonFormField<String>(
                                          initialValue: 'true',
                                          isExpanded: true,
                                          items: const [
                                            DropdownMenuItem(
                                              value: 'true',
                                              child: Text(
                                                'true — Остальное через прокси',
                                                style: TextStyle(fontSize: 11),
                                              ),
                                            ),
                                          ],
                                          onChanged: null,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          'DomainStrategy',
                                          style: TextStyle(fontSize: 12),
                                        ),
                                        const SizedBox(height: 4),
                                        DropdownButtonFormField<String>(
                                          initialValue: 'AsIs',
                                          items: const [
                                            DropdownMenuItem(
                                              value: 'AsIs',
                                              child: Text(
                                                'AsIs',
                                                style: TextStyle(fontSize: 12),
                                              ),
                                            ),
                                          ],
                                          onChanged: null,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              Wrap(
                                spacing: 14,
                                runSpacing: 14,
                                children: [
                                  for (final f in fields)
                                    SizedBox(
                                      width: constraints.maxWidth >= 480
                                          ? (constraints.maxWidth - 14) / 2
                                          : constraints.maxWidth,
                                      child: f,
                                    ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'GeoIP/GeoSite и стратегии Xray пока недоступны. Сохраняются обычные домены и CIDR; существующие правила процессов сохранятся.',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                              if (editorError != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(
                                    editorError!,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: colors.error,
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text(
                          'Отмена',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: locked
                            ? null
                            : () async {
                                try {
                                  final edited = <Map<String, dynamic>>[
                                    ...rules.where(
                                      (r) => r['type'] == 'process',
                                    ),
                                  ];
                                  for (final action in [
                                    'direct',
                                    'proxy',
                                    'block',
                                  ]) {
                                    for (final type in ['domain', 'cidr']) {
                                      for (final value
                                          in inputs['$action-$type']!.text
                                              .split(RegExp(r'[\n,]+'))
                                              .map((v) => v.trim())
                                              .where((v) => v.isNotEmpty)) {
                                        if (value.startsWith('geosite:') ||
                                            value.startsWith('geoip:')) {
                                          throw const FormatException(
                                            'GeoIP/GeoSite в текущем ядре Velum не подключены. Укажите домен или CIDR.',
                                          );
                                        }
                                        edited.add({
                                          'action': action,
                                          'type': type,
                                          'value': value,
                                        });
                                      }
                                    }
                                  }
                                  await client.saveSettings({
                                    'rules': edited,
                                    'routeMode': 'rules',
                                    'dns': inputs['dns']!.text.trim(),
                                    'directDns': inputs['directDns']!.text
                                        .trim(),
                                  });
                                  if (context.mounted) Navigator.pop(context);
                                } on FormatException catch (e) {
                                  redraw(() => editorError = e.message);
                                } catch (_) {
                                  redraw(
                                    () => editorError =
                                        'Не удалось сохранить профиль.',
                                  );
                                }
                              },
                        child: const Text(
                          'Сохранить',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    for (final input in inputs.values) {
      input.dispose();
    }
  }

  Future<void> chooseLan() async {
    if (rules.isNotEmpty && !lanSelected) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Заменить текущие правила?'),
          content: const Text(
            'Профиль Bypass LAN заменит текущие правила тремя прямыми маршрутами для локальных сетей.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Заменить'),
            ),
          ],
        ),
      );
      if (replace != true) return;
    }
    await save({
      'routeMode': 'rules',
      'rules': [
        for (final cidr in ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'])
          {'type': 'cidr', 'action': 'direct', 'value': cidr},
      ],
    });
  }

  Widget profileRow(
    String name,
    String summary,
    bool selected,
    VoidCallback? callback, {
    bool edit = false,
  }) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: callback,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? colors.primary.withValues(alpha: .4)
                : colors.outlineVariant.withValues(alpha: .5),
          ),
          gradient: selected
              ? LinearGradient(
                  colors: [
                    colors.secondary.withValues(alpha: .22),
                    colors.primary.withValues(alpha: .09),
                  ],
                )
              : null,
          color: selected ? null : colors.surface.withValues(alpha: .5),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    summary,
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (edit)
              IconButton(
                tooltip: 'Изменить профиль',
                onPressed: locked ? null : openEditor,
                icon: const ArenaGlyph('Edit3', size: 15),
                visualDensity: VisualDensity.compact,
              ),
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? colors.primary : Colors.transparent,
                border: Border.all(
                  color: selected ? colors.primary : colors.outline,
                ),
              ),
              child: selected
                  ? ArenaGlyph('Check', size: 13, color: colors.onPrimary)
                  : null,
            ),
          ],
        ),
      ),
    ),
  );

  Widget actionRow(
    IconData icon,
    String text,
    VoidCallback? callback, {
    bool danger = false,
  }) => InkWell(
    onTap: callback,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          ArenaGlyph(
            glyph(icon),
            size: 16,
            color: danger ? const Color(0xfffb7185) : colors.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: danger ? const Color(0xfffda4af) : null,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 112),
        children: [
          Row(
            children: [
              tinyButton(Icons.arrow_back, 'Назад', widget.onBack),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Профили маршрутизации',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -.4,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Настройки → Туннель → Маршрутизация',
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 44,
                child: Switch(
                  value: enabled,
                  onChanged: locked
                      ? null
                      : (value) =>
                            save({'routeMode': value ? 'rules' : 'global'}),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                error!,
                style: TextStyle(color: colors.error, fontSize: 12),
              ),
            ),
          caption('Активный профиль'),
          panel(
            Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: colors.primary.withValues(alpha: .14),
                        border: Border.all(
                          color: colors.primary.withValues(alpha: .4),
                        ),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: ArenaGlyph(
                        'GitBranch',
                        size: 20,
                        color: colors.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            profileName,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Остальное: Через прокси',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    tinyButton(
                      Icons.copy_outlined,
                      'Скопировать профиль',
                      copyProfile,
                    ),
                    const SizedBox(width: 6),
                    SizedBox(
                      height: 32,
                      child: OutlinedButton.icon(
                        onPressed: locked ? null : openEditor,
                        icon: ArenaGlyph(
                          'Edit3',
                          size: 14,
                          color: colors.primary,
                        ),
                        label: const Text(
                          'Изменить',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          side: BorderSide(color: colors.outlineVariant),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    category(
                      'Напрямую',
                      count('direct'),
                      const Color(0xffa7f3d0),
                    ),
                    const SizedBox(width: 8),
                    category(
                      'Через прокси',
                      count('proxy'),
                      const Color(0xffe9d5ff),
                    ),
                    const SizedBox(width: 8),
                    category(
                      'Блокировка',
                      count('block'),
                      const Color(0xfffecdd3),
                    ),
                  ],
                ),
              ],
            ),
            accent: enabled,
          ),
          caption('Все профили'),
          panel(
            Column(
              children: [
                Tooltip(
                  message: 'Требуются подключённые GeoIP/GeoSite rule sets.',
                  child: profileRow(
                    'Россия напрямую (RU Direct)',
                    'Direct 11 · Proxy 4 · Block 1',
                    false,
                    null,
                  ),
                ),
                const SizedBox(height: 8),
                Tooltip(
                  message: 'Доступен эквивалент по трём приватным CIDR без GeoIP/GeoSite.',
                  child: profileRow(
                    'Bypass LAN (Локальная сеть)',
                    'Direct 3 · Proxy 0 · Block 0',
                    lanSelected,
                    locked ? null : chooseLan,
                  ),
                ),
                const SizedBox(height: 8),
                Tooltip(
                  message: 'Требуются GeoIP/GeoSite и режим остаточного direct-трафика.',
                  child: profileRow(
                    'Выборочный (Только список через VPN)',
                    'Direct 1 · Proxy 8 · Block 1',
                    false,
                    null,
                  ),
                ),
                const SizedBox(height: 8),
                Tooltip(
                  message: 'Требуются GeoSite-базы блокировки рекламы.',
                  child: profileRow(
                    'Global + Anti-Ads (Весь трафик)',
                    'Direct 1 · Proxy 0 · Block 2',
                    false,
                    null,
                  ),
                ),
                const SizedBox(height: 8),
                profileRow(
                  'Пользовательский',
                  'Direct ${count('direct')} · Proxy ${count('proxy')} · Block ${count('block')}',
                  enabled && !lanSelected,
                  locked ? null : () => save({'routeMode': 'rules'}),
                  edit: true,
                ),
              ],
            ),
            padding: const EdgeInsets.all(12),
          ),
          caption('Действия'),
          panel(
            Column(
              children: [
                actionRow(
                  Icons.add,
                  'Создать профиль',
                  locked ? null : openEditor,
                ),
                const Divider(),
                actionRow(
                  Icons.download_outlined,
                  'Импорт профиля',
                  locked
                      ? null
                      : () => setState(() => importOpen = !importOpen),
                ),
                const Divider(),
                actionRow(
                  Icons.restart_alt,
                  'Сбросить по умолчанию',
                  locked ? null : () => reset(),
                  danger: true,
                ),
              ],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16),
          ),
          if (importOpen)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: panel(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Импорт JSON маршрутизации Velum',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: importText,
                      minLines: 4,
                      maxLines: 7,
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'ArenaMono',
                      ),
                      decoration: const InputDecoration(
                        hintText: '{"format":"velum-routing","routeMode":"rules","rules":[]}',
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => setState(() => importOpen = false),
                          child: const Text('Отмена'),
                        ),
                        FilledButton(
                          onPressed: locked ? null : importProfile,
                          child: const Text('Импортировать'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          Text(
            'Изменения применяются при следующем подключении. В этой версии хранится один пользовательский набор правил; geo-базы и автообновляемые профили INCY пока не поддерживаются.',
            style: TextStyle(
              fontSize: 11,
              height: 1.5,
              color: colors.onSurfaceVariant,
            ),
          ),
          if (locked)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Отключите соединение для изменения маршрутизации.',
                style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
              ),
            ),
        ],
      ),
    ),
  );

  Future<void> reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Сбросить маршрутизацию?'),
        content: const Text(
          'Пользовательские правила будут удалены. Прямые исключения сохранятся.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Сбросить'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await save({'routeMode': 'global', 'rules': <Map<String, dynamic>>[]});
    }
  }
}
