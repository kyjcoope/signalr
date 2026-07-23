/// Immutable wrapper for grpc EventMonitoringProfile that adds server
/// provenance to every link.
@immutable
class EvEventMonitoringProfile extends Equatable
    implements Comparable<EvEventMonitoringProfile> {
  final String id;
  final String name;
  final String description;
  final EventProfileType type;
  final int flags;
  final List<EvEventProfileLink> links;

  @override
  int compareTo(EvEventMonitoringProfile other) {
    return name.toLowerCase().compareTo(other.name.toLowerCase());
  }

  EvEventMonitoringProfile({
    this.id = '',
    this.name = '',
    this.description = '',
    this.type = EventProfileType.EVENT_PROFILE_TYPE_NONE,
    this.flags = 0,
    List<EvEventProfileLink> links = const [],
  }) : links = List.unmodifiable(links);

  EvEventMonitoringProfile.fromGrpc(
    EventMonitoringProfile profile,
    String server,
  ) : this(
        id: profile.id,
        name: profile.name,
        description: profile.description,
        type: profile.type,
        flags: profile.flags.toInt(),
        links: profile.links
            .map(
              (link) => EvEventProfileLink(
                server: server,
                guid: link.guid,
                message: link.message,
                timeout: Duration(seconds: link.timeout.seconds.toInt()),
                priority: link.priority,
                confirm: link.confirm,
                source: link.source,
                target: link.target,
                triggeredByEventLink: link.triggeredByEventLink,
              ),
            )
            .toList(),
      );

  EvEventMonitoringProfile copyWith({
    String? id,
    String? name,
    String? description,
    EventProfileType? type,
    int? flags,
    List<EvEventProfileLink>? links,
  }) {
    return EvEventMonitoringProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      type: type ?? this.type,
      flags: flags ?? this.flags,
      links: links ?? this.links,
    );
  }

  @override
  List<Object?> get props => [
    id,
    name,
    description,
    type.name,
    type.value,
    flags,
    links,
  ];
}

EventLinkSource _freezeEventLinkSource(EventLinkSource? source) {
  final value = EventLinkSource.clone(
    source ??
        EventLinkSource(
          type: EventSource.EVENT_SOURCE_NONE,
          id: EventLinkIdentifier(),
        ),
  );
  value.freeze();
  return value;
}

EventProfileLinkTarget _freezeEventLinkTarget(EventProfileLinkTarget? target) {
  final value = EventProfileLinkTarget.clone(
    target ?? EventProfileLinkTarget(),
  );
  value.freeze();
  return value;
}

/// Immutable wrapper for EventProfileLink that includes its server slug.
@immutable
class EvEventProfileLink extends Equatable
    implements Comparable<EvEventProfileLink> {
  final String server;
  final String guid;
  final String message;
  final Duration timeout;
  final int priority;
  final bool confirm;
  final EventLinkSource source;
  final EventProfileLinkTarget target;
  final bool triggeredByEventLink;
  final int? analyticRuleId;
  final bool securityAlarm;

  @override
  int compareTo(EvEventProfileLink other) {
    return priority.compareTo(other.priority);
  }

  String get sourceID {
    switch (source.type) {
      case EventSource.EVENT_SOURCE_ANALYTICS:
        return source.id.analyticRuleId.deviceId.toString();
      case EventSource.EVENT_SOURCE_HEALTH:
        return source.id.healthId.event.name;
      case EventSource.EVENT_SOURCE_DISCONNECT_SECURITY:
      case EventSource.EVENT_SOURCE_SECURITY:
        return source.id.securityId.deviceId.toString();
      default:
        return source.id.stringId.isNotEmpty
            ? source.id.stringId
            : source.id.numericId.toString();
    }
  }

  EvEventProfileLink({
    this.server = '',
    this.guid = '',
    this.message = '',
    this.timeout = Duration.zero,
    this.priority = 0,
    this.confirm = true,
    EventLinkSource? source,
    EventProfileLinkTarget? target,
    this.triggeredByEventLink = true,
    this.analyticRuleId,
    this.securityAlarm = false,
  }) : source = _freezeEventLinkSource(source),
       target = _freezeEventLinkTarget(target);

  @override
  List<Object?> get props => [
    server,
    guid,
    message,
    timeout,
    priority,
    confirm,
    source.writeToJson(),
    target.writeToJson(),
    triggeredByEventLink,
    analyticRuleId,
    securityAlarm,
  ];
}
