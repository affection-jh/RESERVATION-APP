import 'dart:async';
import 'package:flutter/material.dart';
import '../models/reservation.dart';
import '../models/course.dart';
import '../models/place.dart';
import 'firestore_service.dart';

/// 예약 관련 Firebase 작업 및 실시간 구독을 관리하는 서비스
class ReservationService {
  // 싱글톤 패턴
  static final ReservationService _instance = ReservationService._internal();
  factory ReservationService() => _instance;
  ReservationService._internal();

  final FirestoreService _firestoreService = FirestoreService();

  // 예약 변경을 알리는 Stream Controllers
  final _reservationUpdateController =
      StreamController<ReservationUpdate>.broadcast();
  final _sessionUpdateController = StreamController<SessionUpdate>.broadcast();
  final _courseUpdateController = StreamController<CourseUpdate>.broadcast();
  final _placeUpdateController = StreamController<PlaceUpdate>.broadcast();

  // 현재 Place 상태 (실제로는 서버나 상태 관리에서 가져옴)
  Place? _currentPlace;

  /// Place 설정
  void setPlace(Place place) {
    _currentPlace = place;
    _notifyPlaceUpdate(PlaceUpdate(place: place, type: UpdateType.full));
  }

  /// Place 가져오기
  Place? get currentPlace => _currentPlace;

  // ==================== Stream 구독 메서드 ====================

  /// 모든 예약 변경 구독
  Stream<ReservationUpdate> watchReservations() {
    return _reservationUpdateController.stream;
  }

  /// 특정 세션의 예약 변경 구독
  Stream<SessionUpdate> watchSession(
    String courseId,
    int dayOfWeek,
    String startTime,
  ) {
    return _sessionUpdateController.stream.where(
      (update) =>
          update.courseId == courseId &&
          update.dayOfWeek == dayOfWeek &&
          update.startTime == startTime,
    );
  }

  /// 특정 코스의 예약 변경 구독
  Stream<CourseUpdate> watchCourse(String courseId) {
    return _courseUpdateController.stream.where(
      (update) => update.courseId == courseId,
    );
  }

  /// Place 전체 변경 구독
  Stream<PlaceUpdate> watchPlace() {
    return _placeUpdateController.stream;
  }

  // ==================== 가벼운 갱신 메서드 ====================

  /// 예약 추가 (가벼운 갱신)
  Future<void> addReservation(Reservation reservation) async {
    if (_currentPlace == null) return;

    final course = _currentPlace!.findCourse(reservation.courseId);
    if (course == null) return;

    final session = course.findSession(
      reservation.dayOfWeek,
      reservation.startTime,
    );
    if (session == null) return;

    // 예약 추가
    final updatedSession = session.addReservation(reservation);
    final updatedCourse = _updateCourseSession(course, updatedSession);
    final updatedPlace = _updatePlaceCourse(updatedCourse);

    _currentPlace = updatedPlace;

    // 가벼운 갱신 알림 (특정 세션만)
    _notifySessionUpdate(
      SessionUpdate(
        courseId: reservation.courseId,
        dayOfWeek: reservation.dayOfWeek,
        startTime: reservation.startTime,
        session: updatedSession,
        type: UpdateType.partial,
      ),
    );

    // 예약 변경 알림
    _notifyReservationUpdate(
      ReservationUpdate(reservation: reservation, type: UpdateType.added),
    );
  }

  /// 예약 삭제 (가벼운 갱신)
  Future<void> removeReservation(
    String reservationId,
    String courseId,
    int dayOfWeek,
    String startTime,
  ) async {
    if (_currentPlace == null) return;

    final course = _currentPlace!.findCourse(courseId);
    if (course == null) return;

    final session = course.findSession(dayOfWeek, startTime);
    if (session == null) return;

    // 예약 삭제
    final updatedSession = session.removeReservation(reservationId);
    final updatedCourse = _updateCourseSession(course, updatedSession);
    final updatedPlace = _updatePlaceCourse(updatedCourse);

    _currentPlace = updatedPlace;

    // 가벼운 갱신 알림 (특정 세션만)
    _notifySessionUpdate(
      SessionUpdate(
        courseId: courseId,
        dayOfWeek: dayOfWeek,
        startTime: startTime,
        session: updatedSession,
        type: UpdateType.partial,
      ),
    );

    // 예약 변경 알림
    _notifyReservationUpdate(
      ReservationUpdate(reservationId: reservationId, type: UpdateType.removed),
    );
  }

  /// 특정 세션의 예약 현황만 갱신 (가벼운 갱신)
  Future<void> refreshSession(
    String courseId,
    int dayOfWeek,
    String startTime,
  ) async {
    if (_currentPlace == null) return;

    final course = _currentPlace!.findCourse(courseId);
    if (course == null) return;

    final session = course.findSession(dayOfWeek, startTime);
    if (session == null) return;

    // 세션 갱신 알림
    _notifySessionUpdate(
      SessionUpdate(
        courseId: courseId,
        dayOfWeek: dayOfWeek,
        startTime: startTime,
        session: session,
        type: UpdateType.refresh,
      ),
    );
  }

  /// 특정 코스의 모든 세션 갱신
  Future<void> refreshCourse(String courseId) async {
    if (_currentPlace == null) return;

    final course = _currentPlace!.findCourse(courseId);
    if (course == null) return;

    // 코스 갱신 알림
    _notifyCourseUpdate(
      CourseUpdate(
        courseId: courseId,
        course: course,
        type: UpdateType.refresh,
      ),
    );
  }

  /// 특정 날짜의 예약 현황 갱신 (가벼운 갱신)
  Future<void> refreshDate(DateTime date) async {
    if (_currentPlace == null) return;

    // 해당 날짜에 예약이 있는 모든 세션 찾기
    final affectedSessions = <SessionUpdate>[];

    for (final course in _currentPlace!.courses) {
      for (final session in course.sessions) {
        final hasReservationForDate = session.reservations.any((reservation) {
          final resDate = DateTime(
            reservation.reservedDate.year,
            reservation.reservedDate.month,
            reservation.reservedDate.day,
          );
          final targetDate = DateTime(date.year, date.month, date.day);
          return resDate == targetDate;
        });

        if (hasReservationForDate) {
          affectedSessions.add(
            SessionUpdate(
              courseId: course.id,
              dayOfWeek: session.dayOfWeek,
              startTime: session.startTime,
              session: session,
              type: UpdateType.refresh,
            ),
          );
        }
      }
    }

    // 각 세션 갱신 알림
    for (final update in affectedSessions) {
      _notifySessionUpdate(update);
    }
  }

  /// 전체 Place 갱신 (무거운 갱신 - 필요시에만 사용)
  Future<void> refreshPlace() async {
    if (_currentPlace == null) return;

    _notifyPlaceUpdate(
      PlaceUpdate(place: _currentPlace!, type: UpdateType.full),
    );
  }

  // ==================== 내부 헬퍼 메서드 ====================

  Course _updateCourseSession(Course course, CourseSession updatedSession) {
    final updatedSessions = course.sessions.map((session) {
      if (session.dayOfWeek == updatedSession.dayOfWeek &&
          session.startTime == updatedSession.startTime) {
        return updatedSession;
      }
      return session;
    }).toList();

    return Course(
      description: course.description,
      id: course.id,
      name: course.name,
      color: course.color,
      sessions: updatedSessions,
    );
  }

  Place _updatePlaceCourse(Course updatedCourse) {
    final updatedCourses = _currentPlace!.courses.map((course) {
      if (course.id == updatedCourse.id) {
        return updatedCourse;
      }
      return course;
    }).toList();

    return _currentPlace!.copyWith(courses: updatedCourses);
  }

  void _notifyReservationUpdate(ReservationUpdate update) {
    if (!_reservationUpdateController.isClosed) {
      _reservationUpdateController.add(update);
    }
  }

  void _notifySessionUpdate(SessionUpdate update) {
    if (!_sessionUpdateController.isClosed) {
      _sessionUpdateController.add(update);
    }
  }

  void _notifyCourseUpdate(CourseUpdate update) {
    if (!_courseUpdateController.isClosed) {
      _courseUpdateController.add(update);
    }
  }

  void _notifyPlaceUpdate(PlaceUpdate update) {
    if (!_placeUpdateController.isClosed) {
      _placeUpdateController.add(update);
    }
  }

  // ==================== Firebase CRUD 작업 ====================

  /// 예약 생성
  ///
  /// [reservation] 생성할 예약 객체 (id가 없으면 자동 생성)
  ///
  /// Returns: 생성된 예약 또는 null
  Future<Reservation?> createReservation(Reservation reservation) async {
    try {
      debugPrint('🔥 [ReservationService] 예약 생성 시작');
      debugPrint('🔥 [ReservationService] userId: ${reservation.userId}');
      debugPrint('🔥 [ReservationService] courseId: ${reservation.courseId}');
      debugPrint('🔥 [ReservationService] placeId: ${reservation.placeId}');
      debugPrint('🔥 [ReservationService] dayOfWeek: ${reservation.dayOfWeek}');
      debugPrint('🔥 [ReservationService] startTime: ${reservation.startTime}');
      debugPrint(
        '🔥 [ReservationService] reservedDate: ${reservation.reservedDate}',
      );

      final createdReservation = await _firestoreService.createReservation(
        reservation,
      );

      debugPrint('✅ [ReservationService] 예약 생성 완료: ${createdReservation.id}');
      return createdReservation;
    } catch (e) {
      debugPrint('❌ [ReservationService] 예약 생성 실패: $e');
      return null;
    }
  }

  /// 예약 삭제 (취소)
  ///
  /// [reservationId] 삭제할 예약 ID
  /// [placeId] 플레이스 ID
  ///
  /// Returns: 삭제 성공 여부
  Future<bool> deleteReservation({
    required String reservationId,
    required String placeId,
  }) async {
    try {
      debugPrint('🔥 [ReservationService] 예약 삭제 시작');
      debugPrint('🔥 [ReservationService] reservationId: $reservationId');
      debugPrint('🔥 [ReservationService] placeId: $placeId');

      await _firestoreService.deleteReservation(
        reservationId: reservationId,
        placeId: placeId,
      );

      debugPrint('✅ [ReservationService] 예약 삭제 완료: $reservationId');
      return true;
    } catch (e) {
      debugPrint('❌ [ReservationService] 예약 삭제 실패: $e');
      return false;
    }
  }

  /// 예약 이동 (같은 코스 내에서만)
  ///
  /// [reservationId] 이동할 예약 ID
  /// [placeId] 플레이스 ID
  /// [newDayOfWeek] 새로운 요일
  /// [newStartTime] 새로운 시작 시간
  /// [newReservedDate] 새로운 예약 날짜
  ///
  /// Returns: 이동 성공 여부
  Future<bool> moveReservationWithinCourse({
    required String reservationId,
    required String placeId,
    required int newDayOfWeek,
    required String newStartTime,
    required DateTime newReservedDate,
  }) async {
    try {
      debugPrint('🔥 [ReservationService] 예약 이동 시작');
      debugPrint('🔥 [ReservationService] reservationId: $reservationId');
      debugPrint('🔥 [ReservationService] placeId: $placeId');
      debugPrint('🔥 [ReservationService] newDayOfWeek: $newDayOfWeek');
      debugPrint('🔥 [ReservationService] newStartTime: $newStartTime');
      debugPrint('🔥 [ReservationService] newReservedDate: $newReservedDate');

      await _firestoreService.moveReservationWithinCourse(
        reservationId: reservationId,
        placeId: placeId,
        newDayOfWeek: newDayOfWeek,
        newStartTime: newStartTime,
        newReservedDate: newReservedDate,
      );

      debugPrint('✅ [ReservationService] 예약 이동 완료: $reservationId');
      return true;
    } catch (e) {
      debugPrint('❌ [ReservationService] 예약 이동 실패: $e');
      return false;
    }
  }

  /// 리소스 정리
  void dispose() {
    _reservationUpdateController.close();
    _sessionUpdateController.close();
    _courseUpdateController.close();
    _placeUpdateController.close();
  }
}

// ==================== 업데이트 모델 ====================

enum UpdateType {
  partial, // 부분 갱신 (가벼움)
  refresh, // 새로고침
  full, // 전체 갱신 (무거움)
  added, // 추가됨
  removed, // 삭제됨
}

/// 예약 변경 알림
class ReservationUpdate {
  final Reservation? reservation;
  final String? reservationId;
  final UpdateType type;

  ReservationUpdate({this.reservation, this.reservationId, required this.type});
}

/// 세션 변경 알림
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

/// 코스 변경 알림
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

/// Place 변경 알림
class PlaceUpdate {
  final Place place;
  final UpdateType type;

  PlaceUpdate({required this.place, required this.type});
}
