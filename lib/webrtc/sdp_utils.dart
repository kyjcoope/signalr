/// SDP parsing and manipulation utilities using Dart extension methods.
library;

/// Extension methods for SDP string manipulation.
extension SdpUtils on String {
  /// Check if this SDP contains H264 codec.
  bool get containsH264 =>
      RegExp(r'\bH264/90000\b', caseSensitive: false).hasMatch(this);

  /// Apply H264 profile fix for compatibility.
  ///
  /// Normalizes profile-level-id to baseline and adds level-asymmetry-allowed.
  String get withH264ProfileFix {
    var sdp = replaceAllMapped(
      RegExp(r'profile-level-id=([0-9A-Fa-f]{6})'),
      (_) => 'profile-level-id=42e01f',
    );

    if (!sdp.toLowerCase().contains('level-asymmetry-allowed')) {
      sdp = sdp.replaceFirst(
        'packetization-mode=1;',
        'level-asymmetry-allowed=1;packetization-mode=1;',
      );
    }

    return sdp;
  }

  /// Build mapping from m-line index to mid attribute.
  Map<int, String> get mlineToMidMapping {
    final lines = split(RegExp(r'\r?\n'));
    final map = <int, String>{};
    var mIndex = -1;

    for (final line in lines) {
      if (line.startsWith('m=')) mIndex++;
      if (line.startsWith('a=mid:')) {
        final mid = line.substring('a=mid:'.length).trim();
        if (mIndex >= 0) map[mIndex] = mid;
      }
    }

    return map;
  }

  /// Extract the primary video codec from this SDP.
  ///
  /// Returns the first non-helper codec (excludes RTX, ULPFEC, RED, etc).
  String? get primaryVideoCodec {
    // Find video section
    final sections = split(RegExp(r'\r?\nm='));
    String? videoSection;

    for (final raw in sections) {
      final sec = raw.startsWith('m=') ? raw : 'm=$raw';
      if (sec.startsWith(RegExp(r'm=video'))) {
        videoSection = sec;
        break;
      }
    }

    if (videoSection == null) return null;

    // Get payload types from m-line
    final mLine = videoSection.split(RegExp(r'\r?\n')).first;
    final parts = mLine.split(' ');
    if (parts.length < 4) return null;

    final pts = parts
        .skip(3)
        .where((p) => RegExp(r'^\d+$').hasMatch(p))
        .toList();
    if (pts.isEmpty) return null;

    // Find codec for first non-helper payload type
    final lines = split(RegExp(r'\r?\n'));
    const helperCodecs = {'RTX', 'ULPFEC', 'RED', 'FLEXFEC-03'};

    for (final pt in pts) {
      final rtpmapLine = lines.firstWhere(
        (l) => l.startsWith('a=rtpmap:$pt '),
        orElse: () => '',
      );
      if (rtpmapLine.isEmpty) continue;

      final codecPart = rtpmapLine.split(' ').skip(1).firstOrNull ?? '';
      final codecName = codecPart.split('/').first.toUpperCase();

      if (!helperCodecs.contains(codecName)) {
        return codecName;
      }
    }

    return null;
  }

  /// Munge SDP for H264 compatibility if needed.
  String get withCompatibilityFixes {
    if (containsH264) {
      return withH264ProfileFix;
    }
    return this;
  }
}

/// Resolve a mid from either the provided sdpMid or the mline index.
String? resolveMid(String? sdpMid, int? mline, Map<int, String> mlineToMid) {
  if (sdpMid != null && sdpMid.isNotEmpty) return sdpMid;
  if (mline != null) return mlineToMid[mline];
  return null;
}
