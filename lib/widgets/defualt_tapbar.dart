import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class DefaultTapbar extends StatelessWidget {
  final List<String> labels;
  final int selectedIndex;
  final Function(int) onTabChanged;
  final Widget? trailing;
  final double tabSpacing;
  /// true면 선택 탭 아래에 점 표시, false면 닷 없음(텍스트만)
  final bool showIndicator;

  const DefaultTapbar({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onTabChanged,
    this.trailing,
    this.tabSpacing = 24,
    this.showIndicator = true,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          ...labels.asMap().entries.map((entry) {
            final index = entry.key;
            final label = entry.value;
            final isSelected = selectedIndex == index;

            return Row(
              children: [
                _buildTab(label, index, isSelected),
                if (index < labels.length - 1) SizedBox(width: tabSpacing),
              ],
            );
          }).toList(),
          if (trailing != null) ...[const Spacer(), trailing!],
        ],
      ),
    );
  }

  Widget _buildTab(String label, int index, bool isSelected) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onTabChanged(index),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 200),
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: isSelected
                  ? AppColors.textPrimary
                  : AppColors.textSecondary.withOpacity(0.7),
            ),
            child: Text(label),
          ),
          if (showIndicator) ...[
            const SizedBox(height: 4),
            SizedBox(
              height: 10,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: isSelected
                    ? Container(
                        key: const ValueKey('dot'),
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: AppColors.primaryGreen,
                          shape: BoxShape.circle,
                        ),
                      )
                    : const SizedBox(
                        key: ValueKey('empty'),
                        width: 10,
                        height: 10,
                      ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
