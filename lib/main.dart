import 'package:flutter/material.dart';
import 'package:flutter_redux/flutter_redux.dart';
import 'package:redux/redux.dart';
import 'package:redux_thunk/redux_thunk.dart';
import 'package:signalr/camera/redux/state.dart';
import 'package:signalr/redux/reducer.dart';
import 'package:signalr/redux/state.dart';

import 'demo/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final store = Store<AppState>(
    appReducer,
    initialState: const AppState(cameraState: CameraState()),
    middleware: [thunkMiddleware],
  );

  runApp(
    MaterialApp(
      home: StoreProvider<AppState>(store: store, child: const App()),
    ),
  );
}
