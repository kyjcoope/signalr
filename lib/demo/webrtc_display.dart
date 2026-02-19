import 'package:flutter/material.dart';
import 'package:flutter_redux/flutter_redux.dart';
import 'package:redux/redux.dart';

import 'package:signalr/auth/auth.dart';
import 'package:signalr/signalr/signalr_session_hub.dart';
import 'package:signalr/redux/app_state.dart';
import 'package:signalr/redux/thunks.dart';
import 'camera_list.dart';

/// Main display widget for WebRTC camera streams.
class WebRtcDisplay extends StatefulWidget {
  const WebRtcDisplay({super.key});

  @override
  State<WebRtcDisplay> createState() => _WebRtcDisplayState();
}

class _WebRtcDisplayState extends State<WebRtcDisplay> {
  final _authService = AuthService();

  final GlobalKey<CameraListState> _cameraListKey =
      GlobalKey<CameraListState>();
  final ScrollController _scrollController = ScrollController();
  bool _showScrollToTop = false;

  static const double _compactBreakpoint = 600;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _initialize();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    SignalRSessionHub.instance.shutdown();
    super.dispose();
  }

  void _onScroll() {
    final show = _scrollController.offset > 200;
    if (show != _showScrollToTop) {
      setState(() => _showScrollToTop = show);
    }
  }

  void _scrollToTop() {
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Future<void> _initialize() async {
    final store = StoreProvider.of<AppState>(context, listen: false);
    store.dispatch(loginAndInitHub(authService: _authService));
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isCompact = width < _compactBreakpoint;

    return StoreConnector<AppState, bool>(
      converter: (store) => store.state.cameras.isLoaded,
      builder: (context, hasCameras) {
        return Scaffold(
          body: isCompact
              ? _buildScrollingLayout()
              : _buildFixedToolbarLayout(),
          floatingActionButton: _showScrollToTop
              ? FloatingActionButton.small(
                  onPressed: _scrollToTop,
                  child: const Icon(Icons.keyboard_arrow_up),
                )
              : null,
        );
      },
    );
  }

  /// Layout for large screens: fixed toolbar + scrollable camera list
  Widget _buildFixedToolbarLayout() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          _ControlsToolbar(
            cameraListKey: _cameraListKey,
            authService: _authService,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: CameraList(
              key: _cameraListKey,
              authService: _authService,
              scrollController: _scrollController,
            ),
          ),
        ],
      ),
    );
  }

  /// Layout for compact screens: everything scrolls together
  Widget _buildScrollingLayout() {
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: _ControlsToolbar(
              cameraListKey: _cameraListKey,
              authService: _authService,
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          sliver: CameraListSliver(
            key: _cameraListKey,
            authService: _authService,
          ),
        ),
      ],
    );
  }
}

/// Compact toolbar with toggles and action buttons — now Redux-connected.
class _ControlsToolbar extends StatelessWidget {
  const _ControlsToolbar({
    required this.cameraListKey,
    required this.authService,
  });

  final GlobalKey<CameraListState> cameraListKey;
  final AuthService authService;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isCompact = width < 600;

    return StoreConnector<AppState, _ToolbarVM>(
      converter: (store) => _ToolbarVM.fromStore(store, authService),
      builder: (context, vm) {
        if (isCompact) {
          return _buildCompact(context, vm);
        }
        return _buildWide(context, vm);
      },
    );
  }

  /// Status dot: red=idle/error, amber=connecting, green=connected.
  Widget _statusDot(ServerStatus status) {
    final Color color;
    final String tooltip;
    switch (status) {
      case ServerStatus.idle:
        color = Colors.grey;
        tooltip = 'Not connected';
        break;
      case ServerStatus.connecting:
        color = Colors.amber;
        tooltip = 'Connecting…';
        break;
      case ServerStatus.connected:
        color = Colors.green;
        tooltip = 'Connected';
        break;
      case ServerStatus.error:
        color = Colors.red;
        tooltip = 'Connection error';
        break;
    }
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      ),
    );
  }

  Widget _buildWide(BuildContext context, _ToolbarVM vm) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            _statusDot(vm.serverStatus),
            const SizedBox(width: 12),
            _CompactToggle(
              icon: Icons.star,
              color: Colors.amber,
              value: vm.favoritesOnly,
              onChanged: vm.onFavoritesChanged,
              tooltip: 'Favorites only',
            ),
            const SizedBox(width: 8),
            _CompactToggle(
              icon: Icons.hourglass_top,
              color: Colors.blue,
              value: vm.pendingOnly,
              onChanged: vm.onPendingChanged,
              tooltip: 'Pending only',
            ),
            const SizedBox(width: 8),
            _CompactToggle(
              icon: Icons.check_circle,
              color: Colors.green,
              value: vm.workingOnly,
              onChanged: vm.onWorkingChanged,
              tooltip: 'Working only',
            ),
            const Spacer(),
            if (vm.isFetching)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            OutlinedButton.icon(
              onPressed: vm.canFetch ? vm.onFetchCameras : null,
              icon: const Icon(Icons.cloud_download, size: 18),
              label: const Text('Fetch Cameras'),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: vm.canFetch
                  ? () => cameraListKey.currentState?.connectAll()
                  : null,
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('Connect All'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => cameraListKey.currentState?.stopAll(),
              icon: const Icon(Icons.stop, size: 18, color: Colors.red),
              label: const Text('Stop All'),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: () =>
                  cameraListKey.currentState?.resetFavoritesAndWorking(),
              icon: const Icon(Icons.refresh),
              tooltip: 'Reset',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompact(BuildContext context, _ToolbarVM vm) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            _statusDot(vm.serverStatus),
            const SizedBox(width: 8),
            _CompactToggle(
              icon: Icons.star,
              color: Colors.amber,
              value: vm.favoritesOnly,
              onChanged: vm.onFavoritesChanged,
              tooltip: 'Favorites',
            ),
            _CompactToggle(
              icon: Icons.hourglass_top,
              color: Colors.blue,
              value: vm.pendingOnly,
              onChanged: vm.onPendingChanged,
              tooltip: 'Pending',
            ),
            _CompactToggle(
              icon: Icons.check_circle,
              color: Colors.green,
              value: vm.workingOnly,
              onChanged: vm.onWorkingChanged,
              tooltip: 'Working',
            ),
            const Spacer(),
            if (vm.isFetching)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            IconButton(
              onPressed: vm.canFetch ? vm.onFetchCameras : null,
              icon: const Icon(Icons.cloud_download),
              tooltip: 'Fetch Cameras',
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              onPressed: vm.canFetch
                  ? () => cameraListKey.currentState?.connectAll()
                  : null,
              icon: const Icon(Icons.play_arrow, color: Colors.green),
              tooltip: 'Connect All',
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              onPressed: () => cameraListKey.currentState?.stopAll(),
              icon: const Icon(Icons.stop, color: Colors.red),
              tooltip: 'Stop All',
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              onPressed: () =>
                  cameraListKey.currentState?.resetFavoritesAndWorking(),
              icon: const Icon(Icons.refresh),
              tooltip: 'Reset',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolbarVM {
  final bool favoritesOnly;
  final bool workingOnly;
  final bool pendingOnly;
  final ServerStatus serverStatus;
  final bool isFetching;
  final void Function(bool) onFavoritesChanged;
  final void Function(bool) onWorkingChanged;
  final void Function(bool) onPendingChanged;
  final VoidCallback onFetchCameras;

  /// Fetch/connect buttons enabled only when server is connected and not mid-fetch.
  bool get canFetch => serverStatus == ServerStatus.connected && !isFetching;

  _ToolbarVM({
    required this.favoritesOnly,
    required this.workingOnly,
    required this.pendingOnly,
    required this.serverStatus,
    required this.isFetching,
    required this.onFavoritesChanged,
    required this.onWorkingChanged,
    required this.onPendingChanged,
    required this.onFetchCameras,
  });

  static _ToolbarVM fromStore(Store<AppState> store, AuthService authService) {
    final filters = store.state.filters;
    final auth = store.state.auth;
    return _ToolbarVM(
      favoritesOnly: filters.favoritesOnly,
      workingOnly: filters.workingOnly,
      pendingOnly: filters.pendingOnly,
      serverStatus: auth.serverStatus,
      isFetching: auth.isFetchingCameras,
      onFavoritesChanged: (v) => store.dispatch(setFavoritesOnlyAndPersist(v)),
      onWorkingChanged: (v) => store.dispatch(setWorkingOnlyAndPersist(v)),
      onPendingChanged: (v) => store.dispatch(setPendingOnlyAndPersist(v)),
      onFetchCameras: () =>
          store.dispatch(fetchCameras(authService: authService)),
    );
  }
}

/// Compact toggle button (icon that lights up when active).
class _CompactToggle extends StatelessWidget {
  const _CompactToggle({
    required this.icon,
    required this.color,
    required this.value,
    required this.onChanged,
    required this.tooltip,
  });

  final IconData icon;
  final Color color;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: () => onChanged(!value),
      icon: Icon(icon, color: value ? color : Colors.grey.shade400),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
    );
  }
}
