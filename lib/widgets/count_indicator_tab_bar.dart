import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// 리스트 개수를 인디케이터로 표시하는 탭바 위젯
/// 스토리 툴바와 동일한 UI이지만, 점 부분이 리스트 개수를 나타냅니다.
class CountIndicatorTabBar extends StatelessWidget {
  final List<String> labels;
  final List<int> counts; // 각 탭의 리스트 개수
  final int selectedIndex;
  final Function(int) onTabChanged;
  final Widget? trailing;
  final double tabSpacing;

  const CountIndicatorTabBar({
    super.key,
    required this.labels,
    required this.counts,
    required this.selectedIndex,
    required this.onTabChanged,
    this.trailing,
    this.tabSpacing = 24,
  }) : assert(labels.length == counts.length, 'labels와 counts의 길이가 같아야 합니다.');

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
            final count = counts[index];

            return Row(
              children: [
                _buildTab(label, index, isSelected, count),
                if (index < labels.length - 1) SizedBox(width: tabSpacing),
              ],
            );
          }).toList(),
          if (trailing != null) ...[const Spacer(), trailing!],
        ],
      ),
    );
  }

  Widget _buildTab(String label, int index, bool isSelected, int count) {
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
          const SizedBox(height: 4),
          // 고정 높이로 UI 흔들림 방지
          SizedBox(
            height: 10,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: AppColors.primaryGreen,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
