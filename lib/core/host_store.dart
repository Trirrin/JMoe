import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一条自定义线路。
class CustomHost {
  /// 主机名，如 `www.example.com` 或完整 `https://host/`
  final String host;

  /// 显示名（空则用 host）
  final String label;

  /// 备注（可选，方便用户区分来源）
  final String note;

  final int at;

  const CustomHost({
    required this.host,
    this.label = '',
    this.note = '',
    required this.at,
  });

  String get displayName => label.isEmpty ? host : label;

  Map<String, dynamic> toJson() => {
        'host': host,
        'label': label,
        'note': note,
        'at': at,
      };

  static CustomHost fromJson(Map<String, dynamic> m) => CustomHost(
        host: '${m['host'] ?? ''}',
        label: '${m['label'] ?? ''}',
        note: '${m['note'] ?? ''}',
        at: (m['at'] as num?)?.toInt() ?? 0,
      );
}

/// 线路管理：自定义线路 + 「固定线路」偏好。
///
/// 用户诉求：
///  * 可以添加**自定义线路**，它要出现在线路列表里，启动时也能看到
///  * 可以**固定一条线路**，之后启动直接跳过启动页
class HostStore extends ChangeNotifier {
  HostStore._();
  static final HostStore instance = HostStore._();

  static const _kCustom = 'customHosts';
  static const _kSkipStartup = 'skipStartup';

  SharedPreferences? _prefs;

  final List<CustomHost> _custom = [];

  /// 是否启动时跳过启动页。
  ///
  /// 开启后直接用「上次进入所用的线路」连接（AppState.apiHost），
  /// 不需要单独「固定线路」—— 少一个概念、少一处不一致。
  bool skipStartup = false;

  List<CustomHost> get customHosts => List.unmodifiable(_custom);

  /// 供启动页/设置页统一使用的线路表：内置 + 服务器 + 自定义。
  ///
  /// 返回 `[host, label]` 形式，与 JmApi.hosts 结构一致，
  /// 便于直接合并展示。
  List<List<String>> mergeWith(List<List<String>> base) {
    final out = <List<String>>[];
    final seen = <String>{};
    for (final b in base) {
      if (b.isEmpty) continue;
      final h = b[0];
      if (seen.contains(h)) continue;
      seen.add(h);
      out.add([h, b.length > 1 ? b[1] : h]);
    }
    // 自定义线路排在末尾，标注「自定义」
    for (final c in _custom) {
      if (seen.contains(c.host)) continue;
      seen.add(c.host);
      out.add([c.host, c.displayName]);
    }
    return out;
  }

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    skipStartup = _prefs?.getBool(_kSkipStartup) ?? false;
    final raw = _prefs?.getString(_kCustom);
    if (raw != null && raw.isNotEmpty) {
      try {
        _custom
          ..clear()
          ..addAll(
            (jsonDecode(raw) as List).map(
              (e) => CustomHost.fromJson(Map<String, dynamic>.from(e as Map)),
            ),
          );
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> addCustom(CustomHost h) async {
    // 规范化：去掉协议与末尾斜杠，只存主机名
    var host = h.host.trim();
    host = host.replaceFirst(RegExp(r'^https?://'), '');
    host = host.split('/').first;
    if (host.isEmpty) return;
    if (_custom.any((e) => e.host == host)) return;
    _custom.add(CustomHost(
      host: host,
      label: h.label.trim(),
      note: h.note.trim(),
      at: DateTime.now().millisecondsSinceEpoch,
    ));
    await _persistCustom();
  }

  Future<void> removeCustom(String host) async {
    _custom.removeWhere((e) => e.host == host);
    await _persistCustom();
  }

  Future<void> setSkipStartup(bool v) async {
    skipStartup = v;
    await _prefs?.setBool(_kSkipStartup, v);
    notifyListeners();
  }

  Future<void> _persistCustom() async {
    notifyListeners();
    await _prefs?.setString(
      _kCustom,
      jsonEncode(_custom.map((e) => e.toJson()).toList()),
    );
  }
}
