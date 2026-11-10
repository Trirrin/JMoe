import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';

import '../core/app_log.dart';
import '../core/app_state.dart';
import '../core/downloader.dart';
import '../core/favorites_backup.dart';
import '../core/app_theme.dart';
import '../core/jm_service.dart';
import '../core/sync_service.dart';
import '../core/models.dart';
import '../widgets/detail_route.dart';
import '../core/jm_protocol.dart';
import '../widgets/app_toast.dart';
import '../widgets/common_widgets.dart';
import 'anime_player_page.dart';
import 'novel_detail_page.dart';
import 'unified_detail_page.dart';
import 'login_page.dart';
import 'downloads_hub_page.dart';
import 'bookmarks_page.dart';
import 'collect_page.dart';
import 'imported_page.dart';
import 'unified_home_page.dart';
import '../core/l10n.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage>
    with AutomaticKeepAliveClientMixin {
  final _service = JmService.instance;
  final _items = <Comic>[];
  bool _loading = true;

  final Set<String> _cloudIds = {};

  FavSort _favSort = FavSort.recent;

  List<Comic>? _sortedCache;
  FavSort? _sortedCacheFor;
  int _sortedCacheLen = -1;

  List<Comic> get _sortedItems {
    if (_sortedCache != null &&
        _sortedCacheFor == _favSort &&
        _sortedCacheLen == _items.length) {
      return _sortedCache!;
    }
    final list = List<Comic>.from(_items);
    switch (_favSort) {
      case FavSort.recent:
        list.sort((a, b) {
          final at = a.updateAt ?? 0;
          final bt = b.updateAt ?? 0;
          if (at == 0 && bt == 0) return a.name.compareTo(b.name);
          if (at == 0) return 1;
          if (bt == 0) return -1;
          return bt.compareTo(at);
        });
      case FavSort.name:
        list.sort((a, b) => a.name.compareTo(b.name));
      case FavSort.added:
        list.sort((a, b) {
          final ai = AppState.instance.localFavorites.indexWhere(
            (f) => '${f['id']}' == a.id,
          );
          final bi = AppState.instance.localFavorites.indexWhere(
            (f) => '${f['id']}' == b.id,
          );
          final at = ai < 0
              ? 0
              : (AppState.instance.localFavorites[ai]['at'] as num?)
                      ?.toInt() ??
                  0;
          final bt = bi < 0
              ? 0
              : (AppState.instance.localFavorites[bi]['at'] as num?)
                      ?.toInt() ??
                  0;
          if (at == 0 && bt == 0) return 0;
          if (at == 0) return -1;
          if (bt == 0) return 1;
          return bt.compareTo(at);
        });
    }
    _sortedCache = list;
    _sortedCacheFor = _favSort;
    _sortedCacheLen = _items.length;
    return list;
  }

  bool _cloudKnown = false;

  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    AppState.instance.addListener(_onStateChanged);
    _items
      ..clear()
      ..addAll(_localFavoritesAsComics());
    if (_items.isNotEmpty) _loading = false;
    final cached = AppState.instance.cachedCloudIds;
    if (cached.isNotEmpty && AppState.instance.loggedIn) {
      _cloudIds
        ..clear()
        ..addAll(cached);
      _cloudKnown = true;
    }
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!AppState.instance.loggedIn) return;
      unawaited(_syncAndFetch());
    });
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _removeSelected() async {
    final ids = Set<String>.from(_selectedIds);
    final loggedIn = AppState.instance.loggedIn;

    setState(() {
      _items.removeWhere((e) => ids.contains(e.id));
      _selectionMode = false;
      _selectedIds.clear();
    });
    for (final id in ids) {
      final fav = AppState.instance.localFavorites
          .where((f) => '${f['id']}' == id)
          .toList();
      if (fav.isEmpty) continue;
      await AppState.instance.setLocalFavorite(fav.first, false);
    }

    if (!mounted) return;
    var okCount = 0;
    var failCount = 0;
    if (loggedIn) {
      for (final id in ids) {
        final r = await JmService.instance.setFavorite(id, target: false);
        if (r.ok) {
          await AppState.instance.dequeueUnfavorite(id);
          okCount++;
        } else {
          await AppState.instance.queueUnfavorite(id);
          failCount++;
          unawaited(AppLog.instance.log(
            'FAV',
            'remove failed id=$id err=${r.error}',
          ));
        }
      }
    } else {
      okCount = ids.length;
    }

    if (!mounted) return;
    AppToast.show(
      context,
      failCount == 0
          ? L.tp('removedN', {'n': okCount})
          : L.tp('removedPendingSync', {
              'n': okCount,
              'p': failCount,
            }),
      icon: failCount == 0
          ? Icons.check_circle_rounded
          : Icons.cloud_off_rounded,
      accent: failCount == 0 ? null : Theme.of(context).colorScheme.error,
    );
    if (failCount > 0) await _syncAndFetch();
  }

  String _kindOf(String id) {
    final fav = AppState.instance.localFavorites
        .where((f) => '${f['id']}' == id)
        .toList();
    final t = fav.isEmpty ? '' : '${fav.first['type'] ?? ''}';
    return switch (t) {
      'novel' => L.t('novels'),
      'video' => L.t('anime'),
      _ => L.t('searchComic'),
    };
  }

  List<Comic> _localFavoritesAsComics() {
    return AppState.instance.localFavorites
        .map((fav) => Comic(
              id: '${fav['id'] ?? ''}',
              name: '${fav['name'] ?? ''}',
              author: '${fav['author'] ?? ''}',
              image: '${fav['cover'] ?? ''}',
              source: '${fav['source'] ?? 'jm'}',
              updateAt:
                  fav['update_at'] is int ? fav['update_at'] as int : null,
            ))
        .where((c) => c.id.isNotEmpty)
        .toList();
  }

  static String _normId(String raw) {
    var s = raw.trim();
    if (s.toLowerCase().startsWith('eh:')) s = s.substring(3);
    if (s.toUpperCase().startsWith('JM')) s = s.substring(2);
    s = s.replaceAll(RegExp(r'[^0-9A-Za-z]'), '');
    return s;
  }

  bool _inCloud(String id) => _cloudIds.contains(_normId(id));

  static const int _pageWindow = 3;

  int _totalFavorites = 0;

  int _firstLoadedPage = 1;
  int _lastLoadedPage = 0;

  bool _appendingPage = false;

  Future<void> _maybeAppendPage() async {
    if (_appendingPage) return;
    if (_totalFavorites <= 0) return;
    if (_items.length >= _totalFavorites) return;
    _appendingPage = true;
    try {
      final next = _lastLoadedPage + 1;
      final (list, _) = await _service.fetchFavorites(page: next);
      if (!mounted || !_service.lastFavoritesOk) return;
      if (list.isEmpty) return;
      setState(() {
        _items.addAll(list);
        _lastLoadedPage = next;
        _trimWindow();
      });
    } catch (_) {
    } finally {
      _appendingPage = false;
    }
  }

  void _trimWindow() {
    final pages = _lastLoadedPage - _firstLoadedPage + 1;
    if (pages <= _pageWindow) return;
    const perPage = 20;
    if (_items.length <= perPage) return;
    final drop = _items.take(perPage).length;
    _items.removeRange(0, drop);
    _firstLoadedPage++;
  }

  SyncState _syncState = SyncState.idle;
  String? _syncError;

  bool get _hideListOnFailure =>
      AppState.instance.loggedIn &&
      _syncState == SyncState.failed &&
      !_userPulled;

  bool _userPulled = false;

  Future<void> _load() async {
    setState(() => _loading = true);
    if (!AppState.instance.loggedIn) {
      _cloudIds.clear();
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(_localFavoritesAsComics());
        _loading = false;
      });
      return;
    }
    if (_items.isEmpty) {
      setState(() {
        _items
          ..clear()
          ..addAll(_localFavoritesAsComics());
      });
    }
    await _syncAndFetch();
  }

  Future<void> _forceLogout() async {
    final state = AppState.instance;
    await JmService.instance.logout().catchError((_) => <String, dynamic>{});
    await state.saveSession(null, null);
    JmApi.instance.jwtToken = null;
    JmApi.instance.cookieValue = null;
    if (!mounted) return;
    setState(() {
      _loading = false;
      _syncState = SyncState.failed;
      _syncError = L.t('sessionExpiredRelogin');
      _cloudKnown = false;
      _cloudIds.clear();
      _items
        ..clear()
        ..addAll(_localFavoritesAsComics());
    });
    AppToast.show(
      context,
      L.t('sessionExpiredRelogin'),
      icon: Icons.lock_outline_rounded,
      accent: Theme.of(context).colorScheme.error,
    );
  }

  Future<void> _goLogin() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
    if (mounted) _load();
  }

  Future<void> _uploadToCloud() async {
    if (!AppState.instance.loggedIn) {
      await _goLogin();
      return;
    }
    if (_syncState == SyncState.running) return;
    setState(() {
      _syncState = SyncState.running;
      _syncError = null;
    });

    final cloud = <Comic>[];
    var page = 1;
    while (page <= 20) {
      final (list, total) = await _service.fetchFavorites(page: page);
      if (!_service.lastFavoritesOk) {
        if (_service.lastFavoritesAuthFailed) {
          await _forceLogout();
          if (mounted) {
            AppToast.show(
              context,
              L.t('sessionExpiredRelogin'),
              icon: Icons.lock_outline_rounded,
              accent: Theme.of(context).colorScheme.error,
            );
          }
          return;
        }
        if (!mounted) return;
        setState(() {
          _syncState = SyncState.failed;
          _syncError = L.t('networkError');
        });
        AppToast.show(
          context,
          L.t('syncUploadFailed'),
          icon: Icons.error_outline_rounded,
          accent: Theme.of(context).colorScheme.error,
        );
        return;
      }
      if (list.isEmpty) break;
      cloud.addAll(list);
      if (total > 0 && cloud.length >= total) break;
      page++;
    }
    if (!mounted) return;
    setState(() {
      _cloudIds
        ..clear()
        ..addAll(cloud.map((e) => _normId(e.id)));
      _cloudKnown = true;
    });

    final local = AppState.instance.localFavorites;
    final todo = <String>[];
    for (final fav in local) {
      final id = '${fav['id'] ?? ''}';
      if (id.isEmpty) continue;
      final t = '${fav['type'] ?? ''}';
      if (t == 'video') continue;
      if (_inCloud(id)) continue;
      todo.add(id);
    }

    if (todo.isEmpty) {
      if (!mounted) return;
      setState(() => _syncState = SyncState.done);
      print('[JMOE] upload: cloud=${_cloudIds.length} '
          'local=${local.length} todo=0 '
          'sampleCloud=${_cloudIds.take(3).toList()} '
          'sampleLocal=${local.take(3).map((e) => e['id']).toList()}');
      AppToast.show(
        context,
        L.t('syncNothingToUpload'),
        icon: Icons.cloud_done_rounded,
      );
      await _syncAndFetch();
      return;
    }
    print('[JMOE] upload: cloud=${_cloudIds.length} local=${local.length} '
        'todo=${todo.length}');

    var okCount = 0;
    var failCount = 0;
    String? lastErr;
    for (final id in todo) {
      final r = await _service.setFavorite(id, target: true);
      if (r.ok) {
        okCount++;
        await AppState.instance.markFavoriteSynced(id);
        await AppState.instance.dequeueUnfavorite(id);
      } else {
        failCount++;
        lastErr = r.error;
        unawaited(AppLog.instance.log(
          'FAV',
          'upload failed id=$id err=${r.error}',
        ));
        print('[JMOE] upload failed id=$id err=${r.error}');
      }
    }

    if (!mounted) return;
    setState(() {
      _syncState = failCount == 0 ? SyncState.done : SyncState.failed;
      _syncError = lastErr;
    });
    AppToast.show(
      context,
      failCount == 0
          ? L.tp('syncUploadDone', {'n': '$okCount'})
          : L.tp('syncUploadPartial', {
              'ok': '$okCount',
              'fail': '$failCount',
              'e': lastErr ?? '',
            }),
      icon: failCount == 0
          ? Icons.cloud_done_rounded
          : Icons.error_outline_rounded,
      accent: failCount == 0 ? null : Theme.of(context).colorScheme.error,
    );
    await _syncAndFetch();
  }

  Future<void> _syncAndFetch() async {
    setState(() {
      _syncState = SyncState.running;
      _syncError = null;
    });
    try {
      final all = <Comic>[];
      var page = 1;
      var cloudOk = true;
      while (page <= _pageWindow) {
        final (list, total) = await _service.fetchFavorites(page: page);
        if (!_service.lastFavoritesOk) {
          cloudOk = false;
          break;
        }
        if (list.isEmpty) break;
        all.addAll(list);
        _totalFavorites = total;
        if (total > 0 && all.length >= total) break;
        if (list.length < 20) break;
        page++;
      }
      _firstLoadedPage = 1;
      _lastLoadedPage = page;
      if (!mounted) return;
      if (_service.lastFavoritesAuthFailed) {
        await _forceLogout();
        if (!mounted) return;
        return;
      }
      setState(() {
        _items
          ..clear()
          ..addAll(all);
        _cloudIds
          ..clear()
          ..addAll(all.map((e) => _normId(e.id)));
        _cloudKnown = cloudOk;
        final listed = _items.map((e) => _normId(e.id)).toSet();
        for (final fav in AppState.instance.localFavorites) {
          final id = '${fav['id'] ?? ''}';
          if (id.isEmpty || listed.contains(_normId(id))) continue;
          _items.add(
            Comic(
              id: id,
              name: '${fav['name'] ?? ''}',
              author: '${fav['author'] ?? ''}',
              image: '${fav['cover'] ?? ''}',
              source: '${fav['source'] ?? 'jm'}',
              updateAt: fav['update_at'] is int
                  ? fav['update_at'] as int
                  : null,
            ),
          );
        }
        _loading = false;
        _syncState = cloudOk ? SyncState.done : SyncState.failed;
        if (!cloudOk) {
          _syncError = _service.lastFavoritesAuthFailed
              ? L.t('sessionExpiredRelogin')
              : L.t('networkError');
        }
      });
      if (cloudOk) {
        await AppState.instance.saveCloudIdsCache(_cloudIds);
      }
      if (!cloudOk && mounted) {
        AppToast.show(
          context,
          _service.lastFavoritesAuthFailed
              ? L.t('sessionExpiredRelogin')
              : L.t('favoritesPullFailed'),
          icon: Icons.cloud_off_rounded,
          accent: Theme.of(context).colorScheme.error,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _syncState = SyncState.failed;
        _syncError = '$e';
        _cloudKnown = false;
      });
      AppToast.show(
        context,
        L.tp('favoritesPullFailedWith', {'e': '$e'}),
        icon: Icons.cloud_off_rounded,
        accent: Theme.of(context).colorScheme.error,
      );
    }
  }

  Future<void> _pullRefresh() async {
    _userPulled = true;
    await _syncAndFetch();
  }

  Future<void> _exportFavorites() async {
    final favs = AppState.instance.localFavorites;
    if (favs.isEmpty) {
      AppToast.show(context, L.t('noFavorites'));
      return;
    }
    final path = await FavoritesBackup.exportToFile();
    if (!mounted) return;
    if (path == null) {
      AppToast.show(context, L.t('exportFailed'));
      return;
    }
    AppToast.show(
      context,
      L.tp('exportedTo', {'p': _shortPath(path)}),
      icon: Icons.check_circle_rounded,
      actionLabel: L.t('openFolder'),
      onAction: () => ChapterDownloader.openFolder(File(path).parent.path),
    );
  }

  String _shortPath(String p) {
    final i = p.lastIndexOf('/');
    return i >= 0 ? p.substring(i + 1) : p;
  }

  Future<void> _importFavorites() async {
    final path = await FilePickerChannel.pickFile(extensions: ['json']);
    if (!mounted) return;
    if (path == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(L.t('importFavorites')),
        content: Text(L.tp('importFavoritesFile', {'p': _shortPath(path)})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(L.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(L.t('import')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final r = await FavoritesBackup.importFromPickedFile(path);
    if (!mounted) return;
    AppToast.show(
      context,
      r.ok
          ? L.tp('importedCount', {'n': r.count})
          : (r.error ?? L.t('importFailed')),
      icon: r.ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
      accent: r.ok ? null : Theme.of(context).colorScheme.error,
    );
    if (r.ok) await _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final state = AppState.instance;
    final bgPath = state.customBackground;
    final body = SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _pullRefresh,
          edgeOffset: MediaQuery.of(context).padding.top,
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.axis == Axis.vertical) {
                final remain =
                    n.metrics.maxScrollExtent - n.metrics.pixels;
                if (remain < n.metrics.viewportDimension * 1.5) {
                  unawaited(_maybeAppendPage());
                }
              }
              return false;
            },
            child: CustomScrollView(
              key: const PageStorageKey('library_scroll'),
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              slivers: [
              SliverAppBar(
                pinned: true,
                backgroundColor: theme.colorScheme.surface,
                title: Text(
                  _selectionMode
                      ? L.tp('selectedOfN', {
                          'n': '${_selectedIds.length}',
                          't': '${_items.length}',
                        })
                      : L.t('tabShelf'),
                ),
                actions: [
                  if (_selectionMode) ...[
                    IconButton(
                      tooltip: L.t('invertSelection'),
                      icon: const Icon(Icons.flip_to_back_rounded),
                      onPressed: () {
                        setState(() {
                          final all = _items.map((e) => e.id).toSet();
                          final next = all.difference(_selectedIds);
                          _selectedIds
                            ..clear()
                            ..addAll(next);
                        });
                      },
                    ),
                    IconButton(
                      tooltip: L.t('selectAll'),
                      icon: const Icon(Icons.select_all_rounded),
                      onPressed: () {
                        setState(() {
                          _selectedIds
                            ..clear()
                            ..addAll(
                              _items.map((e) => e.id),
                            );
                        });
                      },
                    ),
                    IconButton(
                      tooltip: L.t('delete'),
                      icon: Icon(
                        Icons.delete_outline,
                        color: theme.colorScheme.error,
                      ),
                      onPressed: _selectedIds.isEmpty
                          ? null
                          : _removeSelected,
                    ),
                    IconButton(
                      tooltip: L.t('cancel'),
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        setState(() {
                          _selectionMode = false;
                          _selectedIds.clear();
                        });
                      },
                    ),
                  ] else ...[
                    IconButton(
                      tooltip: L.t('syncNow'),
                      icon: _syncState == SyncState.running
                          ? const SizedBox(
                              width: 17,
                              height: 17,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_upload_outlined, size: 22),
                      onPressed: _syncState == SyncState.running
                          ? null
                          : (state.loggedIn ? _uploadToCloud : _goLogin),
                    ),
                    IconButton(
                      tooltip: L.t('multiSelect'),
                      icon: const Icon(Icons.checklist_rounded),
                      onPressed: () =>
                          setState(() => _selectionMode = true),
                    ),
                  ],
                  const SizedBox(width: 4),
                ],
              ),
              SliverToBoxAdapter(child: _buildEntryGrid(theme, state)),
              if (state.pendingUnfavoriteCount > 0)
                SliverToBoxAdapter(
                  child: _SyncBanner(
                    message: L.tp('pendingUnfavoriteN', {
                      'n': state.pendingUnfavoriteCount,
                    }),
                    onRetry: () async {
                      await SyncService.instance.flushUnfavoriteQueue();
                      if (mounted) await _syncAndFetch();
                    },
                  ),
                ),
              if (_syncState == SyncState.failed && state.loggedIn)
                SliverToBoxAdapter(
                  child: _SyncBanner(
                    message: _syncError ?? L.t('networkError'),
                    onRetry: _pullRefresh,
                  ),
                ),
              SliverToBoxAdapter(
                child: SectionHeader(
                  title: L.t('favorites'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PopupMenuButton<FavSort>(
                        initialValue: _favSort,
                        tooltip: L.t('sort'),
                        icon: const Icon(Icons.sort_rounded, size: 19),
                        onSelected: (v) => setState(() => _favSort = v),
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: FavSort.recent,
                            child: Text(L.t('sortRecentlyUpdated')),
                          ),
                          PopupMenuItem(
                            value: FavSort.added,
                            child: Text(L.t('sortByFavTime')),
                          ),
                          PopupMenuItem(
                            value: FavSort.name,
                            child: Text(L.t('sortByName')),
                          ),
                        ],
                      ),
                      IconButton(
                        tooltip: L.t('importFavorites'),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.file_download_outlined, size: 18),
                        onPressed: _importFavorites,
                      ),
                      IconButton(
                        tooltip: L.t('exportFavorites'),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.file_upload_outlined, size: 18),
                        onPressed: _exportFavorites,
                      ),
                      if (!state.loggedIn)
                        TextButton(
                          onPressed: () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const LoginPage(),
                              ),
                            );
                            _load();
                          },
                          child: Text(L.t('loginSync')),
                        ),
                    ],
                  ),
                ),
              ),
              if (_loading && _items.isEmpty && state.localFavorites.isEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
              if (_hideListOnFailure)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 30, 16, 40),
                    child: EmptyView(
                      message: L.t('favoritesHiddenUntilRefresh'),
                      icon: Icons.cloud_off_rounded,
                      onRetry: _pullRefresh,
                    ),
                  ),
                ),
              if (!_hideListOnFailure && _items.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(40),
                    child: EmptyView(
                      message: L.t('noFavorites'),
                      icon: Icons.favorite_border,
                    ),
                  ),
                ),
              if (!_hideListOnFailure && _items.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.all(AppStyle.pagePadding),
                  sliver: SliverToBoxAdapter(
                    child: LayoutBuilder(
                      builder: (context, box) {
                        const cols = 3;
                        const gap = 8.0;
                        final cardW =
                            (box.maxWidth - gap * (cols - 1)) / cols;
                        return Wrap(
                          spacing: gap,
                          runSpacing: 10,
                          children: [
                            for (final c0 in _sortedItems)
                              SizedBox(
                                width: cardW,
                                child: Builder(
                                  builder: (context) {
                                    final c = c0;
                                    final id = c.id;
                                    final picked =
                                        _selectedIds.contains(id);
                                    final isCloud = state.loggedIn &&
                                        _cloudKnown &&
                                        _inCloud(id);
                                    final isLocalOnly = state.loggedIn &&
                                        (!_cloudKnown ||
                                            !_inCloud(id));
                                    final card = ComicCard(
                                      title: c.name,
                                      subtitle: c.author,
                                      cover: _service.coverUrl(c),
                                      kindTag: _kindOf(id),
                                      cloudTag: isCloud,
                                      localTag: isLocalOnly,
                                      onTap: () {
                                        if (_selectionMode) {
                                          setState(() {
                                            if (picked) {
                                              _selectedIds.remove(id);
                                            } else {
                                              _selectedIds.add(id);
                                            }
                                          });
                                          return;
                                        }
                                        _openFavorite(c);
                                      },
                                      onLongPress: () {
                                        setState(() {
                                          _selectionMode = true;
                                          _selectedIds.add(id);
                                        });
                                      },
                                    );
                                    if (!_selectionMode) return card;
                                    final coverH = cardW * 4 / 3;
                                    return GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () => setState(() {
                                        if (picked) {
                                          _selectedIds.remove(id);
                                        } else {
                                          _selectedIds.add(id);
                                        }
                                      }),
                                      child: Stack(
                                        children: [
                                          Opacity(
                                            opacity: picked ? 1.0 : 0.45,
                                            child: card,
                                          ),
                                          if (picked)
                                            Positioned(
                                              left: 0,
                                              top: 0,
                                              width: cardW,
                                              height: coverH,
                                              child: IgnorePointer(
                                                child: DecoratedBox(
                                                  decoration: BoxDecoration(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                      AppStyle.cardRadius,
                                                    ),
                                                    border: Border.all(
                                                      color: theme
                                                          .colorScheme.primary,
                                                      width: 2.5,
                                                    ),
                                                    color: theme
                                                        .colorScheme.primary
                                                        .withValues(alpha: 0.10),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          Positioned(
                                            right: 6,
                                            top: 6,
                                            child: Container(
                                              width: 20,
                                              height: 20,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: picked
                                                    ? theme.colorScheme.primary
                                                    : Colors.black26,
                                                border: Border.all(
                                                  color: Colors.white,
                                                  width: 1.5,
                                                ),
                                              ),
                                              child: picked
                                                  ? const Icon(
                                                      Icons.check_rounded,
                                                      size: 13,
                                                      color: Colors.white,
                                                    )
                                                  : null,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
            ),
          ),
        ),
    );

    return Scaffold(
      body: bgPath.isEmpty
          ? body
          : Stack(
              children: [
                Positioned.fill(
                  child: Image.file(
                    File(bgPath),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
                Positioned.fill(
                  child: ColoredBox(
                    color: theme.colorScheme.surface.withValues(alpha: 0.72),
                  ),
                ),
                body,
              ],
            ),
    );
  }

  Widget _buildEntryGrid(ThemeData theme, AppState state) {
    final entries = <_Entry>[
      _Entry(
        icon: Icons.download_outlined,
        label: L.t('myDownloads'),
        color: const Color(0xFF009688),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const DownloadsHubPage()),
        ),
      ),
      _Entry(
        icon: Icons.bookmark_rounded,
        label: L.t('bookmarks'),
        color: const Color(0xFFEC407A),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const BookmarksPage()),
        ),
      ),
      _Entry(
        icon: Icons.person_add_alt_1_rounded,
        label: L.t('following'),
        color: const Color(0xFF26A69A),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const CollectPage()),
        ),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: entries
            .map(
              (e) => Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: InkWell(
                    onTap: e.onTap,
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: e.color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        children: [
                          Icon(e.icon, color: e.color, size: 22),
                          const SizedBox(height: 6),
                          Text(
                            e.label,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: e.color,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  void _openFavorite(Comic c) {
    final fav = AppState.instance.localFavorites
        .where((f) => '${f['id']}' == c.id)
        .toList();
    final type = fav.isEmpty ? '' : '${fav.first['type'] ?? ''}';
    switch (type) {
      case 'novel':
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => NovelDetailPage(
              nid: c.id,
              title: c.name,
              cover: c.image,
            ),
          ),
        );
        return;
      case 'video':
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AnimePlayerPage(
              id: c.id,
              title: c.name,
            ),
          ),
        );
        return;
      default:
        Navigator.of(context).push(
          detailRoute(
            builder: (_) => UnifiedDetailPage(
              source: SourceRegistry.current,
              comic: c,
            ),
          ),
        );
    }
  }

}

class _Entry {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  _Entry({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });
}

class _SyncBanner extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _SyncBanner({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(
          color: scheme.errorContainer.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              Icons.cloud_off_rounded,
              size: 16,
              color: scheme.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                L.t('syncFailedRetry'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.3,
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: Text(L.t('retry'), style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }
}
enum FavSort {
  recent,

  name,

  added,
}
