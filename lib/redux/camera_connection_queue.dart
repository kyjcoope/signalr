import 'dart:async';
import 'dart:collection';

import 'package:redux/redux.dart';

import '../signalr/signalr_session_hub.dart';
import '../utils/logger.dart';
import '../webrtc/redux/webrtc_actions.dart';

import 'app_state.dart';
import 'camera_connection_controller.dart';

/// Centralized concurrency controller for camera WebRTC connections.
///
/// Throttles simultaneous signaling sessions to avoid overwhelming the server,
/// caps total active decoders to prevent hardware exhaustion (Android
/// `E/MediaCodec: NO_MEMORY`), and retries failed cameras inline — they go
/// to the back of the queue with a longer timeout so other cameras aren't
/// blocked.
///
/// All camera connections — individual and bulk — flow through this queue.
///
/// Usage:
/// ```dart
/// // Bulk connect (e.g., "Connect All" button)
/// await CameraConnectionQueue.instance.enqueueAll(cameraIds, store);
///
/// // Single camera
/// await CameraConnectionQueue.instance.enqueue(slug, store);
///
/// // Cancel everything (e.g., "Cancel All" or shutdown)
/// CameraConnectionQueue.instance.cancelAll();
/// ```
class CameraConnectionQueue {
  CameraConnectionQueue._();

  static final CameraConnectionQueue instance = CameraConnectionQueue._();

  // ═══════════════════════════════════════════════════════════════════════════
  // Configuration — tweak these to tune concurrency behavior
  // ═══════════════════════════════════════════════════════════════════════════

  /// Max cameras going through WebRTC signaling simultaneously.
  static int maxConcurrent = 4;

  /// Hard cap on total active (connected) decoders. Beyond this, cameras
  /// stay queued until a slot opens via disconnect.
  static int maxActiveDecoders = 16;

  /// Timeout for the first attempt — catches quick-connecting cameras.
  static Duration fastTimeout = const Duration(seconds: 15);

  /// Timeout for retries — gives struggling cameras more time.
  static Duration slowTimeout = const Duration(seconds: 20);

  // ═══════════════════════════════════════════════════════════════════════════
  // State
  // ═══════════════════════════════════════════════════════════════════════════

  /// Max total attempts per camera (1 fast + N-1 slow retries).
  static int maxAttempts = 3;

  /// Single queue: cameras waiting to connect. Retries go to the back
  /// with an incremented attempt counter so they get the longer timeout.
  final Queue<_QueueEntry> _queue = Queue();

  /// Camera IDs currently occupying a connection slot.
  final Set<String> _activeSlots = {};

  /// Camera IDs that have successfully connected (decoder tracking).
  /// Using a Set instead of an int counter makes add/remove idempotent:
  /// - Adding a slug that's already connected is a no-op (prevents overcounting
  ///   on auto-reconnect).
  /// - Removing a slug that isn't connected is a no-op (prevents undercounting
  ///   when disconnecting cameras that never reached connected state).
  final Set<String> _connectedSlugs = {};

  /// All camera IDs currently "owned" by the queue — either waiting in
  /// the queue, occupying an active slot, or pending retry. This prevents
  /// external callers (e.g., `onSessionFailed` auto-reconnect) from
  /// double-enqueueing a camera the queue is already going to retry.
  final Set<String> _managedSlugs = {};

  /// Set to true while the queue is actively processing entries.
  bool _processing = false;

  /// Set to true when cancelAll is called to abort processing.
  bool _cancelled = false;

  /// Completers for callers awaiting their enqueue to finish.
  final Map<String, Completer<void>> _completers = {};

  // ═══════════════════════════════════════════════════════════════════════════
  // Public API
  // ═══════════════════════════════════════════════════════════════════════════

  /// Enqueue a single camera for connection.
  ///
  /// Returns a future that completes when the camera either connects
  /// successfully, fails, or is cancelled.
  /// Whether the queue is currently managing (queued, in-flight, or
  /// pending retry) a given camera. Used by external callers like
  /// `onSessionFailed` to avoid double-enqueueing.
  bool isManaged(String slug) => _managedSlugs.contains(slug);

  Future<void> enqueue(String slug, Store<AppState> store) {
    // Don't double-enqueue
    if (_managedSlugs.contains(slug)) {
      Logger().info('[Queue] $slug already managed — skipping enqueue');
      return _completers[slug]?.future ?? Future.value();
    }

    // If this camera was previously tracked as connected (e.g., it
    // ICE-connected but then dropped and auto-reconnect fired), clean
    // up the stale decoder count before re-enqueueing.
    if (_connectedSlugs.remove(slug)) {
      Logger().info('[Queue] $slug was in connectedSlugs — cleaned up');
    }

    final completer = Completer<void>();
    _completers[slug] = completer;
    _managedSlugs.add(slug);
    _queue.add(_QueueEntry(slug: slug, store: store));

    store.dispatch(SetSessionQueued(slug));

    Logger().info(
      '[Queue] Enqueued $slug '
      '(pending=${_queue.length}, active=${_activeSlots.length}, '
      'connected=${_connectedSlugs.length}/$maxActiveDecoders)',
    );

    _scheduleProcessing();
    return completer.future;
  }

  /// Enqueue multiple cameras at once (e.g., "Connect All").
  ///
  /// Returns when all cameras have either connected or failed.
  Future<void> enqueueAll(List<String> slugs, Store<AppState> store) async {
    _cancelled = false;

    final futures = <Future<void>>[];
    for (final slug in slugs) {
      futures.add(enqueue(slug, store));
    }

    Logger().info(
      '[Queue] Enqueued ${slugs.length} cameras '
      '(maxConcurrent=$maxConcurrent, maxDecoders=$maxActiveDecoders)',
    );

    await Future.wait(futures);
  }

  /// Cancel all pending connections.
  ///
  /// In-flight connections (already in their signaling slot) will finish
  /// their current attempt but won't be retried.
  void cancelAll() {
    _cancelled = true;

    final count = _queue.length;

    // Complete all pending completers and clear management tracking
    for (final entry in _queue) {
      _managedSlugs.remove(entry.slug);
      _completers.remove(entry.slug)?.complete();
    }

    _queue.clear();

    Logger().info(
      '[Queue] Cancelled all — cleared $count pending, '
      '${_activeSlots.length} still in-flight',
    );
  }

  /// Notify the queue that a camera was disconnected externally.
  ///
  /// Decrements the decoder count and potentially unblocks queued cameras
  /// that were waiting for a decoder slot.
  void notifyDisconnected(String slug) {
    if (_connectedSlugs.remove(slug)) {
      Logger().info(
        '[Queue] Decoder freed ($slug) — '
        'connected=${_connectedSlugs.length}/$maxActiveDecoders',
      );
      _scheduleProcessing();
    }
  }

  /// Current count of connected decoders (for external visibility).
  int get connectedCount => _connectedSlugs.length;

  // ═══════════════════════════════════════════════════════════════════════════
  // Processing Engine
  // ═══════════════════════════════════════════════════════════════════════════

  /// Schedule queue processing on the next microtask (coalesces multiple
  /// enqueue calls into a single processing loop).
  void _scheduleProcessing() {
    if (_processing) return;
    _processing = true;
    scheduleMicrotask(_processQueue);
  }

  void _processQueue() {
    _processing = false;

    if (_cancelled) return;

    // Fill available slots from the queue, staggering starts by 200ms
    // to reduce main-thread contention from concurrent createPeerConnection
    // calls (each one blocks the platform thread for ~600ms+ under load).
    int started = 0;
    while (_activeSlots.length < maxConcurrent &&
        _connectedSlugs.length < maxActiveDecoders &&
        _queue.isNotEmpty) {
      final entry = _queue.removeFirst();
      final timeout = entry.attempt > 0 ? slowTimeout : fastTimeout;
      if (started > 0) {
        final delay = Duration(milliseconds: 200 * started);
        _activeSlots.add(entry.slug);
        Future.delayed(delay, () {
          if (!_cancelled) {
            _startSlotBody(entry, timeout);
          } else {
            _activeSlots.remove(entry.slug);
            _managedSlugs.remove(entry.slug);
            _completers.remove(entry.slug)?.complete();
          }
        });
      } else {
        _startSlot(entry, timeout);
      }
      started++;
    }
  }

  /// Start a camera in a connection slot (adds to _activeSlots + starts).
  void _startSlot(_QueueEntry entry, Duration timeout) {
    _activeSlots.add(entry.slug);
    _startSlotBody(entry, timeout);
  }

  /// Actually kick off the connection attempt (slot already reserved).
  void _startSlotBody(_QueueEntry entry, Duration timeout) {
    final phase = entry.attempt == 0 ? 'fast' : 'retry #${entry.attempt}';
    Logger().info(
      '[Queue] Starting ${entry.slug} ($phase, timeout=${timeout.inSeconds}s) '
      '[${_activeSlots.length}/$maxConcurrent slots, '
      '${_connectedSlugs.length}/$maxActiveDecoders decoders]',
    );

    // Fire and forget — completion is tracked via _onSlotComplete
    unawaited(_runSlot(entry, timeout));
  }

  Future<void> _runSlot(_QueueEntry entry, Duration timeout) async {
    final slug = entry.slug;
    final store = entry.store;
    bool success = false;

    try {
      final sw = Stopwatch()..start();

      await CameraConnectionController.instance
          .connect(slug, store)
          .timeout(timeout);

      final remaining = timeout - sw.elapsed;
      if (remaining <= Duration.zero) throw TimeoutException(null);

      final hub = SignalRSessionHub.instance;
      final session = hub.getSession(slug);
      if (session != null) {
        success = await session.connectionResult.timeout(remaining);
      }
    } on TimeoutException {
      Logger().warn('[Queue] $slug timed out (${timeout.inSeconds}s)');

      // Free the slot FIRST so the next camera can start while we clean up.
      // _onSlotComplete handles retry logic and queue advancement.
      _onSlotComplete(entry, false);

      // Clean up the stale session in the background — don't block the slot.
      unawaited(
        CameraConnectionController.instance
            .disconnectImmediate(slug, store)
            .catchError(
              (e) =>
                  Logger().warn('[Queue] $slug cleanup after timeout failed: $e'),
            ),
      );
      return;
    } catch (e) {
      Logger().error('[Queue] $slug connection error: $e');
    }

    _onSlotComplete(entry, success);
  }

  void _onSlotComplete(_QueueEntry entry, bool success) {
    final slug = entry.slug;
    _activeSlots.remove(slug);

    if (_cancelled) {
      _managedSlugs.remove(slug);
      _completers.remove(slug)?.complete();
      return;
    }

    if (success) {
      _connectedSlugs.add(slug);
      _managedSlugs.remove(slug); // No longer managed — camera is live
      Logger().info(
        '[Queue] ✅ $slug connected '
        '[${_connectedSlugs.length}/$maxActiveDecoders decoders]',
      );
      _completers.remove(slug)?.complete();
    } else if (entry.attempt + 1 < maxAttempts) {
      final next = entry.attempt + 1;
      Logger().info('[Queue] $slug → back of queue for retry #$next');
      _queue.add(_QueueEntry(
        slug: slug,
        store: entry.store,
        attempt: next,
      ));
    } else {
      _managedSlugs.remove(slug);
      Logger().warn(
        '[Queue] ❌ $slug failed after $maxAttempts attempts — giving up',
      );
      _completers.remove(slug)?.complete();
    }

    // Process next items in the queue
    _scheduleProcessing();
  }
}

/// Internal queue entry pairing a camera slug with its Redux store.
class _QueueEntry {
  final String slug;
  final Store<AppState> store;
  final int attempt;

  _QueueEntry({required this.slug, required this.store, this.attempt = 0});
}
