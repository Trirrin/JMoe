import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_state.dart';
import '../core/cache_manager.dart';
import '../core/config_backup.dart';
import '../core/l10n.dart';
import '../core/storage_manager.dart';
import '../main.dart';

class StoragePage extends StatefulWidget {
  const StoragePage({super.key});

  @override
  State<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends State<StoragePage> {
  List<StorageSlice> _slices = const [];
  bool _loading = true;
  int _total = 0;

  static const List<Color> _palette = [
    Color(0xFF4CAF50),
    Color(0xFF2196F3),
    Color(0xFFFF9800),
    Color(0xFF9C27B0),
    Color(0xFF9E9E9E),
  ];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final s = await StorageManager.instance.collect();
    if (!mounted) return;
    setState(() {
      _slices = s;
      _total = s.fold<int>(0, (a, b) => a + b.bytes);
      _loading = false;
    });
  }

  String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  Color _colorOf(int i) => _palette[i % _palette.length];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('storageManage')),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              edgeOffset: MediaQuery.of(context).padding.top,
              child: ListView(
            physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  Center(
                    child: SizedBox(
                      width: 200,
                      height: 200,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          CustomPaint(
                            size: const Size(200, 200),
                            painter: _PiePainter(
                              values: _slices.map((e) => e.bytes).toList(),
                              colors: List.generate(
                                _slices.length,
                                (i) => _colorOf(i),
                              ),
                              holeColor: scheme.surface,
                              trackColor:
                                  scheme.surfaceContainerHighest,
                            ),
                          ),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _fmt(_total),
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                L.t('storageTotalUsed'),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  ...List.generate(_slices.length, (i) {
                    final s = _slices[i];
                    final pct = _total <= 0 ? 0.0 : s.bytes / _total;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: _colorOf(i),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    L.t(s.key),
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${_fmt(s.bytes)}  ·  ${(pct * 100).toStringAsFixed(1)}%',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (s.clearable)
                              TextButton(
                                onPressed: s.bytes <= 0
                                    ? null
                                    : () => _confirmClear(s),
                                child: Text(L.t('clear')),
                              ),
                          ],
                        ),
                      ),
                    );
                  }),

                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _total <= 0 ? null : _confirmClearAll,
                      icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: scheme.error,
                        side: BorderSide(
                          color: scheme.error.withValues(alpha: 0.5),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      label: Text(L.t('clearAllCache')),
                    ),
                  ),

                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: _confirmClearAllData,
                      icon: const Icon(Icons.warning_amber_rounded, size: 18),
                      style: FilledButton.styleFrom(
                        backgroundColor:
                            scheme.errorContainer.withValues(alpha: 0.6),
                        foregroundColor: scheme.onErrorContainer,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      label: Text(L.t('clearAllData')),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    L.t('clearAllDataDesc'),
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),

                  Text(
                    L.t('cachePolicy'),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.straighten_rounded),
                          title: Text(L.t('cacheMaxSize')),
                          subtitle: Text(
                            CacheManager.instance.maxSizeMb == 0
                                ? L.t('unlimited')
                                : '${CacheManager.instance.maxSizeMb} MB',
                          ),
                          trailing: const Icon(Icons.chevron_right, size: 18),
                          onTap: _pickMaxSize,
                        ),
                        const Divider(height: 1),
                        ListTile(
                          leading: const Icon(Icons.schedule_rounded),
                          title: Text(L.t('cacheRetention')),
                          subtitle: Text(
                            CacheManager.instance.retentionDays == 0
                                ? L.t('forever')
                                : L.tp('daysN', {
                                    'n': CacheManager.instance.retentionDays,
                                  }),
                          ),
                          trailing: const Icon(Icons.chevron_right, size: 18),
                          onTap: _pickRetention,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),
                  Text(
                    L.t('configBackup'),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    L.t('configBackupDesc'),
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.6,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _exportConfig,
                          icon: const Icon(Icons.upload_file_rounded, size: 18),
                          label: Text(L.t('exportConfig')),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: _importConfig,
                          icon: const Icon(Icons.download_rounded, size: 18),
                          label: Text(L.t('importConfig')),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
    );
  }

  Future<void> _pickMaxSize() async {
    const options = [0, 256, 512, 1024, 2048, 4096];
    final cm = CacheManager.instance;
    final sel = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (c) => ListView(
        shrinkWrap: true,
        children: options
            .map(
              (v) => ListTile(
                title: Text(v == 0 ? L.t('unlimited') : '$v MB'),
                trailing: cm.maxSizeMb == v
                    ? const Icon(Icons.check, size: 18)
                    : null,
                onTap: () => Navigator.pop(c, v),
              ),
            )
            .toList(),
      ),
    );
    if (sel != null) {
      await cm.setMaxSizeMb(sel);
      await _refresh();
    }
  }

  Future<void> _pickRetention() async {
    const options = [0, 7, 15, 30, 60, 180];
    final cm = CacheManager.instance;
    final sel = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (c) => ListView(
        shrinkWrap: true,
        children: options
            .map(
              (v) => ListTile(
                title: Text(
                  v == 0 ? L.t('forever') : L.tp('daysN', {'n': v}),
                ),
                trailing: cm.retentionDays == v
                    ? const Icon(Icons.check, size: 18)
                    : null,
                onTap: () => Navigator.pop(c, v),
              ),
            )
            .toList(),
      ),
    );
    if (sel != null) {
      await cm.setRetentionDays(sel);
      await _refresh();
    }
  }

  Future<void> _confirmClear(StorageSlice s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(L.t('clear')),
        content: Text(L.tp('clearCategoryConfirm', {'name': L.t(s.key)})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(L.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(L.t('delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await StorageManager.instance.clear(s.key);
    await _refresh();
  }

  Future<void> _confirmClearAllData() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(L.t('clearAllData')),
        content: Text(L.t('clearAllDataConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(L.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(L.t('delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _loading = true);

    try {
      await StorageManager.instance.clearAll();
    } catch (_) {}

    try {
      final sp = await SharedPreferences.getInstance();
      await sp.clear();
    } catch (_) {}

    try {
      await AppState.instance.clearAllData();
    } catch (_) {}

    if (!mounted) return;

    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AppBootstrap()),
      (route) => false,
    );
  }

  Future<void> _confirmClearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(L.t('clearAllCache')),
        content: Text(L.t('clearAllCacheConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(L.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(L.t('delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await StorageManager.instance.clearAll();
    await _refresh();
  }

  Future<void> _exportConfig() async {
    final path = await ConfigBackup.instance.exportToFile();
    if (!mounted) return;
    _snack(
      path == null
          ? L.t('exportFailed')
          : L.tp('exportedTo', {'path': path}),
    );
  }

  Future<void> _importConfig() async {
    final ctrl = TextEditingController();
    final json = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(L.t('importConfig')),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: ctrl,
            maxLines: 8,
            decoration: InputDecoration(
              hintText: L.t('importHint'),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text(L.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text.trim()),
            child: Text(L.t('ok')),
          ),
        ],
      ),
    );
    if (json == null || json.isEmpty) return;
    final r = await ConfigBackup.instance.import(json);
    if (!mounted) return;
    _snack(
      r.ok
          ? L.tp('importedCount', {'n': r.count})
          : L.tp('importFailed', {'e': r.error ?? ''}),
    );
  }

  void _snack(String s) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(s),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 2200),
      ),
    );
  }
}

class _PiePainter extends CustomPainter {
  final List<int> values;
  final List<Color> colors;

  final Color holeColor;

  final Color trackColor;

  _PiePainter({
    required this.values,
    required this.colors,
    required this.holeColor,
    required this.trackColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final total = values.fold<int>(0, (a, b) => a + b);
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final center = rect.center;
    final radius = math.min(size.width, size.height) / 2;

    canvas.drawCircle(
      center,
      radius,
      Paint()..color = trackColor,
    );

    if (total <= 0) return;

    var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v <= 0) continue;
      final sweep = 2 * math.pi * (v / total);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start,
        sweep,
        true,
        Paint()..color = colors[i % colors.length],
      );
      start += sweep;
    }

    canvas.drawCircle(
      center,
      radius * 0.58,
      Paint()..color = holeColor,
    );
  }

  @override
  bool shouldRepaint(_PiePainter old) =>
      old.values != values ||
      old.colors != colors ||
      old.holeColor != holeColor ||
      old.trackColor != trackColor;
}
