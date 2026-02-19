import 'package:flutter/material.dart';
import 'package:signalr/demo/webrtc_display.dart';

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SignalR WebRTC Demo')),
      body: const WebRtcDisplay(),
    );
  }
}
