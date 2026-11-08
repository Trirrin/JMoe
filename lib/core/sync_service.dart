import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_log.dart';
import 'app_state.dart';
import 'cache_manager.dart';
import 'jm_service.dart';
import 'models.dart';

/// 云端与本地一致性同步。
///
/// 解决问题：登录后云端收藏/历史与本地书架可能不一致。
/// 策略（以「合并优先、冲突以云端为准」为原则）：
///  1. 登录成功或进入书架时触发一次同步
///  2. 本地有、云端无 → 标记为「仅本地」并保留（不擅自删除用户数据）
///  3. 云端有、本地无 → 补录到本地书架
///  4. 两边都有但元信息（名称/封面）不同 → 以云端为准更新
///  5. 缓存章节索引与本地书架对账，清理失效索引
class SyncService {
  SyncService._();
  static final SyncService instance = SyncService._();

  final _service = JmService.instance;

  /// 同步状态（供 UI 显示）
  final ValueNotifier<SyncState> state = ValueNotifier(SyncState.idle);

  /// 上次同步时间
  DateTime? lastSyncAt;

  /// 同步结果摘要
  String? lastMessage;

  /// 拉取云端收藏并与本地合并。
  Future<SyncResult> syncFavorites() async {
    if (!AppState.instance.loggedIn) {
      return const SyncResult(skipped: true);
    }
    if (state.value == SyncState.running) {
      return const SyncResult(skipped: true);
    }
    state.value = SyncState.running;
    try {
      // 0) 先把上次失败/待取消的收藏同步掉
      //    （放在最前：保证云端状态先收敛，后面的对账才准）
      await flushUnfavoriteQueue();
      // 云端分页拉取（最多取前 10 页，避免过大）
      final cloud = <Comic>[];
      var page = 1;
      while (page <= 10) {
        final (list, total) = await _service.fetchFavorites(page: page);
        if (list.isEmpty) break;
        cloud.addAll(list);
        if (total > 0 && cloud.length >= total) break;
        page++;
      }

      final local = AppState.instance.localFavorites;
      final localIds = local.map((e) => '${e['id']}').toSet();
      final cloudIds = cloud.map((c) => c.id).toSet();

      var added = 0;   // 云端有、本地无 → 补录
      var updated = 0; // 两边都有 → 以云端为准刷新元信息
      var localOnly = 0;

      for (final c in cloud) {
        final cover = _service.coverUrl(c);
        if (!localIds.contains(c.id)) {
          await AppState.instance.toggleLocalFavorite({
            'id': c.id,
            'name': c.name,
            'author': c.author,
            'cover': cover,
            'source': 'jm',
            'update_at': c.updateAt,
          });
          added++;
        } else {
          final idx = AppState.instance.localFavorites.indexWhere(
            (e) => '${e['id']}' == c.id,
          );
          if (idx >= 0) {
            final cur = AppState.instance.localFavorites[idx];
            if ('${cur['name']}' != c.name ||
                '${cur['cover'] ?? ''}' != (cover ?? '')) {
              await AppState.instance.updateLocalFavoriteMeta(c.id, {
                'name': c.name,
                'author': c.author,
                'cover': cover,
                'update_at': c.updateAt,
              });
              updated++;
            }
          }
        }
      }

      // 本地独有的仅计数提示，不删除
      for (final e in local) {
        if (!cloudIds.contains('${e['id']}')) localOnly++;
      }

      lastSyncAt = DateTime.now();
      lastMessage = 'added=$added updated=$updated localOnly=$localOnly';
      state.value = SyncState.done;
      return SyncResult(
        added: added,
        updated: updated,
        localOnly: localOnly,
      );
    } catch (e, st) {
      state.value = SyncState.failed;
      lastMessage = '$e';
      // 失败必须留痕：之前只存了字符串、什么都不打，
      // 用户反馈「同步失败但完全不知道原因」。
      unawaited(AppLog.instance.error('SYNC', e, st));
      print('[JMOE] syncFavorites FAILED: $e');
      return SyncResult(error: '$e');
    }
  }

  /// 处理「待取消收藏」队列：逐条去云端确认并取消。
  ///
  /// 为什么单独做：收藏的取消是**切换语义**，失败后无法靠简单重发补救
  /// （重发可能反而又收藏回来）。所以这里用 [JmService.setFavorite]
  /// ——它先读状态、只在确实不一致时切一次、再回读校验，是幂等的。
  ///
  /// 处理策略：
  ///  * 成功 → 出队
  ///  * 鉴权失败 → 停止（等用户重新登录，队列保留）
  ///  * 其它失败 → 保留在队列，下次再试
  Future<({int ok, int fail})> flushUnfavoriteQueue() async {
    final queue = AppState.instance.pendingUnfavorite;
    if (queue.isEmpty) return (ok: 0, fail: 0);
    if (!AppState.instance.loggedIn) return (ok: 0, fail: 0);

    var ok = 0;
    var fail = 0;
    for (final item in queue) {
      final id = '${item['id'] ?? ''}';
      if (id.isEmpty) continue;
      final r = await _service.setFavorite(id, target: false);
      if (r.ok) {
        await AppState.instance.dequeueUnfavorite(id);
        ok++;
      } else {
        fail++;
        unawaited(AppLog.instance.log(
          'SYNC',
          'unfavorite flush failed id=$id err=${r.error}',
        ));
        // token 失效时不必继续试后续条目
        if (_service.lastFavoritesAuthFailed) break;
      }
    }
    lastMessage = 'unfav ok=$ok fail=$fail';
    return (ok: ok, fail: fail);
  }

  /// 缓存索引与本地书架对账：清理磁盘上已不存在的章节索引。
  Future<int> reconcileCache() async {
    return CacheManager.instance.reconcileIndex();
  }
}

enum SyncState { idle, running, done, failed }

class SyncResult {
  final bool skipped;
  final int added;
  final int updated;
  final int localOnly;
  final String? error;

  const SyncResult({
    this.skipped = false,
    this.added = 0,
    this.updated = 0,
    this.localOnly = 0,
    this.error,
  });

  bool get hasChanges => added > 0 || updated > 0;
}
