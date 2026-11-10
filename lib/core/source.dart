import 'models.dart';

class PageRef {
  final int index;

  final String? directUrl;

  final String? resolveUrl;

  const PageRef(this.index, {this.directUrl, this.resolveUrl});
}

class ReadBundle {
  final String albumId;
  final String chapterId;
  final String chapterName;
  final List<PageRef> pages;

  final String? scrambleId;

  final String scrambleAid;

  const ReadBundle({
    required this.albumId,
    required this.chapterId,
    required this.chapterName,
    required this.pages,
    this.scrambleId,
    this.scrambleAid = '',
  });

  int get length => pages.length;
}

class DetailInfo {
  final Comic comic;
  final String description;
  final List<String> tags;
  final List<Chapter> chapters;
  final List<Comic> related;
  final int totalPages;
  final int views;
  final int likes;
  final int comments;

  final bool liked;

  final List<MapEntry<String, String>> meta;

  const DetailInfo({
    required this.comic,
    this.description = '',
    this.tags = const [],
    this.chapters = const [],
    this.related = const [],
    this.totalPages = 0,
    this.views = 0,
    this.likes = 0,
    this.comments = 0,
    this.meta = const [],
    this.liked = false,
  });
}

class HomeSection {
  final String title;
  final List<Comic> items;

  final bool grid;

  final String? moreKey;

  const HomeSection({
    required this.title,
    required this.items,
    this.grid = true,
    this.moreKey,
  });
}

class HomeFeed {
  final List<Comic> hero;
  final List<HomeSection> sections;

  final bool hasMore;
  final int nextPage;

  const HomeFeed({
    this.hero = const [],
    this.sections = const [],
    this.hasMore = false,
    this.nextPage = 2,
  });
}

class PageResult<T> {
  final List<T> items;
  final int total;
  final bool hasMore;
  final int nextPage;

  const PageResult({
    this.items = const [],
    this.total = 0,
    this.hasMore = false,
    this.nextPage = 2,
  });
}

class BrowseCategory {
  final String id;
  final String label;
  final String slug;
  final List<BrowseCategory> subs;

  const BrowseCategory({
    required this.id,
    required this.label,
    required this.slug,
    this.subs = const [],
  });
}

abstract class ComicSource {
  String get id;
  String get label;

  String? coverOf(Comic c);

  Future<HomeFeed> home({int page = 1});

  Future<PageResult<Comic>> search(
    String query, {
    int page = 1,
    String order = '',
    String searchType = 'site',
    String? year,
    String? month,
  });

  Future<List<BrowseCategory>> categories();

  Future<PageResult<Comic>> browse({
    String? category,
    String? sub,
    int page = 1,
    String order = 'mr',
  });

  Future<DetailInfo> detail(Comic comic);

  Future<ReadBundle> read(Comic comic, Chapter chapter);

  Future<String?> resolvePageUrl(String pageUrl) async => null;

  Future<PageResult<Comic>> more({required String key, int page = 1});
}
