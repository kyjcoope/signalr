import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:signalr/signalr/signalr_session_hub.dart';

import 'dart:developer' as dev;

import '../webrtc/webrtc_camera_session.dart';

class WebRtcDisplay extends StatefulWidget {
  const WebRtcDisplay({super.key});
  @override
  State<WebRtcDisplay> createState() => _WebRtcDisplay();
}

class _WebRtcDisplay extends State<WebRtcDisplay> {
  final sessionHub = SignalRSessionHub(
    signalRUrl: 'https://jci-osp-api-gateway-dev.osp-jci.com/SignalingHub',
  );

  final Map<String, RTCVideoRenderer> renderers = {};
  final Map<String, WebRtcCameraSession> cameraSessions = {};

  final List<String> desiredCameras = ['exacqu-H110E1-2'];

  bool _isInitialized = false;
  bool _devicesRegistered = false;
  bool _camerasConnected = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    // Dispose all renderers
    for (var renderer in renderers.values) {
      renderer.dispose();
    }
    sessionHub.shutdown();
    super.dispose();
  }

  void _initialize() async {
    sessionHub.onRegister = _onDevicesRegistered;
    await sessionHub.initialize();
    setState(() {
      _isInitialized = true;
    });
    dev.log('SignalR session initialized');
  }

  void _onDevicesRegistered() {
    dev.log(
      'Devices registered: ${sessionHub.availableProducers.length} devices available',
    );
    setState(() {
      _devicesRegistered = true;
    });
  }

  Future<void> _connectToCameras() async {
    if (!_devicesRegistered) {
      dev.log('Cannot connect - devices not yet registered');
      return;
    }

    dev.log('Connecting to cameras...');
    setState(() {
      _camerasConnected = false; // Reset state
    });

    for (String cameraId in desiredCameras) {
      final cameraSession = await sessionHub.connectToCamera(cameraId);
      if (cameraSession != null) {
        // Create renderer for this camera
        final renderer = RTCVideoRenderer();
        await renderer.initialize();

        renderers[cameraId] = renderer;
        cameraSessions[cameraId] = cameraSession;

        // Set up track handler
        cameraSession.onTrack = (RTCTrackEvent e) => _onTrack(cameraId, e);
      }
    }

    setState(() {
      _camerasConnected = true;
    });
  }

  void _disconnectCameras() {
    dev.log('Disconnecting all cameras...');

    // Dispose renderers
    for (var renderer in renderers.values) {
      renderer.dispose();
    }

    // Disconnect sessions
    for (var cameraId in cameraSessions.keys.toList()) {
      sessionHub.disconnectCamera(cameraId);
    }

    renderers.clear();
    cameraSessions.clear();

    setState(() {
      _camerasConnected = false;
    });
  }

  void _onTrack(String cameraId, RTCTrackEvent e) {
    dev.log('[$cameraId] Track event: ${e.track.kind}');
    if (e.track.kind == 'video') {
      final renderer = renderers[cameraId];
      if (renderer != null) {
        setState(() {
          renderer.srcObject = e.streams.first;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Status',
                    style: Theme.of(context).textTheme.headlineSmall,
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
                        'Devices: ${_devicesRegistered ? "${sessionHub.availableProducers.length} registered" : "Registering..."}',
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        _camerasConnected
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: _camerasConnected ? Colors.green : Colors.grey,
                      ),
                      const SizedBox(width: 8),
                      Text('Cameras: ${cameraSessions.length} connected'),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Control buttons
          Row(
            children: [
              ElevatedButton.icon(
                onPressed: _devicesRegistered && !_camerasConnected
                    ? _connectToCameras
                    : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Connect Cameras'),
              ),
              const SizedBox(width: 16),
              ElevatedButton.icon(
                onPressed: _camerasConnected ? _disconnectCameras : null,
                icon: const Icon(Icons.stop),
                label: const Text('Disconnect'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red[100],
                  foregroundColor: Colors.red[800],
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Video display section
          Expanded(
            child: _camerasConnected && renderers.isNotEmpty
                ? GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          childAspectRatio: 16 / 9,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                    itemCount: renderers.length,
                    itemBuilder: (context, index) {
                      final cameraId = renderers.keys.elementAt(index);
                      final renderer = renderers[cameraId]!;

                      return Card(
                        child: Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: Text(
                                cameraId,
                                style: const TextStyle(fontSize: 12),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Expanded(
                              child: Container(
                                color: Colors.black,
                                child: RTCVideoView(renderer),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  )
                : Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.videocam_off,
                          size: 64,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _isInitialized
                              ? _devicesRegistered
                                    ? 'Click "Connect Cameras" to start'
                                    : 'Waiting for device registration...'
                              : 'Initializing SignalR connection...',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
