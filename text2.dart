import 'package:flutter/material.dart';

import '../../../theme/style_sheet.dart';
import '../../../theme/theme_manager.dart';

class EvMenuItem extends StatelessWidget {
  final IconData? iconData;
  final String actionText;
  final bool destructive;
  final Color? iconColor;

  /*
   * Compact items use 8 px content padding.
   * Regular items use the original 16 px content padding.
   */
  final bool compact;

  const EvMenuItem({
    super.key,
    this.iconData,
    required this.actionText,
    this.destructive = false,
    this.iconColor,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final itemPadding = compact ? 8.0 : 16.0;

    return Padding(
      padding: EdgeInsets.all(itemPadding),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            iconData,
            color: destructive ? EvTheme.get.theme.sIconCritical : iconColor,
          ),
          if (iconData != null) const SizedBox(width: 8),
          Flexible(
            child: Text(
              actionText,
              style: destructive
                  ? evStyle(
                      context,
                      CraftStyle.fourteenFive,
                      color: EvTheme.get.theme.sTextCritical,
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}
