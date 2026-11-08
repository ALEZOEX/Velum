import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'imports.dart';
import 'models.dart';
import 'system_proxy.dart';
export 'models.dart';
export 'system_proxy.dart';

const defaultSettings = <String, dynamic>{
  'theme': 'system',
  'themeId': 'velum-acid-violet',
  'patternId': 'topography',
  'patternIntensity': 68,
  'desktopLayout': 'compact',
  'language': 'ru',
  'mode': 'proxy',
  'mtu': 1400,
  'ipv6': true,
  'dns': 'https://1.1.1.1/dns-query',
  'directDns': 'local',
  'routeMode': 'global',
  'rules': <Map<String, dynamic>>[],
  'fragment': false,
  'reconnect': false,
  'proxyPort': 2080,
  'interface': '',
  'autoConnect': false,
  'autostart': false,
  'minimizeToTray': true,
  'systemProxy': false,
};
const _networkKeys = {
  'mode',
  'mtu',
  'ipv6',
  'dns',
  'directDns',
  'routeMode',
  'rules',
  'fragment',
  'reconnect',
  'proxyPort',
  'interface',
};

enum LinuxServiceState {
  notInstalled,
  installedStopped,
  running,
  unavailable,
  checkError,
}

class VelumClient extends ChangeNotifier {
  VelumClient({
    Directory? directory,
    Uri? apiBase,
    this.proxyManager,
  })  : directory =
            directory ??
            Directory(
              Platform.environment['VELUM_CONFIG_DIR'] ??
                  '${Platform.environment['HOME'] ?? Platform.environment['USERPROFILE']}/.config/velum',
            ),
        apiBase = apiBase ?? Uri.parse('http://127.0.0.1:27841/v1/');

  final Directory directory;
  final Uri apiBase;
  SystemProxyManager? proxyManager;
  SystemProxyStatus systemProxyStatus = SystemProxyStatus.disabled;

  bool get systemProxySupported => proxyManager?.isSupported ?? false;
  String get systemProxyUnsupportedReason =>
      proxyManager?.unsupportedReason ?? '';
  String get systemProxyEnvironment => proxyManager?.environmentName ?? '';
  final List<Profile> profiles = [];
  final List<Subscription> subscriptions = [];
  final Set<String> updatingSubscriptions = {};
  final List<Map<String, dynamic>> logs = [];
  Map<String, dynamic> settings = Map<String, dynamic>.from(defaultSettings);
  Map<String, dynamic> status = {};
  int selected = 0;
  String exclusions = '';
  String state = 'offline';
  String mode = '';
  String message = '';
  bool busy = false;
  bool pinging = false;
  Timer? _timer;
  Timer? _subscriptionTimer;
  bool _disposed = false;
  bool _polling = false;
  String _token = '';
  String _storageError = '';
  Future<void> _writes = Future<void>.value();
  File get _file => File('${directory.path}/profiles.json');
  File get _tokenFile {
    final override = Platform.environment['VELUM_TOKEN_FILE'];
    if (override != null && override.isNotEmpty) return File(override);
    if (Platform.isWindows) {
      final programData = Platform.environment['ProgramData'];
      if (programData != null && programData.isNotEmpty) {
        final shared = File('$programData\\Velum\\token');
        if (shared.existsSync()) return shared;
      }
    }
    return File('${directory.path}/token');
  }

  bool get running => state == 'running';
  bool get proxyInboundActive => running && (mode == 'proxy' || mode.isEmpty);
  String get engineState =>
      status['engineState'] as String? ?? (running ? 'running' : 'stopped');
  String get serviceMode => status['serviceMode'] as String? ?? 'console';
  bool get managedByService =>
      serviceMode == 'windows-service' || serviceMode == 'systemd';
  bool get verified => status['verified'] == true;
  bool get tunAllowed => state != 'offline' && status['tunAllowed'] == true;
  int? get latencyMs => status['latencyMs'] as int?;
  int get uptimeSeconds => status['uptimeSeconds'] as int? ?? 0;
  DateTime? get connectedAt =>
      DateTime.tryParse(status['connectedAt'] as String? ?? '');
  int? get uploadTotal => status['uploadTotal'] as int?;
  int? get downloadTotal => status['downloadTotal'] as int?;
  int? get uploadRate => status['uploadRate'] as int?;
  int? get downloadRate => status['downloadRate'] as int?;
  String get activeProfile => status['activeProfile'] as String? ?? '';
  int indexOf(Profile profile) => profiles.indexWhere(
    (p) => p.id == profile.id && p.subscriptionId == profile.subscriptionId,
  );
  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  Future<void> initialize() async {
    try {
      await _prepareDirectory();
      if (await _file.exists()) {
        final bytes = await _file.readAsBytes();
        if (bytes.length > 4 * maxImportBytes) {
          throw const FormatException('Файл профилей слишком большой.');
        }
        final document = _validatedDocument(jsonDecode(utf8.decode(bytes)));
        _applyDocument(document);
        if (document['migrated'] == true) {
          final original = File('${directory.path}/profiles.v1.backup.json');
          if (!await original.exists()) {
            await _privateWrite(original, bytes);
          }
          await _save();
        }
      }
    } on FormatException catch (error) {
      message = error.message;
      _storageError = error.message;
    } catch (_) {
      message =
          'Не удалось прочитать локальные профили. Проверьте каталог Velum.';
      _storageError = message;
    }
    if (Platform.isLinux || Platform.isMacOS) {
      await _ensureClientToken();
    }
    try {
      _token = (await _tokenFile.readAsString()).trim();
    } catch (_) {
      if (message.isEmpty) {
        message = 'Служба ещё не настроена. Выполните scripts/init-client.py.';
      }
    }
    proxyManager ??= await createSystemProxyManager(configDirectory: directory);
    await refresh();
    try {
      final proxyPort = settings['proxyPort'] as int? ?? 2080;
      final isVpnRunning = (state == 'running');
      final userWantsProxy = (settings['systemProxy'] == true);
      final inboundActive = await isProxyInboundListening(proxyPort);
      await proxyManager!.recoverIfOrphaned(
        host: '127.0.0.1',
        port: proxyPort,
        isVpnRunning: isVpnRunning,
        isProxyInboundActive: inboundActive,
        userWantsProxy: userWantsProxy,
      );
    } catch (error) {
      message = 'Не удалось восстановить системный прокси: $error';
    }
    await refreshSystemProxyStatus();
    _timer?.cancel();
    _subscriptionTimer?.cancel();
    _timer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(refresh()),
    );
    _subscriptionTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(_updateDueSubscriptions()),
    );
    if (settings['autoConnect'] == true &&
        state == 'disconnected' &&
        profiles.isNotEmpty) {
      await reconnect();
    }
    notifyListeners();
  }

  List<Profile> filteredProfiles({
    String query = '',
    String? subscriptionId,
    bool favoritesOnly = false,
    String sort = 'name',
  }) {
    final needle = query.toLowerCase().trim();
    final result = profiles
        .where(
          (p) =>
              (subscriptionId == null || p.subscriptionId == subscriptionId) &&
              (!favoritesOnly || p.favorite) &&
              (needle.isEmpty ||
                  '${p.name} ${p.server} ${p.protocol}'.toLowerCase().contains(
                    needle,
                  )),
        )
        .toList();
    switch (sort) {
      case 'latency':
        result.sort(
          (a, b) => (a.latencyMs ?? 1 << 30).compareTo(b.latencyMs ?? 1 << 30),
        );
      case 'protocol':
        result.sort(
          (a, b) =>
              '${a.protocol} ${a.name}'.compareTo('${b.protocol} ${b.name}'),
        );
      case 'original':
        break;
      default:
        result.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
    }
    return result;
  }

  Future<void> importText(String text, {String? title}) async {
    if (utf8.encode(text).length > maxImportBytes) {
      throw const FormatException('Данные больше 1 МБ.');
    }
    final payload = unwrapImport(text);
    final source = Uri.tryParse(payload);
    if (source?.scheme == 'https' &&
        source!.userInfo.isEmpty &&
        !(source.hasPort && source.fragment.isNotEmpty)) {
      final id = 'sub-${stableId(payload)}';
      final existing = subscriptions.where((s) => s.id == id).firstOrNull;
      final initial =
          existing ??
          Subscription(
            id: id,
            url: payload,
            title: _cleanTitle(title ?? source.host),
          );
      final fetched = await _fetchSubscription(initial);
      await _mutate(() {
        final index = subscriptions.indexWhere((s) => s.id == id);
        if (index < 0) {
          if (subscriptions.length >= 100) {
            throw const FormatException('Лимит — 100 подписок.');
          }
          subscriptions.add(fetched.subscription);
        } else {
          subscriptions[index] = fetched.subscription;
        }
        _replaceSubscriptionProfiles(id, fetched.profiles);
      });
    } else {
      final parsed = parseSubscriptionBody(payload);
      await _mutate(() {
        final identities = profiles
            .where((p) => p.subscriptionId == null)
            .map((p) => profileIdentity(p.uri))
            .toSet();
        profiles.addAll(
          parsed.where((p) => identities.add(profileIdentity(p.uri))),
        );
        if (profiles.length > maxProfiles) {
          throw const FormatException('Лимит — 500 профилей.');
        }
      });
    }
    message = '';
    notifyListeners();
  }

  Future<({Subscription subscription, List<Profile> profiles})>
  _fetchSubscription(Subscription subscription) async {
    final source = Uri.parse(subscription.url);
    if (source.scheme != 'https' ||
        source.host.isEmpty ||
        source.userInfo.isNotEmpty) {
      throw const FormatException(
        'Для подписки нужен HTTPS URL без встроенного пароля.',
      );
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client
          .getUrl(source)
          .timeout(const Duration(seconds: 10));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, subscription.userAgent);
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode != 200) {
        throw FormatException(
          'Подписка вернула HTTP ${response.statusCode}; перенаправления отключены.',
        );
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        bytes.addAll(chunk);
        if (bytes.length > maxImportBytes) {
          throw const FormatException('Подписка больше 1 МБ.');
        }
      }
      final parsed = parseSubscriptionBody(
        utf8.decode(bytes),
        subscriptionId: subscription.id,
      );
      String? header(String name) => response.headers.value(name);
      final info = <String, int>{};
      for (final part in (header('subscription-userinfo') ?? '').split(';')) {
        final pair = part.trim().split('=');
        if (pair.length == 2) {
          final value = int.tryParse(pair[1].trim());
          if (value != null && value >= 0) {
            info[pair[0].trim()] = value;
          }
        }
      }
      var name = header('profile-title');
      if (name?.startsWith('base64:') == true) {
        try {
          name = utf8.decode(
            base64.decode(base64.normalize(name!.substring(7))),
          );
        } catch (_) {
          name = null;
        }
      }
      final expiration = info['expire'];
      final expires =
          expiration != null && expiration > 0 && expiration < 253402300799
          ? DateTime.fromMillisecondsSinceEpoch(expiration * 1000, isUtc: true)
          : null;
      return (
        subscription: subscription.copyWith(
          title:
              subscription.lastUpdated != null || name == null || name.isEmpty
              ? subscription.title
              : _cleanTitle(name),
          lastUpdated: DateTime.now().toUtc(),
          upload: info['upload'],
          download: info['download'],
          total: info['total'],
          expires: expires,
          error: '',
          supportUrl: _safeWebUrl(header('support-url')),
          webpageUrl: _safeWebUrl(header('profile-web-page-url')),
          announceText: (header('announce') ?? '').substring(
            0,
            (header('announce') ?? '').length.clamp(0, 4096),
          ),
        ),
        profiles: parsed,
      );
    } finally {
      client.close(force: true);
    }
  }

  String? _safeWebUrl(String? value) {
    if (value == null || value.length > 4096) {
      return null;
    }
    final uri = Uri.tryParse(value);
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? value
        : null;
  }

  void _replaceSubscriptionProfiles(String id, List<Profile> replacements) {
    final chosen = profiles.isEmpty ? null : profiles[selected].id;
    final previous = {
      for (final p in profiles.where((p) => p.subscriptionId == id))
        profileIdentity(p.uri): p,
    };
    final next = replacements.map((p) {
      final old = previous[profileIdentity(p.uri)];
      return old == null
          ? p
          : p.copyWith(
              id: old.id,
              name: old.customName ? old.name : p.name,
              customName: old.customName,
              favorite: old.favorite,
              latencyMs: old.latencyMs,
              lastChecked: old.lastChecked,
            );
    }).toList();
    final insertion = profiles.indexWhere((p) => p.subscriptionId == id);
    profiles.removeWhere((p) => p.subscriptionId == id);
    if (profiles.length + next.length > maxProfiles) {
      throw const FormatException('Лимит — 500 профилей.');
    }
    profiles.insertAll(
      insertion < 0 || insertion > profiles.length
          ? profiles.length
          : insertion,
      next,
    );
    final nextIndex = profiles.indexWhere((p) => p.id == chosen);
    selected = nextIndex < 0 ? 0 : nextIndex;
  }

  Future<void> updateSubscription(String id) async {
    if (updatingSubscriptions.contains(id)) {
      return;
    }
    final initial = subscriptions.where((s) => s.id == id).firstOrNull;
    if (initial == null) {
      return;
    }
    updatingSubscriptions.add(id);
    notifyListeners();
    try {
      final fetched = await _fetchSubscription(initial);
      await _mutate(() {
        final index = subscriptions.indexWhere((s) => s.id == id);
        if (index < 0) {
          return;
        }
        subscriptions[index] = fetched.subscription;
        _replaceSubscriptionProfiles(id, fetched.profiles);
      });
    } catch (error) {
      final text = error is FormatException
          ? error.message
          : 'Не удалось загрузить подписку. Сохранённые серверы оставлены.';
      await _mutate(() {
        final index = subscriptions.indexWhere((s) => s.id == id);
        if (index >= 0) {
          subscriptions[index] = subscriptions[index].copyWith(error: text);
        }
      });
      message = text;
      rethrow;
    } finally {
      updatingSubscriptions.remove(id);
      notifyListeners();
    }
  }

  Future<void> updateAllSubscriptions() async {
    var failures = 0;
    for (final id in subscriptions.map((s) => s.id).toList()) {
      try {
        await updateSubscription(id);
      } catch (_) {
        failures++;
      }
    }
    if (failures > 0) {
      message =
          'Не удалось обновить подписок: $failures. Сохранённые серверы оставлены.';
      notifyListeners();
    }
  }

  Future<void> _updateDueSubscriptions() async {
    if (_disposed) {
      return;
    }
    final now = DateTime.now();
    for (final sub in List<Subscription>.of(subscriptions)) {
      if (sub.autoUpdate &&
          (sub.lastUpdated == null ||
              now.difference(sub.lastUpdated!).inMinutes >=
                  sub.intervalMinutes)) {
        try {
          await updateSubscription(sub.id);
        } catch (_) {}
      }
    }
  }

  Future<void> configureSubscription(
    String id, {
    String? title,
    String? userAgent,
    bool? autoUpdate,
    int? intervalMinutes,
  }) async {
    if (userAgent != null &&
        (userAgent.length > 256 || userAgent.contains(RegExp(r'[\r\n]')))) {
      throw const FormatException(
        'User-Agent: не более 256 символов без переносов.',
      );
    }
    if (intervalMinutes != null &&
        (intervalMinutes < 15 || intervalMinutes > 10080)) {
      throw const FormatException(
        'Интервал обновления — от 15 минут до 7 дней.',
      );
    }
    await _mutate(() {
      final index = subscriptions.indexWhere((s) => s.id == id);
      if (index >= 0) {
        subscriptions[index] = subscriptions[index].copyWith(
          title: title == null ? null : _cleanTitle(title),
          userAgent: userAgent,
          autoUpdate: autoUpdate,
          intervalMinutes: intervalMinutes,
        );
      }
    });
  }

  Future<void> removeSubscription(String id) async => _mutate(() {
    subscriptions.removeWhere((s) => s.id == id);
    final chosen = profiles.isEmpty ? null : profiles[selected].id;
    profiles.removeWhere((p) => p.subscriptionId == id);
    final nextIndex = profiles.indexWhere((p) => p.id == chosen);
    selected = nextIndex < 0 ? 0 : nextIndex;
  });

  int _existingProfile(String id) {
    final index = profiles.indexWhere((profile) => profile.id == id);
    if (index < 0) {
      throw StateError('Профиль уже удалён или обновлён.');
    }
    return index;
  }

  Future<void> select(int index) async {
    RangeError.checkValidIndex(index, profiles);
    final id = profiles[index].id;
    await _mutate(() {
      selected = _existingProfile(id);
    });
  }

  Future<void> remove(int index) async {
    RangeError.checkValidIndex(index, profiles);
    final id = profiles[index].id;
    await _mutate(() {
      final chosen = profiles[selected].id;
      profiles.removeAt(_existingProfile(id));
      final nextIndex = profiles.indexWhere((p) => p.id == chosen);
      selected = nextIndex < 0 ? 0 : nextIndex;
    });
  }

  Future<void> toggleFavorite(int index) async {
    RangeError.checkValidIndex(index, profiles);
    final id = profiles[index].id;
    await _mutate(() {
      final current = _existingProfile(id);
      profiles[current] = profiles[current].copyWith(
        favorite: !profiles[current].favorite,
      );
    });
  }

  Future<void> rename(int index, String name) async {
    RangeError.checkValidIndex(index, profiles);
    final id = profiles[index].id;
    final clean = _cleanTitle(name);
    await _mutate(() {
      final current = _existingProfile(id);
      profiles[current] = profiles[current].copyWith(
        name: clean,
        customName: true,
      );
    });
  }

  Future<void> edit(int index, String uri, String name) async {
    RangeError.checkValidIndex(index, profiles);
    final old = profiles[index];
    final parsed = parseProfile(uri, subscriptionId: old.subscriptionId);
    final clean = _cleanTitle(name);
    await _mutate(() {
      final current = _existingProfile(old.id);
      profiles[current] = parsed.copyWith(
        id: old.id,
        name: clean,
        customName: true,
        favorite: profiles[current].favorite,
      );
    });
  }

  String exportProfile(int index) {
    RangeError.checkValidIndex(index, profiles);
    final profile = profiles[index];
    if (Uri.parse(profile.uri).scheme == 'vmess') {
      final data = jsonDecode(
        utf8.decode(base64.decode(base64.normalize(profile.uri.substring(8)))),
      ) as Map<String, dynamic>;
      data['ps'] = profile.name;
      return 'vmess://${base64.encode(utf8.encode(jsonEncode(data)))}';
    }
    return Uri.parse(profile.uri).replace(fragment: profile.name).toString();
  }

  Future<void> saveExclusions(String value) async {
    if (value.length > 16384) {
      throw const FormatException('Слишком много исключений.');
    }
    await _mutate(() {
      exclusions = value;
    });
  }

  Future<void> pingProfiles([List<int>? indices]) async {
    if (pinging) {
      return;
    }
    final ids = (indices ?? List<int>.generate(profiles.length, (i) => i))
        .where((i) => i >= 0 && i < profiles.length)
        .map((i) => profiles[i].id)
        .toList();
    pinging = true;
    notifyListeners();
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < ids.length && !_disposed) {
        final id = ids[cursor++];
        final profile = profiles.where((p) => p.id == id).firstOrNull;
        if (profile == null) {
          continue;
        }
        int? ms;
        if (['hy2', 'hysteria2'].contains(Uri.parse(profile.uri).scheme)) {
          final index = profiles.indexWhere((p) => p.id == id);
          if (index >= 0) {
            profiles[index] = profiles[index].copyWith(clearLatency: true);
          }
          continue;
        }
        try {
          final result = await _request('probe', {'uri': profile.uri});
          if (result['ok'] == true && result['latencyMs'] is int) {
            ms = result['latencyMs'] as int;
          }
        } catch (_) {
          final watch = Stopwatch()..start();
          try {
            final socket = await Socket.connect(
              profile.server,
              profile.port,
              timeout: const Duration(seconds: 3),
            );
            ms = watch.elapsedMilliseconds;
            socket.destroy();
          } catch (_) {
            ms = null;
          }
        }
        final index = profiles.indexWhere((p) => p.id == id);
        if (index >= 0) {
          profiles[index] = profiles[index].copyWith(
            latencyMs: ms,
            clearLatency: ms == null,
            lastChecked: DateTime.now().toUtc(),
          );
          notifyListeners();
        }
      }
    }

    try {
      await Future.wait(List.generate(min(4, ids.length), (_) => worker()));
      await _mutate(() {});
    } finally {
      pinging = false;
      notifyListeners();
    }
  }

  Future<void> saveSettings(Map<String, dynamic> value) async {
    final validated = _validateSettings({...settings, ...value});
    await _mutate(() {
      settings = validated;
    });
  }

  String exportBackup() =>
      const JsonEncoder.withIndent('  ')
          .convert({'format': 'velum-backup', ..._document()});
  Future<void> restoreBackup(String source) async {
    if (utf8.encode(source).length > 4 * maxImportBytes) {
      throw const FormatException('Резервная копия больше 4 МБ.');
    }
    final decoded = jsonDecode(source);
    if (decoded is! Map || decoded['format'] != 'velum-backup') {
      throw const FormatException('Это не резервная копия Velum.');
    }
    final document = _validatedDocument(decoded);
    await _mutate(() {
      _applyDocument(document);
    }, allowRecovery: true);
    _storageError = '';
  }

  Future<void> _prepareDirectory() async {
    await directory.create(recursive: true);
    if (Platform.isLinux || Platform.isMacOS) {
      final result = await Process.run('chmod', ['700', directory.path]);
      if (result.exitCode != 0) {
        throw const FileSystemException(
          'Не удалось ограничить доступ к каталогу Velum.',
        );
      }
    }
  }

  Future<void> _privateWrite(File target, List<int> bytes) async {
    final handle = await target.open(mode: FileMode.write);
    try {
      if (Platform.isLinux || Platform.isMacOS) {
        final result = await Process.run('chmod', ['600', target.path]);
        if (result.exitCode != 0) {
          throw const FileSystemException('Не удалось защитить файл Velum.');
        }
      }
      await handle.writeFrom(bytes);
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  Map<String, dynamic> _document() => {
    'version': 2,
    'profiles': profiles.map((p) => p.toJson()).toList(),
    'subscriptions': subscriptions.map((s) => s.toJson()).toList(),
    'selected': selected,
    'exclusions': exclusions,
    'settings': settings,
  };
  Future<void> _save() async {
    await _prepareDirectory();
    final tmp = File('${_file.path}.${Random.secure().nextInt(1 << 32)}.tmp');
    try {
      await _privateWrite(tmp, utf8.encode(jsonEncode(_document())));
      await tmp.rename(_file.path);
    } finally {
      if (await tmp.exists()) {
        await tmp.delete();
      }
    }
  }

  Future<void> _mutate(void Function() change, {bool allowRecovery = false}) {
    final result = _writes.then((_) async {
      if (_storageError.isNotEmpty && !allowRecovery) {
        throw const FormatException(
          'Исходный файл профилей не загружен. Восстановите проверенную резервную копию перед изменениями.',
        );
      }
      final previous = jsonDecode(jsonEncode(_document()));
      try {
        change();
        await _save();
      } catch (_) {
        _applyDocument(_validatedDocument(previous));
        rethrow;
      }
      notifyListeners();
    });
    _writes = result.catchError((Object _) {});
    return result;
  }

  String _cleanTitle(String value) {
    var clean = value.trim();
    if (clean.contains('%')) {
      try {
        clean = Uri.decodeComponent(clean).trim();
      } catch (_) {}
    }
    if (clean.isEmpty ||
        clean.length > 200 ||
        clean.contains(RegExp(r'[\r\n\x00]'))) {
      throw const FormatException('Имя: от 1 до 200 символов без переносов.');
    }
    return clean;
  }

  Map<String, dynamic> _validatedDocument(dynamic raw) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('Некорректный файл профилей.');
    }
    final version = raw['version'];
    if (version != null && version != 1 && version != 2) {
      throw const FormatException('Версия файла профилей не поддерживается.');
    }
    final rows = raw['profiles'];
    if (rows is! List || rows.length > maxProfiles) {
      throw const FormatException('Некорректный список серверов.');
    }
    final subRows = raw['subscriptions'] ?? [];
    if (subRows is! List || subRows.length > 100) {
      throw const FormatException('Некорректный список подписок.');
    }
    final subs = <Subscription>[];
    final subIds = <String>{};
    for (final row in subRows) {
      if (row is! Map<String, dynamic> ||
          row['id'] is! String ||
          row['url'] is! String ||
          row['title'] is! String) {
        throw const FormatException('Некорректная подписка.');
      }
      final uri = Uri.tryParse(row['url'] as String);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          !subIds.add(row['id'] as String)) {
        throw const FormatException(
          'Некорректный URL или идентификатор подписки.',
        );
      }
      final minutes = row['intervalMinutes'] ?? 360;
      final ua = row['userAgent'] ?? 'Velum/0.2';
      if (minutes is! int ||
          minutes < 15 ||
          minutes > 10080 ||
          ua is! String ||
          ua.length > 256 ||
          ua.contains(RegExp(r'[\r\n]')) ||
          (row['autoUpdate'] != null && row['autoUpdate'] is! bool)) {
        throw const FormatException('Некорректные параметры подписки.');
      }
      int? number(String key) {
        final v = row[key];
        if (v != null && (v is! int || v < 0)) {
          throw const FormatException('Некорректная статистика подписки.');
        }
        return v as int?;
      }

      DateTime? date(String key) {
        final v = row[key];
        if (v == null) {
          return null;
        }
        if (v is! String || DateTime.tryParse(v) == null) {
          throw const FormatException('Некорректная дата.');
        }
        return DateTime.parse(v);
      }

      subs.add(
        Subscription(
          id: row['id'] as String,
          url: row['url'] as String,
          title: _cleanTitle(row['title'] as String),
          userAgent: ua,
          autoUpdate: row['autoUpdate'] as bool? ?? false,
          intervalMinutes: minutes,
          lastUpdated: date('lastUpdated'),
          upload: number('upload'),
          download: number('download'),
          total: number('total'),
          expires: date('expires'),
          announceText: row['announceText'] is String
              ? (row['announceText'] as String).substring(
                  0,
                  (row['announceText'] as String).length.clamp(0, 4096),
                )
              : null,
          error: row['error'] is String ? row['error'] as String : '',
          supportUrl: row['supportUrl'] is String
              ? _safeWebUrl(row['supportUrl'] as String)
              : null,
          webpageUrl: row['webpageUrl'] is String
              ? _safeWebUrl(row['webpageUrl'] as String)
              : null,
        ),
      );
    }
    final parsed = <Profile>[];
    final ids = <String>{};
    for (final row in rows) {
      if (row is! Map<String, dynamic> || row['uri'] is! String) {
        throw const FormatException('Некорректный сервер в файле.');
      }
      final subId = row['subscriptionId'];
      if (subId != null && (subId is! String || !subIds.contains(subId))) {
        throw const FormatException(
          'Сервер ссылается на неизвестную подписку.',
        );
      }
      var profile = parseProfile(
        row['uri'] as String,
        subscriptionId: subId as String?,
      );
      var id = row['id'] is String && (row['id'] as String).isNotEmpty
          ? row['id'] as String
          : profile.id;
      if (id.length > 100) {
        throw const FormatException('Некорректный идентификатор сервера.');
      }
      if (!ids.add(id)) {
        if (version == 2) {
          throw const FormatException('Повторный идентификатор сервера.');
        }
        id = '$id-legacy-${parsed.length}';
        ids.add(id);
      }
      final name = row['name'];
      if (name != null && name is! String) {
        throw const FormatException('Некорректное имя сервера.');
      }
      final favorite = row['favorite'];
      final latency = row['latencyMs'];
      final checked = row['lastChecked'];
      if ((favorite != null && favorite is! bool) ||
          (latency != null && (latency is! int || latency < 0)) ||
          (checked != null &&
              (checked is! String || DateTime.tryParse(checked) == null)) ||
          (row['customName'] != null && row['customName'] is! bool)) {
        throw const FormatException('Некорректные свойства сервера.');
      }
      profile = profile.copyWith(
        id: id,
        name: name == null ? profile.name : _cleanTitle(name as String),
        favorite: favorite as bool? ?? false,
        latencyMs: latency as int?,
        lastChecked: checked == null ? null : DateTime.parse(checked as String),
        customName: row['customName'] as bool? ?? false,
      );
      parsed.add(profile);
    }
    var selectedIndex = raw['selected'] ?? 0;
    if (version != 2 &&
        selectedIndex is int &&
        (selectedIndex < 0 || selectedIndex >= max(1, parsed.length))) {
      selectedIndex = 0;
    }
    final exclusionsValue = raw['exclusions'] ?? '';
    if (selectedIndex is! int ||
        selectedIndex < 0 ||
        selectedIndex >= max(1, parsed.length) ||
        exclusionsValue is! String ||
        exclusionsValue.length > 16384) {
      throw const FormatException('Некорректный выбор сервера или исключения.');
    }
    final config = raw['settings'] ?? <String, dynamic>{};
    if (config is! Map<String, dynamic>) {
      throw const FormatException('Некорректные настройки.');
    }
    return {
      'profiles': parsed,
      'subscriptions': subs,
      'selected': selectedIndex,
      'exclusions': exclusionsValue,
      'settings': _validateSettings({...defaultSettings, ...config}),
      'migrated': version != 2,
    };
  }

  void _applyDocument(Map<String, dynamic> document) {
    profiles
      ..clear()
      ..addAll(document['profiles'] as List<Profile>);
    subscriptions
      ..clear()
      ..addAll(document['subscriptions'] as List<Subscription>);
    selected = document['selected'] as int;
    exclusions = document['exclusions'] as String;
    settings = document['settings'] as Map<String, dynamic>;
  }

  Map<String, dynamic> _validateSettings(Map<String, dynamic> value) {
    if (value.keys.any((k) => !defaultSettings.containsKey(k))) {
      throw const FormatException('Неизвестный параметр настроек.');
    }
    for (final key in [
      'ipv6',
      'fragment',
      'reconnect',
      'autoConnect',
      'autostart',
      'minimizeToTray',
      'systemProxy',
    ]) {
      if (value[key] is! bool) {
        throw const FormatException('Некорректный переключатель настройки.');
      }
    }
    if (!['system', 'light', 'dark'].contains(value['theme']) ||
        !['proxy', 'tun'].contains(value['mode']) ||
        !['global', 'rules'].contains(value['routeMode'])) {
      throw const FormatException('Некорректный режим настроек.');
    }
    if (![
          'velum-acid-violet',
          'hyper-amethyst',
          'cyber-orchid',
          'acid-matrix',
          'incy-emerald',
        ].contains(value['themeId']) ||
        ![
          'topography',
          'hex-grid',
          'cyber-circuit',
          'dot-constellation',
          'aurora-clean',
          'rings',
          'diamonds',
          'triangles',
          'crosses',
          'orbital',
          'silk',
          'prism',
          'starmap',
          'bloom',
          'interference',
        ].contains(value['patternId']) ||
        value['patternIntensity'] is! int ||
        (value['patternIntensity'] as int) < 0 ||
        (value['patternIntensity'] as int) > 100 ||
        !['compact', 'wide'].contains(value['desktopLayout']) ||
        !['ru', 'en'].contains(value['language'])) {
      throw const FormatException('Некорректные параметры оформления.');
    }
    final mtu = value['mtu'];
    final port = value['proxyPort'];
    if (mtu is! int ||
        mtu < 1280 ||
        mtu > 9000 ||
        port is! int ||
        port < 1024 ||
        port > 65535) {
      throw const FormatException('MTU: 1280–9000; порт: 1024–65535.');
    }
    for (final key in ['dns', 'directDns', 'interface']) {
      if (value[key] is! String ||
          (value[key] as String).length > 2048 ||
          (value[key] as String).contains(RegExp(r'[\r\n\x00]'))) {
        throw const FormatException('Некорректные сетевые настройки.');
      }
    }
    final rules = value['rules'];
    if (rules is! List || rules.length > 100) {
      throw const FormatException('Допустимо не более 100 правил.');
    }
    for (final rule in rules) {
      if (rule is! Map ||
          !['direct', 'proxy', 'block'].contains(rule['action']) ||
          !['domain', 'cidr', 'process'].contains(rule['type']) ||
          rule['value'] is! String ||
          (rule['value'] as String).trim().isEmpty ||
          (rule['value'] as String).length > 1024 ||
          rule.keys.any((key) => !['action', 'type', 'value'].contains(key))) {
        throw const FormatException('Некорректное правило маршрутизации.');
      }
    }
    return jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _request(
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (_token.isEmpty) {
      _token = (await _tokenFile.readAsString()).trim();
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client
          .openUrl(body == null ? 'GET' : 'POST', apiBase.resolve(path))
          .timeout(const Duration(seconds: 3));
      request.headers.set('Authorization', 'Bearer $_token');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 25),
      );
      if (response.statusCode == 401) {
        throw const FormatException('Токен службы не совпадает.');
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 4))) {
        bytes.addAll(chunk);
        if (bytes.length > maxImportBytes) {
          throw const FormatException('Ответ службы слишком большой.');
        }
      }
      final data = jsonDecode(utf8.decode(bytes));
      if (data is! Map<String, dynamic>) {
        throw const FormatException('Некорректный ответ службы.');
      }
      if (response.statusCode >= 400) {
        if (data['state'] is String) {
          _apply(data);
        }
        throw FormatException(
          data['error'] is String
              ? data['error'] as String
              : 'Ошибка службы ${response.statusCode}.',
        );
      }
      return data;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> refresh() async {
    if (_disposed || busy || _polling) {
      return;
    }
    _polling = true;
    try {
      _apply(await _request('status'));
      if (proxyManager != null && proxyManager!.isSupported) {
        final proxyPort = settings['proxyPort'] as int? ?? 2080;
        final newStatus =
            await proxyManager!.getStatus('127.0.0.1', proxyPort);
        if (newStatus != systemProxyStatus) {
          systemProxyStatus = newStatus;
          notifyListeners();
        }
      }
    } catch (_) {
      state = 'offline';
    } finally {
      _polling = false;
      notifyListeners();
    }
  }

  void _apply(Map<String, dynamic> data) {
    final previousState = state;
    status = data;
    state = data['state'] as String? ?? 'offline';
    mode = data['mode'] as String? ?? '';
    message = _storageError.isEmpty
        ? data['error'] as String? ?? ''
        : _storageError;

    _handleStateTransition(previousState, state);
  }

  Future<void> _handleStateTransition(String from, String to) async {
    if (from == to || proxyManager == null || !proxyManager!.isSupported) {
      return;
    }
    final proxyPort = settings['proxyPort'] as int? ?? 2080;
    if (to == 'running') {
      if (settings['systemProxy'] == true && mode != 'tun') {
        try {
          await proxyManager!.enable(host: '127.0.0.1', port: proxyPort);
        } catch (error) {
          message = 'Не удалось включить системный прокси: $error';
        }
        await refreshSystemProxyStatus();
      }
    } else if (from == 'running') {
      if (settings['systemProxy'] == true) {
        try {
          await proxyManager!.restore(host: '127.0.0.1', port: proxyPort);
        } catch (error) {
          message = 'Не удалось восстановить системный прокси: $error';
        }
        await refreshSystemProxyStatus();
      }
    }
  }

  Future<void> refreshSystemProxyStatus() async {
    if (proxyManager == null) return;
    if (!proxyManager!.isSupported) {
      systemProxyStatus = SystemProxyStatus.unsupported;
      notifyListeners();
      return;
    }
    final proxyPort = settings['proxyPort'] as int? ?? 2080;
    systemProxyStatus = await proxyManager!.getStatus('127.0.0.1', proxyPort);
    notifyListeners();
  }

  Future<void> setSystemProxyEnabled(bool enabled) async {
    await saveSettings({'systemProxy': enabled});
    if (proxyManager == null || !proxyManager!.isSupported) {
      await refreshSystemProxyStatus();
      return;
    }
    final proxyPort = settings['proxyPort'] as int? ?? 2080;
    if (enabled) {
      if (state == 'running' && mode != 'tun') {
        try {
          await proxyManager!.enable(host: '127.0.0.1', port: proxyPort);
        } catch (e) {
          message = 'Не удалось включить системный прокси: $e';
        }
      }
    } else {
      try {
        await proxyManager!.restore(host: '127.0.0.1', port: proxyPort);
      } catch (e) {
        message = 'Не удалось восстановить системный прокси: $e';
      }
    }
    await refreshSystemProxyStatus();
  }

  /// Probes whether a local TCP listener is actively accepting connections on the proxy port.
  Future<bool> isProxyInboundListening([int? port]) async {
    final targetPort = port ?? (settings['proxyPort'] as int? ?? 2080);
    try {
      final socket = await Socket.connect('127.0.0.1', targetPort,
          timeout: const Duration(milliseconds: 300));
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> refreshLogs() async {
    final result = await _request('logs');
    final entries = result['entries'];
    if (entries is List) {
      logs
        ..clear()
        ..addAll(entries.whereType<Map<String, dynamic>>().take(500));
      notifyListeners();
    }
  }

  void clearLocalLogs() {
    logs.clear();
    notifyListeners();
  }

  Future<void> checkConnection() async => _runCommand(() async {
    _apply(await _request('check', {}));
  });
  Future<void> reconnect() async {
    if (profiles.isEmpty) {
      return;
    }
    await _runCommand(() async {
      _apply(await _request('connect', _connectBody()));
    });
  }

  Map<String, dynamic> _connectBody() => {
    'uri': profiles[selected].uri,
    'exclusions': exclusions
        .split(RegExp(r'[,\n]'))
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty)
        .toList(),
    'settings': {for (final key in _networkKeys) key: settings[key]},
  };
  Future<void> toggle() async {
    if (state == 'running') {
      await _runCommand(() async {
        _apply(await _request('disconnect', {}));
      });
    } else {
      await reconnect();
    }
  }

  /// Installs and starts the privileged Windows service after a UAC prompt.
  /// The GUI itself never asks for permanent administrator rights.
  Future<void> installWindowsService() async {
    if (!Platform.isWindows) {
      throw const FormatException(
        'Системная служба доступна только в Windows.',
      );
    }
    final executable = File(
      '${File(Platform.resolvedExecutable).parent.path}\\bin\\velumd.exe',
    );
    if (!await executable.exists()) {
      throw const FormatException(
        'Не найден bin\\velumd.exe рядом с приложением Velum.',
      );
    }
    final script =
        "\$ErrorActionPreference = 'Stop'\n"
        "\$arguments = '--service install --tun'\n"
        "\$process = Start-Process -FilePath '${executable.path.replaceAll("'", "''")}' "
        "-ArgumentList \$arguments -Verb RunAs -PassThru -Wait -WindowStyle Hidden\n"
        "exit \$process.ExitCode\n";
    final encoded = base64Encode(_utf16le(script));
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-EncodedCommand',
      encoded,
    ]);
    if (result.exitCode != 0) {
      final detail = '${result.stderr}'.trim();
      throw FormatException(
        detail.isEmpty
            ? 'Установка службы отменена или завершилась с ошибкой.'
            : 'Установка службы не удалась: $detail',
      );
    }
    _token = '';
    await refresh();
  }

  Future<void> _ensureClientToken() async {
    final file = _tokenFile;
    if (await file.exists()) {
      try {
        final content = (await file.readAsString()).trim();
        if (content.length >= 32) {
          _token = content;
          return;
        }
      } catch (_) {}
    }
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final tokenHex =
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    try {
      await _prepareDirectory();
      await _privateWrite(file, utf8.encode('$tokenHex\n'));
      _token = tokenHex;
    } catch (_) {}
  }

  Future<LinuxServiceState> checkLinuxServiceState() async {
    if (!Platform.isLinux) return LinuxServiceState.notInstalled;
    try {
      if (!await Directory('/run/systemd/system').exists()) {
        return LinuxServiceState.checkError;
      }
      final unitFile = File('/etc/systemd/system/velum.service');
      final hasUnit = await unitFile.exists();
      if (!hasUnit) {
        final listResult = await Process.run('systemctl', [
          'list-unit-files',
          'velum.service',
        ]);
        if (listResult.exitCode != 0 ||
            !listResult.stdout.toString().contains('velum.service')) {
          return LinuxServiceState.notInstalled;
        }
      }

      final activeResult = await Process.run('systemctl', [
        'is-active',
        'velum.service',
      ]);
      final activeText = activeResult.stdout.toString().trim();
      if (activeText == 'active') {
        if (state != 'offline' && tunAllowed) {
          return LinuxServiceState.running;
        } else {
          return LinuxServiceState.unavailable;
        }
      } else {
        return LinuxServiceState.installedStopped;
      }
    } catch (_) {
      return LinuxServiceState.checkError;
    }
  }

  Future<ProcessResult> _runPrivilegedLinuxCommand(List<String> command) async {
    final checkPkexec = await Process.run('which', ['pkexec']);
    if (checkPkexec.exitCode != 0) {
      throw const FormatException(
        'Утилита pkexec не найдена в системе. Установите пакет polkit.',
      );
    }
    try {
      return await Process.run('pkexec', command);
    } on ProcessException catch (e) {
      throw FormatException('Ошибка запуска pkexec: ${e.message}');
    }
  }

  Future<void> startLinuxService() async {
    if (!Platform.isLinux) {
      throw const FormatException('Действие доступно только на Linux.');
    }
    if (!await Directory('/run/systemd/system').exists()) {
      throw const FormatException(
        'В системе не обнаружен активный systemd. Служба Velum требует systemd.',
      );
    }

    final controlScript = File('/usr/local/lib/velum/velum-service-control');
    List<String> command;
    if (await controlScript.exists()) {
      command = [controlScript.path, 'start'];
    } else {
      command = ['systemctl', 'start', 'velum.service'];
    }

    final result = await _runPrivilegedLinuxCommand(command);
    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      if (result.exitCode == 126 ||
          stderr.contains('dismissed') ||
          stderr.contains('canceled') ||
          stderr.contains('cancelled')) {
        throw const FormatException('Авторизация отменена пользователем.');
      }
      if (stderr.contains('No authentication agent found')) {
        throw const FormatException(
          'В графической сессии не найден Polkit Authentication Agent. '
          'Запустите службу вручную в терминале: sudo systemctl start velum.service',
        );
      }
      throw FormatException(
        stderr.isEmpty
            ? 'Не удалось запустить службу (код ${result.exitCode}).'
            : 'Ошибка запуска службы: $stderr',
      );
    }

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      await refresh();
      if (state != 'offline' && tunAllowed) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    throw const FormatException(
      'Служба запущена, но API не ответило вовремя. Проверьте: journalctl -u velum.service',
    );
  }

  Future<void> stopLinuxService() async {
    if (!Platform.isLinux) {
      throw const FormatException('Действие доступно только на Linux.');
    }
    final controlScript = File('/usr/local/lib/velum/velum-service-control');
    List<String> command;
    if (await controlScript.exists()) {
      command = [controlScript.path, 'stop'];
    } else {
      command = ['systemctl', 'stop', 'velum.service'];
    }

    final result = await _runPrivilegedLinuxCommand(command);
    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      if (result.exitCode == 126 || stderr.contains('dismissed')) {
        throw const FormatException('Авторизация отменена пользователем.');
      }
      throw FormatException('Ошибка остановки службы: $stderr');
    }

    await refresh();
  }

  Future<void> uninstallLinuxService() async {
    if (!Platform.isLinux) {
      throw const FormatException('Действие доступно только на Linux.');
    }
    final controlScript = File('/usr/local/lib/velum/velum-service-control');
    final uninstallScript = File('/usr/local/lib/velum/uninstall-service.sh');
    List<String> command;
    if (await controlScript.exists()) {
      command = [controlScript.path, 'uninstall'];
    } else if (await uninstallScript.exists()) {
      command = [uninstallScript.path];
    } else {
      command = ['systemctl', 'disable', '--now', 'velum.service'];
    }

    final result = await _runPrivilegedLinuxCommand(command);
    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      if (result.exitCode == 126 || stderr.contains('dismissed')) {
        throw const FormatException('Авторизация отменена пользователем.');
      }
      throw FormatException('Ошибка удаления службы: $stderr');
    }

    await refresh();
  }

  Future<void> installLinuxService() async {
    if (!Platform.isLinux) {
      throw const FormatException('Действие доступно только на Linux.');
    }
    if (!await Directory('/run/systemd/system').exists()) {
      throw const FormatException(
        'В системе не обнаружен активный systemd. Служба Velum требует systemd.',
      );
    }
    await _ensureClientToken();

    final trustedInstaller = File('/usr/local/lib/velum/install-service.sh');
    if (await trustedInstaller.exists()) {
      final user = Platform.environment['USER'] ?? '';
      final result = await _runPrivilegedLinuxCommand([
        trustedInstaller.path,
        if (user.isNotEmpty) ...['--user', user],
      ]);
      if (result.exitCode != 0) {
        final stderr = result.stderr.toString().trim();
        if (result.exitCode == 126 || stderr.contains('dismissed')) {
          throw const FormatException('Авторизация отменена пользователем.');
        }
        throw FormatException('Ошибка установки службы: $stderr');
      }
      await refresh();
      return;
    }

    throw const FormatException('trusted-installer-required');
  }

  List<int> _utf16le(String value) {
    final bytes = <int>[];
    for (final unit in value.codeUnits) {
      bytes
        ..add(unit & 0xff)
        ..add((unit >> 8) & 0xff);
    }
    return bytes;
  }

  Future<void> _runCommand(Future<void> Function() action) async {
    if (busy) {
      return;
    }
    busy = true;
    message = '';
    notifyListeners();
    try {
      await action();
    } on FormatException catch (error) {
      message = error.message;
    } catch (_) {
      state = 'offline';
      message = 'Служба недоступна. Проверьте её запуск и токен.';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _subscriptionTimer?.cancel();
    if (state == 'running' && settings['systemProxy'] == true) {
      final proxyPort = settings['proxyPort'] as int? ?? 2080;
      proxyManager?.restore(host: '127.0.0.1', port: proxyPort).ignore();
    }
    super.dispose();
  }
}
