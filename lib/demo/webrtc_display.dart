import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:signalr/signalr/signalr_consumer_session.dart';

import 'dart:developer' as dev;

class WebRtcDisplay extends StatefulWidget {
  const WebRtcDisplay({super.key});
  @override
  State<WebRtcDisplay> createState() => _WebRtcDisplay();
}

class _WebRtcDisplay extends State<WebRtcDisplay> {
  final session = SignalRConsumerSession(
    signalRUrl: 'https://jci-osp-api-gateway-dev.osp-jci.com/SignalingHub',
  );
  final renderer = RTCVideoRenderer();
  final camId = 'NVR-PG-1VMS-1054-2';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    session.shutdown();
    renderer.dispose();
    super.dispose();
  }

  void _boot() async {
    await renderer.initialize();
    session.onTrack = _onTrack;
    session.onRegister = () => session.addDesiredPeer(camId);
    session.onSessionStarted = (s, _) => session.initLocalConnection();
    await session.signalingHandler.setupSignaling();
  }

  void _onTrack(RTCTrackEvent e) {
    dev.log('Track event: ${e.track.kind} from ${e.streams.first.id}');
    if (e.track.kind == 'video') {
      dev.log('Setting video track to renderer');
      setState(() {
        renderer.srcObject = e.streams.first;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Flexible(child: Text('Current peer is $camId')),
      Flexible(
        child: Container(
          color: Colors.black,
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: RTCVideoView(renderer),
          ),
        ),
      ),
    ],
  );
}
