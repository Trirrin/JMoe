import 'jm_service.dart';
import 'models.dart';
import 'source.dart';
import 'l10n.dart';

/// JM 数据源适配器：把 JmService 的接口映射到统一的 ComicSource。
class JmSource implements ComicSource {
  JmSource._();
  static final JmSource instance = JmSource._();

  final _service = JmService.instance;

  @override
  String get id => 'jm';

  @override
  String get label => 'JM';

  @override
  String? coverOf(Comic c) => _service.coverUrl(c);

  /// 清理服务端标题里的运营话术（如「連載更新→右滑看更多→」）。
  static String cleanTitle(String raw) {
    var s = raw;
    s = s.replaceAll(RegExp(r'→[^→]*→?'), '');
    s = s.replaceAll(RegExp(r'(左|右|上|下)滑(查看|看)?(更|更)?多'), '');
    s = s.replaceAll(RegExp(r'看更多'), '');
    s = s.replaceAll(RegExp(r'[→←↑↓]+'), '');
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  @override
  Future<HomeFeed> home({int page = 1}) async {
    // 只请求轻量接口，保证首屏快速出现内容；
    // 推荐分区（promote 响应体可达数 MB）由 homeDeferred 单独异步补齐。
    final results = await Future.wait([
      _service.fetchRandomRecommend().catchError((_) => <Comic>[]),
      _service.fetchLatest(page: page).catchError((_) => <Comic>[]),
    ]);
    final hero = results[0];
    final latest = results[1];

    final sections = <HomeSection>[];
    if (latest.isNotEmpty) {
      sections.add(
        HomeSection(title: L.t('latestUpdate'), items: latest, moreKey: 'latest'),
      );
    }
    return HomeFeed(
      hero: hero.take(8).toList(),
      sections: sections,
      hasMore: false,
      nextPage: 2,
    );
  }

  /// 异步补齐推荐分区（首页会先显示上面 home() 的结果）。
  Future<List<HomeSection>> homeDeferred() async {
    List<PromoteSection> promote;
    try {
      promote = await _service.fetchPromote();
    } catch (_) {
      return const [];
    }
    final sections = <HomeSection>[];
    for (final p in promote) {
      if (p.content.isEmpty) continue;
      final title = cleanTitle(p.title);
      if (title.isEmpty) continue;

      String? moreKey;
      switch (p.type) {
        case 'promote':
          moreKey = 'promote:${p.filterVal.isNotEmpty ? p.filterVal : p.id}';
          break;
        case 'category_id':
          moreKey = 'category:${p.filterVal}';
          break;
        default:
          moreKey = null;
      }
      sections.add(
        HomeSection(
          title: title,
          items: p.content,
          grid: p.type != 'promote',
          moreKey: moreKey,
        ),
      );
    }
    return sections;
  }

  @override
  Future<PageResult<Comic>> search(
    String query, {
    int page = 1,
    String order = 'mr',
  }) async {
    final (list, total) = await _service.search(
      query,
      page: page,
      order: order,
    );
    return PageResult(
      items: list,
      total: total,
      hasMore: list.isNotEmpty && (total == 0 || page * 24 < total),
      nextPage: page + 1,
    );
  }

  @override
  Future<List<BrowseCategory>> categories() async {
    final groups = await _service.fetchCategories();
    return groups
        .map(
          (g) => BrowseCategory(
            id: g.id,
            // 服务端仅对 id 型分类下发 total_albums；slug 型（最新A漫/Cosplay/3D/
            // 禁漫漢化組）为 0，此时不显示数字，避免误以为没有内容。
            label: _catLabel(g),
            slug: g.slug.isEmpty ? g.id : g.slug,
            subs: g.subs
                .map(
                  (s) => BrowseCategory(id: s.id, label: s.name, slug: s.slug),
                )
                .toList(),
          ),
        )
        .toList();
  }

  /// 分类显示名：有真实数量时附在第二行。
  static String _catLabel(CategoryGroup g) {
    final n = int.tryParse(g.total) ?? 0;
    return n > 0 ? '${g.name}\n$n' : g.name;
  }

  @override
  Future<PageResult<Comic>> browse({
    String? category,
    String? sub,
    int page = 1,
    String order = 'mr',
  }) async {
    final (list, total) = await _service.fetchCategoryFilter(
      slug: category ?? 'doujin',
      order: order,
      page: page,
      sub: sub,
    );
    return PageResult(
      items: list,
      total: total,
      hasMore: list.isNotEmpty && (total == 0 || page * 24 < total),
      nextPage: page + 1,
    );
  }

  @override
  Future<DetailInfo> detail(Comic comic) async {
    final d = await _service.fetchAlbum(comic.id);
    if (d == null) {
      return DetailInfo(comic: comic);
    }
    // 单本作品 series 为空（series_id=0）：把自身当作唯一章节，
    // 否则详情页不会出现「开始阅读」。
    final chapters = d.series.isNotEmpty
        ? d.series
        : <Chapter>[
            Chapter(
              id: d.comic.id,
              name: d.comic.name,
              sort: 1,
              source: 'jm',
            ),
          ];

    return DetailInfo(
      comic: d.comic,
      description: d.comic.description ?? '',
      tags: d.tags,
      chapters: chapters,
      related: d.related,
      totalPages: d.totalPhotos,
      views: d.views,
      likes: d.likes,
      comments: d.commentTotal,
    );
  }

  @override
  Future<ReadBundle> read(Comic comic, Chapter chapter) async {
    final r = await _service.fetchRead(chapter.id);
    if (r == null) {
      return ReadBundle(
        albumId: comic.id,
        chapterId: chapter.id,
        chapterName: chapter.name,
        pages: const [],
      );
    }
    return ReadBundle(
      albumId: comic.id,
      chapterId: r.id,
      chapterName: r.name.isNotEmpty ? r.name : chapter.name,
      scrambleId: r.scrambleId,
      // 官方 scramble_image 的 aid 参数即 readList.id（章节 ID）
      scrambleAid: r.id,
      pages: r.images.map((p) => PageRef(p.page, directUrl: p.url)).toList(),
    );
  }

  @override
  Future<String?> resolvePageUrl(String pageUrl) async => null;

  @override
  Future<PageResult<Comic>> more({required String key, int page = 1}) async {
    if (key == 'latest') {
      final list = await _service.fetchLatest(page: page);
      return PageResult(
        items: list,
        hasMore: list.isNotEmpty,
        nextPage: page + 1,
      );
    }
    if (key.startsWith('category:')) {
      final catId = key.substring(9);
      final (list, total) = await _service.fetchCategoryFilter(
        slug: catId,
        page: page,
      );
      return PageResult(
        items: list,
        total: total,
        hasMore: list.isNotEmpty && (total == 0 || page * 24 < total),
        nextPage: page + 1,
      );
    }
    final id = key.startsWith('promote:') ? key.substring(8) : key;
    final (list, total) = await _service.fetchPromoteList(id, page);
    return PageResult(
      items: list,
      total: total,
      hasMore: list.isNotEmpty && (total == 0 || page * 24 < total),
      nextPage: page + 1,
    );
  }
}
