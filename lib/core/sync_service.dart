import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_log.dart';
import 'app_state.dart';
import 'cache_manager.dart';
import 'jm_service.dart';
import 'models.dart';

class SyncService {
  SyncService._();
  static final SyncService instance = SyncService._();

  final _service = JmService.instance;

  final ValueNotifier<SyncState> state = ValueNotifier(SyncState.idle);

  DateTime? lastSyncAt;

  String? lastMessage;

  Future<SyncResult> syncFavorites() async {
    if (!AppState.instance.loggedIn) {
      return const SyncResult(skipped: true);
    }
    if (state.value == SyncState.running) {
      return const SyncResult(skipped: true);
    }
    state.value = SyncState.running;
    try {
      await flushUnfavoriteQueue();
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

      var added = 0;
      var updated = 0;
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
      unawaited(AppLog.instance.error('SYNC', e, st));
      print('[JMOE] syncFavorites FAILED: $e');
      return SyncResult(error: '$e');
    }
  }

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
        if (_service.lastFavoritesAuthFailed) break;
      }
    }
    lastMessage = 'unfav ok=$ok fail=$fail';
    return (ok: ok, fail: fail);
  }

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
