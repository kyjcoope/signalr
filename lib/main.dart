import 'dart:core';
import 'package:flutter/material.dart';
import 'package:signalr/http_override.dart';
import 'package:universal_io/io.dart';

import 'demo/app.dart';
import 'isolate/isolate.dart';

void main() async {
  HttpOverrides.global = DeviceHttpOverrides();
  WidgetsFlutterBinding.ensureInitialized();
  await LogPrinterIsolate.start();
  runApp(MaterialApp(home: App()));
}
