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
import '../core/detail_cache.dart';
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

class UnifiedDetailPage extends StatefulWidget {
  final ComicSource source;
  final Comic comic;

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

  int _selectedChapter = 0;

  bool _userPickedChapter = false;
  bool _liked = false;

  Comic get _comic => _info?.comic ?? widget.comic;

  String get _serial => _comic.id.replaceFirst('eh:', '');

  String get _serialForCopy =>
      widget.source.id == 'jm' ? 'JM$_serial' : _serial;

  @override
  void initState() {
    super.initState();
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

  bool _subscribed = false;

  bool _heroFlying = false;

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
    final key = '${widget.source.id}:${widget.comic.id}';
    final cached = DetailCache.instance.get<DetailInfo>(key);
    if (cached != null) {
      DetailCache.instance.touch(key);
      setState(() {
        _info = cached;
        _loading = false;
        _error = null;
        _fav = cached.comic.isFavorite || _fav;
        _liked = cached.comic.liked || cached.liked;
        final lastRead = AppState.instance.lastReadFor(_comic.id);
        final idx = cached.chapters.indexWhere(
          (c) => c.id == (lastRead?.chapterId ?? ''),
        );
        _selectedChapter = idx >= 0 ? idx : 0;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final info = await widget.source.detail(widget.comic);
      if (!mounted) return;
      DetailCache.instance.put(key, info);
      setState(() {
        _info = info;
        _loading = false;
        _fav = info.comic.isFavorite || _fav;
        _liked = info.comic.liked || info.liked;
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

  Widget _buildDetailFab() {
    final scheme = Theme.of(context).colorScheme;
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

  Future<void> _enterReading() async {
    if (_info == null) return;
    final chapters = _info?.chapters ?? const <Chapter>[];
    if (chapters.isEmpty) return;

    final last = AppState.instance.lastReadFor(_comic.id);

    if (_userPickedChapter) {
      await _openReader(_selectedChapter);
      return;
    }

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

  void _toast(String msg, {IconData? icon, Color? accent}) {
    if (!mounted) return;
    AppToast.show(context, msg, icon: icon, accent: accent);
  }

  Future<void> _copySerial() async {
    await Clipboard.setData(ClipboardData(text: _serialForCopy));
    HapticFeedback.lightImpact();
    _toast('已复制${widget.source.id == 'jm' ? L.t('jmId') : L.t('galleryId')}：$_serial');
  }

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
    DetailCache.instance
        .invalidate('${widget.source.id}:${widget.comic.id}');

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
        unawaited(AppLog.instance.log(
          'FAV',
          'setFavorite($target) failed id=${_comic.id} err=${r.error}',
        ));
        print('[JMOE] favorite sync failed: ${r.error}');
        if (!target) {
          await AppState.instance.queueUnfavorite(_comic.id);
        }
      }());
    }
  }

  Future<void> _openReader(int index, {int startPage = 1}) async {
    final chapters = _info?.chapters ?? const <Chapter>[];
    if (chapters.isEmpty) return;
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
    if (!mounted) return;
    final last = AppState.instance.lastReadFor(_comic.id);
    if (last == null) return;
    final i = chapters.indexWhere((c) => c.id == last.chapterId);
    if (i < 0) return;
    setState(() => _selectedChapter = i);
  }

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
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              for (final a in _comic.authorList)
                                GestureDetector(
                                  onTap: () => _searchAuthor(a),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        a,
                                        style: theme.textTheme.labelMedium
                                            ?.copyWith(
                                          color: Colors.white,
                                          decoration:
                                              TextDecoration.underline,
                                          decorationColor: Colors.white54,
                                        ),
                                      ),
                                      const SizedBox(width: 2),
                                      const Icon(
                                        Icons.chevron_right_rounded,
                                        size: 13,
                                        color: Colors.white54,
                                      ),
                                    ],
                                  ),
                                ),
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
          if (actions.isNotEmpty)
            Row(children: actions),
          if (actions.isNotEmpty && items.isNotEmpty)
            const SizedBox(height: 10),
          if (items.isNotEmpty)
            Wrap(spacing: 8, runSpacing: 8, children: items),
        ],
      ),
    );
  }

  Future<void> _toggleLike() async {
    HapticFeedback.lightImpact();
    final target = !_liked;
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
    final albumId = _comic.id;
    final messenger = ScaffoldMessenger.of(context);
    BackgroundTaskService.instance.like(
      albumId,
      onFailed: () {
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

  final Set<String> _downloading = {};

  Future<void> _downloadChapter(int index) async {
    final chapters = _info?.chapters ?? const <Chapter>[];
    if (index < 0 || index >= chapters.length) return;
    final ch = chapters[index];

    if (_downloading.contains(ch.id)) return;
    setState(() => _downloading.add(ch.id));
    HapticFeedback.selectionClick();
    _toast(L.t('downloadStarted'));

    try {
      final bundle = await widget.source.read(_comic, ch);
      if (bundle.length == 0) {
        _toast(L.t('noImages'));
        return;
      }

      final task = ChapterDownloader.start(
        source: widget.source,
        albumName: _comic.name,
        bundle: bundle,
        albumId: _comic.id,
        chapterName: ch.name,
        coverUrl: _cover,
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

  int _chapterView = 0;

  bool _chapterDesc = false;

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

  bool _followAuthor = false;

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
            ],
          ),
        ),
      ),
    );
  }

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

  final String hint;
  final ColorScheme scheme;
  final bool active;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final accent = color ?? scheme.primary;
    final fg = active ? accent : scheme.onSurface;
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
