import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../utils/logger.dart';
import 'sdp_utils.dart';

/// Manages ICE candidate queueing, resolution, and signaling.
///
/// Handles the complexity of:
/// - Queueing remote candidates before remote description is set
/// - Resolving mid from mline index when not provided
/// - Tracking end-of-candidates signaling
/// - One-time callbacks for first local/remote ICE
class IceCandidateManager {
  IceCandidateManager({
    required this.onSendCandidate,
    this.onLocalIceStarted,
    this.onRemoteIceStarted,
    this.tag = '',
  });

  /// Called when a candidate needs to be sent to the remote peer.
  final void Function(RTCIceCandidate candidate) onSendCandidate;

  /// Called once when the first local ICE candidate is generated.
  final VoidCallback? onLocalIceStarted;

  /// Called once when the first remote ICE candidate is received.
  final VoidCallback? onRemoteIceStarted;

  /// Tag for logging.
  final String tag;

  final Queue<RTCIceCandidate> _pendingRemoteCandidates =
      Queue<RTCIceCandidate>();
  final Queue<RTCIceCandidate> _pendingLocalCandidates =
      Queue<RTCIceCandidate>();
  final Set<String> _eocSentForMid = {};
  final Set<String> _seenRemoteCandidates = {};
  Map<int, String> _mlineToMid = {};

  bool _firedLocalIce = false;
  bool _firedRemoteIce = false;
  bool _remoteDescSet = false;
  bool _holdLocal = false;
  Completer<void>? _gatheringCompleter;

  /// Set the mline-to-mid mapping (usually from remote SDP).
  void setMlineMapping(Map<int, String> mapping) {
    _mlineToMid = mapping;
  }

  /// Mark that the remote description has been set.
  void markRemoteDescSet() {
    _remoteDescSet = true;
  }

  /// Hold local candidates — queue them instead of sending.
  ///
  /// Call this before `setLocalDescription` to prevent candidates from
  /// being sent to the server before the SDP answer arrives.
  void holdLocalCandidates() {
    _holdLocal = true;
  }

  /// Release all held local candidates, sending them in order.
  ///
  /// Call this after the SDP answer has been sent successfully.
  void releaseLocalCandidates() {
    _holdLocal = false;
    final count = _pendingLocalCandidates.length;
    if (count > 0) {
      Logger().info('$tag Releasing $count held local candidates');
    }
    while (_pendingLocalCandidates.isNotEmpty) {
      onSendCandidate(_pendingLocalCandidates.removeFirst());
    }
  }

  /// Reset state for a new negotiation.
  void reset() {
    _pendingRemoteCandidates.clear();
    _pendingLocalCandidates.clear();
    _eocSentForMid.clear();
    _seenRemoteCandidates.clear();
    _mlineToMid.clear();
    _firedLocalIce = false;
    _firedRemoteIce = false;
    _remoteDescSet = false;
    _holdLocal = false;
    _gatheringCompleter = null;
  }

  /// Create a new gathering completer.
  Completer<void> createGatheringCompleter() {
    _gatheringCompleter = Completer<void>();
    return _gatheringCompleter!;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Local Candidates
  // ═══════════════════════════════════════════════════════════════════════════

  /// Handle a local ICE candidate from WebRTC.
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

    if (_holdLocal) {
      _pendingLocalCandidates.addLast(candidate);
    } else {
      onSendCandidate(candidate);
    }
  }

  /// Send end-of-candidates for a mid.
  void sendEndOfCandidates(String mid) {
    if (_eocSentForMid.add(mid)) {
      onSendCandidate(RTCIceCandidate('', mid, null));
    }
  }

  /// Send end-of-candidates for all known mids.
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
        // Fallback to default mids
        for (final mid in const ['audio0', 'video0', 'application1']) {
          sendEndOfCandidates(mid);
        }
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Remote Candidates
  // ═══════════════════════════════════════════════════════════════════════════

  /// Queue a remote candidate (before remote desc is set).
  void queueRemoteCandidate(RTCIceCandidate candidate) {
    _pendingRemoteCandidates.addLast(candidate);
  }

  /// Handle a remote ICE candidate.
  ///
  /// If remote description is not set, queues for later.
  /// Otherwise, adds to peer connection immediately.
  /// Duplicate candidates (same candidate string) are silently skipped.
  Future<void> handleRemoteCandidate(
    RTCIceCandidate candidate,
    RTCPeerConnection? pc,
  ) async {
    if ((candidate.candidate ?? '').isEmpty) {
      Logger().info(
        '$tag Received end-of-candidates for mid=${candidate.sdpMid}',
      );
      return;
    }

    // Deduplicate: skip candidates we've already processed
    final candidateStr = candidate.candidate!;
    if (!_seenRemoteCandidates.add(candidateStr)) {
      return; // Already seen, skip silently
    }

    if (pc == null || !_remoteDescSet) {
      _pendingRemoteCandidates.addLast(candidate);
      return;
    }

    await _addCandidate(candidate, pc);
  }

  /// Drain all queued remote candidates.
  Future<void> drainQueuedCandidates(RTCPeerConnection pc) async {
    if (_pendingRemoteCandidates.isEmpty) return;

    final count = _pendingRemoteCandidates.length;
    Logger().info('$tag Draining $count queued candidates');

    final futures = <Future<void>>[];
    while (_pendingRemoteCandidates.isNotEmpty) {
      final candidate = _pendingRemoteCandidates.removeFirst();
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
