import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../theme/style_sheet.dart';
import '../../../theme/theme_manager.dart';

class EvMenuItem extends StatelessWidget {
  static const double compactHeight = 45;
  static const double compactIconSize = 16;

  final IconData? iconData;
  final String actionText;
  final bool destructive;
  final Color? iconColor;
  final bool compact;

  const EvMenuItem({
    super.key,
    this.iconData,
    required this.actionText,
    this.destructive = false,
    this.iconColor,
    this.compact = kIsWeb,
  });

  @override
  Widget build(BuildContext context) {
    final textStyle = compact
        ? evStyle(
            context,
            CraftStyle.twelveSix,
            color: destructive ? EvTheme.get.theme.sTextCritical : null,
          )
        : destructive
        ? evStyle(
            context,
            CraftStyle.fourteenFive,
            color: EvTheme.get.theme.sTextCritical,
          )
        : null;

    final text = Text(
      actionText,
      maxLines: compact ? 1 : null,
      overflow: compact ? TextOverflow.ellipsis : null,
      style: textStyle,
    );

    return SizedBox(
      height: compact ? compactHeight : null,
      child: Padding(
        padding: compact
            ? const EdgeInsets.symmetric(horizontal: 8)
            : const EdgeInsets.all(16),
        child: Row(
          mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (iconData != null)
              Icon(
                iconData,
                size: compact ? compactIconSize : null,
                color: destructive
                    ? EvTheme.get.theme.sIconCritical
                    : iconColor,
              ),
            if (iconData != null) const SizedBox(width: 8),
            if (compact) Expanded(child: text) else Flexible(child: text),
          ],
        ),
      ),
    );
  }
}
