import 'dart:async';

import 'package:dio/dio.dart';
import '../core/app_log.dart';
import '../core/app_state.dart';
import '../core/jm_protocol.dart';
import '../core/models.dart';

/// JM 站点的业务 API 封装（端点常量与官方客户端 `apiPaths` 一一对应）。
class JmService {
  JmService._();
  static final JmService instance = JmService._();

  JmApi get _api => JmApi.instance;

  String? imgHost = JmProtocol.fallbackImgHost;
  String? logoUrl;
  Map<String, dynamic>? settings;

  /// 应用设置（含 img_host / app_shunts / is_cn 等）。
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

  /// 封面地址。
  ///
  /// ⚠️ 服务端在列表项的 `image` 字段里下发的是**写死的 CDN 域名**
  /// （实测见过 `cdn-msp2.jmdanjonproxy.vip`、`tencent.jmdanjonproxy.xyz`），
  /// 这些域名在部分网络下直接 `Connection reset by peer` —— 表现就是
  /// 「封面全是灰块」。而 `/setting` 下发的 `img_host` 才是当前可用图源
  /// （官方客户端靠 `app_img_shunt` 切它）。
  ///
  /// 所以：凡是 JM 的封面，**一律用本机 imgHost 重拼**，只保留服务端给的
  /// 路径部分（`/media/...`），不信任它写死的域名。
  String? coverUrl(Comic c) {
    final host = imgHost ?? JmProtocol.fallbackImgHost;
    final raw = c.image;
    if (raw != null && raw.isNotEmpty) {
      if (raw.startsWith('http')) {
        // 只有域名不属于 JM 的 CDN 家族时才原样使用
        // （EH 源的封面、或第三方图片）
        if (c.source != 'jm') return raw;
        final path = _pathOf(raw);
        if (path.isEmpty) return raw;
        return '$host$path';
      }
      // 相对路径，直接拼当前图源
      return '$host${raw.startsWith('/') ? '' : '/'}$raw';
    }
    if (c.source == 'jm' && c.id.isNotEmpty) {
      final v = c.updateAt ?? 0;
      return '$host/media/albums/${c.id}_3x4.jpg?v=$v';
    }
    return null;
  }

  /// 从绝对 URL 里取出「路径 + 查询串」，用于替换域名。
  static String _pathOf(String url) {
    try {
      final u = Uri.parse(url);
      final q = u.hasQuery ? '?${u.query}' : '';
      return '${u.path}$q';
    } catch (_) {
      return '';
    }
  }


  /// 图片线路测速：请求该 CDN 上的一张固定小图，返回毫秒数。
  /// 失败返回 null。
  Future<int?> measureImgHost(
    String host, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final sw = Stopwatch()..start();
    try {
      // 用一张确定存在的缩略图探测（promote 里的首图更稳，但需请求；
      // 这里用 logo 路径，几乎所有镜像都同步）
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

  /// 手动指定首选图片线路（持久化由调用方通过 AppState 完成）。
  void setImgHost(String host) {
    if (host.isEmpty) return;
    imgHost = host;
  }

  /// 图片主机的备用域名，加载失败时依次尝试。
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

  /// 给一个可能已经失效的图片地址，列出所有可替换的候选地址。
  ///
  /// 用在「取图失败」的自愈路径上：服务端下发的图片域名可能是死域名，
  /// 换成本机 imgHost / 备用镜像往往立刻就能出图。
  List<String> imageUrlCandidates(String url) {
    final path = _pathOf(url);
    if (path.isEmpty) return const [];
    return [
      for (final h in imgHostCandidates)
        if (!url.startsWith(h)) '$h$path',
    ];
  }

  // ---------------- 首页 ----------------

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
      if (date != null) 'date': date,
      'page': page,
    });
    final data = r['data'];
    if (data is Map && data['list'] is List) {
      final total = int.tryParse('${data['total'] ?? 0}') ?? 0;
      return (_comicList(data['list']), total);
    }
    return (const <Comic>[], 0);
  }

  // ---------------- 分类 / 搜索 ----------------

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

  /// 站内搜索。
  ///
  /// 参数与官方客户端 `Search.tsx` 一一对应：
  ///  * `o`  排序：`''` 最新 / `mv` 最多观看 / `mp` 最多图片 / `tf` 最多爱心
  ///  * `search_type` 搜索方式：`site` 综合 / `work` 作品 / `author` 作者 /
  ///    `tag` 标签 / `character` 角色
  ///  * `y` / `m` 年份 / 月份筛选（`2024` / `3`）
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

  // ---------------- 详情 / 阅读 ----------------

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

  /// 下载信息（需登录）。
  Future<Map<String, dynamic>?> fetchDownload(String id) async {
    final r = await _api.get('album_download_2/$id');
    if (r['data'] is Map) return Map<String, dynamic>.from(r['data'] as Map);
    return null;
  }

  // ---------------- 会员 ----------------

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

  /// 校验当前 JWT 是否仍然有效。
  ///
  /// 为什么需要它：服务端 token 会过期，但本地会话（jwt + member）会一直留着。
  /// 过期后表现是「界面显示已登录，但收藏/历史全是空的」，用户完全无从判断。
  /// 启动时调一次轻量接口，401 就说明凭据失效，应清理本地会话并提示重新登录。
  ///
  /// 返回 true = 仍有效；false = 已失效；null = 网络问题，无法判断
  /// （此时**不要**清除会话，否则断网启动会把用户踢下线）。
  Future<bool?> verifySession() async {
    if (AppState.instance.offlineMode) return null;
    try {
      final r = await _api.get('member', {});
      final code = r['code'];
      if (code == 200) return true;
      if (code == 401) return false;
      // 其它 code（5xx / 线路故障）不算凭据问题
      print('[JMOE] verifySession inconclusive: code=$code');
      return null;
    } catch (e) {
      print('[JMOE] verifySession EXC: $e');
      return null;
    }
  }

  // ---------------- 收藏 / 历史 / 点赞 ----------------

  /// 最近一次 `fetchFavorites` 是否真的拿到了云端数据。
  ///
  /// 未登录 / 凭据过期时接口返回 `code=401` + 空 data，而 [fetchFavorites]
  /// 只能返回空列表 —— 调用方无法区分「真的没有收藏」和「拉取失败」。
  /// 书架据此决定要不要给条目打「本地」角标：
  /// 拉取失败时**一律不打**，否则会把所有条目都误标成本地。
  bool lastFavoritesOk = false;

  /// 上次拉收藏是否因为**鉴权失败**（401「請先登入會員」）。
  ///
  /// 这与「网络失败」要区分开：前者说明本地 JWT 已过期，
  /// 界面却仍显示已登录，用户会一直搞不清为什么同步不了。
  bool lastFavoritesAuthFailed = false;

  Future<(List<Comic>, int)> fetchFavorites({
    int page = 1,
    String folderId = '0',
    String order = 'mr',
  }) async {
    lastFavoritesOk = false;
    lastFavoritesAuthFailed = false;
    // 诊断：明确记录「本次请求是否带上了鉴权头」。
    // 401 有两种完全不同的原因：token 真的失效，或者 token 根本没注入。
    // 不打这一行的话，用户只能看到「同步失败」却无从判断。
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
      // 失败要留痕：401 = 凭据失效，其它 = 服务端异常
      print('[JMOE] fetchFavorites failed: code=$code msg=${r['errorMsg']}');
      unawaited(AppLog.instance.log(
        'FAV',
        'fetchFavorites failed code=$code msg=${r['errorMsg']}',
      ));
      lastFavoritesOk = false;
      // 401 标记为「鉴权失败」：调用方据此触发自动退出登录
      lastFavoritesAuthFailed = code == 401;
      return (const <Comic>[], 0);
    }
    final data = r['data'];
    if (data is Map) {
      final total = int.tryParse('${data['total'] ?? 0}') ?? 0;
      lastFavoritesOk = true;
      return (_comicList(data['list'] ?? data['content']), total);
    }
    // code=200 但 data 不是 Map：格式异常，同样视为失败
    print('[JMOE] fetchFavorites bad data: ${data.runtimeType}');
    lastFavoritesOk = false;
    return (const <Comic>[], 0);
  }

  /// 切换收藏状态（官方接口语义就是「切换」，没有显式 add/remove）。
  ///
  /// ⚠️ **这是切换语义**：连续调用两次会回到原状态。
  /// 因此上层绝不能靠「重试」来保证幂等 —— 网络超时后重发可能反而
  /// 把刚取消的又收藏回来。需要可靠同步时请用 [setFavorite]。
  Future<Map<String, dynamic>> toggleFavorite(String aid) async =>
      _api.post('favorite', {'aid': aid});

  /// **幂等地**把某作品设为「已收藏 / 未收藏」。
  ///
  /// 实现思路：切换接口无法指定目标状态，所以先确认当前状态，
  /// 只有确实不一致时才切换一次，切换后再回读校验。
  ///
  /// [isFavoriteNow] 由调用方传入（它掌握本地已知状态），
  /// 可避免每次都多打一次列表接口。
  ///
  /// 返回 (成功?, 错误信息)。
  Future<({bool ok, String? error})> setFavorite(
    String aid, {
    required bool target,
  }) async {
    try {
      // 1) 回读云端当前状态（以服务端为准，避免本地状态过期导致反向操作）
      final current = await _isFavoriteOnCloud(aid);
      if (current == null) {
        // 读不到状态就不敢盲切 —— 盲切很可能把状态弄反
        return (ok: false, error: 'cannot read favorite state');
      }
      if (current == target) {
        // 已经是目标状态，无需操作（幂等）
        return (ok: true, error: null);
      }
      // 2) 切换一次
      final r = await toggleFavorite(aid);
      if (r['code'] != 200) {
        return (ok: false, error: '${r['errorMsg'] ?? 'code=${r['code']}'}');
      }
      // 3) 回读校验：确认真的改过来了
      final after = await _isFavoriteOnCloud(aid);
      if (after == null) {
        // 校验失败：不确定结果，交给上层重试
        return (ok: false, error: 'cannot verify favorite state');
      }
      if (after == target) return (ok: true, error: null);
      return (ok: false, error: 'state mismatch after toggle');
    } catch (e) {
      return (ok: false, error: '$e');
    }
  }

  /// 查云端某作品是否在收藏里。返回 null 表示查询失败（未知）。
  Future<bool?> _isFavoriteOnCloud(String aid) async {
    final target = aid.trim();
    // 收藏可能很多，最多翻 30 页（够覆盖常见规模）
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

  /// 点赞。
  ///
  /// 必须用 **urlencoded** 提交：实测 `like` 接口对 multipart 会返回
  /// 「点讚失败」，只有 x-www-form-urlencoded 才返回 200。
  Future<Map<String, dynamic>> toggleLike(String id) async =>
      _api.postForm('like', {'id': id, 'like_type': 'album'});

  // ---------------- 每周必看 ----------------

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

  // ---------------- 评论 / 论坛 ----------------

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
      if (commentId != null) 'comment_id': commentId,
    });
  }

  /// 某个用户的评论列表（「我的评论」页用）。
  ///
  /// 服务端 `forum` 支持 `uid` 过滤（实测：传 uid 后 total 变成该用户的
  /// 评论数、返回项 UID 全等于它）。返回原始项，由页面自己渲染，
  /// 因为评论里混着漫画评论（有 AID）和聊天区发言（无 AID）。
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

  /// 评论点赞 / 取消点赞（comment_vote）。
  Future<Map<String, dynamic>> voteComment(String commentId,
          {String? aid}) async =>
      _api.post('comment_vote', {
        'comment_id': commentId,
        if (aid != null) 'aid': aid,
      });

  // ---------------- 通知 / 签到 ----------------

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


  // ---------------- 账号资产 / 签到 / 套餐（只读） ----------------

  /// 当前账号资产：JCoin 余额、经验、会员到期等。
  ///
  /// 官方端点 `coin` 在未登录时返回 `{status:0, msg:"請先登入會員"}`；
  /// 登录后返回资产字段。字段名可能随版本变化，这里做宽松解析。
  Future<Map<String, dynamic>?> fetchCoin() async {
    try {
      final r = await _api.get('coin', {});
      final d = r['data'];
      if (d is Map) {
        final m = Map<String, dynamic>.from(d);
        // 统一抽取常见字段
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
      // data 是字符串/空时视为未登录或不可用
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

  /// 签到活动信息（含连续签到奖励）。
  Future<Map<String, dynamic>?> fetchDaily(String userId) async {
    try {
      final r = await _api.get('daily', {'user_id': userId});
      final d = r['data'];
      if (d is Map) return Map<String, dynamic>.from(d);
    } catch (_) {}
    return null;
  }

  /// 解析签到状态：今天是否已签到 + 连续天数 + 本月日历。
  ///
  /// ⚠️ 服务端 `record` 是**二维**的：按周分组，每周一个子数组
  /// （实测 `[[01..07],[08..14],[15..21],[22..28],[29..30]]`）。
  /// 早期只取了每组的 `first`，于是日历上只剩 1/8/15/22/29 —— 这就是
  /// 「签到日历只显示 1、今天、15、22、29」的根因。这里必须整体摊平。
  static DailyStatus parseDaily(Map<String, dynamic>? d) {
    if (d == null) return const DailyStatus();
    final now = DateTime.now();
    final todayStr = now.day.toString().padLeft(2, '0');

    final rec = d['record'];
    final days = <DailyDay>[];
    if (rec is List) {
      for (final r in rec) {
        if (r is List) {
          // 正常的按周分组
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
          // 兜底：服务端改成平铺数组时也能解析
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
    // 按日期排序（服务端顺序理论上有序，但别依赖它）
    days.sort((a, b) => a.date.compareTo(b.date));

    final todaySigned = days.any((e) => e.date == todayStr && e.signed);
    final signedCount = days.where((e) => e.signed).length;
    // 连续天数：从今天往前数（今天未签则从昨天数）
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

  /// 执行签到。
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

  /// 会员套餐（只读展示）。不发起任何支付。
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


  // ---------------- 账号资料编辑 ----------------

  /// 读取账号资料（可编辑字段）。
  ///
  /// 官方端点：`GET useredit/{uid}`，返回 nickName / firstName / lastName /
  /// gender / birthday / website / city / country / occupation / aboutMe 等。
  Future<Map<String, dynamic>?> fetchProfile(String uid) async {
    try {
      final r = await _api.get('useredit/$uid', {});
      final d = r['data'];
      if (d is Map) return Map<String, dynamic>.from(d);
    } catch (_) {}
    return null;
  }

  /// 保存账号资料。
  ///
  /// 实测要点：
  /// - **必须带 uid 字段**，否则服务端返回 520 或静默失败
  /// - `birthday` 不能是 `"0000-00-00"`（会报「無效生日」），空值应不提交
  /// - 成功时 msg = "Profile was successfully updated!"
  /// - 改密码用 `password` + `password_confirm`
  ///
  /// 邮箱无法通过此接口修改（返回里根本没有 email 字段），
  /// 需要在官方站点操作。
  Future<({bool ok, String? message})> saveProfile(
    String uid,
    Map<String, dynamic> fields, {
    String? newPassword,
    String? newPasswordConfirm,
  }) async {
    // 白名单过滤，杜绝误传敏感字段
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
      // 生日为空或占位值不提交（服务端会判为无效）
      if (k == 'birthday') {
        if (sv.isEmpty || sv.startsWith('0000')) return;
      }
      if (sv.isEmpty) return;
      payload[k] = sv;
    });

    // 改密码
    if (newPassword != null && newPassword.isNotEmpty) {
      payload['password'] = newPassword;
      payload['password_confirm'] = newPasswordConfirm ?? newPassword;
    }

    try {
      final r = await _api.post('useredit/$uid', payload);
      final code = r['code'];
      final msg = r['errorMsg'] ?? r['msg'];
      final msgStr = (msg == null || '$msg'.isEmpty) ? null : '$msg';

      // 成功判定：code 200 且 msg 不是失败措辞
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

  // ---------------- 小说 ----------------

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

  /// 小说章节列表：来自 `novelchapters`。
  ///
  /// 与 [fetchNovelContent] 一样，单线路 500 时换线重试 ——
  /// 否则章节列表会空掉，整个阅读页进不去。
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

  /// 小说正文（单章）。返回含 content(HTML)/title/total_views 等字段。
  ///
  /// ⚠️ 实测发现：`novelchapters` 在部分线路上**稳定 HTTP 500**
  /// （cdnbtd / cdnutc / cdngwc.net 全部 500，而 cdngwc.club、
  /// cdnutc.me 正常返回正文）。这是服务端单线路故障，不是参数问题。
  ///
  /// 因此这里：当前线路拿不到 content 就**换线重试一次**，
  /// 避免用户看到「本章内容需要登录或购买后查看」这种误导性提示。
  Future<Map<String, dynamic>?> fetchNovelContent({
    required String ncid,
    String lang = 'TW',
  }) async {
    final params = {'ncid': ncid, 'lang': lang};
    var r = await _api.get('novelchapters', params);
    var data = r['data'];
    final first = data is Map ? Map<String, dynamic>.from(data) : null;
    // 有 content 就直接用
    if (first != null && '${first['content'] ?? ''}'.trim().isNotEmpty) {
      return first;
    }
    // 没拿到正文 → 换线路再试
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

  /// 小说章节列表（从详情 series 提取，统一排序）。
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

  // ---------------- 视频 / 游戏 / 博客 / 书库 ----------------

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

  /// 视频分页（返回 列表/是否有更多/总数）。
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

  // ---------------- 工具 ----------------

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


/// 单日签到状态。
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

/// 签到总体状态。
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
