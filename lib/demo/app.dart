import 'package:flutter/material.dart';
import 'package:signalr/demo/webrtc_display.dart';

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Flutter WebRTC Example')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [Text('webrtc client'), Flexible(child: WebRtcDisplay())],
        ),
      ),
    );
  }
}
