// lib\demo\webrtc_display.dart

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

  final List<String> desiredCameras = [
    //'ed25cd2f-a3da-4fd8-a32d-69382565baf7',
    'e155e2bf-12d2-4ba2-b236-717f3021a0b6',
  ];

  bool _isInitialized = false;
  bool _devicesRegistered = false;
  bool _camerasConnected = false;
  // --- NEW STATE VARIABLE ---
  // We use this simple bool to track if a stream has been successfully received.
  bool _streamReceived = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    for (var renderer in renderers.values) {
      renderer.dispose();
    }
    for (var session in cameraSessions.values) {
      session.dispose();
    }
    sessionHub.shutdown();
    super.dispose();
  }

  void _initialize() async {
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

  Future<void> _connectToCameras() async {
    if (!_devicesRegistered) {
      dev.log('Cannot connect - devices not yet registered');
      return;
    }

    dev.log('Connecting to cameras...');
    _streamReceived = false; // Reset on new connection
    setState(() {
      _camerasConnected = true;
    });

    for (String cameraId in desiredCameras) {
      final cameraSession = await sessionHub.connectToCamera(cameraId);
      if (cameraSession != null) {
        final renderer = RTCVideoRenderer();
        await renderer.initialize();

        renderers[cameraId] = renderer;
        cameraSessions[cameraId] = cameraSession;

        cameraSession.onTrack = (RTCTrackEvent event) {
          dev.log(
            '[$cameraId] Handling track event in UI layer: ${event.track.kind}',
          );
          if (event.streams.isEmpty) return;

          final stream = event.streams[0];
          final videoRenderer = renderers[cameraId];

          if (videoRenderer != null) {
            // We do not need to call Helper.setSpeakerphoneOn(). Setting the srcObject
            // is sufficient for both audio and video playback.
            setState(() {
              videoRenderer.srcObject = stream;
              _streamReceived = true; // Set our reliable flag
            });
          }
        };
      }
    }
  }

  void _disconnectCameras() {
    dev.log('Disconnecting all cameras...');
    _streamReceived = false;

    for (var renderer in renderers.values) {
      renderer.srcObject = null;
      renderer.dispose();
    }

    for (var session in cameraSessions.values) {
      session.dispose();
    }

    renderers.clear();
    cameraSessions.clear();

    if (mounted) {
      setState(() {
        _camerasConnected = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                      // --- FINAL FIX: Use our reliable state variable ---
                      Icon(
                        _streamReceived
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: _streamReceived ? Colors.green : Colors.grey,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Cameras: ${_streamReceived ? cameraSessions.length : 0} connected',
                      ),
                      // --- END OF FIX ---
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              ElevatedButton.icon(
                onPressed:
                    _isInitialized && _devicesRegistered && !_camerasConnected
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
                                child: RTCVideoView(
                                  renderer,
                                  mirror: false,
                                  objectFit: RTCVideoViewObjectFit
                                      .RTCVideoViewObjectFitContain,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  )
                : Center(/* ... unchanged ... */),
          ),
        ],
      ),
    );
  }
}
