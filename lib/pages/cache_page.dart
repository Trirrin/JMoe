import 'package:flutter/material.dart';

import '../core/cache_manager.dart';
import '../core/l10n.dart';
import '../core/chapter_cache.dart';
import '../core/novel_cache.dart';
import '../widgets/common_widgets.dart';

/// 缓存管理页：占用统计、容量上限、保留时长、清理操作、已缓存章节列表。
class CachePage extends StatefulWidget {
  const CachePage({super.key});

  @override
  State<CachePage> createState() => _CachePageState();
}

class _CachePageState extends State<CachePage> {
  int _usedBytes = 0;
  int _capBytes = 0;
  double _ratio = 0;
  int _chapterCount = 0;
  int _novelBytes = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    CacheManager.instance.revision.addListener(_refresh);
    _refresh();
  }

  @override
  void dispose() {
    CacheManager.instance.revision.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _refresh() async {
    final s = await CacheManager.instance.usageStats();
    final novelBytes = await NovelCacheManager.instance.usedBytes();
    if (!mounted) return;
    setState(() {
      _usedBytes = s.used;
      _capBytes = s.cap;
      _ratio = s.ratio;
      _chapterCount = CacheManager.instance.cachedChapters.length;
      _novelBytes = novelBytes;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cm = CacheManager.instance;
    final chapters = cm.cachedChapters;

    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('cacheManage')),
        actions: [
          IconButton(
            tooltip: L.t('refresh'),
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _refresh,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                // 占用卡片
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          scheme.primaryContainer,
                          scheme.primaryContainer.withValues(alpha: 0.55),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                      children: [
                        Icon(
                          Icons.sd_storage_rounded,
                          size: 30,
                          color: scheme.onPrimaryContainer,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                L.t('cacheUsed'),
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: scheme.onPrimaryContainer
                                      .withValues(alpha: 0.8),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _capBytes > 0
                                    ? '${_fmt(_usedBytes)} / ${_fmt(_capBytes)}'
                                    : _fmt(_usedBytes),
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                  color: scheme.onPrimaryContainer,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          _capBytes > 0
                              ? '${(_ratio * 100).toStringAsFixed(1)}%'
                              : L.t('unlimited'),
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: scheme.onPrimaryContainer,
                          ),
                        ),
                      ],
                        ),
                        if (_capBytes > 0) ...[
                          const SizedBox(height: 12),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value: _ratio,
                              minHeight: 5,
                              backgroundColor:
                                  scheme.onPrimaryContainer.withValues(alpha: 0.15),
                              valueColor: AlwaysStoppedAnimation(
                                scheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            L.tp('cacheChapters', {'n': _chapterCount}),
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onPrimaryContainer
                                  .withValues(alpha: 0.85),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                SectionHeader(title: L.t('cacheCapacitySection')),
                // 最大容量
                ListTile(
                  leading: const Icon(Icons.straighten_rounded),
                  title: Text(L.t('cacheMaxSize')),
                  subtitle: Text(
                    cm.maxSizeMb == 0
                        ? L.t('unlimited')
                        : '${cm.maxSizeMb} MB',
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => _pickSize(cm),
                ),
                // 保留时长
                ListTile(
                  leading: const Icon(Icons.schedule_rounded),
                  title: Text(L.t('cacheRetention')),
                  subtitle: Text(
                    cm.retentionDays == 0
                        ? L.t('forever')
                        : L.tp('daysN', {'n': cm.retentionDays}),
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => _pickDays(cm),
                ),

                SectionHeader(title: L.t('novelCache')),
                ListTile(
                  leading: const Icon(Icons.menu_book_rounded),
                  title: Text(L.t('novelCacheUsed')),
                  subtitle: Text(_fmt(_novelBytes)),
                  trailing: TextButton(
                    onPressed: _novelBytes <= 0
                        ? null
                        : () async {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (c) => AlertDialog(
                                title: Text(L.t('clearNovelCache')),
                                content: Text(L.t('clearNovelCacheConfirm')),
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
                            await NovelCacheManager.instance.clearAll();
                            if (!mounted) return;
                            await _refresh();
                          },
                    child: Text(L.t('clear')),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    L.t('novelCacheDesc'),
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),

                SectionHeader(title: L.t('cacheCleanSection')),
                ListTile(
                  leading: Icon(Icons.auto_delete_outlined, color: scheme.primary),
                  title: Text(L.t('clearExpired')),
                  subtitle: Text(L.t('clearExpiredDesc')),
                  onTap: () async {
                    final n = await cm.clearExpired();
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(L.tp('clearedItems', {'n': n})),
                      ),
                    );
                    await _refresh();
                  },
                ),
                ListTile(
                  leading: Icon(Icons.delete_sweep_outlined, color: scheme.error),
                  title: Text(
                    L.t('clearAllCache'),
                    style: TextStyle(color: scheme.error),
                  ),
                  subtitle: Text(L.t('clearAllCacheDesc')),
                  onTap: () async {
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
                    await cm.clearAll();
                    if (!mounted) return;
                    await _refresh();
                  },
                ),

                if (chapters.isNotEmpty) ...[
                  SectionHeader(title: L.t('cachedChapters')),
                  ...chapters.map((e) {
                    final key = '${e['key']}';
                    return ListTile(
                      dense: true,
                      leading: SizedBox(
                        width: 40,
                        height: 54,
                        child: CoverImage(
                          url: e['cover'] as String?,
                          borderRadius: BorderRadius.circular(5),
                          memCacheWidth: 120,
                        ),
                      ),
                      title: Text(
                        '${e['comicName'] ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                      subtitle: Text(
                        '${e['chapterName'] ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () async {
                          final parts = key.split(':');
                          if (parts.length == 2) {
                            ChapterCacheManager.instance
                                .cancelTask(parts[0], parts[1]);
                            await cm.unmarkChapter(parts[0], parts[1]);
                            await cm.clearAll();
                          }
                          await _refresh();
                        },
                      ),
                    );
                  }),
                ],
              ],
            ),
    );
  }

  Future<void> _pickSize(CacheManager cm) async {
    const options = [0, 256, 512, 1024, 2048, 4096];
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

  Future<void> _pickDays(CacheManager cm) async {
    const options = [0, 7, 15, 30, 60, 180];
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
}
