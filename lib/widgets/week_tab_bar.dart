import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../utils/week_range_calculator.dart';

/// 정책 기반 동적 주간 탭바 위젯
class WeekTabBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onTabChanged;
  final Widget? trailing; // 끝에 표시할 위젯
  final List<int> availableWeekOffsets; // 정책에서 계산된 주차 범위
  final bool showDot; // 닷 표시 여부

  const WeekTabBar({
    super.key,
    required this.selectedIndex,
    required this.onTabChanged,
    required this.availableWeekOffsets,
    this.trailing,
    this.showDot = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // 주차 탭들을 Expanded로 감싸서 남은 공간 차지
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                // 동적으로 생성된 주차 탭들
                ...availableWeekOffsets.asMap().entries.map((entry) {
                  final index = entry.key;
                  final weekOffset = entry.value;
                  return Padding(
                    padding: EdgeInsets.only(
                      left: index == 0 ? 20 : 0,
                      right: index < availableWeekOffsets.length - 1 ? 24 : 0,
                    ),
                    child: _buildWeekTab(
                      WeekRangeCalculator.getWeekLabel(weekOffset),
                      index,
                      showDot: showDot,
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
        // trailing을 오른쪽에 배치
        if (trailing != null) ...[trailing!, SizedBox(width: 20)],
      ],
    );
  }

  Widget _buildWeekTab(String label, int index, {required bool showDot}) {
    final isSelected = selectedIndex == index;
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
              letterSpacing: -0.5,
              fontWeight: FontWeight.bold,
              color: isSelected
                  ? AppColors.textPrimary
                  : AppColors.textSecondary.withOpacity(0.7),
            ),
            child: Text(label),
          ),
          if (showDot) ...[
            const SizedBox(height: 4),
            // 고정 높이로 UI 흔들림 방지
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
