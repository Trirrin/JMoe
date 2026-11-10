import 'dart:async';

import 'app_log.dart';
import 'jm_service.dart';

class BackgroundTaskService {
  BackgroundTaskService._();
  static final BackgroundTaskService instance = BackgroundTaskService._();

  final Set<String> _inflight = {};

  bool isInflight(String key) => _inflight.contains(key);

  void run({
    required String key,
    required Future<bool> Function() action,
    void Function()? onFailed,
    String logTag = 'BG',
  }) {
    if (_inflight.contains(key)) return;
    _inflight.add(key);
    unawaited(() async {
      try {
        final ok = await action();
        if (!ok) {
          unawaited(AppLog.instance.log(logTag, 'task failed: $key'));
          onFailed?.call();
        }
      } catch (e, st) {
        unawaited(AppLog.instance.error(logTag, e, st));
        onFailed?.call();
      } finally {
        _inflight.remove(key);
      }
    }());
  }

  void like(String albumId, {void Function()? onFailed}) {
    run(
      key: 'like:$albumId',
      logTag: 'LIKE',
      action: () async {
        final r = await JmService.instance.toggleLike(albumId);
        return r['code'] == 200;
      },
      onFailed: onFailed,
    );
  }

  bool isLikeInflight(String albumId) => isInflight('like:$albumId');

  void favorite(
    String albumId, {
    required bool target,
    void Function()? onFailed,
  }) {
    run(
      key: 'fav:$albumId',
      logTag: 'FAV',
      action: () async {
        final r = await JmService.instance.setFavorite(albumId, target: target);
        return r.ok;
      },
      onFailed: onFailed,
    );
  }
}
