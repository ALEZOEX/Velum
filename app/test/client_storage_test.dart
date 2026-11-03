import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:velum/client.dart';

void main() {
  late Directory directory;
  late VelumClient client;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('velum-storage-');
    client = VelumClient(directory: directory);
  });
  tearDown(() async {
    client.dispose();
    await directory.delete(recursive: true);
  });
  test(
    'Migrates old profiles without changing names, selection or exclusions',
    () async {
      final original = jsonEncode({
        'profiles': [
          {'uri': 'hy2://test@192.0.2.1:443#Remote', 'name': 'My chosen label'},
          {'uri': 'trojan://test@192.0.2.2:443', 'name': 'Second'},
        ],
        'selected': 1,
        'exclusions': 'example.org',
      });
      await File('${directory.path}/profiles.json').writeAsString(original);
      await client.initialize();
      expect(client.profiles.first.name, 'My chosen label');
      expect(client.selected, 1);
      expect(client.exclusions, 'example.org');
      expect(client.settings['autoConnect'], false);
      expect(
        await File('${directory.path}/profiles.v1.backup.json').readAsString(),
        original,
      );
      expect(
        (await File('${directory.path}/profiles.json').stat()).mode & 0x1ff,
        0x180,
      );
    },
  );
  test('Backup roundtrip keeps favorite, custom name and selection; invalid backup is atomic', () async {
    await client.importText(
      'hy2://test@192.0.2.1:443#First\ntrojan://test@192.0.2.2:443#Second',
    );
    await client.rename(0, 'Personal');
    await client.toggleFavorite(0);
    await client.select(1);
    await client.saveSettings({
      'theme': 'dark',
      'rules': [
        {'type': 'domain', 'value': 'example.org', 'action': 'direct'},
      ],
    });
    final backup = client.exportBackup();
    await client.remove(0);
    await client.restoreBackup(backup);
    expect(client.profiles.length, 2);
    expect(client.profiles.first.favorite, true);
    expect(client.profiles.first.name, 'Personal');
    expect(client.selected, 1);
    expect(client.settings['theme'], 'dark');
    final invalid = jsonDecode(backup) as Map<String, dynamic>;
    invalid['settings']['proxyPort'] = 22;
    await expectLater(
      client.restoreBackup(jsonEncode(invalid)),
      throwsFormatException,
    );
    expect(client.exportBackup(), backup);
  });
  test(
    'Selection and queued favorite updates survive concurrent writes',
    () async {
      await client.importText(
        'hy2://test@192.0.2.1:443#First\ntrojan://test@192.0.2.2:443#Second',
      );
      await Future.wait([
        client.toggleFavorite(0),
        client.rename(1, 'Changed'),
      ]);
      expect(client.profiles.first.favorite, true);
      expect(client.profiles.last.name, 'Changed');
      expect(client.filteredProfiles(query: 'changed').single.name, 'Changed');
      expect(client.filteredProfiles(favoritesOnly: true).single.name, 'First');
    },
  );
  test(
    'Unreadable future-version store is preserved until explicit recovery',
    () async {
      const raw = '{"version":99,"profiles":[]}';
      final store = File('${directory.path}/profiles.json');
      await store.writeAsString(raw);
      await client.initialize();
      await expectLater(
        client.importText('trojan://test@192.0.2.1:443'),
        throwsFormatException,
      );
      expect(await store.readAsString(), raw);
      final backup = jsonEncode({
        'format': 'velum-backup',
        'version': 2,
        'profiles': [],
        'selected': 0,
      });
      await client.restoreBackup(backup);
      await client.importText('trojan://test@192.0.2.1:443');
      expect(client.profiles.length, 1);
    },
  );
}
