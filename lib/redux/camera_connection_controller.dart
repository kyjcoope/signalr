import 'dart:async';

import 'package:redux/redux.dart';
import 'package:synchronized/synchronized.dart';

import '../signalr/signalr_session_hub.dart';
import '../utils/logger.dart';
import '../webrtc/session_state.dart';
import 'camera_connection_queue.dart';
import 'actions.dart';
import 'app_state.dart';
import 'thunks.dart' show syncSessionToRedux;

class CameraConnectionController {
  CameraConnectionController._();

  static final CameraConnectionController instance =
      CameraConnectionController._();

  static const _debounceDuration = Duration(milliseconds: 500);

  final Map<String, bool> _desiredState = {};
  final Map<String, Timer> _disconnectTimers = {};
  final Map<String, Lock> _locks = {};

  Lock _lockFor(String slug) => _locks.putIfAbsent(slug, () => Lock());

  Future<void> connect(String slug, Store<AppState> store) async {
    _desiredState[slug] = true;

    _disconnectTimers[slug]?.cancel();
    _disconnectTimers.remove(slug);

    await _lockFor(slug).synchronized(() async {
      if (_desiredState[slug] != true) {
        Logger().info(
          '[ConnCtrl] $slug: desired state changed, skipping connect',
        );
        return;
      }
      await _doConnect(slug, store);
    });
  }

  void disconnect(String slug, Store<AppState> store) {
    _desiredState[slug] = false;

    final queue = CameraConnectionQueue.instance;
    if (queue.cancel(slug)) {
      Logger().info('[ConnCtrl] $slug: cancelled from pending queue');
      store.dispatch(RemoveSession(slug));
      return;
    }

    if (queue.isManaged(slug)) {
      Logger().info('[ConnCtrl] $slug: cancel signal sent to active slot');
      store.dispatch(RemoveSession(slug));
      return;
    }

    if (_disconnectTimers.containsKey(slug)) return;

    _disconnectTimers[slug] = Timer(_debounceDuration, () {
      _disconnectTimers.remove(slug);
      _lockFor(slug).synchronized(() async {
        if (_desiredState[slug] != false) {
          Logger().info(
            '[ConnCtrl] $slug: desired state changed, skipping disconnect',
          );
          return;
        }
        await _doDisconnect(slug, store);
      });
    });
  }

  Future<void> disconnectImmediate(String slug, Store<AppState> store) async {
    _desiredState[slug] = false;

    _disconnectTimers[slug]?.cancel();
    _disconnectTimers.remove(slug);

    await _lockFor(slug).synchronized(() async {
      if (_desiredState[slug] != false) {
        Logger().info(
          '[ConnCtrl] $slug: desired state changed, skipping disconnect',
        );
        return;
      }
      await _doDisconnect(slug, store);
    });
  }

  void cancelAll() {
    CameraConnectionQueue.instance.cancelAll();
    for (final timer in _disconnectTimers.values) {
      timer.cancel();
    }
    _disconnectTimers.clear();
    _desiredState.clear();
  }

  Future<void> _doConnect(String slug, Store<AppState> store) async {
    final hub = SignalRSessionHub.instance;

    if (hub.isConnected(slug)) {
      final session = hub.getSession(slug);
      final state = session?.state;

      if (state == SessionConnectionState.connected) {
        Logger().info('[ConnCtrl] $slug: already connected — skipping');
        return;
      }

      Logger().info(
        '[ConnCtrl] $slug: stale session (state=$state) — tearing down',
      );
      await _doDisconnect(slug, store);
    }

    Logger().info('[ConnCtrl] $slug: connecting');
    final session = await hub.connectToCamera(slug);
    if (session == null) {
      Logger().error('[ConnCtrl] $slug: connect FAILED');
      return;
    }

    if (session.state.isTerminal) {
      Logger().info('[ConnCtrl] $slug: session failed during connect');
      syncSessionToRedux(store, slug);
      return;
    }

    session.onChanged = () => syncSessionToRedux(store, slug);
    session.onStatsUpdated = () => syncSessionToRedux(store, slug);
    session.onSessionFailed = (_) {
      final queue = CameraConnectionQueue.instance;
      if (_desiredState[slug] == true && !queue.isManaged(slug)) {
        Logger().info('[ConnCtrl] $slug: auto-reconnecting after failure');
        queue.enqueue(slug, store);
      } else if (queue.isManaged(slug)) {
        Logger().info(
          '[ConnCtrl] $slug: queue already managing retry — skipping auto-reconnect',
        );
      }
    };

    Logger().info('[ConnCtrl] $slug: connected and wired');
  }

  Future<void> _doDisconnect(String slug, Store<AppState> store) async {
    final hub = SignalRSessionHub.instance;

    if (!hub.isConnected(slug)) {
      Logger().info('[ConnCtrl] $slug: already disconnected');
      CameraConnectionQueue.instance.notifyDisconnected(slug);
      if (!CameraConnectionQueue.instance.isManaged(slug)) {
        store.dispatch(RemoveSession(slug));
      }
      return;
    }

    Logger().info('[ConnCtrl] $slug: disconnecting');
    await hub.disconnectCamera(slug);
    CameraConnectionQueue.instance.notifyDisconnected(slug);
    if (!CameraConnectionQueue.instance.isManaged(slug)) {
      store.dispatch(RemoveSession(slug));
    }
    Logger().info('[ConnCtrl] $slug: disconnected');
  }
}
