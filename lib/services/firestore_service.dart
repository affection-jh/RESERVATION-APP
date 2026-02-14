import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import '../models/place.dart';
import '../models/reservation.dart';
import '../models/session_reservation.dart';
import '../models/date_capacity_override.dart';
import '../models/course.dart';
import '../models/notification.dart';
import '../models/course_override.dart';
import '../providers/story_provider.dart';
import '../policies/course_policy.dart';
import '../utils/timezone_utils.dart';

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

  /// 검색 응답 등에서 id/name/adminId를 안전히 문자열로 (null/다른 타입 → '')
  static String _ensureString(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    return value.toString();
  }

  /// 선택 필드용: null이면 null, 아니면 문자열로
  static String? _ensureStringOrNull(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    return value.toString();
  }

  /// 날짜를 "YYYY-MM-DD" 형식 문자열로 변환
  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  /// Timestamp를 DateTime으로 변환 (public)
  DateTime timestampToDateTime(dynamic timestamp) {
    return _timestampToDateTime(timestamp);
  }

  /// Timestamp를 DateTime으로 변환 (private)
  DateTime _timestampToDateTime(dynamic timestamp) {
    if (timestamp == null) {
      return DateTime.now();
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
    final snapshot =
        await _firestore
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

  /// 플레이스 서버 검색 (이름/위치 포함 검색, Callable)
  ///
  /// [query] 검색어 (공백 trim 후 전달). 빈 문자열이면 빈 목록 반환.
  Future<List<Place>> searchPlaces(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    debugPrint('[FirestoreService.searchPlaces] 호출: "$trimmed"');
    final callable = FirebaseFunctions.instance.httpsCallable('searchPlaces');
    try {
      final result = await callable.call({'query': trimmed});
      final data = result.data as Map<String, dynamic>?;
      final list = data?['places'] as List<dynamic>?;
      if (list == null) {
        debugPrint('[FirestoreService.searchPlaces] 응답 places 필드 없음');
        return [];
      }
      debugPrint('[FirestoreService.searchPlaces] 서버 응답 ${list.length}건 수신');
      final places = <Place>[];
      for (final raw in list) {
        if (raw is! Map) continue;
        try {
          final item = Map<String, dynamic>.from(raw);
          // 검색 결과: adminId 없어도 됨. id/name은 문자열로 통일, courses는 검색에서 미사용이라 빈 배열
          final normalized = <String, dynamic>{
            'id': _ensureString(item['id']),
            'name': _ensureString(item['name']),
            'adminId': _ensureString(item['adminId']),
            'description': _ensureStringOrNull(item['description']),
            'location': _ensureStringOrNull(item['location']),
            'appBarText': _ensureStringOrNull(item['appBarText']),
            'greetingText': _ensureStringOrNull(item['greetingText']),
            'imageUrl': _ensureStringOrNull(item['imageUrl']),
            'courses': [], // 검색 결과에서는 코스 파싱 생략(서버 형식 차이로 파싱 실패 방지)
          };
          places.add(Place.fromJson(normalized));
        } catch (e) {
          debugPrint('[FirestoreService.searchPlaces] 항목 파싱 스킵: $e');
          debugPrint('[FirestoreService.searchPlaces] 수신 항목: $raw');
        }
      }
      debugPrint('[FirestoreService.searchPlaces] 파싱 완료 ${places.length}건');
      return places;
    } on FirebaseFunctionsException catch (e) {
      debugPrint(
        '[FirestoreService.searchPlaces] Callable 오류: code=${e.code}, message=${e.message}',
      );
      rethrow;
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
      final updatedCourses =
          coursesData.map((c) {
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
      'sessions':
          sessions
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
  /// 서버에서 코스 삭제를 중앙화합니다.
  ///
  /// - 코스 제거 + 관련 데이터 정합성 정리(예약/카운트/오버라이드/정책/주차오픈/멤버데이터)는
  ///   Callable `deleteCourse`가 단일 진실입니다.
  /// - cascade=false일 때 미래 예약이 있으면 서버가 requiresCascade=true로 막습니다.
  Future<void> deleteCourse(
    String placeId,
    String courseId, {
    bool cascade = false,
  }) async {
    final callable = FirebaseFunctions.instance.httpsCallable('deleteCourse');
    await callable.call({
      'placeId': placeId,
      'courseId': courseId,
      'cascade': cascade,
    });
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
      final now = TimezoneUtils.getSeoulDateTime();
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

      // effectiveFrom <= now 인 후보들 중 가장 최신(effectiveFrom) 선택
      final candidates = <CoursePolicy>[];
      if (active != null && !active.effectiveFrom.isAfter(now)) {
        candidates.add(active);
      }
      if (scheduled != null && !scheduled.effectiveFrom.isAfter(now)) {
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
    final dataToSave =
        isFuture
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
    final snapshot =
        await _firestore
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
    final dateString = _formatDate(reservation.reservedDate);
    final callable = FirebaseFunctions.instance.httpsCallable(
      'createReservation',
    );

    final result = await callable.call({
      'placeId': reservation.placeId,
      'courseId': reservation.courseId,
      'dayOfWeek': reservation.dayOfWeek,
      'startTime': reservation.startTime,
      'reservedDateString': dateString,
      // 관리자가 다른 사용자를 위해 예약 생성 시 userId 전달
      'userId': reservation.userId,
      // 관리자 강제 추가(정원/오픈 전/마감 전 등) - 명시적 확인을 거친 경우에만 true
      'force': force,
    });

    final data = result.data as Map<dynamic, dynamic>;
    final id = (data['id'] as String?) ?? '';
    if (id.isEmpty) {
      throw Exception('예약 생성에 실패했습니다. (서버 응답 오류)');
    }

    return reservation.copyWith(id: id);
  }

  /// 예약 삭제 (배치 함수 사용)
  Future<void> deleteReservation({
    required String reservationId,
    required String placeId,
  }) async {
    // 배치 함수 사용 (개별도 배치로 처리)
    await batchCancelReservations(
      reservationIds: [reservationId],
      placeId: placeId,
    );
  }

  /// 코스 등록(수강) 취소 (관리자)
  ///
  /// - 미래 예약이 존재하면 서버가 requiresCascade=true로 막습니다.
  /// - cascade=true로 재호출하면 미래 예약을 연쇄 취소 후 등록을 **삭제**합니다.
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

  /// 예약 이동 (같은 코스 내에서만) - 배치 함수 사용
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
    // 배치 함수 사용 (개별도 배치로 처리)
    await batchMoveReservations(
      reservationIds: [reservationId],
      placeId: placeId,
      newDayOfWeek: newDayOfWeek,
      newStartTime: newStartTime,
      newReservedDate: newReservedDate,
    );
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
            data['reservedAt'] =
                _timestampToDateTime(data['reservedAt']).toIso8601String();
            data['reservedDate'] =
                _timestampToDateTime(data['reservedDate']).toIso8601String();
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
            data['reservedAt'] =
                _timestampToDateTime(data['reservedAt']).toIso8601String();
            data['reservedDate'] =
                _timestampToDateTime(data['reservedDate']).toIso8601String();
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
            data['reservedAt'] =
                _timestampToDateTime(data['reservedAt']).toIso8601String();
            data['reservedDate'] =
                _timestampToDateTime(data['reservedDate']).toIso8601String();
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
    data['lastUpdated'] =
        _timestampToDateTime(data['lastUpdated']).toIso8601String();
    if (data['createdAt'] != null) {
      data['createdAt'] =
          _timestampToDateTime(data['createdAt']).toIso8601String();
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
          data['lastUpdated'] =
              _timestampToDateTime(data['lastUpdated']).toIso8601String();
          if (data['createdAt'] != null) {
            data['createdAt'] =
                _timestampToDateTime(data['createdAt']).toIso8601String();
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
        data['lastUpdated'] =
            _timestampToDateTime(data['lastUpdated']).toIso8601String();
        if (data['createdAt'] != null) {
          data['createdAt'] =
              _timestampToDateTime(data['createdAt']).toIso8601String();
        }
        return SessionReservation.fromJson(data);
      }).toList();
    });
  }

  /// 코스 전체에서 "예약이 존재하는(sessionReservations.reservedCount > 0)" 세션ID 목록 구독
  ///
  /// - 주차(weekOffset)와 무관하게, 해당 코스에서 예약이 한 번이라도 잡힌 세션 템플릿(sessionId)을 찾을 때 사용
  Stream<Set<String>> watchReservedSessionIdsForCourse(
    String courseId, {
    DateTime? startDate,
  }) {
    // 과거(완료된) 세션까지 전부 스트리밍하면 문서 수가 무한히 누적되어 비용이 커질 수 있음.
    // "앞으로 예약이 잡힌 세션 템플릿"을 파악하는 목적이 대부분이라,
    // 기본은 오늘 이후(date >= today)만 대상으로 좁힌다.
    final sd = startDate ?? TimezoneUtils.getSeoulToday();
    final startDateString = _formatDate(sd);

    // NOTE:
    // reservedCount > 0 + date 범위(inequality) 조합은 인덱스/쿼리 제약에 걸릴 수 있어
    // 서버 필터는 date만 적용하고, reservedCount는 클라이언트에서 필터링한다.
    return _firestore
        .collection('sessionReservations')
        .where('courseId', isEqualTo: courseId)
        .where('date', isGreaterThanOrEqualTo: startDateString)
        .snapshots()
        .map((snapshot) {
          final ids = <String>{};
          for (final doc in snapshot.docs) {
            final data = doc.data();
            final sessionId = data['sessionId'] as String?;
            final reservedCount = (data['reservedCount'] as num?)?.toInt() ?? 0;
            if (reservedCount <= 0) continue;
            if (sessionId != null && sessionId.isNotEmpty) {
              ids.add(sessionId);
            }
          }
          return ids;
        });
  }

  /// 특정 sessionId에 대해 예약이 존재하는 날짜 중 "가장 이른 날짜"를 찾음 (관리자 UX: 잠긴 세션 클릭 시 해당 날짜로 이동)
  Future<DateTime?> findFirstReservedDateForSession(String sessionId) async {
    final snapshot =
        await _firestore
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
  Future<DateCapacityOverride?> getCapacityOverride(
    String placeId,
    String sessionId,
    String date,
  ) async {
    final query = _firestore
        .collection('dateCapacityOverrides')
        .where('placeId', isEqualTo: placeId)
        .where('sessionId', isEqualTo: sessionId)
        .where('date', isEqualTo: date)
        .limit(1);

    final snapshot = await query.get();
    if (snapshot.docs.isEmpty) return null;

    final data = snapshot.docs.first.data();
    data['createdAt'] =
        _timestampToDateTime(data['createdAt']).toIso8601String();
    if (data['updatedAt'] != null) {
      data['updatedAt'] =
          _timestampToDateTime(data['updatedAt']).toIso8601String();
    }

    return DateCapacityOverride.fromJson(data);
  }

  /// 날짜별 수용인원 오버라이드 설정
  Future<DateCapacityOverride> setCapacityOverride({
    required String placeId,
    required String sessionId,
    required String date,
    required int capacity,
  }) async {
    // sessionId = "${courseId}_${dayOfWeek}_${startTime}"
    // courseId는 "_"를 포함할 수 있으므로(예: course_123...), 뒤에서 2개 토큰을 제외하고 합친다.
    final parts = sessionId.split('_');
    final derivedCourseId =
        parts.length >= 3 ? parts.sublist(0, parts.length - 2).join('_') : '';

    // 기존 오버라이드 확인
    final existing = await getCapacityOverride(placeId, sessionId, date);

    if (existing != null) {
      // 업데이트
      final docRef = _firestore
          .collection('dateCapacityOverrides')
          .doc(existing.id);
      await docRef.update({
        'placeId': placeId,
        'courseId': derivedCourseId,
        'capacity': capacity,
        'updatedAt': _dateTimeToTimestamp(DateTime.now()),
      });
      return existing.copyWith(capacity: capacity, updatedAt: DateTime.now());
    } else {
      // 생성
      final docRef = _firestore.collection('dateCapacityOverrides').doc();
      final override = DateCapacityOverride(
        id: docRef.id,
        placeId: placeId,
        courseId: derivedCourseId,
        sessionId: sessionId,
        date: date,
        capacity: capacity,
        createdAt: DateTime.now(),
      );
      await docRef.set({
        ...override.toJson(),
        'createdAt': _dateTimeToTimestamp(override.createdAt),
      });
      return override;
    }
  }

  /// 날짜별 수용인원 오버라이드 삭제
  Future<void> deleteCapacityOverride({
    required String placeId,
    required String sessionId,
    required String date,
  }) async {
    final query = _firestore
        .collection('dateCapacityOverrides')
        .where('placeId', isEqualTo: placeId)
        .where('sessionId', isEqualTo: sessionId)
        .where('date', isEqualTo: date)
        .limit(1);

    final snapshot = await query.get();
    if (snapshot.docs.isNotEmpty) {
      await snapshot.docs.first.reference.delete();
    }
  }

  /// 날짜별 수용인원 오버라이드 구독 (특정 코스의 특정 날짜 범위)
  ///
  /// ✅ 최적화: courseId 필드로 서버 사이드 필터링하여 읽기 비용 절감
  Stream<Map<String, int>> watchDateCapacityOverrides({
    required String placeId,
    required String courseId,
    required DateTime startDate,
    required DateTime endDate,
  }) {
    final startDateString = _formatDate(startDate);
    final endDateString = _formatDate(endDate);

    return _firestore
        .collection('dateCapacityOverrides')
        .where('placeId', isEqualTo: placeId)
        .where('courseId', isEqualTo: courseId)
        .where('date', isGreaterThanOrEqualTo: startDateString)
        .where('date', isLessThanOrEqualTo: endDateString)
        .orderBy('date')
        .snapshots()
        .map((snapshot) {
          final overrides = <String, int>{};
          for (final doc in snapshot.docs) {
            final data = doc.data();
            final sessionId = data['sessionId'] as String?;
            final date = data['date'] as String?;
            final dynamic capRaw = data['capacity'];
            final int? capacity =
                capRaw is int
                    ? capRaw
                    : (capRaw is num
                        ? capRaw.toInt()
                        : int.tryParse('$capRaw'));
            if (sessionId != null && date != null && capacity != null) {
              overrides['${sessionId}_$date'] = capacity;
            }
          }
          return overrides;
        });
  }

  // ==================== Stories ====================

  /// 플레이스별 스토리 조회 (최대 5개, 인덱스 없이 클라이언트에서 정렬)
  Future<List<Story>> getStoriesByPlace(String placeId) async {
    debugPrint('[FirestoreService.getStoriesByPlace] 시작 - placeId: $placeId');
    debugPrint(
      '[FirestoreService.getStoriesByPlace] 쿼리: stories 컬렉션, placeId == $placeId (클라이언트에서 정렬)',
    );

    try {
      final snapshot =
          await _firestore
              .collection('stories')
              .where('placeId', isEqualTo: placeId)
              .get();

      debugPrint(
        '[FirestoreService.getStoriesByPlace] 쿼리 결과 - 문서 개수: ${snapshot.docs.length}',
      );

      final stories =
          snapshot.docs.map((doc) {
            final data = doc.data();
            debugPrint(
              '[FirestoreService.getStoriesByPlace] 문서 ID: ${doc.id}, placeId: ${data['placeId']}, title: ${data['title']}',
            );
            data['createdAt'] =
                _timestampToDateTime(data['createdAt']).toIso8601String();
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

  // ==================== Notifications ====================

  /// 사용자 알림 목록 조회 (역할별)
  Future<List<AppNotification>> getUserNotifications(
    String userId, {
    bool isAdmin = false,
  }) async {
    final snapshot =
        await _firestore
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
      final doc =
          await _firestore
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

  // ==================== Batch Operations ====================

  /// 일괄 예약 이동 (관리자)
  ///
  /// 관리자 권한으로 정원을 초과해서도 이동 가능
  Future<Map<String, dynamic>> batchMoveReservations({
    required List<String> reservationIds,
    required String placeId,
    required int newDayOfWeek,
    required String newStartTime,
    required DateTime newReservedDate,
  }) async {
    final dateString = _formatDate(newReservedDate);
    final callable = FirebaseFunctions.instance.httpsCallable(
      'batchMoveReservations',
    );

    final result = await callable.call({
      'reservationIds': reservationIds,
      'placeId': placeId,
      'newDayOfWeek': newDayOfWeek,
      'newStartTime': newStartTime,
      'newReservedDateString': dateString,
    });

    return result.data as Map<String, dynamic>;
  }

  /// 일괄 예약 취소 (관리자)
  ///
  /// 관리자 권한으로 1시간 제한 우회 가능 (단, 이미 시작된 세션은 취소 불가)
  Future<Map<String, dynamic>> batchCancelReservations({
    required List<String> reservationIds,
    required String placeId,
  }) async {
    final callable = FirebaseFunctions.instance.httpsCallable(
      'batchCancelReservations',
    );

    final result = await callable.call({
      'reservationIds': reservationIds,
      'placeId': placeId,
    });

    return result.data as Map<String, dynamic>;
  }

  // ==================== Course Overrides (비정기 일정) ====================

  /// 특정 주의 비정기 일정 조회
  ///
  /// [weekStartDate] 해당 주의 시작 날짜 (월요일) "YYYY-MM-DD" 형식
  Future<List<CourseOverride>> getCourseOverrides({
    required String placeId,
    String? courseId,
    required String weekStartDate,
  }) async {
    try {
      Query query = _firestore
          .collection('courseOverrides')
          .where('placeId', isEqualTo: placeId)
          .where('weekStartDate', isEqualTo: weekStartDate);

      if (courseId != null) {
        query = query.where('courseId', isEqualTo: courseId);
      }

      final snapshot = await query.get();
      return snapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        data['id'] = doc.id;
        return CourseOverride.fromJson(data);
      }).toList();
    } catch (e) {
      debugPrint('[FirestoreService] getCourseOverrides error: $e');
      return [];
    }
  }

  /// 비정기 일정 생성/수정/삭제 (Functions 사용)
  Future<Map<String, dynamic>> upsertCourseOverride({
    required String placeId,
    required String courseId,
    required String date,
    required int dayOfWeek,
    required String weekStartDate,
    String? startTime,
    String? endTime,
    int? capacity,
    bool isCancelled = false,
    String action = 'create', // 'create' | 'update' | 'delete'
    String? overrideId,
    bool sendNotification = true,
  }) async {
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'upsertCourseOverride',
      );
      final result = await callable.call({
        'placeId': placeId,
        'courseId': courseId,
        'date': date,
        'dayOfWeek': dayOfWeek,
        'startTime': startTime,
        'endTime': endTime,
        'capacity': capacity,
        'isCancelled': isCancelled,
        'weekStartDate': weekStartDate,
        'action': action,
        'overrideId': overrideId,
        'sendNotification': sendNotification,
      });

      return {
        'success': result.data['success'] == true,
        'overrideId': result.data['overrideId'],
      };
    } catch (e) {
      debugPrint('[FirestoreService] upsertCourseOverride error: $e');
      rethrow;
    }
  }

  /// 비정기 일정 생성 (로컬, Functions 미사용 - 구독용)
  Future<CourseOverride> createCourseOverride(CourseOverride override) async {
    final docRef = _firestore.collection('courseOverrides').doc(override.id);
    await docRef.set(override.toJson());
    return override;
  }

  /// 비정기 일정 업데이트 (로컬, Functions 미사용)
  Future<void> updateCourseOverride(CourseOverride override) async {
    final docRef = _firestore.collection('courseOverrides').doc(override.id);
    await docRef.update({
      ...override.toJson(),
      'updatedAt': _dateTimeToTimestamp(DateTime.now()),
    });
  }

  /// 비정기 일정 삭제 (로컬, Functions 미사용)
  Future<void> deleteCourseOverride(String overrideId) async {
    await _firestore.collection('courseOverrides').doc(overrideId).delete();
  }

  /// 특정 날짜의 비정기 일정 조회
  Future<List<CourseOverride>> getCourseOverridesByDate({
    required String placeId,
    required String date, // "YYYY-MM-DD"
  }) async {
    try {
      final snapshot =
          await _firestore
              .collection('courseOverrides')
              .where('placeId', isEqualTo: placeId)
              .where('date', isEqualTo: date)
              .get();

      return snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        return CourseOverride.fromJson(data);
      }).toList();
    } catch (e) {
      debugPrint('[FirestoreService] getCourseOverridesByDate error: $e');
      return [];
    }
  }

  /// 비정기 일정 구독 (실시간 반영)
  Stream<List<CourseOverride>> streamCourseOverrides({
    required String placeId,
    String? courseId,
    required String weekStartDate,
  }) {
    Query query = _firestore
        .collection('courseOverrides')
        .where('placeId', isEqualTo: placeId)
        .where('weekStartDate', isEqualTo: weekStartDate);

    if (courseId != null) {
      query = query.where('courseId', isEqualTo: courseId);
    }

    return query.snapshots().map((snapshot) {
      return snapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        data['id'] = doc.id;
        return CourseOverride.fromJson(data);
      }).toList();
    });
  }

  // ==================== Booking Week Opens ====================

  /// 관리자 미리 예약 열기: 특정 주차를 정책과 상관없이 오픈
  Future<void> setBookingWeekOpened({
    required String placeId,
    required String courseId,
    required String weekStartDate, // "YYYY-MM-DD" (주차 시작 월요일)
  }) async {
    try {
      final docId = '${placeId}_${courseId}_$weekStartDate';
      await _firestore.collection('bookingWeekOpens').doc(docId).set({
        'placeId': placeId,
        'courseId': courseId,
        'weekStartDate': weekStartDate,
        'openedAt': _dateTimeToTimestamp(TimezoneUtils.getSeoulDateTime()),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[FirestoreService] setBookingWeekOpened error: $e');
      rethrow;
    }
  }

  /// 특정 주차가 미리 열렸는지 확인
  Future<bool> isBookingWeekOpened({
    required String placeId,
    required String courseId,
    required String weekStartDate,
  }) async {
    try {
      final docId = '${placeId}_${courseId}_$weekStartDate';
      final doc =
          await _firestore.collection('bookingWeekOpens').doc(docId).get();
      return doc.exists;
    } catch (e) {
      debugPrint('[FirestoreService] isBookingWeekOpened error: $e');
      return false;
    }
  }

  /// 코스의 미리 열린 주차 목록 구독
  Stream<Set<String>> streamBookingWeekOpens({
    required String placeId,
    required String courseId,
  }) {
    return _firestore
        .collection('bookingWeekOpens')
        .where('placeId', isEqualTo: placeId)
        .where('courseId', isEqualTo: courseId)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs
              .map((doc) => doc.data()['weekStartDate'] as String? ?? '')
              .where((date) => date.isNotEmpty)
              .toSet();
        });
  }
}
