import 'package:flutter/material.dart';

class SeedColorPicker extends StatelessWidget {
  const SeedColorPicker({
    super.key,
    required this.selectedColor,
    required this.onColorSelected,
  });

  final Color selectedColor;
  final ValueChanged<Color> onColorSelected;

  static const _presets = <Color>[
    Color(0xFF2563EB), // 蓝色
    Color(0xFF059669), // 绿色
    Color(0xFF7C3AED), // 紫色
    Color(0xFFEA580C), // 橙色
    Color(0xFFDC2626), // 红色
    Color(0xFF0891B2), // 青色
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 16,
      runSpacing: 12,
      alignment: WrapAlignment.center,
      children: _presets.map((color) {
        final isSelected = color.toARGB32() == selectedColor.toARGB32();
        return GestureDetector(
          onTap: () => onColorSelected(color),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: isSelected
                  ? Border.all(
                      color: color,
                      width: 3,
                      strokeAlign: BorderSide.strokeAlignOutside,
                    )
                  : null,
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.4),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: isSelected
                ? const Icon(Icons.check, color: Colors.white, size: 20)
                : null,
          ),
        );
      }).toList(),
    );
  }
}
