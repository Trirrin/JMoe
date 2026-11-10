import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_theme.dart';
import '../core/favorites_backup.dart';
import '../core/jmoe_archive.dart';
import '../core/l10n.dart';
import '../widgets/common_widgets.dart';
import 'jmoe_archive_reader_page.dart';

class FilePickerChannel {
  FilePickerChannel._();
  static const _ch = MethodChannel('jmoe/reader');

  static Future<String?> pickFile({
    List<String> extensions = const [],
    String? mimeType,
  }) async {
    try {
      return await _ch.invokeMethod<String>('pickFile', {
        'extensions': extensions,
        'mime': ?mimeType,
      });
    } catch (_) {
      return null;
    }
  }

  static Future<String?> pickSavePath({
    required String suggestedName,
  }) async {
    try {
      return await _ch.invokeMethod<String>('pickSavePath', {
        'name': suggestedName,
      });
    } catch (_) {
      return null;
    }
  }
}

class ImportedPage extends StatefulWidget {
  const ImportedPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  State<ImportedPage> createState() => _ImportedPageState();
}

class _ImportedPageState extends State<ImportedPage> {
  bool _loading = true;
  bool _importing = false;
  final _items = <_ImportedItem>[];

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<Directory> _dir() async {
    final d = Directory(await FavoritesBackup.appSubDir('imported'));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  Future<void> _scan() async {
    setState(() => _loading = true);
    final out = <_ImportedItem>[];
    try {
      final dir = await _dir();
      for (final f in dir.listSync().whereType<File>()) {
        if (!JmoeArchive.isArchiveName(f.path)) continue;
        final count = await JmoeArchive.pageCount(f.path);
        final meta = await JmoeArchive.readAlbumMeta(f.path) ?? const {};
        final fallbackName = f.uri.pathSegments.last
            .replaceAll('.jmoe', '')
            .replaceAll('_', ' ');
        final title = '${meta['chapterName'] ?? meta['title'] ?? fallbackName}';
        out.add(
          _ImportedItem(
            file: f,
            title: title.isEmpty ? fallbackName : title,
            albumTitle: '${meta['albumName'] ?? meta['title'] ?? ''}',
            pageCount: count,
            meta: meta,
          ),
        );
      }
      out.sort((a, b) => a.title.compareTo(b.title));
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _items
        ..clear()
        ..addAll(out);
      _loading = false;
    });
  }

  Future<void> _importFromPicker() async {
    if (_importing) return;
    setState(() => _importing = true);
    final path = await FilePickerChannel.pickFile(extensions: ['jmoe']);
    if (!mounted) {
      return;
    }
    if (path == null) {
      setState(() => _importing = false);
      return;
    }
    try {
      final src = File(path);
      if (!await src.exists()) {
        throw const FileSystemException('source missing');
      }
      final count = await JmoeArchive.pageCount(path);
      if (count <= 0) {
        if (mounted) {
          setState(() => _importing = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(L.t('archiveBroken'))),
          );
        }
        return;
      }
      final dir = await _dir();
      final base = src.uri.pathSegments.last;
      final target = File('${dir.path}/$base');
      if (target.path != src.path) {
        await src.copy(target.path);
      }
      if (!mounted) return;
      setState(() => _importing = false);
      await _scan();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L.t('importedOk'))),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _importing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L.tp('importFailedWith', {'e': '$e'}))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final body = RefreshIndicator(
        onRefresh: _scan,
        edgeOffset: MediaQuery.of(context).padding.top,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _items.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      SizedBox(
                        height: MediaQuery.of(context).size.height * 0.25,
                      ),
                      EmptyView(
                        message: L.t('importedEmpty'),
                        icon: Icons.inbox_outlined,
                      ),
                    ],
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(AppStyle.pagePadding),
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: _items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final it = _items[i];
                      return Card(
                        child: ListTile(
                          leading: SizedBox(
                            width: 46,
                            height: 62,
                            child: Container(
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Icon(
                                Icons.lock_outline_rounded,
                                size: 20,
                              ),
                            ),
                          ),
                          title: Text(
                            it.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            [
                              if (it.albumTitle.isNotEmpty) it.albumTitle,
                              L.tp('importedMeta', {
                                'p': '${it.pageCount}',
                                's': _fmtSize(it.file.lengthSync()),
                              }),
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                          trailing: IconButton(
                            tooltip: L.t('delete'),
                            icon: Icon(
                              Icons.delete_outline_rounded,
                              size: 18,
                              color: scheme.error,
                            ),
                            onPressed: () async {
                              try {
                                await it.file.delete();
                              } catch (_) {}
                              await _scan();
                            },
                          ),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => JmoeArchiveReaderPage(
                                  file: it.file,
                                  title: it.title,
                                  meta: it.meta,
                                ),
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
      );

    final toolbar = Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        IconButton(
          tooltip: L.t('openFolder'),
          icon: const Icon(Icons.folder_open_rounded, size: 20),
          onPressed: () async {
            final d = await _dir();
            if (!mounted) return;
            await FavoritesBackup.openFolder(d.path);
          },
        ),
        TextButton.icon(
          onPressed: _importing ? null : _importFromPicker,
          icon: _importing
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.file_open_rounded, size: 18),
          label: Text(
            L.t('importFile'),
            style: const TextStyle(fontSize: 12.5),
          ),
        ),
        const SizedBox(width: 4),
      ],
    );

    if (widget.embedded) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: toolbar,
          ),
          Expanded(child: body),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('imported')),
        actions: [toolbar],
      ),
      body: body,
    );
  }

  String _fmtSize(int b) {
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

class _ImportedItem {
  final File file;
  final String title;

  final String albumTitle;
  final int pageCount;
  final Map<String, dynamic> meta;

  const _ImportedItem({
    required this.file,
    required this.title,
    required this.pageCount,
    this.albumTitle = '',
    this.meta = const {},
  });
}
