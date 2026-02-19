import 'dart:convert';
import 'package:web/web.dart' as web;

class FavoritesStore {
  static const _favKey = 'favorite_cameras';
  static const _favOnlyKey = 'favorite_cameras_only';
  static const _workOnlyKey = 'working_cameras_only';
  static const _pendingOnlyKey = 'pending_cameras_only';

  Future<Set<String>> loadFavorites() async {
    final raw = _read(_favKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final list = (jsonDecode(raw) as List).cast<String>();
      return list.toSet();
    } catch (_) {
      return raw.split('|').where((e) => e.isNotEmpty).toSet();
    }
  }

  Future<void> saveFavorites(Set<String> ids) async {
    _write(_favKey, jsonEncode(ids.toList()..sort()));
  }

  Future<bool> loadFavoritesOnly() async => _readBool(_favOnlyKey);

  Future<void> saveFavoritesOnly(bool value) async =>
      _writeBool(_favOnlyKey, value);

  Future<bool> loadWorkingOnly() async => _readBool(_workOnlyKey);

  Future<void> saveWorkingOnly(bool value) async =>
      _writeBool(_workOnlyKey, value);

  Future<bool> loadPendingOnly() async => _readBool(_pendingOnlyKey);

  Future<void> savePendingOnly(bool value) async =>
      _writeBool(_pendingOnlyKey, value);

  // ═══════════════════════════════════════════════════════════════════════════
  // Storage Helpers
  // ═══════════════════════════════════════════════════════════════════════════

  bool _readBool(String key) {
    final raw = _read(key);
    if (raw == null) return false;
    return raw == '1' || raw.toLowerCase() == 'true';
  }

  void _writeBool(String key, bool value) => _write(key, value ? '1' : '0');

  String? _read(String key) => web.window.localStorage.getItem(key);

  void _write(String key, String value) {
    web.window.localStorage.setItem(key, value);
  }
}
