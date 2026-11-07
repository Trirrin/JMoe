import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:pointycastle/export.dart';
import 'l10n.dart';


/// JMComic3 客户端协议实现。
///
/// 逆向自 `www.jmcomico3.cn` 分发的 2.1.12 客户端（Capacitor + React 包）：
///  * 请求头 `Tokenparam: <unix秒>,<版本>`、`Token: md5(<unix秒> + "185Hcomic3PAPP7R")`
///  * 响应 `data` 字段为 AES/ECB/PKCS7 密文（base64），
///    密钥 = md5(时间戳 + "185Hcomic3PAPP7R") 或 md5("18comicAPPContent")
///    广告接口用 md5("ad_content_all")
///  * 线路表来自 `newsvr-2025.txt`（AES-ECB，密钥 md5("diosfjckwpqpdfjkvnqQjsik")）
class JmProtocol {
  static const String tokenKey = '185Hcomic3PAPP7R';
  static const String altTokenKey = '18comicAPPContent';
  static const String hostConfigKey = 'diosfjckwpqpdfjkvnqQjsik';
  static const String version = '2.1.12';

  static const String primaryHostConfigUrl =
      'https://rup4a04-c02.tos-cn-hongkong.bytepluses.com/newsvr-2025.txt';
  static const String backupHostConfigUrl =
      'https://rup4a04-c01.tos-ap-southeast-1.bytepluses.com/newsvr-2025.txt';

  /// 内置兜底线路，所有网络线路都失败时使用。
  static const List<List<String>> builtinHosts = [
    ['www.cdnbtd.cc', '线路1'],
    ['www.cdnutc.cc', '线路2'],
    ['www.cdngwc.net', '线路3'],
    ['www.cdngwc.club', '线路4'],
    ['www.cdnutc.me', '线路5'],
  ];

  static const String fallbackImgHost = 'https://cdn-msp.jmapiproxy3.cc';

  static String md5Hex(String input) => md5.convert(utf8.encode(input)).toString();

  /// 服务端线路名是繁体（「線路1」），按界面语言做字形转换。
  /// 简体模式下转为「线路1」，英文模式保留数字。
  static String localizeHostLabel(String label, String uiLang) {
    if (uiLang.startsWith('en')) {
      // 提取数字，输出 Line N
      final m = RegExp(r'(\d+)').firstMatch(label);
      return m != null ? 'Line ${m.group(1)}' : label;
    }
    if (uiLang.contains('Hant')) return label;
    // 简体：常用繁体字映射
    const map = {
      '線路': '线路', '線': '线', '路': '路', '臺': '台', '灣': '湾',
      '專': '专', '業': '业', '標': '标', '籤': '签',
    };
    var out = label;
    map.forEach((k, v) => out = out.replaceAll(k, v));
    return out;
  }

  /// AES/ECB/PKCS7 解密（base64 输入）。
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
      // PKCS7 去填充
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

  /// 解密线路配置文本（`newsvr-2025.txt` 的内容）。
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

  /// 解析响应体：`{"code":200,"data":"<base64 密文>"}` -> 明文 JSON。
  static Map<String, dynamic> decodeResponse(
    dynamic body,
    int timestamp,
    String path,
  ) {
    if (body is String) {
      try {
        body = jsonDecode(body);
      } catch (_) {
        return {'code': -1, 'data': null, 'errorMsg': body};
      }
    }
    if (body is! Map) {
      print('[JMOE] ' + 'decodeResponse: body not map');
      return {'code': -1, 'data': null, 'errorMsg': L.t('responseFormatError')};
    }
    final map = Map<String, dynamic>.from(body);
    final data = map['data'];
    // 部分接口（如 hot_tags）直接返回明文数组/对象，无需解密
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
      // 兜底：有些接口返回的是未加密的 JSON 字符串
      try {
        map['data'] = jsonDecode(data);
      } catch (_) {
        print('[JMOE] decrypt failed, ts=' + timestamp.toString());
        map['data'] = null;
      }
    }
    return map;
  }
}

/// 线路切换 / 重试 / 解密 的 HTTP 客户端。
class JmApi {
  JmApi._();

  static final JmApi instance = JmApi._();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      // promote/setting 等接口响应体较大（可达数 MB），需要足够时间
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

  /// 只拉取线路表（不测速），供启动页展示。
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

  /// 测量单条线路延迟（毫秒）；失败返回 null。
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

  /// 静默切换线路（不额外验证，启动页已测速）。
  Future<void> switchHostQuiet(String hostName) async {
    _baseUrl = 'https://$hostName/';
  }

  /// 拉取线路配置并**并发测速择优**，返回最终选中的线路。
  ///
  /// 策略：
  ///   1. 取线路表（远程配置 → 内置兜底）
  ///   2. 对所有线路并发 ping（限时），取最快可用者
  ///   3. 全失败时退回上一次可用线路或首选线路
  Future<void> bootstrap() async {
    // 1) 线路表
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

    // 2) 并发测速择优
    final best = await pickFastestHost();
    _baseUrl = 'https://${best ?? hosts.first[0]}/';
    print('[JMOE] bootstrap picked host=' + (_baseUrl ?? ''));
  }

  /// 并发 ping 所有线路，返回延迟最低的 hostName（失败返回 null）。
  ///
  /// [timeout] 为整体预算；[preferred] 为上次成功的线路（同延迟时优先）。
  Future<String?> pickFastestHost({
    Duration timeout = const Duration(seconds: 6),
    String? preferred,
  }) async {
    if (hosts.isEmpty) return null;
    final results = <String, int>{}; // host -> ms

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
        // 只要有响应（即使 code 异常）也说明线路连通
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
    // 上次可用线路若延迟接近最优（差值 <200ms），优先沿用，避免每次启动抖动
    if (preferred != null && results.containsKey(preferred)) {
      final bestMs = sorted.first.value;
      if (results[preferred]! - bestMs < 200) return preferred;
    }
    return sorted.first.key;
  }

  /// 手动切换线路，返回是否可用。
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

  /// GET 请求（自动解密）。失败时按线路表轮换重试一次。
  Future<Map<String, dynamic>> get(
    String path, [
    Map<String, dynamic>? params,
  ]) async {
    final merged = <String, dynamic>{...?params};
    merged.putIfAbsent('lang', () => lang);
    final clean = <String, dynamic>{};
    merged.forEach((k, v) {
      if (v == null) return;
      if (v is String && v.isEmpty) return;
      clean[k] = v;
    });

    Object? lastError;
    // 网络不佳时重试 4 次（指数退避 300/600/1200ms），
    // 仍失败则停止，由 UI 提供「点击重试」，避免无休止转圈。
    for (var attempt = 0; attempt < 4; attempt++) {
      final ts = _now();
      try {
        final res = await _dio.get<dynamic>(
          '${baseUrl}$path',
          queryParameters: clean,
          options: Options(
            headers: _headers(ts),
            responseType: ResponseType.json,
          ),
        );
        final map = JmProtocol.decodeResponse(res.data, ts, path);
        final code = map['code'];
        print('[JMOE] ' + 'GET ' + path + ' -> code=' + code.toString());
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
        print('[JMOE] ' + 'GET ' + path + ' EXC: ' + e.toString());
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

  /// POST（multipart/form-data），与官方客户端一致。
  Future<Map<String, dynamic>> post(
    String path, [
    Map<String, dynamic>? params,
  ]) async {
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
          '${baseUrl}$path',
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

  /// 原始字节（图片、下载用）。
  Future<Uint8List?> fetchBytes(String url, {String? referer}) async {
    try {
      final res = await _dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'User-Agent': 'okhttp/4.12.0',
            if (referer != null) 'Referer': referer,
          },
        ),
      );
      final data = res.data;
      if (data == null) return null;
      return Uint8List.fromList(data);
    } catch (_) {
      return null;
    }
  }

  Dio get raw => _dio;
}
