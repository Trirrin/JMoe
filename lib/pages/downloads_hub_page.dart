import 'package:flutter/material.dart';

import '../core/l10n.dart';
import 'downloads_page.dart';
import 'imported_page.dart';

/// 「下载」页：把原来的「我的下载」与「我导入」合并到一个页面。
///
/// 两个功能本质是同一件事的两端：
///  * **下载**：App 自己下载保存的内容
///  * **导入**：外部放进来的 `.jmoe` 包
/// 用户管理「本地内容」时不应该在两个入口之间来回切换，
/// 所以合并成一个页面、用两个 Tab 区分。
///
/// 布局：Tab 栏右侧直接放排序/清空按钮（不再单独占一行，
/// 避免把内容整体往下推）。
class DownloadsHubPage extends StatefulWidget {
  const DownloadsHubPage({super.key, this.initialTab = 0});

  /// 0 = 下载，1 = 导入
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

  /// 用来把「排序 / 清空」这两个动作转发给内嵌的下载页
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
          // 只在「下载」Tab 显示排序/清空（导入 Tab 没有这些概念）
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
