import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:signalr/demo/camera_list_item.dart';
import 'package:signalr/auth/auth.dart';
import 'dart:developer' as dev;

import '../signalr/signalr_session_hub.dart';
import '../store/favorites_store.dart';

/// Camera list widget for fixed toolbar layout.
class CameraList extends StatefulWidget {
  const CameraList({
    super.key,
    required this.hub,
    required this.authService,
    required this.favoritesOnly,
    required this.workingOnly,
    required this.pendingOnly,
    this.scrollController,
  });

  final SignalRSessionHub hub;
  final AuthService authService;
  final bool favoritesOnly;
  final bool workingOnly;
  final bool pendingOnly;
  final ScrollController? scrollController;

  @override
  CameraListState createState() => CameraListState();
}

/// Camera list as a sliver for scrolling toolbar layout.
class CameraListSliver extends StatefulWidget {
  const CameraListSliver({
    super.key,
    required this.hub,
    required this.authService,
    required this.favoritesOnly,
    required this.workingOnly,
    required this.pendingOnly,
  });

  final SignalRSessionHub hub;
  final AuthService authService;
  final bool favoritesOnly;
  final bool workingOnly;
  final bool pendingOnly;

  @override
  CameraListState createState() => CameraListState();
}

/// Shared state for both CameraList and CameraListSliver.
class CameraListState extends State<StatefulWidget> {
  // Renderers are kept local - they're a UI concern
  final Map<String, RTCVideoRenderer> _renderers = {};

  final TextEditingController _filterCtrl = TextEditingController();
  String _filter = '';

  static const double _compactBreakpoint = 600;

  final FavoritesStore _store = FavoritesStore();
  Set<String> _favorites = {};
  final Set<String> _working = {};
  final Set<String> _pending = {};
  final Map<String, String> _codec = {};

  // Access widget properties dynamically
  SignalRSessionHub get _hub {
    final w = widget;
    if (w is CameraList) return w.hub;
    if (w is CameraListSliver) return w.hub;
    throw StateError('Invalid widget type');
  }

  AuthService get _auth {
    final w = widget;
    if (w is CameraList) return w.authService;
    if (w is CameraListSliver) return w.authService;
    throw StateError('Invalid widget type');
  }

  bool get _favoritesOnly {
    final w = widget;
    if (w is CameraList) return w.favoritesOnly;
    if (w is CameraListSliver) return w.favoritesOnly;
    return false;
  }

  bool get _workingOnly {
    final w = widget;
    if (w is CameraList) return w.workingOnly;
    if (w is CameraListSliver) return w.workingOnly;
    return false;
  }

  bool get _pendingOnly {
    final w = widget;
    if (w is CameraList) return w.pendingOnly;
    if (w is CameraListSliver) return w.pendingOnly;
    return false;
  }

  ScrollController? get _scrollController {
    final w = widget;
    if (w is CameraList) return w.scrollController;
    return null;
  }

  @override
  void initState() {
    super.initState();
    _filterCtrl.addListener(() {
      final q = _filterCtrl.text.trim();
      if (q != _filter) setState(() => _filter = q);
    });
    _loadFavorites();
    _syncExistingSessions();
  }

  /// Sync UI state with any existing sessions in the hub.
  /// This enables session persistence across page navigation.
  void _syncExistingSessions() {
    for (final entry in _hub.activeSessions.entries) {
      final cameraId = entry.key;
      final session = entry.value;

      // Create renderer for existing session
      if (!_renderers.containsKey(cameraId)) {
        _initRendererForSession(cameraId, session.remoteStream);
      }

      // Mark as working if connected
      if (session.remoteStream != null) {
        _working.add(cameraId);
      }
    }
  }

  Future<void> _initRendererForSession(
    String cameraId,
    MediaStream? stream,
  ) async {
    if (_renderers.containsKey(cameraId)) return;

    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    renderer.srcObject = stream;

    if (mounted) {
      setState(() => _renderers[cameraId] = renderer);
    }
  }

  Future<void> _loadFavorites() async {
    final favs = await _store.loadFavorites();
    if (!mounted) return;
    setState(() => _favorites = favs);
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
    // Only dispose renderers - sessions are managed by hub
    for (final r in _renderers.values) {
      r.srcObject = null;
      r.dispose();
    }
    _renderers.clear();
    _filterCtrl.dispose();
    super.dispose();
  }

  Iterable<String> get _availableProducers => _auth.devices.keys;

  List<String> _visibleCameras() {
    var base = _availableProducers.toList()..sort();

    if (_favoritesOnly) {
      base = base.where((id) => _favorites.contains(id)).toList();
    }

    bool isWorkingNow(String id) =>
        _working.contains(id) && _hub.isConnected(id);

    if (_workingOnly && _pendingOnly) {
      base = base
          .where((id) => isWorkingNow(id) || _pending.contains(id))
          .toList();
    } else if (_workingOnly) {
      base = base.where(isWorkingNow).toList();
    } else if (_pendingOnly) {
      base = base.where((id) => _pending.contains(id)).toList();
    }

    if (_filter.isNotEmpty) {
      final f = _filter.toLowerCase();
      base = base.where((id) {
        final name = _auth.devices[id]?.name.toLowerCase() ?? '';
        return id.toLowerCase().contains(f) || name.contains(f);
      }).toList();
    }

    return base;
  }

  Future<void> connectAll() async {
    final targets = _visibleCameras();
    for (final id in targets) {
      if (!_hub.isConnected(id)) {
        await _connect(id);
      }
    }
  }

  Future<void> stopAll() async {
    final ids = _hub.connectedCameraIds.toList();
    for (final id in ids) {
      await _disconnect(id);
    }
  }

  Future<void> _connect(String cameraId) async {
    dev.log('Connecting $cameraId...');

    // Initialize renderer first
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    setState(() => _renderers[cameraId] = renderer);

    // Connect via hub - session is managed there
    final session = await _hub.connectToCamera(cameraId);
    if (session == null) {
      // Failed to connect, cleanup renderer
      renderer.dispose();
      setState(() => _renderers.remove(cameraId));
      return;
    }

    // Set up callbacks
    session.onTrack = (RTCTrackEvent event) {
      if (event.streams.isEmpty) return;
      // Use the stored remoteStream from session
      setState(() => renderer.srcObject = session.remoteStream);
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
  }

  Future<void> _disconnect(String cameraId) async {
    // Disconnect via hub
    await _hub.disconnectCamera(cameraId);

    // Cleanup local renderer
    final renderer = _renderers.remove(cameraId);
    renderer?.srcObject = null;
    renderer?.dispose();

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
    // Dispatch to correct build method based on widget type
    if (widget is CameraListSliver) {
      return _buildSliver(context);
    }
    return _buildList(context);
  }

  Widget _buildList(BuildContext context) {
    final all = _availableProducers.toList()..sort();
    final cameras = _visibleCameras();

    if (all.isEmpty) {
      return const Center(child: Text('No cameras available'));
    }

    final width = MediaQuery.of(context).size.width;
    final compact = width < _compactBreakpoint;

    return Column(
      children: [
        _buildFilterRow(all.length, cameras.length),
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            itemCount: cameras.length,
            itemBuilder: (context, index) =>
                _buildCameraItem(cameras[index], compact),
          ),
        ),
      ],
    );
  }

  Widget _buildSliver(BuildContext context) {
    final all = _availableProducers.toList()..sort();
    final cameras = _visibleCameras();
    final width = MediaQuery.of(context).size.width;
    final compact = width < _compactBreakpoint;

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(child: _buildFilterRow(all.length, cameras.length)),
        if (cameras.isEmpty)
          const SliverFillRemaining(
            child: Center(child: Text('No cameras available')),
          )
        else
          SliverList.builder(
            itemCount: cameras.length,
            itemBuilder: (context, index) =>
                _buildCameraItem(cameras[index], compact),
          ),
      ],
    );
  }

  Widget _buildFilterRow(int total, int visible) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _filterCtrl,
              decoration: InputDecoration(
                hintText: 'Filter cameras...',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: const OutlineInputBorder(),
                suffixIcon: _filter.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => _filterCtrl.clear(),
                      ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text('$visible/$total', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _buildCameraItem(String cameraId, bool compact) {
    final connected = _hub.isConnected(cameraId);
    final renderer = _renderers[cameraId];
    final isFav = _favorites.contains(cameraId);
    final device = _auth.devices[cameraId];
    final name = device?.name ?? 'Unknown Camera';
    final type = device?.sourceType ?? 'Unknown Type';
    final session = _hub.getSession(cameraId);
    final codec = _codec[cameraId] ?? session?.negotiatedVideoCodec ?? '—';

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
  }
}
