import '../policies/course_policy.dart';

/// 정책 기반으로 표시할 주차 범위를 계산하는 헬퍼 클래스
class WeekRangeCalculator {
  /// 정책에 따라 표시할 주차 범위 반환
  /// 반환값: [0, 1, 2, ...] 형태의 weekOffset 리스트
  /// - weekOffset = 0: 이번 주
  /// - weekOffset = 1: 다음 주
  /// - weekOffset = 2: 2주 후
  /// - weekOffset = 3: 3주 후
  static List<int> getAvailableWeekOffsets(CoursePolicy policy) {
    if (policy.openStrategy.type == BookingOpenStrategyType.rollingWindow) {
      // rollingWindow: 오픈 가능한 날짜를 주차로 변환
      final days = policy.openStrategy.rollingWindow?.windowDays ?? 21;
      final maxWeeks = (days / 7).ceil().clamp(1, 8);
      return List.generate(maxWeeks, (i) => i);
    } else {
      // weeklyRelease: weeksAhead 기반
      final weeksAhead = policy.openStrategy.weeklyRelease?.weeksAhead ?? 1;
      // weeksAhead=1이면 [0] (이번주만)
      // weeksAhead=2이면 [0, 1] (이번주, 다음주)
      return List.generate(weeksAhead.clamp(1, 8), (i) => i);
    }
  }

  /// 주차 인덱스를 사용자 친화적인 라벨로 변환
  /// - weekOffset = 0: "이번 주"
  /// - weekOffset = 1: "다음 주"
  /// - weekOffset = 2: "다다음 주"
  /// - weekOffset >= 3: "${weekOffset}주 후"
  static String getWeekLabel(int weekOffset) {
    switch (weekOffset) {
      case 0:
        return '이번 주';
      case 1:
        return '다음 주';
      case 2:
        return '다다음 주';
      default:
        return '$weekOffset주 후';
    }
  }
}
