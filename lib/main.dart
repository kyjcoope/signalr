import 'dart:core';
import 'package:flutter/material.dart';

import 'demo/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MaterialApp(home: App()));
}
