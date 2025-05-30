import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:signalr/signalr/signalr_consumer_session.dart';

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
  final camId = 'nvr-victoriaproxmox-1';

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
    if (e.track.kind == 'video') renderer.srcObject = e.streams.first;
    setState(() => {});
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
