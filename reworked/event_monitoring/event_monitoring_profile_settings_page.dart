String displayProfiles(String objectName) =>
    LocaleKeys.displayingProfiles.tr(args: [objectName]);

class EventMonitoringProfilesSettingsPage extends StatefulWidget {
  const EventMonitoringProfilesSettingsPage({super.key});

  @override
  State<EventMonitoringProfilesSettingsPage> createState() =>
      _EventMonitoringProfilesSettingsPageState();
}

class _EventMonitoringProfilesSettingsPageState
    extends State<EventMonitoringProfilesSettingsPage>
    with SingleTickerProviderStateMixin {
  late EventMonitorListModel _model;
  late TabController _tabController;

  String _searchFilter = '';
  SortTypes _sortType = SortTypes.alpha;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _storeInit(Store<AppState> store) {
    _model = EventMonitorListModel(store);
  }

  void _modelUpdater(
    EventMonitorListModel? oldModel,
    EventMonitorListModel newModel,
  ) {
    if (!mounted) return;
    _model = newModel;
    if (!_model.hasEventMonitoringPrivileges) {
      Navigator.pushReplacementNamed(
        NavBarNavigationManager().context,
        RoutePaths.more.path,
      );
    }
  }

  void _onSearch(String text) {
    setState(() => _searchFilter = text);
  }

  List<EvEventMonitoringProfile> _filterFunc(
    String filter, {
    SortTypes? option,
  }) {
    _searchFilter = filter;
    _sortType = option ?? _sortType;

    final matches = _model.profiles
        .where(
          (profile) =>
              profile.name.toLowerCase().contains(filter.toLowerCase()),
        )
        .toList();
    return _sortType == SortTypes.alphaDesc
        ? matches.reversed.toList()
        : matches;
  }

  Widget _buildSearchBar() => Padding(
    padding: const EdgeInsets.fromLTRB(10, 5, 10, 10),
    child: SortableSearchBar(
      hintText: LocaleKeys.findEventMonitoringProfile.tr(),
      // Always pass the current store projection, including while search
      // is active. This prevents a stale search source after a server sync.
      items: _model.profiles,
      onSearch: _onSearch,
      filterFunc: _filterFunc,
      filterSetter: (_) => setState(() {}),
    ),
  );

  Widget _buildTabSwitcher() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TabBar(
            isScrollable: true,
            controller: _tabController,
            tabs: EventMonitorTab.values
                .where((tab) => !tab.isSearchResults)
                .map((tab) => Tab(text: tab.title))
                .toList(),
          ),
          const Divider(),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildTabs() {
    return Expanded(
      child: TabBarView(
        controller: _tabController,
        children: [
          EventMonitoringProfilesListPage(
            tab: EventMonitorTab.active,
            searchFilter: _searchFilter,
            sortType: _sortType,
          ),
          EventMonitoringProfilesListPage(
            tab: EventMonitorTab.inactive,
            searchFilter: _searchFilter,
            sortType: _sortType,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StoreConnector<AppState, EventMonitorListModel>(
      converter: EventMonitorListModel.new,
      builder: (context, model) {
        _model = model;

        return Scaffold(
          resizeToAvoidBottomInset: false,
          appBar: EvAppBar(
            showLeading: context.showSmallRes,
            isLarge: !context.showSmallRes,
            title: LocaleKeys.eventMonitoringProfiles.tr(),
          ),
          body: GestureDetector(
            onTap: () {
              final currentFocus = FocusScope.of(context);
              if (!currentFocus.hasPrimaryFocus) {
                currentFocus.unfocus();
              }
            },
            child: Column(
              children: [
                _buildSearchBar(),
                if (_searchFilter.isEmpty) ...[
                  _buildTabSwitcher(),
                  _buildTabs(),
                ],
                if (_searchFilter.isNotEmpty)
                  Expanded(
                    child: EventMonitoringProfilesListPage(
                      key: const PageStorageKey('search_results_list'),
                      tab: EventMonitorTab.search,
                      searchFilter: _searchFilter,
                      sortType: _sortType,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
      onInit: _storeInit,
      onWillChange: _modelUpdater,
      distinct: true,
    );
  }
}
