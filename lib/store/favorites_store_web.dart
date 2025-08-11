import 'dart:convert';
import 'package:web/web.dart' as web;

class FavoritesStore {
  static const _favKey = 'favorite_cameras';
  static const _favOnlyKey = 'favorite_cameras_only';

  static const _workKey = 'working_cameras';
  static const _workOnlyKey = 'working_cameras_only';

  static const _maxAge = 31536000;

  Future<Set<String>> loadFavorites() async {
    final raw = _readCookie(_favKey) ?? _readLocal(_favKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final list = (jsonDecode(raw) as List).cast<String>();
      return list.toSet();
    } catch (_) {
      return raw.split('|').where((e) => e.isNotEmpty).toSet();
    }
  }

  Future<void> saveFavorites(Set<String> ids) async {
    final payload = jsonEncode(ids.toList()..sort());
    _writeCookie(_favKey, payload, maxAge: _maxAge);
    _writeLocal(_favKey, payload);
  }

  Future<bool> loadFavoritesOnly() async {
    final raw = _readCookie(_favOnlyKey) ?? _readLocal(_favOnlyKey);
    if (raw == null) return false;
    return raw == '1' || raw.toLowerCase() == 'true';
  }

  Future<void> saveFavoritesOnly(bool value) async {
    final v = value ? '1' : '0';
    _writeCookie(_favOnlyKey, v, maxAge: _maxAge);
    _writeLocal(_favOnlyKey, v);
  }

  Future<Set<String>> loadWorking() async {
    final raw = _readCookie(_workKey) ?? _readLocal(_workKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final list = (jsonDecode(raw) as List).cast<String>();
      return list.toSet();
    } catch (_) {
      return raw.split('|').where((e) => e.isNotEmpty).toSet();
    }
  }

  Future<void> saveWorking(Set<String> ids) async {
    final payload = jsonEncode(ids.toList()..sort());
    _writeCookie(_workKey, payload, maxAge: _maxAge);
    _writeLocal(_workKey, payload);
  }

  Future<bool> loadWorkingOnly() async {
    final raw = _readCookie(_workOnlyKey) ?? _readLocal(_workOnlyKey);
    if (raw == null) return false;
    return raw == '1' || raw.toLowerCase() == 'true';
  }

  Future<void> saveWorkingOnly(bool value) async {
    final v = value ? '1' : '0';
    _writeCookie(_workOnlyKey, v, maxAge: _maxAge);
    _writeLocal(_workOnlyKey, v);
  }

  String? _readCookie(String name) {
    final cookie = web.document.cookie;
    if (cookie.isEmpty) return null;
    for (final part in cookie.split('; ')) {
      if (part.startsWith('$name=')) {
        return Uri.decodeComponent(part.substring(name.length + 1));
      }
    }
    return null;
  }

  void _writeCookie(String name, String value, {int? maxAge}) {
    final attrs = <String>['path=/', if (maxAge != null) 'Max-Age=$maxAge'];
    web.document.cookie =
        '$name=${Uri.encodeComponent(value)}; ${attrs.join('; ')}';
  }

  String? _readLocal(String key) => web.window.localStorage.getItem(key);

  void _writeLocal(String key, String value) {
    web.window.localStorage.setItem(key, value);
  }
}
