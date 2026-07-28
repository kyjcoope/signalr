class SimplePopupMenu<T> extends StatefulWidget {
  final Iterable<(T, bool)> menuItems;
  final ValueSetter<T> menuSelected;
  final IconData? buttonIcon;
  final Widget? buttonWidget;
  final Widget Function(T item) builder;
  final String? tooltip;
  final bool enableMenuButton;
  final double? maxWidth;
  final ButtonStyle? style;

  const SimplePopupMenu({
    super.key,
    required this.menuItems,
    required this.menuSelected,
    required this.builder,
    this.buttonIcon,
    this.buttonWidget,
    this.tooltip,
    this.enableMenuButton = true,
    this.maxWidth,
    this.style,
  });

  @override
  State<SimplePopupMenu<T>> createState() => _SimplePopupMenuState<T>();
}

class _SimplePopupMenuState<T> extends State<SimplePopupMenu<T>> {
  static const double _menuGap = 8;
  static const double _screenMargin = 8;

  final LayerLink _layerLink = LayerLink();

  bool _menuOpen = false;

  List<PopupMenuEntry<T>> _getMenuItems() {
    final items = widget.menuItems.toList();

    return [
      for (var index = 0; index < items.length; index++) ...[
        PopupMenuItem<T>(
          padding: EdgeInsets.zero,
          value: items[index].$1,
          enabled: items[index].$2,
          child: widget.builder(items[index].$1),
        ),
        if (index != items.length - 1) const PopupMenuDivider(height: 1),
      ],
    ];
  }

  Future<void> _showMenu(BuildContext anchorContext) async {
    if (_menuOpen || !widget.enableMenuButton) {
      return;
    }

    final items = _getMenuItems();

    if (items.isEmpty) {
      return;
    }

    setState(() {
      _menuOpen = true;
    });

    final navigator = Navigator.of(anchorContext);

    final selectedValue = await navigator.push<T>(
      _AnchoredPopupMenuRoute<T>(
        layerLink: _layerLink,
        anchorContext: anchorContext,
        items: items,
        maxWidth: widget.maxWidth ?? 224,
        gap: _menuGap,
        screenMargin: _screenMargin,
        theme: Theme.of(anchorContext),
        popupMenuTheme: PopupMenuTheme.of(anchorContext),
        barrierLabel: MaterialLocalizations.of(
          anchorContext,
        ).modalBarrierDismissLabel,
      ),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _menuOpen = false;
    });

    if (selectedValue != null) {
      widget.menuSelected(selectedValue);
    }
  }

  Widget _buildButton(BuildContext buttonContext) {
    final onPressed = widget.enableMenuButton
        ? () => _showMenu(buttonContext)
        : null;

    if (widget.buttonWidget != null) {
      return Tooltip(
        message:
            widget.tooltip ?? MaterialLocalizations.of(context).showMenuTooltip,
        child: InkWell(onTap: onPressed, child: widget.buttonWidget),
      );
    }

    return IconButton(
      tooltip: widget.tooltip,
      style: widget.style ?? EvTheme.get.iconSecondary,
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      icon: Icon(widget.buttonIcon ?? Icons.more_vert),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: Builder(
        builder: (buttonContext) {
          return Semantics(
            expanded: _menuOpen,
            child: _buildButton(buttonContext),
          );
        },
      ),
    );
  }
}

class _AnchoredPopupMenuRoute<T> extends PopupRoute<T> {
  _AnchoredPopupMenuRoute({
    required this.layerLink,
    required this.anchorContext,
    required this.items,
    required this.maxWidth,
    required this.gap,
    required this.screenMargin,
    required this.theme,
    required this.popupMenuTheme,
    required String barrierLabel,
  }) : _barrierLabel = barrierLabel;

  final LayerLink layerLink;
  final BuildContext anchorContext;
  final List<PopupMenuEntry<T>> items;

  final double maxWidth;
  final double gap;
  final double screenMargin;

  final ThemeData theme;
  final PopupMenuThemeData popupMenuTheme;

  final String _barrierLabel;

  @override
  bool get barrierDismissible => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => _barrierLabel;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 200);

  Rect? _getAnchorRect() {
    final anchorRenderObject = anchorContext.findRenderObject();

    final navigator = Navigator.of(anchorContext);
    final overlayRenderObject = navigator.overlay?.context.findRenderObject();

    if (anchorRenderObject is! RenderBox ||
        overlayRenderObject is! RenderBox ||
        !anchorRenderObject.attached ||
        !overlayRenderObject.attached) {
      return null;
    }

    final topLeft = anchorRenderObject.localToGlobal(
      Offset.zero,
      ancestor: overlayRenderObject,
    );

    return topLeft & anchorRenderObject.size;
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final mediaQuery = MediaQuery.of(context);
    final anchorRect = _getAnchorRect();

    if (anchorRect == null) {
      return const SizedBox.shrink();
    }

    /*
     * The menu always opens above the button.
     *
     * Its bottom-right corner is attached to the button's top-right corner.
     * The height is constrained only when the viewport is too short.
     */
    final availableHeight = math.max(
      0.0,
      anchorRect.top - gap - mediaQuery.padding.top - screenMargin,
    );

    final availableWidth = math.max(
      0.0,
      anchorRect.right - mediaQuery.padding.left - screenMargin,
    );

    final effectiveMaxWidth = math.min(maxWidth, availableWidth);

    final menuAnimation = animation.drive(
      CurveTween(curve: Curves.easeOutCubic),
    );

    final scaleAnimation = Tween<double>(
      begin: 0.96,
      end: 1,
    ).animate(menuAnimation);

    final menu = Theme(
      data: theme,
      child: PopupMenuTheme(
        data: popupMenuTheme,
        child: Material(
          type: MaterialType.card,
          elevation: 8,
          shadowColor: Colors.black,
          surfaceTintColor: Colors.transparent,
          color:
              popupMenuTheme.color ??
              (theme.useMaterial3
                  ? theme.colorScheme.surfaceContainer
                  : theme.cardColor),
          shape:
              popupMenuTheme.shape ??
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(theme.useMaterial3 ? 4 : 2),
              ),
          clipBehavior: Clip.none,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: effectiveMaxWidth,
              maxHeight: availableHeight,
            ),
            child: IntrinsicWidth(
              stepWidth: 56,
              child: Semantics(
                role: SemanticsRole.menu,
                scopesRoute: true,
                namesRoute: true,
                explicitChildNodes: true,
                child: SingleChildScrollView(
                  padding:
                      popupMenuTheme.menuPadding ??
                      const EdgeInsets.symmetric(vertical: 8),
                  child: ListBody(children: items),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return Stack(
      clipBehavior: Clip.none,
      children: [
        CompositedTransformFollower(
          link: layerLink,
          showWhenUnlinked: false,

          // Exact UI/UX placement:
          targetAnchor: Alignment.topRight,
          followerAnchor: Alignment.bottomRight,

          // Only the intended visual gap is fixed.
          offset: Offset(0, -gap),

          child: FadeTransition(
            opacity: menuAnimation,
            child: ScaleTransition(
              scale: scaleAnimation,
              alignment: Alignment.bottomRight,
              child: menu,
            ),
          ),
        ),
      ],
    );
  }
}
