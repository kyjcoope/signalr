import 'package:shared_preferences/shared_preferences.dart';

/// Persistent storage for favorites and filter toggles.
class FavoritesStore {
  static const _favKey = 'favorite_cameras';
  static const _favOnlyKey = 'favorite_cameras_only';
  static const _workOnlyKey = 'working_cameras_only';
  static const _pendingOnlyKey = 'pending_cameras_only';

  /// Cached SharedPreferences instance.
  static SharedPreferences? _prefs;

  /// Get or initialize the SharedPreferences instance.
  Future<SharedPreferences> get _instance async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<Set<String>> loadFavorites() async {
    final prefs = await _instance;
    return prefs.getStringList(_favKey)?.toSet() ?? {};
  }

  Future<void> saveFavorites(Set<String> ids) async {
    final prefs = await _instance;
    await prefs.setStringList(_favKey, ids.toList()..sort());
  }

  Future<bool> loadFavoritesOnly() async {
    final prefs = await _instance;
    return prefs.getBool(_favOnlyKey) ?? false;
  }

  Future<void> saveFavoritesOnly(bool value) async {
    final prefs = await _instance;
    await prefs.setBool(_favOnlyKey, value);
  }

  Future<bool> loadWorkingOnly() async {
    final prefs = await _instance;
    return prefs.getBool(_workOnlyKey) ?? false;
  }

  Future<void> saveWorkingOnly(bool value) async {
    final prefs = await _instance;
    await prefs.setBool(_workOnlyKey, value);
  }

  Future<bool> loadPendingOnly() async {
    final prefs = await _instance;
    return prefs.getBool(_pendingOnlyKey) ?? false;
  }

  Future<void> savePendingOnly(bool value) async {
    final prefs = await _instance;
    await prefs.setBool(_pendingOnlyKey, value);
  }
}
