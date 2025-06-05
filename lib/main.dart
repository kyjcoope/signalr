import 'dart:core';
import 'dart:io';
import 'package:flutter/material.dart';

import 'demo/app.dart';
import 'http_override.dart';

void main() {
  //HttpOverrides.global = DeviceHttpOverrides();
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MaterialApp(home: App()));
}
