import 'package:equatable/equatable.dart';
import 'package:signalr/camera/redux/state.dart';

class AppState extends Equatable {
  const AppState({required this.cameraState});

  final CameraState cameraState;

  AppState copyWith({CameraState? cameraState}) {
    return AppState(cameraState: cameraState ?? this.cameraState);
  }

  @override
  List<Object> get props => [cameraState];
}
