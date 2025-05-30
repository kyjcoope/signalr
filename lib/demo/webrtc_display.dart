import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:signalr/signalr/signalr_consumer_session.dart';

class WebRtcDisplay extends StatefulWidget {
  const WebRtcDisplay({super.key});

  @override
  State<StatefulWidget> createState() => _WebRtcDisplay();
}

class _WebRtcDisplay extends State<WebRtcDisplay> {
  final SignalRConsumerSession session = SignalRConsumerSession(
    signalRUrl: 'https://jci-osp-api-gateway-dev.osp-jci.com/SignalingHub',
  );
  final RTCVideoRenderer renderer = RTCVideoRenderer();

  String camId = 'nvr-victoriaproxmox-1';
  // String camId = 'Simon-VMS-Camera-v1';
  String updateId = '';

  @override
  void initState() {
    super.initState();
    _initSession();
  }

  @override
  void dispose() {
    session.shutdown();
    renderer.srcObject = null;
    renderer.dispose();
    super.dispose();
  }

  void _initSession() async {
    await renderer.initialize();
    session.onTrack = _onTrack;
    session.onRegister = () async {
      // print('onRegister ${session.producers.last}');
      session.addDesiredPeer(camId);
    };
    session.onSessionStarted = (s, camId) {
      print('onSessionStarted');
      session.initLocalConnection();
    };
    await session.setupLocalTrack();
    await session.signalingHandler.setupSignaling();
  }

  void _onTrack(RTCTrackEvent event) {
    if (event.track.kind == 'video') {
      print('trackmessage ${event.track.id} :: ${event.streams[0].id}');
      renderer.srcObject = event.streams[0];
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(
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
}
