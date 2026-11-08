import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:velum/client.dart';

void main() {
  late Directory directory;
  late VelumClient client;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('velum-test-');
    client = VelumClient(directory: directory);
  });
  tearDown(() async {
    client.dispose();
    await directory.delete(recursive: true);
  });
  test('Base64 subscription deduplicates and persists profiles', () async {
    const uri = 'hy2://password@192.0.2.1:443#Test';
    await client.importText(base64.encode(utf8.encode('$uri\n$uri')));
    expect(client.profiles.length, 1);
    final data = jsonDecode(
      await File('${directory.path}/profiles.json').readAsString(),
    ) as Map<String, dynamic>;
    expect((data['profiles'] as List).length, 1);
  });
  test('Invalid subscription is rejected atomically', () async {
    await expectLater(
      client.importText('hy2://password@192.0.2.1:443\nhttps://bad'),
      throwsFormatException,
    );
    expect(client.profiles, isEmpty);
    expect(await File('${directory.path}/profiles.json').exists(), isFalse);
  });
  test('Token is automatically initialized on Linux if absent', () async {
    expect(await File('${directory.path}/token').exists(), isFalse);
    await client.initialize();
    final tokenFile = File('${directory.path}/token');
    expect(await tokenFile.exists(), isTrue);
    final token = (await tokenFile.readAsString()).trim();
    expect(token.length, 64);
  });
}
