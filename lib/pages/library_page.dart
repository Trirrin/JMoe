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
import 'novel_pages.dart';
import 'unified_detail_page.dart';
import 'login_page.dart';
import 'downloads_page.dart';
import 'bookmarks_page.dart';
import 'collect_page.dart';
import 'imported_page.dart';
import 'unified_home_page.dart';
import '../core/l10n.dart';

/// 「书架」：收藏（云端/本地）+ 历史 + 入口集合。
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

  /// 最近一次从云端拉到的收藏 ID 集合。
  /// 用来区分「已上云」与「仅本地」两种角标。
  final Set<String> _cloudIds = {};

  /// 收藏排序方式（最近更新 / 名称）
  FavSort _favSort = FavSort.recent;

  /// 按当前排序返回列表副本（缓存结果，避免每帧重排）。
  ///
  /// 之前是 getter 每次 build 都重新 sort：虽然结果一致，但会新建 List，
  /// 导致 Wrap 每次都是全新 children —— 列表位置轻微跳动、图片重复绑定。
  /// 现在缓存起来，只在数据或排序方式变化时重算。
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
        // 有更新时间的按时间倒序排在前面，没有的（如本地新增）放后面
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
        // 按「加入收藏的时间」倒序（最近收藏的在前）。
        // 云端列表本身就按收藏时间返回，所以保持原顺序即可；
        // 本地新增的收藏没有 at 字段时排在最前（刚加的）。
        list.sort((a, b) {
          final ai = AppState.instance.localFavorites.indexWhere(
            (f) => '${f['id']}' == '${a.id}',
          );
          final bi = AppState.instance.localFavorites.indexWhere(
            (f) => '${f['id']}' == '${b.id}',
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

  /// 云端列表是否**成功**拉取过。
  ///
  /// 只有成功拉到才能判断某条是否在云端。拉取失败（未登录 / 401 / 断网）
  /// 时 `_cloudIds` 是空的，若照常判断就会把所有条目都标成「本地」——
  /// 用户看到的「这几个漫画都没上云吗，为啥都显示本地」正是这个原因。
  bool _cloudKnown = false;

  /// 多选模式（长按进入）
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    AppState.instance.addListener(_onStateChanged);
    // 同步灌入本地收藏，保证首帧就有内容（不等 _load 异步完成）
    _items
      ..clear()
      ..addAll(_localFavoritesAsComics());
    if (_items.isNotEmpty) _loading = false;
    // **先用上次缓存的云端 id 预填角标**：
    // 否则首帧只能把全部条目显示成「本地」，等云端列表回来再一起变成
    // 云端图标 —— 用户看到的就是「先是本地，忽然全变云端」的闪变。
    final cached = AppState.instance.cachedCloudIds;
    if (cached.isNotEmpty && AppState.instance.loggedIn) {
      _cloudIds
        ..clear()
        ..addAll(cached);
      _cloudKnown = true;
    }
    _load();
    // 打开书架只做「拉取」，不做任何上传。
    //
    // 用户要求：「刷新收藏不要跟着上云，只有进到书签页或者手动点击
    // 上云才上云」。原来这里会 flush 待同步队列（= 上传），已移除。
    // 上云入口只剩顶部云图标按钮。
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


  /// 批量移除选中的收藏。
  ///
  /// 必须同时做三件事，否则「移除」等于假装成功：
  ///  1. **删本地收藏**（之前漏了 → 下次加载又回来了）
  ///  2. 云端用**幂等**的 setFavorite(false)（不是盲目 toggle）
  ///  3. 失败项 **入队重试**（断网 / token 过期时不丢操作）
  Future<void> _removeSelected() async {
    final ids = Set<String>.from(_selectedIds);
    final loggedIn = AppState.instance.loggedIn;

    // 1) 先删本地（立即生效，界面马上不见）
    setState(() {
      _items.removeWhere((e) => ids.contains('${e.id}'));
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
    // 2) 云端同步（无网络/未登录时直接入队，保证不丢）
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
      // 未登录：无云端可同步，纯本地删除即可
      okCount = ids.length;
    }

    if (!mounted) return;
    // 3) 明确反馈：成功几个 / 待重试几个
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

  /// 本地收藏的类型（novel / comic / video 等），用于右下角类型角标。
  ///
  /// 收藏记录里存了 `type`（小说收藏会写 `type: 'novel'`），
  /// 云端收藏则只有漫画，统一按 'comic' 处理。
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

  /// 把本地收藏转换成 Comic 列表。
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


  /// 收藏 id 归一化：只保留 id 本体，用于云端/本地之间可靠比对。
  ///
  /// 云端返回的 id 形如 `123456`，本地收藏里可能是 `123456`、
  /// `JM123456`、`eh:...`、带前后空格等。之前两侧直接字符串比较，
  /// 只要写法不同就判成「不在云端」——用户看到的正是
  /// 「有些明明上云了却还显示本地」「点上云没反应（因为被判成已存在）」。
  static String _normId(String raw) {
    var s = raw.trim();
    // 去掉源前缀
    if (s.toLowerCase().startsWith('eh:')) s = s.substring(3);
    if (s.toUpperCase().startsWith('JM')) s = s.substring(2);
    // 只保留数字与字母，去除空格/连字符
    s = s.replaceAll(RegExp(r'[^0-9A-Za-z]'), '');
    return s;
  }

  /// 该 id 是否在云端收藏里（已归一化比对）。
  bool _inCloud(String id) => _cloudIds.contains(_normId(id));

  /// 收藏列表当前保留的页数上限
  static const int _pageWindow = 3;

  /// 云端收藏总条数（0 = 未知）
  int _totalFavorites = 0;

  /// 当前窗口已加载的页码区间 [first, last]
  int _firstLoadedPage = 1;
  int _lastLoadedPage = 0;

  /// 是否正在追加下一页（防重入）
  bool _appendingPage = false;

  /// 滚动到近底部时**预取下一页**，并按窗口上限释放最早的页。
  ///
  /// 用户要求「划到第二页时就开始拉第 4 页」：
  /// 这里不等滚到底部才拉，而是在剩余不到 1.5 屏时就开始预取。
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
        // 超出窗口 → 释放最早的整页（避免收藏太多时内存爆掉）
        _trimWindow();
      });
    } catch (_) {
    } finally {
      _appendingPage = false;
    }
  }

  /// 保持最多 [_pageWindow] 页：超了就丢掉最早那页。
  void _trimWindow() {
    final pages = _lastLoadedPage - _firstLoadedPage + 1;
    if (pages <= _pageWindow) return;
    // 每页约 20 条（服务端一页的量），丢弃最早一页
    const perPage = 20;
    if (_items.length <= perPage) return;
    final drop = _items.take(perPage).length;
    _items.removeRange(0, drop);
    _firstLoadedPage++;
  }

  /// 后台同步状态（用于书架顶部提示 + 手动重试）
  SyncState _syncState = SyncState.idle;
  String? _syncError;

  /// 是否**因同步失败而隐藏**收藏列表。
  ///
  /// 规则（按用户要求）：
  ///  * 已登录 + 本次拉取失败 + 用户还没主动下拉过 → 隐藏
  ///  * 用户下拉刷新（或点重试）后无论成败都显示（让用户看到手头数据）
  ///  * 未登录（纯本地收藏）不隐藏 —— 本来就没有云端可同步
  bool get _hideListOnFailure =>
      AppState.instance.loggedIn &&
      _syncState == SyncState.failed &&
      !_userPulled;

  /// 是否已经"主动拉取过一次"。
  ///
  /// 用户要求：**进入页面时若同步失败，先不显示收藏列表**，
  /// 等用户下拉刷新（或点重试）再显示。
  /// 这样避免「看起来有收藏但其实是过期/不完整数据」的误导。
  bool _userPulled = false;

  Future<void> _load() async {
    setState(() => _loading = true);
    if (!AppState.instance.loggedIn) {
      // 未登录：直接用本地收藏填充 _items，这样首帧就有内容
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
    // 已登录：**先渲染本地内容**，云端对账放后台跑，
    // 失败也不清空列表（用户至少还能看到本地收藏）。
    if (_items.isEmpty) {
      setState(() {
        _items
          ..clear()
          ..addAll(_localFavoritesAsComics());
      });
    }
    await _syncAndFetch();
  }

  /// 凭据失效时强制退出登录，并提示用户重新登录。
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
      // 退出后只剩本地收藏
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

  /// 上云：先拉云端列表 → 缓存 → 只把「不在列表里」的推上去。
  ///
  /// 之前直接遍历本地待同步项挨个 `toggleFavorite`，问题有两个：
  ///  1. 不知道云端到底有什么，可能把已在云端的又「切换」一次反而取消收藏；
  ///  2. 全程静默，失败没有任何提示，用户看不到发生了什么。
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

    // 1) 先拉云端完整列表（分页取全）并缓存到 _cloudIds
    final cloud = <Comic>[];
    var page = 1;
    while (page <= 20) {
      final (list, total) = await _service.fetchFavorites(page: page);
      if (!_service.lastFavoritesOk) {
        // 鉴权失败 → 自动退出
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
        // 归一化：云端 id 可能是 '123'、'jm123'、'eh:...' 等形态，
        // 本地收藏存的也可能是另一种写法。统一抽成「纯数字/纯串」再比对，
        // 否则会出现「明明在云端，却被判成本地没上云」。
        ..addAll(cloud.map((e) => _normId('${e.id}')));
      _cloudKnown = true;
    });

    // 2) 只上传「本地有、云端没有」的
    final local = AppState.instance.localFavorites;
    final todo = <String>[];
    for (final fav in local) {
      final id = '${fav['id'] ?? ''}';
      if (id.isEmpty) continue;
      // 小说同样是 JM 的作品，**可以上云收藏**。
      // （视频是另一套内容体系，服务端收藏接口不认，跳过）
      final t = '${fav['type'] ?? ''}';
      if (t == 'video') continue;
      if (_inCloud(id)) continue;
      todo.add(id);
    }

    if (todo.isEmpty) {
      if (!mounted) return;
      setState(() => _syncState = SyncState.done);
      // 诊断：明确区分「云端没有本地项」与「有哪些被判定为已存在」
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
      // 用幂等的 setFavorite(target:true)：先读状态、必要时切一次、再校验。
      // 直接用 toggle 的风险是「这件其实已在云端（只是没被判定到）」时
      // 反而把它取消掉。
      final r = await _service.setFavorite(id, target: true);
      if (r.ok) {
        okCount++;
        await AppState.instance.markFavoriteSynced(id);
        // 若它同时还在「待取消」队列里（用户来回改过），要撤掉那条
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
    // 明确反馈：成功几个 / 失败几个（失败带原因）
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

  /// 云端对账 + 拉取。失败时保留当前列表，并把错误显示成可重试的提示条。
  Future<void> _syncAndFetch() async {
    setState(() {
      _syncState = SyncState.running;
      _syncError = null;
    });
    // **只拉取，不上传**。
    //
    // 用户明确要求：「刷新收藏不要跟着上云，只有进到书签页或者手动
    // 点击上云才上云」。所以这里不再调用 SyncService.syncFavorites()
    // （它内部会 flush 待同步队列 = 上传）。
    // 上云只有一个入口：顶部云图标按钮 _uploadToCloud。
    // 2) 拉云端收藏列表（**拉全所有页**）
    //
    // 之前只请求 page=1：服务端每页约 24 条，收藏多于 24 个时，
    // 后面的作品根本不在 _cloudIds 里 → 明明在云端却被标成「本地」，
    // 用户看到的「一些在云端的没显示出来云端收藏」就是这个原因。
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
        if (list.length < 20) break; // 不足一页，已到末尾
        page++;
      }
      _firstLoadedPage = 1;
      _lastLoadedPage = page;
      if (!mounted) return;
      // 凭据失效 → **自动退出登录**。
      // 服务端返回 401「請先登入會員」说明本地 JWT 已过期，
      // 但界面还显示已登录，用户永远搞不清为什么同步不了。
      // 直接清掉会话，下次进来就是明确的「未登录」状态。
      if (_service.lastFavoritesAuthFailed) {
        await _forceLogout();
        if (!mounted) return;
        return;
      }
      setState(() {
        _items
          ..clear()
          ..addAll(all);
        // 注意：这里必须和 _uploadToCloud 用**同一套归一化**，
        // 否则「显示角标」与「上云判断」会不一致。
        _cloudIds
          ..clear()
          ..addAll(all.map((e) => _normId('${e.id}')));
        _cloudKnown = cloudOk;        // 合并本地收藏里「云端没有」的条目，
        // 这样登录后也能看到本地新增的收藏（不再被云端列表覆盖）。
        // listed 用归一化后的 id，避免同一作品因写法不同被重复插入。
        final listed = _items.map((e) => _normId('${e.id}')).toSet();
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
        // 区分两种失败：
        //  * 401「請先登入會員」= 本地 JWT 已过期（界面仍显示已登录）
        //  * 其它 = 网络 / 服务端问题
        if (!cloudOk) {
          _syncError = _service.lastFavoritesAuthFailed
              ? L.t('sessionExpiredRelogin')
              : L.t('networkError');
        }
      });
      // 拉取失败必须**弹出提示**，不能只在页面里显示一条小横条 ——
      // 用户反馈「云端拉取失败没提示」正是这个原因。
      if (cloudOk) {
        // 成功 → 把本次云端 id 落盘，供下次进页面时预填角标
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
        // 拉取失败 → 云端状态未知，不要给任何条目下「本地」结论
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

  /// 下拉刷新：**只从云端拉取**，不做任何上传。
  ///
  /// 上云是独立动作（顶部云图标按钮），刷新只负责「看看云端现在有什么」。
  /// 之前刷新会顺带把本地待同步项推上去，导致用户只是想刷新列表却触发了
  /// 一堆上传请求，既慢又容易误操作。
  Future<void> _pullRefresh() async {
    // 用户主动下拉 → 之后的失败也照常显示列表（不再隐藏）
    _userPulled = true;
    await _syncAndFetch();
  }

  /// 导出收藏为 JSON 文件，并弹出带「打开目录」按钮的提示。
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
    // Toast 右侧带「打开目录」按钮
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

  /// 从**用户选择的 JSON 文件**导入收藏。
  Future<void> _importFavorites() async {
    // 先选文件，再确认（顺序反了会让用户先看弹窗却不知选哪个文件）
    final path = await FilePickerChannel.pickFile(extensions: ['json']);
    if (!mounted) return;
    if (path == null) return; // 用户取消
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
    // 自定义背景图：存在则铺在最底层（内容会盖在上面，不影响可读性）
    final bgPath = state.customBackground;
    final body = SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _pullRefresh,
          // 扣除状态栏高度：刷新图标从状态栏下方出现
          edgeOffset: MediaQuery.of(context).padding.top,
          child: NotificationListener<ScrollNotification>(
            // 分页预取：滚动到剩余不足 1.5 屏时就开始拉下一页，
            // 而不是等滚到底再拉（那样会明显卡一下）。
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
              // 始终可滚动 + 回弹：保证下拉刷新能完整收回
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
                    // 反选
                    IconButton(
                      tooltip: L.t('invertSelection'),
                      icon: const Icon(Icons.flip_to_back_rounded),
                      onPressed: () {
                        setState(() {
                          final all = _items.map((e) => '${e.id}').toSet();
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
                              _items.map((e) => '${e.id}'),
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
                    // 同步到云端（上传）：云 + 向上箭头图标
                    IconButton(
                      tooltip: L.t('syncNow'),
                      icon: _syncState == SyncState.running
                          ? const SizedBox(
                              width: 17,
                              height: 17,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          // 改用 Material 内置「云上传」图标：几何由官方保证，不会再画歪
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
              // 待同步提示：有「取消收藏」没同步成功时告诉用户，
              // 并可点击立即重试。这是「移除能否保证同步」的可见保障。
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
              // 同步失败提示：可手动重试（后台同步不再阻塞页面）
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
                  // 收藏导入 / 导出（JSON）+ 排序
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 排序：最近更新 / 名称 / 收藏时间
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
              // 同步失败且用户还没主动下拉过 → **不显示列表**，只留提示。
              // 用户要求：失败先隐藏，下拉刷新才显示，避免展示不完整数据。
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
                  // 用 Wrap 代替 SliverGrid：卡片高度由内容自然决定，
                  // 与发现页一致，避免 Grid 反复量算导致的切页卡顿。
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
                                    final id = '${c.id}';
                                    final picked =
                                        _selectedIds.contains(id);
                                    // 右上角角标：
                                    //  * 云端列表**已确认**且含此项 → 云朵
                                    //  * 云端未确认（加载中 / 拉取失败）也显示「本地」，
                                    //    因为这条确实来自本地收藏，只是还不知道是否已上云
                                    //    —— 用户明确要求「加载完成前也显示本地」。
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
                                      // 右下角：类型（漫画 / 小说 / 视频）
                                      kindTag: _kindOf(id),
                                      // 右上角：云朵优先，其次才是「本地」
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
                                        // 按收藏的**类型**分流打开：
                                        // 之前无脑开漫画详情，导致收藏的小说 /
                                        // 视频点进去是「作品不存在」。
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
                                    // 多选态：未选中的压暗 + 选中加描边勾选圈。
                                    //
                                    // 重要：描边和勾选圈都只覆盖**封面区域**
                                    // （高度 = 宽度 × 4/3），不能用 Positioned.fill
                                    // —— 那会画到封面下方的文字区，与作者名重叠。
                                    final coverH = cardW * 4 / 3;
                                    // 多选态点击**不要水波纹/光晕**：
                                    // 卡片本身已有压暗 + 描边 + 勾选圈作为反馈，
                                    // 再叠一层 InkWell 涟漪会显得脏。
                                    // 用 GestureDetector（无 material 反馈）+ 卡片
                                    // 关闭自身 splash。
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
                // 背景图（拉伸铺满，轻微模糊避免抢内容视觉）
                Positioned.fill(
                  child: Image.file(
                    File(bgPath),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
                // 半透明遮罩：保证卡片与文字在任何背景图上都清晰
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
          MaterialPageRoute(builder: (_) => const DownloadsPage()),
        ),
      ),
      // 「我导入」：管理外部导入的 .jmoe 加密包
      _Entry(
        icon: Icons.inbox_rounded,
        label: L.t('imported'),
        color: const Color(0xFF7E57C2),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ImportedPage()),
        ),
      ),
      // 书签：标记「这一话很精彩」的章节总览
      _Entry(
        icon: Icons.bookmark_rounded,
        label: L.t('bookmarks'),
        color: const Color(0xFFEC407A),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const BookmarksPage()),
        ),
      ),
      // 关注与专辑：关注作者/标签、按作者聚合作品
      _Entry(
        icon: Icons.person_add_alt_1_rounded,
        label: L.t('followAndAlbums'),
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

  /// 本地收藏中「云端列表里没有」的条目。

  /// 展示「仅本地」收藏区（已登录时也要能看到刚加入的条目）。

  /// 打开一条收藏：按类型分流到对应详情页。
  ///
  /// 本地收藏记录里带 `type`（novel / video / comic），
  /// 云端收藏一律是漫画。之前不区分类型，小说/视频收藏点进去
  /// 会当成漫画打开，显示「作品不存在」。
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

  /// 打开本地收藏条目（小说走小说详情，漫画走统一详情）。

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

/// 书架同步失败提示条：一条细横幅 + 「重试」，不遮挡收藏内容。
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
/// 收藏列表排序方式
enum FavSort {
  /// 最近更新（按作品 update_at 倒序，无更新时间的排在后面）
  recent,

  /// 按名称
  name,

  /// 按收藏时间（最近加入的在前）
  added,
}