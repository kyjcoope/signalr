import 'package:shared_preferences/shared_preferences.dart';

class FavoritesStore {
  static const _favKey = 'favorite_cameras';
  static const _favOnlyKey = 'favorite_cameras_only';

  static const _workKey = 'working_cameras';
  static const _workOnlyKey = 'working_cameras_only';

  static const _pendingOnlyKey = 'pending_cameras_only';

  Future<Set<String>> loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_favKey) ?? const <String>[];
    return list.toSet();
  }

  Future<void> saveFavorites(Set<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_favKey, ids.toList()..sort());
  }

  Future<bool> loadFavoritesOnly() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_favOnlyKey) ?? false;
  }

  Future<void> saveFavoritesOnly(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_favOnlyKey, value);
  }

  Future<Set<String>> loadWorking() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_workKey) ?? const <String>[];
    return list.toSet();
  }

  Future<void> saveWorking(Set<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_workKey, ids.toList()..sort());
  }

  Future<bool> loadWorkingOnly() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_workOnlyKey) ?? false;
  }

  Future<void> saveWorkingOnly(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_workOnlyKey, value);
  }

  Future<bool> loadPendingOnly() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_pendingOnlyKey) ?? false;
  }

  Future<void> savePendingOnly(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_pendingOnlyKey, value);
  }
}
