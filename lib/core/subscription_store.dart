import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Subscription {
  final String comicId;

  final String name;

  final String cover;

  final String source;

  final int chapterCount;

  final String lastChapterId;

  final int createdAt;

  const Subscription({
    required this.comicId,
    required this.name,
    this.cover = '',
    this.source = 'jm',
    this.chapterCount = 0,
    this.lastChapterId = '',
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'comicId': comicId,
        'name': name,
        'cover': cover,
        'source': source,
        'chapterCount': chapterCount,
        'lastChapterId': lastChapterId,
        'createdAt': createdAt,
      };

  static Subscription fromJson(Map<String, dynamic> m) => Subscription(
        comicId: '${m['comicId'] ?? ''}',
        name: '${m['name'] ?? ''}',
        cover: '${m['cover'] ?? ''}',
        source: '${m['source'] ?? 'jm'}',
        chapterCount: (m['chapterCount'] as num?)?.toInt() ?? 0,
        lastChapterId: '${m['lastChapterId'] ?? ''}',
        createdAt: (m['createdAt'] as num?)?.toInt() ?? 0,
      );

  Subscription copyWith({int? chapterCount, String? lastChapterId}) =>
      Subscription(
        comicId: comicId,
        name: name,
        cover: cover,
        source: source,
        chapterCount: chapterCount ?? this.chapterCount,
        lastChapterId: lastChapterId ?? this.lastChapterId,
        createdAt: createdAt,
      );
}

class SubscriptionStore extends ChangeNotifier {
  SubscriptionStore._();
  static final SubscriptionStore instance = SubscriptionStore._();

  static const _key = 'subscriptions';

  SharedPreferences? _prefs;
  final List<Subscription> _items = [];

  List<Subscription> get items => List.unmodifiable(_items);
  int get count => _items.length;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs?.getString(_key);
    if (raw == null || raw.isEmpty) return;
    try {
      _items
        ..clear()
        ..addAll(
          (jsonDecode(raw) as List).map(
            (e) => Subscription.fromJson(Map<String, dynamic>.from(e as Map)),
          ),
        );
    } catch (_) {}
    notifyListeners();
  }

  bool isSubscribed(String comicId) =>
      _items.any((e) => e.comicId == comicId);

  Subscription? find(String comicId) {
    for (final s in _items) {
      if (s.comicId == comicId) return s;
    }
    return null;
  }

  Future<void> subscribe(Subscription s) async {
    final i = _items.indexWhere((e) => e.comicId == s.comicId);
    if (i >= 0) {
      _items[i] = s;
    } else {
      _items.add(s);
    }
    await _persist();
  }

  Future<void> unsubscribe(String comicId) async {
    _items.removeWhere((e) => e.comicId == comicId);
    await _persist();
  }

  Future<void> updateBaseline(
    String comicId, {
    required int chapterCount,
    required String lastChapterId,
  }) async {
    final i = _items.indexWhere((e) => e.comicId == comicId);
    if (i < 0) return;
    _items[i] = _items[i].copyWith(
      chapterCount: chapterCount,
      lastChapterId: lastChapterId,
    );
    await _persist();
  }

  Future<void> _persist() async {
    notifyListeners();
    await _prefs?.setString(
      _key,
      jsonEncode(_items.map((e) => e.toJson()).toList()),
    );
  }

  static const _kAuthorBase = 'authorBaselines';

  final Map<String, (int, String)> _authorBase = {};

  (int, String)? authorBaseline(String key) => _authorBase[key];

  Future<void> setAuthorBaseline(
    String key, {
    required int chapterCount,
    required String lastChapterId,
  }) async {
    _authorBase[key] = (chapterCount, lastChapterId);
    await _prefs?.setString(
      _kAuthorBase,
      jsonEncode(_authorBase.map(
        (k, v) => MapEntry(k, [v.$1, v.$2]),
      )),
    );
  }

  void loadAuthorBaselines() {
    final raw = _prefs?.getString(_kAuthorBase);
    if (raw == null || raw.isEmpty) return;
    try {
      final m = jsonDecode(raw) as Map;
      _authorBase.clear();
      m.forEach((k, v) {
        if (v is List && v.length >= 2) {
          _authorBase['$k'] = (
            v[0] is num ? (v[0] as num).toInt() : 0,
            '${v[1]}',
          );
        }
      });
    } catch (_) {}
  }
}
