import 'package:flutter/material.dart';
import 'package:flutter_redux/flutter_redux.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:redux/redux.dart';
import 'package:signalr/camera/redux/selectors.dart';
import 'package:signalr/camera/redux/state.dart';
import 'package:signalr/camera/redux/thunks.dart';
import 'package:signalr/redux/state.dart';
import 'dart:developer' as dev;

class WebRtcDisplay extends StatefulWidget {
  const WebRtcDisplay({super.key});
  @override
  State<WebRtcDisplay> createState() => _WebRtcDisplay();
}

class _WebRtcDisplay extends State<WebRtcDisplay> {
  final Map<String, RTCVideoRenderer> renderers = {};
  final List<String> desiredCameras = ['exacqu-H110E1-2'];

  @override
  void dispose() {
    for (var renderer in renderers.values) {
      renderer.dispose();
    }
    super.dispose();
  }

  Future<void> _connectToCameras() async {
    final store = StoreProvider.of<AppState>(context);

    dev.log('Connecting to cameras...');
    for (String cameraId in desiredCameras) {
      final renderer = RTCVideoRenderer();
      await renderer.initialize();
      renderers[cameraId] = renderer;

      store.dispatch(connectToCameraThunk(cameraId));
    }
  }

  void _disconnectCameras() {
    final store = StoreProvider.of<AppState>(context);

    dev.log('Disconnecting all cameras...');
    for (var renderer in renderers.values) {
      renderer.dispose();
    }
    renderers.clear();
    store.dispatch(disconnectAllCamerasThunk());
  }

  void _setupVideoRenderers(_ViewModel viewModel) {
    for (final camera in viewModel.connectedCameras) {
      final renderer = renderers[camera.deviceId];
      if (renderer != null && camera.session != null) {
        if (camera.session!.onTrack == null) {
          camera.session!.onTrack = (event) {
            if (event.track.kind == 'video') {
              dev.log(
                '[${camera.deviceId}] Setting video track to renderer from UI',
              );
              setState(() {
                renderer.srcObject = event.streams.first;
              });
            }
          };
          dev.log('[${camera.deviceId}] Video renderer callback set up');
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return StoreConnector<AppState, _ViewModel>(
      converter: (store) => _ViewModel.fromStore(store),
      onInit: (store) {
        store.onChange.listen((state) {
          _updateVideoRenderers(state.cameraState);
        });
      },
      onWillChange: (previousViewModel, newViewModel) {
        _setupVideoRenderers(newViewModel);
      },
      builder: (context, viewModel) {
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
                            viewModel.isSignalRConnected
                                ? Icons.check_circle
                                : Icons.pending,
                            color: viewModel.isSignalRConnected
                                ? Colors.green
                                : Colors.orange,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'SignalR: ${viewModel.isSignalRConnected ? "Connected" : "Connecting..."}',
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            viewModel.isDeviceRegistrationComplete
                                ? Icons.check_circle
                                : Icons.pending,
                            color: viewModel.isDeviceRegistrationComplete
                                ? Colors.green
                                : Colors.orange,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Devices: ${viewModel.isDeviceRegistrationComplete ? "${viewModel.availableDevices.length} registered" : "Registering..."}',
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            viewModel.connectedCameraCount > 0
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            color: viewModel.connectedCameraCount > 0
                                ? Colors.green
                                : Colors.grey,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Cameras: ${viewModel.connectedCameraCount} connected',
                          ),
                        ],
                      ),
                      if (viewModel.errorMessage != null) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(Icons.error, color: Colors.red),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Error: ${viewModel.errorMessage}',
                                style: const TextStyle(color: Colors.red),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed:
                        viewModel.canConnectToCameras &&
                            viewModel.connectedCameraCount == 0
                        ? _connectToCameras
                        : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Connect Cameras'),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton.icon(
                    onPressed: viewModel.connectedCameraCount > 0
                        ? _disconnectCameras
                        : null,
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
                child:
                    viewModel.connectedCameras.isNotEmpty &&
                        renderers.isNotEmpty
                    ? GridView.builder(
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              childAspectRatio: 16 / 9,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                            ),
                        itemCount: viewModel.connectedCameras.length,
                        itemBuilder: (context, index) {
                          final camera = viewModel.connectedCameras[index];
                          final renderer = renderers[camera.deviceId];

                          if (renderer == null) return const SizedBox();

                          return Card(
                            child: Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.all(8.0),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          camera.deviceId,
                                          style: const TextStyle(fontSize: 12),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (camera.hasVideo)
                                        const Icon(
                                          Icons.videocam,
                                          color: Colors.green,
                                          size: 16,
                                        ),
                                      const SizedBox(width: 4),
                                      _buildStatusIcon(camera.status),
                                    ],
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
                              viewModel.isSignalRConnected
                                  ? viewModel.isDeviceRegistrationComplete
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
      },
    );
  }

  Widget _buildStatusIcon(CameraConnectionStatus status) {
    switch (status) {
      case CameraConnectionStatus.connected:
        return const Icon(Icons.check_circle, color: Colors.green, size: 16);
      case CameraConnectionStatus.connecting:
        return const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case CameraConnectionStatus.failed:
        return const Icon(Icons.error, color: Colors.red, size: 16);
      case CameraConnectionStatus.disconnected:
        return const Icon(
          Icons.radio_button_unchecked,
          color: Colors.grey,
          size: 16,
        );
    }
  }

  void _updateVideoRenderers(CameraState cameraState) {
    for (final camera in cameraState.activeCameras.values) {
      if (camera.status == CameraConnectionStatus.connected &&
          camera.session != null) {
        final renderer = renderers[camera.deviceId];
        if (renderer != null && camera.session!.onTrack == null) {
          camera.session!.onTrack = (event) {
            if (event.track.kind == 'video') {
              dev.log('[${camera.deviceId}] Setting video track to renderer');
              setState(() {
                renderer.srcObject = event.streams.first;
              });
            }
          };
          dev.log(
            '[${camera.deviceId}] Video renderer callback set up in update method',
          );
        }
      }
    }
  }
}

class _ViewModel {
  const _ViewModel({
    required this.isSignalRConnected,
    required this.isDeviceRegistrationComplete,
    required this.availableDevices,
    required this.connectedCameras,
    required this.connectedCameraCount,
    required this.canConnectToCameras,
    required this.errorMessage,
  });

  final bool isSignalRConnected;
  final bool isDeviceRegistrationComplete;
  final List<String> availableDevices;
  final List<CameraInfo> connectedCameras;
  final int connectedCameraCount;
  final bool canConnectToCameras;
  final String? errorMessage;

  factory _ViewModel.fromStore(Store<AppState> store) {
    return _ViewModel(
      isSignalRConnected: selectIsSignalRConnected(store.state),
      isDeviceRegistrationComplete: selectIsDeviceRegistrationComplete(
        store.state,
      ),
      availableDevices: selectAvailableDevices(store.state),
      connectedCameras: selectConnectedCameras(store.state),
      connectedCameraCount: selectConnectedCameraCount(store.state),
      canConnectToCameras: selectCanConnectToCameras(store.state),
      errorMessage: selectCameraError(store.state),
    );
  }
}
