import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_log.dart';
import 'jm_source.dart';
import 'models.dart';
import 'collect_store.dart';
import 'subscription_store.dart';

/// 订阅更新检查：定期看订阅的作品有没有新章节。
///
/// 发现新章节时通过原生通道发系统通知（不引入第三方通知插件，
/// 直接用 NotificationManager，可控且无需额外依赖）。
class SubscriptionChecker {
  SubscriptionChecker._();
  static final SubscriptionChecker instance = SubscriptionChecker._();

  static const _ch = MethodChannel('jmoe/reader');

  Timer? _timer;

  /// 检查间隔（默认 6 小时，避免频繁请求被限速）
  static const _interval = Duration(hours: 6);

  bool _running = false;

  /// 启动周期检查（App 启动时调用一次即可）。
  void start() {
    _timer?.cancel();
    // 首次延迟 30 秒，避开启动阶段的网络请求高峰
    _timer = Timer.periodic(_interval, (_) => checkNow());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 立即检查一次所有订阅。
  Future<void> checkNow() async {
    if (_running) return;
    final subs = SubscriptionStore.instance.items;
    if (subs.isEmpty) return;
    _running = true;
    try {
      for (final s in subs) {
        try {
          // 拉取详情拿最新章节列表
          final comic = Comic(
            id: s.comicId,
            name: s.name,
            author: '',
            image: s.cover,
            source: s.source,
          );
          final info = await JmSource.instance.detail(comic);
          final chapters = info.chapters;
          if (chapters.isEmpty) continue;

          final latestId = chapters.last.id;
          // 基线为空说明是刚订阅、还没记录过 → 只更新基线不通知
          if (s.lastChapterId.isEmpty) {
            await SubscriptionStore.instance.updateBaseline(
              s.comicId,
              chapterCount: chapters.length,
              lastChapterId: latestId,
            );
            continue;
          }
          // 有新章节（章节数变多，或最后一章 id 变了）
          if (chapters.length > s.chapterCount ||
              latestId != s.lastChapterId) {
            final added = chapters.length - s.chapterCount;
            await _notify(
              title: s.name,
              body: added > 0
                  ? '更新了 $added 话'
                  : '有新的章节',
              cover: s.cover,
            );
            await SubscriptionStore.instance.updateBaseline(
              s.comicId,
              chapterCount: chapters.length,
              lastChapterId: latestId,
            );
          }
        } catch (e, st) {
          unawaited(AppLog.instance.error('SUB', e, st));
        }
      }

      // ---- 关注的作者：检查其全部作品更新 ----
      //
      // 用户要求「关注需要订阅这个作者的所有更新」。
      // 关注是按作者关键词存的，订阅是按作品 id 存的，
      // 两者维度不同 —— 所以这里单独走一遍：
      // 按作者名搜作品 → 对每部作品比对章节数基线 → 有变化就通知。
      await _checkFollowedAuthors();
    } finally {
      _running = false;
    }
  }

  /// 检查「关注的作者」名下所有作品是否有更新。
  Future<void> _checkFollowedAuthors() async {
    final follows = CollectStore.instance.follows;
    final authors = follows
        .where((f) => f.kind == 'author')
        .map((f) => f.keyword)
        .toList();
    if (authors.isEmpty) return;

    for (final author in authors) {
      try {
        // 按作者名搜作品（官方 search_type=author）
        final r = await JmSource.instance.search(
          author,
          page: 1,
          searchType: 'author',
        );
        if (r.items.isEmpty) continue;
        // 只看前若干部，避免一次请求过多被限速
        for (final c in r.items.take(8)) {
          try {
            final info = await JmSource.instance.detail(c);
            final chapters = info.chapters;
            if (chapters.isEmpty) continue;
            final latestId = chapters.last.id;
            final key = 'author:${c.id}';
            final base =
                SubscriptionStore.instance.authorBaseline(key);
            if (base == null) {
              // 首次见到 → 只记基线，不打扰用户
              await SubscriptionStore.instance.setAuthorBaseline(
                key,
                chapterCount: chapters.length,
                lastChapterId: latestId,
              );
              continue;
            }
            if (chapters.length > base.$1 || latestId != base.$2) {
              await _notify(
                title: '$author · ${c.name}',
                body: chapters.length > base.$1
                    ? '更新了 ${chapters.length - base.$1} 话'
                    : '有新的章节',
                cover: JmSource.instance.coverOf(c) ?? '',
              );
              await SubscriptionStore.instance.setAuthorBaseline(
                key,
                chapterCount: chapters.length,
                lastChapterId: latestId,
              );
            }
          } catch (_) {}
        }
      } catch (e, st) {
        unawaited(AppLog.instance.error('SUB-AUTHOR', e, st));
      }
    }
  }

  /// 发系统通知。
  Future<void> _notify({
    required String title,
    required String body,
    String cover = '',
  }) async {
    try {
      await _ch.invokeMethod('notify', {
        'title': title,
        'body': body,
        'id': title.hashCode & 0x7FFFFFFF,
      });
    } catch (_) {
      // 通知权限未授予等情况：静默失败，不影响主流程
    }
  }
}

/// 订阅管理页：列出所有订阅，可取消。
class SubscriptionsPage extends StatefulWidget {
  const SubscriptionsPage({super.key});

  @override
  State<SubscriptionsPage> createState() => _SubscriptionsPageState();
}

class _SubscriptionsPageState extends State<SubscriptionsPage> {
  @override
  void initState() {
    super.initState();
    SubscriptionStore.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    SubscriptionStore.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final items = SubscriptionStore.instance.items;
    return Scaffold(
      appBar: AppBar(
        title: Text('更新订阅'),
        actions: [
          IconButton(
            tooltip: '立即检查',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () async {
              await SubscriptionChecker.instance.checkNow();
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      body: items.isEmpty
          ? const Center(child: Text('还没有订阅任何作品'))
          : ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, i) {
                final s = items[i];
                return ListTile(
                  leading: const Icon(Icons.notifications_active_rounded),
                  title: Text(s.name, maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  subtitle: Text('已订阅 ${s.chapterCount} 话'),
                  trailing: IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () =>
                        SubscriptionStore.instance.unsubscribe(s.comicId),
                  ),
                );
              },
            ),
    );
  }
}
