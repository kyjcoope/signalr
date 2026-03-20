import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../webrtc/webrtc_stats_monitor.dart';

class CameraListItem extends StatelessWidget {
  const CameraListItem({
    super.key,
    required this.cameraId,
    required this.name,
    required this.type,
    required this.codec,
    required this.connected,
    required this.isFav,
    required this.isPending,
    required this.isWorking,
    required this.textureId,
    required this.renderer,
    required this.onConnect,
    required this.onDisconnect,
    required this.onToggleFavorite,
    required this.compact,
    this.videoStats,
    this.trackInfo,
    this.videoTrackCount = 0,
    this.activeVideoTrack = 0,
    this.onSwitchTrack,
    this.errorMessage,
  });

  final String cameraId;
  final String name;
  final String type;
  final String codec;
  final bool connected;
  final bool isFav;
  final bool isPending;
  final bool isWorking;
  final int? textureId;
  final RTCVideoRenderer? renderer;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onToggleFavorite;
  final bool compact;
  final WebRtcVideoStats? videoStats;
  final String? trackInfo;
  final int videoTrackCount;
  final int activeVideoTrack;
  final void Function(int trackIndex)? onSwitchTrack;
  final String? errorMessage;

  static const double _videoWidth = 320;
  static const double _videoHeight = 180;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            compact ? _buildCompactLayout() : _buildWideLayout(),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: compact ? double.infinity : _videoWidth,
                height: compact ? (_videoHeight * 0.75) : _videoHeight,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Container(
                        color: Colors.black,
                        child: _buildPanelContent(),
                      ),
                    ),
                    if (connected && _hasVideo && videoTrackCount > 1)
                      Positioned(
                        bottom: 4,
                        left: 0,
                        right: 0,
                        child: _buildTrackSwitcher(),
                      ),
                    if (videoStats != null)
                      Positioned(
                        top: 4,
                        right: 4,
                        child: _StatsOverlay(stats: videoStats!),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool get _hasVideo => kIsWeb ? renderer != null : textureId != null;

  Widget _buildPanelContent() {
    if (connected && _hasVideo) {
      if (kIsWeb) {
        return RTCVideoView(
          renderer!,
          mirror: false,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
        );
      } else {
        return FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: 16,
            height: 9,
            child: Texture(textureId: textureId!),
          ),
        );
      }
    }

    if (isPending) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: Colors.white38,
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildTrackSwitcher() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _trackArrow(
          icon: Icons.chevron_left,
          enabled: activeVideoTrack > 0,
          onTap: () => onSwitchTrack?.call(activeVideoTrack - 1),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            '${activeVideoTrack + 1} / $videoTrackCount',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
        ),
        _trackArrow(
          icon: Icons.chevron_right,
          enabled: activeVideoTrack < videoTrackCount - 1,
          onTap: () => onSwitchTrack?.call(activeVideoTrack + 1),
        ),
      ],
    );
  }

  Widget _trackArrow({
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: enabled ? 0.5 : 0.2),
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            color: enabled ? Colors.white : Colors.white38,
            size: 18,
          ),
        ),
      ),
    );
  }

  Widget _buildWideLayout() {
    final showStop = connected || isPending;
    return Row(
      children: [
        IconButton(
          tooltip: isFav ? 'Unfavorite' : 'Favorite',
          icon: Icon(
            isFav ? Icons.star : Icons.star_border,
            color: isFav ? Colors.amber : null,
          ),
          onPressed: onToggleFavorite,
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: Text(
            cameraId,
            style: const TextStyle(fontSize: 13),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: Text(
            name,
            style: const TextStyle(fontSize: 13),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: Text(
            type,
            style: const TextStyle(fontSize: 13),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 1,
          child: Text(
            codec,
            style: TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              color: codec == '—' ? Colors.grey : Colors.deepPurple,
            ),
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (trackInfo != null) ...[
          const SizedBox(width: 6),
          _chip(trackInfo!, Colors.teal, Icons.videocam),
        ],
        const SizedBox(width: 8),
        _statusChip(),
        const SizedBox(width: 8),
        showStop
            ? OutlinedButton.icon(
                onPressed: onDisconnect,
                icon: const Icon(Icons.stop, color: Colors.red),
                label: const Text('Stop'),
              )
            : ElevatedButton.icon(
                onPressed: onConnect,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start'),
              ),
      ],
    );
  }

  Widget _buildCompactLayout() {
    final showStop = connected || isPending;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Top control row
        Row(
          children: [
            IconButton(
              tooltip: isFav ? 'Unfavorite' : 'Favorite',
              icon: Icon(
                isFav ? Icons.star : Icons.star_border,
                color: isFav ? Colors.amber : null,
              ),
              onPressed: onToggleFavorite,
            ),
            const SizedBox(width: 4),
            _statusChip(),
            const Spacer(),
            showStop
                ? OutlinedButton(
                    onPressed: onDisconnect,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                    ),
                    child: const Text('Stop'),
                  )
                : ElevatedButton(
                    onPressed: onConnect,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                    ),
                    child: const Text('Start'),
                  ),
          ],
        ),
        const SizedBox(height: 4),
        _kv('ID', cameraId, mono: true),
        _kv('Name', name),
        _kv('Type', type),
        _kv(
          'Codec',
          codec,
          mono: true,
          valueColor: codec == '—' ? Colors.grey : Colors.deepPurple,
        ),
      ],
    );
  }

  Widget _statusChip() {
    if (errorMessage != null) {
      return Tooltip(
        message: errorMessage!,
        child: _chip(errorMessage!, Colors.red, Icons.error_outline),
      );
    }
    if (isWorking) {
      return _chip('Working', Colors.green, Icons.check_circle);
    }
    if (isPending) {
      return _chip('Pending', Colors.blue, Icons.hourglass_top);
    }
    return const SizedBox.shrink();
  }

  Widget _chip(String label, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11, color: color)),
        ],
      ),
    );
  }

  Widget _kv(
    String label,
    String value, {
    bool mono = false,
    Color? valueColor,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(fontSize: 12, color: Colors.black87),
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: Colors.black54,
              ),
            ),
            TextSpan(
              text: value,
              style: TextStyle(
                fontFamily: mono ? 'monospace' : null,
                color: valueColor,
              ),
            ),
          ],
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Semi-transparent overlay showing live WebRTC video stats.
class _StatsOverlay extends StatelessWidget {
  const _StatsOverlay({required this.stats});

  final WebRtcVideoStats stats;

  @override
  Widget build(BuildContext context) {
    // Don't show anything until we have real data.
    if (stats.rfps <= 0 && stats.dfps <= 0) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          _line('Rx', '${stats.rfps.round()} fps'),
          _line('Dec', '${stats.dfps.round()} fps'),
          if (stats.width > 0 && stats.height > 0)
            _line('Res', '${stats.width}x${stats.height}'),
          if (stats.bitrateKbps > 0)
            _line('Kbps', stats.bitrateKbps.round().toString()),
        ],
      ),
    );
  }

  Widget _line(String label, String value) {
    return Text(
      '$label: $value',
      style: const TextStyle(
        color: Colors.white,
        fontSize: 10,
        fontFamily: 'monospace',
        height: 1.4,
      ),
    );
  }
}
