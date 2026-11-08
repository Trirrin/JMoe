import 'dart:async';

import 'app_log.dart';
import 'jm_service.dart';

/// 通用「后台操作」服务。
///
/// 用途：任何「点一下要立刻有反馈，但真正的网络请求不该绑在页面上」
/// 的操作都走这里。典型场景：
///  * 点赞 —— 点完立刻变红，退出详情页请求照样发完
///  * 收藏 —— 同理
///  * 订阅 —— 同理
///
/// 设计要点：
///  * 请求**不 await**，页面 dispose 也继续
///  * 按 key 去重，避免连点重复发
///  * 失败回调只触发一次，由调用方决定怎么提示
class BackgroundTaskService {
  BackgroundTaskService._();
  static final BackgroundTaskService instance = BackgroundTaskService._();

  /// 正在进行的任务 key（如 `like:1489072`）
  final Set<String> _inflight = {};

  bool isInflight(String key) => _inflight.contains(key);

  /// 发送一个后台任务。
  ///
  /// [key] 用于去重；[action] 返回是否成功；[onFailed] 失败时回调一次。
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

  // ---------------- 点赞 ----------------

  /// 点赞（后台执行，退出页面也继续）。
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

  // ---------------- 收藏 ----------------

  /// 收藏 / 取消收藏（后台执行）。
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
