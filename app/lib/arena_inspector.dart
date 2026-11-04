import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'arena_icons.dart';
import 'client.dart';

class ArenaInspector extends StatefulWidget {
  const ArenaInspector({
    super.key,
    required this.client,
    required this.index,
    required this.onAction,
  });
  final VelumClient client;
  final int index;
  final ValueChanged<String> onAction;
  @override
  State<ArenaInspector> createState() => _ArenaInspectorState();
}

class _ArenaInspectorState extends State<ArenaInspector> {
  bool json = false, copied = false;
  late final identity = widget.client.profiles[widget.index].id;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.client,
    builder: (context, _) {
      final matches = widget.client.profiles.where((p) => p.id == identity);
      if (matches.isEmpty) return const SizedBox.shrink();
      final p = matches.first;
      final uri = Uri.parse(p.uri);
      final colors = Theme.of(context).colorScheme;
      final source = json
          ? const JsonEncoder.withIndent('  ').convert(p.toJson())
          : p.uri;
      return Dialog(
        backgroundColor: const Color(0xff1a0e31),
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: colors.secondary.withValues(alpha: .22)),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 512,
            maxHeight: MediaQuery.sizeOf(context).height * .88,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    ArenaGlyph('Globe', size: 20, color: colors.secondary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            '${p.protocol} · ${uri.queryParameters['type'] ?? 'TCP'}',
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: p.favorite
                          ? 'Убрать из избранного'
                          : 'В избранное',
                      onPressed: () => widget.onAction('favorite'),
                      icon: ArenaGlyph(
                        'Star',
                        color: p.favorite
                            ? const Color(0xfffacc15)
                            : colors.onSurfaceVariant,
                      ),
                    ),
                    if (p.subscriptionId == null)
                      IconButton(
                        tooltip: 'Удалить сервер',
                        onPressed: () {
                          Navigator.pop(context);
                          widget.onAction('delete');
                        },
                        icon: const ArenaGlyph(
                          'Trash2',
                          color: Color(0xfffda4af),
                        ),
                      ),
                    IconButton(
                      tooltip: 'Закрыть параметры',
                      onPressed: () => Navigator.pop(context),
                      icon: const ArenaGlyph('X'),
                    ),
                  ],
                ),
                const Divider(),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      for (final entry in [
                        (false, 'QR и Параметры'),
                        (true, 'Профиль JSON'),
                      ])
                        Expanded(
                          child: TextButton(
                            onPressed: () => setState(() => json = entry.$1),
                            style: TextButton.styleFrom(
                              backgroundColor: json == entry.$1
                                  ? const Color(0x809333ea)
                                  : Colors.transparent,
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text(
                              entry.$2,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (!json) ...[
                  Center(
                    child: Container(
                      width: 208,
                      height: 208,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: colors.primary.withValues(alpha: .45),
                        ),
                        gradient: RadialGradient(
                          colors: [
                            colors.secondary.withValues(alpha: .22),
                            const Color(0xeb0a0514),
                          ],
                        ),
                      ),
                      child: QrImageView(
                        data: p.uri,
                        padding: EdgeInsets.zero,
                        eyeStyle: const QrEyeStyle(
                          eyeShape: QrEyeShape.square,
                          color: Color(0xfff5f2ff),
                        ),
                        dataModuleStyle: const QrDataModuleStyle(
                          dataModuleShape: QrDataModuleShape.square,
                          color: Color(0xfff5f2ff),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .3),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: .1),
                      ),
                    ),
                    child: Wrap(
                      spacing: 16,
                      runSpacing: 8,
                      children: [
                        for (final entry in [
                          ('Endpoint:', '${p.server}:${p.port}'),
                          (
                            'SNI / Host:',
                            uri.queryParameters['sni'] ??
                                uri.queryParameters['host'] ??
                                '—',
                          ),
                          if (uri.queryParameters['security'] == 'reality') ...[
                            (
                              'Fingerprint:',
                              uri.queryParameters['fp'] ?? 'chrome',
                            ),
                            ('Short ID:', uri.queryParameters['sid'] ?? '—'),
                          ],
                        ])
                          SizedBox(
                            width: 190,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  entry.$1,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                                Text(
                                  entry.$2,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontFamily: 'ArenaMono',
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ] else
                  Container(
                    padding: const EdgeInsets.all(14),
                    color: Colors.black.withValues(alpha: .3),
                    child: SelectableText(
                      source,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'ArenaMono',
                        color: colors.primary,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .4),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: .1),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          source,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'ArenaMono',
                            fontSize: 11,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: source));
                          if (mounted) setState(() => copied = true);
                        },
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          minimumSize: Size.zero,
                        ),
                        child: Text(
                          copied ? 'Скопировано' : 'Копировать',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    widget.onAction('edit');
                  },
                  child: const Text(
                    'Изменить профиль',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
