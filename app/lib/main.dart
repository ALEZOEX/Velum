import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'client.dart';
import 'arena_style.dart';
import 'arena_connection.dart';
import 'arena_settings.dart';
import 'arena_routing.dart';
import 'arena_servers.dart';
import 'arena_import.dart';
import 'arena_logs.dart';
import 'arena_inspector.dart';
import 'arena_icons.dart';

void main() => runApp(const VelumApp());

class VelumApp extends StatefulWidget {
  const VelumApp({super.key, this.client, this.initialize = true});
  final VelumClient? client;
  final bool initialize;
  @override
  State<VelumApp> createState() => _VelumAppState();
}

class _VelumAppState extends State<VelumApp> {
  late final VelumClient client = widget.client ?? VelumClient();
  @override
  void initState() {
    super.initState();
    client.addListener(update);
    if (widget.initialize) unawaited(client.initialize());
  }

  void update() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    client.removeListener(update);
    if (widget.client == null) client.dispose();
    super.dispose();
  }

  ThemeData theme(Brightness brightness) => arenaTheme(
    brightness,
    themeId: client.settings['themeId'] as String? ?? 'velum-acid-violet',
  );

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Velum',
    debugShowCheckedModeBanner: false,
    theme: theme(Brightness.light),
    darkTheme: theme(Brightness.dark),
    themeMode: ThemeMode.dark,
    home: Home(client: client),
  );
}

const pages = <(String, IconData)>[
  ('Подключение', Icons.power_settings_new_rounded),
  ('Серверы', Icons.dns_outlined),
  ('Подписки', Icons.rss_feed_rounded),
  ('Маршрутизация', Icons.alt_route_rounded),
  ('Журнал', Icons.subject_rounded),
  ('Настройки', Icons.tune_rounded),
];

class Home extends StatefulWidget {
  const Home({super.key, required this.client});
  final VelumClient client;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  VelumClient get client => widget.client;
  final input = TextEditingController();
  final importTitle = TextEditingController();
  final search = TextEditingController();
  final exclusions = TextEditingController();
  int page = 0;
  bool importVisible = false;
  bool importing = false;
  bool favoritesOnly = false;
  bool exclusionsDirty = false;
  String sort = 'name';
  String? subscriptionFilter;
  String? importError;
  String? notice;
  String? noticeError;
  bool get running => client.state == 'running';
  bool get locked => client.busy;
  Profile? get selectedProfile => client.profiles.isEmpty
      ? null
      : client.profiles[client.selected.clamp(0, client.profiles.length - 1)];

  @override
  void initState() {
    super.initState();
    client.addListener(update);
  }

  void update() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    client.removeListener(update);
    input.dispose();
    importTitle.dispose();
    search.dispose();
    exclusions.dispose();
    super.dispose();
  }

  Future<void> action(Future<void> Function() task, {String? success}) async {
    setState(() {
      noticeError = null;
      notice = null;
    });
    try {
      await task();
      if (mounted && success != null) setState(() => notice = success);
    } on FormatException catch (e) {
      if (mounted) setState(() => noticeError = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => noticeError = 'Не удалось выполнить действие. Проверьте доступ к файлам и соединение со службой.',
        );
      }
    }
  }

  Future<void> import() async {
    setState(() {
      importing = true;
      importError = null;
    });
    try {
      await client.importText(
        input.text,
        title: importTitle.text.trim().isEmpty ? null : importTitle.text.trim(),
      );
      if (mounted) {
        setState(() {
          input.clear();
          importTitle.clear();
          importVisible = false;
          notice = 'Профили добавлены';
        });
      }
    } on FormatException catch (e) {
      if (mounted) setState(() => importError = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => importError = 'Импорт не выполнен. Проверьте ссылку, формат данных и доступ к сети.',
        );
      }
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  void navigate(int index) {
    if (index == 4) {
      unawaited(action(client.refreshLogs));
      unawaited(showArenaLogs(context, client));
      return;
    }
    setState(() {
      page = index;
      notice = null;
      noticeError = null;
    });
    if (index == 4) unawaited(action(client.refreshLogs));
  }

  void openImport() => unawaited(showArenaImport(context, client));

  Future<void> openUrl(String value) async {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['https', 'http', 'mailto', 'tg'].contains(uri.scheme)) {
      return;
    }
    try {
      if (Platform.isLinux) await Process.start('xdg-open', [value]);
    } catch (_) {
      if (mounted) setState(() => noticeError = 'Не удалось открыть ссылку.');
    }
  }

  Future<void> windowAction(String action) async {
    try {
      await const MethodChannel('velum/window').invokeMethod<void>(action);
    } on MissingPluginException {
      if (action == 'close') await SystemNavigator.pop();
    }
  }

  void inspectServer(int index) {
    final identity = client.profiles[index].id;
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .75),
      builder: (_) => ArenaInspector(
        client: client,
        index: index,
        onAction: (value) {
          final current = client.profiles.indexWhere((p) => p.id == identity);
          if (current >= 0) unawaited(profileAction(value, current));
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!exclusionsDirty && exclusions.text != client.exclusions) {
      exclusions.text = client.exclusions;
    }
    final scheme = Theme.of(context).colorScheme;
    final body = switch (page) {
      0 => ArenaConnection(
        client: client,
        onImport: openImport,
        onSubscriptions: () => navigate(2),
        onInspect: inspectServer,
        onQr: () => unawaited(showArenaImport(context, client, scan: true)),
        onOpenUrl: (url) => unawaited(openUrl(url)),
      ),
      1 => ArenaServers(
        client: client,
        onImport: openImport,
        onInspect: inspectServer,
        onQr: () => unawaited(showArenaImport(context, client, scan: true)),
        onSubscriptions: () => navigate(2),
      ),
      3 => ArenaRouting(
        client: client,
        onBack: () => navigate(0),
        advancedRules: Column(children: routingPage()),
      ),
      5 => ArenaSettings(
        client: client,
        onRouting: () => navigate(3),
        onLogs: () => navigate(4),
        onSubscriptions: () => navigate(2),
        advancedSettings: Column(children: settingsPage()),
        appearance: client.settings,
        onAppearanceChanged: (patch) =>
            unawaited(action(() => client.saveSettings(patch))),
      ),
      _ => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 112),
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: () => navigate(0),
                    icon: const ArenaGlyph('ArrowLeft'),
                  ),
                  Text(
                    pages[page].$1,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              ...page == 2 ? subscriptionsPage() : logsPage(),
            ],
          ),
        ),
      ),
    };
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: ArenaBackdrop(
                patternId:
                    client.settings['patternId'] as String? ?? 'topography',
                intensity: client.settings['patternIntensity'] as int? ?? 68,
                connected: running,
              ),
            ),
            Column(
              children: [
                SizedBox(
                  height: 48,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onPanStart: (_) => unawaited(windowAction('drag')),
                            onDoubleTap: () =>
                                unawaited(windowAction('maximize')),
                            child: Row(
                              children: [
                                ShaderMask(
                                  shaderCallback: (rect) => LinearGradient(
                                    colors: [
                                      scheme.primary,
                                      const Color(0xffc084fc),
                                    ],
                                  ).createShader(rect),
                                  child: const Text(
                                    'VELUM',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 1.08,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                const Text(
                                  'v0.2.0',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Color(0x8ce9d5ff),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        SizedBox(
                          key: const ValueKey('nav-3'),
                          child: arenaSmallButton(
                            'Globe',
                            'Профили маршрутизации',
                            () => navigate(page == 3 ? 0 : 3),
                            acid: client.settings['routeMode'] == 'rules',
                          ),
                        ),
                        const SizedBox(width: 6),
                        SizedBox(
                          key: const ValueKey('nav-4'),
                          child: arenaSmallButton(
                            'Terminal',
                            'Журнал и конфигурация',
                            () => navigate(4),
                          ),
                        ),
                        Container(
                          width: 1,
                          height: 16,
                          margin: const EdgeInsets.symmetric(horizontal: 8),
                          color: Colors.white.withValues(alpha: .1),
                        ),
                        for (final entry in [
                          ('Minus', 'minimize'),
                          ('Square', 'maximize'),
                          ('X', 'close'),
                        ])
                          SizedBox(
                            width: 32,
                            height: 32,
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              onPressed: () =>
                                  unawaited(windowAction(entry.$2)),
                              tooltip: entry.$2,
                              icon: ArenaGlyph(
                                entry.$1,
                                size: 14,
                                color: const Color(0xa6e9d5ff),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Expanded(child: body),
              ],
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Container(
                    key: const ValueKey('arena-dock'),
                    height: MediaQuery.sizeOf(context).width >= 640 ? 52 : 66,
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: const Color(0xe00e071b),
                      borderRadius: BorderRadius.circular(40),
                      border: Border.all(color: const Color(0x38a855f7)),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0xa6000000),
                          offset: Offset(0, 14),
                          blurRadius: 40,
                        ),
                      ],
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final entry in [
                          (0, 'Share2', 'Подключение'),
                          (1, 'Server', 'Серверы'),
                          (5, 'Settings', 'Настройки'),
                        ])
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, c) => Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 2,
                                ),
                                child: TextButton(
                                  key: ValueKey('nav-${entry.$1}'),
                                  onPressed: () => navigate(entry.$1),
                                  style: TextButton.styleFrom(
                                    minimumSize: Size.zero,
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    padding: EdgeInsets.symmetric(
                                      vertical:
                                          MediaQuery.sizeOf(context).width >=
                                              640
                                          ? 10
                                          : 8,
                                      horizontal: 4,
                                    ),
                                    shape: StadiumBorder(
                                      side: BorderSide(
                                        color: page == entry.$1
                                            ? scheme.primary.withValues(
                                                alpha: .45,
                                              )
                                            : Colors.transparent,
                                      ),
                                    ),
                                    backgroundColor: page == entry.$1
                                        ? scheme.secondary.withValues(alpha: .2)
                                        : Colors.transparent,
                                  ),
                                  child: MediaQuery.sizeOf(context).width >= 640
                                      ? Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            ArenaGlyph(
                                              entry.$2,
                                              size: 16,
                                              color: page == entry.$1
                                                  ? scheme.primary
                                                  : const Color(0xa6d8ccf0),
                                            ),
                                            const SizedBox(width: 8),
                                            Flexible(
                                              child: Text(
                                                entry.$3,
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  height: 1.2,
                                                  fontWeight: FontWeight.bold,
                                                  color: page == entry.$1
                                                      ? Colors.white
                                                      : const Color(0xa6d8ccf0),
                                                ),
                                              ),
                                            ),
                                          ],
                                        )
                                      : Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            ArenaGlyph(
                                              entry.$2,
                                              size: 16,
                                              color: page == entry.$1
                                                  ? scheme.primary
                                                  : const Color(0xa6d8ccf0),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              entry.$3,
                                              style: TextStyle(
                                                fontSize: 11,
                                                height: 1.2,
                                                fontWeight: FontWeight.bold,
                                                color: page == entry.$1
                                                    ? Colors.white
                                                    : const Color(0xa6d8ccf0),
                                              ),
                                            ),
                                          ],
                                        ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (noticeError != null || notice != null)
              Positioned(
                top: 54,
                left: 24,
                right: 24,
                child: Center(
                  child: Material(
                    color: const Color(0xff120924),
                    borderRadius: BorderRadius.circular(30),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              noticeError ?? notice!,
                              style: TextStyle(
                                fontSize: 12,
                                color: noticeError != null
                                    ? scheme.error
                                    : scheme.primary,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () => setState(() {
                              noticeError = null;
                              notice = null;
                            }),
                            icon: const ArenaGlyph('X'),
                            iconSize: 14,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget statusDot() => SizedBox(
    width: 8,
    height: 8,
    child: DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: running
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.outline,
      ),
    ),
  );
  Widget message(String text, {bool error = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          error ? Icons.error_outline : Icons.check_circle_outline,
          size: 19,
          color: error
              ? Theme.of(context).colorScheme.error
              : Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: error
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ],
    ),
  );
  Widget section(String title, String? description, Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (description != null) ...[
          const SizedBox(height: 6),
          Text(
            description,
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 18),
        child,
      ],
    ),
  );
  Widget surface(Widget child) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(12),
    ),
    child: child,
  );

  List<Widget> connectionPage() {
    final title = locked
        ? 'Подключаем…'
        : !running
        ? client.state == 'offline'
              ? 'Служба недоступна'
              : 'Не подключено'
        : client.verified
        ? 'Соединение проверено'
        : 'Ядро запущено';
    return [
      Center(
        child: Column(
          children: [
            const SizedBox(height: 8),
            ArenaPowerButton(
              running: running,
              busy: locked,
              onPressed: locked || (!running && selectedProfile == null)
                  ? null
                  : () => action(client.toggle),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              running
                  ? client.mode == 'tun'
                        ? 'Системный туннель активен'
                        : 'Локальный прокси активен'
                  : 'Выберите сервер и включите соединение.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 28),
      surface(
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 8,
          ),
          leading: const Icon(Icons.dns_outlined),
          title: Text(
            selectedProfile?.name ?? 'Сервер не выбран',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            selectedProfile == null
                ? 'Добавьте свой профиль или подписку'
                : '${selectedProfile!.protocol} · ${selectedProfile!.server}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: IconButton(
            tooltip: 'Выбрать сервер',
            icon: const Icon(Icons.chevron_right),
            onPressed: () => navigate(1),
          ),
        ),
      ),
      const SizedBox(height: 20),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          FilledButton.icon(
            onPressed: locked || (!running && selectedProfile == null)
                ? null
                : () => action(client.toggle),
            icon: locked
                ? const SizedBox(
                    width: 17,
                    height: 17,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    running
                        ? Icons.stop_rounded
                        : Icons.power_settings_new_rounded,
                  ),
            label: Text(running ? 'Отключить' : 'Подключить'),
          ),
          if (running)
            OutlinedButton.icon(
              onPressed: locked ? null : () => action(client.checkConnection),
              icon: const Icon(Icons.network_check_rounded),
              label: const Text('Проверить соединение'),
            ),
          if (running)
            IconButton(
              tooltip: 'Переподключить',
              onPressed: locked ? null : () => action(client.reconnect),
              icon: const Icon(Icons.refresh_rounded),
            ),
          if (selectedProfile == null)
            OutlinedButton.icon(
              onPressed: openImport,
              icon: const Icon(Icons.add),
              label: const Text('Добавить сервер'),
            ),
        ],
      ),
      const SizedBox(height: 30),
      if (running) ...[
        section(
          'Сеанс',
          null,
          Wrap(
            spacing: 36,
            runSpacing: 20,
            children: [
              metric('Время', duration(client.uptimeSeconds)),
              metric('Получено', bytes(client.downloadTotal)),
              metric('Отправлено', bytes(client.uploadTotal)),
              if (client.latencyMs != null)
                metric('Проверка HTTPS', '${client.latencyMs} мс'),
            ],
          ),
        ),
        if (client.downloadRate != null || client.uploadRate != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Text(
              '↓ ${bytes(client.downloadRate)}/с     ↑ ${bytes(client.uploadRate)}/с',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (client.mode != 'tun')
          section(
            'Использование прокси',
            'Подключение Velum не меняет сеть всех приложений.',
            SelectableText(
              client.status['proxy'] as String? ??
                  '127.0.0.1:${client.settings['proxyPort'] ?? 2080}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
      ],
      const Divider(),
      const SizedBox(height: 20),
      Text(
        'Закрытие окна не отключает службу. Для завершения сеанса нажмите «Отключить».',
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ];
  }

  Widget metric(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
        ),
      ),
      const SizedBox(height: 6),
      Text(
        value,
        style: Theme.of(context).textTheme.titleLarge
            ?.copyWith(fontWeight: FontWeight.w500),
      ),
    ],
  );
  String bytes(int? value) {
    if (value == null) return '—';
    const units = ['Б', 'КБ', 'МБ', 'ГБ'];
    var v = value.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
  }

  String duration(int seconds) {
    final d = Duration(seconds: seconds);
    return '${d.inHours.toString().padLeft(2, '0')}:${(d.inMinutes % 60).toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  String date(DateTime? value) => value == null
      ? 'Ещё не обновлялась'
      : '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')}.${value.year} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  List<Widget> serversPage() {
    final filtered = client.filteredProfiles(
      query: search.text,
      subscriptionId: subscriptionFilter,
      favoritesOnly: favoritesOnly,
      sort: sort,
    );
    return [
      if (importVisible) importPanel(),
      TextField(
        controller: search,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: 'Найти сервер',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: search.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Очистить поиск',
                  onPressed: () {
                    search.clear();
                    setState(() {});
                  },
                  icon: const Icon(Icons.close),
                ),
        ),
      ),
      const SizedBox(height: 14),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilterChip(
            label: const Text('Избранное'),
            avatar: const Icon(Icons.star_outline, size: 17),
            selected: favoritesOnly,
            onSelected: (v) => setState(() => favoritesOnly = v),
          ),
          SizedBox(
            width: 160,
            child: DropdownButtonFormField<String>(
              initialValue: sort,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Порядок',
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(value: 'name', child: Text('По имени')),
                DropdownMenuItem(value: 'latency', child: Text('По задержке')),
                DropdownMenuItem(
                  value: 'protocol',
                  child: Text('По протоколу'),
                ),
              ],
              onChanged: (v) => setState(() => sort = v ?? 'name'),
            ),
          ),
          OutlinedButton.icon(
            onPressed: client.pinging || client.profiles.isEmpty
                ? null
                : () => action(
                    () => client.pingProfiles(
                      filtered.map(client.indexOf).toList(),
                    ),
                  ),
            icon: client.pinging
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.speed, size: 18),
            label: const Text('Проверить TCP'),
          ),
        ],
      ),
      if (client.subscriptions.isNotEmpty) ...[
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('Все'),
              selected: subscriptionFilter == null,
              onSelected: (_) => setState(() => subscriptionFilter = null),
            ),
            ...client.subscriptions.map(
              (s) => ChoiceChip(
                label: Text(s.title),
                selected: subscriptionFilter == s.id,
                onSelected: (_) => setState(() => subscriptionFilter = s.id),
              ),
            ),
          ],
        ),
      ],
      const SizedBox(height: 22),
      if (filtered.isEmpty)
        empty(
          Icons.dns_outlined,
          client.profiles.isEmpty
              ? 'Здесь будут ваши серверы'
              : 'Серверы не найдены',
          client.profiles.isEmpty
              ? 'Импортируйте ссылку сервера, список или подписку.'
              : 'Измените поиск или фильтр.',
          actionLabel: client.profiles.isEmpty ? 'Добавить подключение' : null,
          onAction: openImport,
        ),
      for (final p in filtered) profileRow(p),
      if (filtered.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text(
            'TCP-проверка показывает доступность порта сервера, а не скорость VPN.',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
    ];
  }

  Widget profileRow(Profile p) {
    final index = client.indexOf(p);
    final selected = index == client.selected;
    return Column(
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 0,
            vertical: 5,
          ),
          selected: selected,
          leading: Icon(
            selected ? Icons.radio_button_checked : Icons.radio_button_off,
            size: 21,
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
              if (p.favorite)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(
                    Icons.star_rounded,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
            ],
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              '${p.protocol} · ${p.server}${p.latencyMs == null ? '' : ' · ${p.latencyMs} мс TCP'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          onTap: locked ? null : () => selectProfile(index),
          trailing: PopupMenuButton<String>(
            tooltip: 'Действия с сервером',
            onSelected: (value) => profileAction(value, index),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'favorite',
                child: Text(
                  p.favorite ? 'Убрать из избранного' : 'В избранное',
                ),
              ),
              const PopupMenuItem(value: 'ping', child: Text('Проверить TCP')),
              const PopupMenuItem(
                value: 'copy',
                child: Text('Скопировать ссылку'),
              ),
              const PopupMenuItem(
                value: 'rename',
                child: Text('Переименовать'),
              ),
              const PopupMenuItem(
                value: 'edit',
                child: Text('Изменить профиль'),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'delete',
                enabled: !locked && !(running && selected),
                child: const Text('Удалить'),
              ),
            ],
          ),
        ),
        const Divider(),
      ],
    );
  }

  Future<void> selectProfile(int index) async => action(() async {
    await client.select(index);
    if (running) await client.reconnect();
  });
  Future<void> profileAction(String value, int index) async {
    final p = client.profiles[index];
    switch (value) {
      case 'favorite':
        await action(() => client.toggleFavorite(index));
      case 'ping':
        await action(() => client.pingProfiles([index]));
      case 'copy':
        await action(
          () => Clipboard.setData(
            ClipboardData(text: client.exportProfile(index)),
          ),
          success: 'Ссылка скопирована. Она содержит данные доступа.',
        );
      case 'rename':
        final name = await textDialog('Название сервера', 'Название', p.name);
        if (name != null) await action(() => client.rename(index, name));
      case 'edit':
        if (running && index == client.selected) {
          setState(
            () => noticeError =
                'Отключите текущий сервер перед изменением его данных.',
          );
          return;
        }
        final uri = await textDialog(
          'Изменить профиль',
          'Ссылка сервера',
          p.uri,
          multiline: true,
        );
        if (uri != null) await action(() => client.edit(index, uri, p.name));
      case 'delete':
        if (await confirm(
          'Удалить сервер?',
          'Сервер «${p.name}» будет удалён с этого устройства.',
        )) {
          await action(() => client.remove(index));
        }
    }
  }

  Widget importPanel() => Padding(
    padding: const EdgeInsets.only(bottom: 28),
    child: surface(
      Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Добавить подключение',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Закрыть импорт',
                  onPressed: importing
                      ? null
                      : () => setState(() => importVisible = false),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: input,
              minLines: 3,
              maxLines: 6,
              enabled: !importing,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Ссылка, подписка или список серверов',
                helperText: 'HTTPS, share-ссылки и Base64',
                errorText: importError,
                errorMaxLines: 4,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: importTitle,
              enabled: !importing,
              decoration: const InputDecoration(
                labelText: 'Название подписки',
                hintText: 'Необязательно',
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: importing ? null : import,
                  icon: importing
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add),
                  label: Text(importing ? 'Импортируем…' : 'Добавить'),
                ),
                TextButton.icon(
                  onPressed: importing
                      ? null
                      : () => action(() async {
                          final value = await Clipboard.getData(
                            Clipboard.kTextPlain,
                          );
                          if (mounted && value != null) {
                            setState(() => input.text = value.text ?? '');
                          }
                        }),
                  icon: const Icon(Icons.content_paste, size: 18),
                  label: const Text('Из буфера'),
                ),
                TextButton.icon(
                  onPressed: importing ? null : importFile,
                  icon: const Icon(Icons.file_open_outlined, size: 18),
                  label: const Text('Из файла'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  List<Widget> subscriptionsPage() => [
    Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        OutlinedButton.icon(
          onPressed: client.subscriptions.isEmpty || locked
              ? null
              : () => action(client.updateAllSubscriptions),
          icon: const Icon(Icons.sync),
          label: const Text('Обновить все'),
        ),
        TextButton.icon(
          onPressed: openImport,
          icon: const Icon(Icons.add),
          label: const Text('Добавить подписку'),
        ),
      ],
    ),
    const SizedBox(height: 24),
    if (client.subscriptions.isEmpty)
      empty(
        Icons.rss_feed,
        'Подписок пока нет',
        'Добавьте HTTPS-ссылку. Velum сохранит источник и сможет обновлять список серверов.',
        actionLabel: 'Добавить подписку',
        onAction: openImport,
      ),
    for (final s in client.subscriptions)
      Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    s.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Настройки подписки',
                  onSelected: (value) async {
                    switch (value) {
                      case 'settings':
                        await subscriptionSettings(s.id);
                      case 'copy':
                        await action(
                          () => Clipboard.setData(ClipboardData(text: s.url)),
                          success: 'Ссылка подписки скопирована. Она содержит данные доступа.',
                        );
                      case 'delete':
                        if (await confirm(
                          'Удалить подписку?',
                          'Подписка и её серверы будут удалены с этого устройства.',
                        )) {
                          await action(() => client.removeSubscription(s.id));
                        }
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'settings',
                      child: Text('Настройки подписки'),
                    ),
                    const PopupMenuItem(
                      value: 'copy',
                      child: Text('Скопировать ссылку'),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'delete',
                      enabled:
                          !locked &&
                          !(running && selectedProfile?.subscriptionId == s.id),
                      child: const Text('Удалить'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              '${client.profiles.where((p) => p.subscriptionId == s.id).length} серверов · ${date(s.lastUpdated)}',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              s.autoUpdate
                  ? 'Автообновление каждые ${s.intervalMinutes} мин'
                  : 'Обновление вручную',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (s.total != null && s.total! > 0) ...[
              const SizedBox(height: 12),
              Text(
                '${bytes((s.upload ?? 0) + (s.download ?? 0))} из ${bytes(s.total)}',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: (((s.upload ?? 0) + (s.download ?? 0)) / s.total!).clamp(
                  0,
                  1,
                ),
              ),
            ],
            if (s.expires != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Действует до ${date(s.expires)}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            if (s.error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  s.error,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: locked
                      ? null
                      : () => action(
                          () => client.updateSubscription(s.id),
                          success: 'Подписка обновлена',
                        ),
                  icon: const Icon(Icons.sync, size: 18),
                  label: const Text('Обновить'),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    subscriptionFilter = s.id;
                    page = 1;
                  }),
                  child: const Text('Показать серверы'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Divider(),
          ],
        ),
      ),
  ];
  Future<void> subscriptionSettings(String id) async {
    final s = client.subscriptions.firstWhere((s) => s.id == id);
    final name = TextEditingController(text: s.title);
    final userAgent = TextEditingController(text: s.userAgent);
    final interval = TextEditingController(text: '${s.intervalMinutes}');
    var auto = s.autoUpdate;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('Настройки подписки'),
          content: SizedBox(
            width: 430,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'Название'),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: userAgent,
                    decoration: const InputDecoration(labelText: 'User-Agent'),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Автообновление'),
                    value: auto,
                    onChanged: (v) => setDialog(() => auto = v),
                  ),
                  TextField(
                    controller: interval,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Интервал в минутах',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    if (result == true) {
      await action(
        () => client.configureSubscription(
          id,
          title: name.text,
          userAgent: userAgent.text,
          autoUpdate: auto,
          intervalMinutes: int.tryParse(interval.text) ?? 60,
        ),
      );
    }
    name.dispose();
    userAgent.dispose();
    interval.dispose();
  }

  List<Widget> routingPage() {
    final rules = (client.settings['rules'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .toList();
    return [
      setting(
        'Режим маршрутизации',
        'Глобальный режим использует прокси, сохраняя прямые исключения.',
        dropdown(client.settings['routeMode'] as String? ?? 'global', const {
          'global': 'Глобальный',
          'rules': 'По правилам',
        }, (v) => saveSetting('routeMode', v)),
      ),
      const SizedBox(height: 24),
      section(
        'Прямые исключения',
        'Домены и CIDR через запятую. Они сохраняются независимо от подписок.',
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: exclusions,
              onChanged: (_) => exclusionsDirty = true,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Домены и сети',
                hintText: 'example.org, 192.168.0.0/16',
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: locked
                    ? null
                    : () => action(
                        () => client.saveExclusions(exclusions.text),
                        success: 'Исключения сохранены',
                      ),
                child: const Text('Сохранить исключения'),
              ),
            ),
          ],
        ),
      ),
      Row(
        children: [
          Expanded(
            child: Text(
              'Правила',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          TextButton.icon(
            onPressed: locked ? null : () => editRule(),
            icon: const Icon(Icons.add),
            label: const Text('Добавить'),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        client.settings['routeMode'] == 'rules'
            ? 'Проверяются по порядку. Изменения применяются при переподключении.'
            : 'Правила сохранены, но не применяются в глобальном режиме. Выберите «По правилам».',
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 14),
      if (rules.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 18),
          child: Text(
            'Правил пока нет. Можно направить домен, сеть или процесс напрямую, через прокси либо заблокировать.',
          ),
        ),
      for (final entry in rules.indexed)
        Column(
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(switch (entry.$2['action']) {
                'block' => Icons.block,
                'direct' => Icons.call_made,
                _ => Icons.alt_route,
              }),
              title: Text(
                entry.$2['value'] as String? ?? '',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${ruleType(entry.$2['type'] as String? ?? '')} · ${ruleAction(entry.$2['action'] as String? ?? '')}',
                style: const TextStyle(fontSize: 12),
              ),
              onTap: locked ? null : () => editRule(index: entry.$1),
              trailing: PopupMenuButton<String>(
                tooltip: 'Действия с правилом',
                onSelected: (v) => action(() async {
                  final copy = rules
                      .map((r) => Map<String, dynamic>.of(r))
                      .toList();
                  final i = entry.$1;
                  if (v == 'delete') copy.removeAt(i);
                  if (v == 'up' && i > 0) {
                    final item = copy.removeAt(i);
                    copy.insert(i - 1, item);
                  }
                  if (v == 'down' && i < copy.length - 1) {
                    final item = copy.removeAt(i);
                    copy.insert(i + 1, item);
                  }
                  await client.saveSettings({'rules': copy});
                }),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'up',
                    enabled: !locked && entry.$1 > 0,
                    child: const Text('Выше'),
                  ),
                  PopupMenuItem(
                    value: 'down',
                    enabled: !locked && entry.$1 < rules.length - 1,
                    child: const Text('Ниже'),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    enabled: !locked,
                    child: const Text('Удалить'),
                  ),
                ],
              ),
            ),
            const Divider(),
          ],
        ),
      const SizedBox(height: 24),
      if (running)
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: locked ? null : () => action(client.reconnect),
            icon: const Icon(Icons.refresh),
            label: const Text('Применить и переподключить'),
          ),
        ),
    ];
  }

  String ruleType(String value) => switch (value) {
    'cidr' => 'IP / CIDR',
    'process' => 'Процесс',
    _ => 'Домен',
  };
  String ruleAction(String value) => switch (value) {
    'direct' => 'Напрямую',
    'block' => 'Блокировать',
    _ => 'Через прокси',
  };
  Future<void> editRule({int? index}) async {
    final rules = (client.settings['rules'] as List<dynamic>? ?? [])
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
    final existing = index == null ? null : rules[index];
    var type = existing?['type'] as String? ?? 'domain';
    var target = existing?['action'] as String? ?? 'direct';
    final value = TextEditingController(
      text: existing?['value'] as String? ?? '',
    );
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text(index == null ? 'Добавить правило' : 'Изменить правило'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: type,
                  decoration: const InputDecoration(labelText: 'Условие'),
                  items: const [
                    DropdownMenuItem(
                      value: 'domain',
                      child: Text('Домен и поддомены'),
                    ),
                    DropdownMenuItem(value: 'cidr', child: Text('IP / CIDR')),
                    DropdownMenuItem(
                      value: 'process',
                      child: Text('Имя процесса'),
                    ),
                  ],
                  onChanged: (v) => setDialog(() => type = v ?? 'domain'),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: value,
                  decoration: InputDecoration(
                    labelText: 'Значение',
                    hintText: switch (type) {
                      'cidr' => '192.168.0.0/16',
                      'process' => 'firefox',
                      _ => 'example.org',
                    },
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: target,
                  decoration: const InputDecoration(labelText: 'Действие'),
                  items: const [
                    DropdownMenuItem(value: 'direct', child: Text('Напрямую')),
                    DropdownMenuItem(
                      value: 'proxy',
                      child: Text('Через прокси'),
                    ),
                    DropdownMenuItem(
                      value: 'block',
                      child: Text('Блокировать'),
                    ),
                  ],
                  onChanged: (v) => setDialog(() => target = v ?? 'direct'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    if (result == true) {
      await action(() async {
        final rule = {
          'action': target,
          'type': type,
          'value': value.text.trim(),
        };
        if (index == null) {
          rules.add(rule);
        } else {
          rules[index] = rule;
        }
        await client.saveSettings({'rules': rules});
      });
    }
    value.dispose();
  }

  List<Widget> logsPage() => [
    Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        OutlinedButton.icon(
          onPressed: () => action(client.refreshLogs),
          icon: const Icon(Icons.refresh),
          label: const Text('Обновить'),
        ),
        TextButton.icon(
          onPressed: client.logs.isEmpty
              ? null
              : () => action(
                  () => Clipboard.setData(
                    ClipboardData(
                      text: const JsonEncoder.withIndent('  ')
                          .convert(client.logs),
                    ),
                  ),
                  success: 'Журнал скопирован',
                ),
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Скопировать'),
        ),
      ],
    ),
    const SizedBox(height: 20),
    if (client.logs.isEmpty)
      empty(
        Icons.subject,
        'Событий пока нет',
        'Запустите соединение или обновите журнал службы.',
      ),
    for (final entry in client.logs.reversed)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              (entry['time'] ?? entry['timestamp'] ?? '').toString(),
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              (entry['message'] ?? entry['event'] ?? jsonEncode(entry))
                  .toString(),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 10),
            const Divider(),
          ],
        ),
      ),
  ];

  List<Widget> settingsPage() => [
    section(
      'Подключение',
      'Изменения сетевых настроек применяются при следующем подключении.',
      Column(
        children: [
          setting(
            'Режим подключения',
            client.status['tunAllowed'] == true
                ? 'Служба поддерживает системный туннель.'
                : 'Для TUN запустите системную службу с сетевыми привилегиями.',
            dropdown(
              client.settings['mode'] as String? ?? 'proxy',
              const {'proxy': 'Локальный прокси', 'tun': 'Системный TUN'},
              (v) => saveSetting('mode', v),
              disabled: client.status['tunAllowed'] == true
                  ? const <String>{}
                  : const <String>{'tun'},
            ),
          ),
          setting(
            'Исходящий интерфейс',
            'Оставьте пустым для автоматического выбора.',
            editValue(
              client.settings['interface'] as String? ?? '',
              'Интерфейс',
              (v) => saveSetting('interface', v),
            ),
          ),
          setting(
            'Порт HTTP / SOCKS',
            'Локальный адрес 127.0.0.1.',
            editValue(
              '${client.settings['proxyPort'] ?? 2080}',
              'Локальный порт',
              (v) async {
                final port = int.tryParse(v);
                if (port == null || port < 1024 || port > 65535) {
                  throw const FormatException('Нужен порт от 1024 до 65535.');
                }
                await saveSetting('proxyPort', port);
              },
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Перезапуск ядра после сбоя'),
            subtitle: const Text(
              'Если служба поддерживает восстановление сеанса.',
            ),
            value: client.settings['reconnect'] as bool? ?? false,
            onChanged: locked ? null : (v) => saveSetting('reconnect', v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Маршрутизировать IPv6 в TUN'),
            value: client.settings['ipv6'] as bool? ?? true,
            onChanged: locked ? null : (v) => saveSetting('ipv6', v),
          ),
          setting(
            'MTU',
            'Размер пакета TUN, 1280–9000.',
            editValue('${client.settings['mtu'] ?? 1400}', 'MTU', (v) async {
              final mtu = int.tryParse(v);
              if (mtu == null || mtu < 1280 || mtu > 9000) {
                throw const FormatException('MTU должен быть от 1280 до 9000.');
              }
              await saveSetting('mtu', mtu);
            }),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('TLS-фрагментация'),
            subtitle: const Text(
              'Настройка совместимости; может замедлить соединение.',
            ),
            value: client.settings['fragment'] as bool? ?? false,
            onChanged: locked ? null : (v) => saveSetting('fragment', v),
          ),
        ],
      ),
    ),
    const Divider(),
    const SizedBox(height: 24),
    section(
      'DNS',
      'Удалённый DNS используется через прокси. Bootstrap сервера выполняется до подключения.',
      Column(
        children: [
          setting(
            'Удалённый DNS',
            'Например, https://1.1.1.1/dns-query.',
            editValue(
              client.settings['dns'] as String? ?? 'https://1.1.1.1/dns-query',
              'Удалённый DNS',
              (v) => saveSetting('dns', v),
            ),
          ),
          setting(
            'Прямой DNS',
            'local — системный резолвер.',
            editValue(
              client.settings['directDns'] as String? ?? 'local',
              'Прямой DNS',
              (v) => saveSetting('directDns', v),
            ),
          ),
        ],
      ),
    ),
    const Divider(),
    const SizedBox(height: 24),
    section(
      'Внешний вид',
      null,
      setting(
        'Тема',
        'Системная тема следует настройкам рабочего стола.',
        dropdown(client.settings['theme'] as String? ?? 'system', const {
          'system': 'Системная',
          'light': 'Светлая',
          'dark': 'Тёмная',
        }, (v) => saveSetting('theme', v)),
      ),
    ),
    const Divider(),
    const SizedBox(height: 24),
    section(
      'Резервная копия',
      'Содержит ссылки и данные доступа. Храните её в надёжном месте.',
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          OutlinedButton.icon(
            onPressed: () => backupExport(),
            icon: const Icon(Icons.save_alt),
            label: const Text('Экспортировать'),
          ),
          OutlinedButton.icon(
            onPressed: locked || running ? null : () => backupRestore(),
            icon: const Icon(Icons.restore),
            label: const Text('Восстановить'),
          ),
        ],
      ),
    ),
    if (running)
      Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: locked ? null : () => action(client.reconnect),
            icon: const Icon(Icons.refresh),
            label: const Text('Применить и переподключить'),
          ),
        ),
      ),
    Text(
      'Velum · открытый исходный код\nGPL-3.0-or-later',
      style: TextStyle(
        fontSize: 12,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  ];
  Widget setting(String title, String? description, Widget control) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 13),
    child: LayoutBuilder(
      builder: (context, box) {
        final label = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            if (description != null) ...[
              const SizedBox(height: 5),
              Text(
                description,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        );
        if (box.maxWidth < 560) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [label, const SizedBox(height: 12), control],
          );
        }
        return Row(
          children: [
            Expanded(child: label),
            const SizedBox(width: 24),
            SizedBox(width: 230, child: control),
          ],
        );
      },
    ),
  );
  Widget dropdown(
    String value,
    Map<String, String> options,
    Future<void> Function(String) changed, {
    Set<String> disabled = const <String>{},
  }) => DropdownButtonFormField<String>(
    key: ValueKey('$value-${options.keys.join()}'),
    initialValue: options.containsKey(value) ? value : options.keys.first,
    isExpanded: true,
    items: options.entries
        .map(
          (e) => DropdownMenuItem(
            value: e.key,
            enabled: !disabled.contains(e.key),
            child: Text(e.value),
          ),
        )
        .toList(),
    onChanged: locked
        ? null
        : (v) {
            if (v != null) unawaited(changed(v));
          },
  );
  Widget editValue(
    String value,
    String label,
    Future<void> Function(String) save,
  ) => OutlinedButton(
    onPressed: locked
        ? null
        : () async {
            final result = await textDialog(label, label, value);
            if (result != null) await action(() => save(result));
          },
    child: Row(
      children: [
        Expanded(
          child: Text(
            value.isEmpty ? 'Автоматически' : value,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.left,
          ),
        ),
        const SizedBox(width: 8),
        const Icon(Icons.edit_outlined, size: 16),
      ],
    ),
  );
  Future<void> saveSetting(String key, dynamic value) => action(
    () => client.saveSettings({key: value}),
    success: 'Настройка сохранена',
  );
  Future<void> backupExport() async {
    final location = await getSaveLocation(
      suggestedName: 'velum-backup.json',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (location == null || !mounted) return;
    await action(() async {
      final file = File(location.path);
      final stream = await file.open(mode: FileMode.write);
      try {
        if (Platform.isLinux) {
          final chmod = await Process.run('chmod', ['600', file.path]);
          if (chmod.exitCode != 0) {
            throw const FileSystemException(
              'Не удалось защитить резервную копию.',
            );
          }
        }
        await stream.writeString(client.exportBackup());
        await stream.flush();
      } finally {
        await stream.close();
      }
    }, success: 'Резервная копия сохранена');
  }

  Future<void> backupRestore() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (file == null || !mounted) return;
    if (!await confirm(
      'Заменить текущие данные?',
      'Серверы, подписки и настройки будут заменены данными из резервной копии.',
    )) {
      return;
    }
    await action(() async {
      if (await file.length() > 4 * 1024 * 1024) {
        throw const FormatException('Резервная копия больше 4 МБ.');
      }
      await client.restoreBackup(await file.readAsString());
    }, success: 'Резервная копия восстановлена');
  }

  Future<void> importFile() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Профили и подписки',
          extensions: ['txt', 'json', 'conf'],
        ),
      ],
    );
    if (file == null || !mounted) return;
    await action(() async {
      if (await file.length() > 1024 * 1024) {
        throw const FormatException('Файл больше 1 МБ.');
      }
      input.text = await file.readAsString();
    });
  }

  Future<String?> textDialog(
    String title,
    String label,
    String value, {
    bool multiline = false,
  }) async {
    final controller = TextEditingController(text: value);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: multiline ? 3 : 1,
            maxLines: multiline ? 6 : 1,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(labelText: label),
            onSubmitted: multiline
                ? null
                : (_) => Navigator.pop(context, controller.text.trim()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<bool> confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Продолжить'),
            ),
          ],
        ),
      ) ??
      false;
  Widget empty(
    IconData icon,
    String title,
    String body, {
    String? actionLabel,
    VoidCallback? onAction,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 36),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 30, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 16),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          body,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (actionLabel != null) ...[
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: onAction,
            icon: const Icon(Icons.add),
            label: Text(actionLabel),
          ),
        ],
      ],
    ),
  );
}
