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

  /// Extract the primary video codec from each video m-section.
  ///
  /// Returns a list where index 0 = codec of the 1st video m-line, etc.
  List<String> get videoCodecsPerSection {
    final sections = split(RegExp(r'\r?\nm='));
    final result = <String>[];
    const helperCodecs = {'RTX', 'ULPFEC', 'RED', 'FLEXFEC-03'};

    for (final raw in sections) {
      final sec = raw.startsWith('m=') ? raw : 'm=$raw';
      if (!sec.startsWith(RegExp(r'm=video'))) continue;

      final secLines = sec.split(RegExp(r'\r?\n'));
      final mLine = secLines.first;
      final parts = mLine.split(' ');
      if (parts.length < 4) {
        result.add('?');
        continue;
      }

      final pts = parts
          .skip(3)
          .where((p) => RegExp(r'^\d+$').hasMatch(p))
          .toList();

      String codec = '?';
      for (final pt in pts) {
        final rtpmapLine = secLines.firstWhere(
          (l) => l.startsWith('a=rtpmap:$pt '),
          orElse: () => '',
        );
        if (rtpmapLine.isEmpty) continue;

        final codecPart = rtpmapLine.split(' ').skip(1).firstOrNull ?? '';
        final codecName = codecPart.split('/').first.toUpperCase();

        if (!helperCodecs.contains(codecName)) {
          codec = codecName;
          break;
        }
      }
      result.add(codec);
    }

    return result;
  }

  /// Munge SDP for H264 compatibility if needed.
  String get withCompatibilityFixes {
    if (containsH264) {
      return withH264ProfileFix;
    }
    return this;
  }

  /// Force DTLS active role in the answer SDP.
  ///
  /// This fixes "hanging DTLS" where both sides wait for the other to send
  /// ClientHello. By forcing 'active', Flutter will initiate the handshake.
  ///
  /// Only apply this to ANSWER SDPs, not offers.
  String get withDtlsActiveRole {
    // Replace actpass with active to force Flutter to be the DTLS client
    // This is critical for IoT cameras that expect the client to initiate
    return replaceAll('a=setup:actpass', 'a=setup:active');
  }

  /// Apply all answer-specific compatibility fixes.
  ///
  /// Use this for local answer SDP before sending to remote peer.
  String get withAnswerFixes {
    var sdp = this;
    // Force active DTLS role
    sdp = sdp.withDtlsActiveRole;
    // Apply H264 fixes if needed
    if (sdp.containsH264) {
      sdp = sdp.withH264ProfileFix;
    }
    return sdp;
  }
}

/// Resolve a mid from either the provided sdpMid or the mline index.
String? resolveMid(String? sdpMid, int? mline, Map<int, String> mlineToMid) {
  if (sdpMid != null && sdpMid.isNotEmpty) return sdpMid;
  if (mline != null) return mlineToMid[mline];
  return null;
}
