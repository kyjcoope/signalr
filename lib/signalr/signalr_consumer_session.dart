import 'dart:async';
import 'dart:developer' as dev;
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:signalr/signalr/singalr_handler.dart';

import '../webrtc/i_webrtc_session.dart';
import '../webrtc/signaling_message.dart';
import 'signalr_message.dart';

const webrtcName = 'ExacqClient';

class SignalRConsumerSession implements IWebrtcSession {
  SignalRConsumerSession({
    required String signalRUrl,
    this.onRegister,
    this.onConnectionComplete,
    this.onDataChannelReady,
    this.onSessionStarted,
    this.onSessionEnded,
    this.onStreamUpdate,
    this.onTrack,
    this.onDataFrame,
  }) {
    signalingHandler = SignalRHandler(
      signalServiceUrl: signalRUrl,
      onConnect: _onConnectResponse,
      onRegister: _onRegister,
      onInvite: _onInvite,
      onTrickle: _onTrickleMessage,
    );
  }
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  late final SignalRHandler signalingHandler;
  String? _session;
  final Set<String> _producers = {};
  String? _selectedProducer;
  final Set<String> _desiredPeers = {};
  List<IceServer> iceServers = [];
  final StreamController<String> _messageController =
      StreamController<String>.broadcast();

  Set<String> get producers => _producers;
  String? get selectedProducer => _selectedProducer;
  @override
  Stream<String> get messageStream => _messageController.stream;

  VoidCallback? onRegister;
  VoidCallback? onConnectionComplete;
  VoidCallback? onDataChannelReady;
  void Function(String, String)? onSessionStarted;
  VoidCallback? onSessionEnded;
  VoidCallback? onStreamUpdate;
  void Function(RTCTrackEvent)? onTrack;
  void Function(Uint8List)? onDataFrame;

  void shutdown() {
    _dataChannel?.close();
    _peerConnection?.close();
    signalingHandler.shutdown([_session ?? '']);
    _desiredPeers.clear();
    _producers.clear();
    _session = null;
    _selectedProducer = null;
  }

  void addDesiredPeer(String peer) {
    if (_desiredPeers.contains(peer)) return;
    _desiredPeers.add(peer);
    _initNeededConnections();
  }

  void removeDesiredPeer(String peer) {
    _desiredPeers.remove(peer);
    _removeConnection(peer);
  }

  Future<void> initLocalConnection() async {
    if (_peerConnection != null) return;
    final defaultIceServers = [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
      ...iceServers.map((e) => e.toJson()),
    ];

    final config = <String, dynamic>{
      'iceServers': defaultIceServers,
      'iceTransportPolicy': 'all',
      'iceCandidatePoolSize': 0,
      'rtcpMuxPolicy': 'require',
      'sdpSemantics': 'unified-plan',
    };

    dev.log('Initializing WebRTC peer connection: $config');
    var pc = await createPeerConnection(config);

    // attach callbacks
    pc.onTrack = _onTrack;
    pc.onSignalingState = (state) async {
      var state2 = await pc.getSignalingState();
      dev.log('remote pc: onSignalingState($state), state2($state2)');
    };
    pc.onIceGatheringState = (state) async {
      var state2 = await pc.getIceGatheringState();
      dev.log('remote pc: onIceGatheringState($state), state2($state2)');
    };
    pc.onIceConnectionState = (state) async {
      var state2 = await pc.getIceConnectionState();
      dev.log(
        'remote pc: onIceConnectionState($state), state2($state2) ${DateTime.now()}',
      );

      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
        dev.log('🎉 ICE CONNECTION ESTABLISHED!');
        _logSelectedCandidatePair();
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        dev.log('❌ ICE CONNECTION FAILED - Network connectivity issue');
        _restartIce();
      } else if (state ==
          RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        dev.log('⚠️ ICE CONNECTION DISCONNECTED - Attempting reconnection');
      }
    };
    pc.onConnectionState = (state) async {
      dev.log('remote pc: onConnectionState($state) ${DateTime.now()}');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        dev.log('remote pc: CONNECTION ESTABLISHED');
        onConnectionComplete?.call();
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        dev.log('remote pc: CONNECTION FAILED');
      }
    };
    pc.onIceCandidate = _onIceCandidate;
    pc.onRenegotiationNeeded = _onRemoteRenegotiationNeeded;
    pc.onDataChannel = _onDataChannel;

    // Don't add transceivers here - let them be created from the remote offer
    // This ensures proper matching of media lines

    _peerConnection = pc;
  }

  Future<void> _logSelectedCandidatePair() async {
    try {
      var stats = await _peerConnection!.getStats();
      for (var stat in stats) {
        if (stat.type == 'candidate-pair' &&
            stat.values['state'] == 'succeeded') {
          dev.log('✅ Selected candidate pair: ${stat.values}');
        }
      }
    } catch (e) {
      dev.log('Failed to get stats: $e');
    }
  }

  Future<void> _restartIce() async {
    try {
      dev.log('Attempting ICE restart...');
      await _peerConnection!.restartIce();
    } catch (e) {
      dev.log('ICE restart failed: $e');
    }
  }

  void _onIceCandidate(RTCIceCandidate candidate) {
    dev.log('Local ICE Candidate: ${candidate.candidate}');
    var ice = RTCIceCandidate(
      candidate.candidate,
      candidate.sdpMid,
      candidate.sdpMLineIndex,
    );

    if (_session != null) {
      signalingHandler.sendTrickle(
        TrickleMessage(session: _session!, candidate: ice, id: '4'),
      );
    }
  }

  void _onTrickleMessage(TrickleMessage msg) async {
    if (_peerConnection == null || (msg.candidate.candidate ?? '').isEmpty) {
      dev.log(
        'onTrickleMessage: PeerConnection not initialized or candidate is empty',
      );
      return;
    }
    dev.log('Received Remote ICE Candidate: ${msg.candidate.toMap()}');
    try {
      var ice = RTCIceCandidate(
        msg.candidate.candidate,
        msg.candidate.sdpMid,
        msg.candidate.sdpMLineIndex,
      );
      dev.log('Adding remote ICE Candidate to PC: ${ice.toMap()}');
      await _peerConnection!.addCandidate(ice);
    } catch (e) {
      dev.log('Error adding remote ICE candidate: $e');
    }
  }

  void _onDataChannel(RTCDataChannel channel) {
    dev.log('onDataChannel: ${channel.label}');
    _dataChannel = channel;
    _dataChannel!.onMessage = _onDataChannelMessage;
    _dataChannel!.onDataChannelState = _onDataChannelState;
  }

  void _onDataChannelState(RTCDataChannelState state) {
    dev.log('_onDataChannelState: $state');
    if (state == RTCDataChannelState.RTCDataChannelOpen) {
      onDataChannelReady?.call();
    }
  }

  void _onDataChannelMessage(RTCDataChannelMessage msg) {
    dev.log('onDataChannelMessage: ${msg.text}');
    if (msg.isBinary) {
      onDataFrame?.call(Uint8List.fromList(msg.binary));
    }
    {
      _messageController.add(msg.text);
    }
  }

  @override
  void sendDataChannelMessage(String text) {
    if (_dataChannel == null) return;
    dev.log('onSendDatamessage $text, $_dataChannel');
    _dataChannel!.send(RTCDataChannelMessage(text));
  }

  void _onRemoteRenegotiationNeeded() {
    dev.log('onRemoteRenegotiationNeeded');
  }

  void _onTrack(RTCTrackEvent event) {
    dev.log('onTrack: ${event.streams.length} ${event.track.kind}');

    // Make sure the track is properly added to your video renderer
    if (event.track.kind == 'video') {
      dev.log('Video track received: ${event.track.id}');
      // You need to set this track to your RTCVideoRenderer
      // Make sure you have a video renderer widget in your UI that displays this track
    }

    onTrack?.call(event);
  }

  Future<void> _negotiate(InviteResponse msg) async {
    final oaConstraints = <String, dynamic>{
      'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': true},
      'optional': [
        {'DtlsSrtpKeyAgreement': true},
      ],
    };

    final remoteDesc = RTCSessionDescription(msg.offer.sdp, msg.offer.type);
    dev.log('''
        **** Received Offer ****
        \n ${remoteDesc.toMap()}
        ****''');

    // Don't pre-create transceivers - let WebRTC create them from the offer
    dev.log('Attempting to set remote description...');
    await _peerConnection!
        .setRemoteDescription(remoteDesc)
        .then((_) {
          dev.log('setRemoteDescription SUCCESS');
        })
        .catchError((e) {
          dev.log('setRemoteDescription FAILED: $e', error: e);
        });

    // Now configure the transceivers that were created from the remote offer
    var transceivers = await _peerConnection!.getTransceivers();
    dev.log(
      'Found ${transceivers.length} transceivers after setRemoteDescription',
    );

    for (var i = 0; i < transceivers.length; i++) {
      var transceiver = transceivers[i];
      dev.log('Processing transceiver $i: MID=${transceiver.mid}');

      try {
        var currentDir = await transceiver.getDirection();
        dev.log('  Current direction: $currentDir');

        // Force all transceivers to receive-only
        await transceiver.setDirection(TransceiverDirection.RecvOnly);
        dev.log('  Set direction to RecvOnly');

        // Log receiver track info
        if (transceiver.receiver.track != null) {
          dev.log(
            '  Receiver track: ${transceiver.receiver.track!.kind} - ${transceiver.receiver.track!.id}',
          );
        }
      } catch (e) {
        dev.log('  Failed to configure transceiver: $e');
      }
    }

    // Wait for WebRTC internal state to stabilize
    dev.log('Waiting for WebRTC internal state to stabilize...');
    await Future.delayed(const Duration(milliseconds: 200));

    // Create answer with explicit video/audio constraints
    dev.log('Creating answer...');
    var answer = await _peerConnection!.createAnswer(oaConstraints);

    dev.log('''
        **** Creating Answer ****
        \n ${answer.toMap()}
        ****''');

    // Check if video is being accepted or rejected
    if (answer.sdp != null && answer.sdp!.contains('m=video 0')) {
      dev.log('WARNING: Answer still rejecting video (m=video 0)');

      // Try to diagnose the issue
      dev.log('Diagnosing video rejection...');
      var finalTransceivers = await _peerConnection!.getTransceivers();
      for (var i = 0; i < finalTransceivers.length; i++) {
        var t = finalTransceivers[i];
        dev.log(
          'Transceiver $i: MID=${t.mid}, Track=${t.receiver.track?.kind}',
        );
        try {
          var dir = await t.getDirection();
          var currentDir = await t.getCurrentDirection();
          dev.log('  Direction: $dir, Current: $currentDir');
        } catch (e) {
          dev.log('  Direction error: $e');
        }
      }
    } else {
      dev.log('SUCCESS: Answer accepts video!');
    }

    dev.log('Attempting to set local description...');
    await _peerConnection!
        .setLocalDescription(answer)
        .then((_) {
          dev.log('setLocalDescription SUCCESS');
        })
        .catchError((e) {
          dev.log('setLocalDescription FAILED: $e', error: e);
        });

    await signalingHandler.sendInvite(
      InviteRequest(
        session: msg.session,
        answer: SdpWrapper(type: answer.type ?? '', sdp: answer.sdp ?? ''),
        id: msg.id,
      ),
    );
  }

  void _onRegister(RegisterResponse msg) {
    dev.log('onRegister: ${msg.deviceIds.length} devices');
    _producers.addAll(msg.deviceIds);
    onRegister?.call();
  }

  void _initNeededConnections() {
    for (final peer in _desiredPeers) {
      if (_producers.any((p) => p.startsWith(peer)) &&
          _selectedProducer != peer) {
        final match = _producers.firstWhereOrNull((p) => p.startsWith(peer));
        dev.log('match: $match for $peer');
        if (match == null) continue;
        _selectedProducer = match;
        signalingHandler.sendConnect(
          ConnectRequest(
            signalingHandler.connectionId,
            authorization: '',
            deviceId: match,
            iceServers: iceServers,
          ),
        );
      }
    }
  }

  void _removeConnection(String peerId) {
    if (_selectedProducer == peerId) {
      _selectedProducer = null;
    }
    // signalingHandler.endSession(_session!);
  }

  void _onConnectResponse(ConnectResponse msg) {
    dev.log('''
        **** Session Started ****

        SessionId: \n ${msg.session}
        ProducerId: \n $_selectedProducer
        ****''');
    _session = msg.session;
    iceServers = msg.iceServers;
    for (var ice in iceServers) {
      dev.log('ICE Server: ${ice.toJson()}');
    }
    onSessionStarted?.call(msg.session, _selectedProducer ?? '');
  }

  void _onInvite(InviteResponse msg) {
    if (msg.offer.type == 'offer') {
      _negotiate(msg);
    }
  }

  void startStatsProbe(RTCPeerConnection pc) {
    Timer.periodic(const Duration(seconds: 2), (t) async {
      var stats = await pc.getStats();
      for (var stat in stats) {
        dev.log(
          'id: ${stat.id}, timestamp: ${stat.timestamp}, type: ${stat.type}, values: ${stat.values}',
        );
      }
    });
  }
}
