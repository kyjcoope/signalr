import 'package:flutter/material.dart';
import 'package:signalr/config.dart';
import 'dart:developer' as dev;

import 'package:signalr/signalr/signalr_session_hub.dart';
import 'package:signalr/store/favorites_store.dart';
import 'camera_list.dart';

class WebRtcDisplay extends StatefulWidget {
  const WebRtcDisplay({super.key});

  @override
  State<WebRtcDisplay> createState() => _WebRtcDisplay();
}

class _WebRtcDisplay extends State<WebRtcDisplay> {
  final sessionHub = SignalRSessionHub(signalRUrl: 'https://$signalRUrl');

  bool _devicesRegistered = false;

  final _store = FavoritesStore();
  bool _favoritesOnly = false;
  bool _workingOnly = false;
  bool _pendingOnly = false;

  final GlobalKey<CameraListState> _cameraListKey =
      GlobalKey<CameraListState>();

  @override
  void initState() {
    super.initState();
    _initialize();
    _loadToggles();
  }

  @override
  void dispose() {
    sessionHub.shutdown();
    super.dispose();
  }

  Future<void> _initialize() async {
    sessionHub.onRegister = _onDevicesRegistered;
    await sessionHub.initialize();
    if (!mounted) return;
    setState(() {});
    dev.log('SignalR session initialized');
  }

  void _onDevicesRegistered() {
    dev.log(
      'Devices registered: ${sessionHub.availableProducers.length} devices available',
    );
    if (!mounted) return;
    setState(() {
      _devicesRegistered = true;
    });
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

  Widget _buildStatusControls(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isCompact = width < 600; // breakpoint for vertical layout

    final toggles = [
      _StatusToggle(
        icon: const Icon(Icons.star, color: Colors.amber, size: 18),
        label: 'Favorites',
        value: _favoritesOnly,
        onChanged: _setFavoritesOnly,
      ),
      _StatusToggle(
        icon: const Icon(Icons.hourglass_top, color: Colors.blue, size: 18),
        label: 'Pending',
        value: _pendingOnly,
        onChanged: _setPendingOnly,
      ),
      _StatusToggle(
        icon: const Icon(Icons.check_circle, color: Colors.green, size: 18),
        label: 'Working',
        value: _workingOnly,
        onChanged: _setWorkingOnly,
      ),
    ];

    if (!isCompact) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Status', style: Theme.of(context).textTheme.headlineSmall),
          const Spacer(),
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 18,
            runSpacing: 8,
            children: toggles,
          ),
        ],
      );
    }

    // Compact (mobile) layout: vertical
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Status', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final t in toggles)
              Padding(padding: const EdgeInsets.only(bottom: 8), child: t),
          ],
        ),
      ],
    );
  }

  Widget _buildActionsRow(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isCompact = width < 600;
    final buttons = [
      ElevatedButton.icon(
        onPressed: () => _cameraListKey.currentState?.connectAll(),
        icon: const Icon(Icons.play_circle_fill),
        label: const Text('Connect all'),
      ),
      OutlinedButton.icon(
        onPressed: () => _cameraListKey.currentState?.stopAll(),
        icon: const Icon(Icons.stop_circle, color: Colors.red),
        label: const Text('Stop all'),
      ),
      TextButton.icon(
        onPressed:
            () => _cameraListKey.currentState?.resetFavoritesAndWorking(),
        icon: const Icon(Icons.refresh),
        label: const Text('Reset'),
      ),
    ];

    if (!isCompact) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [Wrap(spacing: 12, runSpacing: 8, children: buttons)],
      );
    }

    // Vertical stack on compact
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final b in buttons)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Align(alignment: Alignment.centerLeft, child: b),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Card(
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      _buildStatusControls(context),
                      const SizedBox(height: 12),
                      _buildActionsRow(context),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child:
                    !_devicesRegistered
                        ? const Center(
                          child: Text('Waiting for device registration...'),
                        )
                        : CameraList(
                          key: _cameraListKey,
                          sessionHub: sessionHub,
                          favoritesOnly: _favoritesOnly,
                          workingOnly: _workingOnly,
                          pendingOnly: _pendingOnly,
                        ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StatusToggle extends StatelessWidget {
  const _StatusToggle({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final Widget icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        const SizedBox(width: 6),
        Text(label),
        const SizedBox(width: 6),
        Switch(
          value: value,
          onChanged: onChanged,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
  }
}
