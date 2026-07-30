import 'package:flutter/material.dart';

import '../../../theme/style_sheet.dart';
import '../../../theme/theme_manager.dart';

class EvMenuItem extends StatelessWidget {
  static const double compactHeight = 45;

  final IconData? iconData;
  final String actionText;
  final bool destructive;
  final Color? iconColor;

  /// Compact mode uses:
  /// - 45px total height
  /// - 8px horizontal padding
  ///
  /// Normal mode retains the original 16px padding.
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
    return SizedBox(
      height: compact ? compactHeight : null,
      child: Padding(
        padding: compact
            ? const EdgeInsets.symmetric(horizontal: 8)
            : const EdgeInsets.all(16),
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
                maxLines: compact ? 1 : null,
                overflow: compact ? TextOverflow.ellipsis : null,
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
      ),
    );
  }
}
