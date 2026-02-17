import '../models/course.dart';
import '../models/course_override.dart';
import '../models/session_reservation_summary.dart';
import '../utils/timezone_utils.dart';

/// 코스 + courseOverride로 주차 슬롯 리스트 생성 (ReservationSummaryProvider.updateSessionSlots용)
/// sessionReservations 컬렉션 없이 place/course/override만으로 슬롯 구성.
class SessionSlotBuilder {
  SessionSlotBuilder._();

  static int _parseTimeToMinutes(String time) {
    final parts = time.split(':');
    if (parts.isEmpty) return 0;
    final h = int.tryParse(parts[0]) ?? 0;
    final m = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
    return (h.clamp(0, 23) * 60) + (m.clamp(0, 59));
  }

  static String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  /// 해당 날짜의 유효 세션 목록 (정기 + add, cancel 반영)
  static List<CourseSession> effectiveSessionsForDate(
    Course course,
    DateTime date,
    Map<String, List<CourseOverride>> overridesByDate,
  ) {
    final dateStr = _formatDate(date);
    final overrides = overridesByDate[dateStr] ?? <CourseOverride>[];
    final regular = course.getSessionsByDay(date.weekday);

    final cancelled = overrides.where((o) => o.isCancelled == true).toList();
    final cancelAllForDay = cancelled.any((o) {
      final st = o.startTime;
      return st == null || st.isEmpty;
    });
    final cancelledStartTimes =
        cancelled.map((o) => o.startTime).whereType<String>().toSet();

    final filteredRegular = cancelAllForDay
        ? <CourseSession>[]
        : regular.where((s) => !cancelledStartTimes.contains(s.startTime)).toList();

    final addedOrModified = overrides
        .where((o) =>
            o.isCancelled != true &&
            o.startTime != null &&
            o.endTime != null)
        .map((o) => CourseSession(
              dayOfWeek: o.dayOfWeek,
              startTime: o.startTime!,
              endTime: o.endTime!,
              capacity: o.capacity ?? 0,
            ))
        .toList();

    final overrideStartTimes = addedOrModified.map((s) => s.startTime).toSet();
    final base =
        filteredRegular.where((s) => !overrideStartTimes.contains(s.startTime)).toList();
    final all = <CourseSession>[...base, ...addedOrModified]
      ..sort((a, b) =>
          _parseTimeToMinutes(a.startTime).compareTo(_parseTimeToMinutes(b.startTime)));
    return all;
  }

  /// 주차(월요일 startDate) 기준으로 슬롯 리스트 생성. getCapacityOverride 없으면 session.capacity 사용.
  static List<SessionReservationSummary> buildSlotsForWeek({
    required String placeId,
    required Course course,
    required DateTime startDate,
    required Map<String, List<CourseOverride>> overridesByDate,
    int? Function(String sessionId, String date)? getCapacityOverride,
  }) {
    final weekDates =
        List.generate(7, (i) => startDate.add(Duration(days: i)));
    final slotList = <SessionReservationSummary>[];
    final now = TimezoneUtils.getSeoulDateTime();

    for (final date in weekDates) {
      final dateStr = _formatDate(date);
      final sessions = effectiveSessionsForDate(course, date, overridesByDate);
      for (final session in sessions) {
        final sessionId = SessionReservationSummary.generateSessionId(
          course.id,
          session.dayOfWeek,
          session.startTime,
        );
        final capacity =
            getCapacityOverride?.call(sessionId, dateStr) ?? session.capacity;
        slotList.add(
          SessionReservationSummary(
            id: '${sessionId}_$dateStr',
            sessionId: sessionId,
            courseId: course.id,
            placeId: placeId,
            dayOfWeek: session.dayOfWeek,
            startTime: session.startTime,
            date: dateStr,
            capacity: capacity,
            reservedCount: 0,
            lastUpdated: now,
            createdAt: null,
          ),
        );
      }
    }
    return slotList;
  }
}
