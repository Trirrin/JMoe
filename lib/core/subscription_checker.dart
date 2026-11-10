import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_log.dart';
import 'jm_source.dart';
import 'models.dart';
import 'collect_store.dart';
import 'subscription_store.dart';

class SubscriptionChecker {
  SubscriptionChecker._();
  static final SubscriptionChecker instance = SubscriptionChecker._();

  static const _ch = MethodChannel('jmoe/reader');

  Timer? _timer;

  static const _interval = Duration(hours: 6);

  bool _running = false;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) => checkNow());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> checkNow() async {
    if (_running) return;
    final subs = SubscriptionStore.instance.items;
    if (subs.isEmpty) return;
    _running = true;
    try {
      for (final s in subs) {
        try {
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
          if (s.lastChapterId.isEmpty) {
            await SubscriptionStore.instance.updateBaseline(
              s.comicId,
              chapterCount: chapters.length,
              lastChapterId: latestId,
            );
            continue;
          }
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

      await _checkFollowedAuthors();
    } finally {
      _running = false;
    }
  }

  Future<void> _checkFollowedAuthors() async {
    final follows = CollectStore.instance.follows;
    final authors = follows
        .where((f) => f.kind == 'author')
        .map((f) => f.keyword)
        .toList();
    if (authors.isEmpty) return;

    for (final author in authors) {
      try {
        final r = await JmSource.instance.search(
          author,
          page: 1,
          searchType: 'author',
        );
        if (r.items.isEmpty) continue;
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
    }
  }
}

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
