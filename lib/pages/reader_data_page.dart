import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/l10n.dart';
import '../core/reader_store.dart';
import '../core/reading_stats.dart';
import '../core/storage_manager.dart';
import '../core/downloader.dart';

/// 阅读数据页：书签 / 批注 / 阅读时长统计。
///
/// 数据来自 ReaderStore（已持久化）与 ReaderSettings（累计阅读秒数）。
class ReaderDataPage extends StatefulWidget {
  /// 书籍 id；为 null 时聚合展示所有书籍的数据。
  final String? bookId;

  const ReaderDataPage({super.key, this.bookId});

  @override
  State<ReaderDataPage> createState() => _ReaderDataPageState();
}

class _ReaderDataPageState extends State<ReaderDataPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 3, vsync: this);

  /// 存储占用（分类）
  List<StorageSlice> _storageSlices = const [];
  int _storageTotal = 0;

  @override
  void initState() {
    super.initState();
    _loadStorage();
  }

  Future<void> _loadStorage() async {
    try {
      final s = await StorageManager.instance.collect();
      if (!mounted) return;
      setState(() {
        _storageSlices = s;
        _storageTotal = s.fold<int>(0, (a, b) => a + b.bytes);
      });
    } catch (_) {}
  }

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bookId = widget.bookId;

    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('readerData')),
        bottom: TabBar(
          controller: _tab,
          tabs: [
            Tab(text: L.t('bookmarks')),
            Tab(text: L.t('annotations')),
            Tab(text: L.t('readingStats')),
          ],
        ),
      ),
      body: TabBarView(
              controller: _tab,
              children: [
                bookId == null
                    ? _noBookHint(theme, L.t('noBookmarks'))
                    : _buildBookmarks(theme, bookId),
                bookId == null
                    ? _noBookHint(theme, L.t('noAnnotations'))
                    : _buildAnnotations(theme, bookId),
                _buildStats(theme),
              ],
            ),
    );
  }

  /// 无关联书籍时的占位提示
  Widget _noBookHint(ThemeData theme, String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            height: 1.6,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildBookmarks(ThemeData theme, String bookId) {
    final list = ReaderStore.instance.bookmarks(bookId);
    if (list.isEmpty) {
      return Center(
        child: Text(
          L.t('noBookmarks'),
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: list.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final b = list[i];
        return Card(
          elevation: 0,
          color: theme.colorScheme.surfaceContainerLow,
          child: ListTile(
            leading: const Icon(Icons.bookmark_outline),
            title: Text(
              b.chapterTitle,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              b.excerpt,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: () async {
                await ReaderStore.instance.removeBookmark(bookId, b);
                if (mounted) setState(() {});
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildAnnotations(ThemeData theme, String bookId) {
    final list = ReaderStore.instance.annotations(bookId);
    if (list.isEmpty) {
      return Center(
        child: Text(
          L.t('noAnnotations'),
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: list.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final a = list[i];
        return Card(
          elevation: 0,
          color: theme.colorScheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        a.chapterTitle,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: () async {
                        await ReaderStore.instance
                            .removeAnnotation(bookId, a.id);
                        if (mounted) setState(() {});
                      },
                    ),
                  ],
                ),
                Text(
                  a.text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, height: 1.6),
                ),
                if (a.note.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer
                          .withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      a.note,
                      style: const TextStyle(fontSize: 12, height: 1.5),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildStats(ThemeData theme) {
    final scheme = theme.colorScheme;
    final st = ReadingStats.instance;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        // ---- 总览 ----
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                scheme.primaryContainer,
                scheme.primaryContainer.withValues(alpha: 0.5),
              ],
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Expanded(
                child: _overviewCell(
                  theme,
                  L.t('totalReadingTime'),
                  _fmtDur(st.totalSeconds),
                ),
              ),
              Container(
                width: 1,
                height: 36,
                color: scheme.onPrimaryContainer.withValues(alpha: 0.15),
              ),
              Expanded(
                child: _overviewCell(
                  theme,
                  L.t('todayReading'),
                  _fmtDur(st.todaySeconds),
                ),
              ),
              Container(
                width: 1,
                height: 36,
                color: scheme.onPrimaryContainer.withValues(alpha: 0.15),
              ),
              Expanded(
                child: _overviewCell(
                  theme,
                  L.t('streakDays'),
                  '${st.streakDays} ${L.t('daysShort')}',
                ),
              ),
            ],
          ),
        ),

        // ---- 三大板块分区 ----
        const SizedBox(height: 20),
        _buildTypeSection(
          theme,
          type: StatType.comic,
          icon: Icons.auto_stories_rounded,
          title: L.t('searchComic'),
          unit: L.t('unitChapter'),
        ),
        const SizedBox(height: 14),
        _buildTypeSection(
          theme,
          type: StatType.novel,
          icon: Icons.menu_book_rounded,
          title: L.t('novels'),
          unit: L.t('unitChapter'),
        ),
        const SizedBox(height: 14),
        _buildTypeSection(
          theme,
          type: StatType.video,
          icon: Icons.movie_rounded,
          title: L.t('anime'),
          unit: L.t('unitVideo'),
        ),

        // ---- 缓存 ----
        const SizedBox(height: 20),
        _sectionTitle(theme, L.t('cacheStats')),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      L.t('cacheHitRate'),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  Text(
                    '${_hitRate(st) * 100 ~/ 1}%',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: scheme.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: _hitRate(st),
                  minHeight: 5,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                L.tp('cacheDetail', {
                  'hit': st.cacheHits,
                  'miss': st.cacheMisses,
                  'mb': (st.bytesSaved / 1024 / 1024).toStringAsFixed(1),
                }),
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),

        // ---- 下载与缓存 ----
        const SizedBox(height: 20),
        _sectionTitle(theme, L.t('downloadAndCache')),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 下载任务
              Row(
                children: [
                  Icon(Icons.download_rounded,
                      size: 16, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      L.t('downloadTasks'),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  Text(
                    L.tp('downloadCounts', {
                      'active': ChapterDownloader.activeCount,
                      'done': ChapterDownloader.allTasks
                          .where((t) => t.done)
                          .length,
                    }),
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // 存储占用明细
              ..._storageSlices.map((sl) {
                final pct =
                    _storageTotal <= 0 ? 0.0 : sl.bytes / _storageTotal;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 76,
                        child: Text(
                          L.t(sl.key),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: pct,
                            minHeight: 4,
                            backgroundColor: scheme.surfaceContainerHighest,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 66,
                        child: Text(
                          _fmtBytes(sl.bytes),
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      L.t('storageTotalUsed'),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Text(
                    _fmtBytes(_storageTotal),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        // ---- 收藏 / 历史 ----
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: _statCard(
                theme,
                icon: Icons.favorite_border,
                label: L.t('localFavorites'),
                value: '${AppState.instance.localFavorites.length}',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _statCard(
                theme,
                icon: Icons.history,
                label: L.t('history'),
                value: '${AppState.instance.history.length}',
              ),
            ),
          ],
        ),
      ],
    );
  }

  double _hitRate(ReadingStats st) {
    final t = st.cacheHits + st.cacheMisses;
    return t == 0 ? 0 : st.cacheHits / t;
  }

  String _fmtDur(int sec) {
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    if (h > 0) return '$h${L.t('hoursShort')}$m${L.t('minutesShort')}';
    return '$m${L.t('minutesShort')}';
  }

  Widget _overviewCell(ThemeData theme, String label, String value) {
    final scheme = theme.colorScheme;
    return Column(
      children: [
        Text(
          value,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
            color: scheme.onPrimaryContainer,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: scheme.onPrimaryContainer.withValues(alpha: 0.75),
          ),
        ),
      ],
    );
  }

  /// 单个板块的统计卡片：时长 / 今日 / 本篇数 / 页数 / 7 日曲线
  Widget _buildTypeSection(
    ThemeData theme, {
    required StatType type,
    required IconData icon,
    required String title,
    required String unit,
  }) {
    final scheme = theme.colorScheme;
    final t = ReadingStats.instance.of(type);
    final week = t.last7Days;
    final maxSec = week.fold<int>(1, (a, b) => b.seconds > a ? b.seconds : a);

    // 该板块无任何数据时也显示，只是数值为 0（便于用户知道有这一栏）
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行
          Row(
            children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 四个数字
          Row(
            children: [
              Expanded(
                child: _typeMetric(theme, L.t('totalReadingTime'),
                    _fmtDur(t.seconds)),
              ),
              Expanded(
                child: _typeMetric(theme, L.t('todayReading'),
                    _fmtDur(t.todaySeconds)),
              ),
              Expanded(
                child: _typeMetric(
                    theme, unit, '${t.chapters}'),
              ),
              Expanded(
                child: _typeMetric(
                    theme, L.t('worksRead'), '${t.works.length}'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 7 日曲线
          SizedBox(
            height: 44,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: week.map((d) {
                final hh = maxSec <= 0 ? 0.0 : d.seconds / maxSec;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: FractionallySizedBox(
                              heightFactor: hh.clamp(0.03, 1.0),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: d.seconds > 0
                                      ? scheme.primary
                                          .withValues(alpha: 0.7)
                                      : scheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          d.day.split('-').last,
                          style: TextStyle(
                            fontSize: 8,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _typeMetric(ThemeData theme, String label, String value) {
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 9.5, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }


  Widget _sectionTitle(ThemeData theme, String text) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 14,
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Text(
          text,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }


  Widget _statCard(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required String value,
  }) {
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, size: 22, color: scheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          Text(
            value,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
