import 'timezone_utils.dart';
import '../models/course.dart';

/// 유효기간(종료일) 계산/통제 유틸
///
/// 목표:
/// - UI는 "날짜"만 다루고(시간 제외), 항상 서울 기준으로 계산/비교한다.
/// - 기간 연장은 "기존 종료일"을 기준으로 +N 한다.
/// - 종료일은 최소 (max(오늘, 기존 종료일)) 이상만 허용한다. (단축 방지)
class EnrollmentValidUntilUtil {
  EnrollmentValidUntilUtil._();

  static final DateTime _maxSelectableDate = DateTime(2100, 12, 31);

  /// DateTime을 "서울 날짜(YYYY-MM-DD) 00:00" 형태로 정규화
  static DateTime toSeoulDateOnly(DateTime dt) {
    final s = TimezoneUtils.formatDateToSeoul(dt); // YYYY-MM-DD
    final parts = s.split('-');
    final y = int.parse(parts[0]);
    final m = int.parse(parts[1]);
    final d = int.parse(parts[2]);
    return DateTime(y, m, d);
  }

  /// 날짜(00:00)끼리 비교해서 더 큰 날짜 반환
  static DateTime maxDateOnly(DateTime a, DateTime b) {
    final aa = DateTime(a.year, a.month, a.day);
    final bb = DateTime(b.year, b.month, b.day);
    return aa.isAfter(bb) ? aa : bb;
  }

  static bool isBeforeOrSameDateOnly(DateTime a, DateTime b) {
    final aa = DateTime(a.year, a.month, a.day);
    final bb = DateTime(b.year, b.month, b.day);
    return aa.isBefore(bb) || aa.isAtSameMomentAs(bb);
  }

  static DateTime clampToMaxDateOnly(DateTime dateOnly) {
    final d = DateTime(dateOnly.year, dateOnly.month, dateOnly.day);
    return d.isAfter(_maxSelectableDate) ? _maxSelectableDate : d;
  }

  /// 기간 연장 "기준 종료일" 계산: max(기존 종료일, 오늘)
  static DateTime computeBaseEndDateOnly({
    required DateTime originalValidUntil,
    DateTime? seoulToday,
  }) {
    final today = seoulToday ?? TimezoneUtils.getSeoulToday();
    final original = toSeoulDateOnly(originalValidUntil);
    return maxDateOnly(original, today);
  }

  /// base(날짜) + periodValue 계산 (서울 날짜-only)
  static DateTime computeExtendedEndDateOnly({
    required DateTime baseEndDateOnly,
    required PeriodType periodType,
    required int periodValue,
  }) {
    final base = DateTime(
      baseEndDateOnly.year,
      baseEndDateOnly.month,
      baseEndDateOnly.day,
    );
    if (periodValue == 0) return base;

    DateTime result;
    switch (periodType) {
      case PeriodType.weeks:
        result = base.add(Duration(days: periodValue * 7));
        break;
      case PeriodType.days:
        result = base.add(Duration(days: periodValue));
        break;
      case PeriodType.months:
        result = _addMonthsClamped(base, periodValue);
        break;
    }

    return clampToMaxDateOnly(result);
  }

  static int _daysInMonth(int year, int month) {
    final lastDay = DateTime(year, month + 1, 0);
    return lastDay.day;
  }

  /// month overflow를 고려하고, 말일은 말일로 clamp한다.
  static DateTime _addMonthsClamped(DateTime dateOnly, int monthsToAdd) {
    final monthIndex = (dateOnly.month - 1) + monthsToAdd;
    final targetYear = dateOnly.year + (monthIndex ~/ 12);
    final targetMonth = (monthIndex % 12) + 1;
    final maxDay = _daysInMonth(targetYear, targetMonth);
    final targetDay = dateOnly.day > maxDay ? maxDay : dateOnly.day;
    return DateTime(targetYear, targetMonth, targetDay);
  }
}


