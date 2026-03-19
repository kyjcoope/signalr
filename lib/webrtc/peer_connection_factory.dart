import '../signalr/signalr_messages.dart';
import '../utils/logger.dart';

abstract final class PeerConnectionFactory {
  static const String defaultStunServer = 'stun:stun.l.google.com:19302';

  static Map<String, dynamic> buildConfig({
    required List<IceServerConfig> iceServers,
    bool turnTcpOnly = false,
    int iceCandidatePoolSize = 0,
  }) {
    final servers = iceServers.map((e) => e.toJson()).toList();
    if (turnTcpOnly) {
      return _buildTcpOnlyConfig(servers, iceCandidatePoolSize);
    }
    return _buildDefaultConfig(servers, iceCandidatePoolSize);
  }

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

    if (tcpServers.isEmpty) {
      Logger().error(
        'PeerConnectionFactory: turnTcpOnly=true but no TCP/TLS TURN servers found! '
        'Falling back to all servers to avoid guaranteed failure.',
      );
      return _buildDefaultConfig(servers, iceCandidatePoolSize);
    }

    return {
      'iceServers': tcpServers,
      'iceTransportPolicy': 'relay',
      'iceCandidatePoolSize': iceCandidatePoolSize,
      'rtcpMuxPolicy': 'require',
      'sdpSemantics': 'unified-plan',
    };
  }

  static Map<String, dynamic> _buildDefaultConfig(
    List<Map<String, Object?>> servers,
    int iceCandidatePoolSize,
  ) {
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
