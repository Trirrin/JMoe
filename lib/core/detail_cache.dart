class DetailCache {
  DetailCache._();
  static final DetailCache instance = DetailCache._();

  static const Duration ttl = Duration(seconds: 30);

  final _data = <String, _Entry>{};

  void put(String key, Object value) {
    _data[key] = _Entry(value, DateTime.now());
  }

  T? get<T>(String key) {
    final e = _data[key];
    if (e == null) return null;
    if (DateTime.now().difference(e.at) > ttl) {
      _data.remove(key);
      return null;
    }
    return e.value as T?;
  }

  void touch(String key) {
    final e = _data[key];
    if (e == null) return;
    _data[key] = _Entry(e.value, DateTime.now());
  }

  void invalidate(String key) => _data.remove(key);

  void clear() => _data.clear();

  void prune() {
    final now = DateTime.now();
    _data.removeWhere((_, e) => now.difference(e.at) > ttl);
  }
}

class _Entry {
  _Entry(this.value, this.at);
  final Object value;
  final DateTime at;
}
