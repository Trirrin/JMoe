import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一个「关注」条目：可以关注作者或标签。
class FollowItem {
  /// 'author' 或 'tag'
  final String kind;

  /// 关键词（作者名 / 标签名）
  final String keyword;

  /// 显示名（默认同 keyword，可手动改）
  final String title;

  /// 关注时间
  final int at;

  const FollowItem({
    required this.kind,
    required this.keyword,
    this.title = '',
    required this.at,
  });

  String get displayName => title.isEmpty ? keyword : title;

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'keyword': keyword,
        'title': title,
        'at': at,
      };

  static FollowItem fromJson(Map<String, dynamic> m) => FollowItem(
        kind: '${m['kind'] ?? 'author'}',
        keyword: '${m['keyword'] ?? ''}',
        title: '${m['title'] ?? ''}',
        at: (m['at'] as num?)?.toInt() ?? 0,
      );
}

/// 一个「专辑」：用来把同一作者的多部作品聚合在一起。
///
/// 为什么需要：同一作者可能有多个笔名、或用工作室名义发布，
/// 单靠作者名字符串无法归到一起。所以专辑允许手工编辑**多个关键词**，
/// 命中任一关键词的作品都算这个专辑的。
class Album {
  final String id;
  final String name;

  /// 多个关键词（作者名/笔名/工作室名），命中任一即归入本专辑
  final List<String> keywords;

  /// 自定义封面（空 = 用最新作品的封面）
  final String cover;

  final int at;

  Album({
    required this.id,
    required this.name,
    this.keywords = const [],
    this.cover = '',
    required this.at,
  });

  Album copyWith({
    String? name,
    List<String>? keywords,
    String? cover,
  }) =>
      Album(
        id: id,
        name: name ?? this.name,
        keywords: keywords ?? this.keywords,
        cover: cover ?? this.cover,
        at: at,
      );

  /// 该作品作者是否命中本专辑的关键词。
  bool matches(String author) {
    final a = author.toLowerCase().trim();
    if (a.isEmpty) return false;
    for (final k in keywords) {
      final kk = k.toLowerCase().trim();
      if (kk.isEmpty) continue;
      if (a == kk || a.contains(kk) || kk.contains(a)) return true;
    }
    return false;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'keywords': keywords,
        'cover': cover,
        'at': at,
      };

  static Album fromJson(Map<String, dynamic> m) => Album(
        id: '${m['id'] ?? ''}',
        name: '${m['name'] ?? ''}',
        keywords: (m['keywords'] as List? ?? const [])
            .map((e) => '$e')
            .toList(),
        cover: '${m['cover'] ?? ''}',
        at: (m['at'] as num?)?.toInt() ?? 0,
      );
}

/// 关注（作者/标签）与专辑的持久化存储。
class CollectStore extends ChangeNotifier {
  CollectStore._();
  static final CollectStore instance = CollectStore._();

  static const _kFollow = 'follows';
  static const _kAlbums = 'albums';

  SharedPreferences? _prefs;

  final List<FollowItem> _follows = [];
  final List<Album> _albums = [];

  List<FollowItem> get follows => List.unmodifiable(_follows);
  List<Album> get albums => List.unmodifiable(_albums);

  List<FollowItem> get followAuthors =>
      _follows.where((e) => e.kind == 'author').toList();
  List<FollowItem> get followTags =>
      _follows.where((e) => e.kind == 'tag').toList();

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _read(_prefs!.getString(_kFollow), _follows, FollowItem.fromJson);
    _read(_prefs!.getString(_kAlbums), _albums, Album.fromJson);
    notifyListeners();
  }

  void _read<T>(
    String? raw,
    List<T> out,
    T Function(Map<String, dynamic>) parse,
  ) {
    if (raw == null || raw.isEmpty) return;
    try {
      out
        ..clear()
        ..addAll(
          (jsonDecode(raw) as List)
              .map((e) => parse(Map<String, dynamic>.from(e as Map))),
        );
    } catch (_) {}
  }

  // ---------- 关注 ----------

  bool isFollowing(String kind, String keyword) =>
      _follows.any((e) => e.kind == kind && e.keyword == keyword);

  Future<void> toggleFollow(String kind, String keyword) async {
    final k = keyword.trim();
    if (k.isEmpty) return;
    final i = _follows.indexWhere((e) => e.kind == kind && e.keyword == k);
    if (i >= 0) {
      _follows.removeAt(i);
    } else {
      _follows.add(FollowItem(
        kind: kind,
        keyword: k,
        at: DateTime.now().millisecondsSinceEpoch,
      ));
    }
    await _persistFollows();
  }

  Future<void> renameFollow(String kind, String keyword, String title) async {
    final i = _follows.indexWhere((e) => e.kind == kind && e.keyword == keyword);
    if (i < 0) return;
    final old = _follows[i];
    _follows[i] = FollowItem(
      kind: old.kind,
      keyword: old.keyword,
      title: title,
      at: old.at,
    );
    await _persistFollows();
  }

  Future<void> _persistFollows() async {
    notifyListeners();
    await _prefs?.setString(
      _kFollow,
      jsonEncode(_follows.map((e) => e.toJson()).toList()),
    );
  }

  // ---------- 专辑 ----------

  Future<Album> createAlbum({
    required String name,
    List<String> keywords = const [],
  }) async {
    final a = Album(
      id: 'alb_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      keywords: keywords,
      at: DateTime.now().millisecondsSinceEpoch,
    );
    _albums.add(a);
    await _persistAlbums();
    return a;
  }

  Future<void> updateAlbum(Album a) async {
    final i = _albums.indexWhere((e) => e.id == a.id);
    if (i < 0) return;
    _albums[i] = a;
    await _persistAlbums();
  }

  Future<void> deleteAlbum(String id) async {
    _albums.removeWhere((e) => e.id == id);
    await _persistAlbums();
  }

  Future<void> _persistAlbums() async {
    notifyListeners();
    await _prefs?.setString(
      _kAlbums,
      jsonEncode(_albums.map((e) => e.toJson()).toList()),
    );
  }
}
