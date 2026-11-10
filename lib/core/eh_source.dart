import 'app_state.dart';
import 'ehentai_service.dart';
import 'models.dart';
import 'source.dart';
import 'l10n.dart';

class EhSource implements ComicSource {
  EhSource._();
  static final EhSource instance = EhSource._();

  final _service = EHentaiService.instance;

  @override
  String get id => 'ehentai';

  @override
  String get label => 'E-Hentai';

  @override
  String? coverOf(Comic c) => c.image;

  Comic _toComic(EHItem item) => Comic(
    id: 'eh:${item.url}',
    name: item.title,
    author: item.uploader,
    category: item.category,
    image: item.cover,
    source: 'ehentai',
  );

  @override
  Future<HomeFeed> home({int page = 1}) async {
    final urls = [
      (_service.popularUrl(page: 1), L.t('latestUpload')),
      (_service.categoryUrl('doujinshi', page: 1), L.t('doujinshi')),
      (_service.categoryUrl('manga', page: 1), L.t('manga')),
    ];
    final pages = await Future.wait(
      urls.map((u) async {
        try {
          return await _service.fetchListing(u.$1);
        } catch (_) {
          return null;
        }
      }),
    );
    if (pages.every((p) => p == null)) {
      throw Exception(
        AppState.instance.offlineMode
            ? L.t('offline')
            : (_service.lastError ?? L.t('networkError')),
      );
    }
    final first = pages[0] ?? const EHPage(items: [], nextUrl: null, total: 0);

    final hero = first.items.take(8).map(_toComic).toList();
    final sections = <HomeSection>[
      for (var i = 1; i < urls.length; i++)
        if (pages[i]?.items.isNotEmpty == true)
          HomeSection(
            title: urls[i].$2,
            items: pages[i]!.items.map(_toComic).toList(),
            moreKey: 'cat:${urls[i].$1}',
          ),
      if (first.items.isNotEmpty)
        HomeSection(
          title: L.t('latestUpload'),
          items: first.items.map(_toComic).toList(),
          moreKey: 'next:${first.nextUrl ?? ''}',
        ),
    ];
    return HomeFeed(hero: hero, sections: sections);
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
    final p = await _service.fetchListing(_service.searchUrl(query, page: page));
    return PageResult(
      items: p.items.map(_toComic).toList(),
      total: p.total,
      hasMore: p.nextUrl != null,
      nextPage: page + 1,
    );
  }

  @override
  Future<List<BrowseCategory>> categories() async {
    return EHentaiService.categories
        .map(
          (c) => BrowseCategory(
            id: c['slug']!,
            label: c['label']!,
            slug: c['slug']!,
          ),
        )
        .toList();
  }

  @override
  Future<PageResult<Comic>> browse({
    String? category,
    String? sub,
    int page = 1,
    String order = 'mr',
  }) async {
    final p = await _service.fetchListing(
      _service.categoryUrl(category ?? 'doujinshi', page: page),
    );
    return PageResult(
      items: p.items.map(_toComic).toList(),
      total: p.total,
      hasMore: p.nextUrl != null,
      nextPage: page + 1,
    );
  }

  @override
  Future<DetailInfo> detail(Comic comic) async {
    final url = comic.id.startsWith('eh:')
        ? comic.id.substring(3)
        : comic.id;
    final g = await _service.fetchGallery(url);
    final meta = <MapEntry<String, String>>[
      if (g.category.isNotEmpty) MapEntry(L.t('tabCategories'), g.category),
      if (g.uploader.isNotEmpty) MapEntry(L.t('uploader'), g.uploader),
      if (g.posted.isNotEmpty) MapEntry(L.t('published'), g.posted),
      if (g.language.isNotEmpty) MapEntry(L.t('languageLabel'), g.language),
      if (g.fileSize.isNotEmpty) MapEntry(L.t('sizeLabel'), g.fileSize),
      if (g.length.isNotEmpty) MapEntry(L.t('pagesLabel'), g.length),
      if (g.rating != null)
        MapEntry(L.t('sortRating'), L.tp('ratingFav', {'rating': g.rating!.toStringAsFixed(1), 'n': g.favorites})),
    ];
    final count = g.pageLinks.length;
    return DetailInfo(
      comic: Comic(
        id: comic.id,
        name: g.title,
        author: g.uploader,
        category: g.category,
        image: g.cover.isNotEmpty ? g.cover : comic.image,
        source: 'ehentai',
      ),
      description: g.jpTitle,
      tags: g.tags.take(20).toList(),
      chapters: [
        Chapter(
          id: 'gallery',
          name: count > 0 ? L.tp('allPagesN', {'n': count}) : L.t('reading'),
          sort: 1,
          source: 'ehentai',
        ),
      ],
      related: const [],
      totalPages: count,
      meta: meta,
    );
  }

  final Map<String, EHGallery> _galleryCache = {};

  @override
  Future<ReadBundle> read(Comic comic, Chapter chapter) async {
    final url = comic.id.startsWith('eh:')
        ? comic.id.substring(3)
        : comic.id;
    final g = _galleryCache[url] ?? await _service.fetchGallery(url);
    _galleryCache[url] = g;
    return ReadBundle(
      albumId: comic.id,
      chapterId: chapter.id,
      chapterName: g.title,
      pages: [
        for (var i = 0; i < g.pageLinks.length; i++)
          PageRef(i + 1, resolveUrl: g.pageLinks[i]),
      ],
    );
  }

  @override
  Future<String?> resolvePageUrl(String pageUrl) =>
      _service.fetchImageUrl(pageUrl);

  @override
  Future<PageResult<Comic>> more({required String key, int page = 1}) async {
    String url;
    if (key.startsWith('cat:')) {
      final base = key.substring(4);
      url = page > 1 ? '$base?page=$page' : base;
    } else if (key.startsWith('next:')) {
      url = key.substring(5);
      if (url.isEmpty) return const PageResult();
    } else {
      url = _service.popularUrl(page: page);
    }
    final p = await _service.fetchListing(url);
    return PageResult(
      items: p.items.map(_toComic).toList(),
      total: p.total,
      hasMore: p.nextUrl != null,
      nextPage: page + 1,
    );
  }
}
