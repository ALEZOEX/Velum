import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'arena_icons.dart';
import 'client.dart';
import 'imports.dart' show maxImportBytes;

Future<void> showArenaImport(
  BuildContext context,
  VelumClient client, {
  bool scan = false,
}) => showDialog<void>(
  context: context,
  barrierColor: Colors.black.withValues(alpha: .75),
  builder: (_) => ArenaImport(client: client, scan: scan),
);

class ArenaImport extends StatefulWidget {
  const ArenaImport({super.key, required this.client, this.scan = false});
  final VelumClient client;
  final bool scan;
  @override
  State<ArenaImport> createState() => _ArenaImportState();
}

class _ArenaImportState extends State<ArenaImport> {
  final input = TextEditingController();
  final name = TextEditingController();
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    if (widget.scan) {
      WidgetsBinding.instance.addPostFrameCallback((_) => pick(qr: true));
    }
  }

  @override
  void dispose() {
    input.dispose();
    name.dispose();
    super.dispose();
  }

  Future<void> pick({bool qr = false}) async {
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(
            label: qr ? 'QR изображение' : 'Конфигурация',
            extensions: qr
                ? ['png', 'jpg', 'jpeg', 'webp']
                : ['txt', 'sub', 'conf', 'json'],
          ),
        ],
      );
      if (file == null) return;
      if (await file.length() > (qr ? 16 * 1024 * 1024 : maxImportBytes)) {
        throw const FormatException('Файл слишком большой.');
      }
      String value;
      if (qr) {
        if (!Platform.isLinux) {
          throw const FormatException(
            'Чтение QR из файла пока доступно на Linux.',
          );
        }
        final result = await Process.run('zbarimg', [
          '--quiet',
          '--raw',
          file.path,
        ]).timeout(const Duration(seconds: 10));
        if (result.exitCode != 0 || '${result.stdout}'.trim().isEmpty) {
          throw const FormatException(
            'QR-код не найден. Для чтения требуется zbarimg.',
          );
        }
        value = '${result.stdout}'.trim();
      } else {
        value = await file.readAsString();
      }
      if (mounted) {
        setState(() {
          input.text = value;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException
              ? e.message
              : 'Не удалось прочитать файл.',
        );
      }
    }
  }

  Future<void> submit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.client.importText(
        input.text,
        title: name.text.trim().isEmpty ? null : name.text.trim(),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e is FormatException
              ? e.message
              : 'Не удалось импортировать данные.';
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final acid = Theme.of(context).colorScheme.primary;
    final text = input.text.trim();
    final isSub = text.startsWith('https://');
    final detected =
        isSub ||
        RegExp(r'^(vless|vmess|trojan|ss|hy2|hysteria2|socks5?|https?)://')
            .hasMatch(text);
    final badge = isSub
        ? 'SUB'
        : detected
        ? text.split(':').first.toUpperCase()
        : 'AUTO';
    return Dialog(
      backgroundColor: const Color(0xff1a0e31),
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: Color(0x38a855f7)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 448),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0x4dc084fc),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: acid.withValues(alpha: .1),
                      border: Border.all(
                        color: acid.withValues(alpha: .45),
                        width: 2,
                      ),
                    ),
                    child: Center(
                      child: ArenaGlyph('Link2', size: 20, color: acid),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Добавить',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xffb5a1cc),
                          ),
                        ),
                        Text(
                          'Провайдер',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: acid,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: busy ? null : () => Navigator.pop(context),
                    icon: const ArenaGlyph('X'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xa00d061a),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: detected
                        ? acid.withValues(alpha: .45)
                        : const Color(0x38a855f7),
                  ),
                ),
                child: Row(
                  children: [
                    ArenaGlyph(
                      detected ? 'Check' : 'Sparkles',
                      color: detected ? acid : const Color(0xffc084fc),
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Определение типа',
                            style: TextStyle(
                              fontSize: 11,
                              color: Color(0xffb5a1cc),
                            ),
                          ),
                          Text(
                            detected ? 'Тип определён' : 'Ожидание ссылки',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: detected ? acid : const Color(0xffe9d5ff),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      badge,
                      style: TextStyle(
                        color: acid,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text(
                    'Ссылка',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: busy ? null : () => setState(input.clear),
                    child: const Text(
                      'Очистить',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
              TextField(
                key: const ValueKey('arena-import-input'),
                controller: input,
                minLines: 3,
                maxLines: 5,
                onChanged: (_) => setState(() {}),
                style: TextStyle(
                  fontFamily: 'ArenaMono',
                  color: acid,
                  fontSize: 12,
                ),
                decoration: const InputDecoration(
                  hintText: 'https://sub..../ваш-ключ или vless://...',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (final item in [
                    ('ClipboardPaste', 'Вставить'),
                    ('FileText', 'Файл'),
                    ('ScanLine', 'Сканировать'),
                  ])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: OutlinedButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  if (item.$1 == 'ClipboardPaste') {
                                    final data = await Clipboard.getData(
                                      'text/plain',
                                    );
                                    if (mounted) {
                                      setState(
                                        () => input.text = data?.text ?? '',
                                      );
                                    }
                                  } else {
                                    await pick(qr: item.$1 == 'ScanLine');
                                  }
                                },
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 2,
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              ArenaGlyph(item.$1, size: 14, color: acid),
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  item.$2,
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              const Text(
                'Название (опционально)',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: name,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  hintText: 'Определится автоматически',
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    style: const TextStyle(
                      color: Color(0xfffda4af),
                      fontSize: 12,
                    ),
                  ),
                ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: busy || text.isEmpty ? null : submit,
                style: FilledButton.styleFrom(
                  shape: const StadiumBorder(),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(
                  busy
                      ? 'Добавление...'
                      : isSub
                      ? 'Добавить провайдера'
                      : 'Добавить сервер',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              TextButton(
                onPressed: busy ? null : () => Navigator.pop(context),
                child: const Text('Отмена', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
