import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/l10n.dart';
import '../core/reading_stats.dart';
import '../core/storage_manager.dart';
import '../core/downloader.dart';
import '../widgets/reading_calendar.dart';

/// 阅读数据页：只保留**阅读时长统计**。
///
/// 书签 / 批注板块已按需求移除（漫画阅读场景用不到划线批注，
/// 书签也只是多一层噪音）。数据本身仍留在 ReaderStore 里，
/// 万一以后要恢复展示不需要迁移数据。
class ReaderDataPage extends StatefulWidget {
  /// 书籍 id（保留参数位以兼容调用方；当前不影响展示）。
  final String? bookId;

  /// 供外部预热：切到统计页前先把体积数据算好，避免首次进入时
  /// 「先空后满」的跳变与卡顿。
  static final GlobalKey<State<ReaderDataPage>> statsKey =
      GlobalKey<State<ReaderDataPage>>();

  static void precacheNow() {
    final st = statsKey.currentState;
    if (st == null) return;
    // ignore: avoid_dynamic_calls
    (st as dynamic).precacheStorage();
  }

  const ReaderDataPage({super.key, this.bookId});

  @override
  State<ReaderDataPage> createState() => _ReaderDataPageState();
}

class _ReaderDataPageState extends State<ReaderDataPage> {
  /// 存储占用（分类）
  List<StorageSlice> _storageSlices = const [];
  int _storageTotal = 0;

  /// 上次可见性，用于「切回本页时刷新数据」
  bool _lastVisible = true;

  /// 存储明细是否已就绪。
  ///
  /// 之前 `_storageSlices` 一开始是空数组，异步返回后才插入到列表里，
  /// 于是「切到统计页」时会先看到短内容、几十毫秒后又被撑长 ——
  /// 视觉上就是内容「跳一下」。现在未就绪时不渲染该区块（保留固定占位），
  /// 就绪后一次性画出来，不再跳。
  bool _storageReady = false;

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
        _storageReady = true;
      });
    } catch (_) {
      if (mounted) setState(() => _storageReady = true);
    }
  }

  /// 供外部预热调用（见 [ReaderDataPage.precacheNow]）。
  Future<void> precacheStorage() => _loadStorage();

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Offstage 会切换 TickerMode；从隐藏变为可见时刷新一次
    final visible = TickerMode.of(context);
    if (visible && !_lastVisible) {
      // 让出一帧再刷新，避免 build 期间 setState
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
    _lastVisible = visible;
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      // 刷新按钮已移除：本页为统计展示，进入/切回即刷新，手上不需要按钮。
      appBar: AppBar(title: Text(L.t('readingStats'))),
      body: RefreshIndicator(
        onRefresh: () async => setState(() {}),
        edgeOffset: MediaQuery.of(context).padding.top,
        child: _buildStats(theme),
      ),
    );
  }

  Widget _buildStats(ThemeData theme) {
    final scheme = theme.colorScheme;
    final st = ReadingStats.instance;

    return ListView(
      key: const PageStorageKey('stats_scroll'),
      // 可下拉刷新：内容不满一屏时也能拉
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
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

        // ---- 阅读日历 ----
        //
        // 三个板块合并展示：每天读了多少时间一目了然。
        // 圆形格子 + 颜色深浅表示活跃度，与签到日历风格一致。
        const SizedBox(height: 20),
        _sectionTitle(theme, L.t('readingCalendar')),
        const SizedBox(height: 8),
        ReadingCalendar(daily: st.mergedDaily),

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
              // 下载与离线资源
              Row(
                children: [
                  Icon(Icons.download_rounded,
                      size: 16, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      L.t('offlineResourceStats'),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // 离线资源明细：下载章节 / 导入包 / 小说缓存 / 视频缓存。
              // 用户要求「统计也需要计算离线资源」——
              // 之前这一块只统计在线阅读，离线看的内容完全不计入。
              Builder(
                builder: (context) {
                  final tasks = ChapterDownloader.allTasks;
                  final doneChapters =
                      tasks.where((t) => t.done).length;
                  final donePages = tasks
                      .where((t) => t.done)
                      .fold<int>(0, (a, t) => a + t.total);
                  final bytes = ChapterDownloader.totalDownloadBytes();
                  return Text(
                    L.tp('offlineResourceDetail', {
                      'c': '$doneChapters',
                      'p': '$donePages',
                      'mb': (bytes / 1024 / 1024).toStringAsFixed(1),
                    }),
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              // 存储占用明细：未采集完时显示固定高度的占位，
              // 就绪后一次性替换 —— 避免「先短后长」导致的跳变。
              if (!_storageReady)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else
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
              if (_storageReady)
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
