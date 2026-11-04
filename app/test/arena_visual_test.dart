import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velum/main.dart';
import 'package:velum/client.dart';

class VisualClient extends VelumClient {
  VisualClient({required Directory directory}) : super(directory: directory);
  @override
  Future<void> refreshLogs() async {}
}

void main() {
  setUpAll(() async {
    final mono = FontLoader('ArenaMono')
      ..addFont(rootBundle.load('assets/fonts/NotoSansMono-Regular.ttf'));
    await mono.load();
    final material = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await material.load();
    final regular = FontLoader('ArenaSans')
      ..addFont(rootBundle.load('assets/fonts/NotoSans-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/NotoSans-Bold.ttf'));
    await regular.load();
  });
  for (final width in [480, 980]) {
    testWidgets('Arena layout at $width px', (tester) async {
      final directory = Directory.systemTemp.createTempSync('velum-visual-');
      final client = VisualClient(directory: directory);
      client.state = 'disconnected';
      client.subscriptions.add(
        Subscription(
          id: 'fixture',
          url: 'https://example.invalid/sub',
          title: 'Velum Edge Cloud',
          intervalMinutes: 120,
          upload: 3420000000,
          download: 18940000000,
          total: 107374182400,
          announceText: 'Добавлены узлы XHTTP Reality (Финляндия и Германия) с защитой от ТСПУ',
          supportUrl: 'https://example.invalid/support',
          webpageUrl: 'https://example.invalid',
          expires: DateTime(2026, 11, 28),
        ),
      );
      for (final item in [
        ('Финляндия · Хельсинки #1', 31),
        ('Германия · Франкфурт XHTTP', 44),
        ('Нидерланды · Амстердам Gaming', 49),
      ]) {
        client.profiles.add(
          Profile(
            'vless://00000000-0000-4000-8000-000000000001@192.0.2.1:443?security=reality&type=tcp',
            item.$1,
            id: item.$1,
            subscriptionId: 'fixture',
            latencyMs: item.$2,
          ),
        );
      }
      tester.view.physicalSize = Size(width.toDouble(), 760);
      tester.view.devicePixelRatio = 1;
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: VelumApp(client: client, initialize: false),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> capture(String screen) async {
        expect(tester.takeException(), isNull, reason: '$screen at $width');
        final target = Platform.environment['VELUM_CAPTURE_DIR'];
        if (target == null) return;
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          Directory(target).createSync(recursive: true);
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('$target/flutter-$screen-$width.png')
              .writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      expect(
        tester.getSize(find.byKey(const ValueKey('arena-dock'))).height,
        width >= 640 ? 52 : 66,
      );
      await capture('connection');
      for (final entry in [(1, 'servers'), (5, 'settings'), (3, 'routing')]) {
        await tester.tap(find.byKey(ValueKey('nav-${entry.$1}')));
        await tester.pumpAndSettle();
        await capture(entry.$2);
      }
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Параметры сервера и QR').first);
      await tester.pumpAndSettle();
      await capture('inspector');
      await tester.tap(find.byTooltip('Закрыть параметры'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-4')));
      await tester.pumpAndSettle();
      await capture('logs');
      await tester.tap(find.byTooltip('Закрыть журнал'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Добавить провайдера или сервер'));
      await tester.pumpAndSettle();
      expect(find.text('Ссылка'), findsOneWidget);
      await capture('import');
      await tester.pumpWidget(const SizedBox());
      client.dispose();
      directory.deleteSync(recursive: true);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }
}
