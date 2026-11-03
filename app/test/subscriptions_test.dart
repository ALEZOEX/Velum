import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:velum/client.dart';

class _TrustedTestClient extends HttpOverrides {
  _TrustedTestClient(this.context);
  final SecurityContext context;
  @override
  HttpClient createHttpClient(SecurityContext? _) =>
      super.createHttpClient(context);
}

void main() {
  test('HTTPS refresh replaces group atomically and preserves favorite/custom name', () async {
    final directory = await Directory.systemTemp.createTemp(
      'velum-subscription-',
    );
    final cert = '${directory.path}/cert.pem';
    final key = '${directory.path}/key.pem';
    final generated = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'ec',
      '-pkeyopt',
      'ec_paramgen_curve:P-256',
      '-nodes',
      '-keyout',
      key,
      '-out',
      cert,
      '-days',
      '1',
      '-subj',
      '/CN=localhost',
      '-addext',
      'subjectAltName=IP:127.0.0.1',
    ]);
    expect(generated.exitCode, 0);
    final serverContext = SecurityContext()
      ..useCertificateChain(cert)
      ..usePrivateKey(key);
    final trustedContext = SecurityContext(withTrustedRoots: true)
      ..setTrustedCertificates(cert);
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    var body =
        'trojan://pass@192.0.2.1:443#First\ntrojan://pass@192.0.2.2:443#Second';
    var status = 200;
    var userAgent = '';
    final requests = server.listen((request) async {
      userAgent = request.headers.value(HttpHeaders.userAgentHeader) ?? '';
      request.response.statusCode = status;
      request.response.headers.set(
        'profile-title',
        'base64:${base64.encode(utf8.encode('Test subscription'))}',
      );
      request.response.headers.set(
        'subscription-userinfo',
        'upload=10; download=20; total=1024; expire=2000000000',
      );
      request.response.write(body);
      await request.response.close();
    });
    final client = VelumClient(
      directory: Directory('${directory.path}/client'),
    );
    try {
      await HttpOverrides.runWithHttpOverrides(() async {
        await client.importText(
          'https://127.0.0.1:${server.port}/subscription',
        );
        final id = client.subscriptions.single.id;
        expect(client.subscriptions.single.title, 'Test subscription');
        expect(client.subscriptions.single.total, 1024);
        expect(client.profiles.length, 2);
        await client.toggleFavorite(0);
        await client.rename(0, 'Personal first');
        await client.configureSubscription(id, userAgent: 'Velum test agent');
        body = 'trojan://pass@192.0.2.1:443#Updated remote title\ntrojan://pass@192.0.2.3:443#Third';
        await client.updateSubscription(id);
        expect(userAgent, 'Velum test agent');
        expect(client.profiles.first.name, 'Personal first');
        expect(client.profiles.first.favorite, true);
        expect(client.profiles.last.server, '192.0.2.3');
        body = 'not a valid server';
        await expectLater(client.updateSubscription(id), throwsFormatException);
        expect(client.profiles.length, 2);
        expect(client.profiles.last.server, '192.0.2.3');
        status = 302;
        await expectLater(
          client.importText('https://127.0.0.1:${server.port}/other'),
          throwsFormatException,
        );
        expect(client.subscriptions.length, 1);
      }, _TrustedTestClient(trustedContext));
    } finally {
      client.dispose();
      await server.close(force: true);
      await requests.cancel();
      await directory.delete(recursive: true);
    }
  });
}
