import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_log.dart';
import '../core/app_state.dart';
import '../core/collect_store.dart';
import '../core/subscription_store.dart';
import '../core/app_theme.dart';
import '../core/image_cache.dart';
import '../core/jm_service.dart';
import '../core/background_task.dart';
import '../core/models.dart';
import '../core/downloader.dart';
import '../core/share_util.dart';
import '../core/source.dart';
import '../widgets/detail_route.dart';
import '../widgets/app_toast.dart';
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
    _subscribed = SubscriptionStore.instance.isSubscribed(widget.comic.id);
    _followAuthor = CollectStore.instance.isFollowing('author', widget.comic.author.trim());
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 监听本页 route 的动画：Hero 飞行 = 路由正在过渡。
    final anim = ModalRoute.of(context)?.animation;
    if (anim != null && anim != _routeAnim) {
      _routeAnim?.removeListener(_onRouteAnim);
      _routeAnim = anim;
      anim.addListener(_onRouteAnim);
    }
  }

  Animation<double>? _routeAnim;

  void _onRouteAnim() {
    final v = _routeAnim?.value ?? 1.0;
    final flying = v > 0.001 && v < 0.999;
    // 只维护「是否飞行中」（用于 IgnorePointer）。
    //
    // **不再用透明度隐藏 FAB**：二值切换会有「突然出现」的观感，
    // 渐变又晚一帧会闪。真正的解法是交给 Hero 的 placeholderBuilder —
    // Hero 飞行时自动用占位替换源控件，落位后恢复，
    // 时机完全由框架控制，没有一帧误差。
    if (flying != _heroFlying) {
      if (!mounted) return;
      setState(() => _heroFlying = flying);
    }
  }

  @override
  void dispose() {
    _routeAnim?.removeListener(_onRouteAnim);
    super.dispose();
  }

  /// 是否已订阅该作品的更新
  bool _subscribed = false;

  /// Hero 是否正在飞行（飞行期间隐藏 FAB，避免被飞行层遮挡）
  bool _heroFlying = false;


  /// 切换订阅：订阅后 App 会定期检查新章节并推送系统通知。
  Future<void> _toggleSubscribe() async {
    HapticFeedback.lightImpact();
    final id = widget.comic.id;
    if (_subscribed) {
      await SubscriptionStore.instance.unsubscribe(id);
      if (!mounted) return;
      setState(() => _subscribed = false);
      _toast(L.t('unsubscribed'), icon: Icons.notifications_off_outlined);
      return;
    }
    final chapters = _info?.chapters ?? const <Chapter>[];
    await SubscriptionStore.instance.subscribe(
      Subscription(
        comicId: id,
        name: _comic.name,
        cover: _cover ?? '',
        source: widget.source.id,
        // 以当前章节数为基线，之后变多了才通知
        chapterCount: chapters.length,
        lastChapterId: chapters.isEmpty ? '' : chapters.last.id,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (!mounted) return;
    setState(() => _subscribed = true);
    _toast(L.t('subscribed'), icon: Icons.notifications_active_rounded);
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
        _liked = info.comic.liked || info.liked;
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
  /// 详情页右下角按钮。
  ///
  /// **自绘静态容器**（不用 FloatingActionButton）：
  /// FAB 内部有 splash / elevation / scale 的自带动画，
  /// Hero 落位、真控件第一次上屏时会把这些动画播一遍 → 闪烁。
  /// 静态容器没有入场动画，落位即最终态。
  ///
  /// 几何与列表侧圆钮对齐（高 56、圆角 16），两端尺寸一致，
  /// Hero 飞行时不会出现尺寸突变。
  Widget _buildDetailFab() {
    final scheme = Theme.of(context).colorScheme;
    // 只有章节已加载且非空时才可点。
    // 章节没回来之前按钮是「禁用态」（灰化 + 不响应），
    // 避免「点了没反应，加载完才突然跳走」。
    final ready = _info != null && (_info!.chapters.isNotEmpty);
    return Material(
      color: ready
          ? scheme.primaryContainer
          : scheme.primaryContainer.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(16),
      elevation: 6,
      shadowColor: Colors.black45,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: ready ? _enterReading : null,
        child: SizedBox(
          height: 56,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (!ready)
                  // 未就绪：显示小转圈而不是播放图标，
                  // 让用户明确知道「正在准备」而非「按钮坏了」
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.onPrimaryContainer,
                    ),
                  )
                else
                  Icon(
                    Icons.play_arrow,
                    size: 20,
                    color: scheme.onPrimaryContainer,
                  ),
                const SizedBox(width: 6),
                Text(
                  _fabLabel,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.onPrimaryContainer.withValues(
                      alpha: ready ? 1 : 0.6,
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

  /// 进入阅读：
  /// - 若用户在选集中手动选过章节（_selectedChapter 非默认续读项），播放该话；
  /// - 否则按上次进度续读；无记录则第 1 话第 1 页。
  Future<void> _enterReading() async {
    // 章节还没加载完 → 这里不该被触发（按钮此时是禁用态）。
    // 之前是「先 await _load() 再跳转」，用户点了没反应、
    // 直到加载完成才突然跳走 —— 现在改成按钮禁用，
    // 点击要么立即跳，要么明确不可点。
    if (_info == null) return;
    final chapters = _info?.chapters ?? const <Chapter>[];
    if (chapters.isEmpty) return;

    final last = AppState.instance.lastReadFor(_comic.id);

    // 用户主动选了某话 → 播该话
    if (_userPickedChapter) {
      await _openReader(_selectedChapter);
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
    await _openReader(chapterIndex, startPage: page);
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

  /// 轻提示：走自绘 Toast（有入场/出场动画，不顶 FAB、不排队）。
  void _toast(String msg, {IconData? icon, Color? accent}) {
    if (!mounted) return;
    AppToast.show(context, msg, icon: icon, accent: accent);
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

    // ---- 1) 本地优先：立即生效（离线也能用，永远"成功"）----
    setState(() => _fav = target);
    await AppState.instance.setLocalFavorite(
      {
        'id': _comic.id,
        'name': _comic.name,
        'author': _comic.author,
        'cover': _cover,
        'source': widget.source.id,
        'update_at': _comic.updateAt,
        'pendingSync': AppState.instance.loggedIn && target,
      },
      target,
    );
    if (!mounted) return;
    _toast(
      target ? L.t('favorited') : L.t('unfavorited'),
      icon: target ? Icons.favorite_rounded : Icons.favorite_border_rounded,
      accent: target ? const Color(0xFFFF6B81) : null,
    );

    // ---- 2) 云端同步（幂等 + 失败入队重试）----
    //
    // 关键点：云端接口是**切换**语义，直接重发可能把状态翻反。
    // 所以统一走 setFavorite（读状态 → 必要时切一次 → 回读校验）。
    // 取消收藏失败时**必须入队**，否则本地删了、云端还在，
    // 下次刷新就"复活"，用户会认为移除没生效。
    if (AppState.instance.loggedIn && widget.source.id == 'jm') {
      unawaited(() async {
        final r = await JmService.instance.setFavorite(
          _comic.id,
          target: target,
        );
        if (r.ok) {
          await AppState.instance.markFavoriteSynced(_comic.id);
          await AppState.instance.dequeueUnfavorite(_comic.id);
          return;
        }
        // 失败：留痕 + 入队等重试
        unawaited(AppLog.instance.log(
          'FAV',
          'setFavorite($target) failed id=${_comic.id} err=${r.error}',
        ));
        print('[JMOE] favorite sync failed: ${r.error}');
        if (!target) {
          // 取消收藏失败 → 进重试队列
          await AppState.instance.queueUnfavorite(_comic.id);
        }
      }());
    }
  }

  Future<void> _openReader(int index, {int startPage = 1}) async {
    final chapters = _info?.chapters ?? const <Chapter>[];
    if (chapters.isEmpty) return;
    // 离线模式：优先打开已下载的该章（本地文件），不发起网络请求。
    // 依然复用 UnifiedReaderPage（只是数据源换成磁盘），
    // 界面与在线完全一致。
    if (AppState.instance.offlineMode) {
      final ch = chapters[index.clamp(0, chapters.length - 1)];
      unawaited(_openLocal(ch, startPage: startPage));
      return;
    }
    await Navigator.of(context).push(
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
    // **阅读器返回后刷新本页状态**（只是 setState 重建 UI，
    // 不会重新拉取元数据 —— _load() 只在 initState 里调用）。
    //
    // 之前这里没有 await，push 后立刻走完 —— 用户在阅读器里翻到
    // 第 3 话再退出，详情页不重建：章节列表选中的还是进去前那一话、
    // FAB 文案还是「开始阅读」。这两处都读 AppState.lastReadFor()，
    // 数据变了但没人通知 UI。
    if (!mounted) return;
    final last = AppState.instance.lastReadFor(_comic.id);
    if (last == null) return;
    final i = chapters.indexWhere((c) => c.id == last.chapterId);
    if (i < 0) return;
    setState(() => _selectedChapter = i);
  }

  /// 打开本地已下载章节。
  ///
  /// **复用在线阅读器**（用户明确要求）：不再弹独立的 OfflineReaderPage，
  /// 而是把 localDir 交给 UnifiedReaderPage，界面/手势/进度全部一致。
  Future<void> _openLocal(Chapter ch, {int startPage = 1}) async {
    final local = await ChapterDownloader.localPages(
      widget.source.id,
      ch.id,
    );
    if (!mounted) return;
    if (local == null) {
      _toast(L.t('offlineEmpty'));
      return;
    }
    final chapters = _info?.chapters ?? const <Chapter>[];
    final idx = chapters.indexWhere((c) => c.id == ch.id);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UnifiedReaderPage(
          source: widget.source,
          comic: _comic,
          chapters: chapters.isEmpty ? [ch] : chapters,
          initialIndex: idx < 0 ? 0 : idx,
          initialPage: startPage,
          albumName: _comic.name,
          localDir: local.dir,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      // body 用 Stack：把 FAB 放在内容之上、同一渲染树里，
      // 这样 Hero 转场时封面飞过也不会盖住按钮。
      body: Stack(
        children: [
          CustomScrollView(
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
          // FAB 作为普通页面内容放在 Stack 末尾（后画的在上层）。
          //
          // 为什么回退掉 OverlayPortal：
          // 详情页按钮：用 Hero（与列表侧圆钮做形变衔接）。
          //
          // 这次**不写 flightShuttleBuilder**，用 Hero 原生行为：
          // Hero 会把目标侧 child 按插值矩形缩放，落位时矩形正好等于
          // child 的自然尺寸 → 缩放比 1.0，理论上零跳变。
          //
          // 之前反复加 FittedBox / 手绘插值 / placeholderBuilder，
          // 都是在覆盖原生行为 —— 反而让「飞行内容」和「真控件」
          // 的几何/阴影对不上，落位必闪。
          // 去掉所有覆盖，交给框架是最稳的。
          Positioned(
            right: 16,
            bottom: 16 + MediaQuery.of(context).padding.bottom,
            child: Hero(
              tag: 'fab_${widget.source.id}_${_comic.id}',
              child: _buildDetailFab(),
            ),
          ),
        ],
      ),
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
        // 订阅更新：有更新时推系统通知
        _RoundBtn(
          icon: _subscribed
              ? Icons.notifications_active
              : Icons.notifications_none,
          color: _subscribed ? theme.colorScheme.primary : null,
          onTap: _toggleSubscribe,
        ),
        _RoundBtn(icon: Icons.share_rounded, onTap: _share),
        const SizedBox(width: 8),
      ],
      flexibleSpace: FlexibleSpaceBar(
        background: ClipRRect(
          // 圆角裁剪：Hero 飞行中详情页从卡片尺寸放大到全屏，
          // 若不加圆角会短暂露出直角
          borderRadius: const BorderRadius.vertical(
            bottom: Radius.circular(16),
          ),
          child: Stack(
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
                        // 飞行层固定用「同一张封面 + 同一个圆角」构造，
                        // 不引用 from/to 任一方的 widget。
                        //
                        // 原因：引用源卡片 widget 时，飞行途中卡片被重建 /
                        // 滚出 cacheExtent / 图片被 LRU 淘汰都会让飞行层失效；
                        // 引用目标 widget 又会被 ClipRRect 的裁剪边界影响。
                        // 独立构造最简单，也永远稳定。
                        flightShuttleBuilder: (ctx, anim, dir, from, to) {
                          final t = Curves.easeInOutCubic.transform(
                            anim.value,
                          );
                          final a = dir == HeroFlightDirection.push
                              ? t
                              : 1 - t;
                          final radius = AppStyle.cardRadius +
                              (10 - AppStyle.cardRadius) * a;
                          return ClipRRect(
                            borderRadius: BorderRadius.circular(radius),
                            child: CachedCover(url: _cover),
                          );
                        },
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
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // 作者名可点击：跳转搜索该作者的作品
                              Flexible(
                                child: GestureDetector(
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
                                            decoration:
                                                TextDecoration.underline,
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
                              ),
                              // 关注作者：之后可在「关注」里快速找到其全部作品
                              const SizedBox(width: 6),
                              GestureDetector(
                                onTap: _toggleFollowAuthor,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _followAuthor
                                        ? theme.colorScheme.primary
                                        : Colors.white24,
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _followAuthor
                                            ? Icons.check_rounded
                                            : Icons.add_rounded,
                                        size: 12,
                                        color: Colors.white,
                                      ),
                                      const SizedBox(width: 3),
                                      Text(
                                        L.t('follow'),
                                        style: const TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
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
    // 点赞 / 评论从「小一号的统计胶囊」提升为**两个大按钮**，
    // 与其它只读统计（浏览量/话数/页数）明确区分开。
    // 之前它们和浏览量长得一样，用户根本不知道能点。
    final items = <Widget>[
      if (info.views > 0)
        _StatChip(
          icon: Icons.visibility_outlined,
          label: '${info.views}',
          scheme: scheme,
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

    // 大按钮行：点赞 + 评论
    final actions = <Widget>[
      if (info.likes > 0 || true)
        Expanded(
          child: _BigAction(
            icon: _liked
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            label: info.likes > 0 ? '${info.likes}' : L.t('likeAction'),
            hint: L.t('likeAction'),
            active: _liked,
            color: const Color(0xFFFF5470),
            scheme: scheme,
            onTap: _toggleLike,
          ),
        ),
      if (widget.source.id == 'jm') ...[
        // 两个按钮之间留足间距（之前紧贴在一起，看起来像一个控件）
        const SizedBox(width: 12),
        Expanded(
          child: _BigAction(
            icon: Icons.forum_rounded,
            label: info.comments > 0 ? '${info.comments}' : L.t('comments'),
            hint: L.t('comments'),
            scheme: scheme,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => CommentPage(aid: _comic.id, title: _comic.name),
              ),
            ),
          ),
        ),
      ],
    ];

    if (items.isEmpty && actions.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 可点击的**大按钮**（点赞 / 评论）：一眼能看出能点
          if (actions.isNotEmpty)
            Row(children: actions),
          if (actions.isNotEmpty && items.isNotEmpty)
            const SizedBox(height: 10),
          // 只读统计（浏览量 / 话数 / 页数）
          if (items.isNotEmpty)
            Wrap(spacing: 8, runSpacing: 8, children: items),
        ],
      ),
    );
  }

  /// 点赞（**后台执行**，退出详情页也继续）。
  ///
  /// 用户要求：
  ///  * 点下去立刻变红（本地先行，不等网络）
  ///  * 即使马上退出详情页，请求也要继续发出
  ///  * 失败时弹 toast，并把红色取消
  ///
  /// 所以请求走 `LikeService`（全局单例，不绑定本页 State），
  /// 这样页面 dispose 后请求照样跑完。失败回调用全局 messenger 提示，
  /// 不依赖本页是否还活着。
  Future<void> _toggleLike() async {
    HapticFeedback.lightImpact();
    final target = !_liked;
    // 1) 立即反馈：按钮变红 + 数字 +/-1
    setState(() {
      _liked = target;
      if (_info != null) {
        final n = _info!.likes + (target ? 1 : -1);
        _info = DetailInfo(
          comic: _info!.comic,
          description: _info!.description,
          tags: _info!.tags,
          chapters: _info!.chapters,
          related: _info!.related,
          totalPages: _info!.totalPages,
          views: _info!.views,
          likes: n < 0 ? 0 : n,
          comments: _info!.comments,
          meta: _info!.meta,
          liked: target,
        );
      }
    });
    // 2) 后台发送（不 await；页面关掉也会继续）
    final albumId = _comic.id;
    final messenger = ScaffoldMessenger.of(context);
    BackgroundTaskService.instance.like(
      albumId,
      onFailed: () {
        // 失败：弹 toast + 把按钮恢复
        messenger.showSnackBar(
          SnackBar(
            content: Text(L.t('likeFailed')),
            behavior: SnackBarBehavior.floating,
          ),
        );
        if (mounted) {
          setState(() {
            _liked = !target;
            if (_info != null) {
              final n = _info!.likes + (target ? -1 : 1);
              _info = DetailInfo(
                comic: _info!.comic,
                description: _info!.description,
                tags: _info!.tags,
                chapters: _info!.chapters,
                related: _info!.related,
                totalPages: _info!.totalPages,
                views: _info!.views,
                likes: n < 0 ? 0 : n,
                comments: _info!.comments,
                meta: _info!.meta,
                liked: !target,
              );
            }
          });
        }
      },
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
        // 作品级数据（多个选集共用一份 album.json）：
        // 这样离线 / 导出后仍有作者、简介、标签，能展示完整详情。
        albumExtra: {
          'author': _comic.author,
          'description': _info?.description ?? '',
          'tags': _info?.tags ?? const <String>[],
          'totalPages': _info?.totalPages ?? 0,
          'chapters': (_info?.chapters ?? const <Chapter>[])
              .map((c) => {'id': c.id, 'name': c.name, 'sort': c.sort})
              .toList(),
        },
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


  /// 章节列表视图：列表 → 并排（两列） → 数字格
  int _chapterView = 0;

  /// 章节排序：false = 第一话到最新（默认），true = 最新到第一话
  bool _chapterDesc = false;

  /// 按当前排序返回章节列表（附带原始索引，供选中态使用）。
  ///
  /// 注意：索引必须跟着走，否则「选中第 3 话」在倒序下会指到别的章。
  List<(int, Chapter)> _sortedChapters() {
    final list = _info?.chapters ?? const <Chapter>[];
    final idx = List<int>.generate(list.length, (i) => i);
    if (_chapterDesc) idx.sort((a, b) => b.compareTo(a));
    return [for (final i in idx) (i, list[i])];
  }

  Widget _buildChapters(ThemeData theme) {
    final sorted = _sortedChapters();
    final total = sorted.length;
    final showCount =
        _chaptersExpanded ? total : (total > 8 ? 8 : total);
    final last = AppState.instance.lastReadFor(_comic.id);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: L.tp('chaptersN', {'n': total}),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 视图切换：列表 → 并排 → 数字格 → 回到列表
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: L.t('chapterView'),
                icon: Icon(
                  switch (_chapterView) {
                    0 => Icons.view_agenda_outlined,
                    1 => Icons.grid_view_rounded,
                    _ => Icons.apps_rounded,
                  },
                  size: 19,
                ),
                onPressed: () => setState(() {
                  _chapterView = (_chapterView + 1) % 3;
                }),
              ),
              // 排序切换：正序 ↔ 倒序
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: _chapterDesc
                    ? L.t('chapterOrderNewest')
                    : L.t('chapterOrderOldest'),
                icon: Icon(
                  _chapterDesc
                      ? Icons.south_rounded
                      : Icons.north_rounded,
                  size: 19,
                ),
                onPressed: () =>
                    setState(() => _chapterDesc = !_chapterDesc),
              ),
              if (total > 8)
                TextButton(
                  onPressed: () =>
                      setState(() => _chaptersExpanded = !_chaptersExpanded),
                  child: Text(
                    _chaptersExpanded ? L.t('collapse') : L.t('expandAll'),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppStyle.pagePadding,
          ),
          // 三种视图各自排布：
          //  0 列表（每行一章，信息最全）
          //  1 并排（两列，行数减半，仍显示章名）
          //  2 数字格（只显示编号，一屏看到最多章节）
          child: _chapterView == 0
              ? Column(
                  children: [
                    for (var i = 0; i < showCount; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: _chapterTile(
                          theme,
                          sorted[i].$2,
                          sorted[i].$1,
                          last?.chapterId,
                        ),
                      ),
                  ],
                )
              : _chapterView == 1
                  ? Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (var i = 0; i < showCount; i++)
                          SizedBox(
                            width: (MediaQuery.of(context).size.width -
                                    AppStyle.pagePadding * 2 -
                                    8) /
                                2,
                            child: _chapterTile(
                              theme,
                              sorted[i].$2,
                              sorted[i].$1,
                              last?.chapterId,
                            ),
                          ),
                      ],
                    )
                  : GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      padding: EdgeInsets.zero,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 6,
                        mainAxisSpacing: 6,
                        crossAxisSpacing: 6,
                        childAspectRatio: 1,
                      ),
                      itemCount: showCount,
                      itemBuilder: (context, i) {
                        final (realIdx, c) = sorted[i];
                        final reading = _selectedChapter == realIdx;
                        return Material(
                          color: reading
                              ? scheme.primary
                              : scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(8),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () => setState(() {
                              _selectedChapter = realIdx;
                              _userPickedChapter = true;
                            }),
                            child: Center(
                              child: Text(
                                '${c.sort > 0 ? c.sort : realIdx + 1}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: reading
                                      ? scheme.onPrimary
                                      : scheme.onSurfaceVariant,
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

  /// 是否已关注该作者
  bool _followAuthor = false;

  /// 关注 / 取消关注作者。
  ///
  /// 关注后可在「关注」页点该作者，直接看他的全部作品；
  /// 也能在订阅检查里收到该作者的更新通知。
  Future<void> _toggleFollowAuthor() async {
    HapticFeedback.lightImpact();
    final a = _comic.author.trim();
    if (a.isEmpty) return;
    await CollectStore.instance.toggleFollow('author', a);
    if (!mounted) return;
    setState(() {
      _followAuthor = CollectStore.instance.isFollowing('author', a);
    });
    _toast(
      _followAuthor ? L.t('followed') : L.t('unfollowed'),
      icon: _followAuthor
          ? Icons.person_add_alt_1_rounded
          : Icons.person_remove_rounded,
    );
  }

  /// 该书是否已被标记为书签。  ///
  /// 书签与「阅读进度 / 收藏」都不同：它标记的是**这一话很精彩**，
  /// 用户可以在书签总览里一眼找回，不必记得话号。
  bool _isBookmarked(Chapter c) =>
      AppState.instance.isChapterBookmarked(_comic.id, c.id);

  Future<void> _toggleChapterBookmark(Chapter c) async {
    HapticFeedback.lightImpact();
    final on = !_isBookmarked(c);
    await AppState.instance.setChapterBookmark(
      comicId: _comic.id,
      chapterId: c.id,
      comicName: _comic.name,
      chapterName: c.hasName
          ? c.name
          : L.tp('episodeN', {'n': c.sort > 0 ? c.sort : 1}),
      cover: _cover ?? '',
      source: widget.source.id,
      on: on,
    );
    if (!mounted) return;
    setState(() {});
    _toast(
      on ? L.t('bookmarkAdded') : L.t('bookmarkRemoved'),
      icon: on ? Icons.bookmark_added_rounded : Icons.bookmark_remove_outlined,
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
              // 书签：标记「这一话很精彩」，可在书签总览里快速找回
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => _toggleChapterBookmark(c),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    _isBookmarked(c)
                        ? Icons.bookmark_rounded
                        : Icons.bookmark_border_rounded,
                    size: 17,
                    color: _isBookmarked(c)
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
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
              // 行尾不再放 ✓/○：整行背景色 + 文字加粗已经能区分
              // 「当前选中」与其它，再加一个圆圈图标是重复信息。
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
                    detailRoute(builder: (_) => UnifiedDetailPage(
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

/// 详情页的大号操作按钮（点赞 / 评论）。
///
/// 与 [_StatChip]（只读统计）刻意做成不同视觉：
///  * 更大：高 44，圆角 12，占满一半宽度
///  * 有底色 + 描边 → 看起来就是「按钮」
///  * 带文字提示（点赞 / 评论），而不只是一个数字
/// 这样用户一眼就知道这两处能点，不会像之前那样误以为只是统计数字。
class _BigAction extends StatelessWidget {
  const _BigAction({
    required this.icon,
    required this.label,
    required this.hint,
    required this.scheme,
    this.active = false,
    this.color,
    this.onTap,
  });

  final IconData icon;
  final String label;

  /// 按钮下方的动作名（点赞 / 评论）
  final String hint;
  final ColorScheme scheme;
  final bool active;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final accent = color ?? scheme.primary;
    final fg = active ? accent : scheme.onSurface;
    // 圆角 22（接近胶囊）：比之前的 12 明显更圆润
    const radius = 22.0;
    return Material(
      color: active
          ? accent.withValues(alpha: 0.12)
          : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: onTap,
        child: Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: active
                  ? accent.withValues(alpha: 0.5)
                  : scheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 19, color: fg),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  '$hint $label',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 只读统计胶囊（浏览量 / 话数 / 页数）。
///
/// 刻意做得比 [_BigAction] 小且无描边：它们是信息而非操作。
class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final ColorScheme scheme;

  const _StatChip({
    required this.icon,
    required this.label,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
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
            color: scheme.onSurfaceVariant,
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
    );
  }
}
