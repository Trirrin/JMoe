import 'dart:async';

import 'package:flutter/material.dart';
import 'core/collect_store.dart';
import 'core/host_store.dart';
import 'core/subscription_checker.dart';
import 'core/subscription_store.dart';
import 'widgets/clipboard_link_watcher.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';

import 'core/app_log.dart';
import 'core/app_state.dart';
import 'core/jm_protocol.dart';
import 'core/app_theme.dart';
import 'core/downloader.dart';
import 'core/image_cache.dart';
import 'core/jm_service.dart';
import 'core/l10n.dart';
import 'core/reader_settings.dart';
import 'core/reading_stats.dart';
import 'core/temp_store.dart';
import 'pages/startup_host_page.dart';
import 'pages/main_page.dart';

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
    if (state.loggedIn) {
      unawaited(_verifyLogin());
    }
    try {
      await ImageCacheManager.instance.diskUsage();
    } catch (_) {}
  }

  Future<void> _verifyLogin() async {
    final valid = await JmService.instance.verifySession();
    if (valid != false) return;
    final state = AppState.instance;
    await state.saveSession(null, null);
    JmApi.instance.jwtToken = null;
    JmApi.instance.cookieValue = null;
    unawaited(AppLog.instance.log('AUTH', 'session expired, logged out'));
    print('[JMOE] session expired → cleared local session');
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
  ReaderSettings.appThemeMode = () => switch (AppState.instance.themeMode) {
        ThemeMode.dark => 'dark',
        ThemeMode.light => 'light',
        ThemeMode.system => 'system',
      };
  await ReadingStats.instance.load();
  await SubscriptionStore.instance.load();
  SubscriptionStore.instance.loadAuthorBaselines();
  await CollectStore.instance.load();
  await HostStore.instance.load();
  SubscriptionChecker.instance.start();
  await ChapterDownloader.restoreFromDisk();
  unawaited(TempStore.instance.sweepOnStartup());
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
      title: 'JMoe',
      debugShowCheckedModeBanner: false,
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
          child: ClipboardLinkWatcher(
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
      home: const AppBootstrap(),
    );
  }
}
