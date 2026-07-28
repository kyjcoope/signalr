import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme/theme_manager.dart';

enum SimplePopupMenuPlacement {
  /// Above the button, extending toward the left.
  topLeft,

  /// Above the button, extending toward the right.
  topRight,

  /// Below the button, extending toward the left.
  bottomLeft,

  /// Below the button, extending toward the right.
  bottomRight,
}

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

  /// The preferred menu placement.
  final SimplePopupMenuPlacement placement;

  /// When true, the menu can flip vertically if the preferred placement
  /// does not have enough room.
  ///
  /// For example, bottomLeft falls back to topLeft.
  final bool autoFlip;

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
    this.placement = SimplePopupMenuPlacement.topLeft,
    this.autoFlip = true,
  });

  @override
  State<SimplePopupMenu<T>> createState() => _SimplePopupMenuState<T>();
}

class _SimplePopupMenuState<T> extends State<SimplePopupMenu<T>> {
  static const double _menuGap = 8;
  static const double _screenMargin = 8;

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
        anchorContext: anchorContext,
        items: items,
        maxWidth: widget.maxWidth ?? 224,
        gap: _menuGap,
        screenMargin: _screenMargin,
        preferredPlacement: widget.placement,
        autoFlip: widget.autoFlip,
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
    return Builder(
      builder: (buttonContext) {
        return Semantics(
          expanded: _menuOpen,
          child: _buildButton(buttonContext),
        );
      },
    );
  }
}

class _AnchoredPopupMenuRoute<T> extends PopupRoute<T> {
  _AnchoredPopupMenuRoute({
    required this.anchorContext,
    required this.items,
    required this.maxWidth,
    required this.gap,
    required this.screenMargin,
    required this.preferredPlacement,
    required this.autoFlip,
    required this.theme,
    required this.popupMenuTheme,
    required String barrierLabel,
  }) : _barrierLabel = barrierLabel;

  final BuildContext anchorContext;
  final List<PopupMenuEntry<T>> items;

  final double maxWidth;
  final double gap;
  final double screenMargin;

  final SimplePopupMenuPlacement preferredPlacement;
  final bool autoFlip;

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

  bool get _prefersAbove =>
      preferredPlacement == SimplePopupMenuPlacement.topLeft ||
      preferredPlacement == SimplePopupMenuPlacement.topRight;

  bool get _extendsLeft =>
      preferredPlacement == SimplePopupMenuPlacement.topLeft ||
      preferredPlacement == SimplePopupMenuPlacement.bottomLeft;

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

    final topInset = math.max(
      mediaQuery.padding.top,
      mediaQuery.viewInsets.top,
    );

    final bottomInset = math.max(
      mediaQuery.padding.bottom,
      mediaQuery.viewInsets.bottom,
    );

    final safeBounds = Rect.fromLTRB(
      mediaQuery.padding.left + screenMargin,
      topInset + screenMargin,
      mediaQuery.size.width - mediaQuery.padding.right - screenMargin,
      mediaQuery.size.height - bottomInset - screenMargin,
    );

    final availableAbove = math.max(0.0, anchorRect.top - gap - safeBounds.top);

    final availableBelow = math.max(
      0.0,
      safeBounds.bottom - anchorRect.bottom - gap,
    );

    /*
     * If automatic flipping is enabled, initially allow the menu to
     * use the larger side. The layout delegate uses the menu's actual
     * rendered height to choose the final side.
     */
    final availableHeight = autoFlip
        ? math.max(availableAbove, availableBelow)
        : (_prefersAbove ? availableAbove : availableBelow);

    final availableLeft = math.max(0.0, anchorRect.right - safeBounds.left);

    final availableRight = math.max(0.0, safeBounds.right - anchorRect.left);

    final availableWidth = _extendsLeft ? availableLeft : availableRight;

    final effectiveMaxWidth = math.min(maxWidth, availableWidth);

    final configuredShape =
        popupMenuTheme.shape ??
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(theme.useMaterial3 ? 4 : 2),
        );

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
                  padding: EdgeInsets.zero,
                  child: ListBody(children: items),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return CustomSingleChildLayout(
      delegate: _AdaptivePopupMenuLayoutDelegate(
        anchorRect: anchorRect,
        safeBounds: safeBounds,
        preferredPlacement: preferredPlacement,
        autoFlip: autoFlip,
        gap: gap,
      ),
      child: FadeTransition(opacity: menuAnimation, child: menu),
    );
  }
}

class _AdaptivePopupMenuLayoutDelegate extends SingleChildLayoutDelegate {
  const _AdaptivePopupMenuLayoutDelegate({
    required this.anchorRect,
    required this.safeBounds,
    required this.preferredPlacement,
    required this.autoFlip,
    required this.gap,
  });

  final Rect anchorRect;
  final Rect safeBounds;
  final SimplePopupMenuPlacement preferredPlacement;
  final bool autoFlip;
  final double gap;

  bool get _prefersAbove =>
      preferredPlacement == SimplePopupMenuPlacement.topLeft ||
      preferredPlacement == SimplePopupMenuPlacement.topRight;

  bool get _extendsLeft =>
      preferredPlacement == SimplePopupMenuPlacement.topLeft ||
      preferredPlacement == SimplePopupMenuPlacement.bottomLeft;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    /*
     * Allow the menu to use its natural size. The menu's own
     * ConstrainedBox controls its maximum width and height.
     */
    return BoxConstraints.loose(constraints.biggest);
  }

  bool _shouldOpenAbove(Size childSize) {
    if (!autoFlip) {
      return _prefersAbove;
    }

    final availableAbove = math.max(0.0, anchorRect.top - gap - safeBounds.top);

    final availableBelow = math.max(
      0.0,
      safeBounds.bottom - anchorRect.bottom - gap,
    );

    final preferredSpace = _prefersAbove ? availableAbove : availableBelow;

    final fallbackSpace = _prefersAbove ? availableBelow : availableAbove;

    /*
     * Try the preferred side first using the menu's actual
     * rendered height.
     */
    if (childSize.height <= preferredSpace) {
      return _prefersAbove;
    }

    /*
     * Flip vertically when the menu does not fit on the preferred
     * side but does fit on the opposite side.
     */
    if (childSize.height <= fallbackSpace) {
      return !_prefersAbove;
    }

    /*
     * If neither side can display the menu at its natural height,
     * choose the side with more room. The menu becomes scrollable
     * because its height was constrained to the larger space.
     */
    return availableAbove >= availableBelow;
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final opensAbove = _shouldOpenAbove(childSize);

    double x = _extendsLeft
        ? anchorRect.right - childSize.width
        : anchorRect.left;

    double y = opensAbove
        ? anchorRect.top - gap - childSize.height
        : anchorRect.bottom + gap;

    final maximumX = math.max(
      safeBounds.left,
      safeBounds.right - childSize.width,
    );

    final maximumY = math.max(
      safeBounds.top,
      safeBounds.bottom - childSize.height,
    );

    x = x.clamp(safeBounds.left, maximumX).toDouble();

    y = y.clamp(safeBounds.top, maximumY).toDouble();

    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_AdaptivePopupMenuLayoutDelegate oldDelegate) {
    return anchorRect != oldDelegate.anchorRect ||
        safeBounds != oldDelegate.safeBounds ||
        preferredPlacement != oldDelegate.preferredPlacement ||
        autoFlip != oldDelegate.autoFlip ||
        gap != oldDelegate.gap;
  }
}
