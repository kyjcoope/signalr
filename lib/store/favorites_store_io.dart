import 'package:shared_preferences/shared_preferences.dart';

class FavoritesStore {
  static const _favKey = 'favorite_cameras';
  static const _favOnlyKey = 'favorite_cameras_only';

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
}
