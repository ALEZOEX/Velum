import 'package:flutter/material.dart';

import 'client.dart';
import 'arena_icons.dart';

class ArenaSettings extends StatefulWidget {
  const ArenaSettings({
    super.key,
    required this.client,
    required this.onRouting,
    required this.onLogs,
    required this.onSubscriptions,
    required this.advancedSettings,
    this.appearance = const {},
    this.onAppearanceChanged,
  });
  final VelumClient client;
  final VoidCallback onRouting, onLogs, onSubscriptions;
  final Widget advancedSettings;
  final Map<String, dynamic> appearance;
  final ValueChanged<Map<String, dynamic>>? onAppearanceChanged;
  @override
  State<ArenaSettings> createState() => _ArenaSettingsState();
}

class _ArenaSettingsState extends State<ArenaSettings> {
  String screen = 'main';
  late Map<String, dynamic> appearance = {...widget.appearance};
  VelumClient get client => widget.client;
  bool get locked => client.busy || client.state == 'running';
  Color get acid => Theme.of(context).colorScheme.primary;
  Color get secondary => Theme.of(context).colorScheme.onSurfaceVariant;
  static const palettes = [
    (
      'velum-acid-violet',
      'Velum Кислотный Фиолет',
      'Глубокий фиолетовый космос с кислотно-лаймовым неоном',
      [Color(0xff150a2a), Color(0xffa855f7), Color(0xffb8ff14)],
    ),
    (
      'hyper-amethyst',
      'Гипер-Аметист',
      'Насыщенный ультрафиолет с ярким шартрезом',
      [Color(0xff190b36), Color(0xff9333ea), Color(0xffccff00)],
    ),
    (
      'cyber-orchid',
      'Кибер-Орхидея',
      'Пурпурно-фиолетовый градиент и кислотная мята',
      [Color(0xff1a0b2b), Color(0xffd946ef), Color(0xff80ff72)],
    ),
    (
      'acid-matrix',
      'Кислотный Импульс',
      'Тёмный обсидиан с кислотным лаймом и фиолетовым отблеском',
      [Color(0xff080910), Color(0xff8b5cf6), Color(0xffa3ff12)],
    ),
    (
      'incy-emerald',
      'INCY Классическая',
      'Оригинальная тёмно-зелёная палитра INCY',
      [Color(0xff0b140d), Color(0xff2d5a36), Color(0xff9ef01a)],
    ),
  ];
  static const patterns = [
    ('topography', 'Топографические волны'),
    ('hex-grid', 'Кибер-соты (Hex)'),
    ('cyber-circuit', 'Диагональный контур'),
    ('dot-constellation', 'Матрица точек'),
    ('aurora-clean', 'Чистая Аврора'),
  ];

  Future<void> save(Map<String, dynamic> patch) async {
    try {
      await client.saveSettings(patch);
      if (mounted) setState(() {});
    } on FormatException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось сохранить настройки.')),
        );
      }
    }
  }

  void appearanceChange(Map<String, dynamic> patch) {
    setState(() => appearance.addAll(patch));
    widget.onAppearanceChanged?.call(patch);
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 112),
        child: screen == 'main' ? mainScreen() : subScreen(),
      ),
    ),
  );

  Widget mainScreen() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Настройки',
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w800,
          letterSpacing: -.5,
        ),
      ),
      const SizedBox(height: 20),
      group('Оформление', [
        row(
          Icons.palette_outlined,
          'Тема оформления',
          palettes
              .firstWhere(
                (p) => p.$1 == (appearance['themeId'] ?? 'velum-acid-violet'),
                orElse: () => palettes.first,
              )
              .$2,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              swatches(
                palettes
                    .firstWhere(
                      (p) =>
                          p.$1 ==
                          (appearance['themeId'] ?? 'velum-acid-violet'),
                      orElse: () => palettes.first,
                    )
                    .$4,
                14,
              ),
              const SizedBox(width: 8),
              chevron(),
            ],
          ),
          onTap: () => setState(() => screen = 'theme'),
          accent: true,
        ),
        row(
          Icons.language,
          'Язык',
          null,
          trailing: select('ru', const {'ru': 'Русский'}, null),
        ),
      ]),
      group('Соединение', [
        row(
          Icons.hub_outlined,
          'Режим работы',
          client.settings['mode'] == 'tun'
              ? 'Только виртуальный адаптер TUN'
              : 'Только локальные порты SOCKS5 / HTTP',
          trailing: select(
            client.settings['mode'] as String? ?? 'proxy',
            const {'proxy': 'SOCKS5', 'tun': 'TUN'},
            locked ? null : (value) => save({'mode': value}),
          ),
          accent: true,
        ),
        row(
          Icons.bolt_outlined,
          'Автоподключение',
          'Подключаться при запуске приложения',
          trailing: toggle(
            client.settings['autoConnect'] == true,
            (v) => save({'autoConnect': v}),
          ),
          accent: true,
        ),
        row(
          Icons.shield_outlined,
          'Kill Switch',
          'Блокировка при обрыве пока не реализована',
          trailing: toggle(false, null),
          iconColor: const Color(0xfffb7185),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            row(
              Icons.wifi,
              'Прокси в локальной сети',
              'SOCKS5 :${client.settings['proxyPort'] ?? 2080} · HTTP :${client.settings['proxyPort'] ?? 2080}',
              trailing: toggle(false, null),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 48, bottom: 14),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final protocol in ['SOCKS5', 'HTTP'])
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .3),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: .1),
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '$protocol:  ${client.settings['proxyPort'] ?? 2080}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0x26a855f7),
                      border: Border.all(color: const Color(0x4dc084fc)),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ArenaGlyph('Send', size: 12, color: acid),
                        const SizedBox(width: 5),
                        const Text(
                          'Telegram',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        row(
          Icons.desktop_windows_outlined,
          'Запускать с системой',
          'Системный трей и автозапуск пока не реализованы',
          trailing: toggle(false, null),
        ),
      ]),
      group('Туннель', [
        Column(
          children: [
            row(
              Icons.account_tree_outlined,
              'Профили маршрутизации',
              client.settings['routeMode'] == 'rules'
                  ? 'Пользовательские правила'
                  : 'Выключено (весь трафик через VPN)',
              trailing: toggle(
                client.settings['routeMode'] == 'rules',
                locked
                    ? null
                    : (v) => save({'routeMode': v ? 'rules' : 'global'}),
              ),
              accent: true,
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Material(
                color: Colors.black.withValues(alpha: .25),
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  onTap: widget.onRouting,
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        const Text(
                          'Маршрутизация',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          'Настроить',
                          style: TextStyle(
                            color: acid,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        chevron(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        row(
          Icons.apps_outlined,
          'Прокси по приложениям',
          'Все приложения используют общий маршрут',
          trailing: configure(),
          onTap: () => setState(() => screen = 'per-app'),
          accent: true,
        ),
        row(
          Icons.grid_view_outlined,
          'Фрагментирование',
          'Фрагментация TLS ClientHello',
          trailing: toggle(
            client.settings['fragment'] == true,
            locked ? null : (v) => save({'fragment': v}),
          ),
          accent: true,
        ),
        row(
          Icons.sensors_outlined,
          'Шумовые пакеты (Noises)',
          'Пока не поддерживается текущим ядром клиента',
          trailing: toggle(false, null),
        ),
        row(
          Icons.layers_outlined,
          'Мультиплексирование (Mux)',
          'Настройка пока не реализована',
          trailing: toggle(false, null),
        ),
        row(
          Icons.language,
          'Тип IP',
          null,
          trailing: select(
            client.settings['ipv6'] == true ? 'dual' : 'ipv4',
            const {'dual': 'IPv4 + IPv6', 'ipv4': 'IPv4'},
            locked ? null : (v) => save({'ipv6': v == 'dual'}),
          ),
        ),
        row(
          null,
          'Дополнительные адреса в обход прокси',
          'Домены и подсети, идущие всегда напрямую',
          trailing: chevron(),
          onTap: widget.onRouting,
        ),
      ]),
      group('Подписки', [
        row(
          Icons.sync_outlined,
          'Автообновление подписок',
          'Настраивается отдельно для каждого провайдера',
          trailing: chevron(),
          onTap: widget.onSubscriptions,
        ),
        row(
          null,
          'Настройки пинга',
          'TCP рукопожатие до узла',
          trailing: select('tcp', const {'tcp': 'TCP'}, null),
        ),
        row(
          null,
          'Пинг при обновлении',
          'Автоматическая проверка пока не реализована',
          trailing: toggle(false, null),
        ),
        row(
          Icons.key_outlined,
          'Зашифровать ссылку (crypt1)',
          'Генератор защищённых ссылок velum:// и incy://',
          trailing: chevron(),
          onTap: () => setState(() => screen = 'crypt1'),
          accent: true,
        ),
      ]),
      group('О приложении', [
        row(
          Icons.fingerprint,
          'HWID устройства',
          'Идентификатор устройства не передаётся',
          trailing: toggle(false, null),
          accent: true,
        ),
        row(
          Icons.memory_outlined,
          'Журнал и конфигурация ядра',
          'Просмотр событий подключения и диагностика',
          trailing: chevron(),
          onTap: widget.onLogs,
          accent: true,
        ),
        row(
          Icons.tune_outlined,
          'Дополнительные настройки',
          'DNS, MTU, интерфейс, данные и резервные копии',
          trailing: chevron(),
          onTap: () => setState(() => screen = 'advanced'),
        ),
        row(
          Icons.restart_alt,
          'Сбросить настройки по умолчанию',
          null,
          iconColor: const Color(0xfffb7185),
          onTap: locked ? null : reset,
        ),
      ]),
      Text(
        'Velum Desktop · Linux · sing-box',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11, color: secondary.withValues(alpha: .7)),
      ),
    ],
  );

  Future<void> reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Сбросить настройки?'),
        content: const Text('Профили и подписки сохранятся.'),
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
      await save(Map<String, dynamic>.from(defaultSettings));
    }
  }

  Widget subScreen() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          squareBack(),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              switch (screen) {
                'theme' => 'Тема оформления',
                'per-app' => 'Прокси по приложениям',
                'crypt1' => 'Зашифровать ссылку',
                _ => 'Дополнительные настройки',
              },
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
          ),
          TextButton(
            onPressed: () => setState(() => screen = 'main'),
            child: Text(
              'Готово',
              style: TextStyle(
                color: acid,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      if (screen == 'theme')
        ...themeScreen()
      else if (screen == 'advanced')
        widget.advancedSettings
      else if (screen == 'per-app') ...[
        card(
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                row(
                  Icons.apps_outlined,
                  'Прокси по приложениям',
                  'Правила процессов доступны в маршрутизации',
                  trailing: toggle(false, null),
                ),
                const SizedBox(height: 8),
                Text(
                  'Выберите процесс в редакторе правил. Определение процессов и применимость правил зависят от платформы и режима подключения.',
                  style: TextStyle(fontSize: 12, color: secondary),
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: widget.onRouting,
                  child: const Text('Открыть правила маршрутизации'),
                ),
              ],
            ),
          ),
        ),
      ] else ...[
        card(
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Генератор защищённых ссылок',
                  style: TextStyle(
                    color: acid,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'crypt1 ещё не подключён к Flutter-клиенту. Импорт обычной подписки доступен в разделе провайдеров.',
                  style: TextStyle(fontSize: 12, height: 1.5),
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: widget.onSubscriptions,
                  child: const Text('Открыть подписки'),
                ),
              ],
            ),
          ),
        ),
      ],
    ],
  );

  List<Widget> themeScreen() => [
    card(
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Text(
                  'VELUM',
                  style: TextStyle(
                    color: acid,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                  ),
                ),
                const Spacer(),
                Text(
                  'Предпросмотр',
                  style: TextStyle(color: acid, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .3),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: .08)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: acid.withValues(alpha: .16),
                    ),
                    child: ArenaGlyph('Shield', size: 20, color: acid),
                  ),
                  const SizedBox(width: 12),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Подключено',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Финляндия · Хельсинки #1',
                        style: TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    const SizedBox(height: 14),
    for (final palette in palettes)
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: card(
          InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: widget.onAppearanceChanged == null
                ? null
                : () => appearanceChange({'themeId': palette.$1}),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: palette.$4[1].withValues(alpha: .16),
                    ),
                    child: ArenaGlyph(
                      'Palette',
                      size: 16,
                      color: palette.$4[2],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          palette.$2,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          palette.$3,
                          style: TextStyle(fontSize: 12, color: secondary),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  swatches(palette.$4, 16),
                  const SizedBox(width: 10),
                  if ((appearance['themeId'] ?? 'velum-acid-violet') ==
                      palette.$1)
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: palette.$4[2],
                      ),
                      child: const ArenaGlyph(
                        'Check',
                        color: Color(0xff0b0616),
                        size: 14,
                      ),
                    ),
                ],
              ),
            ),
          ),
          borderColor:
              (appearance['themeId'] ?? 'velum-acid-violet') == palette.$1
              ? palette.$4[2]
              : null,
        ),
      ),
    const SizedBox(height: 6),
    card(
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ArenaGlyph('Sparkles', size: 16, color: acid),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Фоновый узор и градиенты',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  '${appearance['patternIntensity'] ?? 60}%',
                  style: TextStyle(fontSize: 12, color: secondary),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final pattern in patterns)
                  ChoiceChip(
                    label: Text(
                      pattern.$2,
                      style: const TextStyle(fontSize: 12),
                    ),
                    selected:
                        (appearance['patternId'] ?? 'topography') == pattern.$1,
                    onSelected: widget.onAppearanceChanged == null
                        ? null
                        : (_) => appearanceChange({'patternId': pattern.$1}),
                    showCheckmark: false,
                  ),
              ],
            ),
            Slider(
              value: ((appearance['patternIntensity'] as num?) ?? 60)
                  .toDouble()
                  .clamp(0, 100),
              min: 0,
              max: 100,
              onChanged: widget.onAppearanceChanged == null
                  ? null
                  : (v) => appearanceChange({'patternIntensity': v.round()}),
            ),
          ],
        ),
      ),
    ),
    const SizedBox(height: 16),
    row(
      Icons.brightness_6_outlined,
      'Режим темы',
      null,
      trailing: select(client.settings['theme'] as String? ?? 'system', const {
        'system': 'Системная',
        'dark': 'Тёмная',
        'light': 'Светлая',
      }, (v) => save({'theme': v})),
    ),
  ];

  Widget group(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 1,
              fontWeight: FontWeight.w700,
              color: secondary.withValues(alpha: .85),
            ),
          ),
        ),
        card(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      color: Colors.white.withValues(alpha: .06),
                    ),
                  children[i],
                ],
              ],
            ),
          ),
        ),
      ],
    ),
  );
  Widget card(Widget child, {Color? borderColor}) => Container(
    decoration: BoxDecoration(
      color: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xc71a0e31)
          : Theme.of(context).colorScheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: borderColor ?? const Color(0x38a855f7)),
    ),
    child: child,
  );
  Widget row(
    IconData? icon,
    String title,
    String? description, {
    Widget? trailing,
    VoidCallback? onTap,
    bool accent = false,
    Color? iconColor,
  }) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          if (icon != null) ...[
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: accent
                    ? acid.withValues(alpha: .14)
                    : const Color(0x33a855f7),
                borderRadius: BorderRadius.circular(12),
              ),
              child: glyph(
                icon,
                size: 16,
                color: iconColor ?? (accent ? acid : secondary),
              ),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: iconColor,
                  ),
                ),
                if (description != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 11,
                      color: secondary,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing],
        ],
      ),
    ),
  );
  Widget glyph(IconData icon, {double size = 16, Color? color}) {
    final names = <IconData, String>{
      Icons.palette_outlined: 'Palette',
      Icons.language: 'Globe',
      Icons.hub_outlined: 'Network',
      Icons.bolt_outlined: 'Zap',
      Icons.shield_outlined: 'ShieldAlert',
      Icons.wifi: 'Wifi',
      Icons.desktop_windows_outlined: 'Monitor',
      Icons.account_tree_outlined: 'GitBranch',
      Icons.apps_outlined: 'AppWindow',
      Icons.grid_view_outlined: 'Grid',
      Icons.sensors_outlined: 'Radio',
      Icons.layers_outlined: 'Layers',
      Icons.sync_outlined: 'RefreshCw',
      Icons.key_outlined: 'KeyRound',
      Icons.fingerprint: 'Fingerprint',
      Icons.memory_outlined: 'Cpu',
      Icons.tune_outlined: 'Settings',
      Icons.restart_alt: 'RotateCcw',
      Icons.brightness_6_outlined: 'Palette',
    };
    return ArenaGlyph(names[icon] ?? 'Settings', size: size, color: color);
  }

  Widget toggle(bool value, ValueChanged<bool>? onChanged) => Semantics(
    toggled: value,
    enabled: onChanged != null,
    onTap: onChanged == null ? null : () => onChanged(!value),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onChanged == null ? null : () => onChanged(!value),
        borderRadius: BorderRadius.circular(12),
        excludeFromSemantics: true,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 44,
          height: 24,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: value ? acid : Colors.white.withValues(alpha: .16),
            borderRadius: BorderRadius.circular(12),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 20,
              height: 20,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xff0b0616),
                boxShadow: [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 2,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  Widget select(
    String value,
    Map<String, String> options,
    ValueChanged<String>? onChanged,
  ) => Container(
    height: 32,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    decoration: BoxDecoration(
      color: const Color(0x55140a26),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.white.withValues(alpha: .1)),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: value,
        isDense: true,
        style: TextStyle(
          fontFamily: 'ArenaSans',
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        items: [
          for (final entry in options.entries)
            DropdownMenuItem(value: entry.key, child: Text(entry.value)),
        ],
        onChanged: onChanged == null
            ? null
            : (v) {
                if (v != null) onChanged(v);
              },
        icon: const ArenaGlyph('ChevronDown', size: 14),
      ),
    ),
  );
  Widget chevron() => ArenaGlyph('ChevronRight', size: 16, color: secondary);
  Widget configure() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('Настроить', style: TextStyle(fontSize: 12, color: secondary)),
      chevron(),
    ],
  );
  Widget swatches(List<Color> colors, double size) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final color in colors)
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              border: Border.all(color: Colors.white.withValues(alpha: .15)),
            ),
          ),
        ),
    ],
  );
  Widget squareBack() => SizedBox(
    width: 36,
    height: 36,
    child: OutlinedButton(
      onPressed: () => setState(() => screen = 'main'),
      style: OutlinedButton.styleFrom(
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: const BorderSide(color: Color(0x33c084fc)),
      ),
      child: const ArenaGlyph('ArrowLeft', size: 16),
    ),
  );
}
