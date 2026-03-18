import 'dart:async';

import 'package:redux/redux.dart';
import 'package:synchronized/synchronized.dart';

import '../signalr/signalr_session_hub.dart';
import '../utils/logger.dart';
import '../webrtc/session_state.dart';
import 'actions.dart';
import 'app_state.dart';
import 'thunks.dart' show syncSessionToRedux;

/// Manages per-camera connection intent with debounce and serialization.
///
/// **Connect**: Executes immediately (cancels any pending disconnect debounce).
/// **Disconnect**: Debounced by [_debounceDuration] to absorb rapid toggles.
///
/// Operations on the same camera are serialized via per-camera [Lock] —
/// a connect will wait for a pending disconnect to finish, and vice versa.
/// After acquiring the lock, desired state is re-checked so stale intents
/// from cancelled toggles are discarded.
class CameraConnectionController {
  CameraConnectionController._();

  static final CameraConnectionController instance =
      CameraConnectionController._();

  static const _debounceDuration = Duration(milliseconds: 500);

  /// Per-camera desired state: true = connect, false = disconnect.
  final Map<String, bool> _desiredState = {};

  /// Per-camera disconnect debounce timers.
  final Map<String, Timer> _disconnectTimers = {};

  /// Per-camera serialization locks.
  final Map<String, Lock> _locks = {};

  /// Get or create the [Lock] for a camera.
  Lock _lockFor(String slug) => _locks.putIfAbsent(slug, () => Lock());

  // ═══════════════════════════════════════════════════════════════════════════
  // Public API
  // ═══════════════════════════════════════════════════════════════════════════

  /// Connect a camera. Executes immediately, cancelling any pending
  /// disconnect debounce.
  Future<void> connect(String slug, Store<AppState> store) async {
    _desiredState[slug] = true;

    // Cancel any pending disconnect debounce — user changed their mind
    _disconnectTimers[slug]?.cancel();
    _disconnectTimers.remove(slug);

    await _lockFor(slug).synchronized(() async {
      // Re-check: user might have changed mind while we waited for the lock
      if (_desiredState[slug] != true) {
        Logger().info(
          '[ConnCtrl] $slug: desired state changed, skipping connect',
        );
        return;
      }
      await _doConnect(slug, store);
    });
  }

  /// Disconnect a camera after debounce period (for UI toggling).
  ///
  /// The actual disconnect fires after [_debounceDuration]. If [connect]
  /// is called within that window, the disconnect is cancelled.
  void disconnect(String slug, Store<AppState> store) {
    _desiredState[slug] = false;

    _disconnectTimers[slug]?.cancel();
    _disconnectTimers[slug] = Timer(_debounceDuration, () {
      _disconnectTimers.remove(slug);
      _lockFor(slug).synchronized(() async {
        // Re-check: desired state may have changed during debounce or lock wait
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

  /// Disconnect a camera immediately, bypassing debounce.
  ///
  /// Used by bulk operations ([stopAll], [disposeSignalRThunk]) where
  /// debouncing would be inappropriate.
  Future<void> disconnectImmediate(String slug, Store<AppState> store) async {
    _desiredState[slug] = false;

    // Cancel any pending debounce timer
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

  /// Cancel all pending debounce timers and clear state.
  ///
  /// Called during hub shutdown to prevent stale timers from firing
  /// after the hub is torn down.
  void cancelAll() {
    for (final timer in _disconnectTimers.values) {
      timer.cancel();
    }
    _disconnectTimers.clear();
    _desiredState.clear();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Operations
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _doConnect(String slug, Store<AppState> store) async {
    final hub = SignalRSessionHub.instance;

    // Already connected — check if the session is actually healthy
    if (hub.isConnected(slug)) {
      final session = hub.getSession(slug);
      final state = session?.state;

      // If the session is in a terminal or stale state, tear it down
      // and reconnect fresh. This handles the case where ICE failed,
      // the reconnect stalled, or the session silently died.
      if (state != null &&
          (state.isTerminal || state == SessionConnectionState.disconnected)) {
        Logger().info(
          '[ConnCtrl] $slug: stale session (state=$state) — tearing down',
        );
        await _doDisconnect(slug, store);
        // Fall through to reconnect below
      } else {
        Logger().info('[ConnCtrl] $slug: already connected (state=$state)');
        return;
      }
    }

    Logger().info('[ConnCtrl] $slug: connecting');
    final session = await hub.connectToCamera(slug);
    if (session == null) {
      Logger().error('[ConnCtrl] $slug: connect FAILED');
      return;
    }

    // Session may have failed during the await (e.g. fast 480 error response).
    // The onStateChanged callback wasn't wired yet, so the error hasn't reached
    // Redux. Sync the final state (including lastError) before bailing.
    if (session.state.isTerminal) {
      Logger().info('[ConnCtrl] $slug: session failed during connect');
      syncSessionToRedux(store, slug);
      return;
    }

    // Wire Redux sync callbacks
    session.onStateChanged = (_) => syncSessionToRedux(store, slug);
    session.onConnectionComplete = () => syncSessionToRedux(store, slug);
    session.onVideoCodecResolved = (_) => syncSessionToRedux(store, slug);
    session.onLocalIceCandidate = () => syncSessionToRedux(store, slug);
    session.onRemoteIceCandidate = () => syncSessionToRedux(store, slug);
    session.statsNotifier.addListener(() => syncSessionToRedux(store, slug));

    Logger().info('[ConnCtrl] $slug: connected and wired');
  }

  Future<void> _doDisconnect(String slug, Store<AppState> store) async {
    final hub = SignalRSessionHub.instance;

    if (!hub.isConnected(slug)) {
      Logger().info('[ConnCtrl] $slug: already disconnected');
      // Still clean up Redux state in case it's stale
      store.dispatch(RemoveSession(slug));
      return;
    }

    Logger().info('[ConnCtrl] $slug: disconnecting');
    await hub.disconnectCamera(slug);
    store.dispatch(RemoveSession(slug));
    Logger().info('[ConnCtrl] $slug: disconnected');
  }
}
