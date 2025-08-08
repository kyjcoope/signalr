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

  // ICE-gating & queue for remote trickle
  bool _remoteDescSet = false;
  final List<Map<String, dynamic>> _pendingRemoteIce = [];

  // used to await ICE gathering when creating answer
  Completer<void> iceCandidatesGathering = Completer<void>();

  Stream<String> get messageStream => _messageController.stream;

  Future<void> initializeConnection() async {
    if (_peerConnection != null) return;

    final defaultIceServers = [
      // {'urls': 'stun:stun.l.google.com:19302'},
      // {'urls': 'stun:stun1.l.google.com:19302'},
      // {'urls': 'stun:stun2.l.google.com:19302'},
      // {'urls': 'stun:stun3.l.google.com:19302'},
      // {'urls': 'stun:stun4.l.google.com:19302'},
      ...sessionHub.iceServers.map((e) => e.toJson()),
    ];

    final config = <String, dynamic>{
      'iceServers': defaultIceServers,
      'iceTransportPolicy': 'all',
      'iceCandidatePoolSize': 0,
      'rtcpMuxPolicy': 'require',
      'sdpSemantics': 'unified-plan',
      // 'bundlePolicy': 'max-bundle',
    };

    dev.log('[$cameraId] Initializing WebRTC peer connection');
    final pc = await createPeerConnection(config);

    pc.onTrack = _onTrack;
    pc.onIceConnectionState = _onIceConnectionState;
    pc.onConnectionState = _onConnectionState;
    pc.onDataChannel = _onDataChannel;

    // Trickle local candidates (WITHOUT usernameFragment)
    pc.onIceCandidate = _onIceCandidate;

    // Send End-Of-Candidates when gathering completes & unlock gathering gate
    pc.onIceGatheringState = (state) async {
      dev.log('[$cameraId] ICE gathering state: $state');
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        // Send one empty candidate per MID
        try {
          final txs = await pc.getTransceivers();
          for (final t in txs) {
            final mid = t.mid;
            if (mid.isNotEmpty) {
              _sendEndOfCandidates(mid);
            }
          }
        } catch (_) {
          // No transceivers - best-effort: try common mids
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

  // ---------- Public handlers from your signaling layer ----------

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
    final pc = _peerConnection;
    if (pc == null) {
      dev.log('[$cameraId] No peer connection; queueing remote ICE');
      _pendingRemoteIce.add({
        'candidate': msg.candidate.candidate ?? '',
        'sdpMid': msg.candidate.sdpMid,
        'sdpMLineIndex': msg.candidate.sdpMLineIndex,
      });
      return;
    }

    // Build a loose map so we can normalize + gate on SRD
    final raw = <String, dynamic>{
      'candidate': msg.candidate.candidate ?? '',
      'sdpMid': msg.candidate.sdpMid,
      'sdpMLineIndex': msg.candidate.sdpMLineIndex,
    };

    // Always wait for SRD; queue until then
    if (!_remoteDescSet) {
      dev.log('[$cameraId] SRD not set yet; queueing remote ICE');
      _pendingRemoteIce.add(raw);
      return;
    }

    // Normalize (map mlineIndex -> mid if needed). Ignore remote EOC (empty).
    final norm = await _normalizeRemoteCandidate(pc, raw);
    if (norm == null) {
      dev.log('[$cameraId] Remote End-Of-Candidates received');
      return;
    }

    try {
      await pc.addCandidate(
        RTCIceCandidate(
          norm['candidate'],
          norm['sdpMid'],
          norm['sdpMLineIndex'],
        ),
      );
      dev.log('[$cameraId] Added remote ICE candidate (mid=${norm['sdpMid']})');
    } catch (e) {
      dev.log('[$cameraId] Error adding remote ICE candidate: $e');
    }
  }

  // ---------- Negotiation ----------

  Future<void> _negotiate(InviteResponse msg) async {
    iceCandidatesGathering = Completer<void>();

    final oaConstraints = <String, dynamic>{
      'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': true},
      'optional': [
        {'DtlsSrtpKeyAgreement': true},
      ],
    };

    // If H264 present, munge SDP for mobile compatibility
    final offerSdp = _isH264(msg.offer.sdp)
        ? mungeSdp(msg.offer.sdp)
        : msg.offer.sdp;

    final pc = _peerConnection!;
    final remoteDesc = RTCSessionDescription(offerSdp, msg.offer.type);

    // SRD FIRST
    await pc.setRemoteDescription(remoteDesc);
    _remoteDescSet = true;

    // Drain any queued remote ICE now that SRD is done
    await _drainQueuedRemoteIce(pc);

    // Create/set answer
    final answer = await pc.createAnswer(oaConstraints);
    await pc.setLocalDescription(answer);

    // Wait briefly for gathering to complete to include all host/srflx/relay
    final timeout = Future.delayed(const Duration(seconds: 7));
    await Future.any([iceCandidatesGathering.future, timeout]);
    final finalAnswer = await pc.getLocalDescription();

    await sessionHub.signalingHandler.sendInviteAnswer(
      InviteAnswerMessage(
        session: msg.session,
        answerSdp: SdpWrapper(type: finalAnswer!.type!, sdp: finalAnswer.sdp!),
        id: msg.id,
      ),
    );
  }

  Future<void> _drainQueuedRemoteIce(RTCPeerConnection pc) async {
    if (_pendingRemoteIce.isEmpty) return;
    dev.log(
      '[$cameraId] Draining ${_pendingRemoteIce.length} queued remote ICE',
    );
    while (_pendingRemoteIce.isNotEmpty) {
      final raw = _pendingRemoteIce.removeAt(0);
      final norm = await _normalizeRemoteCandidate(pc, raw);
      if (norm == null) continue; // remote EOC
      try {
        await pc.addCandidate(
          RTCIceCandidate(
            norm['candidate'],
            norm['sdpMid'],
            norm['sdpMLineIndex'],
          ),
        );
      } catch (e) {
        dev.log('[$cameraId] Error adding queued ICE: $e');
      }
    }
  }

  // ---------- Local side events ----------

  void _onTrack(RTCTrackEvent event) {
    dev.log('[$cameraId] Track received: ${event.track.kind}');
    onTrack?.call(event);
  }

  void _onIceConnectionState(RTCIceConnectionState state) {
    dev.log('[$cameraId] ICE connection state: $state');
    if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
      dev.log('[$cameraId] ðŸŽ‰ ICE CONNECTION ESTABLISHED!');
    } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
      dev.log('[$cameraId] ❌ ICE CONNECTION FAILED');
    }
  }

  void _onConnectionState(RTCPeerConnectionState state) {
    dev.log('[$cameraId] Peer connection state: $state');
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      dev.log('[$cameraId] ðŸŽ‰ PEER CONNECTION ESTABLISHED!');
      onConnectionComplete?.call();
    }
  }

  void _onIceCandidate(RTCIceCandidate candidate) {
    dev.log('[$cameraId] Local ICE candidate generated');

    // End-of-candidates from the browser (empty candidate) is ignored here
    if (candidate.candidate == null || candidate.candidate!.isEmpty) {
      dev.log(
        '[$cameraId] ✅ Local end-of-candidates signal (ignored here; explicit EOC sent on gathering complete)',
      );
      return;
    }

    // Re-wrap to ensure NO usernameFragment is sent over the wire
    final sanitized = RTCIceCandidate(
      candidate.candidate,
      candidate.sdpMid,
      candidate.sdpMLineIndex,
    );

    if (sessionId != null) {
      sessionHub.signalingHandler.sendTrickle(
        TrickleMessage(session: sessionId!, candidate: sanitized, id: '4'),
      );
    }
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

  // ---------- ICE Candidate normalization (mlineIndex -> mid) ----------

  Future<Map<String, dynamic>?> _normalizeRemoteCandidate(
    RTCPeerConnection pc,
    Map<String, dynamic> c,
  ) async {
    final cand = (c['candidate'] ?? '') as String;
    if (cand.isEmpty) {
      // Remote End-Of-Candidates; nothing to add.
      return null;
    }

    String? sdpMid = (c['sdpMid'] as String?)?.trim();
    int? sdpMLineIndex = c['sdpMLineIndex'] is int
        ? c['sdpMLineIndex'] as int
        : null;

    if ((sdpMid == null || sdpMid.isEmpty) && sdpMLineIndex != null) {
      // Try transceivers first
      try {
        final txs = await pc.getTransceivers();
        if (sdpMLineIndex >= 0 && sdpMLineIndex < txs.length) {
          final mid = txs[sdpMLineIndex].mid;
          if (mid.isNotEmpty) sdpMid = mid;
        }
      } catch (_) {
        // fall through to SDP parse
      }

      // Fallback: parse mids from the *remote* SDP
      if ((sdpMid == null || sdpMid.isEmpty)) {
        final desc = await pc.getRemoteDescription();
        final sdp = desc?.sdp ?? '';
        if (sdp.isNotEmpty) {
          final sections = sdp.split('\r\nm=');
          final midExp = RegExp(r'^a=mid:(.+)$', multiLine: true);
          final mids = <String>[];
          for (final sec in sections) {
            final m = midExp.firstMatch(sec);
            if (m != null) mids.add(m.group(1)!);
          }
          if (sdpMLineIndex >= 0 && sdpMLineIndex < mids.length) {
            sdpMid = mids[sdpMLineIndex];
          }
        }
      }
    }

    return {
      'candidate': cand,
      'sdpMid': sdpMid,
      'sdpMLineIndex': sdpMLineIndex,
    };
  }

  // ---------- Utils ----------

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

  bool _isH264(String sdp) =>
      RegExp(r'\bH264/90000\b', caseSensitive: false).hasMatch(sdp);

  String mungeSdp(String sdp) {
    const iosAllowed = {'640c2a', '42e02a', '42e01f'};
    final defaultId = Platform.isIOS ? '42e02a' : '42e01f';

    // Fix profile-level-id
    sdp = sdp.replaceAllMapped(RegExp(r'profile-level-id=([0-9A-Fa-f]{6})'), (
      m,
    ) {
      final id = m[1]!.toLowerCase();
      final goodId = Platform.isIOS
          ? (iosAllowed.contains(id) ? id : defaultId)
          : defaultId; // always 42e01f on Android
      return 'profile-level-id=$goodId';
    });

    // Ensure level-asymmetry-allowed=1
    if (!sdp.toLowerCase().contains('level-asymmetry-allowed')) {
      sdp = sdp.replaceFirst(
        'packetization-mode=1;',
        'level-asymmetry-allowed=1;packetization-mode=1;',
      );
    }

    return sdp;
  }
}
