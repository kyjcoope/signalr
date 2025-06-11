import 'package:flutter/material.dart';
import 'package:flutter_redux/flutter_redux.dart';
import 'package:signalr/redux/state.dart';

import '../camera/redux/thunks.dart';
import 'webrtc_display.dart';

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final store = StoreProvider.of<AppState>(context);
      store.dispatch(
        initializeSignalRThunk(
          'https://jci-osp-api-gateway-dev.osp-jci.com/SignalingHub',
        ),
      );
    });
  }

  @override
  void dispose() {
    final store = StoreProvider.of<AppState>(context);
    store.dispatch(disposeSignalRThunk());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SignalR WebRTC Demo')),
      body: const WebRtcDisplay(),
    );
  }
}
