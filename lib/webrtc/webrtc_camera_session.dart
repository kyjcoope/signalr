import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';
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

  final StreamController<String> _messageController =
      StreamController<String>.broadcast();

  // Callbacks
  VoidCallback? onConnectionComplete;
  VoidCallback? onDataChannelReady;
  void Function(RTCTrackEvent)? onTrack;
  void Function(Uint8List)? onDataFrame;

  bool remoteDescSet = false;
  List<TrickleMessage> pendingTrickles = [];

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
    final pc = await createPeerConnection(config);

    pc.onTrack = _onTrack;
    pc.onIceConnectionState = _onIceConnectionState;
    pc.onConnectionState = _onConnectionState;
    pc.onIceCandidate = _onIceCandidate;
    pc.onDataChannel = _onDataChannel;
    pc.onIceGatheringState = (state) async {
      dev.log('[$cameraId] ICE gathering state: $state');
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        try {
          final txs = await pc.getTransceivers();
          for (final t in txs) {
            final mid = t.mid;
            if (mid.isNotEmpty) {
              _sendEndOfCandidates(mid);
            }
          }
        } catch (_) {
          dev.log('[$cameraId] Error getting transceivers');
          for (final mid in const ['audio', 'video', 'data']) {
            _sendEndOfCandidates(mid);
          }
        }
        if (!iceCandidatesGathering.isCompleted) {
          iceCandidatesGathering.complete();
        }
      }
    };

    _peerConnection = pc;
  }

  void _sendEndOfCandidates(String mid) {
    if (sessionId == null) return;
    dev.log('[$cameraId] Sending End-Of-Candidates for mid=$mid');

    // Empty candidate + sdpMid only
    final eoc = RTCIceCandidate('', mid, null);
    sessionHub.signalingHandler.sendTrickle(
      TrickleMessage(session: sessionId!, candidate: eoc, id: 'eoc'),
    );
  }

  void dispose() {
    _dataChannel?.close();
    _peerConnection?.close();
    _messageController.close();
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

  Completer<void> iceCandidatesGathering = Completer<void>();

  Future<void> handleTrickle(TrickleMessage msg) async {
    if ((msg.candidate.candidate ?? '').isEmpty) return;
    if (_peerConnection == null || !remoteDescSet) {
      pendingTrickles.add(msg);
      return;
    }

    dev.log('[$cameraId] Received remote ICE candidate');
    try {
      await _peerConnection!.addCandidate(
        RTCIceCandidate(
          msg.candidate.candidate,
          msg.candidate.sdpMid,
          msg.candidate.sdpMLineIndex,
        ),
      );
    } catch (e) {
      dev.log('[$cameraId] Error adding remote ICE candidate: $e');
    }
  }

  Future<void> _drainQueuedRemoteIce() async {
    if (pendingTrickles.isEmpty) return;
    dev.log('[$cameraId] Draining ${pendingTrickles.length} queued remote ICE');
    while (pendingTrickles.isNotEmpty) {
      final trickle = pendingTrickles.removeAt(0);
      try {
        await _peerConnection?.addCandidate(
          RTCIceCandidate(
            trickle.candidate.candidate,
            trickle.candidate.sdpMid,
            trickle.candidate.sdpMLineIndex,
          ),
        );
      } catch (e) {
        dev.log('[$cameraId] Error adding queued ICE: $e');
      }
    }
  }

  Future<void> _negotiate(InviteResponse msg) async {
    iceCandidatesGathering = Completer<void>();
    final oaConstraints = <String, dynamic>{
      'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': true},
      'optional': [
        {'DtlsSrtpKeyAgreement': true},
      ],
    };

    // SDP munging for iOS and Android H.264 compatibility
    final offerSdp = _isH264(msg.offer.sdp)
        ? mungeSdp(msg.offer.sdp)
        : msg.offer.sdp;

    final remoteDesc = RTCSessionDescription(msg.offer.sdp, msg.offer.type);
    await _peerConnection!.setRemoteDescription(remoteDesc);
    remoteDescSet = true;

    // Drain any queued remote ICE now that SRD is done
    await _drainQueuedRemoteIce();

    final answer = await _peerConnection!.createAnswer(oaConstraints);
    await _peerConnection!.setLocalDescription(answer);

    // Android doesn't seem to get RTCIceGatheringState.RTCIceGatheringStateComplete
    // so iceCandidatesGathering is never completed. So we use a timeout
    // to ensure we don't get deadlocked.
    final timeout = Future.delayed(const Duration(seconds: 5));
    await Future.any([iceCandidatesGathering.future, timeout]);
    final finalAnswer = await _peerConnection!.getLocalDescription();

    await sessionHub.signalingHandler.sendInviteAnswer(
      InviteAnswerMessage(
        session: msg.session,
        answerSdp: SdpWrapper(type: finalAnswer!.type!, sdp: finalAnswer.sdp!),
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
    if (candidate.candidate == null || candidate.candidate!.isEmpty) {
      dev.log('[$cameraId] ✅ End of LOCAL candidates signal received.');
      if (!iceCandidatesGathering.isCompleted) {
        dev.log('[$cameraId] 🔓 Unlocking negotiation gate for local peer.');
        iceCandidatesGathering.complete();
      }
      return;
    }
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
