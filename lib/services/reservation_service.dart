import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import '../models/session_reservation.dart';
import '../models/session_reservation_summary.dart';
import '../models/course.dart';
import '../models/place.dart';
import '../utils/timezone_utils.dart';

/// 예약 관련 Firestore/Callable + 실시간 알림 통합 서비스
class ReservationService {
  static final ReservationService _instance = ReservationService._internal();
  factory ReservationService() => _instance;
  ReservationService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  final _reservationUpdateController =
      StreamController<SessionReservationUpdate>.broadcast();
  final _sessionUpdateController = StreamController<SessionUpdate>.broadcast();
  final _courseUpdateController = StreamController<CourseUpdate>.broadcast();
  final _placeUpdateController = StreamController<PlaceUpdate>.broadcast();

  Place? _currentPlace;

  void setPlace(Place place) {
    _currentPlace = place;
    _notifyPlaceUpdate(PlaceUpdate(place: place, type: UpdateType.full));
  }

  Place? get currentPlace => _currentPlace;

  // ==================== 정렬/키/배치 결과 (Provider 등에서 사용) ====================

  static int parseTimeToMinutes(String? time) {
    if (time == null || time.isEmpty) return 0;
    final parts = time.split(':');
    if (parts.isEmpty) return 0;
    final h = int.tryParse(parts[0]) ?? 0;
    final m = (parts.length > 1) ? (int.tryParse(parts[1]) ?? 0) : 0;
    return (h.clamp(0, 23) * 60) + (m.clamp(0, 59));
  }

  static DateTime reservationStartDateTime(SessionReservation r) {
    final minutes = parseTimeToMinutes(r.startTime);
    return DateTime(
      r.reservedDate.year,
      r.reservedDate.month,
      r.reservedDate.day,
      minutes ~/ 60,
      minutes % 60,
    );
  }

  /// 임박한 예약 우선 정렬 (미래: 시간 오름차순, 과거: 시간 내림차순)
  static List<SessionReservation> sortReservationsUpcomingFirst(
    List<SessionReservation> input,
  ) {
    final now = TimezoneUtils.getSeoulDateTime();
    final next = [...input];
    next.sort((a, b) {
      final aDt = reservationStartDateTime(a);
      final bDt = reservationStartDateTime(b);
      final aUpcoming = !aDt.isBefore(now);
      final bUpcoming = !bDt.isBefore(now);
      if (aUpcoming != bUpcoming) return aUpcoming ? -1 : 1;
      final cmp = aUpcoming ? aDt.compareTo(bDt) : bDt.compareTo(aDt);
      if (cmp != 0) return cmp;
      return a.id.compareTo(b.id);
    });
    return next;
  }

  static String reservationKey(SessionReservation r) {
    final d = r.reservedDate;
    final dateString =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return '${r.placeId}|${r.courseId}|${r.dayOfWeek}|${r.startTime}|$dateString';
  }

  static String operationKeyFromParts({
    required String placeId,
    required String courseId,
    required int dayOfWeek,
    required String startTime,
    required DateTime date,
  }) {
    final d = DateTime(date.year, date.month, date.day);
    final dateString =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return '$placeId|$courseId|$dayOfWeek|$startTime|$dateString';
  }

  /// 배치 이동 결과에서 실패가 있으면 예외 발생
  static void throwIfBatchMoveFailed(Map<String, dynamic> result) {
    final results = result['results'] as List<dynamic>? ?? [];
    final failed =
        results.where((r) => (r as Map)['success'] != true).toList();
    if (failed.isNotEmpty) {
      final error =
          (failed.first as Map)['error'] as String? ?? '예약 이동에 실패했습니다.';
      throw Exception(error);
    }
  }

  /// 배치 취소 결과에서 실패가 있으면 예외 발생
  static void throwIfBatchCancelFailed(Map<String, dynamic> result) {
    final results = result['results'] as List<dynamic>? ?? [];
    final failed =
        results.where((r) => (r as Map)['success'] != true).toList();
    if (failed.isNotEmpty) {
      final error =
          (failed.first as Map)['error'] as String? ?? '예약 취소에 실패했습니다.';
      throw Exception(error);
    }
  }

  /// capacity overrides를 summary 맵에 반영한 새 맵 반환
  static Map<String, SessionReservationSummary> applyCapacityOverridesToSummaries(
    Map<String, SessionReservationSummary> byKey,
    Map<String, int> overridesByKey,
  ) {
    final result = <String, SessionReservationSummary>{};
    for (final entry in byKey.entries) {
      final override = overridesByKey[entry.key];
      result[entry.key] = override != null
          ? entry.value.copyWith(capacity: override)
          : entry.value;
    }
    return result;
  }

  /// 리스트를 (sessionId_date) 맵으로 변환하고 capacity override 적용
  static Map<String, SessionReservationSummary> buildSessionSummaryMapWithOverrides(
    List<SessionReservationSummary> list,
    Map<String, int> overridesByKey,
  ) {
    final next = <String, SessionReservationSummary>{};
    for (final sr in list) {
      final key = '${sr.sessionId}_${sr.date}';
      final override = overridesByKey[key];
      next[key] = override != null ? sr.copyWith(capacity: override) : sr;
    }
    return next;
  }

  // ---------- 헬퍼 ----------
  static String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  static DateTime _timestampToDateTime(dynamic timestamp) {
    if (timestamp == null) return DateTime.now();
    if (timestamp is Timestamp) return timestamp.toDate();
    if (timestamp is String) return DateTime.parse(timestamp);
    throw Exception('Invalid timestamp format');
  }

  static List<SessionReservation> _mapReservationDocs(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    return docs.map((doc) {
      final data = Map<String, dynamic>.from(doc.data());
      data['reservedAt'] =
          _timestampToDateTime(data['reservedAt']).toIso8601String();
      data['reservedDate'] =
          _timestampToDateTime(data['reservedDate']).toIso8601String();
      return SessionReservation.fromJson(data);
    }).toList();
  }

  // ==================== Stream 구독 (UI 알림용) ====================

  /// 예약 추가/삭제 알림 스트림 (UI 갱신용)
  Stream<SessionReservationUpdate> watchReservationUpdates() =>
      _reservationUpdateController.stream;
  Stream<SessionUpdate> watchSession(
    String courseId,
    int dayOfWeek,
    String startTime,
  ) =>
      _sessionUpdateController.stream.where(
        (u) =>
            u.courseId == courseId &&
            u.dayOfWeek == dayOfWeek &&
            u.startTime == startTime,
      );
  Stream<CourseUpdate> watchCourse(String courseId) =>
      _courseUpdateController.stream.where((u) => u.courseId == courseId);
  Stream<PlaceUpdate> watchPlace() => _placeUpdateController.stream;

  Future<void> addReservation(SessionReservation reservation) async {
    if (_currentPlace == null) return;
    final course = _currentPlace!.findCourse(reservation.courseId);
    final session = course?.findSession(
      reservation.dayOfWeek,
      reservation.startTime,
    );
    if (session == null) return;
    _notifySessionUpdate(SessionUpdate(
      courseId: reservation.courseId,
      dayOfWeek: reservation.dayOfWeek,
      startTime: reservation.startTime,
      session: session,
      type: UpdateType.refresh,
    ));
    _notifySessionReservationUpdate(
      SessionReservationUpdate(reservation: reservation, type: UpdateType.added),
    );
  }

  Future<void> removeReservation(
    String reservationId,
    String courseId,
    int dayOfWeek,
    String startTime,
  ) async {
    if (_currentPlace == null) return;
    final course = _currentPlace!.findCourse(courseId);
    final session = course?.findSession(dayOfWeek, startTime);
    if (session == null) return;
    _notifySessionUpdate(SessionUpdate(
      courseId: courseId,
      dayOfWeek: dayOfWeek,
      startTime: startTime,
      session: session,
      type: UpdateType.refresh,
    ));
    _notifySessionReservationUpdate(
      SessionReservationUpdate(reservationId: reservationId, type: UpdateType.removed),
    );
  }

  Future<void> refreshSession(
    String courseId,
    int dayOfWeek,
    String startTime,
  ) async {
    if (_currentPlace == null) return;
    final course = _currentPlace!.findCourse(courseId);
    final session = course?.findSession(dayOfWeek, startTime);
    if (session == null) return;
    _notifySessionUpdate(SessionUpdate(
      courseId: courseId,
      dayOfWeek: dayOfWeek,
      startTime: startTime,
      session: session,
      type: UpdateType.refresh,
    ));
  }

  Future<void> refreshCourse(String courseId) async {
    if (_currentPlace == null) return;
    final course = _currentPlace!.findCourse(courseId);
    if (course == null) return;
    _notifyCourseUpdate(CourseUpdate(courseId: courseId, course: course, type: UpdateType.refresh));
  }

  Future<void> refreshDate(DateTime date) async {
    if (_currentPlace == null) return;
    for (final course in _currentPlace!.courses) {
      for (final session in course.sessions) {
        _notifySessionUpdate(SessionUpdate(
          courseId: course.id,
          dayOfWeek: session.dayOfWeek,
          startTime: session.startTime,
          session: session,
          type: UpdateType.refresh,
        ));
      }
    }
  }

  Future<void> refreshPlace() async {
    if (_currentPlace == null) return;
    _notifyPlaceUpdate(PlaceUpdate(place: _currentPlace!, type: UpdateType.full));
  }

  void _notifySessionReservationUpdate(SessionReservationUpdate update) {
    if (!_reservationUpdateController.isClosed) {
      _reservationUpdateController.add(update);
    }
  }

  void _notifySessionUpdate(SessionUpdate update) {
    if (!_sessionUpdateController.isClosed) _sessionUpdateController.add(update);
  }

  void _notifyCourseUpdate(CourseUpdate update) {
    if (!_courseUpdateController.isClosed) _courseUpdateController.add(update);
  }

  void _notifyPlaceUpdate(PlaceUpdate update) {
    if (!_placeUpdateController.isClosed) _placeUpdateController.add(update);
  }

  // ==================== Firestore / Callable CRUD ====================

  Future<bool> hasAnyReservationsForCourse(String courseId) async {
    final snapshot = await _firestore
        .collection('reservations')
        .where('courseId', isEqualTo: courseId)
        .limit(1)
        .get();
    return snapshot.docs.isNotEmpty;
  }

  /// 예약 생성 (실패 시 예외)
  /// [createOneTimeEnrollment] true면 수강 미등록 시 서버에서 1회석 enrollment 생성 후 예약(관리자만)
  Future<SessionReservation> createReservation(
    SessionReservation reservation, {
    bool force = false,
    bool createOneTimeEnrollment = false,
    String? adminDisplayNameForUser,
  }) async {
    final dateString = _formatDate(reservation.reservedDate);
    final params = <String, dynamic>{
      'placeId': reservation.placeId,
      'courseId': reservation.courseId,
      'dayOfWeek': reservation.dayOfWeek,
      'startTime': reservation.startTime,
      'reservedDateString': dateString,
      'userId': reservation.userId,
      'force': force,
    };
    if (createOneTimeEnrollment) {
      params['createOneTimeEnrollment'] = true;
      if (adminDisplayNameForUser != null && adminDisplayNameForUser.isNotEmpty) {
        params['adminDisplayNameForUser'] = adminDisplayNameForUser;
      }
    }
    final result = await FirebaseFunctions.instance
        .httpsCallable('createReservation')
        .call(params);
    final data = result.data as Map<dynamic, dynamic>;
    final id = (data['id'] as String?) ?? '';
    if (id.isEmpty) throw Exception('예약 생성에 실패했습니다. (서버 응답 오류)');
    return reservation.copyWith(id: id);
  }

  /// 배치 예약 생성 (관리자). 한 번의 호출로 동일 세션/날짜에 여러 사용자 예약.
  Future<Map<String, dynamic>> batchCreateReservations({
    required String placeId,
    required String courseId,
    required int dayOfWeek,
    required String startTime,
    required DateTime reservedDate,
    required List<Map<String, dynamic>> entries,
    bool force = false,
  }) async {
    final dateString = _formatDate(reservedDate);
    final params = <String, dynamic>{
      'placeId': placeId,
      'courseId': courseId,
      'dayOfWeek': dayOfWeek,
      'startTime': startTime,
      'reservedDateString': dateString,
      'entries': entries,
      'force': force,
    };
    final result = await FirebaseFunctions.instance
        .httpsCallable('batchCreateReservations')
        .call(params);
    final data = result.data as Map<dynamic, dynamic>;
    return Map<String, dynamic>.from(data);
  }

  Future<void> deleteReservation({
    required String reservationId,
    required String placeId,
  }) async {
    await batchCancelReservations(
      reservationIds: [reservationId],
      placeId: placeId,
    );
  }

  Future<void> moveReservationWithinCourse({
    required String reservationId,
    required String placeId,
    required int newDayOfWeek,
    required String newStartTime,
    required DateTime newReservedDate,
  }) async {
    await batchMoveReservations(
      reservationIds: [reservationId],
      placeId: placeId,
      newDayOfWeek: newDayOfWeek,
      newStartTime: newStartTime,
      newReservedDate: newReservedDate,
    );
  }

  Stream<List<SessionReservation>> watchUserReservations(
    String userId, {
    required String placeId,
  }) {
    return _firestore
        .collection('reservations')
        .where('placeId', isEqualTo: placeId)
        .where('userId', isEqualTo: userId)
        .orderBy('reservedDate', descending: false)
        .snapshots()
        .map((s) => _mapReservationDocs(s.docs));
  }

  Stream<List<SessionReservation>> watchSessionReservations({
    required String placeId,
    required String courseId,
    required int dayOfWeek,
    required String startTime,
    required DateTime date,
  }) {
    final dateString = _formatDate(date);
    return _firestore
        .collection('reservations')
        .where('placeId', isEqualTo: placeId)
        .where('courseId', isEqualTo: courseId)
        .where('dayOfWeek', isEqualTo: dayOfWeek)
        .where('startTime', isEqualTo: startTime)
        .where('reservedDateString', isEqualTo: dateString)
        .snapshots()
        .map((s) => _mapReservationDocs(s.docs));
  }

  /// reservationSummary 컬렉션 구독 (N/M용, Admin/User 모두 사용)
  Stream<List<SessionReservationSummary>> watchReservationSummaryByCourseAndDateRange({
    required String placeId,
    required String courseId,
    required DateTime startDate,
    required DateTime endDate,
  }) {
    final startDateString = _formatDate(startDate);
    final endDateString = _formatDate(endDate);
    return _firestore
        .collection('reservationSummary')
        .where('placeId', isEqualTo: placeId)
        .where('courseId', isEqualTo: courseId)
        .where('date', isGreaterThanOrEqualTo: startDateString)
        .where('date', isLessThanOrEqualTo: endDateString)
        .orderBy('date')
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            final d = doc.data();
            final id = doc.id;
            return SessionReservationSummary(
              id: id,
              sessionId: d['sessionId'] as String? ?? '',
              courseId: d['courseId'] as String? ?? courseId,
              placeId: d['placeId'] as String? ?? placeId,
              dayOfWeek: (d['dayOfWeek'] as num?)?.toInt() ?? 0,
              startTime: d['startTime'] as String? ?? '',
              date: d['date'] as String? ?? '',
              capacity: (d['capacity'] as num?)?.toInt() ?? 0,
              reservedCount: (d['reservedCount'] as num?)?.toInt() ?? 0,
              lastUpdated: DateTime.now(),
              createdAt: null,
            );
          }).toList();
        });
  }

  /// placeId, courseId, 날짜 범위로 reservations 실시간 구독 (예약자 목록 필요 시 on-demand)
  Stream<List<SessionReservation>> watchReservationsByCourseAndDateRange({
    required String placeId,
    required String courseId,
    required DateTime startDate,
    required DateTime endDate,
  }) {
    final startDateString = _formatDate(startDate);
    final endDateString = _formatDate(endDate);
    return _firestore
        .collection('reservations')
        .where('placeId', isEqualTo: placeId)
        .where('courseId', isEqualTo: courseId)
        .where('reservedDateString', isGreaterThanOrEqualTo: startDateString)
        .where('reservedDateString', isLessThanOrEqualTo: endDateString)
        .orderBy('reservedDateString')
        .snapshots()
        .map((s) => _mapReservationDocs(s.docs));
  }

  Future<SessionReservationSummary?> getSessionReservationSummary({
    required String courseId,
    required int dayOfWeek,
    required String startTime,
    required DateTime date,
  }) async {
    final sessionId =
        SessionReservationSummary.generateSessionId(courseId, dayOfWeek, startTime);
    final dateString = _formatDate(date);
    final snapshot = await _firestore
        .collection('reservations')
        .where('courseId', isEqualTo: courseId)
        .where('dayOfWeek', isEqualTo: dayOfWeek)
        .where('startTime', isEqualTo: startTime)
        .where('reservedDateString', isEqualTo: dateString)
        .get();
    final count = snapshot.docs.length;
    if (count == 0) return null;
    final first = snapshot.docs.first.data();
    final placeId = first['placeId'] as String? ?? '';
    return SessionReservationSummary(
      id: '${sessionId}_$dateString',
      sessionId: sessionId,
      courseId: courseId,
      placeId: placeId,
      dayOfWeek: dayOfWeek,
      startTime: startTime,
      date: dateString,
      capacity: 0,
      reservedCount: count,
      lastUpdated: DateTime.now(),
      createdAt: null,
    );
  }

  Stream<SessionReservationSummary?> watchSessionReservationSummary({
    required String courseId,
    required int dayOfWeek,
    required String startTime,
    required DateTime date,
  }) {
    final sessionId =
        SessionReservationSummary.generateSessionId(courseId, dayOfWeek, startTime);
    final dateString = _formatDate(date);
    return _firestore
        .collection('reservations')
        .where('courseId', isEqualTo: courseId)
        .where('dayOfWeek', isEqualTo: dayOfWeek)
        .where('startTime', isEqualTo: startTime)
        .where('reservedDateString', isEqualTo: dateString)
        .snapshots()
        .map((snapshot) {
          final count = snapshot.docs.length;
          if (count == 0) return null;
          final first = snapshot.docs.first.data();
          final placeId = first['placeId'] as String? ?? '';
          return SessionReservationSummary(
            id: '${sessionId}_$dateString',
            sessionId: sessionId,
            courseId: courseId,
            placeId: placeId,
            dayOfWeek: dayOfWeek,
            startTime: startTime,
            date: dateString,
            capacity: 0,
            reservedCount: count,
            lastUpdated: DateTime.now(),
            createdAt: null,
          );
        });
  }

  Stream<List<SessionReservationSummary>> watchCourseSessionReservations({
    required String courseId,
    String? placeId,
    required DateTime startDate,
    required DateTime endDate,
  }) {
    final startDateString = _formatDate(startDate);
    final endDateString = _formatDate(endDate);
    Query<Map<String, dynamic>> q = _firestore
        .collection('reservations')
        .where('courseId', isEqualTo: courseId)
        .where('reservedDateString', isGreaterThanOrEqualTo: startDateString)
        .where('reservedDateString', isLessThanOrEqualTo: endDateString)
        .orderBy('reservedDateString');
    if (placeId != null && placeId.isNotEmpty) {
      q = q.where('placeId', isEqualTo: placeId);
    }
    return q.snapshots().map((snapshot) {
      final byKey = <String, List<Map<String, dynamic>>>{};
      for (final doc in snapshot.docs) {
        final d = doc.data();
        final key = '${d['courseId']}_${d['dayOfWeek']}_${d['startTime']}_${d['reservedDateString']}';
        byKey.putIfAbsent(key, () => []).add({...d, 'placeId': d['placeId'] ?? ''});
      }
      return byKey.entries.map((e) {
        final list = e.value;
        final first = list.first;
        return SessionReservationSummary(
          id: e.key,
          sessionId: SessionReservationSummary.generateSessionId(
            first['courseId'] as String,
            first['dayOfWeek'] as int,
            first['startTime'] as String,
          ),
          courseId: first['courseId'] as String,
          placeId: first['placeId'] as String? ?? '',
          dayOfWeek: first['dayOfWeek'] as int,
          startTime: first['startTime'] as String,
          date: first['reservedDateString'] as String,
          capacity: 0,
          reservedCount: list.length,
          lastUpdated: DateTime.now(),
          createdAt: null,
        );
      }).toList();
    });
  }

  Stream<Set<String>> watchReservedSessionIdsForCourse(
    String placeId,
    String courseId, {
    DateTime? startDate,
  }) {
    final sd = startDate ?? TimezoneUtils.getSeoulToday();
    final startDateString = _formatDate(sd);
    return _firestore
        .collection('reservations')
        .where('placeId', isEqualTo: placeId)
        .where('courseId', isEqualTo: courseId)
        .where('reservedDateString', isGreaterThanOrEqualTo: startDateString)
        .snapshots()
        .map((snapshot) {
          final ids = <String>{};
          for (final doc in snapshot.docs) {
            final data = doc.data();
            final sessionId = SessionReservationSummary.generateSessionId(
              data['courseId'] as String? ?? '',
              (data['dayOfWeek'] as num?)?.toInt() ?? 0,
              data['startTime'] as String? ?? '',
            );
            if (sessionId.isNotEmpty) ids.add(sessionId);
          }
          return ids;
        });
  }

  Future<DateTime?> findFirstReservedDateForSession(String sessionId) async {
    final parts = sessionId.split('_');
    if (parts.length < 3) return null;
    final startTime = parts.last;
    final dayOfWeek = int.tryParse(parts[parts.length - 2]) ?? 0;
    final courseId = parts.sublist(0, parts.length - 2).join('_');
    final snapshot = await _firestore
        .collection('reservations')
        .where('courseId', isEqualTo: courseId)
        .where('dayOfWeek', isEqualTo: dayOfWeek)
        .where('startTime', isEqualTo: startTime)
        .orderBy('reservedDateString')
        .limit(1)
        .get();
    if (snapshot.docs.isEmpty) return null;
    final dateString = snapshot.docs.first.data()['reservedDateString'] as String?;
    if (dateString == null || dateString.isEmpty) return null;
    return DateTime.tryParse(dateString);
  }

  Future<Map<String, dynamic>> batchMoveReservations({
    required List<String> reservationIds,
    required String placeId,
    required int newDayOfWeek,
    required String newStartTime,
    required DateTime newReservedDate,
  }) async {
    final result = await FirebaseFunctions.instance
        .httpsCallable('batchMoveReservations')
        .call({
      'reservationIds': reservationIds,
      'placeId': placeId,
      'newDayOfWeek': newDayOfWeek,
      'newStartTime': newStartTime,
      'newReservedDateString': _formatDate(newReservedDate),
    });
    return result.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> batchCancelReservations({
    required List<String> reservationIds,
    required String placeId,
    bool asAdminAction = false,
  }) async {
    final result = await FirebaseFunctions.instance
        .httpsCallable('batchCancelReservations')
        .call({
      'reservationIds': reservationIds,
      'placeId': placeId,
      if (asAdminAction) 'asAdminAction': true,
    });
    return result.data as Map<String, dynamic>;
  }

  /// 예약 생성 (실패 시 null 반환, 로그만)
  Future<SessionReservation?> createReservationSafe(
    SessionReservation reservation, {
    bool force = false,
  }) async {
    try {
      return await createReservation(reservation, force: force);
    } catch (e) {
      if (kDebugMode) debugPrint('[ReservationService] createReservation: $e');
      return null;
    }
  }

  /// 예약 삭제 (성공 여부 반환)
  Future<bool> deleteReservationSafe({
    required String reservationId,
    required String placeId,
  }) async {
    try {
      await deleteReservation(reservationId: reservationId, placeId: placeId);
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('[ReservationService] deleteReservation: $e');
      return false;
    }
  }

  /// 예약 이동 (성공 여부 반환)
  Future<bool> moveReservationWithinCourseSafe({
    required String reservationId,
    required String placeId,
    required int newDayOfWeek,
    required String newStartTime,
    required DateTime newReservedDate,
  }) async {
    try {
      await moveReservationWithinCourse(
        reservationId: reservationId,
        placeId: placeId,
        newDayOfWeek: newDayOfWeek,
        newStartTime: newStartTime,
        newReservedDate: newReservedDate,
      );
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('[ReservationService] moveReservation: $e');
      return false;
    }
  }

  void dispose() {
    _reservationUpdateController.close();
    _sessionUpdateController.close();
    _courseUpdateController.close();
    _placeUpdateController.close();
  }
}

// ==================== 업데이트 모델 ====================

enum UpdateType { partial, refresh, full, added, removed }

class SessionReservationUpdate {
  final SessionReservation? reservation;
  final String? reservationId;
  final UpdateType type;
  SessionReservationUpdate({
    this.reservation,
    this.reservationId,
    required this.type,
  });
}

class SessionUpdate {
  final String courseId;
  final int dayOfWeek;
  final String startTime;
  final CourseSession session;
  final UpdateType type;
  SessionUpdate({
    required this.courseId,
    required this.dayOfWeek,
    required this.startTime,
    required this.session,
    required this.type,
  });
}

class CourseUpdate {
  final String courseId;
  final Course course;
  final UpdateType type;
  CourseUpdate({
    required this.courseId,
    required this.course,
    required this.type,
  });
}

class PlaceUpdate {
  final Place place;
  final UpdateType type;
  PlaceUpdate({required this.place, required this.type});
}
