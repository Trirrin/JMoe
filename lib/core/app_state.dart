import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';
import 'jm_protocol.dart';
import 'net_throttle.dart';
import 'l10n.dart';

class ReadHistoryEntry {
  final String comicId;
  final String chapterId;
  final String comicName;
  final String chapterName;
  final String? cover;
  final String source;

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

  double get ratio =>
      totalPage <= 0 ? 0 : (page / totalPage).clamp(0.0, 1.0);
}

class HistoryGroup {
  final String comicId;
  final String comicName;
  final String source;
  final String kind;
  final String? cover;

  final List<ReadHistoryEntry> chapters;

  const HistoryGroup({
    required this.comicId,
    required this.comicName,
    required this.source,
    required this.kind,
    required this.cover,
    required this.chapters,
  });

  int get lastAt =>
      chapters.isEmpty ? 0 : chapters.first.updatedAt;

  int get totalPages =>
      chapters.fold<int>(0, (a, e) => a + e.totalPage);

  int get readPages => chapters.fold<int>(0, (a, e) => a + e.page);

  double get overallRatio {
    final t = totalPages;
    return t <= 0 ? 0 : (readPages / t).clamp(0.0, 1.0);
  }

  ReadHistoryEntry? get latest =>
      chapters.isEmpty ? null : chapters.first;
}

enum HistorySort {
  recent,

  progress,
}

class AppState extends ChangeNotifier {
  static final AppState instance = AppState._();
  AppState._();

  SharedPreferences? _prefs;

  ThemeMode themeMode = ThemeMode.system;
  bool oledMode = false;
  Color seedColor = AppStyle.seed;
  String readerMode = 'vertical';

  bool volumeKeyPage = true;

  String customBackground = '';
  bool showPageProgress = true;
  bool enableVolumeKeys = true;
  String imageShunt = '1';

  String imgHost = '';
  String apiHost = '';
  String lang = 'TW';

  String uiLang = 'zh-Hans';

  String cardSize = 'normal';

  bool autoEnterStartup = true;

  bool prefetchNextChapter = true;

  bool confirmDelete = true;

  String imageQuality = 'medium';

  int startTab = 0;

  int gridColumns = 3;

  bool bannerAutoPlay = true;

  int netLimitMbps = 10;

  bool offlineMode = false;

  Future<void> setOfflineMode(bool v) async {
    offlineMode = v;
    notifyListeners();
  }

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

  String? get avatarPath => member?['photo'] as String?;

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
    _loadPendingUnfavorite(p);
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

  Future<void> setVolumeKeyPage(bool v) async {
    volumeKeyPage = v;
    notifyListeners();
    await _prefs?.setBool('volumeKeyPage', v);
  }

  Future<void> setCustomBackground(String path) async {
    customBackground = path;
    notifyListeners();
    await _prefs?.setString('customBackground', path);
  }

  String cacheSkipDate = '';

  static String _todayKey() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-'
        '${n.day.toString().padLeft(2, '0')}';
  }

  bool get cacheSkipToday => cacheSkipDate == _todayKey();

  Future<void> setCacheSkipToday(bool v) async {
    cacheSkipDate = v ? _todayKey() : '';
    notifyListeners();
    await _prefs?.setString('cacheSkipDate', cacheSkipDate);
  }

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

  Future<void> clearAllData() async {
    history = [];
    localFavorites = [];
    await _prefs?.remove('history');
    await _prefs?.remove('localFavorites');
    await _prefs?.remove('search_history');
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

  Future<void> setLastHost(String v) async {
    await _prefs?.setString('lastHost', v);
  }

  String? get lastHost => _prefs?.getString('lastHost');

  Future<void> setLang(String v) async {
    lang = v;
    notifyListeners();
    await _prefs?.setString('lang', v);
  }

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

  List<HistoryGroup> groupedHistory({HistorySort sort = HistorySort.recent}) {
    final map = <String, List<ReadHistoryEntry>>{};
    for (final e in history) {
      final key = '${e.source}_${e.kind}_${e.comicId}';
      map.putIfAbsent(key, () => []).add(e);
    }
    final groups = <HistoryGroup>[];
    map.forEach((_, list) {
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

  Future<void> markFavoriteSynced(String id) async {
    final i = localFavorites.indexWhere((e) => '${e['id']}' == id);
    if (i < 0) return;
    localFavorites[i] = {...localFavorites[i], 'pendingSync': false};
    await _prefs?.setString('localFavorites', jsonEncode(localFavorites));
  }

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

  Future<void> saveCloudIdsCache(Set<String> ids) async {
    _cachedCloudIds = Set<String>.from(ids);
    _cachedCloudAt = DateTime.now().millisecondsSinceEpoch;
    await _prefs?.setString('cachedCloudIds', jsonEncode(ids.toList()));
    await _prefs?.setInt('cachedCloudAt', _cachedCloudAt);
  }

  int get pendingSyncCount =>
      localFavorites.where((e) => e['pendingSync'] == true).length;

  List<Map<String, dynamic>> _pendingUnfavorite = [];

  List<Map<String, dynamic>> get pendingUnfavorite =>
      List.unmodifiable(_pendingUnfavorite);

  int get pendingUnfavoriteCount => _pendingUnfavorite.length;

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

  final ValueNotifier<String?> pendingSearch = ValueNotifier<String?>(null);

  bool pendingSearchAsTag = false;

  void requestSearch(String query, {bool asTag = false}) {
    pendingSearchAsTag = asTag;
    pendingSearch.value = null;
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
