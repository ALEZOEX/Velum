import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velum/arena_style.dart';
import 'package:velum/client.dart';
import 'package:velum/main.dart';

class MemoryClient extends VelumClient {
  MemoryClient({required super.directory});
  @override
  Future<void> saveSettings(Map<String, dynamic> patch) async {
    settings.addAll(patch);
    notifyListeners();
  }
}

void main() {
  testWidgets(
    'Pattern intensity changes rendered pixels; clean aurora stays unchanged',
    (tester) async {
      tester.view.physicalSize = const Size(320, 240);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey();
      Future<List<int>> render(String pattern, int intensity) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: arenaTheme(Brightness.dark),
            home: RepaintBoundary(
              key: key,
              child: ArenaBackdrop(patternId: pattern, intensity: intensity),
            ),
          ),
        );
        await tester.pump();
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        return (await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List().toList();
          image.dispose();
          return bytes;
        }))!;
      }

      final hidden = await render('cyber-circuit', 0);
      final visible = await render('cyber-circuit', 100);
      expect(hidden, isNot(equals(visible)));
      expect(
        await render('aurora-clean', 0),
        equals(await render('aurora-clean', 100)),
      );
      for (final pattern in [
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
      ]) {
        expect(
          await render(pattern, 100),
          isNot(equals(hidden)),
          reason: pattern,
        );
      }
    },
  );
  testWidgets('Brightness slider updates the live backdrop', (tester) async {
    final directory = Directory.systemTemp.createTempSync('velum-slider-');
    final client = MemoryClient(directory: directory);
    tester.view.physicalSize = const Size(980, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(VelumApp(client: client, initialize: false));
    await tester.tap(find.byKey(const ValueKey('nav-5')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Тема оформления'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Режим темы')).dy,
      lessThan(tester.getTopLeft(find.text('Фоновый узор и градиенты')).dy),
    );
    await tester.ensureVisible(find.text('Орбиты'));
    await tester.tap(find.text('Орбиты'));
    await tester.pumpAndSettle();
    expect(client.settings['patternId'], 'orbital');
    expect(
      tester.widget<ArenaBackdrop>(find.byType(ArenaBackdrop)).patternId,
      'orbital',
    );
    await tester.ensureVisible(find.byType(Slider));
    await tester.pumpAndSettle();
    expect(find.textContaining('Яркость узора:'), findsOneWidget);
    await tester.tapAt(
      tester.getTopLeft(find.byType(Slider)) + const Offset(30, 20),
    );
    await tester.pumpAndSettle();
    expect(client.settings['patternIntensity'], lessThan(68));
    expect(
      tester.widget<ArenaBackdrop>(find.byType(ArenaBackdrop)).intensity,
      client.settings['patternIntensity'],
    );
    await tester.pumpWidget(const SizedBox());
    client.dispose();
    directory.deleteSync(recursive: true);
  });

  test('New patterns and brightness survive reload', () async {
    final directory = await Directory.systemTemp.createTemp('velum-pattern-');
    final client = VelumClient(directory: directory);
    try {
      for (final pattern in [
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
      ]) {
        await client.saveSettings({
          'patternId': pattern,
          'patternIntensity': 100,
        });
      }
      final restored = VelumClient(directory: directory);
      try {
        await restored.initialize();
        expect(restored.settings['patternId'], 'interference');
        expect(restored.settings['patternIntensity'], 100);
      } finally {
        restored.dispose();
      }
    } finally {
      client.dispose();
      await directory.delete(recursive: true);
    }
  });
}
