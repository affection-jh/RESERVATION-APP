/// 캘린더/세션 관련 공통 유틸 (날짜·시간·주차)
///
/// calendar_screen, compact_calendar_widget, drag_calendar_editor 등에서
/// 중복되던 _formatDate, _parseTimeToMinutes, _startOfWeekMonday 를 일원화.
class CalendarUtils {
  CalendarUtils._();

  /// "HH:mm" 또는 "H:mm" 문자열을 분 단위 정수로 변환 (0 ~ 1439)
  static int parseTimeToMinutes(String time) {
    final parts = time.split(':');
    if (parts.isEmpty) return 0;
    final h = int.tryParse(parts[0].trim()) ?? 0;
    final m = parts.length > 1 ? (int.tryParse(parts[1].trim()) ?? 0) : 0;
    return (h.clamp(0, 23) * 60) + (m.clamp(0, 59));
  }

  /// 분 단위 정수를 "HH:mm" 문자열로 변환
  static String minutesToTimeString(int minutes) {
    final total = minutes.clamp(0, 24 * 60 - 1);
    final hour = (total ~/ 60) % 24;
    final minute = total % 60;
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  /// DateTime을 "YYYY-MM-DD" 형식 문자열로 (Firestore/API 일치)
  static String formatDateYMD(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  /// 해당 날짜가 속한 주의 월요일 00:00 (날짜만)
  static DateTime startOfWeekMonday(DateTime date) {
    final dateOnly = DateTime(date.year, date.month, date.day);
    return dateOnly.subtract(
      Duration(days: dateOnly.weekday - DateTime.monday),
    );
  }

  /// 기준일 + weekOffset 주의 월요일 00:00 (0=이번주, 1=다음주 …)
  static DateTime weekStartFrom(DateTime referenceDate, int weekOffset) {
    final monday = startOfWeekMonday(referenceDate);
    return monday.add(Duration(days: 7 * weekOffset));
  }
}
