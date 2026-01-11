import '../utils/timezone_utils.dart';

// 코스별 예약/운영 정책 모델
//
// - 예약 오픈 정책(윈도우형/주간 오픈형)
// - 마감 정책(시작 N분 전 마감)
// - 예약 존재 시 관리자 수정/삭제 제한 및 예외 옵션
//
// 중앙 정책 엔진(ReservationPolicyEngine)이 이 모델을 입력으로 사용합니다.

enum BookingOpenStrategyType {
  rollingWindow, // 오늘부터 N일 후까지
  weeklyRelease, // 매주 특정 요일/시간에 특정 주차가 오픈
}

class RollingWindowOpenStrategy {
  final int windowDays; // 오늘 포함 N일 뒤까지 예약 오픈

  const RollingWindowOpenStrategy({required this.windowDays});

  Map<String, dynamic> toJson() => {'windowDays': windowDays};

  factory RollingWindowOpenStrategy.fromJson(Map<String, dynamic> json) {
    return RollingWindowOpenStrategy(
      windowDays: (json['windowDays'] as int?) ?? 21,
    );
  }
}

class WeeklyReleaseOpenStrategy {
  /// 오픈 요일 (1=월 ... 7=일)
  final int releaseDayOfWeek;

  /// 오픈 시간 ("HH:mm")
  final String releaseTime;

  /// 몇 주 앞 주차를 오픈할지 (예: 1이면 다음주 주차, 2면 다다음주 주차)
  final int weeksAhead;

  const WeeklyReleaseOpenStrategy({
    required this.releaseDayOfWeek,
    required this.releaseTime,
    required this.weeksAhead,
  });

  Map<String, dynamic> toJson() => {
    'releaseDayOfWeek': releaseDayOfWeek,
    'releaseTime': releaseTime,
    'weeksAhead': weeksAhead,
  };

  factory WeeklyReleaseOpenStrategy.fromJson(Map<String, dynamic> json) {
    return WeeklyReleaseOpenStrategy(
      releaseDayOfWeek: (json['releaseDayOfWeek'] as int?) ?? 1,
      releaseTime: (json['releaseTime'] as String?) ?? '10:00',
      weeksAhead: (json['weeksAhead'] as int?) ?? 1,
    );
  }
}

class BookingOpenStrategy {
  final BookingOpenStrategyType type;
  final RollingWindowOpenStrategy? rollingWindow;
  final WeeklyReleaseOpenStrategy? weeklyRelease;

  const BookingOpenStrategy._({
    required this.type,
    this.rollingWindow,
    this.weeklyRelease,
  });

  const BookingOpenStrategy.rollingWindow(RollingWindowOpenStrategy strategy)
    : this._(
        type: BookingOpenStrategyType.rollingWindow,
        rollingWindow: strategy,
      );

  const BookingOpenStrategy.weeklyRelease(WeeklyReleaseOpenStrategy strategy)
    : this._(
        type: BookingOpenStrategyType.weeklyRelease,
        weeklyRelease: strategy,
      );

  Map<String, dynamic> toJson() => {
    'type': type.name,
    if (rollingWindow != null) 'rollingWindow': rollingWindow!.toJson(),
    if (weeklyRelease != null) 'weeklyRelease': weeklyRelease!.toJson(),
  };

  factory BookingOpenStrategy.fromJson(Map<String, dynamic> json) {
    final typeName =
        (json['type'] as String?) ?? BookingOpenStrategyType.rollingWindow.name;
    final type = BookingOpenStrategyType.values.firstWhere(
      (e) => e.name == typeName,
      orElse: () => BookingOpenStrategyType.rollingWindow,
    );

    switch (type) {
      case BookingOpenStrategyType.weeklyRelease:
        return BookingOpenStrategy.weeklyRelease(
          WeeklyReleaseOpenStrategy.fromJson(
            (json['weeklyRelease'] as Map<String, dynamic>?) ?? const {},
          ),
        );
      case BookingOpenStrategyType.rollingWindow:
        return BookingOpenStrategy.rollingWindow(
          RollingWindowOpenStrategy.fromJson(
            (json['rollingWindow'] as Map<String, dynamic>?) ?? const {},
          ),
        );
    }
  }
}

class CoursePolicy {
  final String courseId;
  final String placeId;

  /// 세션 시작 몇 분 전까지 예약 가능 (기본 60분)
  final int closeBeforeMinutes;

  /// 예약 오픈 정책
  final BookingOpenStrategy openStrategy;

  /// 예약이 있는 세션에 대해 관리자 강제 이동(같은 코스 내)을 허용할지 (기본 false)
  final bool allowAdminForceMoveWithinCourse;

  /// 정책 버전 (중간 변경 시 버전 올리는 용도)
  final int version;

  /// 적용 시작 시각(UTC/로컬 구분 없이 ISO로 저장; 앱은 local로 해석)
  final DateTime effectiveFrom;

  const CoursePolicy({
    required this.courseId,
    required this.placeId,
    required this.closeBeforeMinutes,
    required this.openStrategy,
    required this.allowAdminForceMoveWithinCourse,
    required this.version,
    required this.effectiveFrom,
  });

  factory CoursePolicy.defaultFor({
    required String courseId,
    required String placeId,
  }) {
    return CoursePolicy(
      courseId: courseId,
      placeId: placeId,
      closeBeforeMinutes: 60,
      openStrategy: const BookingOpenStrategy.weeklyRelease(
        WeeklyReleaseOpenStrategy(
          releaseDayOfWeek: 1, // 월요일
          releaseTime: '09:00', // 9시
          weeksAhead: 1,
        ),
      ),
      allowAdminForceMoveWithinCourse: false,
      version: 1,
      effectiveFrom: TimezoneUtils.getSeoulDateTime(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'courseId': courseId,
      'placeId': placeId,
      'closeBeforeMinutes': closeBeforeMinutes,
      'openStrategy': openStrategy.toJson(),
      'allowAdminForceMoveWithinCourse': allowAdminForceMoveWithinCourse,
      'version': version,
      'effectiveFrom': effectiveFrom.toIso8601String(),
    };
  }

  factory CoursePolicy.fromJson(Map<String, dynamic> json) {
    return CoursePolicy(
      courseId: json['courseId'] as String,
      placeId: json['placeId'] as String,
      closeBeforeMinutes: (json['closeBeforeMinutes'] as int?) ?? 60,
      openStrategy: BookingOpenStrategy.fromJson(
        (json['openStrategy'] as Map<String, dynamic>?) ?? const {},
      ),
      allowAdminForceMoveWithinCourse:
          (json['allowAdminForceMoveWithinCourse'] as bool?) ?? false,
      version: (json['version'] as int?) ?? 1,
      effectiveFrom: json['effectiveFrom'] != null
          ? DateTime.parse(json['effectiveFrom'] as String)
          : TimezoneUtils.getSeoulDateTime(),
    );
  }
}
