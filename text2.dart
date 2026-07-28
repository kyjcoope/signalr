import 'package:flutter/material.dart';

import '../../../theme/style_sheet.dart';
import '../../../theme/theme_manager.dart';

class EvMenuItem extends StatelessWidget {
  final IconData? iconData;
  final String actionText;
  final bool destructive;
  final Color? iconColor;

  const EvMenuItem({
    super.key,
    this.iconData,
    required this.actionText,
    this.destructive = false,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
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
