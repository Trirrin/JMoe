import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';
import 'jm_protocol.dart';
import 'net_throttle.dart';
import 'l10n.dart';

/// 阅读历史条目（本地持久化）。
class ReadHistoryEntry {
  final String comicId;
  final String chapterId;
  final String comicName;
  final String chapterName;
  final String? cover;
  final String source;

  /// 内容类型：comic / novel / video。
  ///
  /// 历史列表要「按作品聚合」并且用不同的图标区分这三类，
  /// 所以必须记下来。旧数据没有这个字段时按 comic 处理。
  final String kind;
  final int page;
  final int totalPage;
  final int updatedAt;

  const ReadHistoryEntry({
    required this.comicId,
    required this.chapterId,
    required this.comicName,
    required this.chapterName,
    this.cover,
    this.source = 'jm',
    this.kind = 'comic',
    this.page = 1,
    this.totalPage = 0,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
    'comicId': comicId,
    'chapterId': chapterId,
    'comicName': comicName,
    'chapterName': chapterName,
    'cover': cover,
    'source': source,
    'kind': kind,
    'page': page,
    'totalPage': totalPage,
    'updatedAt': updatedAt,
  };

  factory ReadHistoryEntry.fromJson(Map<String, dynamic> j) => ReadHistoryEntry(
    comicId: '${j['comicId']}',
    chapterId: '${j['chapterId']}',
    comicName: '${j['comicName'] ?? ''}',
    chapterName: '${j['chapterName'] ?? ''}',
    cover: j['cover'] as String?,
    source: '${j['source'] ?? 'jm'}',
    kind: '${j['kind'] ?? 'comic'}',
    page: j['page'] is num ? (j['page'] as num).toInt() : 1,
    totalPage: j['totalPage'] is num ? (j['totalPage'] as num).toInt() : 0,
    updatedAt: j['updatedAt'] is num ? (j['updatedAt'] as num).toInt() : 0,
  );

  /// 单章进度（0..1）。
  double get ratio =>
      totalPage <= 0 ? 0 : (page / totalPage).clamp(0.0, 1.0);
}

/// 一个**作品**的历史聚合（同一作品的多个选集合并为一个槽位）。
///
/// 用户在历史里想看到的是「我看了哪部作品、看到哪了」，
/// 而不是「第 3 话、第 5 话各占一行」。
class HistoryGroup {
  final String comicId;
  final String comicName;
  final String source;
  final String kind;
  final String? cover;

  /// 该作品下**看过**的选集（按观看时间倒序，未看过的不出现）
  final List<ReadHistoryEntry> chapters;

  const HistoryGroup({
    required this.comicId,
    required this.comicName,
    required this.source,
    required this.kind,
    required this.cover,
    required this.chapters,
  });

  /// 最近一次观看时间
  int get lastAt =>
      chapters.isEmpty ? 0 : chapters.first.updatedAt;

  /// 总页数（所有看过的选集之和）—— 计算总进度占比用
  int get totalPages =>
      chapters.fold<int>(0, (a, e) => a + e.totalPage);

  /// 已读页数（所有看过的选集之和）
  int get readPages => chapters.fold<int>(0, (a, e) => a + e.page);

  /// 所有选集加在一起的总进度占比（0..1）。
  ///
  /// 用户明确要求：「占比最高的得看所有的选集加在一起的总页数」。
  double get overallRatio {
    final t = totalPages;
    return t <= 0 ? 0 : (readPages / t).clamp(0.0, 1.0);
  }

  /// 最近在看的选集
  ReadHistoryEntry? get latest =>
      chapters.isEmpty ? null : chapters.first;
}

/// 历史列表的排序方式。
enum HistorySort {
  /// 最近观看优先
  recent,

  /// 总进度占比优先（所有看过的选集页数之和）
  progress,
}

/// 全局应用状态。
class AppState extends ChangeNotifier {
  static final AppState instance = AppState._();
  AppState._();

  SharedPreferences? _prefs;

  // ---- 偏好 ----
  ThemeMode themeMode = ThemeMode.system;
  bool oledMode = false;
  Color seedColor = AppStyle.seed;
  String readerMode = 'vertical'; // vertical | horizontal

  /// 音量键翻页（阅读页开启后，音量键改为翻页）
  bool volumeKeyPage = true;

  /// 自定义背景图路径（空 = 不用背景图）
  ///
  /// 用户可以把任意图片设为书架背景。存的是应用私有目录里的副本路径，
  /// 而不是用户选的原始位置 —— 原图可能被移动/删除。
  String customBackground = '';
  bool showPageProgress = true;
  bool enableVolumeKeys = true;
  String imageShunt = '1';

  /// 首选图片线路（手动选择，空表示自动）。
  String imgHost = '';
  String apiHost = '';
  /// 内容语言（服务端接口参数：TW/CN/JP/EN）
  String lang = 'TW';

  /// 界面语言（本地文案：zh-Hans / zh-Hant / en）
  String uiLang = 'zh-Hans';

  /// 列表卡片大小：compact / normal / large
  String cardSize = 'normal';

  /// 启动页是否自动进入（true = 测速完直接进，false = 等用户点）
  bool autoEnterStartup = true;

  /// 阅读时是否自动预取下一章
  bool prefetchNextChapter = true;

  /// 删除操作是否需要二次确认
  bool confirmDelete = true;

  /// 缩略图质量：low / medium / high
  String imageQuality = 'medium';

  /// 启动默认页：0 发现 / 1 分类 / 2 书架
  int startTab = 0;

  /// 网格列数
  int gridColumns = 3;

  /// 首页海报轮播是否自动播放
  bool bannerAutoPlay = true;

  /// 网络限速（Mbps），0 表示不限速。默认 10。
  int netLimitMbps = 10;

  /// 离线模式：只使用本地已下载 / 已缓存内容，不发起网络请求。
  bool offlineMode = false;

  /// 切换离线模式（不持久化，仅本次会话有效）。
  Future<void> setOfflineMode(bool v) async {
    offlineMode = v;
    notifyListeners();
  }



  // ---- 账号 ----
  String? jwt;
  Map<String, dynamic>? member;
  bool get loggedIn =>
      (jwt != null && jwt!.isNotEmpty) ||
      (member != null && member!.isNotEmpty);
  String get userName {
    final m = member;
    if (m == null) return '';
    for (final k in ['username', 'nickname', 'name', 'uid']) {
      final v = m[k];
      if (v != null && '$v'.trim().isNotEmpty) return '$v';
    }
    return '';
  }

  /// 头像（相对路径需拼主站）
  String? get avatarPath => member?['photo'] as String?;

  // ---- 本地数据 ----
  List<ReadHistoryEntry> history = [];
  List<Map<String, dynamic>> localFavorites = [];

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final p = _prefs!;
    final mode = p.getString('themeMode') ?? 'system';
    themeMode = switch (mode) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    oledMode = p.getBool('oled') ?? false;
    final seed = p.getInt('seedColor');
    if (seed != null) seedColor = Color(seed);
    readerMode = p.getString('readerMode') ?? 'vertical';
    volumeKeyPage = p.getBool('volumeKeyPage') ?? true;
    customBackground = p.getString('customBackground') ?? '';
    cacheSkipDate = p.getString('cacheSkipDate') ?? '';
    _loadBookmarks(p);
    showPageProgress = p.getBool('showPageProgress') ?? true;
    enableVolumeKeys = p.getBool('enableVolumeKeys') ?? true;
    imageShunt = p.getString('imageShunt') ?? '1';
    imgHost = p.getString('imgHost') ?? '';
    cardSize = p.getString('cardSize') ?? 'normal';
    autoEnterStartup = p.getBool('autoEnterStartup') ?? true;
    prefetchNextChapter = p.getBool('prefetchNextChapter') ?? true;
    confirmDelete = p.getBool('confirmDelete') ?? true;
    imageQuality = p.getString('imageQuality') ?? 'medium';
    startTab = p.getInt('startTab') ?? 0;
    gridColumns = p.getInt('gridColumns') ?? 3;
    bannerAutoPlay = p.getBool('bannerAutoPlay') ?? true;
    netLimitMbps = p.getInt('netLimitMbps') ?? 10;
    NetThrottle.instance.mbps = netLimitMbps;
    apiHost = p.getString('apiHost') ?? '';
    lang = p.getString('lang') ?? 'TW';
    uiLang = p.getString('uiLang') ?? 'zh-Hans';
    L.setLang(uiLang);
    jwt = p.getString('jwt');
    final m = p.getString('member');
    if (m != null && m.isNotEmpty) {
      try {
        member = jsonDecode(m) as Map<String, dynamic>;
      } catch (_) {}
    }
    // 关键：把已保存的登录态注入 API 层。
    // 之前只恢复了 AppState.jwt，却没同步到 JmApi.instance.jwtToken，
    // 导致重启后所有请求都不带 Authorization → 服务端视为未登录，
    // 收藏/点赞/签到等需要登录的接口全部失败。
    if (jwt != null && jwt!.isNotEmpty) {
      JmApi.instance.jwtToken = jwt;
    }
    final cookie = member?['s'];
    if (cookie != null && '$cookie'.isNotEmpty) {
      JmApi.instance.cookieValue = '$cookie';
    }
    final h = p.getString('history');
    if (h != null && h.isNotEmpty) {
      try {
        history = (jsonDecode(h) as List)
            .map((e) => ReadHistoryEntry.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      } catch (_) {}
    }
    final f = p.getString('localFavorites');
    if (f != null && f.isNotEmpty) {
      try {
        localFavorites = (jsonDecode(f) as List)
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      } catch (_) {}
    }
    // 待同步的「取消收藏」队列（失败后重试用）
    _loadPendingUnfavorite(p);
    // 上次拉到的云端收藏 id（用于首屏就显示正确角标，避免闪变）
    _loadCloudIdsCache(p);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    await _prefs?.setString('themeMode', switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      _ => 'system',
    });
  }

  Future<void> setOled(bool v) async {
    oledMode = v;
    notifyListeners();
    await _prefs?.setBool('oled', v);
  }

  Future<void> setSeedColor(Color c) async {
    seedColor = c;
    notifyListeners();
    await _prefs?.setInt('seedColor', c.toARGB32());
  }

  Future<void> setReaderMode(String mode) async {
    readerMode = mode;
    notifyListeners();
    await _prefs?.setString('readerMode', mode);
  }

  /// 开关「音量键翻页」。
  Future<void> setVolumeKeyPage(bool v) async {
    volumeKeyPage = v;
    notifyListeners();
    await _prefs?.setBool('volumeKeyPage', v);
  }

  /// 设置自定义背景图（传空字符串 = 移除）。
  Future<void> setCustomBackground(String path) async {
    customBackground = path;
    notifyListeners();
    await _prefs?.setString('customBackground', path);
  }

  // ---------------- 「今天不再询问缓存方式」 ----------------
  //
  // 缓存蒙版每次进阅读页都会弹，用户选了「边看边缓存」后下次还要再选。
  // 勾了「今天不再询问」就记下日期，当天直接边看边缓存，次日自动恢复。

  /// 记录「今天不再询问」的日期（yyyy-MM-dd），空 = 未设置
  String cacheSkipDate = '';

  static String _todayKey() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-'
        '${n.day.toString().padLeft(2, '0')}';
  }

  /// 今天是否已经选择「不再询问缓存方式」。
  bool get cacheSkipToday => cacheSkipDate == _todayKey();


  Future<void> setCacheSkipToday(bool v) async {
    cacheSkipDate = v ? _todayKey() : '';
    notifyListeners();
    await _prefs?.setString('cacheSkipDate', cacheSkipDate);
  }

  // ---------------- 章节书签 ----------------
  //
  // 用于标记「这一话很精彩」。与阅读进度、收藏都不同：
  // 进度只是「读到哪」，收藏是「喜欢这部作品」，
  // 书签是「这一话值得再回看」，需要能单独浏览。
  //
  // 每条书签记录：
  //  * kind        comic / novel（漫画或小说）
  //  * comicId     作品 id
  //  * chapterId   章节 id
  //  * page        页码（1 起；小说为分页后的页码）
  //  * chapterName / comicName / cover / source
  //  * note        用户批注（可空）
  //  * at          创建时间

  List<Map<String, dynamic>> _bookmarks = [];

  List<Map<String, dynamic>> get chapterBookmarks =>
      List.unmodifiable(_bookmarks);

  void _loadBookmarks(SharedPreferences p) {
    final raw = p.getString('chapterBookmarks');
    if (raw == null || raw.isEmpty) return;
    try {
      _bookmarks = (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      _bookmarks = [];
    }
  }

  /// 该书签是否已存在（按作品+章节+页 判定）。
  bool isChapterBookmarked(
    String comicId,
    String chapterId, {
    int page = 0,
  }) =>
      _bookmarks.any(
        (e) =>
            e['comicId'] == comicId &&
            e['chapterId'] == chapterId &&
            (page <= 0 || (e['page'] as num?)?.toInt() == page),
      );

  /// 添加 / 移除 / 更新书签。
  ///
  /// [page] 为 0 时表示「整章书签」（详情页章节行用），
  /// 大于 0 表示阅读器里针对某一页的书签。
  Future<void> setChapterBookmark({
    required String comicId,
    required String chapterId,
    required String comicName,
    required String chapterName,
    required String cover,
    required String source,
    required bool on,
    int page = 0,
    String kind = 'comic',
    String note = '',
  }) async {
    final i = _bookmarks.indexWhere(
      (e) =>
          e['comicId'] == comicId &&
          e['chapterId'] == chapterId &&
          ((e['page'] as num?)?.toInt() ?? 0) == page,
    );
    if (on) {
      final entry = {
        'comicId': comicId,
        'chapterId': chapterId,
        'comicName': comicName,
        'chapterName': chapterName,
        'cover': cover,
        'source': source,
        'page': page,
        'kind': kind,
        'note': note,
        'at': DateTime.now().millisecondsSinceEpoch,
      };
      if (i >= 0) {
        // 已存在 → 更新批注等内容（保留原创建时间）
        _bookmarks[i] = {..._bookmarks[i], ...entry, 'at': _bookmarks[i]['at']};
      } else {
        _bookmarks.insert(0, entry);
      }
    } else {
      if (i >= 0) _bookmarks.removeAt(i);
    }
    notifyListeners();
    await _prefs?.setString('chapterBookmarks', jsonEncode(_bookmarks));
  }

  /// 更新某条书签的批注。
  Future<void> updateBookmarkNote({
    required String comicId,
    required String chapterId,
    required int page,
    required String note,
  }) async {
    final i = _bookmarks.indexWhere(
      (e) =>
          e['comicId'] == comicId &&
          e['chapterId'] == chapterId &&
          ((e['page'] as num?)?.toInt() ?? 0) == page,
    );
    if (i < 0) return;
    _bookmarks[i] = {..._bookmarks[i], 'note': note};
    notifyListeners();
    await _prefs?.setString('chapterBookmarks', jsonEncode(_bookmarks));
  }

  Future<void> setShowPageProgress(bool v) async {
    showPageProgress = v;
    notifyListeners();
    await _prefs?.setBool('showPageProgress', v);
  }

  Future<void> setEnableVolumeKeys(bool v) async {
    enableVolumeKeys = v;
    notifyListeners();
    await _prefs?.setBool('enableVolumeKeys', v);
  }

  /// 设置首选图片线路并持久化。


  Future<void> setStartTab(int v) async {
    startTab = v;
    notifyListeners();
    await _prefs?.setInt('startTab', v);
  }

  Future<void> setGridColumns(int v) async {
    gridColumns = v;
    notifyListeners();
    await _prefs?.setInt('gridColumns', v);
  }

  /// 设置网络限速（Mbps，0 = 不限速）。
  Future<void> setNetLimitMbps(int v) async {
    netLimitMbps = v;
    NetThrottle.instance.mbps = v;
    notifyListeners();
    await _prefs?.setInt('netLimitMbps', v);
  }

  Future<void> setBannerAutoPlay(bool v) async {
    bannerAutoPlay = v;
    notifyListeners();
    await _prefs?.setBool('bannerAutoPlay', v);
  }

  Future<void> setCardSize(String v) async {
    cardSize = v;
    notifyListeners();
    await _prefs?.setString('cardSize', v);
  }

  Future<void> setAutoEnterStartup(bool v) async {
    autoEnterStartup = v;
    notifyListeners();
    await _prefs?.setBool('autoEnterStartup', v);
  }

  Future<void> setPrefetchNextChapter(bool v) async {
    prefetchNextChapter = v;
    notifyListeners();
    await _prefs?.setBool('prefetchNextChapter', v);
  }

  Future<void> setConfirmDelete(bool v) async {
    confirmDelete = v;
    notifyListeners();
    await _prefs?.setBool('confirmDelete', v);
  }

  Future<void> setImageQuality(String v) async {
    imageQuality = v;
    notifyListeners();
    await _prefs?.setString('imageQuality', v);
  }

  /// 清除所有本地数据（保留登录状态）。
  Future<void> clearAllData() async {
    history = [];
    localFavorites = [];
    await _prefs?.remove('history');
    await _prefs?.remove('localFavorites');
    await _prefs?.remove('search_history');
    // 阅读相关的键全部清掉
    final keys = _prefs?.getKeys().toList() ?? const <String>[];
    for (final k in keys) {
      if (k.startsWith('reader_') || k.startsWith('video_pos_')) {
        await _prefs?.remove(k);
      }
    }
    notifyListeners();
  }

  Future<void> setImgHost(String v) async {
    imgHost = v;
    notifyListeners();
    await _prefs?.setString('imgHost', v);
  }

  Future<void> setImageShunt(String v) async {
    imageShunt = v;
    notifyListeners();
    await _prefs?.setString('imageShunt', v);
  }

  Future<void> setApiHost(String v) async {
    apiHost = v;
    notifyListeners();
    await _prefs?.setString('apiHost', v);
  }

  /// 上次测速最优线路（启动时优先沿用，减少抖动）
  Future<void> setLastHost(String v) async {
    await _prefs?.setString('lastHost', v);
  }

  String? get lastHost => _prefs?.getString('lastHost');

  Future<void> setLang(String v) async {
    lang = v;
    notifyListeners();
    await _prefs?.setString('lang', v);
  }

  /// 设置界面语言（立即换文案）。
  Future<void> setUiLang(String v) async {
    uiLang = v;
    L.setLang(v);
    notifyListeners();
    await _prefs?.setString('uiLang', v);
  }

  Future<void> saveSession(String? token, Map<String, dynamic>? info) async {
    jwt = token;
    member = info;
    notifyListeners();
    if (token == null) {
      await _prefs?.remove('jwt');
      await _prefs?.remove('member');
    } else {
      await _prefs?.setString('jwt', token);
      await _prefs?.setString('member', jsonEncode(info ?? {}));
    }
  }

  Future<void> recordHistory(ReadHistoryEntry entry) async {
    history.removeWhere(
      (e) => e.comicId == entry.comicId && e.chapterId == entry.chapterId,
    );
    history.insert(0, entry);
    if (history.length > 300) history = history.sublist(0, 300);
    notifyListeners();
    await _prefs?.setString(
      'history',
      jsonEncode(history.map((e) => e.toJson()).toList()),
    );
  }

  /// 更新某章阅读进度（页号），并置顶该记录。
  Future<void> updateHistoryProgress({
    required String comicId,
    required String chapterId,
    required int page,
    required int totalPage,
  }) async {
    final i = history.indexWhere(
      (e) => e.comicId == comicId && e.chapterId == chapterId,
    );
    if (i < 0) return;
    final old = history[i];
    history[i] = ReadHistoryEntry(
      comicId: old.comicId,
      chapterId: old.chapterId,
      comicName: old.comicName,
      chapterName: old.chapterName,
      cover: old.cover,
      source: old.source,
      kind: old.kind,
      page: page,
      totalPage: totalPage,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    notifyListeners();
    await _prefs?.setString(
      'history',
      jsonEncode(history.map((e) => e.toJson()).toList()),
    );
  }

  /// 按作品聚合历史：一个作品一个槽位，内部带上所有**看过**的选集。
  ///
  /// [sort] 决定排序方式：
  ///  * [HistorySort.recent]  —— 按最近观看时间倒序（默认）
  ///  * [HistorySort.progress] —— 按「总进度占比」倒序（所有选集之和）
  List<HistoryGroup> groupedHistory({HistorySort sort = HistorySort.recent}) {
    final map = <String, List<ReadHistoryEntry>>{};
    for (final e in history) {
      // 同一作品的选集归到一起；类型也参与 key，避免同名 id 冲突
      final key = '${e.source}_${e.kind}_${e.comicId}';
      map.putIfAbsent(key, () => []).add(e);
    }
    final groups = <HistoryGroup>[];
    map.forEach((_, list) {
      // 每部作品内部按时间倒序
      list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      final head = list.first;
      groups.add(
        HistoryGroup(
          comicId: head.comicId,
          comicName: head.comicName,
          source: head.source,
          kind: head.kind,
          cover: head.cover,
          chapters: list,
        ),
      );
    });
    switch (sort) {
      case HistorySort.recent:
        groups.sort((a, b) => b.lastAt.compareTo(a.lastAt));
      case HistorySort.progress:
        groups.sort((a, b) {
          final c = b.overallRatio.compareTo(a.overallRatio);
          // 占比相同再按最近观看
          return c != 0 ? c : b.lastAt.compareTo(a.lastAt);
        });
    }
    return groups;
  }

  Future<void> clearHistory() async {
    history = [];
    notifyListeners();
    await _prefs?.remove('history');
  }

  Future<void> removeHistory(String comicId, String chapterId) async {
    history.removeWhere(
      (e) => e.comicId == comicId && e.chapterId == chapterId,
    );
    notifyListeners();
    await _prefs?.setString(
      'history',
      jsonEncode(history.map((e) => e.toJson()).toList()),
    );
  }

  bool isLocalFavorite(String id) =>
      localFavorites.any((e) => '${e['id']}' == id);

  /// 更新本地收藏的元信息（云端同步时以云端为准）。
  Future<void> updateLocalFavoriteMeta(
    String id,
    Map<String, dynamic> meta,
  ) async {
    final i = localFavorites.indexWhere((e) => '${e['id']}' == id);
    if (i < 0) return;
    localFavorites[i] = {...localFavorites[i], ...meta};
    notifyListeners();
    await _prefs?.setString('localFavorites', jsonEncode(localFavorites));
  }

  /// 标记某条本地收藏已同步到云端（清除 pendingSync）。
  Future<void> markFavoriteSynced(String id) async {
    final i = localFavorites.indexWhere((e) => '${e['id']}' == id);
    if (i < 0) return;
    localFavorites[i] = {...localFavorites[i], 'pendingSync': false};
    await _prefs?.setString('localFavorites', jsonEncode(localFavorites));
  }

  // ---------------- 云端收藏 id 缓存 ----------------
  //
  // 每次打开书架都要重新拉云端列表，在拉回来之前界面只能猜，
  // 于是用户看到「先全部显示本地 → 突然全变成云端」的闪变。
  // 这里把上次成功拉到的云端 id 集合持久化，下次进页面先用它渲染，
  // 拉取成功后再覆盖 —— 视觉上就不会跳。

  Set<String> _cachedCloudIds = {};
  int _cachedCloudAt = 0;

  Set<String> get cachedCloudIds => _cachedCloudIds;
  int get cachedCloudAt => _cachedCloudAt;

  void _loadCloudIdsCache(SharedPreferences p) {
    final raw = p.getString('cachedCloudIds');
    if (raw == null || raw.isEmpty) return;
    try {
      _cachedCloudIds = (jsonDecode(raw) as List).map((e) => '$e').toSet();
      _cachedCloudAt = p.getInt('cachedCloudAt') ?? 0;
    } catch (_) {
      _cachedCloudIds = {};
    }
  }

  /// 保存云端 id 缓存（拉取成功后调用）。
  Future<void> saveCloudIdsCache(Set<String> ids) async {
    _cachedCloudIds = Set<String>.from(ids);
    _cachedCloudAt = DateTime.now().millisecondsSinceEpoch;
    await _prefs?.setString('cachedCloudIds', jsonEncode(ids.toList()));
    await _prefs?.setInt('cachedCloudAt', _cachedCloudAt);
  }

  /// 待同步到云端的收藏数量。
  int get pendingSyncCount =>
      localFavorites.where((e) => e['pendingSync'] == true).length;

  // ---------------- 待同步的「取消收藏」队列 ----------------
  //
  // 取消收藏必须单独记录：本地条目被删掉后，就没有任何地方记得
  // 「这个 id 还需要去云端取消」。之前书架多选删除只调了切换接口、
  // 不记录失败，一旦失败（断网 / token 过期 / 切换语义翻车）
  // 就永久丢失，用户下次刷新看到它又回来了。
  //
  // 这里存「待取消的 id + 时间」，由 SyncService 在合适的时机重试，
  // 成功后从队列移除。

  List<Map<String, dynamic>> _pendingUnfavorite = [];

  List<Map<String, dynamic>> get pendingUnfavorite =>
      List.unmodifiable(_pendingUnfavorite);

  int get pendingUnfavoriteCount => _pendingUnfavorite.length;

  /// 读盘（在 init 里调用）。
  void _loadPendingUnfavorite(SharedPreferences p) {
    final raw = p.getString('pendingUnfavorite');
    if (raw == null || raw.isEmpty) {
      _pendingUnfavorite = [];
      return;
    }
    try {
      _pendingUnfavorite = (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      _pendingUnfavorite = [];
    }
  }

  /// 记录「这个作品需要去云端取消收藏」（幂等：同一 id 不重复入队）。
  Future<void> queueUnfavorite(String id) async {
    final key = id.trim();
    if (key.isEmpty) return;
    if (_pendingUnfavorite.any((e) => '${e['id']}' == key)) return;
    _pendingUnfavorite.add({
      'id': key,
      'at': DateTime.now().millisecondsSinceEpoch,
    });
    notifyListeners();
    await _prefs?.setString(
      'pendingUnfavorite',
      jsonEncode(_pendingUnfavorite),
    );
  }

  /// 云端已确认取消 → 从队列移除。
  Future<void> dequeueUnfavorite(String id) async {
    final key = id.trim();
    final before = _pendingUnfavorite.length;
    _pendingUnfavorite.removeWhere((e) => '${e['id']}' == key);
    if (_pendingUnfavorite.length == before) return;
    notifyListeners();
    await _prefs?.setString(
      'pendingUnfavorite',
      jsonEncode(_pendingUnfavorite),
    );
  }

  /// 显式设置本地收藏状态（true 收藏 / false 取消），而非切换。
  ///
  /// 切换语义在「失败回滚」场景会出错（调两次就切回去了），
  /// 因此对外统一用幂等的 set。
  Future<void> setLocalFavorite(
    Map<String, dynamic> comic,
    bool favorite,
  ) async {
    final id = '${comic['id']}';
    final exists = isLocalFavorite(id);
    if (favorite) {
      if (!exists) localFavorites.insert(0, comic);
    } else {
      if (exists) localFavorites.removeWhere((e) => '${e['id']}' == id);
    }
    notifyListeners();
    await _prefs?.setString('localFavorites', jsonEncode(localFavorites));
  }

  Future<void> toggleLocalFavorite(Map<String, dynamic> comic) async {
    final id = '${comic['id']}';
    if (isLocalFavorite(id)) {
      localFavorites.removeWhere((e) => '${e['id']}' == id);
    } else {
      localFavorites.insert(0, comic);
    }
    notifyListeners();
    await _prefs?.setString('localFavorites', jsonEncode(localFavorites));
  }

  /// 跨页面发起搜索：详情页点标签/编号时，通知搜索页并切换过去。
  /// 搜索页监听此值。
  final ValueNotifier<String?> pendingSearch = ValueNotifier<String?>(null);

  /// 待搜索词是否为「标签」（用于搜索框内嵌胶囊显示）。
  bool pendingSearchAsTag = false;

  void requestSearch(String query, {bool asTag = false}) {
    pendingSearchAsTag = asTag;
    pendingSearch.value = null; // 先清空以触发变更
    pendingSearch.value = query;
  }

  ReadHistoryEntry? lastReadFor(String comicId) {
    for (final e in history) {
      if (e.comicId == comicId) return e;
    }
    return null;
  }
}

extension AppStateVolumeKey on AppState {
}