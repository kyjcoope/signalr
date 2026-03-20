import 'dart:async';
import 'dart:collection';

import 'package:redux/redux.dart';

import '../signalr/signalr_session_hub.dart';
import '../utils/logger.dart';
import '../webrtc/redux/webrtc_actions.dart';

import 'app_state.dart';
import 'camera_connection_controller.dart';

class _CancelSignal {
  final Completer<void> _completer = Completer<void>();
  bool get isCancelled => _completer.isCompleted;
  Future<void> get future => _completer.future;
  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

class CameraConnectionQueue {
  CameraConnectionQueue._();

  static final CameraConnectionQueue instance = CameraConnectionQueue._();

  static int maxConcurrent = 4;
  static int maxActiveDecoders = 16;
  static Duration fastTimeout = const Duration(seconds: 15);
  static Duration slowTimeout = const Duration(seconds: 20);
  static int maxAttempts = 3;

  final Queue<_QueueEntry> _queue = Queue();
  final Set<String> _activeSlots = {};
  final Set<String> _connectedSlugs = {};
  final Set<String> _managedSlugs = {};
  final Map<String, _CancelSignal> _cancelSignals = {};

  bool _processing = false;
  bool _cancelled = false;
  final Map<String, Completer<void>> _completers = {};

  bool isManaged(String slug) => _managedSlugs.contains(slug);

  Future<void> enqueue(String slug, Store<AppState> store) {
    if (_managedSlugs.contains(slug)) {
      Logger().info('[Queue] $slug already managed — skipping enqueue');
      return _completers[slug]?.future ?? Future.value();
    }

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

  void cancelAll() {
    _cancelled = true;

    final count = _queue.length;

    for (final entry in _queue) {
      _managedSlugs.remove(entry.slug);
      _completers.remove(entry.slug)?.complete();
    }

    _queue.clear();

    for (final slug in _activeSlots) {
      _cancelSignals[slug]?.cancel();
    }

    Logger().info(
      '[Queue] Cancelled all — cleared $count pending, '
      '${_activeSlots.length} still in-flight',
    );
  }

  bool cancel(String slug) {
    final wasQueued = _queue.any((e) => e.slug == slug);

    if (wasQueued) {
      _queue.removeWhere((e) => e.slug == slug);
      _managedSlugs.remove(slug);
      _completers.remove(slug)?.complete();
      Logger().info(
        '[Queue] Cancelled $slug from pending queue '
        '(remaining=${_queue.length})',
      );
      return true;
    }

    if (_activeSlots.contains(slug)) {
      _cancelSignals[slug]?.cancel();
      Logger().info('[Queue] Sent cancel signal to $slug (in active slot)');
      return false;
    }

    return false;
  }

  void notifyDisconnected(String slug) {
    if (_connectedSlugs.remove(slug)) {
      Logger().info(
        '[Queue] Decoder freed ($slug) — '
        'connected=${_connectedSlugs.length}/$maxActiveDecoders',
      );
      _scheduleProcessing();
    }
  }

  int get connectedCount => _connectedSlugs.length;

  void _scheduleProcessing() {
    if (_processing) return;
    _processing = true;
    scheduleMicrotask(_processQueue);
  }

  void _processQueue() {
    _processing = false;

    if (_cancelled) return;

    while (_activeSlots.length < maxConcurrent &&
        _connectedSlugs.length < maxActiveDecoders &&
        _queue.isNotEmpty) {
      final entry = _queue.removeFirst();
      final timeout = entry.attempt > 0 ? slowTimeout : fastTimeout;
      _startSlot(entry, timeout);
    }
  }

  void _startSlot(_QueueEntry entry, Duration timeout) {
    _activeSlots.add(entry.slug);
    _cancelSignals[entry.slug] = _CancelSignal();
    _startSlotBody(entry, timeout);
  }

  void _startSlotBody(_QueueEntry entry, Duration timeout) {
    final phase = entry.attempt == 0 ? 'fast' : 'retry #${entry.attempt}';
    Logger().info(
      '[Queue] Starting ${entry.slug} ($phase, timeout=${timeout.inSeconds}s) '
      '[${_activeSlots.length}/$maxConcurrent slots, '
      '${_connectedSlugs.length}/$maxActiveDecoders decoders]',
    );

    unawaited(_runSlot(entry, timeout));
  }

  Future<void> _runSlot(_QueueEntry entry, Duration timeout) async {
    final slug = entry.slug;
    final store = entry.store;
    final signal = _cancelSignals[slug]!;
    bool success = false;

    if (signal.isCancelled) {
      Logger().info('[Queue] $slug cancelled before connection started');
      _cleanupSlot(slug, store);
      return;
    }

    try {
      final sw = Stopwatch()..start();

      await Future.any([
        CameraConnectionController.instance.connect(slug, store),
        signal.future,
      ]).timeout(timeout);

      if (signal.isCancelled) {
        Logger().info('[Queue] $slug cancelled during connect phase');
        _cleanupSlot(slug, store);
        return;
      }

      final remaining = timeout - sw.elapsed;
      if (remaining <= Duration.zero) throw TimeoutException(null);

      final hub = SignalRSessionHub.instance;
      final session = hub.getSession(slug);
      if (session != null) {
        final result = await Future.any(<Future<dynamic>>[
          session.connectionResult,
          signal.future,
        ]).timeout(remaining);

        if (signal.isCancelled) {
          Logger().info('[Queue] $slug cancelled during ICE/connection phase');
          _cleanupSlot(slug, store);
          return;
        }

        success = result == true;
      }
    } on TimeoutException {
      Logger().warn('[Queue] $slug timed out (${timeout.inSeconds}s)');

      _onSlotComplete(entry, false);

      unawaited(
        CameraConnectionController.instance
            .disconnectImmediate(slug, store)
            .catchError(
              (e) => Logger().warn(
                '[Queue] $slug cleanup after timeout failed: $e',
              ),
            ),
      );
      return;
    } catch (e) {
      Logger().error('[Queue] $slug connection error: $e');
    }

    if (success) {
      Logger().info('[Queue] $slug connected');
    }
    _onSlotComplete(entry, success);
  }

  void _cleanupSlot(String slug, Store<AppState> store) {
    _activeSlots.remove(slug);
    _cancelSignals.remove(slug);
    _managedSlugs.remove(slug);
    _completers.remove(slug)?.complete();
    unawaited(
      CameraConnectionController.instance
          .disconnectImmediate(slug, store)
          .catchError(
            (e) => Logger().warn('[Queue] $slug abort-disconnect failed: $e'),
          ),
    );
    _scheduleProcessing();
  }

  void _onSlotComplete(_QueueEntry entry, bool success) {
    final slug = entry.slug;
    final store = entry.store;
    _activeSlots.remove(slug);
    final wasCancelled = _cancelSignals.remove(slug)?.isCancelled ?? false;

    if (_cancelled) {
      _managedSlugs.remove(slug);
      _completers.remove(slug)?.complete();
      return;
    }

    if (success && wasCancelled) {
      Logger().info(
        '[Queue] $slug completed but was cancelled — disconnecting',
      );
      _managedSlugs.remove(slug);
      _completers.remove(slug)?.complete();
      unawaited(
        CameraConnectionController.instance
            .disconnectImmediate(slug, store)
            .catchError(
              (e) => Logger().warn('[Queue] $slug abort-disconnect failed: $e'),
            ),
      );
      _scheduleProcessing();
      return;
    }

    if (success) {
      _connectedSlugs.add(slug);
      _managedSlugs.remove(slug);
      Logger().info(
        '[Queue] $slug connected '
        '[${_connectedSlugs.length}/$maxActiveDecoders decoders]',
      );
      _completers.remove(slug)?.complete();
    } else if (entry.attempt + 1 < maxAttempts) {
      final next = entry.attempt + 1;
      _queue.add(_QueueEntry(slug: slug, store: entry.store, attempt: next));
    } else {
      _managedSlugs.remove(slug);
      Logger().warn('[Queue] $slug failed after $maxAttempts attempts');
      _completers.remove(slug)?.complete();
    }

    _scheduleProcessing();
  }
}

class _QueueEntry {
  final String slug;
  final Store<AppState> store;
  final int attempt;

  _QueueEntry({required this.slug, required this.store, this.attempt = 0});
}
