import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/app_theme.dart';
import '../core/jm_protocol.dart';
import '../core/jm_service.dart';
import '../core/l10n.dart';
import '../widgets/common_widgets.dart';
import '../widgets/scroll_top_fab.dart';
import 'login_page.dart';

class CommentPage extends StatefulWidget {
  final String aid;
  final String title;
  CommentPage({super.key, required this.aid, String? title})
      : title = title ?? L.t('commentsTitle');

  @override
  State<CommentPage> createState() => _CommentPageState();
}

class _CommentPageState extends State<CommentPage> {
  final _service = JmService.instance;
  final _comments = <Map<String, dynamic>>[];
  final _input = TextEditingController();
  final _scroll = ScrollController();

  double _scrollOffset = 0;

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final o = _scroll.position.pixels;
    final cross = (o > 400) != (_scrollOffset > 400);
    if (cross || (o - _scrollOffset).abs() > 80) {
      setState(() => _scrollOffset = o);
    }
  }

  bool _loading = true;
  bool _sending = false;
  int _page = 1;
  String? _error;

  final Set<String> _liked = {};
  final Set<String> _voting = {};
  String? _replyToCid;
  String? _replyToName;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load(reset: true);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (reset) {
      setState(() {
        _comments.clear();
        _page = 1;
        _loading = true;
        _error = null;
      });
    }
    try {
      final list = await _service.fetchComments(aid: widget.aid, page: _page);
      if (!mounted) return;
      setState(() {
        _comments.addAll(list);
        _page++;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    if (!AppState.instance.loggedIn) {
      final ok = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const LoginPage()),
      );
      if (ok != true) return;
    }
    setState(() => _sending = true);
    final r = await _service.sendComment(
      aid: widget.aid,
      comment: text,
      commentId: _replyToCid,
    );
    if (!mounted) return;
    setState(() {
      _sending = false;
      _replyToCid = null;
      _replyToName = null;
    });
    if (r['code'] == 200 || r['code'] == '200') {
      _input.clear();
      await _load(reset: true);
      if (mounted) {
        _toast(L.t('commentSent'));
        if (_scroll.hasClients) {
          _scroll.animateTo(
            0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      }
    } else {
      _toast('${r['errorMsg'] ?? r['error'] ?? L.t('sendFailed')}');
    }
  }

  Future<void> _toggleLike(Map<String, dynamic> c) async {
    final cid = '${c['CID'] ?? c['cid'] ?? c['id'] ?? ''}';
    if (cid.isEmpty) return;
    if (!AppState.instance.loggedIn) {
      _toast(L.t('loginToLike'));
      return;
    }
    if (_voting.contains(cid)) return;

    final wasLiked = _liked.contains(cid);
    final prev = int.tryParse('${c['likes'] ?? 0}') ?? 0;
    HapticFeedback.selectionClick();

    setState(() {
      _voting.add(cid);
      if (wasLiked) {
        _liked.remove(cid);
        c['likes'] = '${prev > 0 ? prev - 1 : 0}';
      } else {
        _liked.add(cid);
        c['likes'] = '${prev + 1}';
      }
    });

    try {
      final r = await _service.voteComment(cid, aid: widget.aid);
      if (!mounted) return;
      final code = r['code'];
      final hasError = r['errorMsg'] != null || r['error'] != null;
      final ok = !hasError &&
          (code == null || code == 200 || code == '200');
      if (!ok) {
        setState(() {
          if (wasLiked) {
            _liked.add(cid);
          } else {
            _liked.remove(cid);
          }
          c['likes'] = '$prev';
        });
        final msg = r['errorMsg'] ?? r['error'];
        _toast((msg == null || '$msg'.isEmpty)
            ? L.t('operationFailed')
            : '$msg');
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          if (wasLiked) {
            _liked.add(cid);
          } else {
            _liked.remove(cid);
          }
          c['likes'] = '$prev';
        });
      }
    } finally {
      if (mounted) setState(() => _voting.remove(cid));
    }
  }

  void _reply(Map<String, dynamic> c) {
    final cid = '${c['CID'] ?? c['cid'] ?? c['id'] ?? ''}';
    final name =
        '${c['nickname'] ?? c['username'] ?? L.t('unknown')}';
    if (cid.isEmpty) return;
    setState(() {
      _replyToCid = cid;
      _replyToName = name;
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  static const _months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  String _fmtDate(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return '';

    final m = RegExp(r'([A-Za-z]{3})[a-z]*\s+(\d{1,2}),?\s+(\d{4})')
        .firstMatch(s);
    if (m != null) {
      final mon = _months[m.group(1)!.toLowerCase()];
      final day = int.tryParse(m.group(2)!);
      final year = int.tryParse(m.group(3)!);
      if (mon != null && day != null && year != null) {
        return '$year-${_two(mon)}-${_two(day)}';
      }
    }

    final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(s);
    if (iso != null) {
      return '${iso.group(1)}-${iso.group(2)}-${iso.group(3)}';
    }

    final n = int.tryParse(s);
    if (n != null && n > 1000000000) {
      final ms = n > 9999999999 ? n : n * 1000;
      final d = DateTime.fromMillisecondsSinceEpoch(ms);
      return '${d.year}-${_two(d.month)}-${_two(d.day)}';
    }

    return s;
  }

  String _two(int v) => v.toString().padLeft(2, '0');

  String? _avatarUrl(String? photo) {
    if (photo == null || photo.isEmpty) return null;
    if (photo.startsWith('nopic')) return null;
    if (photo.startsWith('http')) return photo;
    final base = JmApi.instance.baseUrl;
    return '${base}media/user/$photo';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: () => _load(reset: true),
            edgeOffset: MediaQuery.of(context).padding.top,
            child: _loading && _comments.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _error != null && _comments.isEmpty
                    ? EmptyView(
                        message: '${L.t('loadFailed')}\n$_error',
                        onRetry: () => _load(reset: true),
                      )
                    : _comments.isEmpty
                        ? EmptyView(
                            message: L.t('noComments'),
                            icon: Icons.chat_bubble_outline,
                          )
                        : NotificationListener<ScrollNotification>(
                            onNotification: (n) {
                              if (n.metrics.pixels >
                                  n.metrics.maxScrollExtent - 300) {
                                _load();
                              }
                              return false;
                            },
                            child: ListView.separated(
                              controller: _scroll,
                              physics: const AlwaysScrollableScrollPhysics(
                                parent: BouncingScrollPhysics(),
                              ),
                              padding: const EdgeInsets.all(
                                AppStyle.pagePadding,
                              ),
                              cacheExtent: 900,
                              itemCount: _comments.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (context, i) =>
                                  _buildComment(theme, _comments[i]),
                            ),
                          ),
          ),
          Positioned(
            right: 16,
            bottom: 84,
            child: ScrollTopFab(
              scrollOffset: _scrollOffset,
              heroTag: null,
              onAction: () {
                if (_scroll.hasClients) {
                  _scroll.animateTo(
                    0,
                    duration: const Duration(milliseconds: 420),
                    curve: Curves.easeOutCubic,
                  );
                }
              },
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildInputBar(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar(ThemeData theme) {
    final scheme = theme.colorScheme;
    final loggedIn = AppState.instance.loggedIn;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(
            top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_replyToName != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Text(
                      L.tp('replyTo', {'name': _replyToName}),
                      style: TextStyle(fontSize: 11, color: scheme.primary),
                    ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: () => setState(() {
                        _replyToCid = null;
                        _replyToName = null;
                      }),
                      child: Icon(
                        Icons.close,
                        size: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    maxLines: 4,
                    minLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: loggedIn
                          ? L.t('commentHint')
                          : L.t('commentLoginHint'),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_rounded, size: 18),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComment(ThemeData theme, Map<String, dynamic> c) {
    final scheme = theme.colorScheme;
    final nickname =
        '${c['nickname'] ?? c['username'] ?? L.t('unknown')}';
    final cid = '${c['CID'] ?? c['cid'] ?? c['id'] ?? ''}';
    final raw = '${c['content'] ?? c['comment'] ?? c['text'] ?? ''}';
    final content = raw
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'</div>'), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .trim();
    final time = _fmtDate('${c['addtime'] ?? c['date'] ?? ''}');
    final likes = int.tryParse('${c['likes'] ?? 0}') ?? 0;
    final liked = _liked.contains(cid);
    final photo = c['photo'] as String?;
    final exp = c['expinfo'];
    final levelName = exp is Map ? '${exp['level_name'] ?? ''}' : '';
    final level = exp is Map ? (exp['level']) : null;
    final isMine = AppState.instance.loggedIn &&
        '${c['UID'] ?? ''}' == '${AppState.instance.member?['uid'] ?? ''}';
    final parentCid = '${c['parent_CID'] ?? '0'}';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 34,
                height: 34,
                child: _avatarUrl(photo) == null
                    ? Container(
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.person,
                          size: 20,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant,
                        ),
                      )
                    : CoverImage(
                        url: _avatarUrl(photo),
                        borderRadius: BorderRadius.circular(17),
                        memCacheWidth: 96,
                      ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            nickname,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: isMine ? scheme.primary : null,
                            ),
                          ),
                        ),
                        if (levelName.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'Lv$level · $levelName',
                              style: TextStyle(
                                fontSize: 8.5,
                                fontWeight: FontWeight.w600,
                                color: scheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (time.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(
                          time,
                          style: TextStyle(
                            fontSize: 9.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (parentCid != '0')
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                L.t('replyToComment'),
                style: TextStyle(
                  fontSize: 10,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 43),
            child: Text(
              content,
              style: const TextStyle(fontSize: 13, height: 1.55),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 43),
            child: Row(
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => _toggleLike(c),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          liked
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          size: 14,
                          color: liked ? scheme.error : scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '$likes',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color:
                                liked ? scheme.error : scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => _reply(c),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.reply_rounded,
                          size: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          L.t('reply'),
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                if (_voting.contains(cid))
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.4),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
