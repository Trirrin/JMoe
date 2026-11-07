import 'package:flutter/material.dart';

import '../../core/chapter_cache.dart';
import '../../core/l10n.dart';

/// 整章缓存蒙版：模糊封面背景 + 统一进度条 + xx/xx。
///
/// 提供三种选择：
///  * 等待缓存完成（默认，进度到 100% 自动消失）
///  * 边看边缓存（立即进入阅读）
///  * 取消缓存
class CacheOverlay extends StatefulWidget {
  final ChapterCacheTask task;
  final VoidCallback onWait;
  final VoidCallback onReadNow;
  final VoidCallback onCancel;

  const CacheOverlay({
    super.key,
    required this.task,
    required this.onWait,
    required this.onReadNow,
    required this.onCancel,
  });

  @override
  State<CacheOverlay> createState() => _CacheOverlayState();
}

class _CacheOverlayState extends State<CacheOverlay> {
  @override
  void initState() {
    super.initState();
    ChapterCacheManager.instance.revision.addListener(_tick);
  }

  @override
  void dispose() {
    ChapterCacheManager.instance.revision.removeListener(_tick);
    super.dispose();
  }

  void _tick() {
    if (!mounted) return;
    setState(() {});
    // 缓存完成 → 自动关闭蒙版并进入阅读
    if (widget.task.isCompleted) {
      widget.onWait();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.task;
    final scheme = Theme.of(context).colorScheme;
    final percent = (t.progress * 100).round();
    final done = t.done;
    final total = t.total;

    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.82),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.downloading_rounded,
                size: 34,
                color: Colors.white70,
              ),
              const SizedBox(height: 14),
              Text(
                t.bundle.chapterName.isNotEmpty
                    ? t.bundle.chapterName
                    : L.t('cachedVersion'),
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 20),
              // 明显进度条
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: t.progress,
                  minHeight: 6,
                  backgroundColor: Colors.white24,
                  valueColor: AlwaysStoppedAnimation(scheme.primary),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '$done/$total',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    '$percent%',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: widget.onCancel,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        side: const BorderSide(color: Colors.white24),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: Text(L.t('cancel')),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: widget.onReadNow,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: Text(L.t('cacheWhileReading')),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                L.t('cacheInBackground'),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 10.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
