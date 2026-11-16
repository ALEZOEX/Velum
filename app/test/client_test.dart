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
    expect((await tokenFile.stat()).mode & 0x1ff, 0x180);
  }, skip: !Platform.isLinux);

  test(
    'Windows uses a provisioned console token for Bearer authentication',
    () async {
      // A clean Windows runner has no installed service token. Exercise the
      // per-user token provisioned by init-client.py, not Linux generation.
      const token =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      final tokenFile = File('${directory.path}/token');
      await tokenFile.writeAsString('$token\n');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final authorizations = <String?>[];
      server.listen((request) async {
        authorizations.add(
          request.headers.value(HttpHeaders.authorizationHeader),
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'state': 'disconnected'}));
        await request.response.close();
      });
      client.dispose();
      client = VelumClient(
        directory: directory,
        apiBase: Uri.parse('http://127.0.0.1:${server.port}/v1/'),
      );
      await client.initialize();
      expect(authorizations, isNotEmpty);
      expect(authorizations, everyElement('Bearer $token'));
      expect(client.state, 'disconnected');
      expect(await tokenFile.readAsString(), '$token\n');
    },
    skip: !Platform.isWindows,
  );

  test(
    'Windows stays offline without generating a missing provisioned token',
    () async {
      await client.initialize();
      expect(await File('${directory.path}/token').exists(), isFalse);
      expect(client.state, 'offline');
    },
    skip: !Platform.isWindows,
  );
}
