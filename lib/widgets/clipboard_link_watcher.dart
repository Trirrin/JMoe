import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_theme.dart';
import '../core/jm_source.dart';
import '../core/models.dart';
import '../core/l10n.dart';
import '../pages/unified_detail_page.dart';
import '../pages/unified_home_page.dart';
import 'app_toast.dart';

class ClipboardLinkWatcher extends StatefulWidget {
  const ClipboardLinkWatcher({super.key, required this.child});

  final Widget child;

  @override
  State<ClipboardLinkWatcher> createState() => _ClipboardLinkWatcherState();
}

class _ClipboardLinkWatcherState extends State<ClipboardLinkWatcher>
    with WidgetsBindingObserver {
  final Set<String> _handled = {};

  bool _showing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadHandled();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (mounted) _checkClipboard();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkClipboard();
    }
  }

  Future<void> _loadHandled() async {
    try {
      final p = await SharedPreferences.getInstance();
      final list = p.getStringList('handledShareLinks');
      if (list != null) _handled.addAll(list);
    } catch (_) {}
  }

  Future<void> _saveHandled() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList('handledShareLinks', _handled.toList());
    } catch (_) {}
  }

  static String? _extractAlbumId(String text) {
    final t = text.trim();
    if (t.isEmpty || t.length > 2000) return null;
    final m = RegExp(
      r'(?:album|comic|photo)/(\d+)',
      caseSensitive: false,
    ).firstMatch(t);
    if (m != null) return m.group(1);
    final jm = RegExp(r'\bjm(\d{4,})\b', caseSensitive: false).firstMatch(t);
    if (jm != null) return jm.group(1);
    return null;
  }

  static bool _looksLikeLink(String text) {
    final t = text.trim();
    if (!t.contains('://') && !t.toLowerCase().contains('jm')) return false;
    return _extractAlbumId(t) != null;
  }

  Future<void> _checkClipboard() async {
    if (_showing) return;
    String? raw;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      raw = data?.text;
    } catch (_) {
      return;
    }
    if (raw == null) return;
    final text = raw.trim();
    if (!_looksLikeLink(text)) {
      return;
    }
    if (_handled.contains(text)) {
      return;
    }
    final id = _extractAlbumId(text);
    if (id == null) return;
    _showing = true;
    if (!mounted) return;
    await _showPrompt(text, id);
    _showing = false;
  }

  Future<void> _showPrompt(String rawText, String albumId) async {
    final accepted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _LinkPromptSheet(
        rawText: rawText,
        albumId: albumId,
      ),
    );
    _handled.add(rawText);
    await _saveHandled();
    if (accepted == true && mounted) {
      await _openAlbum(albumId);
    }
  }

  Future<void> _openAlbum(String albumId) async {
    try {
      final comic = await JmServiceHelper.fetchComicById(albumId);
      if (!mounted) return;
      if (comic == null) {
        AppToast.show(
          context,
          L.t('linkOpenFailed'),
          icon: Icons.link_off_rounded,
          accent: Theme.of(context).colorScheme.error,
        );
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => UnifiedDetailPage(
            source: SourceRegistry.current,
            comic: comic,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        L.tp('linkOpenFailedWith', {'e': '$e'}),
        icon: Icons.link_off_rounded,
        accent: Theme.of(context).colorScheme.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _LinkPromptSheet extends StatelessWidget {
  const _LinkPromptSheet({
    required this.rawText,
    required this.albumId,
  });

  final String rawText;
  final String albumId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppStyle.cardRadius + 4),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.link_rounded,
                    size: 20,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    L.t('clipboardLinkTitle'),
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              L.t('clipboardLinkDesc'),
              style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                rawText,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              L.tp('clipboardLinkId', {'id': albumId}),
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(L.t('clipboardLinkLater')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(L.t('clipboardLinkOpen')),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                L.t('clipboardLinkNeverAsk'),
                style: TextStyle(
                  fontSize: 10,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class JmServiceHelper {
  JmServiceHelper._();

  static Future<Comic?> fetchComicById(String id) async {
    try {
      final stub = Comic(
        id: id,
        name: '',
        author: '',
        image: '',
        source: 'jm',
      );
      final info = await JmSource.instance.detail(stub);
      return info.comic;
    } catch (_) {
      return null;
    }
  }
}
