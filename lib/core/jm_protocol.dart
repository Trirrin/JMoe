import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'app_state.dart';
import 'package:pointycastle/export.dart';
import 'l10n.dart';

class JmProtocol {
  static const String tokenKey = '185Hcomic3PAPP7R';
  static const String altTokenKey = '18comicAPPContent';
  static const String hostConfigKey = 'diosfjckwpqpdfjkvnqQjsik';
  static const String version = '2.1.12';

  static const String primaryHostConfigUrl =
      'https://rup4a04-c02.tos-cn-hongkong.bytepluses.com/newsvr-2025.txt';
  static const String backupHostConfigUrl =
      'https://rup4a04-c01.tos-ap-southeast-1.bytepluses.com/newsvr-2025.txt';

  static const List<List<String>> builtinHosts = [
    ['www.cdnbtd.cc', '线路1'],
    ['www.cdnutc.cc', '线路2'],
    ['www.cdngwc.net', '线路3'],
    ['www.cdngwc.club', '线路4'],
    ['www.cdnutc.me', '线路5'],
  ];

  static const String fallbackImgHost = 'https://cdn-msp.jmapiproxy3.cc';

  static String md5Hex(String input) => md5.convert(utf8.encode(input)).toString();

  static String localizeHostLabel(String label, String uiLang) {
    if (uiLang.startsWith('en')) {
      final m = RegExp(r'(\d+)').firstMatch(label);
      return m != null ? 'Line ${m.group(1)}' : label;
    }
    if (uiLang.contains('Hant')) return label;
    const map = {
      '線路': '线路', '線': '线', '路': '路', '臺': '台', '灣': '湾',
      '專': '专', '業': '业', '標': '标', '籤': '签',
    };
    var out = label;
    map.forEach((k, v) => out = out.replaceAll(k, v));
    return out;
  }

  static Uint8List? aesEcbDecryptBase64(String b64, String key) {
    try {
      final keyBytes = utf8.encode(key);
      final data = base64.decode(b64);
      final cipher = ECBBlockCipher(AESEngine())
        ..init(false, KeyParameter(Uint8List.fromList(keyBytes)));
      final out = Uint8List(data.length);
      for (var offset = 0; offset < data.length; offset += 16) {
        cipher.processBlock(data, offset, out, offset);
      }
      if (out.isEmpty) return out;
      final pad = out.last;
      if (pad >= 1 && pad <= 16 && pad <= out.length) {
        return Uint8List.sublistView(out, 0, out.length - pad);
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? decodeHostConfig(String raw) {
    final text = raw.replaceAll('\uFEFF', '').trim();
    final key = md5Hex(hostConfigKey);
    final decoded = aesEcbDecryptBase64(text, key);
    if (decoded == null) return null;
    try {
      return jsonDecode(utf8.decode(decoded)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> decodeResponse(
    dynamic body,
    int timestamp,
    String path,
  ) {
    if (body is String) {
      if (body.trim().isEmpty) {
        return {'code': 200, 'data': null};
      }
      try {
        body = jsonDecode(body);
      } catch (_) {
        return {'code': -1, 'data': null, 'errorMsg': body};
      }
    }
    if (body is! Map) {
      print('[JMOE] ' 'decodeResponse: body not map');
      return {'code': -1, 'data': null, 'errorMsg': L.t('responseFormatError')};
    }
    final map = Map<String, dynamic>.from(body);
    final data = map['data'];
    if (data is List || data is Map) {
      return map;
    }
    if (data is String && data.isNotEmpty) {
      final keys = <String>[
        md5Hex('$timestamp$altTokenKey'),
        md5Hex('$timestamp$tokenKey'),
        md5Hex(altTokenKey),
        md5Hex(tokenKey),
      ];
      for (final key in keys) {
        final plain = aesEcbDecryptBase64(data, key);
        if (plain == null || plain.isEmpty) continue;
        try {
          map['data'] = jsonDecode(utf8.decode(plain));
          return map;
        } catch (_) {
          continue;
        }
      }
      try {
        map['data'] = jsonDecode(data);
      } catch (_) {
        print('[JMOE] decrypt failed, ts=$timestamp');
        map['data'] = null;
      }
    }
    return map;
  }
}

class JmApi {
  JmApi._();

  static final JmApi instance = JmApi._();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 20),
      followRedirects: true,
      validateStatus: (s) => s != null && s < 500,
      headers: {
        'User-Agent': 'okhttp/4.12.0',
        'Accept-Encoding': 'gzip',
      },
    ),
  );

  String? _baseUrl;
  List<List<String>> hosts = List<List<String>>.from(JmProtocol.builtinHosts);
  String lang = 'TW';
  String? jwtToken;
  String? cookieValue;

  String get baseUrl => _baseUrl ?? 'https://${hosts.first[0]}/';
  String get host => hostLabel(baseUrl);

  static String hostLabel(String url) {
    try {
      final u = Uri.parse(url);
      return u.host;
    } catch (_) {
      return url;
    }
  }

  Future<void> loadHostList() async {
    for (final url in [
      JmProtocol.primaryHostConfigUrl,
      JmProtocol.backupHostConfigUrl,
    ]) {
      try {
        final res = await _dio.get<String>(
          url,
          options: Options(responseType: ResponseType.plain),
        );
        final text = res.data;
        if (text == null || text.isEmpty) continue;
        final cfg = JmProtocol.decodeHostConfig(text);
        if (cfg == null) continue;
        final server = cfg['Server'];
        final labels = cfg['jm3_Server'];
        if (server is List && server.isNotEmpty) {
          final list = <List<String>>[];
          for (final s in server) {
            final name = s.toString();
            var label = name;
            if (labels is List) {
              for (final l in labels) {
                if (l is List && l.length >= 2 && l[0].toString() == name) {
                  label = l[1].toString();
                  break;
                }
              }
            }
            list.add([name, label]);
          }
          if (list.isNotEmpty) hosts = list;
          return;
        }
      } catch (_) {
        continue;
      }
    }
  }

  Future<int?> measure(String hostName,
      {Duration timeout = const Duration(seconds: 6)}) async {
    final sw = Stopwatch()..start();
    try {
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final res = await _dio
          .get<dynamic>(
            'https://$hostName/setting',
            queryParameters: {'lang': lang, 'app_img_shunt': '1'},
            options: Options(
              headers: _headers(ts),
              responseType: ResponseType.json,
              receiveTimeout: timeout,
              connectTimeout: timeout,
            ),
          )
          .timeout(timeout);
      if (res.statusCode != null && res.statusCode! < 500) {
        return sw.elapsedMilliseconds;
      }
    } catch (_) {}
    return null;
  }

  Future<void> switchHostQuiet(String hostName) async {
    _baseUrl = 'https://$hostName/';
  }

  Future<void> bootstrap() async {
    for (final url in [
      JmProtocol.primaryHostConfigUrl,
      JmProtocol.backupHostConfigUrl,
    ]) {
      try {
        final res = await _dio.get<String>(
          url,
          options: Options(responseType: ResponseType.plain),
        );
        final text = res.data;
        if (text == null || text.isEmpty) continue;
        final cfg = JmProtocol.decodeHostConfig(text);
        if (cfg == null) continue;
        final server = cfg['Server'];
        final labels = cfg['jm3_Server'];
        if (server is List && server.isNotEmpty) {
          final list = <List<String>>[];
          for (final s in server) {
            final name = s.toString();
            var label = name;
            if (labels is List) {
              for (final l in labels) {
                if (l is List && l.length >= 2 && l[0].toString() == name) {
                  label = l[1].toString();
                  break;
                }
              }
            }
            list.add([name, label]);
          }
          if (list.isNotEmpty) hosts = list;
          break;
        }
      } catch (_) {
        continue;
      }
    }

    final best = await pickFastestHost();
    _baseUrl = 'https://${best ?? hosts.first[0]}/';
    print('[JMOE] bootstrap picked host=${_baseUrl ?? ''}');
  }

  Future<String?> pickFastestHost({
    Duration timeout = const Duration(seconds: 6),
    String? preferred,
  }) async {
    if (hosts.isEmpty) return null;
    final results = <String, int>{};

    Future<void> probe(String hostName) async {
      final sw = Stopwatch()..start();
      try {
        final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final res = await _dio
            .get<dynamic>(
              'https://$hostName/setting',
              queryParameters: {'lang': lang, 'app_img_shunt': '1'},
              options: Options(
                headers: _headers(ts),
                responseType: ResponseType.json,
                receiveTimeout: timeout,
                connectTimeout: timeout,
              ),
            )
            .timeout(timeout);
        if (res.statusCode != null && res.statusCode! < 500) {
          results[hostName] = sw.elapsedMilliseconds;
        }
      } catch (_) {}
    }

    await Future.wait(hosts.map((h) => probe(h[0]))).timeout(
      timeout + const Duration(seconds: 2),
      onTimeout: () => const [],
    );

    if (results.isEmpty) return null;
    final sorted = results.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    if (preferred != null && results.containsKey(preferred)) {
      final bestMs = sorted.first.value;
      if (results[preferred]! - bestMs < 200) return preferred;
    }
    return sorted.first.key;
  }

  Future<bool> switchHost(String hostName) async {
    final candidate = 'https://$hostName/';
    final ok = await ping(candidate);
    if (ok) _baseUrl = candidate;
    return ok;
  }

  Future<bool> ping(String url) async {
    try {
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final res = await _dio.get<dynamic>(
        '${url}setting',
        queryParameters: {'lang': lang, 't': ts},
        options: Options(
          headers: _headers(ts),
          responseType: ResponseType.json,
        ),
      );
      final map = JmProtocol.decodeResponse(res.data, ts, 'setting');
      return map['code'] == 200;
    } catch (_) {
      return false;
    }
  }

  Map<String, dynamic> _headers(int ts) {
    final h = <String, dynamic>{
      'Tokenparam': '$ts,${JmProtocol.version}',
      'Token': JmProtocol.md5Hex('$ts${JmProtocol.tokenKey}'),
    };
    if (jwtToken != null && jwtToken!.isNotEmpty) {
      h['Authorization'] = 'Bearer $jwtToken';
    }
    if (cookieValue != null && cookieValue!.isNotEmpty) {
      h['Cookie'] = 'AVS=$cookieValue';
    }
    return h;
  }

  int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Future<Map<String, dynamic>?> getOnHost(
    String host,
    String path, [
    Map<String, dynamic>? params,
  ]) async {
    if (AppState.instance.offlineMode) return null;
    final ts = _now();
    final merged = <String, dynamic>{...?params};
    merged.putIfAbsent('lang', () => lang);
    final clean = <String, dynamic>{};
    merged.forEach((k, v) {
      if (v == null) return;
      if (v is String && v.isEmpty) return;
      clean[k] = v;
    });
    try {
      final res = await _dio.get<dynamic>(
        'https://$host/$path',
        queryParameters: clean,
        options: Options(
          headers: _headers(ts),
          responseType: ResponseType.json,
          receiveTimeout: const Duration(seconds: 15),
          connectTimeout: const Duration(seconds: 10),
        ),
      );
      if (res.statusCode != null && res.statusCode! >= 500) {
        print('[JMOE] $host/$path -> HTTP ${res.statusCode}');
        return null;
      }
      final map = JmProtocol.decodeResponse(res.data, ts, path);
      if (map['code'] == 200) return map;
      return null;
    } catch (e) {
      print('[JMOE] $host/$path EXC: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> getWithHostRotation(
    String path, [
    Map<String, dynamic>? params,
  ]) async {
    final current = Uri.tryParse(baseUrl)?.host;
    for (final h in hosts) {
      if (h.isEmpty || h[0] == current) continue;
      final r = await getOnHost(h[0], path, params);
      if (r != null) {
        print('[JMOE] $path recovered on ${h[0]}');
        return r;
      }
    }
    return null;
  }

  Future<Map<String, dynamic>> get(
    String path, [
    Map<String, dynamic>? params,
  ]) async {
    if (AppState.instance.offlineMode) {
      return {'code': -1, 'errorMsg': 'offline'};
    }
    final merged = <String, dynamic>{...?params};
    merged.putIfAbsent('lang', () => lang);
    final clean = <String, dynamic>{};
    merged.forEach((k, v) {
      if (v == null) return;
      if (v is String && v.isEmpty) return;
      clean[k] = v;
    });

    Object? lastError;
    for (var attempt = 0; attempt < 4; attempt++) {
      final ts = _now();
      try {
        final res = await _dio.get<dynamic>(
          '$baseUrl$path',
          queryParameters: clean,
          options: Options(
            headers: _headers(ts),
            responseType: ResponseType.json,
          ),
        );
        final map = JmProtocol.decodeResponse(res.data, ts, path);
        final code = map['code'];
        print('[JMOE] GET $path -> code=$code');
        if (code == 200) return map;
        if (attempt < 3) {
          await Future<void>.delayed(
            Duration(milliseconds: 300 * (1 << attempt)),
          );
          await _rotateHost();
          continue;
        }
        return map;
      } catch (e) {
        print('[JMOE] GET $path EXC: $e');
        lastError = e;
        if (attempt < 3) {
          await Future<void>.delayed(
            Duration(milliseconds: 300 * (1 << attempt)),
          );
          await _rotateHost();
        }
      }
    }
    return {
      'code': -1,
      'data': null,
      'errorMsg': lastError?.toString() ?? L.t('networkError'),
    };
  }

  Future<Map<String, dynamic>> postForm(
    String path, [
    Map<String, dynamic>? params,
  ]) async {
    if (AppState.instance.offlineMode) {
      return {'code': -1, 'errorMsg': 'offline'};
    }
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      final ts = _now();
      try {
        final body = <String, String>{};
        (params ?? {}).forEach((k, v) {
          if (v == null) return;
          body[k] = v.toString();
        });
        final res = await _dio.post<dynamic>(
          '$baseUrl$path',
          data: body,
          options: Options(
            headers: {
              ..._headers(ts),
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            responseType: ResponseType.json,
            contentType: Headers.formUrlEncodedContentType,
          ),
        );
        final map = JmProtocol.decodeResponse(res.data, ts, path);
        final code = map['code'];
        if (code == 200 || res.statusCode == 400 || res.statusCode == 401) {
          return map;
        }
        if (attempt < 3) {
          await Future<void>.delayed(
            Duration(milliseconds: 300 * (1 << attempt)),
          );
          await _rotateHost();
          continue;
        }
        return map;
      } catch (e) {
        lastError = e;
        if (attempt < 3) {
          await Future<void>.delayed(
            Duration(milliseconds: 300 * (1 << attempt)),
          );
          await _rotateHost();
        }
      }
    }
    return {
      'code': -1,
      'errorMsg': '$lastError',
    };
  }

  Future<Map<String, dynamic>> post(
    String path, [
    Map<String, dynamic>? params,
  ]) async {
    if (AppState.instance.offlineMode) {
      return {'code': -1, 'errorMsg': 'offline'};
    }
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      final ts = _now();
      try {
        final form = FormData();
        (params ?? {}).forEach((k, v) {
          if (v == null) return;
          form.fields.add(MapEntry(k, v.toString()));
        });
        final res = await _dio.post<dynamic>(
          '$baseUrl$path',
          data: form,
          options: Options(
            headers: _headers(ts),
            responseType: ResponseType.json,
          ),
        );
        final map = JmProtocol.decodeResponse(res.data, ts, path);
        final code = map['code'];
        if (code == 200 || res.statusCode == 400 || res.statusCode == 401) {
          return map;
        }
        if (attempt < 3) {
          await Future<void>.delayed(
            Duration(milliseconds: 300 * (1 << attempt)),
          );
          await _rotateHost();
          continue;
        }
        return map;
      } catch (e) {
        lastError = e;
        if (attempt < 3) {
          await Future<void>.delayed(
            Duration(milliseconds: 300 * (1 << attempt)),
          );
          await _rotateHost();
        }
      }
    }
    return {
      'code': -1,
      'data': null,
      'errorMsg': lastError?.toString() ?? L.t('networkError'),
    };
  }

  Future<void> _rotateHost() async {
    if (hosts.isEmpty) return;
    final current = Uri.tryParse(baseUrl)?.host;
    for (final h in hosts) {
      if (h.isEmpty || h[0] == current) continue;
      _baseUrl = 'https://${h[0]}/';
      return;
    }
  }

  Future<Uint8List?> fetchBytes(String url, {String? referer}) async {
    if (AppState.instance.offlineMode) return null;
    try {
      final res = await _dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'User-Agent': 'okhttp/4.12.0',
            'Referer': ?referer,
          },
        ),
      );
      final data = res.data;
      if (data == null) return null;
      return Uint8List.fromList(data);
    } catch (e) {
      print('[JMOE] fetchBytes EXC url=$url err=$e');
      return null;
    }
  }

  Dio get raw => _dio;
}
