import 'package:flutter/material.dart';
import '../../../theme/app_colors.dart';

/// 라벨 + 텍스트필드
class FormTextField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final int maxLines;
  final TextInputType? keyboardType;

  const FormTextField({
    super.key,
    required this.label,
    required this.controller,
    this.maxLines = 1,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }
}

/// 아이콘 선택 드롭다운
class IconPicker extends StatelessWidget {
  final IconData value;
  final ValueChanged<IconData> onChanged;

  const IconPicker({super.key, required this.value, required this.onChanged});

  static const List<IconData> _icons = [
    Icons.notifications,
    Icons.info,
    Icons.celebration,
    Icons.campaign,
    Icons.warning_amber,
  ];

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<IconData>(
      value: value,
      decoration: const InputDecoration(
        labelText: '아이콘',
        border: OutlineInputBorder(),
      ),
      items: _icons
          .map(
            (i) => DropdownMenuItem(
              value: i,
              child: Row(
                children: [
                  Icon(i, size: 18),
                  const SizedBox(width: 8),
                  Text(i.toString().split('.').last),
                ],
              ),
            ),
          )
          .toList(),
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}

/// Color? 선택 픽커
class ColorPicker extends StatelessWidget {
  final String label;
  final Color? value;
  final List<Color?> colors;
  final ValueChanged<Color?> onChanged;

  const ColorPicker({
    super.key,
    required this.label,
    required this.value,
    required this.colors,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in colors)
              GestureDetector(
                onTap: () => onChanged(c),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: c ?? Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: value == c
                          ? AppColors.primaryGreen
                          : AppColors.borderLight,
                      width: value == c ? 2 : 1,
                    ),
                  ),
                  child: c == null
                      ? Icon(Icons.block, color: AppColors.textSecondary)
                      : null,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// int 색상값 선택 픽커
class IntColorPicker extends StatelessWidget {
  final String label;
  final int value;
  final List<int> colors;
  final ValueChanged<int> onChanged;

  const IntColorPicker({
    super.key,
    required this.label,
    required this.value,
    required this.colors,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in colors)
              GestureDetector(
                onTap: () => onChanged(c),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Color(c),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: value == c
                          ? AppColors.primaryGreen
                          : AppColors.borderLight,
                      width: value == c ? 2 : 1,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
