import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:exacqvision_lite/auth/interceptor_store.dart';
import 'package:exacqvision_lite/event_monitoring/actions.dart';
import 'package:exacqvision_lite/event_monitoring/event_source_to_event_type.dart';
import 'package:exacqvision_lite/event_monitoring/selectors.dart';
import 'package:exacqvision_lite/server/selectors.dart';
import 'package:exacqvision_lite/store.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:grpc/service_api.dart';
import 'package:nvrsdk/rpc/event_publisher.pbgrpc.dart';
import 'package:nvrsdk/status/event.pb.dart';
import 'package:web/web.dart' as web;

import '../logging/logger.dart';

typedef WebAlertMessageHandler = Future<void> Function(RemoteMessage message);

/// Maintains direct EventPublisher streams while the web app is visible and
/// focused. Incoming events are converted to the same [RemoteMessage] shape as
/// FCM and handed back to FirebaseService for shared caching, UI, and
/// cross-transport deduplication.
class WebAlertStreamManager {
  static final WebAlertStreamManager _instance =
      WebAlertStreamManager._internal();

  WebAlertStreamManager._internal();

  factory WebAlertStreamManager() => _instance;

  static const Duration _stateChangeDebounce = Duration(milliseconds: 250);
  static const int _maximumReconnectSeconds = 30;
  static const String _persistedSubscriptionsKey =
      'eventMonitoring.webAlertSubscriptions.v1';

  final Map<String, StreamSubscription<Event>> _streams = {};
  final Map<String, Timer> _retryTimers = {};
  final Map<String, int> _retryAttempts = {};
  final Map<String, int> _serverGenerations = {};
  final math.Random _random = math.Random();

  final StreamController<(String serverSlug, Event event)>
  _alertStreamController = StreamController<(String, Event)>.broadcast();

  StreamSubscription<dynamic>? _storeSubscription;
  Timer? _stateChangeTimer;
  WebAlertMessageHandler? _onMessage;
  String? _lastSubscriptionSignature;
  String? _lastPersistedSubscriptions;
  bool _initialized = false;
  bool _active = false;

  Stream<(String, Event)> get alertStream => _alertStreamController.stream;

  bool hasActiveStream(String serverSlug) => _streams.containsKey(serverSlug);

  /// Attaches to the existing Redux store. Safe to call more than once.
  void initialize({
    required WebAlertMessageHandler onMessage,
    required bool active,
  }) {
    _onMessage = onMessage;
    _active = active;

    if (!_initialized) {
      _initialized = true;
      final store = AppStoreService().getStore();
      _restorePersistedSubscriptions(store);
      _storeSubscription = store.onChange.listen((_) {
        _persistSubscriptions(store.state);
        _scheduleStateSync();
      });
      _persistSubscriptions(store.state);
      Logger().info('[WebAlertStream] Redux subscription observer attached');
    }

    _lastSubscriptionSignature = null;
    if (_active) {
      _scheduleStateSync(immediate: true);
    } else {
      unawaited(_stopAllStreams());
    }
  }

  /// Starts or stops direct streams as web-app focus changes.
  void setAppActive(bool active) {
    if (_active == active) {
      if (active) _scheduleStateSync();
      return;
    }

    _active = active;
    _lastSubscriptionSignature = null;
    Logger().info('[WebAlertStream] app active=$active');

    if (active) {
      _scheduleStateSync(immediate: true);
    } else {
      _stateChangeTimer?.cancel();
      _stateChangeTimer = null;
      unawaited(_stopAllStreams());
    }
  }

  /// Explicit refresh hook retained for diagnostics and future callers.
  Future<void> refreshSubscription(String serverSlug) async {
    final generation = _nextGeneration(serverSlug);
    _retryTimers.remove(serverSlug)?.cancel();

    final previous = _streams.remove(serverSlug);
    if (previous != null) {
      try {
        await previous.cancel();
      } catch (error) {
        Logger().warn(
          '[WebAlertStream] failed cancelling old stream for '
          '$serverSlug: $error',
        );
      }
    }

    if (!_isCurrent(serverSlug, generation) || !_active) return;

    final state = AppStoreService().getStore().state;
    final subscriptionItems = _buildSubscriptionItems(state, serverSlug);
    if (subscriptionItems.isEmpty) {
      _retryAttempts.remove(serverSlug);
      Logger().info('[WebAlertStream] no direct subscriptions for $serverSlug');
      return;
    }

    try {
      final connection = getConnection(serverSlug, state: state);
      final client = EventPublisherClient(
        connection.channel,
        interceptors: await connection.interceptors,
        options: CallOptions(metadata: connection.attempt.metadata),
      );

      if (!_isCurrent(serverSlug, generation) || !_active) return;

      final request = EventSubscriptionRequest(
        subscriptionList: subscriptionItems,
      );
      final response = client.subscribe(request);

      late final StreamSubscription<Event> subscription;
      subscription = response.listen(
        (event) {
          if (!_isCurrent(serverSlug, generation) || !_active) return;
          _retryAttempts.remove(serverSlug);
          unawaited(_handleEvent(serverSlug, event));
        },
        onError: (Object error, StackTrace stackTrace) {
          _handleStreamEnded(
            serverSlug,
            generation,
            error: error,
            stackTrace: stackTrace,
          );
        },
        onDone: () {
          _handleStreamEnded(serverSlug, generation);
        },
        cancelOnError: true,
      );

      if (!_isCurrent(serverSlug, generation) || !_active) {
        await subscription.cancel();
        return;
      }

      _streams[serverSlug] = subscription;
      Logger().info(
        '[WebAlertStream] subscribed to ${subscriptionItems.length} '
        'source groups on $serverSlug',
      );
    } catch (error, stackTrace) {
      if (!_isCurrent(serverSlug, generation) || !_active) return;
      Logger().error(
        '[WebAlertStream] failed to subscribe on $serverSlug: '
        '$error\n$stackTrace',
      );
      _scheduleReconnect(serverSlug, generation);
    }
  }

  Future<void> cancelForServer(String serverSlug) => _cancelServer(serverSlug);

  Future<void> cancelAll() => _stopAllStreams();

  Future<void> dispose() async {
    _initialized = false;
    _active = false;
    _stateChangeTimer?.cancel();
    _stateChangeTimer = null;
    await _storeSubscription?.cancel();
    _storeSubscription = null;
    await _stopAllStreams();
    _onMessage = null;
    _lastSubscriptionSignature = null;
  }

  void _scheduleStateSync({bool immediate = false}) {
    if (!_initialized || !_active) return;

    _stateChangeTimer?.cancel();
    _stateChangeTimer = null;
    if (immediate) {
      unawaited(_syncSubscriptionsFromState());
      return;
    }

    _stateChangeTimer = Timer(_stateChangeDebounce, () {
      _stateChangeTimer = null;
      unawaited(_syncSubscriptionsFromState());
    });
  }

  Future<void> _syncSubscriptionsFromState() async {
    if (!_active) return;

    final state = AppStoreService().getStore().state;
    final signature = _subscriptionSignature(state);
    if (signature == _lastSubscriptionSignature) return;
    _lastSubscriptionSignature = signature;

    final desiredServers = _desiredServers(state);
    final knownServers = <String>{
      ..._streams.keys,
      ..._retryTimers.keys,
      ..._serverGenerations.keys,
    };

    await Future.wait(
      knownServers
          .where((server) => !desiredServers.contains(server))
          .map(_cancelServer),
    );
    if (!_active) return;

    await Future.wait(desiredServers.map(refreshSubscription));
  }

  Set<String> _desiredServers(dynamic state) {
    final servers = <String>{};
    for (final serverMap in getSubscribedLinks(state).values) {
      for (final entry in serverMap.entries) {
        if (entry.value.isNotEmpty) servers.add(entry.key);
      }
    }
    return servers;
  }

  void _restorePersistedSubscriptions(dynamic store) {
    if (getSubscribedLinks(store.state).isNotEmpty) return;

    try {
      final raw = web.window.localStorage.getItem(_persistedSubscriptionsKey);
      if (raw == null || raw.isEmpty) return;

      final decoded = jsonDecode(raw);
      if (decoded is! Map ||
          decoded['version'] != 1 ||
          decoded['subscriptions'] is! Map) {
        return;
      }

      final restored = _parsePersistedSubscriptions(decoded['subscriptions']);
      if (restored.isEmpty) return;
      store.dispatch(UpdateSubscribedLinks(restored));
      Logger().info(
        '[WebAlertStream] restored ${restored.length} persisted profiles',
      );
    } catch (error) {
      Logger().warn(
        '[WebAlertStream] failed restoring persisted subscriptions: $error',
      );
    }
  }

  void _persistSubscriptions(dynamic state) {
    try {
      final subscriptions = getSubscribedLinks(state);
      if (subscriptions.isEmpty) {
        if (_lastPersistedSubscriptions != null ||
            web.window.localStorage.getItem(_persistedSubscriptionsKey) !=
                null) {
          web.window.localStorage.removeItem(_persistedSubscriptionsKey);
          _lastPersistedSubscriptions = null;
        }
        return;
      }

      final encoded = jsonEncode({
        'version': 1,
        'subscriptions': subscriptions,
      });
      if (encoded == _lastPersistedSubscriptions) return;

      web.window.localStorage.setItem(_persistedSubscriptionsKey, encoded);
      _lastPersistedSubscriptions = encoded;
    } catch (error) {
      Logger().warn('[WebAlertStream] failed persisting subscriptions: $error');
    }
  }

  Map<String, Map<String, List<String>>> _parsePersistedSubscriptions(
    dynamic raw,
  ) {
    if (raw is! Map) return const {};

    final parsed = <String, Map<String, List<String>>>{};
    for (final profileEntry in raw.entries) {
      if (profileEntry.key is! String || profileEntry.value is! Map) continue;

      final servers = <String, List<String>>{};
      for (final serverEntry in (profileEntry.value as Map).entries) {
        if (serverEntry.key is! String || serverEntry.value is! List) continue;
        final guids = (serverEntry.value as List).whereType<String>().toList();
        if (guids.isNotEmpty) servers[serverEntry.key as String] = guids;
      }
      if (servers.isNotEmpty) {
        parsed[profileEntry.key as String] = servers;
      }
    }
    return parsed;
  }

  String _subscriptionSignature(dynamic state) {
    final subscribedLinks = getSubscribedLinks(state);
    final profilesById = {
      for (final profile in getProfiles(state)) profile.id: profile,
    };
    final parts = <String>[];
    final profileIds = subscribedLinks.keys.toList()..sort();

    for (final profileId in profileIds) {
      final profile = profilesById[profileId];
      parts.add('profile:$profileId:${profile?.name ?? ''}');

      final serverMap = subscribedLinks[profileId]!;
      final servers = serverMap.keys.toList()..sort();
      for (final server in servers) {
        final guids = List<String>.from(serverMap[server] ?? const [])..sort();
        parts.add('server:$server:${guids.join(",")}');

        if (profile == null) continue;
        final guidSet = guids.toSet();
        final links =
            profile.links
                .where(
                  (link) =>
                      link.server == server && guidSet.contains(link.guid),
                )
                .toList()
              ..sort((a, b) => a.guid.compareTo(b.guid));
        for (final link in links) {
          parts.add(
            'link:${link.guid}:${link.source.type.value}:${link.sourceID}',
          );
        }
      }
    }
    return parts.join('|');
  }

  List<EventTypesForStream> _buildSubscriptionItems(
    dynamic state,
    String serverSlug,
  ) {
    final subscribedLinks = getSubscribedLinks(state);
    final profilesById = {
      for (final profile in getProfiles(state)) profile.id: profile,
    };
    final merged = <int, Set<EventType>>{};

    for (final entry in subscribedLinks.entries) {
      final linkGuids = entry.value[serverSlug];
      if (linkGuids == null || linkGuids.isEmpty) continue;

      final profile = profilesById[entry.key];
      if (profile == null) continue;
      final guidSet = linkGuids.toSet();

      for (final link in profile.links) {
        if (link.server != serverSlug || !guidSet.contains(link.guid)) {
          continue;
        }

        final eventType = eventSourceToEventType(link.source.type);
        if (eventType == null) continue;
        final sourceStreamId = int.tryParse(link.sourceID) ?? 0;
        merged.putIfAbsent(sourceStreamId, () => <EventType>{}).add(eventType);
      }
    }

    return merged.entries
        .map(
          (entry) => EventTypesForStream(
            eventSourceStreamId: entry.key,
            eventTypeList: entry.value.toList(),
          ),
        )
        .toList();
  }

  Future<void> _handleEvent(String serverSlug, Event event) async {
    if (!_active || event.cached) return;

    final state = AppStoreService().getStore().state;
    final payloadEventType = eventTypeToPayloadSource(event.type);
    if (payloadEventType == null) return;

    final sourceId = _extractSourceId(event);
    final matches = _matchingProfileLinks(
      serverSlug,
      event.type,
      sourceId,
      state,
    ).toList();
    if (matches.isEmpty) return;

    final serverName = getServerName(state, serverSlug);
    final serverSerial = getServerMacAddress(state, serverSlug);
    final eventTime = event.hasStartTime()
        ? DateTime.fromMillisecondsSinceEpoch(
            event.startTime.seconds.toInt() * 1000,
            isUtc: true,
          )
        : DateTime.now().toUtc();

    for (final match in matches) {
      if (!_active) return;

      final (profileName, linkGuid) = match;
      final data = <String, String>{
        'key': 'event_monitor_profile',
        'property': profileName,
        'link_guid': linkGuid,
        'server_name': serverName,
        'server_serial': serverSerial,
        'source_id': sourceId,
        'time': eventTime.toIso8601String(),
        'event_type': payloadEventType.toString(),
      };
      final message = RemoteMessage(
        messageId:
            'web_${serverSlug}_${linkGuid}_${eventTime.millisecondsSinceEpoch}',
        notification: RemoteNotification(title: profileName, body: serverName),
        data: data,
        sentTime: eventTime,
      );

      try {
        final handler = _onMessage;
        if (handler != null) await handler(message);
      } catch (error, stackTrace) {
        Logger().error(
          '[WebAlertStream] delivery failed for $profileName '
          '($linkGuid): $error\n$stackTrace',
        );
      }
    }

    _alertStreamController.add((serverSlug, event));
  }

  Iterable<(String profileName, String linkGuid)> _matchingProfileLinks(
    String serverSlug,
    EventType eventType,
    String sourceId,
    dynamic state,
  ) sync* {
    final subscribedLinks = getSubscribedLinks(state);
    final profilesById = {
      for (final profile in getProfiles(state)) profile.id: profile,
    };

    for (final entry in subscribedLinks.entries) {
      final linkGuids = entry.value[serverSlug];
      if (linkGuids == null || linkGuids.isEmpty) continue;

      final profile = profilesById[entry.key];
      if (profile == null) continue;
      final guidSet = linkGuids.toSet();

      for (final link in profile.links) {
        if (link.server != serverSlug || !guidSet.contains(link.guid)) {
          continue;
        }
        if (eventSourceToEventType(link.source.type) != eventType) continue;
        if (link.sourceID != '0' && link.sourceID != sourceId) continue;
        yield (profile.name, link.guid);
      }
    }
  }

  String _extractSourceId(Event event) {
    switch (event.type) {
      case EventType.EVENT_TYPE_MOTION:
        return event.motion.id.toString();
      case EventType.EVENT_TYPE_INPUT_TRIGGER:
        return event.inputTrigger.deviceId.toString();
      case EventType.EVENT_TYPE_SOFT_TRIGGER:
        return event.softTrigger.id.toString();
      case EventType.EVENT_TYPE_TIME_TRIGGER:
        return event.timeTrigger.id.toString();
      case EventType.EVENT_TYPE_ANALYTICS:
        return event.analytics.deviceId.toString();
      case EventType.EVENT_TYPE_DEVICE_FAIL:
        return event.deviceFail.deviceId.toString();
      case EventType.EVENT_TYPE_DEVICE_CONNECTION_STATUS:
        return event.deviceConnectionStatus.id.toString();
      case EventType.EVENT_TYPE_SECURITY_SENSOR:
        return event.securitySensor.sensorId.toString();
      case EventType.EVENT_TYPE_SECURITY_DEVICE_CONNECTION:
        return event.securityDeviceConnection.deviceId.toString();
      case EventType.EVENT_TYPE_DEVICE_BUTTON:
        return event.deviceButton.deviceId.toString();
      case EventType.EVENT_TYPE_SERIAL_PORT:
        return event.serialPort.deviceId.toString();
      case EventType.EVENT_TYPE_SERIAL_PROFILE:
        return event.serialProfile.deviceId.toString();
      case EventType.EVENT_TYPE_INPUT_STREAM_CONNECTION:
        return event.inputStreamConnection.id.toString();
      case EventType.EVENT_TYPE_EVENT_SOURCE_GROUP:
        return event.eventSourceGroup.sourceGroupId.toString();
      case EventType.EVENT_TYPE_AUTO_CONNECTION:
        return event.autoConnection.id.toString();
      default:
        return '0';
    }
  }

  void _handleStreamEnded(
    String serverSlug,
    int generation, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (!_isCurrent(serverSlug, generation)) return;
    _streams.remove(serverSlug);

    if (error != null) {
      Logger().warn(
        '[WebAlertStream] stream error for $serverSlug: $error'
        '${stackTrace == null ? '' : '\n$stackTrace'}',
      );
    } else {
      Logger().info(
        '[WebAlertStream] stream ended for $serverSlug; reconnecting',
      );
    }
    _scheduleReconnect(serverSlug, generation);
  }

  void _scheduleReconnect(String serverSlug, int generation) {
    if (!_active ||
        !_isCurrent(serverSlug, generation) ||
        !_serverHasDesiredSubscriptions(serverSlug) ||
        _retryTimers.containsKey(serverSlug)) {
      return;
    }

    final attempt = (_retryAttempts[serverSlug] ?? 0) + 1;
    _retryAttempts[serverSlug] = attempt;
    final exponent = math.min(attempt - 1, 5);
    final baseSeconds = math.min(1 << exponent, _maximumReconnectSeconds);
    final delay = Duration(
      seconds: baseSeconds,
      milliseconds: _random.nextInt(500),
    );

    Logger().info(
      '[WebAlertStream] reconnect $attempt for $serverSlug '
      'in ${delay.inMilliseconds}ms',
    );
    _retryTimers[serverSlug] = Timer(delay, () {
      _retryTimers.remove(serverSlug);
      if (_active && _isCurrent(serverSlug, generation)) {
        unawaited(refreshSubscription(serverSlug));
      }
    });
  }

  bool _serverHasDesiredSubscriptions(String serverSlug) {
    final state = AppStoreService().getStore().state;
    return getSubscribedLinks(
      state,
    ).values.any((serverMap) => serverMap[serverSlug]?.isNotEmpty ?? false);
  }

  int _nextGeneration(String serverSlug) {
    final generation = (_serverGenerations[serverSlug] ?? 0) + 1;
    _serverGenerations[serverSlug] = generation;
    return generation;
  }

  bool _isCurrent(String serverSlug, int generation) =>
      _serverGenerations[serverSlug] == generation;

  Future<void> _cancelServer(String serverSlug) async {
    _nextGeneration(serverSlug);
    _retryTimers.remove(serverSlug)?.cancel();
    _retryAttempts.remove(serverSlug);
    final subscription = _streams.remove(serverSlug);
    if (subscription == null) return;

    try {
      await subscription.cancel();
    } catch (error) {
      Logger().warn('[WebAlertStream] failed cancelling $serverSlug: $error');
    }
  }

  Future<void> _stopAllStreams() async {
    final servers = <String>{
      ..._streams.keys,
      ..._retryTimers.keys,
      ..._serverGenerations.keys,
    };
    final subscriptions = <StreamSubscription<Event>>[];

    for (final server in servers) {
      _nextGeneration(server);
      _retryTimers.remove(server)?.cancel();
      _retryAttempts.remove(server);
      final subscription = _streams.remove(server);
      if (subscription != null) subscriptions.add(subscription);
    }

    await Future.wait(
      subscriptions.map((subscription) async {
        try {
          await subscription.cancel();
        } catch (error) {
          Logger().warn('[WebAlertStream] failed cancelling stream: $error');
        }
      }),
    );
  }
}
