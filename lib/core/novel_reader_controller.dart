import 'dart:async';

import 'package:flutter/foundation.dart';

import 'novel_cache.dart';
import 'reader_settings.dart';
import 'reader_store.dart';
import 'reading_stats.dart';

class NovelReaderController extends ChangeNotifier {
  NovelReaderController({
    required this.nid,
    required this.chapters,
    required this.service,
    required this.settings,
  });

  final String nid;

  final List<Map<String, dynamic>> chapters;

  final Future<Map<String, dynamic>?> Function({
    required String ncid,
    required String lang,
  }) service;

  final ReaderSettings settings;

  int index = 0;
  String title = '';
  String text = '';

  String mergedText = '';

  final List<({int index, int start, String title})> chapterStarts = [];

  int mergedUpto = -1;

  bool loading = false;
  String? error;

  bool cacheHit = false;
  bool caching = false;

  bool extending = false;

  int _statSeconds = 0;
  Timer? _statTimer;

  String get pageSource => mergedText.isNotEmpty ? mergedText : text;

  int get chapterCount => chapters.length;

  bool get hasNext => index < chapters.length - 1;
  bool get hasPrev => index > 0;

  String langCode() => 'TW';

  void start() {
    _startStatTimer();
  }

  void _startStatTimer() {
    _statTimer?.cancel();
    _statTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _statSeconds += 10;
      ReadingStats.instance.addSeconds(StatType.novel, 10);
    });
  }

  void stop() {
    _statTimer?.cancel();
    _statTimer = null;
    if (_statSeconds > 0) {
      _statSeconds = 0;
    }
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  Future<void> load({int? jumpToChapter}) async {
    final target = jumpToChapter ?? index;
    if (target < 0 || target >= chapters.length) return;

    index = target;
    loading = true;
    error = null;
    notifyListeners();

    final ncid = '${chapters[target]['ncid'] ?? ''}';
    title = '${chapters[target]['title'] ?? ''}';

    try {
      final cached = await NovelCacheManager.instance.get(nid, ncid);
      final cachedText = '${cached?['text'] ?? ''}';

      if (cachedText.isNotEmpty) {
        cacheHit = true;
        caching = false;
        text = cachedText;
        _resetMerged(cachedText);
        loading = false;
        notifyListeners();

        unawaited(extendMerged(count: 3).then((_) => notifyListeners()));
        return;
      }

      cacheHit = false;
      final d = await service(ncid: ncid, lang: langCode());
      final raw = _htmlToText('${d?['content'] ?? ''}');
      if (raw.isEmpty) {
        error = 'empty';
        loading = false;
        notifyListeners();
        return;
      }

      text = raw;
      caching = false;
      loading = false;
      _resetMerged(raw);
      notifyListeners();

      unawaited(NovelCacheManager.instance.put(nid, ncid, title, raw));

      unawaited(
        ReadingStats.instance.recordChapter(
          type: StatType.novel,
          workId: nid,
        ),
      );

      unawaited(extendMerged(count: 3).then((_) => notifyListeners()));
    } catch (e) {
      error = '$e';
      loading = false;
      notifyListeners();
    }
  }

  void _resetMerged(String body) {
    mergedText = body;
    chapterStarts
      ..clear()
      ..add((index: index, start: 0, title: title));
    mergedUpto = index;
  }

  Future<void> extendMerged({int count = 3}) async {
    if (extending) return;
    extending = true;
    try {
      final end = (mergedUpto + count).clamp(0, chapters.length - 1);
      for (var i = mergedUpto + 1; i <= end; i++) {
        final ncid = '${chapters[i]['ncid'] ?? ''}';
        if (ncid.isEmpty) continue;
        final t = '${chapters[i]['title'] ?? ''}';

        var body = '';
        final cached = await NovelCacheManager.instance.get(nid, ncid);
        final ct = '${cached?['text'] ?? ''}';
        if (ct.isNotEmpty) {
          body = ct;
        } else {
          try {
            final d = await service(ncid: ncid, lang: langCode());
            body = _htmlToText('${d?['content'] ?? ''}');
            if (body.isNotEmpty) {
              unawaited(NovelCacheManager.instance.put(nid, ncid, t, body));
            }
          } catch (_) {
            break;
          }
        }
        if (body.isEmpty) break;

        if (mergedText.isNotEmpty) {
          mergedText += '\n\n\u2014\u2014 $t \u2014\u2014\n\n';
        }
        chapterStarts.add((
          index: i,
          start: mergedText.length,
          title: t,
        ));
        mergedText += body;
        mergedUpto = i;
      }
    } finally {
      extending = false;
    }
  }

  Future<void> saveProgress({required double ratio}) async {
    await ReaderStore.instance.saveProgress(
      nid,
      chapterIndex: index,
      ratio: ratio,
      chapterTitle: title,
    );
  }

  Future<void> addBookmarkAt(int offset) async {
    final src = pageSource;
    final excerpt = src.length > offset + 60
        ? src.substring(offset, offset + 60)
        : (offset < src.length ? src.substring(offset) : '');
    await ReaderStore.instance.addBookmark(
      nid,
      ReaderBookmark(
        bookId: nid,
        chapterKey: '${chapters[index]['ncid'] ?? index}',
        chapterTitle: title,
        offset: offset,
        excerpt: excerpt.replaceAll('\n', ' '),
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<List<({int chapterIndex, int offset, String excerpt})>> searchInBook(
    String query,
  ) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    final hits = <({int chapterIndex, int offset, String excerpt})>[];
    if (mergedText.isNotEmpty) {
      var i = 0;
      while (true) {
        final p = mergedText.indexOf(q, i);
        if (p < 0) break;
        hits.add((
          chapterIndex: _chapterAt(p),
          offset: p,
          excerpt: _excerpt(mergedText, p, q.length),
        ));
        i = p + q.length;
        if (hits.length >= 200) break;
      }
    }

    const workers = 4;
    var cursor = 0;
    final rest = <({int chapterIndex, int offset, String excerpt})>[];

    Future<void> worker() async {
      while (cursor < chapters.length) {
        final i = cursor++;
        if (i == index) continue;
        final ncid = '${chapters[i]['ncid'] ?? ''}';
        if (ncid.isEmpty) continue;
        final cached = await NovelCacheManager.instance.get(nid, ncid);
        final body = '${cached?['text'] ?? ''}';
        if (body.isEmpty) continue;
        var p = 0;
        while (true) {
          final at = body.indexOf(q, p);
          if (at < 0) break;
          rest.add((
            chapterIndex: i,
            offset: at,
            excerpt: _excerpt(body, at, q.length),
          ));
          p = at + q.length;
          if (rest.length >= 200) break;
        }
      }
    }

    await Future.wait(List.generate(workers, (_) => worker()));
    rest.sort((a, b) => a.chapterIndex.compareTo(b.chapterIndex));
    return [...hits, ...rest];
  }

  int _chapterAt(int offset) {
    for (var i = chapterStarts.length - 1; i >= 0; i--) {
      if (offset >= chapterStarts[i].start) return chapterStarts[i].index;
    }
    return index;
  }

  String _excerpt(String src, int at, int qLen) {
    final s = (at - 24).clamp(0, src.length);
    final e = (at + qLen + 24).clamp(0, src.length);
    return src.substring(s, e).replaceAll('\n', ' ');
  }

  static String _htmlToText(String html) {
    if (html.isEmpty) return '';
    var s = html;
    s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'</p>', caseSensitive: false), '\n\n');
    s = s.replaceAll(RegExp(r'<[^>]+>'), '');
    s = s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return s.trim();
  }
}
