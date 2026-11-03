import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:velum/imports.dart';

void main() {
  test(
    'Normalizes deep links and unpadded Base64 without changing secrets',
    () {
      const uri =
          'trojan://pass%3Aword@proxy.example:443?sni=tls.example#Tokyo';
      final wrapped = 'incy://import/${Uri.encodeComponent(uri)}';
      expect(parseSubscriptionBody(wrapped).single.uri, uri);
      final encoded = base64Url
          .encode(utf8.encode('$uri\n$uri'))
          .replaceAll('=', '');
      expect(parseSubscriptionBody(encoded).length, 1);
    },
  );
  test('Imports VMess metadata and Shadowsocks legacy whole-link Base64', () {
    final vmess =
        'vmess://${base64.encode(utf8.encode(jsonEncode({'add': 'node.example', 'port': '443', 'id': '00000000-0000-4000-8000-000000000001', 'ps': 'VMess test'})))}';
    final profile = parseProfile(vmess);
    expect(profile.server, 'node.example');
    expect(profile.port, 443);
    final ss = parseProfile(
      'ss://${base64Url.encode(utf8.encode('aes-128-gcm:secret@node.example:8388')).replaceAll('=', '')}#SS',
    );
    expect(ss.server, 'node.example');
    expect(ss.port, 8388);
  });
  test('Rejects command links, oversized imports and unsupported protocol', () {
    expect(() => parseSubscriptionBody('incy://toggle'), throwsFormatException);
    expect(
      () => parseSubscriptionBody('x' * (maxImportBytes + 1)),
      throwsFormatException,
    );
    expect(
      () => parseProfile('ftp://secret@node.example:21'),
      throwsFormatException,
    );
  });
}
