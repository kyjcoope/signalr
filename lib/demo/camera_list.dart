import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:signalr/demo/camera_list_item.dart';
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
    required this.pendingOnly,
  });

  final SignalRSessionHub sessionHub;
  final bool favoritesOnly;
  final bool workingOnly;
  final bool pendingOnly;

  @override
  CameraListState createState() => CameraListState();
}

class CameraListState extends State<CameraList> {
  final Map<String, RTCVideoRenderer> _renderers = {};
  final Map<String, WebRtcCameraSession> _sessions = {};

  final TextEditingController _filterCtrl = TextEditingController();
  String _filter = '';

  static const double _compactBreakpoint = 600;

  final FavoritesStore _store = FavoritesStore();
  Set<String> _favorites = {};
  final Set<String> _working = {};
  final Set<String> _pending = {};
  final Map<String, String> _codec = {};

  @override
  void initState() {
    super.initState();
    _filterCtrl.addListener(() {
      final q = _filterCtrl.text.trim();
      if (q != _filter) setState(() => _filter = q);
    });
    _loadFavorites();
  }

  Future<void> _loadFavorites() async {
    final favs = await _store.loadFavorites();
    if (!mounted) return;
    setState(() {
      _favorites = favs;
    });
  }

  Future<void> resetFavoritesAndWorking() async {
    setState(() {
      _favorites.clear();
      _working.clear();
      _pending.clear();
      _codec.clear();
    });
    await _store.saveFavorites(_favorites);
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

    bool isWorkingNow(String id) =>
        _working.contains(id) && _sessions.containsKey(id);

    if (widget.workingOnly && widget.pendingOnly) {
      base =
          base
              .where((id) => isWorkingNow(id) || _pending.contains(id))
              .toList();
    } else if (widget.workingOnly) {
      base = base.where(isWorkingNow).toList();
    } else if (widget.pendingOnly) {
      base = base.where((id) => _pending.contains(id)).toList();
    }

    if (_filter.isNotEmpty) {
      final f = _filter.toLowerCase();
      base =
          base.where((id) {
            final name =
                widget.sessionHub.authService.devices[id]?.name.toLowerCase() ??
                '';
            return id.toLowerCase().contains(f) || name.contains(f);
          }).toList();
    }

    return base;
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
      await _disconnect(id);
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
      setState(() => renderer.srcObject = event.streams[0]);
    };

    session.onLocalIceCandidate = () {
      if (!_pending.contains(cameraId) && !_working.contains(cameraId)) {
        setState(() => _pending.add(cameraId));
      }
    };
    session.onRemoteIceCandidate = () {
      if (!_pending.contains(cameraId) && !_working.contains(cameraId)) {
        setState(() => _pending.add(cameraId));
      }
    };

    session.onConnectionComplete = () {
      if (_pending.remove(cameraId) || !_working.contains(cameraId)) {
        setState(() => _working.add(cameraId));
      }
    };

    session.onVideoCodecResolved = (codec) {
      setState(() => _codec[cameraId] = codec);
    };

    setState(() {
      _sessions[cameraId] = session;
      _renderers[cameraId] = renderer;
    });
  }

  Future<void> _disconnect(String cameraId) async {
    await widget.sessionHub.disconnectCamera(cameraId);
    final renderer = _renderers.remove(cameraId);
    renderer?.srcObject = null;
    renderer?.dispose();
    _sessions.remove(cameraId);
    setState(() {
      _pending.remove(cameraId);
      _working.remove(cameraId);
      _codec.remove(cameraId);
    });
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

    final width = MediaQuery.of(context).size.width;
    final compact = width < _compactBreakpoint;

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
                    hintText: 'Filter by camera ID / name...',
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
              final device = widget.sessionHub.authService.devices[cameraId];
              final name = device?.name ?? 'Unknown Camera';
              final type = device?.sourceType ?? 'Unknown Type';
              final codec =
                  _codec[cameraId] ??
                  _sessions[cameraId]?.negotiatedVideoCodec ??
                  '—';

              return CameraListItem(
                cameraId: cameraId,
                name: name,
                type: type,
                codec: codec,
                connected: connected,
                isFav: isFav,
                isPending: _pending.contains(cameraId),
                isWorking: _working.contains(cameraId) && connected,
                renderer: renderer,
                onConnect: () => _connect(cameraId),
                onDisconnect: () => _disconnect(cameraId),
                onToggleFavorite: () => _toggleFavorite(cameraId),
                compact: compact,
              );
            },
          ),
        ),
      ],
    );
  }
}
