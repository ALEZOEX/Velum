import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'arena_icons.dart';
import 'client.dart';

Future<void> showArenaLogs(BuildContext context, VelumClient client) =>
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .75),
      builder: (_) => ArenaLogs(client: client),
    );

class ArenaLogs extends StatefulWidget {
  const ArenaLogs({super.key, required this.client});
  final VelumClient client;
  @override
  State<ArenaLogs> createState() => _ArenaLogsState();
}

class _ArenaLogsState extends State<ArenaLogs> {
  bool config = false;
  String get settings =>
      const JsonEncoder.withIndent('  ').convert(widget.client.settings);
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.client,
    builder: (context, _) => Dialog(
      backgroundColor: const Color(0xff1a0e31),
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: Color(0x38a855f7)),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 768,
          maxHeight: MediaQuery.sizeOf(context).height * .86,
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: 12,
                runSpacing: 8,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () => setState(() => config = false),
                        style: TextButton.styleFrom(
                          backgroundColor: !config
                              ? const Color(0x8c9333ea)
                              : Colors.transparent,
                        ),
                        child: const Text(
                          'Журнал sing-box',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(() => config = true),
                        style: TextButton.styleFrom(
                          backgroundColor: config
                              ? const Color(0x8c9333ea)
                              : Colors.transparent,
                        ),
                        child: const Text(
                          'settings.json',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton.icon(
                        onPressed: () => config
                            ? Clipboard.setData(ClipboardData(text: settings))
                            : widget.client.clearLocalLogs(),
                        icon: ArenaGlyph(config ? 'Copy' : 'Trash2', size: 14),
                        label: Text(
                          config ? 'Копировать' : 'Очистить',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Закрыть журнал',
                        onPressed: () => Navigator.pop(context),
                        icon: const ArenaGlyph('X'),
                      ),
                    ],
                  ),
                ],
              ),
              const Divider(),
              const SizedBox(height: 12),
              Flexible(
                child: Container(
                  constraints: const BoxConstraints(minHeight: 320),
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0x8c000000),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: .1),
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      config
                          ? settings
                          : widget.client.logs.isEmpty
                          ? 'Журнал пуст — включите соединение или проверку пинга'
                          : widget.client.logs
                                .map(
                                  (row) =>
                                      '${row['time'] ?? ''} [${row['level'] ?? 'INFO'}] ${row['message'] ?? ''}',
                                )
                                .join('\n'),
                      style: TextStyle(
                        fontFamily: 'ArenaMono',
                        fontSize: 12,
                        color: config
                            ? const Color(0xffd9f99d)
                            : const Color(0xffe9d5ff),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
