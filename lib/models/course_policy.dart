// 코스별 예약/운영 정책 모델 (Course 문서에 embed)
//
// - 예약 오픈 정책(윈도우형/주간 오픈형)
// - 마감 정책(예약/취소 각각 시작 N분 전 마감)
// - 예약 존재 시 관리자 수정/삭제 제한 및 예외 옵션
//
// 정책 변경은 기존 예약 재검증하지 않음.

enum BookingOpenStrategyType { rollingWindow, weeklyRelease }

class RollingWindowOpenStrategy {
  final int windowDays;

  const RollingWindowOpenStrategy({required this.windowDays});

  Map<String, dynamic> toJson() => {'windowDays': windowDays};

  factory RollingWindowOpenStrategy.fromJson(Map<String, dynamic> json) {
    return RollingWindowOpenStrategy(
      windowDays: (json['windowDays'] as int?) ?? 21,
    );
  }
}

class WeeklyReleaseOpenStrategy {
  final int releaseDayOfWeek;
  final String releaseTime;
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

/// 코스 예약 정책
/// (관리자 강제 이동은 항상 허용으로 간주, 별도 필드 없음)
class CoursePolicy {
  /// 세션 시작 N분 전까지만 예약 가능
  final int reserveCloseBeforeMinutes;

  /// 세션 시작 N분 전까지만 취소 가능
  final int cancelCloseBeforeMinutes;

  final BookingOpenStrategy openStrategy;
  final DateTime updatedAt;

  const CoursePolicy({
    required this.reserveCloseBeforeMinutes,
    required this.cancelCloseBeforeMinutes,
    required this.openStrategy,
    required this.updatedAt,
  });

  static CoursePolicy get defaultValue => CoursePolicy(
    reserveCloseBeforeMinutes: 60,
    cancelCloseBeforeMinutes: 60,
    openStrategy: const BookingOpenStrategy.weeklyRelease(
      WeeklyReleaseOpenStrategy(
        releaseDayOfWeek: 1,
        releaseTime: '09:00',
        weeksAhead: 1,
      ),
    ),
    updatedAt: DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'reserveCloseBeforeMinutes': reserveCloseBeforeMinutes,
    'cancelCloseBeforeMinutes': cancelCloseBeforeMinutes,
    // 구버전 호환
    'closeBeforeMinutes': reserveCloseBeforeMinutes,
    'openStrategy': openStrategy.toJson(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  static int _readMinutes(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    final legacy = json['closeBeforeMinutes'];
    if (legacy is int) return legacy;
    if (legacy is num) return legacy.toInt();
    return 60;
  }

  factory CoursePolicy.fromJson(Map<String, dynamic>? json) {
    if (json == null || json.isEmpty) return defaultValue;
    return CoursePolicy(
      reserveCloseBeforeMinutes: _readMinutes(json, 'reserveCloseBeforeMinutes'),
      cancelCloseBeforeMinutes: _readMinutes(json, 'cancelCloseBeforeMinutes'),
      openStrategy: BookingOpenStrategy.fromJson(
        (json['openStrategy'] as Map<String, dynamic>?) ?? const {},
      ),
      updatedAt:
          json['updatedAt'] != null
              ? DateTime.parse(json['updatedAt'] as String).toLocal()
              : DateTime.now(),
    );
  }
}
