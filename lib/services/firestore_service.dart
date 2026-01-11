import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import '../models/place.dart';
import '../models/reservation.dart';
import '../models/session_reservation.dart';
import '../models/date_capacity_override.dart';
import '../models/course.dart';
import '../models/notification.dart';
import '../providers/story_provider.dart';
import '../providers/promotion_provider.dart';
import '../policies/course_policy.dart';
import '../utils/timezone_utils.dart';
import 'enrollment_service.dart';
import 'member_service.dart';

/// Firestore 데이터베이스 서비스
///
/// 모든 Firestore 작업을 중앙에서 관리하는 서비스 클래스
class FirestoreService {
  static final FirestoreService _instance = FirestoreService._internal();
  factory FirestoreService() => _instance;
  FirestoreService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Firestore 인스턴스 접근 (다른 서비스에서 사용)
  FirebaseFirestore get firestore => _firestore;

  // ==================== Helper Methods ====================

  /// 날짜를 "YYYY-MM-DD" 형식 문자열로 변환
  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  /// Timestamp를 DateTime으로 변환 (public)
  DateTime timestampToDateTime(dynamic timestamp) {
    return _timestampToDateTime(timestamp);
  }

  /// Timestamp를 DateTime으로 변환 (private)
  /// ⚠️ 서버 시간이 없으면 서울 시간대 현재 시간 반환 (서버 없으면 클라이언트 시간 사용)
  DateTime _timestampToDateTime(dynamic timestamp) {
    if (timestamp == null) {
      // 서버 시간이 없으면 서울 시간대 현재 시간 반환
      return TimezoneUtils.getSeoulDateTime();
    }
    if (timestamp is Timestamp) {
      return timestamp.toDate();
    }
    if (timestamp is String) {
      return DateTime.parse(timestamp);
    }
    throw Exception('Invalid timestamp format');
  }

  /// DateTime을 Timestamp로 변환 (public)
  Timestamp dateTimeToTimestamp(DateTime dateTime) {
    return _dateTimeToTimestamp(dateTime);
  }

  /// DateTime을 Timestamp로 변환 (private)
  Timestamp _dateTimeToTimestamp(DateTime dateTime) {
    return Timestamp.fromDate(dateTime);
  }

  // ==================== Places ====================

  /// 플레이스 생성
  Future<Place> createPlace(Place place) async {
    final docRef = _firestore.collection('places').doc(place.id);
    await docRef.set(place.toJson());
    return place;
  }

  /// 플레이스 조회
  Future<Place?> getPlace(String placeId) async {
    try {
      final doc = await _firestore.collection('places').doc(placeId).get();
      if (!doc.exists) {
        debugPrint('[FirestoreService.getPlace] 플레이스 문서가 존재하지 않습니다: $placeId');
        return null;
      }
      final data = doc.data()!;
      debugPrint('[FirestoreService.getPlace] 플레이스 데이터 로드 성공: $placeId');
      return Place.fromJson(data);
    } catch (e, stackTrace) {
      debugPrint('[FirestoreService.getPlace] 플레이스 로드 실패: $placeId');
      debugPrint('[FirestoreService.getPlace] 에러: $e');
      debugPrint('[FirestoreService.getPlace] 스택 트레이스: $stackTrace');
      rethrow;
    }
  }

  /// 특정 관리자(adminId)가 관리하는 플레이스 ID 목록 조회
  ///
  /// Place 문서의 `adminId` 필드를 기준으로 조회합니다.
  Future<List<String>> getManagedPlaceIdsByAdminId(String adminId) async {
    final snapshot = await _firestore
        .collection('places')
        .where('adminId', isEqualTo: adminId)
        .get();
    return snapshot.docs.map((d) => d.id).toList();
  }

  /// 플레이스 실시간 구독
  Stream<Place?> watchPlace(String placeId) {
    return _firestore.collection('places').doc(placeId).snapshots().map((
      snapshot,
    ) {
      if (!snapshot.exists) return null;
      return Place.fromJson(snapshot.data()!);
    });
  }

  /// 플레이스 업데이트
  Future<Place> updatePlace(Place place) async {
    final docRef = _firestore.collection('places').doc(place.id);
    await docRef.update(place.toJson());
    return place;
  }

  /// 플레이스 삭제 (서버 중앙화)
  ///
  /// Cloud Function을 통해 플레이스 삭제를 수행합니다.
  /// 서버에서 활성 예약 확인 및 관련 데이터 정리를 안전하게 처리합니다.
  Future<void> deletePlace(String placeId) async {
    final callable = FirebaseFunctions.instance.httpsCallable('deletePlace');
    try {
      await callable.call({'placeId': placeId});
      debugPrint('✅ [FirestoreService] 플레이스 삭제 완료: $placeId');
    } on FirebaseFunctionsException catch (e) {
      // 서버 에러를 그대로 전달
      throw Exception(e.message ?? '플레이스 삭제 중 오류가 발생했습니다.');
    }
  }

  // ==================== Courses ====================

  /// 플레이스의 코스 목록 조회
  Future<List<Course>> getCoursesByPlace(String placeId) async {
    final placeDoc = await _firestore.collection('places').doc(placeId).get();
    if (!placeDoc.exists) {
      throw Exception('플레이스를 찾을 수 없습니다.');
    }

    final placeData = placeDoc.data()!;
    final coursesData = placeData['courses'] as List?;
    if (coursesData == null) {
      return [];
    }

    return coursesData
        .map((c) => Course.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  /// 플레이스의 코스 목록 실시간 구독
  Stream<List<Course>> watchCoursesByPlace(String placeId) {
    return _firestore.collection('places').doc(placeId).snapshots().map((
      snapshot,
    ) {
      if (!snapshot.exists) {
        return <Course>[];
      }

      final placeData = snapshot.data()!;
      final coursesData = placeData['courses'] as List?;
      if (coursesData == null) {
        return <Course>[];
      }

      return coursesData
          .map((c) => Course.fromJson(c as Map<String, dynamic>))
          .toList();
    });
  }

  /// 코스 생성
  Future<Course> createCourse(String placeId, Course course) async {
    final placeRef = _firestore.collection('places').doc(placeId);

    return await _firestore.runTransaction((transaction) async {
      final placeDoc = await transaction.get(placeRef);
      if (!placeDoc.exists) {
        throw Exception('플레이스를 찾을 수 없습니다.');
      }

      final placeData = placeDoc.data()!;
      final coursesData = (placeData['courses'] as List?) ?? [];

      // 새 코스 추가
      final updatedCourses = [...coursesData, course.toJson()];

      transaction.update(placeRef, {'courses': updatedCourses});
      return course;
    });
  }

  /// 코스 업데이트
  Future<Course> updateCourse(String placeId, Course course) async {
    final placeRef = _firestore.collection('places').doc(placeId);

    return await _firestore.runTransaction((transaction) async {
      final placeDoc = await transaction.get(placeRef);
      if (!placeDoc.exists) {
        throw Exception('플레이스를 찾을 수 없습니다.');
      }

      final placeData = placeDoc.data()!;
      final coursesData = (placeData['courses'] as List?) ?? [];

      // 코스 찾아서 업데이트
      bool courseFound = false;
      final updatedCourses = coursesData.map((c) {
        final courseData = c as Map<String, dynamic>;
        if (courseData['id'] == course.id) {
          courseFound = true;
          return course.toJson();
        }
        return c;
      }).toList();

      // 코스를 찾지 못한 경우 에러 발생
      if (!courseFound) {
        throw Exception('코스를 찾을 수 없습니다.');
      }

      transaction.update(placeRef, {'courses': updatedCourses});
      return course;
    });
  }

  /// 코스 일정(세션 템플릿) 업데이트 (관리자, 중앙 검증)
  ///
  /// 서버에서 "예약이 있는 세션은 삭제/변경 불가" 등을 강제합니다.
  Future<void> updateCourseSchedule({
    required String placeId,
    required String courseId,
    required List<CourseSession> sessions,
  }) async {
    final callable = FirebaseFunctions.instance.httpsCallable(
      'updateCourseSchedule',
    );
    await callable.call({
      'placeId': placeId,
      'courseId': courseId,
      'sessions': sessions
          .map(
            (s) => {
              'dayOfWeek': s.dayOfWeek,
              'startTime': s.startTime,
              'endTime': s.endTime,
              'capacity': s.capacity,
            },
          )
          .toList(),
    });
  }

  /// 코스 삭제
  ///
  /// 코스 삭제 시 해당 코스의 모든 enrollments도 함께 삭제됩니다.
  /// 이는 사용자 혼란 방지와 데이터 일관성을 위한 것입니다.
  Future<void> deleteCourse(String placeId, String courseId) async {
    final placeRef = _firestore.collection('places').doc(placeId);

    // 0. 활성 예약 확인 (미래 날짜 예약이 있는지 확인)
    final todayString = TimezoneUtils.formatDateToSeoul(
      TimezoneUtils.getSeoulDateTime(),
    );
    final activeReservationsQuery = _firestore
        .collection('places')
        .doc(placeId)
        .collection('reservations')
        .where('courseId', isEqualTo: courseId)
        .where('reservedDateString', isGreaterThanOrEqualTo: todayString)
        .limit(1);

    final activeReservationsSnapshot = await activeReservationsQuery.get();
    if (activeReservationsSnapshot.docs.isNotEmpty) {
      throw Exception('활성 예약이 있는 코스는 삭제할 수 없습니다. 먼저 예약을 취소해주세요.');
    }

    // 1. 코스 삭제
    await _firestore.runTransaction((transaction) async {
      final placeDoc = await transaction.get(placeRef);
      if (!placeDoc.exists) {
        throw Exception('플레이스를 찾을 수 없습니다.');
      }

      final placeData = placeDoc.data()!;
      final coursesData = (placeData['courses'] as List?) ?? [];

      // 코스 제거
      final updatedCourses = coursesData.where((c) {
        final courseData = c as Map<String, dynamic>;
        return courseData['id'] != courseId;
      }).toList();

      transaction.update(placeRef, {'courses': updatedCourses});
    });

    // 2. 해당 코스의 모든 enrollments 삭제 (enrollments 컬렉션)
    // 페이지네이션을 사용하여 메모리 효율적으로 처리
    // 10,000명 이상의 대규모 데이터도 안전하게 처리 가능
    final enrollmentService = EnrollmentService();
    await enrollmentService.deleteEnrollmentsByCourse(placeId, courseId);

    // 3. pendingMembers에서 해당 코스 제거
    // 모든 pendingMembers의 courseIds와 courseEnrollments에서 해당 courseId 제거
    final memberService = MemberService();
    await memberService.removeCourseFromAllPendingMembers(
      placeId: placeId,
      courseId: courseId,
    );
  }

  // ==================== Reservations ====================

  // ==================== Course Policies ====================

  /// 코스별 예약/운영 정책 조회 (없으면 기본 정책 반환)
  ///
  /// 정책 문서 경로: coursePolicies/{courseId}
  Future<CoursePolicy> getCoursePolicy({
    required String courseId,
    required String placeId,
  }) async {
    final docRef = _firestore.collection('coursePolicies').doc(courseId);
    final doc = await docRef.get();
    if (!doc.exists) {
      return CoursePolicy.defaultFor(courseId: courseId, placeId: placeId);
    }
    final data = doc.data() as Map<String, dynamic>;

    // 신규 스키마: { active: {...}, scheduled: {...}? }
    // - active: 현재 적용중
    // - scheduled: 미래 적용 예정 (effectiveFrom 기준)
    if (data['active'] is Map<String, dynamic> ||
        data['scheduled'] is Map<String, dynamic>) {
      // 서버와 일관성을 위해 서울 시간대 사용
      final seoulNow = TimezoneUtils.getSeoulDateTime();
      final activeRaw = data['active'];
      final scheduledRaw = data['scheduled'];

      CoursePolicy? active;
      CoursePolicy? scheduled;
      if (activeRaw is Map<String, dynamic>) {
        active = CoursePolicy.fromJson(activeRaw);
      }
      if (scheduledRaw is Map<String, dynamic>) {
        scheduled = CoursePolicy.fromJson(scheduledRaw);
      }

      // effectiveFrom <= seoulNow 인 후보들 중 가장 최신(effectiveFrom) 선택
      final candidates = <CoursePolicy>[];
      if (active != null && !active.effectiveFrom.isAfter(seoulNow)) {
        candidates.add(active);
      }
      if (scheduled != null && !scheduled.effectiveFrom.isAfter(seoulNow)) {
        candidates.add(scheduled);
      }

      if (candidates.isNotEmpty) {
        candidates.sort((a, b) => a.effectiveFrom.compareTo(b.effectiveFrom));
        return candidates.last;
      }

      // 아직 scheduled가 적용 전이면 active(있으면) 또는 default 사용
      if (active != null) return active;
      return CoursePolicy.defaultFor(courseId: courseId, placeId: placeId);
    }

    // 구버전(레거시): 문서 자체가 policy
    return CoursePolicy.fromJson(data);
  }

  /// 코스별 예약/운영 정책 저장/업데이트
  Future<void> upsertCoursePolicy(CoursePolicy policy) async {
    final docRef = _firestore.collection('coursePolicies').doc(policy.courseId);
    // 서버와 일관성을 위해 서울 시간대 사용
    final now = TimezoneUtils.getSeoulDateTime();
    final isFuture = policy.effectiveFrom.isAfter(now);

    // 기존 문서 확인 (권한 검사 및 디버깅용)
    final existingDoc = await docRef.get();
    assert(() {
      debugPrint('[FirestoreService] upsertCoursePolicy');
      debugPrint('  courseId=${policy.courseId}');
      debugPrint('  placeId=${policy.placeId}');
      debugPrint('  isFuture=$isFuture');
      if (existingDoc.exists) {
        final existingData = existingDoc.data();
        debugPrint('  기존 문서 존재: true');
        debugPrint('  기존 문서 구조: ${existingData?.keys.toList()}');
        debugPrint('  기존 문서 placeId (최상위): ${existingData?['placeId']}');
        debugPrint('  기존 문서 active: ${existingData?['active'] != null}');
        debugPrint('  기존 문서 scheduled: ${existingData?['scheduled'] != null}');
      } else {
        debugPrint('  기존 문서 존재: false (새로 생성)');
      }
      return true;
    }());

    // 정책 저장 로직:
    // - 즉시 적용 (isFuture = false): active로 저장, 기존 scheduled는 유지 (미래 적용 예정이면 그대로 둠)
    // - 미래 적용 (isFuture = true): scheduled로 저장, 기존 active는 유지 (현재 적용 중이면 그대로 둠)
    //
    // ⚠️ 주의: merge: true를 사용하므로 기존 필드는 유지됨
    // - 즉시 적용 시: active만 업데이트, scheduled는 그대로 (미래 적용 예정이면 유지)
    // - 미래 적용 시: scheduled만 업데이트, active는 그대로 (현재 적용 중이면 유지)
    final dataToSave = isFuture
        ? {'placeId': policy.placeId, 'scheduled': policy.toJson()}
        : {'placeId': policy.placeId, 'active': policy.toJson()};

    assert(() {
      debugPrint('  저장할 데이터: $dataToSave');
      return true;
    }());

    await docRef.set(dataToSave, SetOptions(merge: true));
  }

  /// 코스에 예약이 존재하는지(= sessionReservations reservedCount > 0이 하나라도 있는지) 확인
  Future<bool> hasAnyReservationsForCourse(String courseId) async {
    final snapshot = await _firestore
        .collection('sessionReservations')
        .where('courseId', isEqualTo: courseId)
        .where('reservedCount', isGreaterThan: 0)
        .limit(1)
        .get();
    return snapshot.docs.isNotEmpty;
  }

  /// 예약 생성 (트랜잭션 사용)
  ///
  /// [reservation.userId]가 현재 로그인한 사용자와 다를 수 있음 (관리자가 다른 사용자를 위해 예약 생성)
  Future<Reservation> createReservation(
    Reservation reservation, {
    bool force = false,
  }) async {
    debugPrint('[FirestoreService] createReservation 시작');
    debugPrint('[FirestoreService] reservation.userId: ${reservation.userId}');
    debugPrint(
      '[FirestoreService] reservation.courseId: ${reservation.courseId}',
    );
    debugPrint(
      '[FirestoreService] reservation.placeId: ${reservation.placeId}',
    );
    debugPrint(
      '[FirestoreService] reservation.dayOfWeek: ${reservation.dayOfWeek}',
    );
    debugPrint(
      '[FirestoreService] reservation.startTime: ${reservation.startTime}',
    );
    debugPrint(
      '[FirestoreService] reservation.reservedDate: ${reservation.reservedDate}',
    );
    debugPrint('[FirestoreService] force: $force');

    final dateString = _formatDate(reservation.reservedDate);
    debugPrint('[FirestoreService] formatted dateString: $dateString');

    final callable = FirebaseFunctions.instance.httpsCallable(
      'createReservation',
    );

    final requestData = {
      'placeId': reservation.placeId,
      'courseId': reservation.courseId,
      'dayOfWeek': reservation.dayOfWeek,
      'startTime': reservation.startTime,
      'reservedDateString': dateString,
      // 관리자가 다른 사용자를 위해 예약 생성 시 userId 전달
      'userId': reservation.userId,
      // 관리자 강제 추가(정원/오픈 전/마감 전 등) - 명시적 확인을 거친 경우에만 true
      'force': force,
    };
    debugPrint('[FirestoreService] Cloud Function 호출 데이터: $requestData');

    try {
      debugPrint('[FirestoreService] Cloud Function 호출 시작');
      final result = await callable.call(requestData);
      debugPrint('[FirestoreService] Cloud Function 응답 수신');
      debugPrint('[FirestoreService] 응답 데이터 타입: ${result.data.runtimeType}');
      debugPrint('[FirestoreService] 응답 데이터: ${result.data}');

      final data = result.data as Map<dynamic, dynamic>;
      final id = (data['id'] as String?) ?? '';
      debugPrint('[FirestoreService] 추출된 예약 ID: $id');

      if (id.isEmpty) {
        debugPrint('[FirestoreService] 예약 ID가 비어있습니다. 서버 응답: $data');
        throw Exception('예약 생성에 실패했습니다. (서버 응답 오류)');
      }

      debugPrint('[ReservationProvider] 예약 생성 성공: $id');
      return reservation.copyWith(id: id);
    } catch (e, stackTrace) {
      debugPrint('[FirestoreService] Cloud Function 호출 실패');
      debugPrint('[FirestoreService] 에러 타입: ${e.runtimeType}');
      debugPrint('[FirestoreService] 에러 메시지: $e');
      debugPrint('[FirestoreService] 스택 트레이스: $stackTrace');

      // Firebase Functions 에러의 경우 상세 정보 추출
      if (e is Exception) {
        final errorString = e.toString();
        debugPrint('[FirestoreService] Exception 문자열: $errorString');
      }

      rethrow;
    }
  }

  /// 예약 삭제 (트랜잭션 사용)
  Future<void> deleteReservation({
    required String reservationId,
    required String placeId,
  }) async {
    debugPrint('[FirestoreService] deleteReservation 시작');
    debugPrint('[FirestoreService] reservationId: $reservationId');
    debugPrint('[FirestoreService] placeId: $placeId');
    final callable = FirebaseFunctions.instance.httpsCallable(
      'cancelReservation',
    );
    try {
      debugPrint('[FirestoreService] Cloud Function(cancelReservation) 호출 시작');
      final result = await callable.call({
        'reservationId': reservationId,
        'placeId': placeId,
      });
      debugPrint('[FirestoreService] Cloud Function(cancelReservation) 응답 수신');
      debugPrint('[FirestoreService] 응답 데이터 타입: ${result.data.runtimeType}');
      debugPrint('[FirestoreService] 응답 데이터: ${result.data}');
      debugPrint('[FirestoreService] deleteReservation 완료');
    } catch (e, stackTrace) {
      debugPrint('[FirestoreService] deleteReservation 실패');
      debugPrint('[FirestoreService] 에러 타입: ${e.runtimeType}');
      debugPrint('[FirestoreService] 에러: $e');
      debugPrint('[FirestoreService] 스택 트레이스: $stackTrace');
      rethrow;
    }
  }

  /// 코스 등록(수강) 취소 (관리자)
  ///
  /// - 미래 예약이 존재하면 서버가 requiresCascade=true로 막습니다.
  /// - cascade=true로 재호출하면 미래 예약을 연쇄 취소 후 등록을 만료 처리합니다.
  Future<Map<String, dynamic>> cancelEnrollment({
    required String placeId,
    required String userId,
    required String courseId,
    bool cascade = false,
  }) async {
    final callable = FirebaseFunctions.instance.httpsCallable(
      'cancelEnrollment',
    );
    final result = await callable.call({
      'placeId': placeId,
      'userId': userId,
      'courseId': courseId,
      'cascade': cascade,
    });
    final data = result.data;
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    return {'success': true};
  }

  /// 예약 이동 (같은 코스 내에서만) - 트랜잭션 사용
  ///
  /// - 크레딧(remainingReservations)은 변경하지 않음 (이동이므로 net 0)
  /// - sessionReservations의 reservedCount를 old-- / new++로 반영
  /// - 정책/마감/오픈 전 여부는 "관리자 예약 관리"에서 허용하되,
  ///   정원(capacity)과 과거 날짜는 엄격히 차단
  Future<void> moveReservationWithinCourse({
    required String reservationId,
    required String placeId,
    required int newDayOfWeek,
    required String newStartTime,
    required DateTime newReservedDate,
  }) async {
    final newDateString = _formatDate(newReservedDate);
    final callable = FirebaseFunctions.instance.httpsCallable(
      'moveReservationWithinCourse',
    );
    await callable.call({
      'reservationId': reservationId,
      'placeId': placeId,
      'newDayOfWeek': newDayOfWeek,
      'newStartTime': newStartTime,
      'newReservedDateString': newDateString,
    });
  }

  /// 세션 취소 (관리자)
  /// 특정 날짜의 세션을 취소하고 모든 예약자에게 알림 전송
  /// 사용자별 예약 조회 (플레이스별 서브컬렉션)
  ///
  /// [userId] 조회할 사용자 ID
  /// [placeId] 플레이스 ID (필수)
  Stream<List<Reservation>> watchUserReservations(
    String userId, {
    required String placeId,
  }) {
    return _firestore
        .collection('places')
        .doc(placeId)
        .collection('reservations')
        .where('userId', isEqualTo: userId)
        .orderBy('reservedDate', descending: false)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            final data = doc.data();
            data['reservedAt'] = _timestampToDateTime(
              data['reservedAt'],
            ).toIso8601String();
            data['reservedDate'] = _timestampToDateTime(
              data['reservedDate'],
            ).toIso8601String();
            return Reservation.fromJson(data);
          }).toList();
        });
  }

  /// 특정 세션의 예약 조회 (날짜별) - 플레이스 서브컬렉션
  Stream<List<Reservation>> watchSessionReservations({
    required String placeId,
    required String courseId,
    required int dayOfWeek,
    required String startTime,
    required DateTime date,
  }) {
    final dateString = _formatDate(date);
    return _firestore
        .collection('places')
        .doc(placeId)
        .collection('reservations')
        .where('courseId', isEqualTo: courseId)
        .where('dayOfWeek', isEqualTo: dayOfWeek)
        .where('startTime', isEqualTo: startTime)
        .where('reservedDateString', isEqualTo: dateString)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            final data = doc.data();
            data['reservedAt'] = _timestampToDateTime(
              data['reservedAt'],
            ).toIso8601String();
            data['reservedDate'] = _timestampToDateTime(
              data['reservedDate'],
            ).toIso8601String();
            return Reservation.fromJson(data);
          }).toList();
        });
  }

  /// 플레이스별 예약 조회 (서브컬렉션에서 직접 조회)
  Stream<List<Reservation>> watchPlaceReservations(
    String placeId,
    DateTime startDate,
  ) {
    final startDateString = _formatDate(startDate);
    return _firestore
        .collection('places')
        .doc(placeId)
        .collection('reservations')
        .where('reservedDateString', isGreaterThanOrEqualTo: startDateString)
        .orderBy('reservedDateString')
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            final data = doc.data();
            data['reservedAt'] = _timestampToDateTime(
              data['reservedAt'],
            ).toIso8601String();
            data['reservedDate'] = _timestampToDateTime(
              data['reservedDate'],
            ).toIso8601String();
            return Reservation.fromJson(data);
          }).toList();
        });
  }

  // ==================== Session Reservations ====================

  /// 세션별 예약 현황 조회 (특정 날짜)
  Future<SessionReservation?> getSessionReservation({
    required String courseId,
    required int dayOfWeek,
    required String startTime,
    required DateTime date,
  }) async {
    final sessionId = SessionReservation.generateSessionId(
      courseId,
      dayOfWeek,
      startTime,
    );
    final dateString = _formatDate(date);

    final query = _firestore
        .collection('sessionReservations')
        .where('sessionId', isEqualTo: sessionId)
        .where('date', isEqualTo: dateString)
        .limit(1);

    final snapshot = await query.get();
    if (snapshot.docs.isEmpty) return null;

    final doc = snapshot.docs.first;
    final data = doc.data();
    // 문서 ID 추가 (서버에서 id 필드를 저장하지 않을 수 있으므로)
    data['id'] = doc.id;
    data['lastUpdated'] = _timestampToDateTime(
      data['lastUpdated'],
    ).toIso8601String();
    if (data['createdAt'] != null) {
      data['createdAt'] = _timestampToDateTime(
        data['createdAt'],
      ).toIso8601String();
    }

    return SessionReservation.fromJson(data);
  }

  /// 세션별 예약 현황 실시간 구독 (특정 날짜)
  Stream<SessionReservation?> watchSessionReservation({
    required String courseId,
    required int dayOfWeek,
    required String startTime,
    required DateTime date,
  }) {
    final sessionId = SessionReservation.generateSessionId(
      courseId,
      dayOfWeek,
      startTime,
    );
    final dateString = _formatDate(date);

    return _firestore
        .collection('sessionReservations')
        .where('sessionId', isEqualTo: sessionId)
        .where('date', isEqualTo: dateString)
        .limit(1)
        .snapshots()
        .map((snapshot) {
          if (snapshot.docs.isEmpty) return null;

          final doc = snapshot.docs.first;
          final data = doc.data();
          // 문서 ID 추가 (서버에서 id 필드를 저장하지 않을 수 있으므로)
          data['id'] = doc.id;
          data['lastUpdated'] = _timestampToDateTime(
            data['lastUpdated'],
          ).toIso8601String();
          if (data['createdAt'] != null) {
            data['createdAt'] = _timestampToDateTime(
              data['createdAt'],
            ).toIso8601String();
          }

          return SessionReservation.fromJson(data);
        });
  }

  /// 코스별 세션 예약 현황 조회 (날짜 범위)
  Stream<List<SessionReservation>> watchCourseSessionReservations({
    required String courseId,
    String? placeId,
    required DateTime startDate,
    required DateTime endDate,
  }) {
    final startDateString = _formatDate(startDate);
    final endDateString = _formatDate(endDate);

    Query<Map<String, dynamic>> q = _firestore
        .collection('sessionReservations')
        .where('courseId', isEqualTo: courseId);
    if (placeId != null && placeId.isNotEmpty) {
      q = q.where('placeId', isEqualTo: placeId);
    }
    // date 범위 + 정렬은 복합 인덱스가 필요 (firestore.indexes.json에 추가됨)
    q = q
        .where('date', isGreaterThanOrEqualTo: startDateString)
        .where('date', isLessThanOrEqualTo: endDateString)
        .orderBy('date');

    return q.snapshots().map((snapshot) {
      return snapshot.docs.map((doc) {
        final data = doc.data();
        // 문서 ID 추가 (서버에서 id 필드를 저장하지 않을 수 있으므로)
        data['id'] = doc.id;
        data['lastUpdated'] = _timestampToDateTime(
          data['lastUpdated'],
        ).toIso8601String();
        if (data['createdAt'] != null) {
          data['createdAt'] = _timestampToDateTime(
            data['createdAt'],
          ).toIso8601String();
        }
        return SessionReservation.fromJson(data);
      }).toList();
    });
  }

  /// 코스 전체에서 "예약이 존재하는(sessionReservations.reservedCount > 0)" 세션ID 목록 구독
  ///
  /// - 주차(weekOffset)와 무관하게, 해당 코스에서 예약이 한 번이라도 잡힌 세션 템플릿(sessionId)을 찾을 때 사용
  Stream<Set<String>> watchReservedSessionIdsForCourse(String courseId) {
    return _firestore
        .collection('sessionReservations')
        .where('courseId', isEqualTo: courseId)
        .where('reservedCount', isGreaterThan: 0)
        .snapshots()
        .map((snapshot) {
          final ids = <String>{};
          for (final doc in snapshot.docs) {
            final data = doc.data();
            final sessionId = data['sessionId'] as String?;
            if (sessionId != null && sessionId.isNotEmpty) {
              ids.add(sessionId);
            }
          }
          return ids;
        });
  }

  /// 특정 sessionId에 대해 예약이 존재하는 날짜 중 "가장 이른 날짜"를 찾음 (관리자 UX: 잠긴 세션 클릭 시 해당 날짜로 이동)
  Future<DateTime?> findFirstReservedDateForSession(String sessionId) async {
    final snapshot = await _firestore
        .collection('sessionReservations')
        .where('sessionId', isEqualTo: sessionId)
        .where('reservedCount', isGreaterThan: 0)
        .orderBy('date')
        .limit(1)
        .get();

    if (snapshot.docs.isEmpty) return null;
    final data = snapshot.docs.first.data();
    final dateString = data['date'] as String?;
    if (dateString == null || dateString.isEmpty) return null;
    // "yyyy-MM-dd"
    return DateTime.tryParse(dateString);
  }

  // ==================== Date Capacity Overrides ====================

  /// 날짜별 수용인원 오버라이드 조회
  /// 고정ID 패턴: ${sessionId}_${date}
  Future<DateCapacityOverride?> getCapacityOverride(
    String sessionId,
    String date,
  ) async {
    // 고정ID 패턴: ${sessionId}_${date}
    final overrideId = '${sessionId}_$date';
    final docRef = _firestore
        .collection('dateCapacityOverrides')
        .doc(overrideId);

    final snapshot = await docRef.get();
    if (!snapshot.exists) return null;

    final data = snapshot.data()!;
    data['id'] = overrideId;
    data['createdAt'] = _timestampToDateTime(
      data['createdAt'],
    ).toIso8601String();
    if (data['updatedAt'] != null) {
      data['updatedAt'] = _timestampToDateTime(
        data['updatedAt'],
      ).toIso8601String();
    }

    return DateCapacityOverride.fromJson(data);
  }

  /// 날짜별 수용인원 오버라이드 설정
  /// 고정ID 패턴: ${sessionId}_${date}
  Future<DateCapacityOverride> setCapacityOverride({
    required String sessionId,
    required String date,
    required int capacity,
  }) async {
    // 고정ID 패턴: ${sessionId}_${date}
    final overrideId = '${sessionId}_$date';
    final docRef = _firestore
        .collection('dateCapacityOverrides')
        .doc(overrideId);

    final existingDoc = await docRef.get();
    final now = TimezoneUtils.getSeoulDateTime();

    if (existingDoc.exists) {
      // 업데이트
      await docRef.update({
        'capacity': capacity,
        'updatedAt': _dateTimeToTimestamp(now),
      });
      final data = existingDoc.data()!;
      return DateCapacityOverride(
        id: overrideId,
        sessionId: sessionId,
        date: date,
        capacity: capacity,
        createdAt: _timestampToDateTime(data['createdAt']),
        updatedAt: now,
      );
    } else {
      // 생성
      final override = DateCapacityOverride(
        id: overrideId,
        sessionId: sessionId,
        date: date,
        capacity: capacity,
        createdAt: now,
      );
      await docRef.set({
        ...override.toJson(),
        'createdAt': _dateTimeToTimestamp(override.createdAt),
      });
      return override;
    }
  }

  /// 날짜별 수용인원 오버라이드 삭제
  /// 고정ID 패턴: ${sessionId}_${date}
  Future<void> deleteCapacityOverride(String sessionId, String date) async {
    // 고정ID 패턴: ${sessionId}_${date}
    final overrideId = '${sessionId}_$date';
    final docRef = _firestore
        .collection('dateCapacityOverrides')
        .doc(overrideId);

    await docRef.delete();
  }

  // ==================== Stories ====================

  /// 플레이스별 스토리 조회 (최대 5개, 인덱스 없이 클라이언트에서 정렬)
  Future<List<Story>> getStoriesByPlace(String placeId) async {
    debugPrint('[FirestoreService.getStoriesByPlace] 시작 - placeId: $placeId');
    debugPrint(
      '[FirestoreService.getStoriesByPlace] 쿼리: stories 컬렉션, placeId == $placeId (클라이언트에서 정렬)',
    );

    try {
      final snapshot = await _firestore
          .collection('stories')
          .where('placeId', isEqualTo: placeId)
          .get();

      debugPrint(
        '[FirestoreService.getStoriesByPlace] 쿼리 결과 - 문서 개수: ${snapshot.docs.length}',
      );

      final stories = snapshot.docs.map((doc) {
        final data = doc.data();
        debugPrint(
          '[FirestoreService.getStoriesByPlace] 문서 ID: ${doc.id}, placeId: ${data['placeId']}, title: ${data['title']}',
        );
        data['createdAt'] = _timestampToDateTime(
          data['createdAt'],
        ).toIso8601String();
        return Story.fromJson(data);
      }).toList();

      // 클라이언트에서 createdAt 기준 내림차순 정렬 후 최대 5개만 반환
      stories.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final limitedStories = stories.take(5).toList();

      debugPrint(
        '[FirestoreService.getStoriesByPlace] 완료 - 스토리 개수: ${limitedStories.length}',
      );
      return limitedStories;
    } catch (e, stackTrace) {
      debugPrint('[FirestoreService.getStoriesByPlace] 에러 발생: $e');
      debugPrint('[FirestoreService.getStoriesByPlace] 스택 트레이스: $stackTrace');
      rethrow;
    }
  }

  /// 스토리 생성
  Future<Story> createStory(Story story) async {
    final docRef = _firestore.collection('stories').doc(story.id);
    await docRef.set({
      ...story.toJson(),
      'createdAt': _dateTimeToTimestamp(story.createdAt),
    });
    return story;
  }

  /// 스토리 업데이트
  Future<Story> updateStory(Story story) async {
    final docRef = _firestore.collection('stories').doc(story.id);
    await docRef.update({
      ...story.toJson(),
      'createdAt': _dateTimeToTimestamp(story.createdAt),
    });
    return story;
  }

  /// 스토리 삭제
  Future<void> deleteStory(String storyId) async {
    await _firestore.collection('stories').doc(storyId).delete();
  }

  // ==================== Promotions ====================

  /// 플레이스별 프로모션 조회
  Future<List<Promotion>> getPromotionsByPlace(String placeId) async {
    final snapshot = await _firestore
        .collection('promotions')
        .where('placeId', isEqualTo: placeId)
        .orderBy('createdAt', descending: true)
        .get();

    return snapshot.docs.map((doc) {
      final data = doc.data();
      data['createdAt'] = _timestampToDateTime(
        data['createdAt'],
      ).toIso8601String();
      return Promotion.fromJson(data);
    }).toList();
  }

  /// 플레이스별 프로모션 실시간 구독
  Stream<List<Promotion>> watchPromotionsByPlace(String placeId) {
    return _firestore
        .collection('promotions')
        .where('placeId', isEqualTo: placeId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            final data = doc.data();
            data['createdAt'] = _timestampToDateTime(
              data['createdAt'],
            ).toIso8601String();
            return Promotion.fromJson(data);
          }).toList();
        });
  }

  /// 프로모션 생성
  Future<Promotion> createPromotion(Promotion promotion) async {
    final docRef = _firestore.collection('promotions').doc(promotion.id);
    await docRef.set({
      ...promotion.toJson(),
      'createdAt': _dateTimeToTimestamp(promotion.createdAt),
    });
    return promotion;
  }

  /// 프로모션 업데이트
  Future<Promotion> updatePromotion(Promotion promotion) async {
    final docRef = _firestore.collection('promotions').doc(promotion.id);
    await docRef.update({
      ...promotion.toJson(),
      'createdAt': _dateTimeToTimestamp(promotion.createdAt),
    });
    return promotion;
  }

  /// 프로모션 삭제
  Future<void> deletePromotion(String promotionId) async {
    await _firestore.collection('promotions').doc(promotionId).delete();
  }

  // ==================== Notifications ====================

  /// 사용자 알림 목록 조회 (역할별)
  Future<List<AppNotification>> getUserNotifications(
    String userId, {
    bool isAdmin = false,
  }) async {
    final snapshot = await _firestore
        .collection('notifications')
        .where('userId', isEqualTo: userId)
        .where('isAdminNotification', isEqualTo: isAdmin)
        .orderBy('createdAt', descending: true)
        .get();

    return snapshot.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      // Timestamp 변환
      if (data['createdAt'] != null) {
        data['createdAt'] = _timestampToDateTime(data['createdAt']);
      }
      return AppNotification.fromJson(data);
    }).toList();
  }

  /// 사용자 알림 실시간 구독 (역할별)
  Stream<List<AppNotification>> watchUserNotifications(
    String userId, {
    bool isAdmin = false,
  }) {
    return _firestore
        .collection('notifications')
        .where('userId', isEqualTo: userId)
        .where('isAdminNotification', isEqualTo: isAdmin)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            final data = doc.data();
            data['id'] = doc.id;
            // Timestamp 변환
            if (data['createdAt'] != null) {
              data['createdAt'] = _timestampToDateTime(data['createdAt']);
            }
            return AppNotification.fromJson(data);
          }).toList();
        });
  }

  /// 알림 ID로 단일 알림 조회
  Future<AppNotification?> getNotificationById(String notificationId) async {
    try {
      final doc = await _firestore
          .collection('notifications')
          .doc(notificationId)
          .get();
      if (!doc.exists) {
        return null;
      }
      final data = doc.data()!;
      data['id'] = doc.id;
      // Timestamp 변환
      if (data['createdAt'] != null) {
        data['createdAt'] = _timestampToDateTime(data['createdAt']);
      }
      return AppNotification.fromJson(data);
    } catch (e) {
      print('[FirestoreService] getNotificationById error: $e');
      return null;
    }
  }

  /// 알림 읽음 처리
  Future<void> markNotificationAsRead(String notificationId) async {
    await _firestore.collection('notifications').doc(notificationId).update({
      'isRead': true,
    });
  }

  /// 모든 알림 읽음 처리
  Future<void> markAllNotificationsAsRead(List<String> notificationIds) async {
    final batch = _firestore.batch();
    for (final id in notificationIds) {
      final ref = _firestore.collection('notifications').doc(id);
      batch.update(ref, {'isRead': true});
    }
    await batch.commit();
  }

  /// 알림 삭제
  Future<void> deleteNotification(String notificationId) async {
    await _firestore.collection('notifications').doc(notificationId).delete();
  }

  /// 알림 생성
  Future<AppNotification> createNotification(
    AppNotification notification,
  ) async {
    final docRef = _firestore.collection('notifications').doc(notification.id);
    await docRef.set({
      ...notification.toJson(),
      'createdAt': _dateTimeToTimestamp(notification.createdAt),
    });
    return notification;
  }
}
