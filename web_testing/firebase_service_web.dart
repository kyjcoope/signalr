import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../../firebase_options.dart';
import '../../logging/logger.dart';
import '../../nav_bar/global_navigation_manager.dart';
import '../../nav_bar/utils/nav_bar_navigation_manager.dart';
import '../../notification_alerts/enum.dart';
import '../../notification_alerts/push_notifications_cache.dart';
import '../../videopush/widget/video_push_notification_panel.dart';
import '../utils/notification_utils.dart';
import '../widget/craft_custom/ev_snackbar.dart';

/// VAPID public key – Firebase Console → Project Settings → Cloud Messaging
/// → Web Push certificates. Public key, safe to commit.
///
/// Keep the existing production assignment, or provide it with:
/// --dart-define=FIREBASE_VAPID_KEY=<public-key>
const String _vapidKey = String.fromEnvironment('FIREBASE_VAPID_KEY');

class FirebaseService {
  static const String _messagingWorkerScript = '/firebase-messaging-sw.js';
  static const String _messagingWorkerScope =
      '/firebase-cloud-messaging-push-scope';
  static const Duration _workerReadyTimeout = Duration(seconds: 12);
  static const Duration _activeLeaseInterval = Duration(seconds: 4);
  static const Duration _incomingPushDedupTtl = Duration(seconds: 8);
  static const Duration _notificationClickDedupTtl = Duration(seconds: 30);
  static const Duration _leaseWarningInterval = Duration(seconds: 30);

  static bool _initialized = false;
  static bool _messageHandlersInitialized = false;
  static bool _activeLeaseInitialized = false;
  static bool _swClickHandlerInitialized = false;
  static bool _lifecycleResumed = true;
  static Future<void>? _firebaseInitializationInFlight;
  static Future<String>? _tokenRequestInFlight;
  static Future<web.ServiceWorkerRegistration>?
  _messagingWorkerRegistrationInFlight;
  static web.ServiceWorkerRegistration? _messagingWorkerRegistration;
  static Timer? _activeLeaseTimer;
  static JSFunction? _visibilityListener;
  static JSFunction? _focusListener;
  static JSFunction? _blurListener;
  static JSFunction? _pageHideListener;
  static JSFunction? _beforeUnloadListener;
  static int _leasePostSequence = 0;
  static bool _leaseWorkerMissingLogged = false;
  static bool? _lastLoggedActiveLeaseState;
  static DateTime? _lastLeaseWarningAt;

  static final Map<String, DateTime> _seenIncomingPushes = {};
  static final Map<String, DateTime> _seenNotificationClicks = {};
  static final String _tabLeaseId =
      'tab-${DateTime.now().microsecondsSinceEpoch}-${DateTime.now().hashCode}';

  /// Initialise Firebase on web. Concurrent calls share one request.
  Future<void> initFirebase() {
    if (_initialized) return Future<void>.value();

    final inFlight = _firebaseInitializationInFlight;
    if (inFlight != null) return inFlight;

    final request = _initializeFirebase();
    _firebaseInitializationInFlight = request;
    return request;
  }

  Future<void> _initializeFirebase() async {
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException(
          'Firebase.initializeApp timed out – browser may be blocking SDK requests',
        ),
      );
      _initialized = true;
      Logger().info('Firebase initialised on web');
    } catch (e, stackTrace) {
      Logger().error('Firebase web init failed: $e\n$stackTrace');
    } finally {
      _firebaseInitializationInFlight = null;
    }
  }

  /// Returns the FCM web push token. Concurrent callers share one request.
  Future<String> getToken() {
    final inFlight = _tokenRequestInFlight;
    if (inFlight != null) return inFlight;

    final request = _getTokenAndClear();
    _tokenRequestInFlight = request;
    return request;
  }

  Future<String> _getTokenAndClear() async {
    try {
      return await _getToken();
    } finally {
      _tokenRequestInFlight = null;
    }
  }

  Future<String> _getToken() async {
    await initFirebase();
    if (!_initialized) {
      Logger().warn(
        '[PushNotify] Skipping FCM token request – Firebase did not initialise',
      );
      return '';
    }

    if (_vapidKey.isEmpty) {
      Logger().error(
        '[PushNotify] FCM token request skipped: FIREBASE_VAPID_KEY is empty',
      );
      return '';
    }

    try {
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      if (settings.authorizationStatus != AuthorizationStatus.authorized) {
        Logger().warn(
          'FCM web notification permission denied: '
          '${settings.authorizationStatus}',
        );
        return '';
      }
    } catch (e, stackTrace) {
      Logger().error(
        '[PushNotify] Failed requesting web notification permission: '
        '$e\n$stackTrace',
      );
      return '';
    }
    Logger().info('FCM web notification permission granted');

    Object? lastError;
    StackTrace? lastStackTrace;
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        final registration = await _ensureMessagingWorkerRegistration(
          forceRefresh: attempt > 1,
        );
        Logger().info(
          '[PushNotify] Messaging worker active: '
          'scope=${registration.scope} '
          'script=${registration.active?.scriptURL}',
        );

        final token = await FirebaseMessaging.instance.getToken(
          vapidKey: _vapidKey,
        );
        if (token == null || token.isEmpty) {
          throw StateError('FirebaseMessaging.getToken returned no token');
        }

        Logger().info('FCM web token obtained');
        _syncActiveLease();
        _announceClientReady();
        return token;
      } catch (e, stackTrace) {
        lastError = e;
        lastStackTrace = stackTrace;
        _messagingWorkerRegistration = null;

        if (attempt < 3) {
          final delay = Duration(milliseconds: 500 * attempt);
          Logger().warn(
            '[PushNotify] FCM token attempt $attempt/3 failed: $e; '
            'retrying in ${delay.inMilliseconds}ms',
          );
          await Future<void>.delayed(delay);
        }
      }
    }

    Logger().error(
      '[PushNotify] Failed to get FCM web token after 3 attempts. '
      'origin=${web.window.location.origin} '
      'worker=$_messagingWorkerScript: $lastError\n$lastStackTrace',
    );
    return '';
  }

  static Future<web.ServiceWorkerRegistration>
  _ensureMessagingWorkerRegistration({bool forceRefresh = false}) {
    final cached = _messagingWorkerRegistration;
    if (!forceRefresh &&
        cached != null &&
        cached.active?.state == 'activated') {
      return Future<web.ServiceWorkerRegistration>.value(cached);
    }

    final inFlight = _messagingWorkerRegistrationInFlight;
    if (inFlight != null) return inFlight;

    final request = _registerMessagingWorker();
    _messagingWorkerRegistrationInFlight = request;
    return request;
  }

  static Future<web.ServiceWorkerRegistration>
  _registerMessagingWorker() async {
    try {
      final container = web.window.navigator.serviceWorker;
      final registration = await container
          .register(
            _messagingWorkerScript.toJS,
            web.RegistrationOptions(
              scope: _messagingWorkerScope,
              updateViaCache: 'none',
            ),
          )
          .toDart
          .timeout(_workerReadyTimeout);

      // register() performs an update check. This explicit update makes
      // redeployments deterministic when a registration already existed.
      try {
        await registration.update().toDart.timeout(const Duration(seconds: 5));
      } catch (e) {
        Logger().warn(
          '[PushNotify] Messaging worker update check failed; '
          'continuing with registration state: $e',
        );
      }

      final deadline = DateTime.now().add(_workerReadyTimeout);
      while (registration.active?.state != 'activated') {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException(
            'Messaging worker did not activate for scope '
            '$_messagingWorkerScope',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      _messagingWorkerRegistration = registration;
      _leaseWorkerMissingLogged = false;
      return registration;
    } finally {
      _messagingWorkerRegistrationInFlight = null;
    }
  }

  static Future<web.ServiceWorkerRegistration?>
  _findActiveMessagingWorkerRegistration() async {
    final cached = _messagingWorkerRegistration;
    if (cached?.active?.state == 'activated') return cached;

    try {
      final registration = await web.window.navigator.serviceWorker
          .getRegistration(_messagingWorkerScope)
          .toDart;
      if (registration?.active?.state != 'activated') return null;

      _messagingWorkerRegistration = registration;
      _leaseWorkerMissingLogged = false;
      return registration;
    } catch (e) {
      _warnLeaseProblem(
        '[PushNotify] Failed looking up messaging worker registration: $e',
      );
      return null;
    }
  }

  /// Invalidates the cached FCM push subscription so the next [getToken]
  /// call creates a fresh one.
  Future<void> deleteToken() async {
    try {
      await FirebaseMessaging.instance.deleteToken();
      Logger().info(
        '[PushNotify] FCM web token invalidated – '
        'will refresh on next getToken()',
      );
    } catch (e) {
      Logger().error('Failed to invalidate FCM web token: $e');
    }
  }

  /// Listen for foreground messages and notification-click routing.
  void handleMessageOnBackground() {
    if (!_messageHandlersInitialized) {
      _messageHandlersInitialized = true;
      FirebaseMessaging.onMessage.listen(_foregroundMessageHandler);
      FirebaseMessaging.onMessageOpenedApp.listen(_notificationClickHandler);
    }
    _initializeServiceWorkerClickHandler();
  }

  Future<void> _foregroundMessageHandler(RemoteMessage message) async {
    Logger().info(
      '[PushNotify] foreground message received: '
      'title="${message.notification?.title}" '
      'key=${message.data["key"]}',
    );

    // The messaging worker is solely responsible for native notifications.
    // A hidden/non-focused tab must never create another notification.
    if (!_shouldHoldActiveLease()) return;

    if (_isDuplicateIncomingPush(message, source: 'foreground')) return;

    final currentContext = NavigationManager().navigatorKey.currentContext;
    final navBarContext = NavBarNavigationManager().navigatorKey.currentContext;
    if (message.notification?.title == null ||
        currentContext == null ||
        navBarContext == null) {
      return;
    }

    try {
      await PushNotificationsCacheManager().putPushNotification(message);
    } catch (e) {
      Logger().error('Web: failed to cache push notification: $e');
    }

    if (!currentContext.mounted) return;

    if (message.data['key'] == PushNotificationCategory.videoPush.dataKey ||
        message.data['key'] ==
            PushNotificationCategory.videoPushMulti.dataKey ||
        message.data['key'] ==
            PushNotificationCategory.videoPushSearch.dataKey) {
      showDialog(
        barrierDismissible: false,
        context: currentContext,
        builder: (BuildContext context) {
          return VideoPushNotificationPanel(message: message);
        },
      );
    } else {
      ScaffoldMessenger.of(currentContext).showSnackBar(
        buildPushNotificationSnackBar(
          currentContext,
          message: message,
          padForNavBar: ModalRoute.of(navBarContext)?.isCurrent ?? true,
        ),
      );
    }
  }

  /// Called when the user taps a notification handled by FlutterFire.
  Future<void> _notificationClickHandler(RemoteMessage message) async {
    Logger().info(
      '[PushNotify] notification clicked (background): '
      'title="${message.notification?.title}" '
      'key=${message.data["key"]}',
    );
    try {
      await PushNotificationsCacheManager().putPushNotification(message);
    } catch (e) {
      Logger().error('Web: failed to cache push notification on click: $e');
    }
    await _routeNotificationWithRetries(message, source: 'onMessageOpenedApp');
  }

  Future<AuthorizationStatus> checkNotificationStatus() async {
    await initFirebase();
    final settings = await FirebaseMessaging.instance.getNotificationSettings();
    return settings.authorizationStatus;
  }

  /// Starts service-worker lease heartbeats for this browser tab.
  void initializeActiveTabLeaseHeartbeat() {
    if (_activeLeaseInitialized) {
      _syncActiveLease();
      return;
    }

    _activeLeaseInitialized = true;
    _installActiveLeaseListeners();
    _syncActiveLease();
    Logger().info('[PushNotify] Active-tab lease heartbeat initialized');
  }

  /// Updates active lease state based on Flutter app lifecycle.
  void updateActiveTabLeaseForLifecycle(AppLifecycleState state) {
    _lifecycleResumed = state == AppLifecycleState.resumed;
    _syncActiveLease();
  }

  /// Stops heartbeats and clears this tab's active lease.
  void disposeActiveTabLeaseHeartbeat() {
    if (!_activeLeaseInitialized) return;

    _activeLeaseInitialized = false;
    _activeLeaseTimer?.cancel();
    _activeLeaseTimer = null;
    _postActiveLease(active: false);
    _lastLoggedActiveLeaseState = null;
    _removeActiveLeaseListeners();
    Logger().info('[PushNotify] Active-tab lease heartbeat disposed');
  }

  static bool _isDuplicateIncomingPush(
    RemoteMessage message, {
    required String source,
  }) {
    final now = DateTime.now();
    _seenIncomingPushes.removeWhere((_, expiresAt) => expiresAt.isBefore(now));

    final fingerprint = _incomingPushFingerprint(message);
    if (_seenIncomingPushes.containsKey(fingerprint)) {
      Logger().info(
        '[PushNotify] Duplicate $source push suppressed: '
        'fingerprint=$fingerprint',
      );
      return true;
    }

    _seenIncomingPushes[fingerprint] = now.add(_incomingPushDedupTtl);
    return false;
  }

  static String _incomingPushFingerprint(RemoteMessage message) {
    final messageId = message.messageId;
    if (messageId != null && messageId.isNotEmpty) {
      return 'messageId:$messageId';
    }

    final sentAt = message.sentTime?.millisecondsSinceEpoch ?? 0;
    final title = message.notification?.title ?? '';
    final body = message.notification?.body ?? '';
    final dataEntries = message.data.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final dataSignature = dataEntries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('&');
    return 'fallback:$sentAt|$title|$body|$dataSignature';
  }

  static bool _isDuplicateNotificationClick(String? clickId) {
    if (clickId == null || clickId.isEmpty) return false;

    final now = DateTime.now();
    _seenNotificationClicks.removeWhere(
      (_, expiresAt) => expiresAt.isBefore(now),
    );
    if (_seenNotificationClicks.containsKey(clickId)) return true;

    _seenNotificationClicks[clickId] = now.add(_notificationClickDedupTtl);
    return false;
  }

  bool _shouldHoldActiveLease() {
    return _lifecycleResumed &&
        web.document.visibilityState == 'visible' &&
        web.document.hasFocus();
  }

  void _syncActiveLease() {
    if (!_activeLeaseInitialized) return;

    final active = _shouldHoldActiveLease();
    if (_lastLoggedActiveLeaseState != active) {
      _lastLoggedActiveLeaseState = active;
      Logger().info(
        '[PushNotify] Active-tab state changed: active=$active '
        'visibility=${web.document.visibilityState} '
        'focused=${web.document.hasFocus()} '
        'lifecycleResumed=$_lifecycleResumed',
      );
    }

    if (active) {
      _activeLeaseTimer ??= Timer.periodic(
        _activeLeaseInterval,
        (_) => _postActiveLease(active: true),
      );
      _postActiveLease(active: true);
    } else {
      _activeLeaseTimer?.cancel();
      _activeLeaseTimer = null;
      _postActiveLease(active: false);
    }
  }

  void _postActiveLease({required bool active}) {
    final sequence = ++_leasePostSequence;
    unawaited(_postActiveLeaseAsync(active: active, sequence: sequence));
  }

  Future<void> _postActiveLeaseAsync({
    required bool active,
    required int sequence,
  }) async {
    final registration = await _findActiveMessagingWorkerRegistration();
    final worker = registration?.active;
    if (worker == null) {
      if (!_leaseWorkerMissingLogged) {
        _leaseWorkerMissingLogged = true;
        Logger().warn(
          '[PushNotify] Active lease deferred: Firebase messaging worker '
          'is not active yet',
        );
      }
      return;
    }

    // Do not let a slow earlier lookup overwrite a newer focus/blur state.
    if (sequence != _leasePostSequence) return;

    final payload = jsonEncode({
      'type': 'APP_ACTIVE_STATE',
      'tabId': _tabLeaseId,
      'active': active,
      'url': web.window.location.href,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });

    try {
      worker.postMessage(payload.toJS);
      _leaseWorkerMissingLogged = false;
    } catch (e) {
      _warnLeaseProblem(
        '[PushNotify] Failed posting APP_ACTIVE_STATE to Firebase worker: $e',
      );
    }
  }

  static void _warnLeaseProblem(String message) {
    final now = DateTime.now();
    final lastWarning = _lastLeaseWarningAt;
    if (lastWarning != null &&
        now.difference(lastWarning) < _leaseWarningInterval) {
      return;
    }
    _lastLeaseWarningAt = now;
    Logger().warn(message);
  }

  void _announceClientReady() {
    unawaited(_announceClientReadyAsync());
  }

  Future<void> _announceClientReadyAsync() async {
    final registration = await _findActiveMessagingWorkerRegistration();
    final worker = registration?.active;
    if (worker == null) return;

    try {
      worker.postMessage(
        jsonEncode({
          'type': 'APP_CLIENT_READY',
          'tabId': _tabLeaseId,
          'url': web.window.location.href,
          'ts': DateTime.now().millisecondsSinceEpoch,
        }).toJS,
      );
    } catch (e) {
      _warnLeaseProblem('[PushNotify] Failed posting APP_CLIENT_READY: $e');
    }
  }

  void _installActiveLeaseListeners() {
    _visibilityListener ??= ((web.Event _) {
      _syncActiveLease();
    }).toJS;
    _focusListener ??= ((web.Event _) {
      _syncActiveLease();
    }).toJS;
    _blurListener ??= ((web.Event _) {
      _syncActiveLease();
    }).toJS;
    _pageHideListener ??= ((web.Event _) {
      _postActiveLease(active: false);
    }).toJS;
    _beforeUnloadListener ??= ((web.Event _) {
      _postActiveLease(active: false);
    }).toJS;

    web.document.addEventListener('visibilitychange', _visibilityListener!);
    web.window.addEventListener('focus', _focusListener!);
    web.window.addEventListener('blur', _blurListener!);
    web.window.addEventListener('pagehide', _pageHideListener!);
    web.window.addEventListener('beforeunload', _beforeUnloadListener!);
  }

  void _removeActiveLeaseListeners() {
    if (_visibilityListener != null) {
      web.document.removeEventListener(
        'visibilitychange',
        _visibilityListener!,
      );
    }
    if (_focusListener != null) {
      web.window.removeEventListener('focus', _focusListener!);
    }
    if (_blurListener != null) {
      web.window.removeEventListener('blur', _blurListener!);
    }
    if (_pageHideListener != null) {
      web.window.removeEventListener('pagehide', _pageHideListener!);
    }
    if (_beforeUnloadListener != null) {
      web.window.removeEventListener('beforeunload', _beforeUnloadListener!);
    }
  }

  Future<void> _routeNotificationWithRetries(
    RemoteMessage message, {
    required String source,
  }) async {
    for (int attempt = 1; attempt <= 8; attempt++) {
      try {
        final contextReady =
            NavigationManager().navigatorKey.currentContext != null;
        if (!contextReady) {
          Logger().info(
            '[PushNotify] $source route deferred (attempt $attempt/8): '
            'navigation context not ready',
          );
        } else {
          notificationRouting(message);
          Logger().info(
            '[PushNotify] $source route dispatched on attempt $attempt/8 '
            'for key=${message.data['key']}',
          );
          return;
        }
      } catch (e) {
        Logger().warn(
          '[PushNotify] $source route attempt $attempt/8 failed: $e',
        );
      }

      if (attempt < 8) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }

    Logger().error(
      '[PushNotify] $source route failed after retries '
      'for key=${message.data['key']}',
    );
  }

  /// Listen for foreground pushes and notification clicks from the worker.
  void _initializeServiceWorkerClickHandler() {
    if (_swClickHandlerInitialized) {
      _announceClientReady();
      return;
    }
    _swClickHandlerInitialized = true;

    final swContainer = web.window.navigator.serviceWorker;
    swContainer.startMessages();
    swContainer.addEventListener(
      'message',
      ((web.Event event) {
        final messageEvent = event as web.MessageEvent;
        _handleServiceWorkerClickMessage(
          messageEvent.data,
          source: 'navigator.serviceWorker',
        );
      }).toJS,
    );

    // Keep this fallback for integrations that relay worker messages through
    // window.postMessage. Same-origin checking prevents cross-origin input.
    web.window.onMessage.listen((event) {
      if (event.origin != web.window.location.origin) return;
      _handleServiceWorkerClickMessage(event.data, source: 'window');
    });

    Logger().info(
      '[PushNotify] Firebase service-worker message listeners attached',
    );
    _announceClientReady();
  }

  void _handleServiceWorkerClickMessage(
    dynamic data, {
    required String source,
  }) {
    try {
      if (data == null) return;

      Map<String, dynamic> message;
      if (data is String) {
        dynamic decoded;
        try {
          decoded = jsonDecode(data);
        } catch (_) {
          return;
        }
        if (decoded is! Map) return;
        message = Map<String, dynamic>.from(decoded);
      } else if (data is Map) {
        message = Map<String, dynamic>.from(data);
      } else {
        // Explicit JSON strings avoid JS-object conversion differences across
        // package:web and browser versions.
        return;
      }

      final type = message['type'];
      if (type == 'SW_READY_PROBE') {
        _announceClientReady();
        return;
      }

      if (type == 'FCM_PUSH') {
        final rawPayload = message['payload'];
        if (rawPayload is! Map) return;

        final payload = Map<String, dynamic>.from(rawPayload);
        final rawData = payload['data'];
        final rawNotification = payload['notification'];
        final remoteMessage = RemoteMessage.fromMap({
          ...payload,
          'data': rawData is Map
              ? Map<String, dynamic>.from(rawData)
              : <String, dynamic>{},
          if (rawNotification is Map)
            'notification': Map<String, dynamic>.from(rawNotification),
        });
        unawaited(_foregroundMessageHandler(remoteMessage));
        return;
      }

      if (type != 'NOTIFICATION_CLICK') {
        Logger().info('[PushNotify] $source ignored message type: $type');
        return;
      }

      final clickId = message['clickId'] as String?;
      if (_isDuplicateNotificationClick(clickId)) {
        Logger().info(
          '[PushNotify] Duplicate notification click suppressed: $clickId',
        );
        return;
      }

      Logger().info(
        '[PushNotify] $source notification click detected in Flutter',
      );
      final route = message['route'] as String?;
      final deepLink = message['deepLink'] as String?;
      final rawPayload = message['payload'];
      final payload = rawPayload is Map
          ? Map<String, dynamic>.from(rawPayload)
          : null;

      final clickMessage = RemoteMessage(
        data: payload ?? {},
        notification: RemoteNotification(
          title: payload?['title'] as String?,
          body: payload?['body'] as String?,
        ),
      );

      if (deepLink != null || route != null) {
        unawaited(
          _routeNotificationWithRetries(
            clickMessage,
            source: 'serviceWorker.click',
          ),
        );
      } else {
        Logger().warn(
          '[PushNotify] $source click payload missing route/deepLink',
        );
      }
    } catch (e, stackTrace) {
      Logger().error(
        '[PushNotify] Error processing $source message: '
        '$e\n$stackTrace',
      );
    }
  }
}
