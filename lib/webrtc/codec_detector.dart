
import '../utils/logger.dart';
import 'sdp_utils.dart';

/// Detects the negotiated video codec from SDP or WebRTC stats.
///
/// Attempts SDP-based detection first (fast, approximate),
/// then accepts stats-based codec resolution from [WebRtcStatsMonitor]
/// (accurate, no duplicate getStats() calls).
class CodecDetector {
  CodecDetector({this.onCodecResolved, this.tag = ''});

  /// Called when the video codec is determined.
  final void Function(String codec)? onCodecResolved;

  /// Tag for logging.
  final String tag;

  String? _detectedCodec;

  /// The detected codec, if available.
  String? get codec => _detectedCodec;

  /// Whether a codec has been detected.
  bool get hasCodec => _detectedCodec != null;

  /// Reset detector state.
  void reset() {
    _detectedCodec = null;
  }

  /// Dispose of resources.
  void dispose() {
    // No timers to clean up anymore — stats polling was removed.
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SDP-based Detection
  // ═══════════════════════════════════════════════════════════════════════════

  /// Try to extract codec from SDP (fast, but approximate).
  void extractFromSdp(String sdp) {
    if (hasCodec) return;

    final codec = sdp.primaryVideoCodec;
    if (codec != null) {
      _setCodec(codec, 'SDP');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Stats-based Resolution (piggybacked on WebRtcStatsMonitor)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Resolve codec from an already-computed stats snapshot.
  ///
  /// Called by the session when [WebRtcStatsMonitor] reports a codec,
  /// eliminating the need for a separate getStats() call.
  void resolveFromStats(String codec) {
    if (hasCodec || codec.isEmpty) return;
    _setCodec(codec, 'Stats');
  }

  void _setCodec(String codec, String source) {
    _detectedCodec = codec;
    Logger().info('$tag Selected video codec ($source): $codec');
    onCodecResolved?.call(codec);
  }
}
