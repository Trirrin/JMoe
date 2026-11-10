import 'dart:async';

import 'package:dio/dio.dart';
import '../core/app_log.dart';
import '../core/app_state.dart';
import '../core/jm_protocol.dart';
import '../core/models.dart';

class JmService {
  JmService._();
  static final JmService instance = JmService._();

  JmApi get _api => JmApi.instance;

  String? imgHost = JmProtocol.fallbackImgHost;
  String? logoUrl;
  Map<String, dynamic>? settings;

  Future<Map<String, dynamic>?> loadSettings({String imgShunt = '1'}) async {
    final r = await _api.get('setting', {'app_img_shunt': imgShunt});
    if (r['code'] == 200 && r['data'] is Map) {
      final data = Map<String, dynamic>.from(r['data'] as Map);
      settings = data;
      final host = data['img_host'];
      if (host is String && host.isNotEmpty) imgHost = host;
      final logo = data['logo_path'];
      if (logo is String && logo.isNotEmpty) logoUrl = logo;
      return data;
    }
    return settings;
  }

  String? coverUrl(Comic c) {
    final host = imgHost ?? JmProtocol.fallbackImgHost;
    final raw = c.image;
    if (raw != null && raw.isNotEmpty) {
      if (raw.startsWith('http')) {
        if (c.source != 'jm') return raw;
        final path = _pathOf(raw);
        if (path.isEmpty) return raw;
        return '$host$path';
      }
      return '$host${raw.startsWith('/') ? '' : '/'}$raw';
    }
    if (c.source == 'jm' && c.id.isNotEmpty) {
      final v = c.updateAt ?? 0;
      return '$host/media/albums/${c.id}_3x4.jpg?v=$v';
    }
    return null;
  }

  static String _pathOf(String url) {
    try {
      final u = Uri.parse(url);
      final q = u.hasQuery ? '?${u.query}' : '';
      return '${u.path}$q';
    } catch (_) {
      return '';
    }
  }

  Future<int?> measureImgHost(
    String host, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final sw = Stopwatch()..start();
    try {
      final url = '$host/media/logo/logo.png';
      final res = await Dio().get<dynamic>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: timeout,
          connectTimeout: timeout,
          validateStatus: (c) => c != null && c < 500,
          followRedirects: true,
          headers: {'User-Agent': 'okhttp/4.12.0'},
        ),
      );
      if (res.statusCode != null && res.statusCode! < 400) {
        return sw.elapsedMilliseconds;
      }
    } catch (_) {}
    return null;
  }

  void setImgHost(String host) {
    if (host.isEmpty) return;
    imgHost = host;
  }

  List<String> get imgHostCandidates {
    final primary = imgHost ?? JmProtocol.fallbackImgHost;
    const mirrors = [
      'https://cdn-msp.jmapiproxy3.cc',
      'https://cdn-msp.jmapiproxy1.cc',
      'https://cdn-msp.jmdanjonproxy.vip',
      'https://cdn-msp2.jmapiproxy2.cc',
    ];
    return {primary, ...mirrors}.toList();
  }

  List<String> imageUrlCandidates(String url) {
    final path = _pathOf(url);
    if (path.isEmpty) return const [];
    return [
      for (final h in imgHostCandidates)
        if (!url.startsWith(h)) '$h$path',
    ];
  }

  Future<List<PromoteSection>> fetchPromote() async {
    final r = await _api.get('promote');
    final data = r['data'];
    final out = <PromoteSection>[];
    if (data is List) {
      for (final s in data) {
        if (s is Map) {
          out.add(PromoteSection.fromJm(Map<String, dynamic>.from(s)));
        }
      }
    }
    return out;
  }

  Future<List<Comic>> fetchLatest({int page = 1}) async {
    final r = await _api.get('latest', {'page': page});
    return _comicList(r['data']);
  }

  Future<List<Comic>> fetchRandomRecommend() async {
    final r = await _api.get('random_recommend');
    return _comicList(r['data']);
  }

  Future<List<String>> fetchHotTags() async {
    final r = await _api.get('hot_tags');
    final data = r['data'];
    if (data is List) return data.map((e) => e.toString()).toList();
    return const [];
  }

  Future<(List<Comic>, int)> fetchPromoteList(String id, int page) async {
    final r = await _api.get('promote_list', {'id': id, 'page': page});
    final data = r['data'];
    if (data is Map) {
      final total = int.tryParse('${data['total'] ?? 0}') ?? 0;
      return (_comicList(data['list']), total);
    }
    return (const <Comic>[], 0);
  }

  Future<(List<Comic>, int)> fetchSerialization({
    String type = 'all',
    int? date,
    int page = 1,
  }) async {
    final r = await _api.get('serialization', {
      'type': type,
      'date': ?date,
      'page': page,
    });
    final data = r['data'];
    if (data is Map && data['list'] is List) {
      final total = int.tryParse('${data['total'] ?? 0}') ?? 0;
      return (_comicList(data['list']), total);
    }
    return (const <Comic>[], 0);
  }

  Future<List<CategoryGroup>> fetchCategories() async {
    final r = await _api.get('categories');
    final data = r['data'];
    final out = <CategoryGroup>[];
    if (data is Map && data['categories'] is List) {
      for (final c in data['categories'] as List) {
        if (c is Map) {
          out.add(CategoryGroup.fromJm(Map<String, dynamic>.from(c)));
        }
      }
    }
    return out;
  }

  Future<(List<Comic>, int)> fetchCategoryFilter({
    required String slug,
    String order = 'mr',
    int page = 1,
    String? sub,
  }) async {
    final r = await _api.get('categories/filter', {
      'page': page,
      'o': order,
      'c': slug,
      if (sub != null && sub.isNotEmpty) 'sub': sub,
    });
    final data = r['data'];
    if (data is Map) {
      final total = int.tryParse('${data['total'] ?? 0}') ?? 0;
      return (_comicList(data['content']), total);
    }
    return (const <Comic>[], 0);
  }

  Future<(List<Comic>, int)> search(
    String query, {
    int page = 1,
    String order = '',
    String searchType = 'site',
    String? year,
    String? month,
  }) async {
    final r = await _api.get('search', {
      'search_query': query,
      'page': page,
      'o': order,
      'search_type': searchType,
      if (year != null && year.isNotEmpty) 'y': year,
      if (month != null && month.isNotEmpty) 'm': month,
    });
    final data = r['data'];
    if (data is Map) {
      final total = int.tryParse('${data['total'] ?? 0}') ?? 0;
      return (_comicList(data['content'] ?? data['list']), total);
    }
    return (const <Comic>[], 0);
  }

  Future<AlbumDetail?> fetchAlbum(String id) async {
    final r = await _api.get('album', {'id': id});
    if (r['code'] == 200 && r['data'] is Map) {
      return AlbumDetail.fromJm(Map<String, dynamic>.from(r['data'] as Map));
    }
    return null;
  }

  Future<List<Chapter>> fetchChapters(String id) async {
    final r = await _api.get('chapter', {'id': id});
    final data = r['data'];
    final out = <Chapter>[];
    if (data is Map && data['series'] is List) {
      for (final s in data['series'] as List) {
        if (s is Map) out.add(Chapter.fromJm(Map<String, dynamic>.from(s)));
      }
    } else if (data is List) {
      for (final s in data) {
        if (s is Map) out.add(Chapter.fromJm(Map<String, dynamic>.from(s)));
      }
    }
    return out;
  }

  Future<ReadChapter?> fetchRead(String chapterId, {String? express}) async {
    final r = await _api.get('comic_read', {
      'id': chapterId,
      if (express != null && express.isNotEmpty) 'express': express,
    });
    if (r['code'] == 200 && r['data'] is Map) {
      return ReadChapter.fromJm(Map<String, dynamic>.from(r['data'] as Map));
    }
    return null;
  }

  Future<Map<String, dynamic>?> fetchDownload(String id) async {
    final r = await _api.get('album_download_2/$id');
    if (r['data'] is Map) return Map<String, dynamic>.from(r['data'] as Map);
    return null;
  }

  Future<Map<String, dynamic>> login(String username, String password) async {
    final r = await _api.post('login', {
      'username': username,
      'password': password,
    });
    return r;
  }

  Future<Map<String, dynamic>> register({
    required String username,
    required String password,
    required String passwordConfirm,
    required String email,
    String gender = 'm',
  }) async {
    return _api.post('register', {
      'username': username,
      'password': password,
      'password_confirm': passwordConfirm,
      'email': email,
      'gender': gender,
    });
  }

  Future<Map<String, dynamic>> confirmRegister(
    String username,
    String numcode,
  ) async {
    return _api.post('confirm', {'username': username, 'numcode': numcode});
  }

  Future<Map<String, dynamic>> forgotPassword(String email) async {
    return _api.post('forgot', {'email': email});
  }

  Future<Map<String, dynamic>> logout() async => _api.post('logout');

  Future<bool?> verifySession() async {
    if (AppState.instance.offlineMode) return null;
    try {
      final r = await _api.get('member', {});
      final code = r['code'];
      if (code == 200) return true;
      if (code == 401) return false;
      print('[JMOE] verifySession inconclusive: code=$code');
      return null;
    } catch (e) {
      print('[JMOE] verifySession EXC: $e');
      return null;
    }
  }

  bool lastFavoritesOk = false;

  bool lastFavoritesAuthFailed = false;

  Future<(List<Comic>, int)> fetchFavorites({
    int page = 1,
    String folderId = '0',
    String order = 'mr',
  }) async {
    lastFavoritesOk = false;
    lastFavoritesAuthFailed = false;
    print('[JMOE] fetchFavorites page=$page '
        'jwt=${(JmApi.instance.jwtToken ?? '').isEmpty ? "MISSING" : "ok"} '
        'cookie=${(JmApi.instance.cookieValue ?? '').isEmpty ? "none" : "ok"} '
        'loggedIn=${AppState.instance.loggedIn}');
    final r = await _api.get('favorite', {
      'page': page,
      'folder_id': folderId,
      'o': order,
    });
    final code = r['code'];
    if (code != 200) {
      print('[JMOE] fetchFavorites failed: code=$code msg=${r['errorMsg']}');
      unawaited(AppLog.instance.log(
        'FAV',
        'fetchFavorites failed code=$code msg=${r['errorMsg']}',
      ));
      lastFavoritesOk = false;
      lastFavoritesAuthFailed = code == 401;
      return (const <Comic>[], 0);
    }
    final data = r['data'];
    if (data is Map) {
      final total = int.tryParse('${data['total'] ?? 0}') ?? 0;
      lastFavoritesOk = true;
      return (_comicList(data['list'] ?? data['content']), total);
    }
    print('[JMOE] fetchFavorites bad data: ${data.runtimeType}');
    lastFavoritesOk = false;
    return (const <Comic>[], 0);
  }

  Future<Map<String, dynamic>> toggleFavorite(String aid) async =>
      _api.post('favorite', {'aid': aid});

  Future<({bool ok, String? error})> setFavorite(
    String aid, {
    required bool target,
  }) async {
    try {
      if (!target) {
        final r = await toggleFavorite(aid);
        if (r['code'] != 200) {
          return (ok: false, error: '${r['errorMsg'] ?? 'code=${r['code']}'}');
        }
        final after = await _isFavoriteOnCloud(aid);
        if (after == null || after == false) return (ok: true, error: null);
        return (ok: false, error: 'still favorited');
      }

      final current = await _isFavoriteOnCloud(aid);
      if (current == null) {
        final r = await toggleFavorite(aid);
        if (r['code'] != 200) {
          return (ok: false, error: '${r['errorMsg'] ?? 'code=${r['code']}'}');
        }
        return (ok: true, error: null);
      }
      if (current == target) {
        return (ok: true, error: null);
      }
      final r = await toggleFavorite(aid);
      if (r['code'] != 200) {
        return (ok: false, error: '${r['errorMsg'] ?? 'code=${r['code']}'}');
      }
      final after = await _isFavoriteOnCloud(aid);
      if (after == null) return (ok: true, error: null);
      if (after == target) return (ok: true, error: null);
      return (ok: false, error: 'state mismatch after toggle');
    } catch (e) {
      return (ok: false, error: '$e');
    }
  }

  Future<bool?> _isFavoriteOnCloud(String aid) async {
    final target = aid.trim();
    for (var page = 1; page <= 30; page++) {
      final (list, total) = await fetchFavorites(page: page);
      if (!lastFavoritesOk) return null;
      for (final c in list) {
        if (c.id.trim() == target) return true;
      }
      if (list.isEmpty) return false;
      if (total > 0 && page * list.length >= total) return false;
      if (list.length < 20) return false;
    }
    return false;
  }

  Future<(List<Comic>, int)> fetchHistory({int page = 1}) async {
    final r = await _api.get('watch_list', {'page': page});
    final data = r['data'];
    if (data is Map) {
      final total = int.tryParse('${data['total'] ?? 0}') ?? 0;
      return (_comicList(data['list'] ?? data['content']), total);
    }
    return (const <Comic>[], 0);
  }

  Future<Map<String, dynamic>> pushHistory(String id) async =>
      _api.post('watch_list', {'id': id});

  Future<Map<String, dynamic>> toggleLike(String id) async =>
      _api.postForm('like', {'id': id, 'like_type': 'album'});

  Future<List<WeekCategory>> fetchWeek() async {
    final r = await _api.get('week');
    final data = r['data'];
    final out = <WeekCategory>[];
    if (data is Map && data['categories'] is List) {
      for (final c in data['categories'] as List) {
        if (c is Map) {
          out.add(
            WeekCategory(
              '${c['id']}',
              (c['title'] ?? '').toString(),
              (c['time'] ?? '').toString(),
            ),
          );
        }
      }
    }
    return out;
  }

  Future<(List<Comic>, int)> fetchWeekFilter(
    String id,
    String type,
    int page,
  ) async {
    final r = await _api.get('week/filter', {
      'id': id,
      'type': type,
      'page': page,
    });
    final data = r['data'];
    if (data is Map) {
      final total = int.tryParse('${data['total'] ?? 0}') ?? 0;
      return (_comicList(data['list']), total);
    }
    return (const <Comic>[], 0);
  }

  Future<List<Map<String, dynamic>>> fetchComments({
    required String aid,
    int page = 1,
    String mode = 'manhua',
  }) async {
    final r = await _api.get('forum', {'mode': mode, 'aid': aid, 'page': page});
    final data = r['data'];
    final out = <Map<String, dynamic>>[];
    if (data is Map) {
      final list = data['list'] ?? data['content'] ?? data['comments'];
      if (list is List) {
        for (final c in list) {
          if (c is Map) out.add(Map<String, dynamic>.from(c));
        }
      }
    } else if (data is List) {
      for (final c in data) {
        if (c is Map) out.add(Map<String, dynamic>.from(c));
      }
    }
    return out;
  }

  Future<Map<String, dynamic>> sendComment({
    required String aid,
    required String comment,
    String? commentId,
  }) async {
    return _api.post('comment', {
      'aid': aid,
      'comment': comment,
      'comment_id': ?commentId,
    });
  }

  Future<(List<Map<String, dynamic>>, int)> fetchUserComments({
    required String uid,
    int page = 1,
    String mode = 'all',
  }) async {
    final r = await _api.get('forum', {
      'mode': mode,
      'uid': uid,
      'page': page,
    });
    final data = r['data'];
    final out = <Map<String, dynamic>>[];
    var total = 0;
    if (data is Map) {
      total = int.tryParse('${data['total'] ?? 0}') ?? 0;
      final list = data['list'] ?? data['content'] ?? data['comments'];
      if (list is List) {
        for (final c in list) {
          if (c is Map) out.add(Map<String, dynamic>.from(c));
        }
      }
    } else if (data is List) {
      for (final c in data) {
        if (c is Map) out.add(Map<String, dynamic>.from(c));
      }
      total = out.length;
    }
    return (out, total);
  }

  Future<Map<String, dynamic>> deleteComment(String commentId) async =>
      _api.post('comment_delete', {'comment_id': commentId});

  Future<Map<String, dynamic>> voteComment(String commentId,
          {String? aid}) async =>
      _api.post('comment_vote', {
        'comment_id': commentId,
        'aid': ?aid,
      });

  Future<List<Map<String, dynamic>>> fetchNotifications({
    int page = 1,
    String type = 'all',
  }) async {
    final r = await _api.get('notifications', {'page': page, 'type': type});
    final data = r['data'];
    final out = <Map<String, dynamic>>[];
    if (data is Map) {
      final list = data['list'] ?? data['content'];
      if (list is List) {
        for (final c in list) {
          if (c is Map) out.add(Map<String, dynamic>.from(c));
        }
      }
    } else if (data is List) {
      for (final c in data) {
        if (c is Map) out.add(Map<String, dynamic>.from(c));
      }
    }
    return out;
  }

  Future<int> fetchUnreadCount() async {
    final r = await _api.get('notifications/unreadCount');
    final data = r['data'];
    if (data is Map) {
      final v = data['count'] ?? data['unread'] ?? data['unread_count'];
      return int.tryParse('$v') ?? 0;
    }
    return int.tryParse('$data') ?? 0;
  }

  Future<Map<String, dynamic>> toggleSerialTracking(String id) async =>
      _api.post('album_sertracking', {'id': id});

  Future<Map<String, dynamic>?> fetchCoin() async {
    try {
      final r = await _api.get('coin', {});
      final d = r['data'];
      if (d is Map) {
        final m = Map<String, dynamic>.from(d);
        return {
          'coin': _pickNum(m, ['coin', 'jcoin', 'JCoin', 'money', 'balance']),
          'exp': _pickNum(m, ['exp', 'experience', 'level_exp']),
          'level': _pickNum(m, ['level', 'lv']),
          'levelName': _pickStr(m, ['level_name', 'levelName', 'grade']),
          'vipExpire': _pickStr(m, [
            'vip_expire',
            'vip_end',
            'ad_free_expire',
            'noad_expire',
            'vip_time',
          ]),
          'vip': _pickBool(m, ['vip', 'is_vip', 'ad_free']),
          'raw': m,
        };
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  num? _pickNum(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v == null) continue;
      final n = num.tryParse('$v');
      if (n != null) return n;
    }
    return null;
  }

  String? _pickStr(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v != null && '$v'.trim().isNotEmpty && '$v' != 'null') return '$v';
    }
    return null;
  }

  bool? _pickBool(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v == null) continue;
      if (v is bool) return v;
      final s = '$v';
      if (s == '1' || s.toLowerCase() == 'true') return true;
      if (s == '0' || s.toLowerCase() == 'false') return false;
    }
    return null;
  }

  Future<Map<String, dynamic>?> fetchDaily(String userId) async {
    try {
      final r = await _api.get('daily', {'user_id': userId});
      final d = r['data'];
      if (d is Map) return Map<String, dynamic>.from(d);
    } catch (_) {}
    return null;
  }

  static DailyStatus parseDaily(Map<String, dynamic>? d) {
    if (d == null) return const DailyStatus();
    final now = DateTime.now();
    final todayStr = now.day.toString().padLeft(2, '0');

    final rec = d['record'];
    final days = <DailyDay>[];
    if (rec is List) {
      for (final r in rec) {
        if (r is List) {
          for (final item in r) {
            if (item is Map) {
              days.add(
                DailyDay(
                  date: '${item['date'] ?? ''}',
                  signed: item['signed'] == true,
                  bonus: item['bonus'] == true,
                ),
              );
            }
          }
        } else if (r is Map) {
          days.add(
            DailyDay(
              date: '${r['date'] ?? ''}',
              signed: r['signed'] == true,
              bonus: r['bonus'] == true,
            ),
          );
        }
      }
    }
    days.sort((a, b) => a.date.compareTo(b.date));

    final todaySigned = days.any((e) => e.date == todayStr && e.signed);
    final signedCount = days.where((e) => e.signed).length;
    var streak = 0;
    for (var i = days.length - 1; i >= 0; i--) {
      final e = days[i];
      if (e.signed) {
        streak++;
      } else if (e.date != todayStr) {
        break;
      }
    }

    return DailyStatus(
      valid: true,
      todaySigned: todaySigned,
      signedCount: signedCount,
      streakDays: streak,
      progress: '${d['currentProgress'] ?? ''}',
      days: days,
    );
  }

  Future<bool> dailyCheck({
    required String userId,
    required String dailyId,
  }) async {
    try {
      final r = await _api.post('daily_chk', {
        'user_id': userId,
        'daily_id': dailyId,
      });
      return r['code'] == 200;
    } catch (_) {
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> fetchPlans() async {
    try {
      final r = await _api.get('payment', {});
      final d = r['data'];
      if (d is Map && d['plans'] is List) {
        return (d['plans'] as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    } catch (_) {}
    return const [];
  }

  Future<Map<String, dynamic>?> fetchProfile(String uid) async {
    try {
      final r = await _api.get('useredit/$uid', {});
      final d = r['data'];
      if (d is Map) return Map<String, dynamic>.from(d);
    } catch (_) {}
    return null;
  }

  Future<({bool ok, String? message})> saveProfile(
    String uid,
    Map<String, dynamic> fields, {
    String? newPassword,
    String? newPasswordConfirm,
  }) async {
    const allowed = {
      'nickName',
      'firstName',
      'lastName',
      'gender',
      'birthday',
      'website',
      'city',
      'country',
      'occupation',
      'company',
      'school',
      'aboutMe',
      'birthPlace',
      'sexuality',
      'relations',
    };

    final payload = <String, dynamic>{'uid': uid};
    fields.forEach((k, v) {
      if (!allowed.contains(k)) return;
      final sv = '$v'.trim();
      if (k == 'birthday') {
        if (sv.isEmpty || sv.startsWith('0000')) return;
      }
      if (sv.isEmpty) return;
      payload[k] = sv;
    });

    if (newPassword != null && newPassword.isNotEmpty) {
      payload['password'] = newPassword;
      payload['password_confirm'] = newPasswordConfirm ?? newPassword;
    }

    try {
      final r = await _api.post('useredit/$uid', payload);
      final code = r['code'];
      final msg = r['errorMsg'] ?? r['msg'];
      final msgStr = (msg == null || '$msg'.isEmpty) ? null : '$msg';

      final failed = msgStr != null &&
          (msgStr.contains('failed') ||
              msgStr.contains('無效') ||
              msgStr.contains('invalid') ||
              msgStr.contains('錯誤'));
      final ok = (code == 200 || code == '200') && !failed;

      return (ok: ok, message: msgStr);
    } catch (e) {
      return (ok: false, message: '$e');
    }
  }

  Future<List<Map<String, dynamic>>> fetchNovels({
    String order = 'mr',
    String type = 'all',
    int page = 1,
  }) async {
    final r = await _api.get('novels', {'o': order, 't': type, 'page': page});
    final data = r['data'];
    if (data is Map && data['list'] is List) {
      return (data['list'] as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return const [];
  }

  Future<Map<String, dynamic>?> fetchNovelDetail(String nid) async {
    final r = await _api.get('novel', {'nid': nid});
    if (r['data'] is Map) return Map<String, dynamic>.from(r['data'] as Map);
    return null;
  }

  Future<List<Map<String, dynamic>>> fetchNovelChapters({
    required String ncid,
    String lang = 'TW',
  }) async {
    final params = {'ncid': ncid, 'lang': lang};
    var r = await _api.get('novelchapters', params);
    var data = r['data'];
    if (data is! Map || (data['list'] == null && data['content'] == null)) {
      final alt = await _api.getWithHostRotation('novelchapters', params);
      if (alt != null && alt['data'] is Map) data = alt['data'];
    }
    final out = <Map<String, dynamic>>[];
    if (data is Map) {
      final list = data['list'] ?? data['content'] ?? data['chapters'];
      if (list is List) {
        for (final c in list) {
          if (c is Map) out.add(Map<String, dynamic>.from(c));
        }
      }
    } else if (data is List) {
      for (final c in data) {
        if (c is Map) out.add(Map<String, dynamic>.from(c));
      }
    }
    return out;
  }

  Future<Map<String, dynamic>?> fetchNovelContent({
    required String ncid,
    String lang = 'TW',
  }) async {
    final params = {'ncid': ncid, 'lang': lang};
    var r = await _api.get('novelchapters', params);
    var data = r['data'];
    final first = data is Map ? Map<String, dynamic>.from(data) : null;
    if (first != null && '${first['content'] ?? ''}'.trim().isNotEmpty) {
      return first;
    }
    final alt = await _api.getWithHostRotation('novelchapters', params);
    if (alt != null && alt['data'] is Map) {
      final m = Map<String, dynamic>.from(alt['data'] as Map);
      if ('${m['content'] ?? ''}'.trim().isNotEmpty) {
        print('[JMOE] novel content recovered via host rotation');
        return m;
      }
    }
    return first;
  }

  static List<Map<String, dynamic>> chaptersFromDetail(Map<String, dynamic>? d) {
    if (d == null) return const [];
    final ser = d['series'];
    if (ser is! List) return const [];
    final out = <Map<String, dynamic>>[];
    for (final e in ser) {
      if (e is! Map) continue;
      final m = Map<String, dynamic>.from(e);
      final ncid = (m['NCID'] ?? m['ncid'] ?? m['id'] ?? '').toString();
      if (ncid.isEmpty) continue;
      out.add({
        'ncid': ncid,
        'title': (m['title'] ?? m['name'] ?? '').toString(),
        'sort': int.tryParse('${m['sort'] ?? ''}') ?? 0,
        'needLogin': '${m['is_need_login'] ?? '0'}' == '1',
        'needBuy': '${m['is_need_buy_nc'] ?? '0'}' == '1',
        'purchased': m['purchased'] == true,
      });
    }
    out.sort(
      (a, b) => (a['sort'] as int).compareTo(b['sort'] as int),
    );
    return out;
  }

  Future<List<Map<String, dynamic>>> searchNovels(String query) async {
    final r = await _api.get('search_novels', {'search_query': query});
    final data = r['data'];
    if (data is Map && data['list'] is List) {
      return (data['list'] as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return const [];
  }

  Future<List<Map<String, dynamic>>> fetchVideos({
    int page = 1,
    String? query,
    String videoType = 'all',
  }) async {
    final r = await _api.get('videos', {
      'page': page,
      if (query != null && query.isNotEmpty) 'search_query': query,
      'video_type': videoType,
    });
    final data = r['data'];
    if (data is Map && data['list'] is List) {
      return (data['list'] as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return const [];
  }

  Future<(List<Map<String, dynamic>>, bool, int)> fetchVideosPaged({
    int page = 1,
    String? query,
    String videoType = 'hanime',
  }) async {
    final r = await _api.get('videos', {
      'page': page,
      if (query != null && query.isNotEmpty) 'search_query': query,
      'video_type': videoType,
    });
    final data = r['data'];
    if (data is Map) {
      final raw = data['list'];
      final list = <Map<String, dynamic>>[];
      if (raw is List) {
        for (final e in raw) {
          if (e is Map) list.add(Map<String, dynamic>.from(e));
        }
      }
      final total = int.tryParse('${data['total'] ?? 0}') ?? 0;
      return (list, list.isNotEmpty && page * 40 < total, total);
    }
    return (const <Map<String, dynamic>>[], false, 0);
  }

  Future<Map<String, dynamic>?> fetchVideoInfo(
    String id, {
    String videoType = 'all',
  }) async {
    final r = await _api.get('video', {'id': id, 'video_type': videoType});
    if (r['data'] is Map) return Map<String, dynamic>.from(r['data'] as Map);
    return null;
  }

  Future<Map<String, dynamic>?> fetchBlogs({
    int page = 1,
    String blogType = 'all',
  }) async {
    final r = await _api.get('blogs', {'page': page, 'blog_type': blogType});
    if (r['data'] is Map) return Map<String, dynamic>.from(r['data'] as Map);
    return null;
  }

  Future<Map<String, dynamic>?> fetchBlogDetail(String id) async {
    final r = await _api.get('blog', {'id': id});
    if (r['data'] is Map) return Map<String, dynamic>.from(r['data'] as Map);
    return null;
  }

  Future<Map<String, dynamic>?> fetchGames() async {
    final r = await _api.get('allgames');
    if (r['data'] is Map) return Map<String, dynamic>.from(r['data'] as Map);
    return null;
  }

  Future<List<Map<String, dynamic>>> fetchCreators(String query) async {
    final r = await _api.get('creator_author', {
      'page': 1,
      'search_query': query,
    });
    final data = r['data'];
    if (data is Map && data['content'] is List) {
      return (data['content'] as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return const [];
  }

  List<Comic> _comicList(dynamic data) {
    final out = <Comic>[];
    if (data is List) {
      for (final c in data) {
        if (c is Map) out.add(Comic.fromJm(Map<String, dynamic>.from(c)));
      }
    }
    return out;
  }
}

class DailyDay {
  final String date;
  final bool signed;
  final bool bonus;
  const DailyDay({
    required this.date,
    required this.signed,
    required this.bonus,
  });
}

class DailyStatus {
  final bool valid;
  final bool todaySigned;
  final int signedCount;
  final int streakDays;
  final String progress;
  final List<DailyDay> days;

  const DailyStatus({
    this.valid = false,
    this.todaySigned = false,
    this.signedCount = 0,
    this.streakDays = 0,
    this.progress = '',
    this.days = const [],
  });
}
