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

  MediaStream? _localStream;

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

  Future<void> setupLocalTrack() async {
    if (_localStream != null) return;

    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': {
        'facingMode': 'user',
        'width': {'min': 640, 'ideal': 1280, 'max': 1920},
        'height': {'min': 480, 'ideal': 720, 'max': 1080},
      },
    });

    dev.log('Local stream initialized: ${_localStream!.id}');
    if (_peerConnection != null) {
      for (var track in _localStream!.getTracks()) {
        _peerConnection!.addTrack(track, _localStream!);
      }
    }
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

    final config = <String, dynamic>{
      'iceServers': iceServers.map((ice) => ice.toJson()).toList(),
    };

    dev.log('Initializing WebRTC peer connection: $config');
    var pc = await createPeerConnection(config);
    //var capabilities = await getRtpReceiverCapabilities('video');

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

    RTCRtpTransceiver? videoTransceiver = await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );

    final capabilities = await getRtpReceiverCapabilities('video');
    if (capabilities.codecs != null) {
      List<RTCRtpCodecCapability> codecs =
          capabilities.codecs!
              .where(
                (codec) =>
                    codec.mimeType.toLowerCase() == 'h264' ||
                    codec.mimeType.toLowerCase() == 'video/h264',
              )
              .toList();
      if (codecs.isNotEmpty) {
        await videoTransceiver.setCodecPreferences(codecs);
        for (var codec in codecs) {
          dev.log(
            'Preferred Video Codec Set: ${codec.mimeType}, ${codec.sdpFmtpLine}',
          );
        }
      } else {
        dev.log(
          'H264 codec not found in local capabilities. Cannot set preference.',
        );
      }
    } else {
      dev.log(
        'WebRTCRemotePeer: Warning - Could not get receiver capabilities.',
      );
    }

    _peerConnection = pc;
    //startStatsProbe(_peerConnection!);
  }

  void _onIceCandidate(RTCIceCandidate candidate) {
    dev.log('Local ICE Candidate: ${candidate.toMap()}');
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
    onTrack?.call(event);
  }

  Future<void> _negotiate(InviteResponse msg) async {
    final oaConstraints = <String, dynamic>{
      'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': true},
      'optional': [],
    };

    final remoteDesc = RTCSessionDescription(msg.offer.sdp, msg.offer.type);

    dev.log('''
        **** Received Offer ****
        \n ${remoteDesc.toMap()}
        ****''');

    dev.log('Attempting to set remote description...');
    await _peerConnection!
        .setRemoteDescription(remoteDesc)
        .then((_) {
          dev.log('setRemoteDescription SUCCESS');
        })
        .catchError((e) {
          dev.log('setRemoteDescription FAILED: $e', error: e);
        });

    var answer = await _peerConnection!.createAnswer(oaConstraints);
    dev.log('''
        **** Creating Answer ****
        \n ${answer.toMap()}
        ****''');

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
