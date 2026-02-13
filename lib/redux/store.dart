import 'package:redux/redux.dart';
import 'package:redux_thunk/redux_thunk.dart';

import 'app_state.dart';
import 'reducers.dart';

/// Create the application Redux store.
Store<AppState> createAppStore() {
  return Store<AppState>(
    appReducer,
    initialState: const AppState(),
    middleware: [thunkMiddleware],
  );
}
