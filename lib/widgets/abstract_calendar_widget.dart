import 'package:flutter/material.dart';
import '../models/course.dart';
import '../theme/app_colors.dart';
import '../utils/timezone_utils.dart';

/// 완전히 추상화된 캘린더 위젯 (코스 카드 내부용)
class AbstractCalendarWidget extends StatelessWidget {
  final Course course;
  final double height;
  final int weekOffset; // 0: 이번주, 1: 다음주, 2: 다다음주

  const AbstractCalendarWidget({
    super.key,
    required this.course,
    this.height = 200,
    this.weekOffset = 0,
  });

  @override
  Widget build(BuildContext context) {
    // 현재 주의 날짜들 계산 (주차 계산은 "오늘 00:00" 기준)
    final today = TimezoneUtils.getSeoulToday();
    final daysFromMonday = today.weekday - 1;
    final thisWeekMonday = today.subtract(Duration(days: daysFromMonday));
    final weekStart = thisWeekMonday.add(Duration(days: weekOffset * 7));

    // 월~일 모든 요일 생성
    final allWeekDates = List.generate(7, (index) {
      return weekStart.add(Duration(days: index));
    });

    // 세션이 있는 날짜만 필터링
    final availableDays = course.availableDays;
    final weekDates = allWeekDates.where((date) {
      return availableDays.contains(date.weekday);
    }).toList();

    if (weekDates.isEmpty || course.sessions.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            '세션이 없습니다',
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
          ),
        ),
      );
    }

    return SizedBox(
      height: height,
      child: Column(
        children: [
          // 요일 헤더
          _buildDayHeaders(weekDates),
          // 캘린더 그리드
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return _buildCalendarGrid(weekDates, constraints.maxHeight);
              },
            ),
          ),
        ],
      ),
    );
  }

  // 요일 헤더
  Widget _buildDayHeaders(List<DateTime> dates) {
    final weekDays = ['월', '화', '수', '목', '금', '토', '일'];

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: dates.map((date) {
          final dayIndex = date.weekday - 1;
          final isToday = _isToday(date);

          return Expanded(
            child: Column(
              children: [
                Text(
                  weekDays[dayIndex],
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: isToday
                        ? AppColors.primaryGreen
                        : AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: isToday
                        ? AppColors.primaryGreen
                        : Colors.transparent,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '${date.day}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: isToday
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: isToday ? Colors.white : AppColors.textPrimary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  // 캘린더 그리드
  Widget _buildCalendarGrid(List<DateTime> dates, double gridHeight) {
    // 세션 시간 범위 계산
    int minHour = 24;
    int maxHour = 0;

    for (final session in course.sessions) {
      final startHour = _parseHour(session.startTime);
      final endHour = _parseHour(session.endTime);
      if (startHour < minHour) minHour = startHour;
      if (endHour > maxHour) maxHour = endHour;
    }

    // 시간 범위 확장 (위아래 여백)
    minHour = (minHour - 1).clamp(0, 23);
    maxHour = (maxHour + 1).clamp(0, 23);

    final hourCount = maxHour - minHour + 1;
    final hourHeight = gridHeight / hourCount;

    return Row(
      children: dates.map((date) {
        return Expanded(
          child: _buildDayColumn(date, minHour, maxHour, hourHeight),
        );
      }).toList(),
    );
  }

  // 날짜별 컬럼
  Widget _buildDayColumn(
    DateTime date,
    int minHour,
    int maxHour,
    double hourHeight,
  ) {
    final dayOfWeek = date.weekday;
    final daySessions = course.sessions
        .where((s) => s.dayOfWeek == dayOfWeek)
        .toList();

    return Stack(
      children: [
        // 시간 라인 (더 연하게)
        ...List.generate(maxHour - minHour + 1, (index) {
          return Positioned(
            top: index * hourHeight,
            left: 0,
            right: 0,
            child: Container(
              height: 0.3,
              color: AppColors.borderLight.withOpacity(0.3),
            ),
          );
        }),
        // 세션 블록
        ...daySessions.map((session) {
          final startHour = _parseHour(session.startTime);
          final endHour = _parseHour(session.endTime);
          final startMinutes = _parseMinutes(session.startTime);
          final endMinutes = _parseMinutes(session.endTime);

          final top =
              ((startHour - minHour) * hourHeight) +
              (startMinutes / 60 * hourHeight);
          final height =
              ((endHour - startHour) * hourHeight) +
              ((endMinutes - startMinutes) / 60 * hourHeight);

          return Positioned(
            top: top,
            left: 1,
            right: 1,
            height: height,
            child: Container(
              decoration: BoxDecoration(
                color: course.colorValue.withOpacity(0.25),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Center(
                child: Text(
                  session.startTime,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: course.colorValue,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ],
    );
  }

  // 시간 파싱 (예: "09:00" -> 9)
  int _parseHour(String time) {
    final parts = time.split(':');
    if (parts.isEmpty) return 0;
    return int.tryParse(parts[0]) ?? 0;
  }

  // 분 파싱 (예: "09:30" -> 30)
  int _parseMinutes(String time) {
    final parts = time.split(':');
    if (parts.length < 2) return 0;
    return int.tryParse(parts[1]) ?? 0;
  }

  // 오늘인지 확인
  bool _isToday(DateTime date) {
    final today = TimezoneUtils.getSeoulDateTime();
    return date.year == today.year &&
        date.month == today.month &&
        date.day == today.day;
  }
}
