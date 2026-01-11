import '../models/reservation.dart';
import 'timezone_utils.dart';

/// 예약 관련 유틸리티 함수들
class ReservationUtils {
  // 시간 문자열을 분 단위로 변환
  static int parseTimeToMinutes(String time) {
    final parts = time.split(':');
    final hour = int.parse(parts[0]);
    final minute = int.parse(parts[1]);
    return hour * 60 + minute;
  }

  /// 예약 취소 가능 여부 체크
  ///
  /// 세션 시작 1시간 전까지 취소 가능
  /// - 과거 날짜: 취소 불가
  /// - 오늘 날짜: 세션 시작 1시간 전까지 취소 가능
  /// - 미래 날짜: 취소 가능
  static bool isCancellationAvailable(Reservation reservation) {
    final now = TimezoneUtils.getSeoulDateTime();
    final today = DateTime(now.year, now.month, now.day);
    final reservationDate = DateTime(
      reservation.reservedDate.year,
      reservation.reservedDate.month,
      reservation.reservedDate.day,
    );

    // 날짜 비교
    final isToday = reservationDate == today;
    final isFuture = reservationDate.isAfter(today);

    if (isFuture) {
      // 미래 날짜는 항상 취소 가능
      return true;
    }

    if (isToday) {
      // 오늘인 경우: 세션 시작 1시간 전까지 취소 가능
      final sessionStartMinutes = parseTimeToMinutes(reservation.startTime);
      final sessionStartTime = DateTime(
        now.year,
        now.month,
        now.day,
        sessionStartMinutes ~/ 60,
        sessionStartMinutes % 60,
      );

      // 세션 시작 1시간 전까지 취소 가능
      final oneHourBefore = sessionStartTime.subtract(const Duration(hours: 1));
      return now.isBefore(oneHourBefore);
    }

    // 과거 날짜는 취소 불가
    return false;
  }

  /// 예약 가능 여부 체크 (세션 정보 필요)
  ///
  /// 세션 시작 1시간 전까지 예약 가능
  /// - 과거 날짜: 예약 불가
  /// - 오늘 날짜: 세션 시작 1시간 전까지 예약 가능
  /// - 미래 날짜: 예약 가능 (자리가 있으면)
  static bool isReservationAvailable({
    required int dayOfWeek,
    required String startTime,
    required DateTime date,
  }) {
    final now = TimezoneUtils.getSeoulDateTime();
    final today = DateTime(now.year, now.month, now.day);
    final sessionDate = DateTime(date.year, date.month, date.day);

    // 날짜 비교
    final isToday = sessionDate == today;
    final isFuture = sessionDate.isAfter(today);

    if (isFuture) {
      // 미래 날짜는 항상 예약 가능 (자리가 있으면)
      return true;
    }

    if (isToday) {
      // 오늘인 경우: 세션 시작 1시간 전까지 예약 가능
      final sessionStartMinutes = parseTimeToMinutes(startTime);
      final sessionStartTime = DateTime(
        now.year,
        now.month,
        now.day,
        sessionStartMinutes ~/ 60,
        sessionStartMinutes % 60,
      );

      // 세션 시작 1시간 전까지 예약 가능
      final oneHourBefore = sessionStartTime.subtract(const Duration(hours: 1));
      return now.isBefore(oneHourBefore);
    }

    // 과거 날짜는 예약 불가
    return false;
  }
}
