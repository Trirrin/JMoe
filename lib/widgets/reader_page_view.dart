import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../core/image_cache.dart';
import '../core/jm_protocol.dart';
import '../core/reading_stats.dart';
import '../core/jm_service.dart';
import '../core/image_scrambler.dart';
import '../core/image_worker.dart';
import '../core/source.dart';
import '../core/temp_store.dart';
import '../core/l10n.dart';

class ReaderPageView extends StatefulWidget {
  final PageRef ref;
  final String? scrambleId;
  final String scrambleAid;
  final String albumId;
  final ComicSource source;
  final String cacheKey;
  final BoxFit fit;

  final double fallbackRatio;

  final String? tempDir;

  final String chapterId;

  final ValueChanged<double>? onLoaded;

  final int? decodeWidth;

  const ReaderPageView({
    super.key,
    required this.ref,
    required this.scrambleId,
    required this.scrambleAid,
    required this.albumId,
    required this.source,
    required this.cacheKey,
    this.chapterId = '',
    this.tempDir,
    this.fit = BoxFit.fitWidth,
    this.fallbackRatio = 0.72,
    this.decodeWidth,
    this.onLoaded,
  });

  @override
  State<ReaderPageView> createState() => _ReaderPageViewState();
}

class _ReaderPageViewState extends State<ReaderPageView> {
  ui.Image? _image;
  bool _failed = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _syncHit();
  }

  void _syncHit() {
    final key = widget.cacheKey;
    if (key.startsWith('http') && widget.ref.directUrl != null) {
      final cached = ImageCacheManager.instance.getUiSync(key);
      if (cached != null) {
        _image = cached;
        unawaited(
          ReadingStats.instance.recordCache(hit: true, savedBytes: 0),
        );
        return;
      }
    }
    unawaited(ReadingStats.instance.recordCache(hit: false));
    _start();
  }

  @override
  void didUpdateWidget(covariant ReaderPageView old) {
    super.didUpdateWidget(old);
    if (old.cacheKey != widget.cacheKey) {
      _image = null;
      _failed = false;
      _started = false;
      _syncHit();
    }
  }

  Future<void> _start() async {
    if (_started) return;
    _started = true;

    final tempDir = widget.tempDir;
    if (tempDir != null && tempDir.isNotEmpty) {
      final bytes = await TempStore.instance.get(
        tempDir,
        widget.ref.index,
        sourceId: widget.source.id,
        chapterId: widget.chapterId,
      );
      if (bytes != null && bytes.isNotEmpty) {
        final img = await ImageCacheManager.decodeScaled(
          bytes,
          targetWidth: widget.decodeWidth,
        );
        if (!mounted) return;
        setState(() {
          _image = img;
          _failed = img == null;
        });
        if (img == null) _started = false;
        return;
      }
    }

    var url = widget.ref.directUrl;
    if (url == null && widget.ref.resolveUrl != null) {
      url = await widget.source.resolvePageUrl(widget.ref.resolveUrl!);
    }
    if (url == null || url.isEmpty) {
      if (mounted) setState(() => _failed = true);
      _started = false;
      return;
    }

    final cached = ImageCacheManager.instance.getUiSync(url);
    if (cached != null) {
      if (mounted) setState(() => _image = cached);
      return;
    }

    final bytes = await ImageCacheManager.instance.load(
      url,
      fetcher: (u) async {
        final b = await JmApi.instance.fetchBytes(
          u,
          referer: widget.source.id == 'ehentai' ? widget.ref.resolveUrl : null,
        );
        if (b != null) return b;
        for (final alt in JmService.instance.imageUrlCandidates(u)) {
          final r = await JmApi.instance.fetchBytes(
            alt,
            referer:
                widget.source.id == 'ehentai' ? widget.ref.resolveUrl : null,
          );
          if (r != null) return r;
        }
        return null;
      },
    );
    if (bytes == null) {
      if (mounted) setState(() => _failed = true);
      _started = false;
      return;
    }

    var data = bytes;
    final sid = widget.scrambleId;
    if (sid != null &&
        ImageScrambler.needScramble(widget.scrambleAid, sid, url)) {
      final pk = ImageScrambler.pageKeyFromUrl(url, widget.ref.index);
      final seg = ImageScrambler.segments(widget.scrambleAid, pk);
      final jpg = await ImageWorker.instance.unscrambleToJpeg(
        bytes: bytes,
        segments: seg,
        maxWidth: widget.decodeWidth,
        quality: 92,
      );
      final img = await ImageCacheManager.decodeScaled(
        jpg ?? bytes,
        targetWidth: widget.decodeWidth,
      );
      if (img != null) ImageCacheManager.instance.putUi(url, img);
      if (!mounted) return;
      setState(() {
        _image = img;
        _failed = img == null;
      });
      if (img == null) _started = false;
      return;
    }

    final img = await ImageCacheManager.decodeScaled(
      data,
      targetWidth: widget.decodeWidth,
    );
    if (img != null) ImageCacheManager.instance.putUi(url, img);
    if (!mounted) return;
    setState(() {
      _image = img;
      _failed = img == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return GestureDetector(
        onTap: () {
          setState(() {
            _failed = false;
            _started = false;
          });
          _start();
        },
        child: Container(
          height: 200,
          alignment: Alignment.center,
          color: Colors.transparent,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.broken_image_outlined,
                color: Colors.white38,
                size: 28,
              ),
              const SizedBox(height: 6),
              Text(
                L.tp('pageNFailed', {'n': widget.ref.index}),
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
        ),
      );
    }
    final img = _image;
    if (img == null) {
      return AspectRatio(
        aspectRatio: widget.fallbackRatio <= 0 ? 0.72 : widget.fallbackRatio,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: Colors.white24,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                L.tp('pageN', {'n': widget.ref.index}),
                style: const TextStyle(color: Colors.white24, fontSize: 11),
              ),
            ],
          ),
        ),
      );
    }
    final ratio = img.width / img.height <= 0 ? 0.72 : img.width / img.height;
    widget.onLoaded?.call(ratio);
    return AspectRatio(
      aspectRatio: ratio,
      child: RawImage(
        image: img,
        fit: widget.fit,
        filterQuality: FilterQuality.low,
      ),
    );
  }
}
