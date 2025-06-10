import 'dart:async';
import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:signalr/signalr/signalr_session_hub.dart';

import '../signalr/signalr_message.dart';
import '../webrtc/signaling_message.dart';

class WebRtcCameraSession {
  WebRtcCameraSession({required this.cameraId, required this.sessionHub});

  final String cameraId;
  final SignalRSessionHub sessionHub;

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  String? sessionId;

  final StreamController<String> _messageController =
      StreamController<String>.broadcast();

  // Callbacks
  VoidCallback? onConnectionComplete;
  VoidCallback? onDataChannelReady;
  void Function(RTCTrackEvent)? onTrack;
  void Function(Uint8List)? onDataFrame;

  Stream<String> get messageStream => _messageController.stream;

  Future<void> initializeConnection() async {
    if (_peerConnection != null) return;

    final defaultIceServers = [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
      {'urls': 'stun:stun3.l.google.com:19302'},
      {'urls': 'stun:stun4.l.google.com:19302'},
      ...sessionHub.iceServers.map((e) => e.toJson()),
    ];

    final config = <String, dynamic>{
      'iceServers': defaultIceServers,
      'iceTransportPolicy': 'all',
      'iceCandidatePoolSize': 0,
      'rtcpMuxPolicy': 'require',
      'sdpSemantics': 'unified-plan',
    };

    dev.log('[$cameraId] Initializing WebRTC peer connection');
    var pc = await createPeerConnection(config);

    // Set up event handlers
    pc.onTrack = _onTrack;
    pc.onIceConnectionState = _onIceConnectionState;
    pc.onConnectionState = _onConnectionState;
    pc.onIceCandidate = _onIceCandidate;
    pc.onDataChannel = _onDataChannel;

    _peerConnection = pc;
  }

  void dispose() {
    _dataChannel?.close();
    _peerConnection?.close();
    _messageController.close();
    dev.log('[$cameraId] Session disposed');
  }

  void sendDataChannelMessage(String text) {
    if (_dataChannel == null) return;
    dev.log('[$cameraId] Sending data channel message: $text');
    _dataChannel!.send(RTCDataChannelMessage(text));
  }

  void handleConnectResponse(ConnectResponse msg) {
    sessionId = msg.session;
    dev.log('[$cameraId] Session started: $sessionId');
    initializeConnection();
  }

  Future<void> handleInvite(InviteResponse msg) async {
    if (msg.offer.type == 'offer') {
      await _negotiate(msg);
    }
  }

  Future<void> handleTrickle(TrickleMessage msg) async {
    if (_peerConnection == null || (msg.candidate.candidate ?? '').isEmpty) {
      dev.log('[$cameraId] Cannot handle trickle - connection not ready');
      return;
    }

    dev.log('[$cameraId] Received remote ICE candidate');
    try {
      var ice = RTCIceCandidate(
        msg.candidate.candidate,
        msg.candidate.sdpMid,
        msg.candidate.sdpMLineIndex,
      );
      await _peerConnection!.addCandidate(ice);
    } catch (e) {
      dev.log('[$cameraId] Error adding remote ICE candidate: $e');
    }
  }

  Future<void> _negotiate(InviteResponse msg) async {
    final oaConstraints = <String, dynamic>{
      'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': true},
      'optional': [
        {'DtlsSrtpKeyAgreement': true},
      ],
    };

    final String remoteSdp = msg.offer.sdp;
    final String fixedSdp = remoteSdp.replaceAllMapped(
      RegExp(r'profile-level-id=([a-fA-F0-9]+)', caseSensitive: false),
      (match) {
        final currentValue = match.group(1)?.toLowerCase();
        if (currentValue == '42e01f') {
          return match.group(0)!;
        } else {
          dev.log(
            '[$cameraId] Replacing profile-level-id=$currentValue with 42e01f',
          );
          return 'profile-level-id=42e01f';
        }
      },
    );

    final remoteDesc = RTCSessionDescription(fixedSdp, msg.offer.type);
    dev.log('[$cameraId] Setting remote description');
    await _peerConnection!.setRemoteDescription(remoteDesc);

    dev.log('[$cameraId] Creating answer');
    var answer = await _peerConnection!.createAnswer(oaConstraints);

    dev.log('[$cameraId] Setting local description');
    await _peerConnection!.setLocalDescription(answer);

    await sessionHub.signalingHandler.sendInviteAnswer(
      InviteAnswerMessage(
        session: msg.session,
        answerSdp: SdpWrapper(type: answer.type ?? '', sdp: answer.sdp ?? ''),
        id: msg.id,
      ),
    );
  }

  void _onTrack(RTCTrackEvent event) {
    dev.log('[$cameraId] Track received: ${event.track.kind}');
    onTrack?.call(event);
  }

  void _onIceConnectionState(RTCIceConnectionState state) {
    dev.log('[$cameraId] ICE connection state: $state');
    if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
      dev.log('[$cameraId] 🎉 ICE CONNECTION ESTABLISHED!');
    } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
      dev.log('[$cameraId] ❌ ICE CONNECTION FAILED');
    }
  }

  void _onConnectionState(RTCPeerConnectionState state) {
    dev.log('[$cameraId] Peer connection state: $state');
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      dev.log('[$cameraId] 🎉 PEER CONNECTION ESTABLISHED!');
      onConnectionComplete?.call();
    }
  }

  void _onIceCandidate(RTCIceCandidate candidate) {
    dev.log('[$cameraId] Local ICE candidate generated');
    if (sessionId != null) {
      sessionHub.signalingHandler.sendTrickle(
        TrickleMessage(session: sessionId!, candidate: candidate, id: '4'),
      );
    }
  }

  void _onDataChannel(RTCDataChannel channel) {
    dev.log('[$cameraId] Data channel opened: ${channel.label}');
    _dataChannel = channel;
    _dataChannel!.onMessage = _onDataChannelMessage;
    _dataChannel!.onDataChannelState = _onDataChannelState;
  }

  void _onDataChannelState(RTCDataChannelState state) {
    dev.log('[$cameraId] Data channel state: $state');
    if (state == RTCDataChannelState.RTCDataChannelOpen) {
      onDataChannelReady?.call();
    }
  }

  void _onDataChannelMessage(RTCDataChannelMessage msg) {
    dev.log('[$cameraId] Data channel message: ${msg.text}');
    if (msg.isBinary) {
      onDataFrame?.call(Uint8List.fromList(msg.binary));
    } else {
      _messageController.add(msg.text);
    }
  }
}
