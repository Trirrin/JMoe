import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/downloader.dart';
import '../core/jmoe_archive.dart';
import '../core/l10n.dart';

/// 阅读一个 `.jmoe` 加密包（离线，逐页解密）。
///
/// 与在线阅读器保持一致的交互：点按切换 UI、左右翻页、缩放手势。
class JmoeArchiveReaderPage extends StatefulWidget {
  const JmoeArchiveReaderPage({
    super.key,
    required this.file,
    required this.title,
    this.meta = const {},
  });

  final File file;
  final String title;
  final Map<String, dynamic> meta;

  /// 打开某目录（复用下载器里的原生能力）。
  static Future<bool> openFolder(String path) =>
      ChapterDownloader.openFolder(path);

  @override
  State<JmoeArchiveReaderPage> createState() => _JmoeArchiveReaderPageState();
}

class _JmoeArchiveReaderPageState extends State<JmoeArchiveReaderPage> {
  List<Uint8List>? _pages;
  bool _loading = true;
  String? _error;
  int _index = 0;
  bool _showUi = true;
  final _ctrl = PageController();

  /// 包内章节 id（用于派生解密密钥）
  String get _chapterId => '${widget.meta['chapterId'] ?? widget.title}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final pages = await JmoeArchive.readAll(
      widget.file.path,
      chapterId: _chapterId,
    );
    if (!mounted) return;
    setState(() {
      _pages = pages;
      _loading = false;
      if (pages == null || pages.isEmpty) {
        _error = L.t('archiveBroken');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = _pages;
    // 作品信息（来自包内 albumMeta），有就展示在顶栏下方
    final albumTitle = '${widget.meta['albumName'] ?? widget.meta['title'] ?? ''}';
    final author = '${widget.meta['author'] ?? ''}';
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.white70),
                  )
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.lock_outline_rounded,
                                color: Colors.white38,
                                size: 44,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 16),
                              FilledButton.tonal(
                                onPressed: _load,
                                child: Text(L.t('retry')),
                              ),
                            ],
                          ),
                        ),
                      )
                    : GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => _showUi = !_showUi),
                        child: PageView.builder(
                          controller: _ctrl,
                          itemCount: pages!.length,
                          onPageChanged: (i) => setState(() => _index = i),
                          itemBuilder: (context, i) => InteractiveViewer(
                            maxScale: 4,
                            child: Center(
                              child: Image.memory(
                                pages[i],
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                              ),
                            ),
                          ),
                        ),
                      ),
          ),
          // 顶栏
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            top: _showUi ? 0 : -160,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + 4,
                bottom: 8,
                left: 4,
                right: 8,
              ),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        // 作品名 / 作者（来自包内元数据）
                        if (albumTitle.isNotEmpty || author.isNotEmpty)
                          Text(
                            [
                              if (albumTitle.isNotEmpty) albumTitle,
                              if (author.isNotEmpty) author,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 10.5,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.only(right: 4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.lock_rounded,
                          size: 11,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          L.t('importedBadge'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 底栏：页码
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            bottom: _showUi ? 0 : -100,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 10,
                bottom: MediaQuery.of(context).padding.bottom + 10,
              ),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
              child: Text(
                pages == null || pages.isEmpty
                    ? '0'
                    : '${_index + 1}/${pages.length}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
