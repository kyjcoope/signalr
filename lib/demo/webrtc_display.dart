import 'package:flutter/material.dart';
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
  final sessionHub = SignalRSessionHub(
    signalRUrl: 'https://jci-osp-api-gateway-dev.osp-jci.com/SignalingHub',
  );

  bool _isInitialized = false;
  bool _devicesRegistered = false;

  final _favoritesStore = FavoritesStore();
  bool _favoritesOnly = false;

  @override
  void initState() {
    super.initState();
    _initialize();
    _loadFavoritesOnly();
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
    setState(() {
      _isInitialized = true;
    });
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

  Future<void> _loadFavoritesOnly() async {
    final favOnly = await _favoritesStore.loadFavoritesOnly();
    if (!mounted) return;
    setState(() => _favoritesOnly = favOnly);
  }

  Future<void> _setFavoritesOnly(bool v) async {
    setState(() => _favoritesOnly = v);
    await _favoritesStore.saveFavoritesOnly(v);
  }

  @override
  Widget build(BuildContext context) {
    final devicesCount = sessionHub.availableProducers.length;

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  // Header: Status (left) + settings (right)
                  Row(
                    children: [
                      Text(
                        'Status',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const Spacer(),
                      Row(
                        children: [
                          const Icon(Icons.star, color: Colors.amber, size: 18),
                          const SizedBox(width: 6),
                          const Text('Favorites only'),
                          const SizedBox(width: 6),
                          Switch(
                            value: _favoritesOnly,
                            onChanged: _setFavoritesOnly,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        _isInitialized ? Icons.check_circle : Icons.pending,
                        color: _isInitialized ? Colors.green : Colors.orange,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'SignalR: ${_isInitialized ? "Connected" : "Connecting..."}',
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        _devicesRegistered ? Icons.check_circle : Icons.pending,
                        color: _devicesRegistered
                            ? Colors.green
                            : Colors.orange,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _devicesRegistered
                            ? 'Devices: $devicesCount registered'
                            : 'Devices: Registering...',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: !_devicesRegistered
                ? const Center(
                    child: Text('Waiting for device registration...'),
                  )
                : CameraList(
                    sessionHub: sessionHub,
                    favoritesOnly: _favoritesOnly,
                  ),
          ),
        ],
      ),
    );
  }
}
