import 'dart:convert';

import 'models.dart';

const maxImportBytes = 1024 * 1024;
const maxProfiles = 500;

String unwrapImport(String input) {
  var value = input.trim();
  for (var depth = 0; depth < 4; depth++) {
    if (value.length > maxImportBytes) {
      throw const FormatException('Данные больше 1 МБ.');
    }
    final match = RegExp(
      r'^(?:velum|incy|happ)://(?:add|import)/(.*)$',
      dotAll: true,
      caseSensitive: false,
    ).firstMatch(value);
    if (match == null) {
      break;
    }
    value = match.group(1)!;
    if (!value.contains('://')) {
      try {
        value = Uri.decodeComponent(value);
      } on FormatException {
        throw const FormatException('Неверная кодировка deep link.');
      }
    }
  }
  if (RegExp(
    r'^(?:velum|incy|happ)://',
    caseSensitive: false,
  ).hasMatch(value)) {
    throw const FormatException(
      'Эта deep link-команда не является импортом. Используйте add/import с обычной ссылкой.',
    );
  }
  return value;
}

Profile parseProfile(String input, {String? subscriptionId}) {
  var raw = input.trim();
  if (raw.length > 16384) {
    throw const FormatException('Ссылка сервера слишком длинная.');
  }
  var uri = Uri.tryParse(raw);
  if (uri == null) {
    throw const FormatException('Некорректная ссылка сервера.');
  }
  if (uri.scheme == 'vmess') {
    try {
      final data = jsonDecode(
        utf8.decode(base64.decode(base64.normalize(raw.substring(8)))),
      ) as Map<String, dynamic>;
      final host = data['add'];
      final port = int.tryParse('${data['port']}');
      if (host is! String ||
          host.isEmpty ||
          data['id'] is! String ||
          port == null ||
          port < 1 ||
          port > 65535) {
        throw const FormatException();
      }
      final name = data['ps'] is String && (data['ps'] as String).isNotEmpty
          ? data['ps'] as String
          : host;
      return Profile(
        raw,
        name,
        id: stableId('${subscriptionId ?? ''}|${profileIdentity(raw)}'),
        subscriptionId: subscriptionId,
      );
    } catch (_) {
      throw const FormatException('Некорректная VMess Base64 JSON-ссылка.');
    }
  }
  if (uri.scheme == 'ss' && !uri.hasPort && !raw.contains('@')) {
    try {
      final fragmentIndex = raw.indexOf('#');
      final encoded = raw.substring(
        5,
        fragmentIndex < 0 ? raw.length : fragmentIndex,
      );
      final decoded = utf8.decode(base64.decode(base64.normalize(encoded)));
      raw =
          'ss://$decoded${fragmentIndex < 0 ? '' : raw.substring(fragmentIndex)}';
      uri = Uri.parse(raw);
    } catch (_) {
      throw const FormatException('Некорректная Shadowsocks-ссылка.');
    }
  }
  if (![
        'vless',
        'trojan',
        'ss',
        'hy2',
        'hysteria2',
        'socks',
        'socks5',
        'http',
        'https',
      ].contains(uri.scheme) ||
      uri.host.isEmpty ||
      !uri.hasPort ||
      uri.port < 1 ||
      uri.port > 65535) {
    throw const FormatException(
      'Поддерживаются VLESS, VMess, Trojan, Shadowsocks, Hysteria 2, SOCKS и HTTP с адресом и портом.',
    );
  }
  if (!['socks', 'socks5', 'http', 'https'].contains(uri.scheme) &&
      uri.userInfo.isEmpty) {
    throw const FormatException('В ссылке отсутствуют учётные данные.');
  }
  final name = uri.fragment.isEmpty ? uri.host : uri.fragment;
  return Profile(
    raw,
    name,
    id: stableId('${subscriptionId ?? ''}|${profileIdentity(raw)}'),
    subscriptionId: subscriptionId,
  );
}

List<Profile> parseSubscriptionBody(String input, {String? subscriptionId}) {
  if (utf8.encode(input).length > maxImportBytes) {
    throw const FormatException('Подписка больше 1 МБ.');
  }
  var payload = unwrapImport(input);
  if (!payload.contains('://')) {
    try {
      payload = utf8.decode(
        base64.decode(base64.normalize(payload.replaceAll(RegExp(r'\s+'), ''))),
      );
    } catch (_) {
      throw const FormatException(
        'Ожидается список ссылок или Base64-подписка.',
      );
    }
  }
  final lines = const LineSplitter()
      .convert(payload)
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty && !s.startsWith('#'))
      .toList();
  if (lines.isEmpty || lines.length > maxProfiles) {
    throw const FormatException('Допустимо от 1 до 500 профилей.');
  }
  final result = <Profile>[];
  final identities = <String>{};
  for (final line in lines) {
    final profile = parseProfile(line, subscriptionId: subscriptionId);
    if (identities.add(profileIdentity(profile.uri))) {
      result.add(profile);
    }
  }
  return result;
}
