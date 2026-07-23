class EventMonitoringProfilesListPage extends StatefulWidget {
  final EventMonitorTab tab;
  final String searchFilter;
  final SortTypes sortType;

  const EventMonitoringProfilesListPage({
    super.key,
    required this.tab,
    required this.searchFilter,
    this.sortType = SortTypes.alpha,
  });

  @override
  State<EventMonitoringProfilesListPage> createState() =>
      _EventMonitoringProfilesListPage();
}

class _EventMonitoringProfilesListPage
    extends State<EventMonitoringProfilesListPage> {
  late EventMonitorListModel _model;
  List<EvEventMonitoringProfile> _filteredProfiles = [];
  GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();

  void _storeInit(Store<AppState> store) {
    _model = EventMonitorListModel(store);
    _filteredProfiles = _getComputedList();
  }

  List<EvEventMonitoringProfile> _getComputedList() {
    final profiles = _model.profiles
        .where(
          (profile) =>
              profile.name.toLowerCase().contains(
                widget.searchFilter.toLowerCase(),
              ) &&
              _model.statusMatches(profile, widget.tab),
        )
        .toList();

    return widget.sortType == SortTypes.alphaDesc
        ? profiles.reversed.toList()
        : profiles;
  }

  void _recalculateFilteredProfiles({bool forceReset = false}) {
    final next = _getComputedList();
    final currentIds = _filteredProfiles.map((profile) => profile.id).toList();
    final nextIds = next.map((profile) => profile.id).toList();
    final identitiesChanged = !listEquals(currentIds, nextIds);

    setState(() {
      _filteredProfiles = next;
      if (forceReset || identitiesChanged) {
        _listKey = GlobalKey<AnimatedListState>();
      }
    });
  }

  void _modelUpdater(
    EventMonitorListModel? oldModel,
    EventMonitorListModel newModel,
  ) {
    if (!mounted) return;
    _model = newModel;
    _recalculateFilteredProfiles();
  }

  @override
  void didUpdateWidget(EventMonitoringProfilesListPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tab != oldWidget.tab ||
        widget.searchFilter != oldWidget.searchFilter ||
        widget.sortType != oldWidget.sortType) {
      _recalculateFilteredProfiles(forceReset: true);
    }
  }

  Widget _buildProfileDisplayCount(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          Text(
            widget.tab.description(_filteredProfiles.length),
            style: evStyle(context, CraftStyle.fourteenFive),
          ),
        ],
      ),
    );
  }

  void _onToggle(bool value, String profileId) {
    final index = _filteredProfiles.indexWhere(
      (profile) => profile.id == profileId,
    );
    if (index < 0) return;

    final profile = _filteredProfiles[index];
    setState(() => _filteredProfiles.removeAt(index));
    _listKey.currentState?.removeItem(
      index,
      (context, animation) =>
          _staticEventProfileTile(profile, animation, state: value),
      duration: const Duration(milliseconds: 300),
    );

    if (value) {
      _model.subscribeAll(profile);
    } else {
      _model.unsubscribeAll(profile);
    }
  }

  Widget _staticEventProfileTile(
    EvEventMonitoringProfile profile,
    Animation<double> animation, {
    bool state = false,
  }) {
    return StaticEventProfileListItem(
      profile: profile,
      switchState: state,
      animation: animation,
      showIcon: false,
    );
  }

  Widget _buildItem(
    BuildContext context,
    int index,
    Animation<double> animation,
  ) {
    if (index >= _filteredProfiles.length) {
      return const SizedBox.shrink();
    }

    final profile = _filteredProfiles[index];
    return wrapDivider(
      SizeTransition(
        sizeFactor: animation,
        child: AnimatedEventProfileListItem(
          key: ValueKey(profile.id),
          profile: profile,
          showIcon: false,
          initialState: _model.profileIsActive(profile),
          onToggle: (value) => _onToggle(value, profile.id),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StoreConnector<AppState, EventMonitorListModel>(
      converter: EventMonitorListModel.new,
      builder: (context, model) => Column(
        children: [
          _buildProfileDisplayCount(context),
          Expanded(
            child: AnimatedList(
              key: _listKey,
              initialItemCount: _filteredProfiles.length,
              itemBuilder: _buildItem,
            ),
          ),
        ],
      ),
      onInit: _storeInit,
      onWillChange: _modelUpdater,
      distinct: true,
    );
  }
}
