import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CustomHost {
  final String host;

  final String label;

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

class HostStore extends ChangeNotifier {
  HostStore._();
  static final HostStore instance = HostStore._();

  static const _kCustom = 'customHosts';
  static const _kSkipStartup = 'skipStartup';

  SharedPreferences? _prefs;

  final List<CustomHost> _custom = [];

  bool skipStartup = false;

  List<CustomHost> get customHosts => List.unmodifiable(_custom);

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
