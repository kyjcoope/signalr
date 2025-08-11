import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:signalr/signalr/signalr_session_hub.dart';
import 'dart:developer' as dev;

import '../webrtc/webrtc_camera_session.dart';
import '../store/favorites_store.dart';

class CameraList extends StatefulWidget {
  const CameraList({
    super.key,
    required this.sessionHub,
    required this.favoritesOnly,
  });

  final SignalRSessionHub sessionHub;
  final bool favoritesOnly;

  @override
  State<CameraList> createState() => _CameraListState();
}

class _CameraListState extends State<CameraList> {
  final Map<String, RTCVideoRenderer> _renderers = {};
  final Map<String, WebRtcCameraSession> _sessions = {};

  final TextEditingController _filterCtrl = TextEditingController();
  String _filter = '';

  static const double _videoWidth = 320;
  static const double _videoHeight = 180;

  final FavoritesStore _favoritesStore = FavoritesStore();
  Set<String> _favorites = {};

  @override
  void initState() {
    super.initState();
    _filterCtrl.addListener(() {
      final q = _filterCtrl.text.trim();
      if (q != _filter) setState(() => _filter = q);
    });
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final favs = await _favoritesStore.loadFavorites();
    if (!mounted) return;
    setState(() {
      _favorites = favs;
    });
  }

  @override
  void dispose() {
    for (final r in _renderers.values) {
      r.srcObject = null;
      r.dispose();
    }
    for (final s in _sessions.values) {
      s.dispose();
    }
    _renderers.clear();
    _sessions.clear();
    _filterCtrl.dispose();
    super.dispose();
  }

  Future<void> _connect(String cameraId) async {
    dev.log('Connecting $cameraId...');
    final session = await widget.sessionHub.connectToCamera(cameraId);
    if (session == null) return;

    final renderer = RTCVideoRenderer();
    await renderer.initialize();

    session.onTrack = (RTCTrackEvent event) {
      if (event.streams.isEmpty) return;
      setState(() {
        renderer.srcObject = event.streams[0];
      });
      dev.log('[$cameraId] track: ${event.track.kind}');
    };

    setState(() {
      _sessions[cameraId] = session;
      _renderers[cameraId] = renderer;
    });
  }

  void _disconnect(String cameraId) {
    dev.log('Disconnecting $cameraId...');
    final renderer = _renderers.remove(cameraId);
    final session = _sessions.remove(cameraId);

    renderer?.srcObject = null;
    renderer?.dispose();
    session?.dispose();

    setState(() {});
  }

  Future<void> _toggleFavorite(String cameraId) async {
    setState(() {
      if (_favorites.contains(cameraId)) {
        _favorites.remove(cameraId);
      } else {
        _favorites.add(cameraId);
      }
    });
    await _favoritesStore.saveFavorites(_favorites);
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.sessionHub.availableProducers.toList()..sort();

    final base = widget.favoritesOnly
        ? all.where((id) => _favorites.contains(id)).toList()
        : all;

    final cameras = _filter.isEmpty
        ? base
        : base
              .where((id) => id.toLowerCase().contains(_filter.toLowerCase()))
              .toList();

    if (all.isEmpty) {
      return const Center(child: Text('No cameras available'));
    }

    return Column(
      children: [
        // Filter row: search + count (favorites toggle is in Status card)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _filterCtrl,
                  decoration: InputDecoration(
                    hintText: 'Filter by camera ID...',
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    border: const OutlineInputBorder(),
                    suffixIcon: _filter.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear',
                            icon: const Icon(Icons.clear),
                            onPressed: () => _filterCtrl.clear(),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${cameras.length}/${all.length}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: cameras.length,
            itemBuilder: (context, index) {
              final cameraId = cameras[index];
              final connected = _sessions.containsKey(cameraId);
              final renderer = _renderers[cameraId];
              final isFav = _favorites.contains(cameraId);

              return Card(
                margin: const EdgeInsets.symmetric(vertical: 6),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header row: Favorite (left) + ID + Start/Stop
                      Row(
                        children: [
                          IconButton(
                            tooltip: isFav ? 'Unfavorite' : 'Favorite',
                            icon: Icon(
                              isFav ? Icons.star : Icons.star_border,
                              color: isFav ? Colors.amber : null,
                            ),
                            onPressed: () => _toggleFavorite(cameraId),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              cameraId,
                              style: const TextStyle(fontSize: 13),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          connected
                              ? OutlinedButton.icon(
                                  onPressed: () => _disconnect(cameraId),
                                  icon: const Icon(
                                    Icons.stop,
                                    color: Colors.red,
                                  ),
                                  label: const Text('Stop'),
                                )
                              : ElevatedButton.icon(
                                  onPressed: () => _connect(cameraId),
                                  icon: const Icon(Icons.play_arrow),
                                  label: const Text('Start'),
                                ),
                        ],
                      ),
                      // Fixed-size panel, only when connected
                      if (connected && renderer != null) ...[
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: SizedBox(
                            width: _videoWidth,
                            height: _videoHeight,
                            child: Container(
                              color: Colors.black,
                              child: RTCVideoView(
                                renderer,
                                mirror: false,
                                objectFit: RTCVideoViewObjectFit
                                    .RTCVideoViewObjectFitContain,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
