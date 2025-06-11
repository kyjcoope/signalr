import 'package:signalr/camera/redux/reducers.dart';

import 'state.dart';

AppState appReducer(AppState state, dynamic action) {
  return AppState(cameraState: cameraReducer(state.cameraState, action));
}
