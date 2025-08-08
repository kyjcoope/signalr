import 'package:flutter/material.dart';
import 'package:signalr/demo/webrtc_display.dart';

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SignalR WebRTC Demo')),
      body: const WebRtcDisplay(), // Always show the display
    );
  }
}
