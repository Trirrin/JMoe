library;

String cleanAuthor(String raw) {
  var s = raw.trim();
  while (s.length >= 2 && s.startsWith('[') && s.endsWith(']')) {
    final inner = s.substring(1, s.length - 1);
    var depth = 0;
    var wrapsWhole = true;
    for (var i = 0; i < inner.length; i++) {
      final c = inner[i];
      if (c == '[') depth++;
      if (c == ']') depth--;
      if (depth < 0) {
        wrapsWhole = false;
        break;
      }
    }
    if (!wrapsWhole) break;
    s = inner.trim();
  }
  return s;
}

List<String> splitAuthors(String raw) {
  final base = cleanAuthor(raw);
  if (base.isEmpty) return const [];
  final parts = base.split(RegExp(r'\s*[,，、;/｜|]\s*'));
  final out = <String>[];
  for (final p in parts) {
    final t = cleanAuthor(p);
    if (t.isEmpty) continue;
    if (out.contains(t)) continue;
    out.add(t);
  }
  return out;
}

class Comic {
  final String id;
  final String name;
  final String author;
  final String? category;
  final String? categorySub;
  final String? description;
  final int? updateAt;
  final String? image;
  final bool liked;
  final bool isFavorite;
  final String source;

  final int? heat;

  List<String> get authorList => splitAuthors(author);

  const Comic({
    required this.id,
    required this.name,
    this.author = '',
    this.category,
    this.categorySub,
    this.description,
    this.updateAt,
    this.image,
    this.liked = false,
    this.isFavorite = false,
    this.source = 'jm',
    this.heat,
  });

  factory Comic.fromJm(Map<String, dynamic> j) {
    final cat = j['category'];
    final sub = j['category_sub'];
    return Comic(
      id: '${j['id']}',
      name: (j['name'] ?? '').toString(),
      author: cleanAuthor((j['author'] ?? '').toString()),
      category: cat is Map ? cat['title']?.toString() : null,
      categorySub: sub is Map ? sub['title']?.toString() : null,
      description: j['description']?.toString(),
      updateAt: j['update_at'] is num
          ? (j['update_at'] as num).toInt()
          : int.tryParse('${j['update_at'] ?? ''}'),
      image: (j['image'] as String?)?.isNotEmpty == true
          ? j['image'] as String
          : null,
      liked: j['liked'] == true,
      isFavorite: j['is_favorite'] == true,
      source: 'jm',
      heat: int.tryParse('${j['likes'] ?? j['total_views'] ?? ''}'),
    );
  }

  Comic copyWith({bool? liked, bool? isFavorite}) => Comic(
    id: id,
    name: name,
    author: author,
    category: category,
    categorySub: categorySub,
    description: description,
    updateAt: updateAt,
    image: image,
    liked: liked ?? this.liked,
    isFavorite: isFavorite ?? this.isFavorite,
    source: source,
  );
}

class Chapter {
  final String id;
  final String name;
  final int sort;
  final String? group;
  final String source;

  const Chapter({
    required this.id,
    required this.name,
    required this.sort,
    this.group,
    this.source = 'jm',
  });

  factory Chapter.fromJm(Map<String, dynamic> j) => Chapter(
    id: '${j['id']}',
    name: (j['name'] ?? '').toString(),
    sort: int.tryParse('${j['sort'] ?? 0}') ?? 0,
    source: 'jm',
  );

  bool get hasName => name.trim().isNotEmpty;
}

class PageImage {
  final int page;
  final String url;
  const PageImage(this.page, this.url);
}

class AlbumDetail {
  final Comic comic;
  final int totalPhotos;
  final int views;
  final int likes;
  final int commentTotal;
  final List<String> tags;
  final List<Chapter> series;
  final List<Comic> related;
  final String seriesId;
  final bool isAids;
  final String price;

  final bool liked;

  const AlbumDetail({
    required this.comic,
    this.totalPhotos = 0,
    this.views = 0,
    this.likes = 0,
    this.commentTotal = 0,
    this.tags = const [],
    this.series = const [],
    this.related = const [],
    this.seriesId = '',
    this.isAids = false,
    this.price = '',
    this.liked = false,
  });

  factory AlbumDetail.fromJm(Map<String, dynamic> d) {
    final series = <Chapter>[];
    final rawSeries = d['series'];
    if (rawSeries is List) {
      for (final s in rawSeries) {
        if (s is Map) series.add(Chapter.fromJm(Map<String, dynamic>.from(s)));
      }
    }
    final related = <Comic>[];
    final rawRelated = d['related_list'];
    if (rawRelated is List) {
      for (final r in rawRelated) {
        if (r is Map) {
          related.add(Comic.fromJm(Map<String, dynamic>.from(r)));
        }
      }
    }
    final tags = <String>[];
    final rawTags = d['tags'];
    if (rawTags is List) {
      for (final t in rawTags) {
        tags.add(t.toString());
      }
    }
    return AlbumDetail(
      comic: Comic.fromJm(d),
      totalPhotos: int.tryParse('${d['total_photos'] ?? 0}') ?? 0,
      views: int.tryParse('${d['total_views'] ?? 0}') ?? 0,
      likes: int.tryParse('${d['likes'] ?? 0}') ?? 0,
      commentTotal: int.tryParse('${d['comment_total'] ?? 0}') ?? 0,
      tags: tags,
      series: series,
      related: related,
      seriesId: '${d['series_id'] ?? ''}',
      isAids: d['is_aids'] == true,
      price: '${d['price'] ?? ''}',
      liked: d['liked'] == true,
    );
  }
}

class ReadChapter {
  final String id;
  final String name;
  final String scrambleId;
  final int totalPage;
  final List<PageImage> images;
  final String seriesId;

  const ReadChapter({
    required this.id,
    required this.name,
    required this.scrambleId,
    required this.totalPage,
    required this.images,
    this.seriesId = '',
  });

  factory ReadChapter.fromJm(Map<String, dynamic> d) {
    final images = <PageImage>[];
    final raw = d['images'];
    if (raw is List) {
      for (final i in raw) {
        if (i is Map) {
          images.add(
            PageImage(
              int.tryParse('${i['page'] ?? 0}') ?? 0,
              (i['image'] ?? '').toString(),
            ),
          );
        }
      }
    }
    return ReadChapter(
      id: '${d['id']}',
      name: (d['name'] ?? '').toString(),
      scrambleId: '${d['scramble_id'] ?? '0'}',
      totalPage: int.tryParse('${d['total_page'] ?? images.length}') ?? images.length,
      images: images,
      seriesId: '${d['series_id'] ?? ''}',
    );
  }
}

class CategoryGroup {
  final String id;
  final String name;
  final String slug;
  final String total;
  final List<CategoryGroup> subs;

  const CategoryGroup({
    required this.id,
    required this.name,
    required this.slug,
    this.total = '',
    this.subs = const [],
  });

  factory CategoryGroup.fromJm(Map<String, dynamic> j) {
    final subs = <CategoryGroup>[];
    final raw = j['sub_categories'];
    if (raw is List) {
      for (final s in raw) {
        if (s is Map) {
          subs.add(
            CategoryGroup(
              id: '${s['CID'] ?? ''}',
              name: (s['name'] ?? '').toString(),
              slug: (s['slug'] ?? '').toString(),
            ),
          );
        }
      }
    }
    return CategoryGroup(
      id: '${j['id'] ?? ''}',
      name: (j['name'] ?? '').toString(),
      slug: (j['slug'] ?? '').toString(),
      total: '${j['total_albums'] ?? ''}',
      subs: subs,
    );
  }
}

class PromoteSection {
  final String id;
  final String title;
  final String type;
  final String filterVal;
  final List<Comic> content;

  const PromoteSection({
    required this.id,
    required this.title,
    this.type = '',
    this.filterVal = '',
    this.content = const [],
  });

  factory PromoteSection.fromJm(Map<String, dynamic> j) {
    final list = <Comic>[];
    final raw = j['content'];
    if (raw is List) {
      for (final c in raw) {
        if (c is Map) list.add(Comic.fromJm(Map<String, dynamic>.from(c)));
      }
    }
    return PromoteSection(
      id: '${j['id'] ?? ''}',
      title: (j['title'] ?? '').toString(),
      type: (j['type'] ?? '').toString(),
      filterVal: '${j['filter_val'] ?? ''}',
      content: list,
    );
  }
}

class WeekCategory {
  final String id;
  final String title;
  final String time;
  const WeekCategory(this.id, this.title, this.time);
}
