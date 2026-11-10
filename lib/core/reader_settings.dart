import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ReaderTheme {
  final String id;
  final Color bg;
  final Color fg;
  final Color subtle;

  const ReaderTheme(this.id, this.bg, this.fg, this.subtle);

  static const List<ReaderTheme> all = [
    ReaderTheme('paper', Color(0xFFF6F1E7), Color(0xFF2B2B2B), Color(0xFF8A8375)),
    ReaderTheme('white', Color(0xFFFFFFFF), Color(0xFF1A1A1A), Color(0xFF9E9E9E)),
    ReaderTheme('green', Color(0xFFCCE8CF), Color(0xFF23331F), Color(0xFF6C8A6E)),
    ReaderTheme('blue', Color(0xFFD6E4F0), Color(0xFF1B2B3A), Color(0xFF6E8399)),
    ReaderTheme('dark', Color(0xFF1C1C1E), Color(0xFFD8D8D8), Color(0xFF7A7A7E)),
    ReaderTheme('black', Color(0xFF000000), Color(0xFFBFC2C6), Color(0xFF5A5C60)),
    ReaderTheme('night', Color(0xFF141A14), Color(0xFF8FA88F), Color(0xFF4E5F4E)),
  ];

  static ReaderTheme byId(String id) =>
      all.firstWhere((t) => t.id == id, orElse: () => all.first);
}

enum PageMode {
  cover,

  slide,

  none,

  scroll,
}

class ReaderSettings extends ChangeNotifier {
  ReaderSettings._();
  static final ReaderSettings instance = ReaderSettings._();

  static const _key = 'reader_settings_v2';

  double fontSize = 18;
  double lineHeight = 1.85;
  double letterSpacing = 0;
  double paragraphSpacing = 14;
  double marginH = 20;
  double marginV = 14;
  double indent = 2;

  TextAlign align = TextAlign.justify;
  int weightIndex = 0;
  int fontIndex = 0;

  String themeId = 'paper';
  bool followSystemTheme = false;

  PageMode pageMode = PageMode.slide;
  bool volumeKeyTurn = true;
  bool showProgress = true;
  bool showBattery = true;
  bool keepScreenOn = true;
  double brightness = 0;

  double ttsRate = 1.0;

  double ttsPitch = 1.0;

  String ttsVoiceName = '';

  double autoScrollSpeed = 40;

  int readingSecondsTotal = 0;

  ReaderTheme get theme {
    if (!followSystemTheme) return ReaderTheme.byId(themeId);

    final appDark = _appIsDark();
    return ReaderTheme.byId(appDark ? 'dark' : 'paper');
  }

  bool _appIsDark() {
    try {
      final mode = appThemeMode?.call();
      if (mode != null) {
        if (mode == 'dark') return true;
        if (mode == 'light') return false;
      }
    } catch (_) {}
    return WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
  }

  static String? Function()? appThemeMode;

  FontWeight get weight => switch (weightIndex) {
        1 => FontWeight.w500,
        2 => FontWeight.w700,
        _ => FontWeight.w400,
      };

  String? get fontFamily {
    switch (fontIndex) {
      case 1:
        return 'serif';
      default:
        return null;
    }
  }

  TextStyle textStyleFor(ReaderTheme t) => TextStyle(
        fontSize: fontSize,
        height: lineHeight,
        letterSpacing: letterSpacing,
        fontWeight: weight,
        fontFamily: fontFamily,
        color: t.fg,
      );

  Future<void> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        fontSize = (m['fontSize'] as num?)?.toDouble() ?? fontSize;
        lineHeight = (m['lineHeight'] as num?)?.toDouble() ?? lineHeight;
        letterSpacing = (m['letterSpacing'] as num?)?.toDouble() ?? letterSpacing;
        paragraphSpacing =
            (m['paragraphSpacing'] as num?)?.toDouble() ?? paragraphSpacing;
        marginH = (m['marginH'] as num?)?.toDouble() ?? marginH;
        marginV = (m['marginV'] as num?)?.toDouble() ?? marginV;
        indent = (m['indent'] as num?)?.toDouble() ?? indent;
        align = switch (m['align']) {
          'left' => TextAlign.left,
          'center' => TextAlign.center,
          'right' => TextAlign.right,
          _ => TextAlign.justify,
        };
        weightIndex = (m['weightIndex'] as num?)?.toInt() ?? weightIndex;
        fontIndex = (m['fontIndex'] as num?)?.toInt() ?? fontIndex;
        themeId = (m['themeId'] as String?) ?? themeId;
        followSystemTheme = (m['followSystemTheme'] as bool?) ?? false;
        pageMode = switch (m['pageMode']) {
          'cover' => PageMode.cover,
          'none' => PageMode.none,
          'scroll' => PageMode.scroll,
          _ => PageMode.slide,
        };
        volumeKeyTurn = (m['volumeKeyTurn'] as bool?) ?? volumeKeyTurn;
        showProgress = (m['showProgress'] as bool?) ?? showProgress;
        showBattery = (m['showBattery'] as bool?) ?? showBattery;
        keepScreenOn = (m['keepScreenOn'] as bool?) ?? keepScreenOn;
        brightness = (m['brightness'] as num?)?.toDouble() ?? brightness;
      ttsRate = (m['ttsRate'] as num?)?.toDouble() ?? ttsRate;
      ttsPitch = (m['ttsPitch'] as num?)?.toDouble() ?? ttsPitch;
      ttsVoiceName = (m['ttsVoiceName'] as String?) ?? ttsVoiceName;
      autoScrollSpeed =
          (m['autoScrollSpeed'] as num?)?.toDouble() ?? autoScrollSpeed;
        readingSecondsTotal =
            (m['readingSecondsTotal'] as num?)?.toInt() ?? readingSecondsTotal;
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> save() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
        _key,
        jsonEncode({
          'fontSize': fontSize,
          'lineHeight': lineHeight,
          'letterSpacing': letterSpacing,
          'paragraphSpacing': paragraphSpacing,
          'marginH': marginH,
          'marginV': marginV,
          'indent': indent,
          'align': switch (align) {
            TextAlign.left => 'left',
            TextAlign.center => 'center',
            TextAlign.right => 'right',
            _ => 'justify',
          },
          'weightIndex': weightIndex,
          'fontIndex': fontIndex,
          'themeId': themeId,
          'followSystemTheme': followSystemTheme,
          'pageMode': switch (pageMode) {
            PageMode.cover => 'cover',
            PageMode.none => 'none',
            PageMode.scroll => 'scroll',
            PageMode.slide => 'slide',
          },
          'volumeKeyTurn': volumeKeyTurn,
          'showProgress': showProgress,
          'showBattery': showBattery,
          'keepScreenOn': keepScreenOn,
          'brightness': brightness,
        'ttsRate': ttsRate,
        'ttsPitch': ttsPitch,
        'ttsVoiceName': ttsVoiceName,
        'autoScrollSpeed': autoScrollSpeed,
          'readingSecondsTotal': readingSecondsTotal,
        }),
      );
    } catch (_) {}
  }

  void update(VoidCallback fn) {
    fn();
    notifyListeners();
    save();
  }

  void addReadingSeconds(int s) {
    readingSecondsTotal += s;
    save();
  }
}
