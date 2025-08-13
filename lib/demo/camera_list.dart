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
    required this.workingOnly,
  });

  final SignalRSessionHub sessionHub;
  final bool favoritesOnly;
  final bool workingOnly;

  @override
  CameraListState createState() => CameraListState();
}

class CameraListState extends State<CameraList> {
  final Map<String, RTCVideoRenderer> _renderers = {};
  final Map<String, WebRtcCameraSession> _sessions = {};

  final TextEditingController _filterCtrl = TextEditingController();
  String _filter = '';

  static const double _videoWidth = 320;
  static const double _videoHeight = 180;

  final FavoritesStore _store = FavoritesStore();
  Set<String> _favorites = {};
  Set<String> _working = {};

  @override
  void initState() {
    super.initState();
    _filterCtrl.addListener(() {
      final q = _filterCtrl.text.trim();
      if (q != _filter) setState(() => _filter = q);
    });
    _loadPersisted();
  }

  Future<void> _loadPersisted() async {
    final favs = await _store.loadFavorites();
    final working = await _store.loadWorking();
    if (!mounted) return;
    setState(() {
      _favorites = favs;
      _working = working;
    });
  }

  Future<void> resetFavoritesAndWorking() async {
    setState(() {
      _favorites.clear();
      _working.clear();
    });
    await _store.saveFavorites(_favorites);
    await _store.saveWorking(_working);
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

  List<String> _visibleCameras() {
    final all = widget.sessionHub.availableProducers.toList()..sort();

    List<String> base = all;
    if (widget.favoritesOnly) {
      base = base.where((id) => _favorites.contains(id)).toList();
    }
    if (widget.workingOnly) {
      base = base.where((id) => _working.contains(id)).toList();
    }

    final filtered =
        _filter.isEmpty
            ? base
            : base
                .where((id) => id.toLowerCase().contains(_filter.toLowerCase()))
                .toList();

    return filtered;
  }

  Future<void> connectAll() async {
    final targets = _visibleCameras();
    for (final id in targets) {
      if (!_sessions.containsKey(id)) {
        await _connect(id);
      }
    }
  }

  Future<void> stopAll() async {
    final ids = _sessions.keys.toList();
    for (final id in ids) {
      _disconnect(id);
    }
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

    session.onLocalIceCandidate = () async {
      if (!_working.contains(cameraId)) {
        setState(() {
          _working.add(cameraId);
        });
        await _store.saveWorking(_working);
      }
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
    await _store.saveFavorites(_favorites);
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.sessionHub.availableProducers.toList()..sort();
    final cameras = _visibleCameras();

    if (all.isEmpty) {
      return const Center(child: Text('No cameras available'));
    }

    return Column(
      children: [
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
                    suffixIcon:
                        _filter.isEmpty
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
              final isWorking = _working.contains(cameraId);

              return Card(
                margin: const EdgeInsets.symmetric(vertical: 6),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
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
                          if (isWorking) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.green.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.green),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: const [
                                  Icon(
                                    Icons.check_circle,
                                    color: Colors.green,
                                    size: 14,
                                  ),
                                  SizedBox(width: 4),
                                  Text(
                                    'Working',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.green,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(width: 8),
                          connected
                              ? OutlinedButton.icon(
                                onPressed: () => _disconnect(cameraId),
                                icon: const Icon(Icons.stop, color: Colors.red),
                                label: const Text('Stop'),
                              )
                              : ElevatedButton.icon(
                                onPressed: () => _connect(cameraId),
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('Start'),
                              ),
                        ],
                      ),
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
                                objectFit:
                                    RTCVideoViewObjectFit
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
