import 'package:flutter/material.dart';

import '../core/l10n.dart';
import 'downloads_page.dart';
import 'imported_page.dart';

class DownloadsHubPage extends StatefulWidget {
  const DownloadsHubPage({super.key, this.initialTab = 0});

  final int initialTab;

  @override
  State<DownloadsHubPage> createState() => _DownloadsHubPageState();
}

class _DownloadsHubPageState extends State<DownloadsHubPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(
    length: 2,
    vsync: this,
    initialIndex: widget.initialTab.clamp(0, 1),
  );

  final _downloadsKey = GlobalKey<DownloadsPageState>();

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('myDownloads')),
        actions: [
          AnimatedBuilder(
            animation: _tab,
            builder: (context, _) {
              if (_tab.index != 0) return const SizedBox.shrink();
              final st = _downloadsKey.currentState;
              if (st == null) return const SizedBox.shrink();
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PopupMenuButton<DownloadSort>(
                    initialValue: st.sortMode,
                    tooltip: L.t('sort'),
                    icon: const Icon(Icons.sort_rounded, size: 20),
                    onSelected: st.setSort,
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: DownloadSort.name,
                        child: Text(L.t('sortByName')),
                      ),
                      PopupMenuItem(
                        value: DownloadSort.time,
                        child: Text(L.t('sortByDownloadTime')),
                      ),
                    ],
                  ),
                  if (st.hasCompleted)
                    IconButton(
                      tooltip: L.t('clear'),
                      icon: const Icon(
                        Icons.cleaning_services_outlined,
                        size: 20,
                      ),
                      onPressed: st.clearCompleted,
                    ),
                ],
              );
            },
          ),
          const SizedBox(width: 4),
        ],
        bottom: TabBar(
          controller: _tab,
          labelColor: scheme.primary,
          unselectedLabelColor: scheme.onSurfaceVariant,
          indicatorColor: scheme.primary,
          tabs: [
            Tab(text: L.t('downloadsTab')),
            Tab(text: L.t('imported')),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          DownloadsPage(key: _downloadsKey, embedded: true),
          const ImportedPage(embedded: true),
        ],
      ),
    );
  }
}
