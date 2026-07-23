class AnimatedEventProfileListItem extends StatefulWidget {
  final EvEventMonitoringProfile profile;
  final bool showIcon;
  final bool initialState;
  final Function(bool value) onToggle;

  const AnimatedEventProfileListItem({
    super.key,
    required this.profile,
    required this.onToggle,
    this.initialState = false,
    this.showIcon = true,
  });

  @override
  State<AnimatedEventProfileListItem> createState() =>
      _AnimatedEventProfileListItem();
}

class _AnimatedEventProfileListItem
    extends State<AnimatedEventProfileListItem> {
  static const _waitDuration = Duration(milliseconds: 500);

  bool _state = false;
  Timer? _toggleTimer;

  @override
  void initState() {
    super.initState();
    _state = widget.initialState;
  }

  @override
  void didUpdateWidget(AnimatedEventProfileListItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile.id != widget.profile.id) {
      _toggleTimer?.cancel();
      _state = widget.initialState;
    } else if (_toggleTimer?.isActive != true &&
        oldWidget.initialState != widget.initialState) {
      _state = widget.initialState;
    }
  }

  @override
  void dispose() {
    _toggleTimer?.cancel();
    super.dispose();
  }

  void _toggleProfile(bool isSelected) {
    setState(() => _state = isSelected);

    // Preserve the existing switch-settle delay while ensuring latest intent
    // wins and no callback survives disposal.
    _toggleTimer?.cancel();
    _toggleTimer = Timer(_waitDuration, () {
      if (mounted) widget.onToggle(isSelected);
    });
  }

  @override
  Widget build(BuildContext context) {
    return EventProfileListItem(
      profile: widget.profile,
      showIcon: widget.showIcon,
      onToggle: _toggleProfile,
      switchState: _state,
    );
  }
}

class StaticEventProfileListItem extends StatelessWidget {
  final EvEventMonitoringProfile profile;
  final bool showIcon;
  final bool switchState;
  final Animation<double> animation;

  const StaticEventProfileListItem({
    super.key,
    required this.profile,
    required this.switchState,
    required this.animation,
    this.showIcon = true,
  });

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor: animation,
      child: EventProfileListItem(
        profile: profile,
        showIcon: showIcon,
        onToggle: (_) {},
        switchState: switchState,
      ),
    );
  }
}

class EventProfileListItem extends StatelessWidget {
  final EvEventMonitoringProfile profile;
  final bool showIcon;
  final Function(bool value) onToggle;
  final bool switchState;

  const EventProfileListItem({
    super.key,
    required this.profile,
    required this.onToggle,
    required this.switchState,
    this.showIcon = true,
  });

  String _buildServerSubtitle(Model model, List<String> slugs) {
    if (slugs.isEmpty) return '';

    var subtitle = getServerName(model.store.state, slugs.first);
    if (slugs.length > 1) {
      subtitle += ' + ${slugs.length - 1} ${LocaleKeys.otherWord.tr()}';
    }
    return subtitle;
  }

  @override
  Widget build(BuildContext context) {
    return StoreConnector<AppState, Model>(
      converter: (store) => Model(store, profile.id),
      builder: (context, model) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => Navigator.pushNamed(
          context,
          RoutePaths.settingsEventMonitoringProfileLinks.path,
          arguments: profile,
        ),
        child: Container(
          padding: EdgeInsets.fromLTRB(showIcon ? 8 : 0, 8, 8, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              showIcon ? Icon(Ev.notifications) : const SizedBox.shrink(),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CenterEllipsesText(text: profile.name),
                      Text(
                        _buildServerSubtitle(model, model.serversForProfile),
                        style: evStyle(context, CraftStyle.fourteenFive),
                      ),
                    ],
                  ),
                ),
              ),
              Row(
                children: [
                  Switch(value: switchState, onChanged: onToggle),
                  const SizedBox(width: 5),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 0, 15, 0),
                    child: Icon(
                      Icons.arrow_forward_ios,
                      size: 15,
                      color: EvTheme.get.theme.sIconPrimary,
                      textDirection: Directionality.of(context),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      distinct: true,
    );
  }
}

class Model extends EvViewModel {
  final String profileId;
  final List<String> subscribedLinks;
  final List<String> serversForProfile;

  Model(super.store, this.profileId)
    : subscribedLinks = getSubsribedLinksForProfile(store.state, profileId),
      serversForProfile = getServersForProfile(store.state, profileId);

  @override
  List<Object?> get props => [profileId, subscribedLinks, serversForProfile];
}
