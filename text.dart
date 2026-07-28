import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme/theme_manager.dart';

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
          /*
           * All items use identical padding so the first and last
           * entries remain the same height as the middle entries.
           *
           * The menu itself has no outer padding, allowing the first
           * and last hover highlights to reach the menu border.
           */
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
    final VoidCallback? onPressed = widget.enableMenuButton
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

    final availableHeight = math.max(
      0.0,
      anchorRect.top - gap - mediaQuery.padding.top - screenMargin,
    );

    final availableWidth = math.max(
      0.0,
      anchorRect.right - mediaQuery.padding.left - screenMargin,
    );

    final effectiveMaxWidth = math.min(maxWidth, availableWidth);

    final configuredShape =
        popupMenuTheme.shape ??
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(theme.useMaterial3 ? 4 : 2),
        );

    /*
     * Use the same border color and thickness as Divider widgets.
     */
    final borderSide = BorderSide(
      color: theme.dividerTheme.color ?? theme.dividerColor,
      width: theme.dividerTheme.thickness ?? 1,
    );

    final ShapeBorder borderedShape = configuredShape is OutlinedBorder
        ? configuredShape.copyWith(side: borderSide)
        : RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(theme.useMaterial3 ? 4 : 2),
            side: borderSide,
          );

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
          shape: borderedShape,

          /*
           * Clips the hover highlight to the rounded menu border.
           */
          clipBehavior: Clip.antiAlias,

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
                  /*
                   * No outer padding means the first and last hover
                   * highlights reach the top and bottom menu borders.
                   */
                  padding: EdgeInsets.zero,
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

          // Attach menu bottom-right to button top-right.
          targetAnchor: Alignment.topRight,
          followerAnchor: Alignment.bottomRight,

          // Constant gap from the UI/UX design.
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
