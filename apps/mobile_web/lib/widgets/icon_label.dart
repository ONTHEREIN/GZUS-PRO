import 'package:flutter/material.dart';

class IconLabel extends StatelessWidget {
  const IconLabel({
    super.key,
    required this.icon,
    required this.label,
    this.centered = false,
  });

  final IconData icon;
  final String label;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: centered ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment:
          centered ? MainAxisAlignment.center : MainAxisAlignment.start,
      children: [
        Icon(icon, size: 15),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
