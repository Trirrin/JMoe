import 'dart:async';
import 'dart:convert';

class ReaderBookmark {
  final String bookId;
  final String chapterKey;
  final String chapterTitle;
  final int offset;
  final String excerpt;
  final int createdAt;

  const ReaderBookmark({
    required this.bookId,
    required this.chapterKey,
    required this.chapterTitle,
    required this.offset,
    required this.excerpt,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'bookId': bookId,
        'chapterKey': chapterKey,
        'chapterTitle': chapterTitle,
        'offset': offset,
        'excerpt': excerpt,
        'createdAt': createdAt,
      };

  factory ReaderBookmark.fromJson(Map<String, dynamic> m) => ReaderBookmark(
        bookId: '${m['bookId'] ?? ''}',
        chapterKey: '${m['chapterKey'] ?? ''}',
        chapterTitle: '${m['chapterTitle'] ?? ''}',
        offset: (m['offset'] as num?)?.toInt() ?? 0,
        excerpt: '${m['excerpt'] ?? ''}',
        createdAt: (m['createdAt'] as num?)?.toInt() ?? 0,
      );
}

class ReaderAnnotation {
  final String id;
  final String bookId;
  final String chapterKey;
  final String chapterTitle;
  final int start;
  final int end;
  final String text;
  final String note;
  final int colorIndex;
  final int createdAt;

  const ReaderAnnotation({
    required this.id,
    required this.bookId,
    required this.chapterKey,
    required this.chapterTitle,
    required this.start,
    required this.end,
    required this.text,
    required this.note,
    required this.colorIndex,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'bookId': bookId,
        'chapterKey': chapterKey,
        'chapterTitle': chapterTitle,
        'start': start,
        'end': end,
        'text': text,
        'note': note,
        'colorIndex': colorIndex,
        'createdAt': createdAt,
      };

  factory ReaderAnnotation.fromJson(Map<String, dynamic> m) => ReaderAnnotation(
        id: '${m['id'] ?? ''}',
        bookId: '${m['bookId'] ?? ''}',
        chapterKey: '${m['chapterKey'] ?? ''}',
        chapterTitle: '${m['chapterTitle'] ?? ''}',
        start: (m['start'] as num?)?.toInt() ?? 0,
        end: (m['end'] as num?)?.toInt() ?? 0,
        text: '${m['text'] ?? ''}',
        note: '${m['note'] ?? ''}',
        colorIndex: (m['colorIndex'] as num?)?.toInt() ?? 0,
        createdAt: (m['createdAt'] as num?)?.toInt() ?? 0,
      );
}

class ReaderProgress {
  final int chapterIndex;
  final double ratio;
  final String chapterTitle;
  final int updatedAt;

  const ReaderProgress({
    required this.chapterIndex,
    required this.ratio,
    required this.chapterTitle,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'chapterIndex': chapterIndex,
        'ratio': ratio,
        'chapterTitle': chapterTitle,
        'updatedAt': updatedAt,
      };

  factory ReaderProgress.fromJson(Map<String, dynamic> m) => ReaderProgress(
        chapterIndex: (m['chapterIndex'] as num?)?.toInt() ?? 0,
        ratio: (m['ratio'] as num?)?.toDouble() ?? 0,
        chapterTitle: '${m['chapterTitle'] ?? ''}',
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
      );
}

class ReaderStore {
  ReaderStore._();
  static final ReaderStore instance = ReaderStore._();

  Future<String?> Function(String key)? _read;
  Future<void> Function(String key, String value)? _write;

  bool _ready = false;

  void setBackend({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
  }) {
    _read = read;
    _write = write;
    _ready = true;
  }

  bool get ready => _ready;

  final Map<String, List<ReaderBookmark>> _bookmarks = {};
  final Map<String, List<ReaderAnnotation>> _annotations = {};
  final Map<String, ReaderProgress> _progress = {};

  String _bk(String bookId) => 'reader_bookmarks_$bookId';
  String _ak(String bookId) => 'reader_annotations_$bookId';
  String _pk(String bookId) => 'reader_progress_$bookId';

  Future<void> loadBook(String bookId) async {
    if (!_ready) return;
    final rb = await _read!(_bk(bookId));
    if (rb != null && rb.isNotEmpty) {
      try {
        final list = (jsonDecode(rb) as List)
            .whereType<Map>()
            .map((e) => ReaderBookmark.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        _bookmarks[bookId] = list;
      } catch (_) {}
    }
    final ra = await _read!(_ak(bookId));
    if (ra != null && ra.isNotEmpty) {
      try {
        final list = (jsonDecode(ra) as List)
            .whereType<Map>()
            .map((e) => ReaderAnnotation.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        _annotations[bookId] = list;
      } catch (_) {}
    }
    final rp = await _read!(_pk(bookId));
    if (rp != null && rp.isNotEmpty) {
      try {
        _progress[bookId] =
            ReaderProgress.fromJson(jsonDecode(rp) as Map<String, dynamic>);
      } catch (_) {}
    }
  }

  ReaderProgress? progress(String bookId) => _progress[bookId];

  Future<void> saveProgress(
    String bookId, {
    required int chapterIndex,
    required double ratio,
    required String chapterTitle,
  }) async {
    if (!_ready) return;
    final p = ReaderProgress(
      chapterIndex: chapterIndex,
      ratio: ratio.clamp(0.0, 1.0),
      chapterTitle: chapterTitle,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _progress[bookId] = p;
    await _write!(_pk(bookId), jsonEncode(p.toJson()));
  }

  List<ReaderBookmark> bookmarks(String bookId) =>
      List.unmodifiable(_bookmarks[bookId] ?? const []);

  bool hasBookmarkAt(String bookId, String chapterKey, int offset) =>
      (_bookmarks[bookId] ?? const []).any(
        (b) =>
            b.chapterKey == chapterKey &&
            (b.offset - offset).abs() < 200,
      );

  Future<void> addBookmark(String bookId, ReaderBookmark b) async {
    if (!_ready) return;
    final list = _bookmarks.putIfAbsent(bookId, () => []);
    list.insert(0, b);
    await _write!(
      _bk(bookId),
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> removeBookmark(String bookId, ReaderBookmark b) async {
    if (!_ready) return;
    final list = _bookmarks[bookId];
    if (list == null) return;
    list.removeWhere((e) => e.createdAt == b.createdAt && e.offset == b.offset);
    await _write!(
      _bk(bookId),
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  List<ReaderAnnotation> annotations(String bookId, {String? chapterKey}) {
    final list = _annotations[bookId] ?? const <ReaderAnnotation>[];
    if (chapterKey == null) return List.unmodifiable(list);
    return List.unmodifiable(list.where((a) => a.chapterKey == chapterKey));
  }

  Future<void> addAnnotation(String bookId, ReaderAnnotation a) async {
    if (!_ready) return;
    final list = _annotations.putIfAbsent(bookId, () => []);
    list.insert(0, a);
    await _write!(
      _ak(bookId),
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> updateAnnotation(String bookId, ReaderAnnotation a) async {
    if (!_ready) return;
    final list = _annotations[bookId];
    if (list == null) return;
    final i = list.indexWhere((e) => e.id == a.id);
    if (i >= 0) list[i] = a;
    await _write!(
      _ak(bookId),
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> removeAnnotation(String bookId, String id) async {
    if (!_ready) return;
    final list = _annotations[bookId];
    if (list == null) return;
    list.removeWhere((e) => e.id == id);
    await _write!(
      _ak(bookId),
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }
}
