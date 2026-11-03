import 'dart:convert';

String profileIdentity(String value) {
  final uri = Uri.tryParse(value);
  return uri == null ? value : uri.replace(fragment: '').toString();
}

String stableId(String value) {
  var hash = BigInt.parse('cbf29ce484222325', radix: 16);
  final prime = BigInt.parse('100000001b3', radix: 16);
  final mask = (BigInt.one << 64) - BigInt.one;
  for (final byte in utf8.encode(value)) {
    hash = ((hash ^ BigInt.from(byte)) * prime) & mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

class Profile {
  const Profile(
    this.uri,
    this.name, {
    this.id = '',
    this.subscriptionId,
    this.favorite = false,
    this.latencyMs,
    this.lastChecked,
    this.customName = false,
  });
  final String uri;
  final String name;
  final String id;
  final String? subscriptionId;
  final bool favorite;
  final int? latencyMs;
  final DateTime? lastChecked;
  final bool customName;
  bool get tcpProbeSupported =>
      !['hy2', 'hysteria2'].contains(Uri.parse(uri).scheme);
  String get protocol {
    final scheme = Uri.parse(uri).scheme;
    return (scheme == 'hy2' ? 'hysteria2' : scheme).toUpperCase();
  }

  String get server {
    final parsed = Uri.parse(uri);
    if (parsed.scheme == 'vmess') {
      try {
        final value = jsonDecode(
          utf8.decode(base64.decode(base64.normalize(uri.substring(8)))),
        ) as Map<String, dynamic>;
        return value['add'] as String? ?? '';
      } catch (_) {
        return '';
      }
    }
    return parsed.host;
  }

  int get port {
    final parsed = Uri.parse(uri);
    if (parsed.scheme == 'vmess') {
      try {
        final value = jsonDecode(
          utf8.decode(base64.decode(base64.normalize(uri.substring(8)))),
        ) as Map<String, dynamic>;
        return int.tryParse('${value['port']}') ?? 0;
      } catch (_) {
        return 0;
      }
    }
    return parsed.hasPort ? parsed.port : 0;
  }

  Profile copyWith({
    String? uri,
    String? name,
    String? id,
    String? subscriptionId,
    bool? favorite,
    int? latencyMs,
    bool clearLatency = false,
    DateTime? lastChecked,
    bool? customName,
  }) => Profile(
    uri ?? this.uri,
    name ?? this.name,
    id: id ?? this.id,
    subscriptionId: subscriptionId ?? this.subscriptionId,
    favorite: favorite ?? this.favorite,
    latencyMs: clearLatency ? null : latencyMs ?? this.latencyMs,
    lastChecked: lastChecked ?? this.lastChecked,
    customName: customName ?? this.customName,
  );
  Map<String, dynamic> toJson() => {
    'uri': uri,
    'name': name,
    'id': id,
    'subscriptionId': subscriptionId,
    'favorite': favorite,
    'latencyMs': latencyMs,
    'lastChecked': lastChecked?.toIso8601String(),
    'customName': customName,
  };
}

class Subscription {
  const Subscription({
    required this.id,
    required this.url,
    required this.title,
    this.userAgent = 'Velum/0.2',
    this.autoUpdate = false,
    this.intervalMinutes = 360,
    this.lastUpdated,
    this.upload,
    this.download,
    this.total,
    this.expires,
    this.error = '',
    this.supportUrl,
    this.webpageUrl,
  });
  final String id;
  final String url;
  final String title;
  final String userAgent;
  final bool autoUpdate;
  final int intervalMinutes;
  final DateTime? lastUpdated;
  final int? upload;
  final int? download;
  final int? total;
  final DateTime? expires;
  final String error;
  final String? supportUrl;
  final String? webpageUrl;
  Subscription copyWith({
    String? title,
    String? userAgent,
    bool? autoUpdate,
    int? intervalMinutes,
    DateTime? lastUpdated,
    int? upload,
    int? download,
    int? total,
    DateTime? expires,
    String? error,
    String? supportUrl,
    String? webpageUrl,
  }) => Subscription(
    id: id,
    url: url,
    title: title ?? this.title,
    userAgent: userAgent ?? this.userAgent,
    autoUpdate: autoUpdate ?? this.autoUpdate,
    intervalMinutes: intervalMinutes ?? this.intervalMinutes,
    lastUpdated: lastUpdated ?? this.lastUpdated,
    upload: upload ?? this.upload,
    download: download ?? this.download,
    total: total ?? this.total,
    expires: expires ?? this.expires,
    error: error ?? this.error,
    supportUrl: supportUrl ?? this.supportUrl,
    webpageUrl: webpageUrl ?? this.webpageUrl,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'title': title,
    'userAgent': userAgent,
    'autoUpdate': autoUpdate,
    'intervalMinutes': intervalMinutes,
    'lastUpdated': lastUpdated?.toIso8601String(),
    'upload': upload,
    'download': download,
    'total': total,
    'expires': expires?.toIso8601String(),
    'error': error,
    'supportUrl': supportUrl,
    'webpageUrl': webpageUrl,
  };
}
