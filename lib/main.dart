import 'dart:core';
import 'package:flutter/material.dart';
import 'package:flutter_redux/flutter_redux.dart';
import 'package:signalr/http_override.dart';
import 'package:universal_io/io.dart';

import 'demo/app.dart';
import 'redux/app_state.dart';
import 'redux/store.dart';

void main() async {
  HttpOverrides.global = DeviceHttpOverrides();
  WidgetsFlutterBinding.ensureInitialized();

  final store = createAppStore();

  runApp(
    StoreProvider<AppState>(
      store: store,
      child: MaterialApp(home: SelectionArea(child: App())),
    ),
  );
}
