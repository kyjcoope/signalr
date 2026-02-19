import 'package:flutter/material.dart';
import 'package:flutter_redux/flutter_redux.dart';
import 'package:redux/redux.dart';
import 'package:signalr/demo/camera_list_item.dart';
import 'package:signalr/auth/auth.dart';

import '../signalr/signalr_session_hub.dart';
import '../redux/app_state.dart';
import '../redux/actions.dart';
import '../redux/selectors.dart';
import '../redux/thunks.dart' as thunks;

/// Camera list widget for fixed toolbar layout.
class CameraList extends StatefulWidget {
  const CameraList({
    super.key,
    required this.authService,
    this.scrollController,
  });

  final AuthService authService;
  final ScrollController? scrollController;

  @override
  CameraListState createState() => CameraListState();
}

/// Camera list as a sliver for scrolling toolbar layout.
class CameraListSliver extends StatefulWidget {
  const CameraListSliver({super.key, required this.authService});

  final AuthService authService;

  @override
  CameraListState createState() => CameraListState();
}

/// Shared state for both CameraList and CameraListSliver.
///
/// Uses Redux store for camera/session/favorites/filter state.
/// The SignalRSessionHub singleton still manages renderers + sessions directly.
class CameraListState extends State<StatefulWidget> {
  final TextEditingController _filterCtrl = TextEditingController();

  static const double _compactBreakpoint = 600;

  final _hub = SignalRSessionHub.instance;

  ScrollController? get _scrollController {
    final w = widget;
    if (w is CameraList) return w.scrollController;
    return null;
  }

  Store<AppState> get _store =>
      StoreProvider.of<AppState>(context, listen: false);

  @override
  void initState() {
    super.initState();
    _filterCtrl.addListener(() {
      final q = _filterCtrl.text.trim();
      _store.dispatch(SetSearchQuery(q));
    });
  }

  @override
  void dispose() {
    _filterCtrl.dispose();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Public API (called from toolbar via GlobalKey)
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> connectAll() async {
    _store.dispatch(thunks.connectAllVisible());
  }

  Future<void> stopAll() async {
    _store.dispatch(thunks.stopAll());
  }

  Future<void> resetFavoritesAndWorking() async {
    _store.dispatch(thunks.resetFavoritesAndWorking());
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Build
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    if (widget is CameraListSliver) {
      return _buildSliver(context);
    }
    return _buildList(context);
  }

  Widget _buildList(BuildContext context) {
    return StoreConnector<AppState, _CameraListVM>(
      converter: _CameraListVM.fromStore,
      builder: (context, vm) {
        if (vm.allSlugs.isEmpty) {
          return const Center(child: Text('No cameras available'));
        }

        final width = MediaQuery.of(context).size.width;
        final compact = width < _compactBreakpoint;

        return Column(
          children: [
            _buildFilterRow(vm.allSlugs.length, vm.visibleSlugs.length),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                itemCount: vm.visibleSlugs.length,
                itemBuilder: (context, index) =>
                    _buildCameraItem(vm.visibleSlugs[index], compact, vm),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSliver(BuildContext context) {
    return StoreConnector<AppState, _CameraListVM>(
      converter: _CameraListVM.fromStore,
      builder: (context, vm) {
        final width = MediaQuery.of(context).size.width;
        final compact = width < _compactBreakpoint;

        return SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: _buildFilterRow(
                vm.allSlugs.length,
                vm.visibleSlugs.length,
              ),
            ),
            if (vm.visibleSlugs.isEmpty)
              const SliverFillRemaining(
                child: Center(child: Text('No cameras available')),
              )
            else
              SliverList.builder(
                itemCount: vm.visibleSlugs.length,
                itemBuilder: (context, index) =>
                    _buildCameraItem(vm.visibleSlugs[index], compact, vm),
              ),
          ],
        );
      },
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
                suffixIcon: _filterCtrl.text.isEmpty
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

  Widget _buildCameraItem(String slug, bool compact, _CameraListVM vm) {
    final store = _store;
    final state = store.state;
    final device = selectDevice(state, slug);
    final session = getWebRtcSession(state, slug);
    final connected = isWebRtcConnected(state, slug);
    final isPending = isWebRtcPending(state, slug);
    final isWorking = connected;
    final isFav = selectIsFavorite(state, slug);
    final name = device?.name ?? 'Unknown Camera';
    final type = device?.sourceType ?? 'Unknown Type';

    // Codec — use the active track's codec
    final activeTrack = _hub.getActiveVideoTrack(slug);
    final codec =
        _hub.getVideoTrackCodec(slug, activeTrack) ??
        session?.negotiatedCodec ??
        '—';

    // Renderer + textureId — still from hub (not in Redux)
    final renderer = _hub.getRenderer(slug);
    final textureId = _hub.getTextureId(slug);

    // Track info
    final trackInfo = selectTrackInfo(state, slug);

    return CameraListItem(
      cameraId: slug,
      name: name,
      type: type,
      codec: codec,
      connected: connected,
      isFav: isFav,
      isPending: isPending,
      isWorking: isWorking,
      textureId: textureId,
      renderer: renderer,
      onConnect: () => store.dispatch(thunks.connectCamera(slug)),
      onDisconnect: () => store.dispatch(thunks.disconnectCamera(slug)),
      onToggleFavorite: () =>
          store.dispatch(thunks.toggleFavoriteAndPersist(slug)),
      compact: compact,
      statsNotifier: _hub.getStatsNotifier(slug),
      trackInfo: trackInfo,
      videoTrackCount: session?.videoTrackCount ?? 0,
      activeVideoTrack: session?.activeVideoTrack ?? 0,
      onSwitchTrack: (index) =>
          store.dispatch(thunks.switchVideoTrack(slug, index)),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// View Model
// ═══════════════════════════════════════════════════════════════════════════

class _CameraListVM {
  final List<String> allSlugs;
  final List<String> visibleSlugs;

  _CameraListVM({required this.allSlugs, required this.visibleSlugs});

  static _CameraListVM fromStore(Store<AppState> store) {
    return _CameraListVM(
      allSlugs: selectAllSlugs(store.state),
      visibleSlugs: selectVisibleCameras(store.state),
    );
  }
}
