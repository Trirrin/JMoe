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
    page: j['page'] is num ? (j['page'] as num).toInt() : 1,
    totalPage: j['totalPage'] is num ? (j['totalPage'] as num).toInt() : 0,
    updatedAt: j['updatedAt'] is num ? (j['updatedAt'] as num).toInt() : 0,
  );
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

  /// 待同步到云端的收藏数量。
  int get pendingSyncCount =>
      localFavorites.where((e) => e['pendingSync'] == true).length;

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
