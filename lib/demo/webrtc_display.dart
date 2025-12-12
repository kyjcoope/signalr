import 'package:flutter/material.dart';
import 'package:signalr/config.dart';
import 'dart:developer' as dev;

import 'package:signalr/models/models.dart';
import 'package:signalr/auth/auth.dart';
import 'package:signalr/signalr/signalr_session_hub.dart';
import 'package:signalr/store/favorites_store.dart';
import 'camera_list.dart';

/// Main display widget for WebRTC camera streams.
class WebRtcDisplay extends StatefulWidget {
  const WebRtcDisplay({super.key});

  @override
  State<WebRtcDisplay> createState() => _WebRtcDisplayState();
}

class _WebRtcDisplayState extends State<WebRtcDisplay> {
  final hub = SignalRSessionHub.instance;
  final authService = AuthService();

  bool _devicesRegistered = false;

  final _store = FavoritesStore();
  bool _favoritesOnly = false;
  bool _workingOnly = false;
  bool _pendingOnly = false;

  final GlobalKey<CameraListState> _cameraListKey =
      GlobalKey<CameraListState>();
  final ScrollController _scrollController = ScrollController();
  bool _showScrollToTop = false;

  static const double _compactBreakpoint = 600;

  @override
  void initState() {
    super.initState();
    _initialize();
    _loadToggles();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    hub.shutdown();
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
    await authService.login(
      UserLogin(
        username: username,
        password: password,
        clientName: 'driver',
        clientID: 'fb2be96f-05a3-4fea-a151-6365feaaf30c',
        clientVersion: '3.0',
        grantType: 'password',
        scopes: '[IdentityServerApi, rabbitmq-jci, api]',
        clientId_: 'jci-authui-client',
      ),
    );

    await hub.initialize('https://$url/SignalingHub', authService);

    if (!mounted) return;
    setState(() => _devicesRegistered = true);
    dev.log('SignalRSessionHub initialized');
  }

  Future<void> _loadToggles() async {
    final favOnly = await _store.loadFavoritesOnly();
    final workOnly = await _store.loadWorkingOnly();
    final pendingOnly = await _store.loadPendingOnly();
    if (!mounted) return;
    setState(() {
      _favoritesOnly = favOnly;
      _workingOnly = workOnly;
      _pendingOnly = pendingOnly;
    });
  }

  Future<void> _setFavoritesOnly(bool v) async {
    setState(() => _favoritesOnly = v);
    await _store.saveFavoritesOnly(v);
  }

  Future<void> _setWorkingOnly(bool v) async {
    setState(() => _workingOnly = v);
    await _store.saveWorkingOnly(v);
  }

  Future<void> _setPendingOnly(bool v) async {
    setState(() => _pendingOnly = v);
    await _store.savePendingOnly(v);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isCompact = width < _compactBreakpoint;

    if (!_devicesRegistered) {
      return const Center(child: CircularProgressIndicator());
    }

    // On compact screens, toolbar scrolls with content
    // On large screens, toolbar is fixed at top
    return Scaffold(
      body: isCompact ? _buildScrollingLayout() : _buildFixedToolbarLayout(),
      floatingActionButton: _showScrollToTop
          ? FloatingActionButton.small(
              onPressed: _scrollToTop,
              child: const Icon(Icons.keyboard_arrow_up),
            )
          : null,
    );
  }

  /// Layout for large screens: fixed toolbar + scrollable camera list
  Widget _buildFixedToolbarLayout() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          _ControlsToolbar(
            favoritesOnly: _favoritesOnly,
            workingOnly: _workingOnly,
            pendingOnly: _pendingOnly,
            onFavoritesChanged: _setFavoritesOnly,
            onWorkingChanged: _setWorkingOnly,
            onPendingChanged: _setPendingOnly,
            onConnectAll: () => _cameraListKey.currentState?.connectAll(),
            onStopAll: () => _cameraListKey.currentState?.stopAll(),
            onReset: () =>
                _cameraListKey.currentState?.resetFavoritesAndWorking(),
            isCompact: false,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: CameraList(
              key: _cameraListKey,
              hub: hub,
              authService: authService,
              favoritesOnly: _favoritesOnly,
              workingOnly: _workingOnly,
              pendingOnly: _pendingOnly,
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
              favoritesOnly: _favoritesOnly,
              workingOnly: _workingOnly,
              pendingOnly: _pendingOnly,
              onFavoritesChanged: _setFavoritesOnly,
              onWorkingChanged: _setWorkingOnly,
              onPendingChanged: _setPendingOnly,
              onConnectAll: () => _cameraListKey.currentState?.connectAll(),
              onStopAll: () => _cameraListKey.currentState?.stopAll(),
              onReset: () =>
                  _cameraListKey.currentState?.resetFavoritesAndWorking(),
              isCompact: true,
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          sliver: CameraListSliver(
            key: _cameraListKey,
            hub: hub,
            authService: authService,
            favoritesOnly: _favoritesOnly,
            workingOnly: _workingOnly,
            pendingOnly: _pendingOnly,
          ),
        ),
      ],
    );
  }
}

/// Compact toolbar with toggles and action buttons.
class _ControlsToolbar extends StatelessWidget {
  const _ControlsToolbar({
    required this.favoritesOnly,
    required this.workingOnly,
    required this.pendingOnly,
    required this.onFavoritesChanged,
    required this.onWorkingChanged,
    required this.onPendingChanged,
    required this.onConnectAll,
    required this.onStopAll,
    required this.onReset,
    required this.isCompact,
  });

  final bool favoritesOnly;
  final bool workingOnly;
  final bool pendingOnly;
  final ValueChanged<bool> onFavoritesChanged;
  final ValueChanged<bool> onWorkingChanged;
  final ValueChanged<bool> onPendingChanged;
  final VoidCallback onConnectAll;
  final VoidCallback onStopAll;
  final VoidCallback onReset;
  final bool isCompact;

  @override
  Widget build(BuildContext context) {
    if (isCompact) {
      return _buildCompactToolbar(context);
    }
    return _buildWideToolbar(context);
  }

  Widget _buildWideToolbar(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // Toggles
            _CompactToggle(
              icon: Icons.star,
              color: Colors.amber,
              value: favoritesOnly,
              onChanged: onFavoritesChanged,
              tooltip: 'Favorites only',
            ),
            const SizedBox(width: 8),
            _CompactToggle(
              icon: Icons.hourglass_top,
              color: Colors.blue,
              value: pendingOnly,
              onChanged: onPendingChanged,
              tooltip: 'Pending only',
            ),
            const SizedBox(width: 8),
            _CompactToggle(
              icon: Icons.check_circle,
              color: Colors.green,
              value: workingOnly,
              onChanged: onWorkingChanged,
              tooltip: 'Working only',
            ),
            const Spacer(),
            // Actions
            ElevatedButton.icon(
              onPressed: onConnectAll,
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('Connect All'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: onStopAll,
              icon: const Icon(Icons.stop, size: 18, color: Colors.red),
              label: const Text('Stop All'),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: onReset,
              icon: const Icon(Icons.refresh),
              tooltip: 'Reset',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactToolbar(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            // Toggles - compact icon buttons
            _CompactToggle(
              icon: Icons.star,
              color: Colors.amber,
              value: favoritesOnly,
              onChanged: onFavoritesChanged,
              tooltip: 'Favorites',
            ),
            _CompactToggle(
              icon: Icons.hourglass_top,
              color: Colors.blue,
              value: pendingOnly,
              onChanged: onPendingChanged,
              tooltip: 'Pending',
            ),
            _CompactToggle(
              icon: Icons.check_circle,
              color: Colors.green,
              value: workingOnly,
              onChanged: onWorkingChanged,
              tooltip: 'Working',
            ),
            const Spacer(),
            // Actions - icon buttons on mobile
            IconButton(
              onPressed: onConnectAll,
              icon: const Icon(Icons.play_arrow, color: Colors.green),
              tooltip: 'Connect All',
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              onPressed: onStopAll,
              icon: const Icon(Icons.stop, color: Colors.red),
              tooltip: 'Stop All',
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              onPressed: onReset,
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
