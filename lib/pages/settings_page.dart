import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/app_theme.dart';
import '../core/jm_protocol.dart';
import '../core/jm_service.dart';
import '../widgets/common_widgets.dart';
import 'language_page.dart';
import 'login_page.dart';
import 'account_page.dart';
import 'host_manage_page.dart';
import 'storage_page.dart';
import '../core/l10n.dart';

/// 「我的」：账号 + 设置（主题/线路/阅读/关于）。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final state = AppState.instance;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                L.t('my'),
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            _buildAccountCard(theme, state),
            SectionHeader(title: L.t('appearance')),
            _buildThemeTile(theme, state),
            _buildOledTile(theme, state),
            _buildColorTile(theme, state),
            SectionHeader(title: L.t('reading')),
            _buildReaderModeTile(theme, state),
            _buildStartTabTile(theme, state),
            _buildBannerTile(theme, state),
            _buildCardSizeTile(theme, state),
            _buildPrefetchTile(theme, state),
            _buildImageQualityTile(theme, state),
            SectionHeader(title: L.t('behavior')),
            _buildAutoEnterTile(theme, state),
            _buildConfirmDeleteTile(theme, state),
            SectionHeader(title: L.t('network')),
            _buildNetLimitTile(theme, state),
            _buildHostTile(theme, state),
            _buildLanguageEntry(theme, state),
                        _buildStorageEntry(theme, state),
            SectionHeader(title: L.t('about')),
            ListTile(
              leading: const Icon(Icons.settings_applications_outlined),
              title: Text(L.t('version')),
              subtitle: Text(L.tp('aboutVersion', {'v': '1.3.0', 'p': '2.1.12'})),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => showAboutDialog(
                context: context,
                applicationName: 'JMoe',
                applicationVersion: L.tp('versionWithProto', {'v': '1.3.0', 'p': '2.1.12'}),
                applicationIcon: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Icon(
                    Icons.auto_stories,
                    size: 40,
                    color: theme.colorScheme.primary,
                  ),
                ),
                applicationLegalese:
                    '${L.t('aboutAuthor')}\n'
                    'GitHub: github.com/liuyuexiaoyu1\n'
                    '${L.t('aboutLicense')}\n\n'
                    '${L.t('aboutDesc')}'
              ),
            ),
            // 「清除所有数据」统一放在「存储管理」里，设置页不再重复入口
          ],
        ),
      ),
    );
  }

  Widget _buildAccountCard(ThemeData theme, AppState state) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Card(
        child: InkWell(
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => state.loggedIn
                    ? const AccountPage()
                    : const LoginPage(),
              ),
            );
            setState(() {});
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Icon(
                    Icons.person,
                    color: theme.colorScheme.onPrimaryContainer,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        state.loggedIn ? state.userName : L.t('notLoggedIn'),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        state.loggedIn
                            ? L.t('settingsAccountManage')
                            : L.t('settingsAccountGuest'),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (state.loggedIn)
                  TextButton(
                    onPressed: () async {
                      await JmService.instance.logout();
                      await state.saveSession(null, null);
                      JmApi.instance.jwtToken = null;
                      JmApi.instance.cookieValue = null;
                      setState(() {});
                    },
                    child: Text(L.t('logout')),
                  )
                else
                  const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildThemeTile(ThemeData theme, AppState state) {
    return ListTile(
      leading: const Icon(Icons.brightness_6_outlined),
      title: Text(L.t('themeMode')),
      subtitle: Text(switch (state.themeMode) {
        ThemeMode.light => L.t('themeLight'),
        ThemeMode.dark => L.t('themeDark'),
        _ => L.t('themeSystem'),
      }),
      trailing: SegmentedButton<ThemeMode>(
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: const [
          ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode, size: 16)),
          ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto, size: 16)),
          ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode, size: 16)),
        ],
        selected: {state.themeMode},
        onSelectionChanged: (s) {
          state.setThemeMode(s.first);
          setState(() {});
        },
      ),
    );
  }

  Widget _buildOledTile(ThemeData theme, AppState state) {
    return SwitchListTile(
      secondary: const Icon(Icons.contrast),
      title: Text(L.t('oledMode')),
      subtitle: Text(L.t('oledDesc')),
      value: state.oledMode,
      onChanged: (v) {
        state.setOled(v);
        setState(() {});
      },
    );
  }

  Widget _buildColorTile(ThemeData theme, AppState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.palette_outlined, size: 20),
              const SizedBox(width: 16),
              Text(L.t('themeColor')),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: AppStyle.colorSeeds.map((c) {
              final color = c['color'] as Color;
              final active = state.seedColor.toARGB32() == color.toARGB32();
              return GestureDetector(
                onTap: () {
                  state.setSeedColor(color);
                  setState(() {});
                },
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: active
                        ? Border.all(
                            color: theme.colorScheme.onSurface,
                            width: 2.5,
                          )
                        : null,
                  ),
                  child: active
                      ? const Icon(Icons.check, size: 18, color: Colors.white)
                      : null,
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildReaderModeTile(ThemeData theme, AppState state) {
    return ListTile(
      leading: const Icon(Icons.auto_stories_outlined),
      title: Text(L.t('readerDirection')),
      subtitle: Text(state.readerMode == 'vertical' ? L.t('readerVertical') : L.t('readerHorizontal')),
      trailing: SegmentedButton<String>(
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: const [
          ButtonSegment(value: 'vertical', icon: Icon(Icons.swap_vert, size: 16)),
          ButtonSegment(value: 'horizontal', icon: Icon(Icons.swap_horiz, size: 16)),
        ],
        selected: {state.readerMode},
        onSelectionChanged: (s) {
          state.setReaderMode(s.first);
          setState(() {});
        },
      ),
    );
  }


  /// 启动默认页。
  Widget _buildStartTabTile(ThemeData theme, AppState state) {
    return ListTile(
      leading: const Icon(Icons.start_rounded),
      title: Text(L.t('startTab')),
      subtitle: Text(switch (state.startTab) {
        1 => L.t('tabCategories'),
        2 => L.t('tabShelf'),
        _ => L.t('tabDiscover'),
      }),
      trailing: SegmentedButton<int>(
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: const [
          ButtonSegment(value: 0, icon: Icon(Icons.explore, size: 16)),
          ButtonSegment(value: 1, icon: Icon(Icons.grid_view, size: 16)),
          ButtonSegment(value: 2, icon: Icon(Icons.collections_bookmark, size: 16)),
        ],
        selected: {state.startTab},
        onSelectionChanged: (v) {
          state.setStartTab(v.first);
          setState(() {});
        },
      ),
    );
  }

  /// 首页海报自动轮播。
  Widget _buildBannerTile(ThemeData theme, AppState state) {
    return SwitchListTile(
      secondary: const Icon(Icons.slideshow_outlined),
      title: Text(L.t('bannerAutoPlay')),
      subtitle: Text(L.t('bannerAutoPlayDesc')),
      value: state.bannerAutoPlay,
      onChanged: (v) {
        state.setBannerAutoPlay(v);
        setState(() {});
      },
    );
  }

  /// 网络限速（Mbps）。
  Widget _buildNetLimitTile(ThemeData theme, AppState state) {
    return ListTile(
      leading: const Icon(Icons.speed_rounded),
      title: Text(L.t('netLimit')),
      subtitle: Text(
        state.netLimitMbps == 0
            ? L.t('unlimited')
            : '${state.netLimitMbps} Mbps',
      ),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () async {
        const options = [0, 2, 5, 10, 20, 50, 100];
        final sel = await showModalBottomSheet<int>(
          context: context,
          showDragHandle: true,
          builder: (c) => ListView(
            shrinkWrap: true,
            children: options
                .map(
                  (v) => ListTile(
                    title: Text(
                      v == 0 ? L.t('unlimited') : '$v Mbps',
                    ),
                    trailing: state.netLimitMbps == v
                        ? const Icon(Icons.check, size: 18)
                        : null,
                    onTap: () => Navigator.pop(c, v),
                  ),
                )
                .toList(),
          ),
        );
        if (sel != null) {
          await state.setNetLimitMbps(sel);
          setState(() {});
        }
      },
    );
  }

  /// 列表卡片大小。
  Widget _buildCardSizeTile(ThemeData theme, AppState state) {
    return ListTile(
      leading: const Icon(Icons.grid_view_rounded),
      title: Text(L.t('listDensity')),
      subtitle: Text(switch (state.cardSize) {
        'compact' => L.t('densityCompactDesc'),
        'large' => L.t('densityLargeDesc'),
        _ => L.t('densityNormalDesc'),
      }),
      trailing: SegmentedButton<String>(
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: const [
          ButtonSegment(value: 'compact', icon: Icon(Icons.view_list, size: 16)),
          ButtonSegment(value: 'normal', icon: Icon(Icons.grid_view, size: 16)),
          ButtonSegment(value: 'large', icon: Icon(Icons.view_agenda, size: 16)),
        ],
        selected: {state.cardSize},
        onSelectionChanged: (v) {
          state.setCardSize(v.first);
          setState(() {});
        },
      ),
    );
  }

  /// 阅读时自动预取下一章。
  Widget _buildPrefetchTile(ThemeData theme, AppState state) {
    return SwitchListTile(
      secondary: const Icon(Icons.auto_awesome_motion_outlined),
      title: Text(L.t('prefetchNext')),
      subtitle: Text(L.t('prefetchNextDesc')),
      value: state.prefetchNextChapter,
      onChanged: (v) {
        state.setPrefetchNextChapter(v);
        setState(() {});
      },
    );
  }

  /// 缩略图质量。
  Widget _buildImageQualityTile(ThemeData theme, AppState state) {
    return ListTile(
      leading: const Icon(Icons.high_quality_outlined),
      title: Text(L.t('imageQuality')),
      subtitle: Text(switch (state.imageQuality) {
        'low' => L.t('qualityLow'),
        'high' => L.t('qualityHigh'),
        _ => L.t('qualityMedium'),
      }),
      trailing: SegmentedButton<String>(
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: const [
          ButtonSegment(
            value: 'low',
            label: Text('S', style: TextStyle(fontSize: 12)),
          ),
          ButtonSegment(
            value: 'medium',
            label: Text('M', style: TextStyle(fontSize: 12)),
          ),
          ButtonSegment(
            value: 'high',
            label: Text('L', style: TextStyle(fontSize: 12)),
          ),
        ],
        selected: {state.imageQuality},
        onSelectionChanged: (v) {
          state.setImageQuality(v.first);
          setState(() {});
        },
      ),
    );
  }

  /// 启动页是否自动进入。
  Widget _buildAutoEnterTile(ThemeData theme, AppState state) {
    return SwitchListTile(
      secondary: const Icon(Icons.login_rounded),
      title: Text(L.t('autoEnterStartup')),
      subtitle: Text(L.t('autoEnterStartupDesc')),
      value: state.autoEnterStartup,
      onChanged: (v) {
        state.setAutoEnterStartup(v);
        setState(() {});
      },
    );
  }

  /// 删除操作二次确认。
  Widget _buildConfirmDeleteTile(ThemeData theme, AppState state) {
    return SwitchListTile(
      secondary: const Icon(Icons.verified_user_outlined),
      title: Text(L.t('confirmDelete')),
      subtitle: Text(L.t('confirmDeleteDesc')),
      value: state.confirmDelete,
      onChanged: (v) {
        state.setConfirmDelete(v);
        setState(() {});
      },
    );
  }

  Widget _buildHostTile(ThemeData theme, AppState state) {
    return ListTile(
      leading: const Icon(Icons.dns_outlined),
      title: Text(L.t('apiLine')),
      subtitle: Text(JmApi.instance.host),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const HostManagePage()),
        );
        if (mounted) setState(() {});
      },
    );
  }

  /// 统一「语言」入口 → 语言管理页（界面语言 + 内容语言）。
  Widget _buildLanguageEntry(ThemeData theme, AppState state) {
    return ListTile(
      leading: const Icon(Icons.translate),
      title: Text(L.t('languageManage')),
      subtitle: Text(
        '${L.t(state.uiLang)} · ${state.lang}',
        style: const TextStyle(fontSize: 11.5),
      ),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const LanguagePage()),
        );
        if (mounted) setState(() {});
      },
    );
  }

  /// 缓存管理入口。
  /// 存储管理入口：占用饼图 + 分类清理 + 配置导入导出。
  Widget _buildStorageEntry(ThemeData theme, AppState state) {
    return ListTile(
      leading: const Icon(Icons.pie_chart_outline_rounded),
      title: Text(L.t('storageManage')),
      subtitle: Text(L.t('storageManageDesc')),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const StoragePage()),
        );
        if (mounted) setState(() {});
      },
    );
  }
}
