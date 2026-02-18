import '../signalr/signalr_messages.dart';

/// Builds WebRTC peer connection configurations.
///
/// Extracted from [WebRtcCameraSession] for reusability and cleaner code.
abstract final class PeerConnectionFactory {
  /// Default STUN server for ICE gathering.
  static const String defaultStunServer = 'stun:stun.l.google.com:19302';

  /// Build a peer connection configuration.
  ///
  /// - [iceServers] - List of ICE server configurations
  /// - [turnTcpOnly] - If true, only use TCP TURN servers (relay mode)
  /// - [iceCandidatePoolSize] - Number of ICE candidates to pre-gather
  static Map<String, dynamic> buildConfig({
    required List<IceServerConfig> iceServers,
    bool turnTcpOnly = false,
    int iceCandidatePoolSize = 4,
  }) {
    final servers = iceServers.map((e) => e.toJson()).toList();

    if (turnTcpOnly) {
      return _buildTcpOnlyConfig(servers, iceCandidatePoolSize);
    }

    return _buildDefaultConfig(servers, iceCandidatePoolSize);
  }

  /// Build config with only TCP TURN servers (relay mode).
  static Map<String, dynamic> _buildTcpOnlyConfig(
    List<Map<String, Object?>> servers,
    int iceCandidatePoolSize,
  ) {
    final tcpServers = servers
        .map((s) {
          final urls = (s['urls'] is List ? s['urls'] : [s['urls']]) as List;
          final tcpUrls = urls.where((u) {
            final str = u.toString().toLowerCase();
            return str.startsWith('turns:') || str.contains('transport=tcp');
          }).toList();
          return {...s, 'urls': tcpUrls};
        })
        .where((s) => (s['urls'] as List).isNotEmpty)
        .toList();

    return {
      'iceServers': tcpServers,
      'iceTransportPolicy': 'relay',
      'iceCandidatePoolSize': iceCandidatePoolSize,
      'rtcpMuxPolicy': 'require',
      'sdpSemantics': 'unified-plan',
    };
  }

  /// Build default config with all transport types.
  static Map<String, dynamic> _buildDefaultConfig(
    List<Map<String, Object?>> servers,
    int iceCandidatePoolSize,
  ) {
    // Add default STUN server
    servers.insert(0, {'urls': defaultStunServer});

    return {
      'iceServers': servers,
      'iceTransportPolicy': 'all',
      'iceCandidatePoolSize': iceCandidatePoolSize,
      'rtcpMuxPolicy': 'require',
      'sdpSemantics': 'unified-plan',
    };
  }
}
