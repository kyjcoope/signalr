import 'package:flutter/material.dart';
import 'package:signalr/demo/webrtc_display.dart';

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  bool showDisplay = false;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Flutter WebRTC Example')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('webrtc client'),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  showDisplay = !showDisplay;
                });
              },
              child: Text(showDisplay ? 'Hide Display' : 'Show Display'),
            ),
            if (showDisplay) Flexible(child: WebRtcDisplay()),
          ],
        ),
      ),
    );
  }
}
