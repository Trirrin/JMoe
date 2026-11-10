import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'chapter_cache.dart';
import 'image_cache.dart';
import 'memory_budget.dart';

enum ScrollDir { forward, backward, idle }

class PrefetchController {
  PrefetchController._();

  static final PrefetchController instance = PrefetchController._();

  final _queue = Queue<_Job>();
  final _pending = <String>{};
  bool _draining = false;
  ScrollDir _dir = ScrollDir.idle;

  int _forwardSpan = 4;
  int _backwardSpan = 2;

  int get forwardSpan => _forwardSpan;
  int get backwardSpan => _backwardSpan;
  int get queued => _queue.length;

  void noteScroll(double delta) {
    if (delta > 0.5) {
      _dir = ScrollDir.forward;
      _forwardSpan = 6;
      _backwardSpan = 2;
    } else if (delta < -0.5) {
      _dir = ScrollDir.backward;
      _forwardSpan = 2;
      _backwardSpan = 6;
    }
  }

  void settle() {
    if (_dir == ScrollDir.idle) return;
    _dir = ScrollDir.idle;
    _forwardSpan = 4;
    _backwardSpan = 3;
  }

  List<int> windowFor(int current, int total) {
    final out = <int>[current];
    for (var d = 1; d <= _forwardSpan; d++) {
      final i = current + d;
      if (i < total) out.add(i);
    }
    for (var d = 1; d <= _backwardSpan; d++) {
      final i = current - d;
      if (i >= 0) out.add(i);
    }
    return out;
  }

  void submit(String key, Future<Object?> Function() task) {
    if (_pending.contains(key)) return;
    _pending.add(key);
    _queue.add(_Job(key, task));
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final job = _queue.removeFirst();
        try {
          await job.run();
        } catch (_) {}
        _pending.remove(job.key);
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      _draining = false;
    }
  }

  void clear() {
    _queue.clear();
    _pending.clear();
  }

  int get pageLimit => MemoryBudget.maxPages;

  void trimUiCache() {
    final cache = ImageCacheManager.instance;
    cache.trimToPages(pageLimit);
  }

  @visibleForTesting
  void resetForTest() {
    clear();
    _dir = ScrollDir.idle;
    _forwardSpan = 4;
    _backwardSpan = 3;
  }
}

class _Job {
  _Job(this.key, this.run);
  final String key;
  final Future<Object?> Function() run;
}

PrefetchController get prefetch => PrefetchController.instance;

ChapterCacheManager get chapterCache => ChapterCacheManager.instance;
