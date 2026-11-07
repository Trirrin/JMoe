import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';

import 'core/app_state.dart';
import 'core/app_theme.dart';
import 'core/downloader.dart';
import 'core/image_cache.dart';
import 'core/jm_service.dart';
import 'core/l10n.dart';
import 'core/reader_settings.dart';
import 'core/reading_stats.dart';
import 'pages/startup_host_page.dart';
import 'pages/main_page.dart';

/// 应用引导状态机：
///   splash → hostPick（测速/选线）→ main
class AppBootstrap extends StatefulWidget {
  const AppBootstrap({super.key});

  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    // 全局透明状态栏。图标明暗由各页面的 AppBar / AnnotatedRegion 决定，
    // 这里只兜底初始值（浅色主题 → 深色图标），避免启动页图标看不见。
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
    );
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
    );
  }

  Future<void> _onEnterMain() async {
    // 进入主界面前补齐设置（不阻塞首帧）
    unawaited(_postInit());
    setState(() => _ready = true);
  }

  Future<void> _postInit() async {
    final state = AppState.instance;
    try {
      await JmService.instance
          .loadSettings(imgShunt: state.imageShunt)
          .timeout(const Duration(seconds: 12));
    } catch (_) {}
    try {
      await ImageCacheManager.instance.diskUsage();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return const MainPage();
    return StartupHostPage(onReady: _onEnterMain);
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await L.load();
  await AppState.instance.init();
  await ReaderSettings.instance.load();
  // 让阅读器主题跟随 App 的深浅色设置（而非系统设置）
  ReaderSettings.appThemeMode = () => switch (AppState.instance.themeMode) {
        ThemeMode.dark => 'dark',
        ThemeMode.light => 'light',
        ThemeMode.system => 'system',
      };
  await ReadingStats.instance.load();
  // 恢复已下载记录（扫描磁盘上的 meta.json，重启后仍可见）
  await ChapterDownloader.restoreFromDisk();
  runApp(const JmoeApp());
}

class JmoeApp extends StatefulWidget {
  const JmoeApp({super.key});

  @override
  State<JmoeApp> createState() => _JmoeAppState();
}

class _JmoeAppState extends State<JmoeApp> {
  @override
  void initState() {
    super.initState();
    AppState.instance.addListener(_onStateChanged);
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_onStateChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return MaterialApp(
      // 语言变化时用 key 强制重建整棵树，确保所有页面文案立即同步，
      // 而不是等到用户操作某个控件触发局部重绘才更新。
      key: ValueKey('app_${state.uiLang}'),
      title: 'JMoe',
      debugShowCheckedModeBanner: false,
      // 系统组件（复制/粘贴/全选等）跟随中文，不再显示英文
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('zh', 'TW'),
        Locale('en'),
      ],
      locale: state.uiLang == 'en'
          ? const Locale('en')
          : state.uiLang == 'zh-Hant'
              ? const Locale('zh', 'TW')
              : const Locale('zh', 'CN'),
      theme: buildAppTheme(state.seedColor, Brightness.light),
      darkTheme: buildAppTheme(
        state.seedColor,
        Brightness.dark,
        oled: state.oledMode,
      ),
      themeMode: state.themeMode,
      // 统一由根节点控制状态栏/导航栏图标明暗：
      // 浅色主题 → 深色图标，深色主题 → 浅色图标。
      // 这样启动页与主界面表现一致，不会出现「启动页任务栏不变色」。
      builder: (context, child) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
            statusBarBrightness:
                isDark ? Brightness.dark : Brightness.light,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const AppBootstrap(),
    );
  }
}
