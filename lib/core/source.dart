import 'models.dart';

/// 统一数据源抽象层。
///
/// 目标：**JM 与 e-hentai 共用同一套 UI 与阅读器**，
/// 每个源只负责把自己的数据映射到统一 DTO，界面层完全不感知来源差异。

/// 一页内容的定位信息。
class PageRef {
  /// 页序号（从 1 开始）
  final int index;

  /// 可直接下载的图片地址（JM 源）
  final String? directUrl;

  /// 需要先解析出图片地址的页面地址（e-hentai 源）
  final String? resolveUrl;

  const PageRef(this.index, {this.directUrl, this.resolveUrl});
}

/// 一章可阅读内容。
class ReadBundle {
  final String albumId;
  final String chapterId;
  final String chapterName;
  final List<PageRef> pages;

  /// JM 图片打乱还原参数；EH 为 null（无需还原）
  final String? scrambleId;

  /// 用于计算分片数的 ID —— 必须与官方 `scramble_image(img, aid, ...)` 的
  /// aid 一致：官方传的是 `readList.id`（章节 ID），而非作品 ID。
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

/// 作品详情（两源统一）。
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

  /// e-hentai 等源的附加信息行（分类/上传者/发布时间…）
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
  });
}

/// 首页分段。
class HomeSection {
  final String title;
  final List<Comic> items;

  /// true = 网格；false = 横向轮播
  final bool grid;

  /// 有值时表示可「查看更多」
  final String? moreKey;

  const HomeSection({
    required this.title,
    required this.items,
    this.grid = true,
    this.moreKey,
  });
}

/// 首页聚合结果（两源统一）。
class HomeFeed {
  final List<Comic> hero;
  final List<HomeSection> sections;

  /// 是否还有下一页（供无限滚动追加到最后一个 section）
  final bool hasMore;
  final int nextPage;

  const HomeFeed({
    this.hero = const [],
    this.sections = const [],
    this.hasMore = false,
    this.nextPage = 2,
  });
}

/// 通用分页结果。
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

/// 分类节点。
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

/// 数据源接口：所有界面都只依赖它。
abstract class ComicSource {
  String get id;
  String get label;

  /// 封面地址
  String? coverOf(Comic c);

  Future<HomeFeed> home({int page = 1});

  Future<PageResult<Comic>> search(
    String query, {
    int page = 1,
    String order = 'mr',
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

  /// 解析单页图片地址（EH 等需要二次解析的源实现；JM 直接返回 null）
  Future<String?> resolvePageUrl(String pageUrl) async => null;

  /// 首页「查看更多」
  Future<PageResult<Comic>> more({required String key, int page = 1});
}
