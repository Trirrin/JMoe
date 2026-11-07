import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/app_theme.dart';
import '../core/image_cache.dart';
import '../core/jm_service.dart';
import '../core/models.dart';
import '../core/downloader.dart';
import '../core/share_util.dart';
import '../core/source.dart';
import '../widgets/common_widgets.dart';
import '../widgets/tag_chip.dart';
import 'comment_page.dart';
import 'search_page.dart';
import 'unified_reader_page.dart';
import '../core/l10n.dart';

/// 统一详情页：JM 与 e-hentai 共用同一套布局与交互。
class UnifiedDetailPage extends StatefulWidget {
  final ComicSource source;
  final Comic comic;

  /// 列表页卡片的 Hero tag（转场起点）。为空则用默认 tag。
  final String? coverTag;

  const UnifiedDetailPage({
    super.key,
    required this.source,
    required this.comic,
    this.coverTag,
});

  @override
  State<UnifiedDetailPage> createState() => _UnifiedDetailPageState();
}

class _UnifiedDetailPageState extends State<UnifiedDetailPage> {
  DetailInfo? _info;
  bool _loading = true;
  String? _error;
  bool _fav = false;
  bool _descExpanded = false;
  bool _chaptersExpanded = false;

  /// 当前选中的章节索引（仅选中，不播放）
  int _selectedChapter = 0;

  /// 用户是否在选集中主动点选过章节（决定右下角按钮播哪一话）。
  bool _userPickedChapter = false;
  bool _liked = false;

  Comic get _comic => _info?.comic ?? widget.comic;

  /// 作品编号：JM 为纯数字 ID，e-hentai 为画廊 ID。
  String get _serial => _comic.id.replaceFirst('eh:', '');

  /// 复制/分享用的编号：JM 源带 "JM" 前缀，EH 源为纯 gid。
  String get _serialForCopy =>
      widget.source.id == 'jm' ? 'JM$_serial' : _serial;

  @override
  void initState() {
    super.initState();
    // 固定列表页带来的封面，避免详情加载后换址导致闪白
    final c = widget.source.coverOf(widget.comic);
    if (c != null && c.isNotEmpty) _pinnedCover = c;
    _fav = widget.comic.isFavorite ||
        AppState.instance.isLocalFavorite(widget.comic.id);
    _liked = widget.comic.liked;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final info = await widget.source.detail(widget.comic);
      if (!mounted) return;
      setState(() {
        _info = info;
        _loading = false;
        _fav = info.comic.isFavorite || _fav;
        _liked = info.comic.liked;
        // 默认选中：上次阅读的章节，否则第 1 话
        final lastRead = AppState.instance.lastReadFor(_comic.id);
        final idx = info.chapters
            .indexWhere((c) => c.id == (lastRead?.chapterId ?? ''));
        _selectedChapter = idx >= 0 ? idx : 0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 详情加载后服务端可能返回与列表页不同的封面地址，
  /// 直接切换会导致内存缓存命不中、重新解码 → 封面闪白。
  /// 因此：一旦从列表页带来了封面就固定用它，
  /// 除非列表页没有封面才用详情页的。
  String? _pinnedCover;

  String? get _cover {
    final fromList = _pinnedCover;
    if (fromList != null && fromList.isNotEmpty) return fromList;
    return widget.source.coverOf(_comic);
  }

  String get _fabLabel =>
      AppState.instance.lastReadFor(_comic.id) != null
          ? L.t('continueReading')
          : L.t('startReading');

  /// 详情页 FAB 本体：进入即刻显示「开始阅读」，不等章节接口返回。
  ///
  /// 配色固定为 primaryContainer，与 Hero 飞行层一致，
  /// 任何状态下都不变色，只切换文字（开始阅读 / 继续阅读）。
  Widget _buildDetailFab() {
    final scheme = Theme.of(context).colorScheme;
    return FloatingActionButton.extended(
      onPressed: _enterReading,
      backgroundColor: scheme.primaryContainer,
      foregroundColor: scheme.onPrimaryContainer,
      icon: const Icon(Icons.play_arrow),
      label: Text(_fabLabel),
    );
  }

  /// 进入阅读：
  /// - 若用户在选集中手动选过章节（_selectedChapter 非默认续读项），播放该话；
  /// - 否则按上次进度续读；无记录则第 1 话第 1 页。
  Future<void> _enterReading() async {
    if (_info == null) {
      await _load();
      if (!mounted) return;
    }
    final chapters = _info?.chapters ?? const <Chapter>[];
    if (chapters.isEmpty) return;

    final last = AppState.instance.lastReadFor(_comic.id);

    // 用户主动选了某话 → 播该话
    if (_userPickedChapter) {
      _openReader(_selectedChapter);
      return;
    }

    // 按本地阅读记录定位：该话 + 该页；无记录则第 1 话
    var chapterIndex = 0;
    var page = 1;
    if (last != null) {
      final i = chapters.indexWhere((c) => c.id == last.chapterId);
      if (i >= 0) {
        chapterIndex = i;
        page = last.page < 1 ? 1 : last.page;
      }
    }
    _openReader(chapterIndex, startPage: page);
  }

  /// 点击作者：按作者名搜索作品。
  void _searchAuthor(String author) {
    final name = author.trim();
    if (name.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SearchPage(
          embedded: false,
          initialQuery: name,
          initialAsTag: false,
          initialAuthorMode: true,
        ),
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  /// 复制编号。
  Future<void> _copySerial() async {
    await Clipboard.setData(ClipboardData(text: _serialForCopy));
    HapticFeedback.lightImpact();
    _toast('已复制${widget.source.id == 'jm' ? L.t('jmId') : L.t('galleryId')}：$_serial');
  }

  /// 系统分享（文本）。
  Future<void> _share() async {
    final ok = await ShareUtil.shareComic(
      sourceId: widget.source.id,
      serial: _serial,
      name: _comic.name,
      author: _comic.author,
      cover: _cover,
    );
    if (!ok) _toast(L.t('shareFailed'));
  }

  Future<void> _toggleFavorite() async {
    HapticFeedback.lightImpact();
    final target = !_fav;

    // ---- 1) 本地优先：立即生效，保证「百分百成功」 ----
    setState(() => _fav = target);
    await AppState.instance.setLocalFavorite(
      {
        'id': _comic.id,
        'name': _comic.name,
        'author': _comic.author,
        'cover': _cover,
        'source': widget.source.id,
        'update_at': _comic.updateAt,
        'pendingSync': AppState.instance.loggedIn,
      },
      target,
    );
    if (!mounted) return;
    _toast(target ? L.t('addedToShelf') : L.t('removedFromShelf'));

    // ---- 2) 后台同步服务端：失败静默（下次打开书架自动重试）----
    if (AppState.instance.loggedIn && widget.source.id == 'jm') {
      unawaited(() async {
        try {
          await JmService.instance.toggleFavorite(_comic.id);
          await AppState.instance.markFavoriteSynced(_comic.id);
        } catch (_) {
          // 保留 pendingSync，等书架同步时重试
        }
      }());
    }
  }

  void _openReader(int index, {int startPage = 1}) {
    final chapters = _info?.chapters ?? const <Chapter>[];
    if (chapters.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UnifiedReaderPage(
          source: widget.source,
          comic: _comic,
          chapters: chapters,
          initialIndex: index,
          initialPage: startPage,
          albumName: _comic.name,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          _buildHeader(theme),
          if (_loading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyView(
                message: L.tp('loadFailedWith', {'e': '$_error'}),
                icon: Icons.cloud_off_outlined,
                onRetry: _load,
              ),
            )
          else ...[
            SliverToBoxAdapter(child: _buildSerialRow(theme)),
            SliverToBoxAdapter(child: _buildStats(theme)),
            if (_info!.meta.isNotEmpty)
              SliverToBoxAdapter(child: _buildMeta(theme)),
            if (_info!.chapters.isNotEmpty)
              SliverToBoxAdapter(child: _buildChapters(theme)),
            if (_info!.tags.isNotEmpty)
              SliverToBoxAdapter(child: _buildTags(theme)),
            if (_info!.description.isNotEmpty)
              SliverToBoxAdapter(child: _buildDescription(theme)),
            if (_info!.related.isNotEmpty)
              SliverToBoxAdapter(child: _buildRelated(theme)),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ],
      ),
      // 「开始阅读 / 继续阅读」：进入详情页即刻存在（不等章节接口），
      // 通过 Hero 与列表页的回到顶部按钮做形变平移衔接。
      floatingActionButton: Hero(
        tag: 'fab_${widget.source.id}_${_comic.id}',
        flightShuttleBuilder: (context, animation, direction, fromCtx, toCtx) {
          // 形变过程保持不透明，仅做尺寸与圆角插值
          return AnimatedBuilder(
            animation: animation,
            builder: (context, _) {
              final t = Curves.easeInOutCubic.transform(animation.value);
              final isForward = direction == HeroFlightDirection.push;
              final a = isForward ? t : 1 - t;
              // 从圆形小按钮 → 圆角胶囊
              final size = lerpDouble(48, 148, a) ?? 148;
              final radius = lerpDouble(24, 20, a) ?? 20;
              return Opacity(
                opacity: 1,
                child: SizedBox(
                  width: size,
                  height: 48,
                  child: Material(
                    // 与 FloatingActionButton.extended 默认配色保持一致，
                    // 避免转场结束时出现明显的颜色跳变
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(radius),
                    child: Center(
                      child: a > 0.5
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.play_arrow,
                                    size: 18,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onPrimaryContainer),
                                const SizedBox(width: 4),
                                Text(
                                  _fabLabel,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onPrimaryContainer,
                                  ),
                                ),
                              ],
                            )
                          : Icon(Icons.arrow_upward_rounded,
                              size: 20,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onPrimaryContainer),
                    ),
                  ),
                ),
              );
            },
          );
        },
        child: _buildDetailFab(),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return SliverAppBar(
      expandedHeight: 300,
      pinned: true,
      stretch: true,
      backgroundColor: theme.colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      leading: _RoundBtn(
        icon: Icons.arrow_back,
        onTap: () => Navigator.of(context).pop(),
      ),
      actions: [
        _RoundBtn(
          icon: _fav ? Icons.favorite : Icons.favorite_border,
          color: _fav ? theme.colorScheme.error : null,
          onTap: _toggleFavorite,
        ),
        _RoundBtn(icon: Icons.share_rounded, onTap: _share),
        const SizedBox(width: 8),
      ],
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: [
            CachedCover(url: _cover),
            BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(color: Colors.black26),
            ),
            // 渐变过渡到「与下方信息区相同的底色」，
            // 避免头部黑底与内容区浅底之间出现生硬分界线
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.55),
                    theme.colorScheme.surface,
                  ],
                  stops: const [0.35, 0.82, 1],
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  SizedBox(
                    width: 92,
                    height: 122,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black45,
                            blurRadius: 12,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Hero(
                        tag: widget.coverTag ??
                            'cover_${widget.source.id}_${_comic.id}',
                        // 不指定 memCacheWidth：与列表页共用同一份内存缓存，
                        // 避免 Hero 结束后因解码尺寸不同而重新加载导致封面闪白。
                        child: CachedCover(
                          url: _cover,
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _comic.name,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 6),
                        if (_comic.author.isNotEmpty)
                          // 作者名可点击：跳转搜索该作者的作品
                          GestureDetector(
                            onTap: () => _searchAuthor(_comic.author),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    _comic.author,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                      color: Colors.white,
                                      decoration: TextDecoration.underline,
                                      decorationColor: Colors.white54,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                const Icon(
                                  Icons.chevron_right_rounded,
                                  size: 14,
                                  color: Colors.white54,
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            // 页数占位：加载完成前先用等宽占位符撑住位置，
                            // 避免数据到达后「突然多出一个 pill」把文字挤动。
                            if (_info == null)
                              Opacity(
                                opacity: 0.35,
                                child: _pill(
                                  L.tp('pagesN', {'n': '—'}),
                                  theme,
                                  subtle: true,
                                ),
                              )
                            else if (_info!.totalPages > 0)
                              _pill(
                                L.tp('pagesN', {'n': _info!.totalPages}),
                                theme,
                                subtle: true,
                              ),
                            if (widget.source.id == 'ehentai')
                              _pill('E-Hentai', theme, subtle: true),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 编号行：显示 JM 号 / EH ID，点击复制，右侧可跳搜索。
  Widget _buildSerialRow(ThemeData theme) {
    final scheme = theme.colorScheme;
    final isJm = widget.source.id == 'jm';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Row(
        children: [
          InkWell(
            onTap: _copySerial,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    // JM 用 # 标签图标；EH 用链接图标
                    isJm ? Icons.tag : Icons.link_rounded,
                    size: 14,
                    color: scheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    isJm ? 'JM$_serial' : _serial,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Icon(
                    Icons.copy_rounded,
                    size: 12,
                    color: scheme.onPrimaryContainer.withValues(alpha: 0.7),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pill(String text, ThemeData theme, {bool subtle = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: subtle
            ? Colors.white.withValues(alpha: 0.22)
            : theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: subtle ? Colors.white : theme.colorScheme.onPrimary,
        ),
      ),
    );
  }

  Widget _buildStats(ThemeData theme) {
    final scheme = theme.colorScheme;
    final info = _info!;
    final items = <Widget>[
      if (info.views > 0)
        _StatChip(
          icon: Icons.visibility_outlined,
          label: '${info.views}',
          scheme: scheme,
        ),
      if (info.likes > 0)
        _StatChip(
          icon: Icons.favorite_outline,
          label: '${info.likes}',
          scheme: scheme,
          active: _liked,
        ),
      if (info.comments > 0)
        _StatChip(
          icon: Icons.chat_bubble_outline,
          label: '${info.comments}',
          scheme: scheme,
          onTap: widget.source.id == 'jm'
              ? () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          CommentPage(aid: _comic.id, title: _comic.name),
                    ),
                  )
              : null,
        ),
      if (info.chapters.length > 1)
        _StatChip(
          icon: Icons.menu_book_outlined,
          label: L.tp('episodesN', {'n': info.chapters.length}),
          scheme: scheme,
        ),
      if (info.totalPages > 0)
        _StatChip(
          icon: Icons.photo_library_outlined,
          label: L.tp('pagesN', {'n': info.totalPages}),
          scheme: scheme,
        ),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Wrap(spacing: 8, runSpacing: 8, children: items),
    );
  }

  /// e-hentai 等源的元信息（分类/上传者/语言/评分…）。
  Widget _buildMeta(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: _info!.meta
              .map(
                (e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 60,
                        child: Text(
                          e.key,
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          e.value,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  /// 下载整章到本地（带进度弹层）。
  /// 正在下载的章节 id 集合（用于即时反馈图标状态）
  final Set<String> _downloading = {};

  /// 下载单章：点击立即反馈，随后后台下载。
  Future<void> _downloadChapter(int index) async {
    final chapters = _info?.chapters ?? const <Chapter>[];
    if (index < 0 || index >= chapters.length) return;
    final ch = chapters[index];

    // ---- 1) 立刻反馈：图标转圈 + 轻提示 ----
    if (_downloading.contains(ch.id)) return;
    setState(() => _downloading.add(ch.id));
    HapticFeedback.selectionClick();
    _toast(L.t('downloadStarted'));

    try {
      // ---- 2) 准备数据（这一步可能慢，但用户已看到反馈） ----
      final bundle = await widget.source.read(_comic, ch);
      if (bundle.length == 0) {
        _toast(L.t('noImages'));
        return;
      }

      // ---- 3) 后台下载：不弹模态框，进度见「下载」页 ----
      final task = ChapterDownloader.start(
        source: widget.source,
        albumName: _comic.name,
        bundle: bundle,
        albumId: _comic.id,
        chapterName: ch.name,
        coverUrl: _cover,
      );

      // 监听完成（用轮询，简单可靠）
      unawaited(() async {
        while (!task.done) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          if (!mounted) return;
        }
        if (!mounted) return;
        setState(() => _downloading.remove(ch.id));
        _toast(
          task.error == null
              ? L.t('downloadDone')
              : L.tp('downloadFailedWith', {'e': task.error ?? ''}),
        );
      }());
    } catch (e) {
      if (mounted) setState(() => _downloading.remove(ch.id));
      _toast(L.tp('downloadFailedWith', {'e': '$e'}));
    }
  }


  Widget _buildChapters(ThemeData theme) {
    final list = _info!.chapters;
    final showCount =
        _chaptersExpanded ? list.length : (list.length > 8 ? 8 : list.length);
    final last = AppState.instance.lastReadFor(_comic.id);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: L.tp('chaptersN', {'n': list.length}),
          trailing: list.length > 8
              ? TextButton(
                  onPressed: () =>
                      setState(() => _chaptersExpanded = !_chaptersExpanded),
                  child: Text(_chaptersExpanded ? L.t('collapse') : L.t('expandAll')),
                )
              : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppStyle.pagePadding),
          child: Column(
            children: [
              for (var i = 0; i < showCount; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _chapterTile(theme, list[i], i, last?.chapterId),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _chapterTile(
    ThemeData theme,
    Chapter c,
    int index,
    String? lastChapterId,
  ) {
    final scheme = theme.colorScheme;
    final reading = _selectedChapter == index;
    return Material(
      color: reading
          ? scheme.primaryContainer.withValues(alpha: 0.6)
          : scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() {
          _selectedChapter = index;
          _userPickedChapter = true;
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color:
                      reading ? scheme.primary : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${c.sort > 0 ? c.sort : index + 1}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: reading ? scheme.onPrimary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  c.hasName ? c.name : L.tp('episodeN', {'n': c.sort > 0 ? c.sort : index + 1}),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: reading ? FontWeight.w600 : FontWeight.w400,
                    color: reading ? scheme.onPrimaryContainer : null,
                  ),
                ),
              ),
              // 单话下载
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => _downloadChapter(index),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    Icons.download_outlined,
                    size: 17,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                reading ? Icons.check_circle_rounded : Icons.circle_outlined,
                size: reading ? 20 : 18,
                color: reading ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 标签区：pixiv 风格胶囊标签（实心底色 + 全圆角），点击直接跳转搜索。
  Widget _buildTags(ThemeData theme) {
    final scheme = theme.colorScheme;
    final tags = _info!.tags;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: L.tp('tagsN', {'n': tags.length})),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: AppStyle.pagePadding),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: tags
                .map(
                  (t) => TagChip(
                    tag: t,
                    onTap: () {
                      // 直接打开搜索页并带上关键词：
                      // 不能只 pop + requestSearch —— 搜索页可能不在路由栈上，
                      // 那样点击后只会回到列表，看不到搜索结果。
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SearchPage(
                            embedded: false,
                            initialQuery: t,
                            initialAsTag: true,
                          ),
                        ),
                      );
                    },
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildDescription(ThemeData theme) {
    final text = _info!.description;
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: L.t('intro')),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: AppStyle.pagePadding),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                text,
                maxLines: _descExpanded ? null : 5,
                overflow: _descExpanded ? null : TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, height: 1.75),
              ),
              if (text.length > 160)
                GestureDetector(
                  onTap: () => setState(() => _descExpanded = !_descExpanded),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _descExpanded ? L.t('collapse') : L.t('expandAll'),
                      style: TextStyle(fontSize: 12, color: scheme.primary),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRelated(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: L.t('relatedRecommend')),
        SizedBox(
          height: 196,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _info!.related.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final c = _info!.related[i];
              return SizedBox(
                width: 110,
                child: ComicCard(
                  title: c.name,
                  subtitle: c.author,
                  cover: widget.source.coverOf(c),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => UnifiedDetailPage(
                        source: widget.source,
                        comic: c,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _RoundBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color? color;

  const _RoundBtn({required this.icon, required this.onTap, this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Material(
        color: Colors.black.withValues(alpha: 0.35),
        shape: const CircleBorder(),
        child: IconButton(
          iconSize: 20,
          visualDensity: VisualDensity.compact,
          icon: Icon(icon, color: color ?? Colors.white),
          onPressed: onTap,
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final ColorScheme scheme;
  final bool active;
  final VoidCallback? onTap;

  const _StatChip({
    required this.icon,
    required this.label,
    required this.scheme,
    this.active = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: active ? scheme.error : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

