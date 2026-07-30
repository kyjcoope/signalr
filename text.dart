import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme/theme_manager.dart';

enum SimplePopupMenuPlacement { topLeft, topRight, bottomLeft, bottomRight }

const double _defaultMenuMaxWidth = 224;
const double _compactMenuWidth = 176;
const double _compactItemHeight = 45;
const double _menuMinWidth = 112;
const double _menuWidthStep = 56;

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

  /// When enabled:
  /// - menu width defaults to 176
  /// - every item is exactly 45px tall
  ///
  /// When disabled, the original menu sizing is preserved.
  final bool compact;

  /// The preferred placement. If [autoFlip] is enabled, the menu can move
  /// vertically when there is not enough space.
  final SimplePopupMenuPlacement placement;

  /// Automatically switches between top and bottom while preserving the
  /// preferred horizontal alignment.
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
    this.compact = false,
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
    final entries = <PopupMenuEntry<T>>[];

    for (final item in widget.menuItems) {
      if (entries.isNotEmpty) {
        entries.add(const PopupMenuDivider(height: 1));
      }

      final itemChild = widget.builder(item.$1);

      entries.add(
        PopupMenuItem<T>(
          value: item.$1,
          enabled: item.$2,
          padding: EdgeInsets.zero,
          height: widget.compact
              ? _compactItemHeight
              : kMinInteractiveDimension,
          child: widget.compact
              ? SizedBox(height: _compactItemHeight, child: itemChild)
              : itemChild,
        ),
      );
    }

    return entries;
  }

  Future<void> _showMenu(BuildContext buttonContext) async {
    if (!widget.enableMenuButton || _menuOpen) {
      return;
    }

    final items = _getMenuItems();

    if (items.isEmpty) {
      return;
    }

    setState(() {
      _menuOpen = true;
    });

    final requestedMaxWidth =
        widget.maxWidth ??
        (widget.compact ? _compactMenuWidth : _defaultMenuMaxWidth);

    final selectedValue = await Navigator.of(buttonContext).push<T>(
      _AnchoredPopupMenuRoute<T>(
        anchorContext: buttonContext,
        items: items,
        maxWidth: requestedMaxWidth,
        compact: widget.compact,
        gap: _menuGap,
        screenMargin: _screenMargin,
        preferredPlacement: widget.placement,
        autoFlip: widget.autoFlip,
        theme: Theme.of(buttonContext),
        popupMenuTheme: PopupMenuTheme.of(buttonContext),
        barrierLabel: MaterialLocalizations.of(buttonContext).menuDismissLabel,
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
    if (widget.buttonWidget != null) {
      Widget button = InkWell(
        onTap: widget.enableMenuButton ? () => _showMenu(buttonContext) : null,
        child: widget.buttonWidget,
      );

      if (widget.tooltip?.isNotEmpty ?? false) {
        button = Tooltip(message: widget.tooltip!, child: button);
      }

      return button;
    }

    return IconButton(
      onPressed: widget.enableMenuButton
          ? () => _showMenu(buttonContext)
          : null,
      tooltip: widget.tooltip,
      style: widget.style ?? EvTheme.get.iconSecondary,
      padding: EdgeInsets.zero,
      icon: Icon(widget.buttonIcon ?? Icons.more_vert),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (buttonContext) {
        return Semantics(
          button: true,
          enabled: widget.enableMenuButton,
          child: _buildButton(buttonContext),
        );
      },
    );
  }
}

class _AnchoredPopupMenuRoute<T> extends PopupRoute<T> {
  final BuildContext anchorContext;
  final List<PopupMenuEntry<T>> items;
  final double maxWidth;
  final bool compact;
  final double gap;
  final double screenMargin;
  final SimplePopupMenuPlacement preferredPlacement;
  final bool autoFlip;
  final ThemeData theme;
  final PopupMenuThemeData popupMenuTheme;

  @override
  final String barrierLabel;

  _AnchoredPopupMenuRoute({
    required this.anchorContext,
    required this.items,
    required this.maxWidth,
    required this.compact,
    required this.gap,
    required this.screenMargin,
    required this.preferredPlacement,
    required this.autoFlip,
    required this.theme,
    required this.popupMenuTheme,
    required this.barrierLabel,
  });

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 160);

  Rect? _getAnchorRect() {
    final anchorRenderObject = anchorContext.findRenderObject();
    final overlayRenderObject = navigator?.overlay?.context.findRenderObject();

    if (anchorRenderObject is! RenderBox ||
        overlayRenderObject is! RenderBox ||
        !anchorRenderObject.attached) {
      return null;
    }

    final topLeft = anchorRenderObject.localToGlobal(
      Offset.zero,
      ancestor: overlayRenderObject,
    );

    return topLeft & anchorRenderObject.size;
  }

  ShapeBorder _getMenuShape() {
    final borderSide = BorderSide(color: theme.dividerColor, width: 1);

    final configuredShape = popupMenuTheme.shape;

    if (configuredShape is OutlinedBorder) {
      return configuredShape.copyWith(side: borderSide);
    }

    return RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: borderSide,
    );
  }

  Widget _buildMenuContents(double effectiveMaxWidth) {
    final contents = SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: ListBody(children: items),
    );

    // Compact mode has an exact width of 176px, unless the available
    // screen width is smaller.
    if (compact) {
      return SizedBox(width: effectiveMaxWidth, child: contents);
    }

    // Normal mode preserves PopupMenuButton's original intrinsic-width
    // behavior, including its 56px width steps.
    return IntrinsicWidth(
      stepWidth: _menuWidthStep,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: math.min(_menuMinWidth, effectiveMaxWidth),
          maxWidth: effectiveMaxWidth,
        ),
        child: contents,
      ),
    );
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final anchorRect = _getAnchorRect();

    if (anchorRect == null) {
      return const SizedBox.shrink();
    }

    final mediaQuery = MediaQuery.of(context);
    final padding = mediaQuery.padding;
    final viewInsets = mediaQuery.viewInsets;

    final safeLeft = math.max(padding.left, viewInsets.left) + screenMargin;
    final safeTop = math.max(padding.top, viewInsets.top) + screenMargin;

    final unsafeRight =
        mediaQuery.size.width -
        math.max(padding.right, viewInsets.right) -
        screenMargin;

    final unsafeBottom =
        mediaQuery.size.height -
        math.max(padding.bottom, viewInsets.bottom) -
        screenMargin;

    final safeRight = math.max(safeLeft, unsafeRight);
    final safeBottom = math.max(safeTop, unsafeBottom);

    final safeBounds = Rect.fromLTRB(safeLeft, safeTop, safeRight, safeBottom);

    final availableAbove = math.max(0.0, anchorRect.top - safeBounds.top - gap);

    final availableBelow = math.max(
      0.0,
      safeBounds.bottom - anchorRect.bottom - gap,
    );

    final prefersAbove = _isAbove(preferredPlacement);

    final availableHeight = autoFlip
        ? math.max(availableAbove, availableBelow)
        : prefersAbove
        ? availableAbove
        : availableBelow;

    final effectiveMaxWidth = math.min(maxWidth, safeBounds.width);

    final menu = Material(
      type: MaterialType.card,
      color: popupMenuTheme.color,
      elevation: popupMenuTheme.elevation ?? 8,
      shadowColor: Colors.black,
      surfaceTintColor: Colors.transparent,
      shape: _getMenuShape(),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: effectiveMaxWidth,
          maxHeight: availableHeight,
        ),
        child: _buildMenuContents(effectiveMaxWidth),
      ),
    );

    return Theme(
      data: theme,
      child: CustomSingleChildLayout(
        delegate: _AdaptivePopupMenuLayoutDelegate(
          anchorRect: anchorRect,
          safeBounds: safeBounds,
          preferredPlacement: preferredPlacement,
          autoFlip: autoFlip,
          gap: gap,
        ),
        child: menu,
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        curve: Curves.easeOut,
        reverseCurve: Curves.easeIn,
      ),
      child: child,
    );
  }
}

class _AdaptivePopupMenuLayoutDelegate extends SingleChildLayoutDelegate {
  final Rect anchorRect;
  final Rect safeBounds;
  final SimplePopupMenuPlacement preferredPlacement;
  final bool autoFlip;
  final double gap;

  const _AdaptivePopupMenuLayoutDelegate({
    required this.anchorRect,
    required this.safeBounds,
    required this.preferredPlacement,
    required this.autoFlip,
    required this.gap,
  });

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.loose(constraints.biggest);
  }

  bool _shouldOpenAbove(Size childSize) {
    final prefersAbove = _isAbove(preferredPlacement);

    if (!autoFlip) {
      return prefersAbove;
    }

    final availableAbove = math.max(0.0, anchorRect.top - safeBounds.top - gap);

    final availableBelow = math.max(
      0.0,
      safeBounds.bottom - anchorRect.bottom - gap,
    );

    final preferredSpace = prefersAbove ? availableAbove : availableBelow;

    final fallbackSpace = prefersAbove ? availableBelow : availableAbove;

    if (childSize.height <= preferredSpace) {
      return prefersAbove;
    }

    if (childSize.height <= fallbackSpace) {
      return !prefersAbove;
    }

    return availableAbove >= availableBelow;
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final opensAbove = _shouldOpenAbove(childSize);
    final extendsLeft = _isLeft(preferredPlacement);

    final desiredX = extendsLeft
        ? anchorRect.right - childSize.width
        : anchorRect.left;

    final desiredY = opensAbove
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

    final x = desiredX.clamp(safeBounds.left, maximumX).toDouble();

    final y = desiredY.clamp(safeBounds.top, maximumY).toDouble();

    return Offset(x, y);
  }

  @override
  bool shouldRelayout(covariant _AdaptivePopupMenuLayoutDelegate oldDelegate) {
    return anchorRect != oldDelegate.anchorRect ||
        safeBounds != oldDelegate.safeBounds ||
        preferredPlacement != oldDelegate.preferredPlacement ||
        autoFlip != oldDelegate.autoFlip ||
        gap != oldDelegate.gap;
  }
}

bool _isAbove(SimplePopupMenuPlacement placement) {
  return placement == SimplePopupMenuPlacement.topLeft ||
      placement == SimplePopupMenuPlacement.topRight;
}

bool _isLeft(SimplePopupMenuPlacement placement) {
  return placement == SimplePopupMenuPlacement.topLeft ||
      placement == SimplePopupMenuPlacement.bottomLeft;
}
