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
  final Set<String> _eocSentForMid = {};
  final Set<String> _seenRemoteCandidates = {};
  Map<int, String> _mlineToMid = {};

  bool _firedLocalIce = false;
  bool _firedRemoteIce = false;
  bool _remoteDescSet = false;
  Completer<void>? _gatheringCompleter;

  /// Set the mline-to-mid mapping (usually from remote SDP).
  void setMlineMapping(Map<int, String> mapping) {
    _mlineToMid = mapping;
  }

  /// Mark that the remote description has been set.
  void markRemoteDescSet() {
    _remoteDescSet = true;
  }

  /// Reset state for a new negotiation.
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

  /// Create a new gathering completer with a safety timeout.
  ///
  /// If the native WebRTC stack hangs and never fires the
  /// end-of-candidates marker, the completer auto-resolves after [timeout].
  Completer<void> createGatheringCompleter({
    Duration timeout = const Duration(seconds: 15),
  }) {
    _gatheringCompleter = Completer<void>();
    // Safety net: auto-complete if ICE gathering hangs
    Future.delayed(timeout, () {
      if (_gatheringCompleter != null && !_gatheringCompleter!.isCompleted) {
        Logger().warn('$tag ICE gathering timed out after ${timeout.inSeconds}s');
        _gatheringCompleter!.complete();
      }
    });
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

    onSendCandidate(candidate);
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
    // End-of-candidates: relay to the peer connection so ICE can
    // transition to completed/failed. Queue if remote desc not set yet.
    if ((candidate.candidate ?? '').isEmpty) {
      Logger().info(
        '$tag Received remote end-of-candidates (mid=${candidate.sdpMid})',
      );
      if (pc == null || !_remoteDescSet) {
        _pendingRemoteCandidates.addLast(candidate);
        return;
      }
      try {
        await pc.addCandidate(candidate);
      } catch (e) {
        Logger().info('$tag EOC addCandidate: $e');
      }
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
