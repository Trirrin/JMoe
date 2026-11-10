import 'jm_service.dart';
import 'models.dart';
import 'source.dart';
import 'l10n.dart';

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
    String order = '',
    String searchType = 'site',
    String? year,
    String? month,
  }) async {
    final (list, total) = await _service.search(
      query,
      page: page,
      order: order,
      searchType: searchType,
      year: year,
      month: month,
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
      liked: d.liked,
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
