// lib\webrtc\webrtc_camera_session.dart

import 'dart:async';
import 'dart:developer' as dev;

import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:signalr/signalr/signalr_session_hub.dart';
import 'package:universal_io/io.dart';

import '../signalr/signalr_message.dart';
import '../webrtc/signaling_message.dart';

class WebRtcCameraSession {
  WebRtcCameraSession({required this.cameraId, required this.sessionHub});

  final String cameraId;
  final SignalRSessionHub sessionHub;

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  String? sessionId;
  String? _offerSdp; // Stores the original offer for sdpMid correction

  // Buffers and flags to solve signaling race conditions
  final List<RTCIceCandidate> _localCandidateBuffer = [];
  final List<RTCIceCandidate> _remoteCandidateBuffer = [];
  bool _isAnswerSent = false;
  bool _isRemoteDescriptionSet = false;

  final StreamController<String> _messageController =
      StreamController<String>.broadcast();

  // Callbacks
  VoidCallback? onConnectionComplete;
  VoidCallback? onDataChannelReady;
  void Function(RTCTrackEvent event)? onTrack;
  void Function(Uint8List)? onDataFrame;

  Stream<String> get messageStream => _messageController.stream;

  Future<void> initializeConnection() async {
    if (_peerConnection != null) return;
    _isAnswerSent = false;
    _isRemoteDescriptionSet = false;
    _localCandidateBuffer.clear();
    _remoteCandidateBuffer.clear();

    final defaultIceServers = [
      {'urls': 'stun:stun.l.google.com:19302'},
      ...sessionHub.iceServers.map((e) => e.toJson()),
    ];

    final config = <String, dynamic>{
      'iceServers': defaultIceServers,
      'iceTransportPolicy': 'all',
      'rtcpMuxPolicy': 'require',
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-compat',
    };

    dev.log('[$cameraId] Initializing WebRTC peer connection with max-compat.');
    var pc = await createPeerConnection(config);

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

  void handleConnectResponse(ConnectResponse msg) {
    sessionId = msg.session;
    dev.log('[$cameraId] Session started: $sessionId');
    initializeConnection();
  }

  Future<void> handleInvite(InviteResponse msg) async {
    if (msg.offer.type == 'offer') {
      _offerSdp = msg.offer.sdp;
      await _negotiate(msg);
    }
  }

  Future<void> _negotiate(InviteResponse msg) async {
    final offerSdp = mungeSdp(msg.offer.sdp);
    final remoteDesc = RTCSessionDescription(offerSdp, msg.offer.type);

    try {
      dev.log('[$cameraId] Setting remote description...');
      await _peerConnection!.setRemoteDescription(remoteDesc);
      dev.log('[$cameraId] Set remote description successfully.');

      _isRemoteDescriptionSet = true;
      dev.log(
        '[$cameraId] Draining ${_remoteCandidateBuffer.length} buffered remote candidates.',
      );
      for (final candidate in _remoteCandidateBuffer) {
        await _peerConnection!.addCandidate(candidate);
      }
      _remoteCandidateBuffer.clear();
    } catch (e) {
      dev.log('[$cameraId] ❌ ERROR setting remote description: $e');
      return;
    }

    var answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);

    await sessionHub.signalingHandler.sendInviteAnswer(
      InviteAnswerMessage(
        session: msg.session,
        answerSdp: SdpWrapper(type: answer.type ?? '', sdp: answer.sdp ?? ''),
        id: msg.id,
      ),
    );

    _isAnswerSent = true;
    for (final candidate in _localCandidateBuffer) {
      _sendTrickle(candidate);
    }
    _localCandidateBuffer.clear();
  }

  Future<void> handleTrickle(TrickleMessage msg) async {
    if (_peerConnection == null || (msg.candidate.candidate ?? '').isEmpty) {
      return;
    }

    RTCIceCandidate candidate = msg.candidate;

    if ((candidate.sdpMid ?? '').isEmpty &&
        candidate.sdpMLineIndex != null &&
        _offerSdp != null) {
      final derivedSdpMid = _getMidForMlineIndex(
        _offerSdp!,
        candidate.sdpMLineIndex!,
      );
      if (derivedSdpMid != null) {
        candidate = RTCIceCandidate(
          candidate.candidate!,
          derivedSdpMid,
          candidate.sdpMLineIndex,
        );
      }
    }

    if (_isRemoteDescriptionSet) {
      try {
        await _peerConnection!.addCandidate(candidate);
      } catch (e) {
        dev.log('[$cameraId] ⚠️ Error adding remote ICE candidate: $e.');
      }
    } else {
      dev.log(
        '[$cameraId] Remote description not set yet. Buffering remote ICE candidate.',
      );
      _remoteCandidateBuffer.add(candidate);
    }
  }

  void _onIceCandidate(RTCIceCandidate candidate) {
    if (candidate.candidate == null) {
      dev.log('[$cameraId] End of local ICE candidates.');
      return;
    }
    // Buffer local candidates to enforce signaling order.
    if (_isAnswerSent) {
      _sendTrickle(candidate);
    } else {
      _localCandidateBuffer.add(candidate);
    }
  }

  void _sendTrickle(RTCIceCandidate candidate) {
    if (sessionId != null) {
      sessionHub.signalingHandler.sendTrickle(
        TrickleMessage(session: sessionId!, candidate: candidate, id: '4'),
      );
    }
  }

  String? _getMidForMlineIndex(String sdp, int mlineIndex) {
    final lines = sdp.split(RegExp(r'\r\n|\n'));
    int currentMline = -1;
    String? currentMid;
    for (final line in lines) {
      if (line.startsWith('m=')) {
        currentMline++;
        currentMid = null;
      }
      if (line.startsWith('a=mid:')) {
        currentMid = line.substring(6).trim();
      }
      if (currentMline == mlineIndex && currentMid != null) {
        return currentMid;
      }
    }
    return null;
  }

  void _onTrack(RTCTrackEvent event) {
    dev.log(
      '[$cameraId] Raw onTrack event received for track: ${event.track.kind}',
    );
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

  bool _isH264(String sdp) =>
      RegExp(r'\bH264/90000\b', caseSensitive: false).hasMatch(sdp);

  String mungeSdp(String sdp) {
    const iosAllowed = {'640c2a', '42e02a', '42e01f'};
    final defaultId = Platform.isIOS ? '42e02a' : '42e01f';

    // Fix profile‑level‑id
    sdp = sdp.replaceAllMapped(RegExp(r'profile-level-id=([0-9A-Fa-f]{6})'), (
      m,
    ) {
      final id = m[1]!.toLowerCase();
      final goodId = Platform.isIOS
          ? (iosAllowed.contains(id) ? id : defaultId)
          : defaultId; // always 42e01f on Android
      return 'profile-level-id=$goodId';
    });

    // Ensure level‑asymmetry‑allowed=1
    if (!sdp.toLowerCase().contains('level-asymmetry-allowed')) {
      sdp = sdp.replaceFirst(
        'packetization-mode=1;',
        'level-asymmetry-allowed=1;packetization-mode=1;',
      );
    }

    return sdp;
  }
}
