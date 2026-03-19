import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../utils/logger.dart';
import 'sdp_utils.dart';

class IceCandidateManager {
  IceCandidateManager({
    required this.onSendCandidate,
    this.onLocalIceStarted,
    this.onRemoteIceStarted,
    this.tag = '',
  });

  final void Function(RTCIceCandidate candidate) onSendCandidate;
  final VoidCallback? onLocalIceStarted;
  final VoidCallback? onRemoteIceStarted;
  final String tag;

  final Queue<RTCIceCandidate> _pendingRemoteCandidates =
      Queue<RTCIceCandidate>();
  final Set<String> _eocSentForMid = {};
  final Set<String> _seenRemoteCandidates = {};
  Map<int, String> _mlineToMid = {};

  bool _firedLocalIce = false;
  bool _firedRemoteIce = false;
  bool _remoteDescSet = false;
  Completer<void>? _gatheringCompleter;

  void setMlineMapping(Map<int, String> mapping) {
    _mlineToMid = mapping;
  }

  void markRemoteDescSet() {
    _remoteDescSet = true;
  }

  void reset() {
    _pendingRemoteCandidates.clear();
    _eocSentForMid.clear();
    _seenRemoteCandidates.clear();
    _mlineToMid.clear();
    _firedLocalIce = false;
    _firedRemoteIce = false;
    _remoteDescSet = false;
    _gatheringCompleter = null;
  }

  Completer<void> createGatheringCompleter({
    Duration timeout = const Duration(seconds: 15),
  }) {
    _gatheringCompleter = Completer<void>();
    Future.delayed(timeout, () {
      if (_gatheringCompleter != null && !_gatheringCompleter!.isCompleted) {
        Logger().warn('$tag ICE gathering timed out after ${timeout.inSeconds}s');
        _gatheringCompleter!.complete();
      }
    });
    return _gatheringCompleter!;
  }

  void handleLocalCandidate(RTCIceCandidate candidate, String? sessionId) {
    if ((candidate.candidate ?? '').isEmpty) {
      Logger().info('$tag ✅ End of LOCAL candidates');
      _gatheringCompleter?.complete();
      return;
    }

    if (!_firedLocalIce) {
      _firedLocalIce = true;
      onLocalIceStarted?.call();
    }

    if (sessionId == null) return;
    onSendCandidate(candidate);
  }

  void sendEndOfCandidates(String mid) {
    if (_eocSentForMid.add(mid)) {
      onSendCandidate(RTCIceCandidate('', mid, null));
    }
  }

  Future<void> sendAllEndOfCandidates(RTCPeerConnection pc) async {
    if (_mlineToMid.isNotEmpty) {
      for (final mid in _mlineToMid.values) {
        sendEndOfCandidates(mid);
      }
    } else {
      try {
        final txs = await pc.getTransceivers();
        for (final t in txs) {
          if (t.mid.isNotEmpty) {
            sendEndOfCandidates(t.mid);
          }
        }
      } catch (_) {
        for (final mid in const ['audio0', 'video0', 'application1']) {
          sendEndOfCandidates(mid);
        }
      }
    }
  }

  void queueRemoteCandidate(RTCIceCandidate candidate) {
    _pendingRemoteCandidates.addLast(candidate);
  }

  Future<void> handleRemoteCandidate(
    RTCIceCandidate candidate,
    RTCPeerConnection? pc,
  ) async {
    if ((candidate.candidate ?? '').isEmpty) {
      Logger().info(
        '$tag Received remote end-of-candidates (mid=${candidate.sdpMid})',
      );
      if (_gatheringCompleter != null && !_gatheringCompleter!.isCompleted) {
        _gatheringCompleter!.complete();
      }
      return;
    }

    final candidateStr = candidate.candidate!;
    if (!_seenRemoteCandidates.add(candidateStr)) return;

    if (pc == null || !_remoteDescSet) {
      _pendingRemoteCandidates.addLast(candidate);
      return;
    }

    await _addCandidate(candidate, pc);
  }

  Future<void> drainQueuedCandidates(RTCPeerConnection pc) async {
    if (_pendingRemoteCandidates.isEmpty) return;

    final count = _pendingRemoteCandidates.length;
    Logger().info('$tag Draining $count queued candidates');

    final futures = <Future<void>>[];
    while (_pendingRemoteCandidates.isNotEmpty) {
      final candidate = _pendingRemoteCandidates.removeFirst();
      if ((candidate.candidate ?? '').isEmpty) {
        Logger().info('$tag Skipping queued end-of-candidates marker');
        continue;
      }
      futures.add(_addCandidate(candidate, pc));
    }
    await Future.wait(futures);
  }

  Future<void> _addCandidate(
    RTCIceCandidate candidate,
    RTCPeerConnection pc,
  ) async {
    if (!_firedRemoteIce) {
      _firedRemoteIce = true;
      onRemoteIceStarted?.call();
    }

    final mid = resolveMid(
      candidate.sdpMid,
      candidate.sdpMLineIndex,
      _mlineToMid,
    );
    if (mid == null) {
      Logger().info('$tag Could not resolve mid for candidate - dropping');
      return;
    }

    try {
      final resolved = RTCIceCandidate(
        candidate.candidate,
        mid,
        candidate.sdpMLineIndex,
      );
      await pc.addCandidate(resolved);
    } catch (e) {
      Logger().info('$tag Error adding ICE candidate: $e');
    }
  }
}
