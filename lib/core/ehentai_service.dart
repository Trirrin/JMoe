import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;

import 'models.dart';
import 'app_log.dart';
import 'l10n.dart';

/// e-hentai.org 数据源适配。
///
/// 通过解析站点 HTML 实现（与浏览同一份页面），
/// 图页需要顺序取 `img#img` 的 `src`，缩略图使用雪碧图切片信息。
class EHentaiService {
  EHentaiService._();
  static final EHentaiService instance = EHentaiService._();

  /// 主域名 + 备用镜像（部分网络下主域不可达）
  static const List<String> _mirrorList = [
    'https://e-hentai.org',
    'https://e-hentai.exhentai.org',
  ];

  /// 上次成功的域名，后续优先使用
  static String _base = 'https://e-hentai.org';

  /// 当前使用的域名
  String get base => _base;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 25),
      followRedirects: true,
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/124.0 Safari/537.36',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      },
    ),
  );

  /// 站点 Cookie（登录态）。
  String? cookie;

  /// 把某个域名替换为候选域名
  String _swapBase(String url, String newBase) {
    for (final m in _mirrorList) {
      if (url.startsWith(m)) return newBase + url.substring(m.length);
    }
    return url;
  }

  /// 带镜像回退的抓取：当前域名失败后依次尝试其他镜像。
  Future<String?> _getHtmlWithFallback(String url) async {
    // 先试当前域名
    final first = await _getHtml(url);
    if (first != null && first.isNotEmpty) return first;

    // 依次尝试其他镜像
    for (final m in _mirrorList) {
      if (m == _base) continue;
      final swapped = _swapBase(url, m);
      if (swapped == url) continue;
      final r = await _getHtml(swapped);
      if (r != null && r.isNotEmpty) {
        _base = m; // 记住可用域名
        return r;
      }
    }
    return null;
  }

  Future<String?> _getHtml(String url) async {
    try {
      final res = await _dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: true,
          maxRedirects: 5,
          validateStatus: (c) => c != null && c < 500,
          headers: {
            // 关键：EH 对没有 User-Agent 的请求直接返回空页，
            // 这正是「EH 源空白」的根因。
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                    'AppleWebKit/537.36 (KHTML, like Gecko) '
                    'Chrome/120.0.0.0 Safari/537.36',
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,'
                    'image/webp,*/*;q=0.8',
            'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
            if (cookie != null && cookie!.isNotEmpty) 'Cookie': cookie!,
            'Referer': base,
          },
        ),
      );
      final body = res.data;
      if (body == null || body.isEmpty) {
        unawaited(AppLog.instance.log('EH', 'empty body: $url'));
        return null;
      }
      // 被拦截时 EH 会返回含「Sad Panda」/「IP blocked」的页面
      if (body.contains('Sad Panda') ||
          body.contains('IP address') && body.contains('blocked')) {
        unawaited(AppLog.instance.log('EH', 'blocked by EH at $url'));
        return null;
      }
      return body;
    } catch (e) {
      unawaited(AppLog.instance.log('EH', 'fetch failed: $url', e));
      return null;
    }
  }

  /// 抓取图片原始字节（绕过防盗链）。
  Future<Uint8List?> fetchBytes(String url, {String? referer}) async {
    try {
      final res = await _dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            if (cookie != null && cookie!.isNotEmpty) 'Cookie': cookie!,
            'Referer': referer ?? base,
            'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
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

  String _abs(String? url) {
    if (url == null || url.isEmpty) return '';
    if (url.startsWith('http')) return url;
    if (url.startsWith('//')) return 'https:$url';
    return '$base${url.startsWith('/') ? '' : '/'}$url';
  }

  /// 首页 / 搜索结果 / 分类列表统一解析。
  Future<EHPage> fetchListing(String url) async {
    final html = await _getHtmlWithFallback(url);
    if (html == null) {
      return const EHPage(items: [], nextUrl: null, total: 0);
    }
    final doc = html_parser.parse(html);
    final items = <EHItem>[];

    // 新版 EH 列表：每个条目是 <td class="gl3c glname"><a href=...>，
    // 标题在内部 <div class="glink">。直接遍历 glname 单元格更稳，
    // 不依赖外层表格的 class（历史上 itg/gtb 变过）。
    var rows = doc.querySelectorAll('td.glname');
    if (rows.isEmpty) {
      // 兜底：旧结构
      rows = doc.querySelectorAll('table.itg tr');
    }

    for (final tr in rows) {
      // 链接可能直接是 td.gl3c a，也可能在 td 内部
      final link = tr.querySelector('a[href*="/g/"]') ??
          tr.querySelector('td.gl3c a');
      if (link == null) continue;
      final href = _abs(link.attributes['href']);
      final titleEl = tr.querySelector('.glink');
      final title = titleEl?.text.trim() ?? link.text.trim();
      if (title.isEmpty) continue;

      // 封面：gl1c 内 div.glthumb img 的 data-src / src，或雪碧图背景
      String cover = '';
      final thumbImg = tr.querySelector('div.glthumb img');
      if (thumbImg != null) {
        cover = _abs(
          thumbImg.attributes['data-src'] ?? thumbImg.attributes['src'],
        );
        if (cover.startsWith('data:')) cover = '';
      }
      if (cover.isEmpty) {
        final cut = tr.querySelector('div.glcut');
        final style = cut?.attributes['style'] ?? '';
        final m = RegExp(r'url\((.*?)\)').firstMatch(style);
        if (m != null) cover = _abs(m.group(1));
      }

      final catEl = tr.querySelector('.cn');
      final posted = tr.querySelector('#posted_${_gidOf(href)}') ??
          tr.querySelector('#postedpop_${_gidOf(href)}');
      final pagesText = tr.querySelectorAll('td.gl4c div').length > 1
          ? tr.querySelectorAll('td.gl4c div').last.text.trim()
          : '';
      final ratingEl = tr.querySelector('.ir');
      double? rating;
      if (ratingEl != null) {
        final pos = ratingEl.attributes['style'] ?? '';
        final m = RegExp(r'-(\d+)px').firstMatch(pos);
        if (m != null) {
          final v = int.tryParse(m.group(1)!) ?? 0;
          if (v >= 0 && v <= 49) rating = v / 5.0;
        }
      }
      final tags = <String>[];
      for (final gt in tr.querySelectorAll('.gt')) {
        final t = gt.attributes['title'];
        if (t != null && t.isNotEmpty) tags.add(t);
      }
      items.add(
        EHItem(
          url: href,
          gid: _gidOf(href),
          title: title,
          cover: cover,
          category: catEl?.text.trim() ?? '',
          pages: int.tryParse(RegExp(r'(\d+)').firstMatch(pagesText)?.group(1) ?? '') ?? 0,
          posted: posted?.text.trim() ?? '',
          uploader: tr.querySelector('.gl4c a')?.text.trim() ?? '',
          rating: rating,
          tags: tags,
        ),
      );
    }

    String? nextUrl;
    final next = doc.querySelector('#unext, a#dnext');
    if (next != null) {
      final href = next.attributes['href'];
      if (href != null && href.isNotEmpty) nextUrl = _abs(href);
    }

    final totalText = doc.querySelector('.ip')?.text ?? '';
    final totalMatch = RegExp(r'([\d,]+)').firstMatch(totalText);
    final total = int.tryParse((totalMatch?.group(1) ?? '').replaceAll(',', '')) ?? 0;
    return EHPage(items: items, nextUrl: nextUrl, total: total);
  }

  String _gidOf(String url) {
    final m = RegExp(r'/g/(\d+)/').firstMatch(url);
    return m?.group(1) ?? '';
  }

  Future<EHGallery> fetchGallery(String url) async {
    final html = await _getHtmlWithFallback(url);
    if (html == null) throw Exception(L.t('galleryLoadFailed'));
    final doc = html_parser.parse(html);
    final title = doc.querySelector('#gn')?.text.trim() ?? '';
    final jpTitle = doc.querySelector('#gj')?.text.trim() ?? '';
    final coverStyle = doc.querySelector('#gd1 div')?.attributes['style'] ?? '';
    final coverMatch = RegExp(r'url\((.*?)\)').firstMatch(coverStyle);
    final cover = _abs(coverMatch?.group(1));

    final meta = <String, String>{};
    for (final tr in doc.querySelectorAll('#gdd tr')) {
      final k = tr.querySelector('.gdt1')?.text.trim() ?? '';
      final v = tr.querySelector('.gdt2')?.text.trim() ?? '';
      if (k.isNotEmpty) meta[k.replaceAll(':', '')] = v;
    }
    final uploader = doc.querySelector('#gdn a')?.text.trim() ?? '';
    final category = doc.querySelector('#gdc .cs')?.text.trim() ?? '';
    final tags = <String>[];
    for (final td in doc.querySelectorAll('#taglist td.tc')) {
      tags.add(td.text.trim().replaceAll(':', ''));
    }
    final tagLinks = <String>[];
    for (final a in doc.querySelectorAll('#taglist a')) {
      tagLinks.add(a.text.trim());
    }
    final ratingText = doc.querySelector('#rating_label')?.text ?? '';
    final ratingMatch = RegExp(r'([\d.]+)').firstMatch(ratingText);
    final rating = double.tryParse(ratingMatch?.group(1) ?? '');
    final favText = doc.querySelector('#favcount')?.text ?? '';
    final favMatch = RegExp(r'(\d+)').firstMatch(favText);

    // 缩略图页：每页的 /s/<key>/<gid>-<index> 链接
    final pageLinks = <String>[];
    final thumbs = doc.querySelectorAll('#gdt a');
    for (final a in thumbs) {
      final href = a.attributes['href'];
      if (href != null && href.contains('/s/')) pageLinks.add(_abs(href));
    }

    // 分页：每页 20/40 张缩略图，页面里 .ptt td a 提供后续缩略图页地址
    final thumbPages = <String>[];
    for (final a in doc.querySelectorAll('.ptt a')) {
      final href = a.attributes['href'];
      if (href != null && href.isNotEmpty) thumbPages.add(_abs(href));
    }
    thumbPages.sort();

    String? firstPageUrl = pageLinks.isNotEmpty ? pageLinks.first : null;

    // 若是多缩略图页，需要再抓取后续页拿到所有 /s/ 链接
    final allLinks = <String>[...pageLinks];
    if (thumbPages.length > 1) {
      for (final tp in thumbPages) {
        final sub = await _getHtmlWithFallback(tp);
        if (sub == null) continue;
        final subDoc = html_parser.parse(sub);
        for (final a in subDoc.querySelectorAll('#gdt a')) {
          final href = a.attributes['href'];
          if (href == null || !href.contains('/s/')) continue;
          final abs = _abs(href);
          if (!allLinks.contains(abs)) allLinks.add(abs);
        }
      }
      // 按 gid-index 排序
      allLinks.sort((a, b) {
        final ai = int.tryParse(RegExp(r'-(\d+)$').firstMatch(a)?.group(1) ?? '0') ?? 0;
        final bi = int.tryParse(RegExp(r'-(\d+)$').firstMatch(b)?.group(1) ?? '0') ?? 0;
        return ai.compareTo(bi);
      });
      if (allLinks.isNotEmpty) firstPageUrl = allLinks.first;
    }

    return EHGallery(
      url: url,
      gid: _gidOf(url),
      title: title,
      jpTitle: jpTitle,
      cover: cover,
      uploader: uploader,
      category: category,
      posted: meta['Posted'] ?? '',
      language: meta['Language'] ?? '',
      fileSize: meta['File Size'] ?? '',
      length: meta['Length'] ?? '',
      favorites: int.tryParse(favMatch?.group(1) ?? '') ?? 0,
      rating: rating,
      tagNamespace: tags,
      tags: tagLinks,
      pageLinks: allLinks,
      firstPageUrl: firstPageUrl,
    );
  }

  /// 取单页原图地址（`img#img`）。
  Future<String?> fetchImageUrl(String pageUrl) async {
    final html = await _getHtmlWithFallback(pageUrl);
    if (html == null) return null;
    final doc = html_parser.parse(html);
    final img = doc.querySelector('#img');
    final src = img?.attributes['src'];
    if (src == null || src.isEmpty) return null;
    return _abs(src);
  }

  String searchUrl(String query, {int page = 1}) {
    final q = Uri.encodeQueryComponent(query.trim());
    final suffix = page > 1 ? '&page=$page' : '';
    return '$base/?f_search=$q$suffix';
  }

  String popularUrl({int page = 1}) =>
      page > 1 ? '$base/?page=$page' : '$base/';

  String categoryUrl(String slug, {int page = 1}) {
    final suffix = page > 1 ? '?page=$page' : '';
    return '$base/$slug$suffix';
  }

  static List<Map<String, String>> get categories => [
    {'slug': 'doujinshi', 'label': L.t('doujinshi')},
    {'slug': 'manga', 'label': L.t('manga')},
    {'slug': 'artistcg', 'label': L.t('artistCg')},
    {'slug': 'gamecg', 'label': L.t('gameCg')},
    {'slug': 'western', 'label': L.t('western')},
    {'slug': 'non-h', 'label': L.t('nonH')},
    {'slug': 'imageset', 'label': L.t('imageSet')},
    {'slug': 'cosplay', 'label': 'Cosplay'},
    {'slug': 'asianporn', 'label': L.t('asianPorn')},
    {'slug': 'misc', 'label': L.t('misc')},
  ];
}

class EHItem {
  final String url;
  final String gid;
  final String title;
  final String cover;
  final String category;
  final int pages;
  final String posted;
  final String uploader;
  final double? rating;
  final List<String> tags;

  const EHItem({
    required this.url,
    required this.gid,
    required this.title,
    required this.cover,
    this.category = '',
    this.pages = 0,
    this.posted = '',
    this.uploader = '',
    this.rating,
    this.tags = const [],
  });
}

class EHPage {
  final List<EHItem> items;
  final String? nextUrl;
  final int total;
  const EHPage({required this.items, this.nextUrl, this.total = 0});
}

class EHGallery {
  final String url;
  final String gid;
  final String title;
  final String jpTitle;
  final String cover;
  final String uploader;
  final String category;
  final String posted;
  final String language;
  final String fileSize;
  final String length;
  final int favorites;
  final double? rating;
  final List<String> tagNamespace;
  final List<String> tags;
  final List<String> pageLinks;
  final String? firstPageUrl;

  const EHGallery({
    required this.url,
    required this.gid,
    required this.title,
    this.jpTitle = '',
    this.cover = '',
    this.uploader = '',
    this.category = '',
    this.posted = '',
    this.language = '',
    this.fileSize = '',
    this.length = '',
    this.favorites = 0,
    this.rating,
    this.tagNamespace = const [],
    this.tags = const [],
    this.pageLinks = const [],
    this.firstPageUrl,
  });

  Comic toComic() => Comic(
    id: 'eh_$gid',
    name: title,
    author: uploader,
    category: category,
    description: jpTitle,
    image: cover,
    source: 'ehentai',
  );
}
