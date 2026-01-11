import 'course_policy.dart';
import '../utils/timezone_utils.dart';

enum ReservationLockReason {
  none,
  pastDate, // 과거 날짜
  notOpenedYet, // 오픈 전
  closedBeforeStart, // 시작 임박 마감
  full, // 정원 마감
  noCreditsOrExpired, // 예약 횟수/기간 문제
}

enum AdminEditLockReason {
  none,
  pastDate,
  hasReservations, // 예약 존재로 편집 잠금
}

class ReservationEligibility {
  final bool canReserve;
  final ReservationLockReason reason;
  final DateTime? openAt; // 오픈 전인 경우 오픈 시각(알림/표시용)

  const ReservationEligibility({
    required this.canReserve,
    required this.reason,
    this.openAt,
  });
}

class AdminEditEligibility {
  final bool canEditTime; // 시간 변경
  final bool canDelete; // 삭제
  final bool canCancelSession; // 취소(운영자 취소)
  final AdminEditLockReason reason;

  const AdminEditEligibility({
    required this.canEditTime,
    required this.canDelete,
    required this.canCancelSession,
    required this.reason,
  });
}

/// 예약/편집 정책 엔진 (중앙 규칙)
///
/// ✅ 시간대 처리:
/// - 클라이언트와 서버 모두 서울 시간대(UTC+9)를 사용합니다
/// - 클라이언트: `TimezoneUtils.getSeoulDateTime()` 사용
/// - 서버: `getSeoulDateTime()` 사용
/// - 이를 통해 클라이언트와 서버의 검증 결과가 일관되게 유지됩니다
/// - 최종 검증은 서버에서 수행되므로 클라이언트 검증은 UX 목적
///
/// 자세한 내용은 `RESERVATION_POLICY_ENGINE.md`를 참고하세요.
class ReservationPolicyEngine {
  /// 예약 오픈 여부 + 오픈 예정 시각 계산
  ///
  /// ⚠️ 중요: `now` 파라미터는 반드시 서울 시간대를 사용해야 합니다.
  /// 클라이언트에서는 `TimezoneUtils.getSeoulDateTime()`을 사용하세요.
  static ReservationEligibility evaluateReservation({
    required DateTime now, // 서울 시간대 (TimezoneUtils.getSeoulDateTime() 사용)
    required CoursePolicy policy,
    required DateTime sessionDate, // 날짜(yyyy-mm-dd)
    required String startTime, // "HH:mm"
    required int capacity,
    required int reservedCount,
    required bool enrollmentCanReserve, // (유효기간 && 남은 횟수)
  }) {
    // 1) 과거 날짜 (가장 우선 체크)
    // ✅ 서울 시간대 기준으로 날짜 비교 (UTC 해석 방지)
    final today = TimezoneUtils.getSeoulToday();
    final sessionDateOnly = TimezoneUtils.getSeoulDateOnly(sessionDate);
    if (sessionDateOnly.isBefore(today)) {
      return const ReservationEligibility(
        canReserve: false,
        reason: ReservationLockReason.pastDate,
      );
    }

    // 2) 정원 마감
    if (reservedCount >= capacity) {
      return const ReservationEligibility(
        canReserve: false,
        reason: ReservationLockReason.full,
      );
    }

    // 3) 시작 N분 전 마감
    // ✅ 서울 시간대 기준으로 세션 시작 시간 계산
    final sessionStart = TimezoneUtils.combineDateAndTimeSeoul(
      sessionDate,
      startTime,
    );
    final closeAt = sessionStart.subtract(
      Duration(minutes: policy.closeBeforeMinutes),
    );
    if (!now.isBefore(closeAt)) {
      return const ReservationEligibility(
        canReserve: false,
        reason: ReservationLockReason.closedBeforeStart,
      );
    }

    // 4) 오픈 정책
    final openAt = _computeOpenAtForSession(
      now: now,
      policy: policy,
      sessionDate: sessionDate,
    );
    if (openAt != null && now.isBefore(openAt)) {
      return ReservationEligibility(
        canReserve: false,
        reason: ReservationLockReason.notOpenedYet,
        openAt: openAt,
      );
    }

    // 5) 크레딧/유효기간 (마지막 체크)
    // 다른 체크를 먼저 수행하여 더 구체적인 오류 메시지를 제공
    if (!enrollmentCanReserve) {
      return const ReservationEligibility(
        canReserve: false,
        reason: ReservationLockReason.noCreditsOrExpired,
      );
    }

    return const ReservationEligibility(
      canReserve: true,
      reason: ReservationLockReason.none,
    );
  }

  /// 관리자 편집 가능 여부
  ///
  /// 기본 정책(확정):
  /// - 예약이 있으면 시간변경/삭제 불가
  /// - 예약이 있으면 '취소'만 가능(운영자 취소 플로우)
  static AdminEditEligibility evaluateAdminEdit({
    required DateTime now,
    required DateTime sessionDate,
    required int reservedCount,
  }) {
    // ✅ 서울 시간대 기준으로 날짜 비교 (UTC 해석 방지)
    final today = TimezoneUtils.getSeoulToday();
    final sessionDateOnly = TimezoneUtils.getSeoulDateOnly(sessionDate);
    if (sessionDateOnly.isBefore(today)) {
      return const AdminEditEligibility(
        canEditTime: false,
        canDelete: false,
        canCancelSession: false,
        reason: AdminEditLockReason.pastDate,
      );
    }

    if (reservedCount > 0) {
      return const AdminEditEligibility(
        canEditTime: false,
        canDelete: false,
        canCancelSession: true,
        reason: AdminEditLockReason.hasReservations,
      );
    }

    return const AdminEditEligibility(
      canEditTime: true,
      canDelete: true,
      canCancelSession: true,
      reason: AdminEditLockReason.none,
    );
  }

  /// 세션 오픈 예정 시각 계산
  ///
  /// - rollingWindow: (세션 날짜 - windowDays)의 00:00에 오픈되는 것으로 단순화
  /// - weeklyRelease: 세션 주차를 weeksAhead 앞 주차의 releaseDay/releaseTime에 오픈
  ///
  /// ⚠️ 시간대 처리:
  /// - `now` 파라미터는 서울 시간대(TimezoneUtils.getSeoulDateTime())
  /// - 반환되는 DateTime도 동일한 시간대(로컬 시간대)로 생성하여 일관성 유지
  static DateTime? _computeOpenAtForSession({
    required DateTime now,
    required CoursePolicy policy,
    required DateTime sessionDate,
  }) {
    // ✅ 서울 시간대 기준으로 날짜 추출 (UTC 해석 방지)
    final dateOnly = TimezoneUtils.getSeoulDateOnly(sessionDate);

    switch (policy.openStrategy.type) {
      case BookingOpenStrategyType.rollingWindow:
        final days = policy.openStrategy.rollingWindow?.windowDays ?? 21;
        final openDate = dateOnly.subtract(Duration(days: days));
        // ✅ 서울 시간대 기준으로 날짜만 반환 (00:00)
        return DateTime(openDate.year, openDate.month, openDate.day);
      case BookingOpenStrategyType.weeklyRelease:
        final s = policy.openStrategy.weeklyRelease;
        if (s == null) return null;

        final weekStart = _startOfWeekMonday(dateOnly);
        final openWeekStart = weekStart.subtract(
          Duration(days: 7 * s.weeksAhead),
        );
        final parts = s.releaseTime.split(':');
        final h = int.tryParse(parts[0]) ?? 10;
        final m = int.tryParse(parts[1]) ?? 0;

        // ✅ 서울 시간대 기준으로 오픈 시각 생성
        final openAt = TimezoneUtils.combineDateAndTimeSeoul(
          openWeekStart.add(Duration(days: (s.releaseDayOfWeek - 1))),
          '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}',
        );
        return openAt;
    }
  }

  static DateTime _startOfWeekMonday(DateTime date) {
    final dateOnly = DateTime(date.year, date.month, date.day);
    return dateOnly.subtract(
      Duration(days: dateOnly.weekday - DateTime.monday),
    );
  }
}
