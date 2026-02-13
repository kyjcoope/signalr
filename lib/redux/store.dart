import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:redux/redux.dart';
import 'package:redux_thunk/redux_thunk.dart';
import 'package:redux_persist/redux_persist.dart';
import 'package:redux_persist_flutter/redux_persist_flutter.dart';

import 'app_state.dart';
import 'reducers.dart';

/// Create the application Redux store with persistence.
///
/// Persists cameras, favorites, and filters to local storage.
/// Session state (WebRTC) is NOT persisted — rebuilt at runtime.
Future<Store<AppState>> createAppStore() async {
  final persistor = Persistor<AppState>(
    storage: FlutterStorage(
      key: 'signalr_redux_state',
      location: FlutterSaveLocation.sharedPreferences,
    ),
    serializer: JsonSerializer<AppState>(AppState.fromJson),
    debug: true,
  );

  final initialState = await persistor.load();
  debugPrint(
    '[Store] Loaded persisted state: '
    '${initialState?.cameras.cameras.length ?? 0} cameras, '
    'isLoaded=${initialState?.cameras.isLoaded ?? false}',
  );

  // Verify serialization roundtrip
  if (initialState != null) {
    final json = initialState.toJson();
    final encoded = jsonEncode(json);
    debugPrint('[Store] Serialized state length: ${encoded.length} chars');
    final decoded = jsonDecode(encoded);
    final restored = AppState.fromJson(decoded);
    debugPrint('[Store] Roundtrip: ${restored.cameras.cameras.length} cameras');
  }

  final store = Store<AppState>(
    appReducer,
    initialState: initialState ?? const AppState(),
    middleware: [thunkMiddleware, persistor.createMiddleware()],
  );

  // Log whenever camera count changes so we know persistence should trigger
  store.onChange.listen((state) {
    debugPrint(
      '[Store] State changed: ${state.cameras.cameras.length} cameras, '
      'serverStatus=${state.auth.serverStatus}',
    );
  });

  return store;
}
