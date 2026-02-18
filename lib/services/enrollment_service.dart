import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import '../models/course_enrollment.dart';
import '../models/enrollment_action.dart';
import '../utils/firestore_utils.dart';
import '../utils/timezone_utils.dart';
import 'firestore_service.dart';

/// Enrollment 관련 Firebase 작업을 관리하는 서비스
class EnrollmentService {
  final FirestoreService _firestoreService = FirestoreService();
  FirebaseFirestore get _firestore => _firestoreService.firestore;

  // Helper 메서드
  Timestamp _dateTimeToTimestamp(DateTime dateTime) {
    return Timestamp.fromDate(dateTime);
  }

  DateTime _timestampToDateTime(dynamic timestamp) {
    if (timestamp == null) return TimezoneUtils.getSeoulDateTime();
    if (timestamp is Timestamp) return timestamp.toDate();
    if (timestamp is String) return DateTime.parse(timestamp);
    throw Exception('Invalid timestamp format');
  }

  CourseEnrollment _courseEnrollmentFromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = Map<String, dynamic>.from(doc.data());

    // 일부 데이터는 id 필드가 없을 수 있어 문서 ID로 보강
    data['id'] ??= doc.id;

    // 기본 DateTime 필드 변환
    data['enrolledAt'] =
        _timestampToDateTime(data['enrolledAt']).toIso8601String();
    data['validFrom'] =
        _timestampToDateTime(data['validFrom']).toIso8601String();
    data['validUntil'] =
        _timestampToDateTime(data['validUntil']).toIso8601String();

    return CourseEnrollment.fromJson(data);
  }

  /// 액션 히스토리 온디멘드 조회 (enrollments/{id}/actionHistory 서브컬렉션)
  Stream<List<EnrollmentAction>> watchActionHistory(String enrollmentId) {
    return _firestore
        .collection('enrollments')
        .doc(enrollmentId)
        .collection('actionHistory')
        .orderBy('performedAt', descending: true)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            final data = Map<String, dynamic>.from(doc.data());
            data['id'] = doc.id;
            if (data['performedAt'] != null &&
                data['performedAt'] is Timestamp) {
              data['performedAt'] =
                  _timestampToDateTime(data['performedAt']).toIso8601String();
            }
            return EnrollmentAction.fromJson(data);
          }).toList();
        });
  }

  /// 액션 히스토리 1회 조회 (구독 없음). 200개씩 페이지네이션.
  /// [startAfterCursor]는 이전 호출의 [nextPageCursor] (화면에서는 불투명 객체로 보관).
  Future<({List<EnrollmentAction> actions, Object? nextPageCursor})>
  getActionHistory(
    String enrollmentId, {
    int limit = 200,
    Object? startAfterCursor,
  }) async {
    Query<Map<String, dynamic>> q = _firestore
        .collection('enrollments')
        .doc(enrollmentId)
        .collection('actionHistory')
        .orderBy('performedAt', descending: true)
        .limit(limit);
    if (startAfterCursor != null && startAfterCursor is DocumentSnapshot) {
      q = q.startAfterDocument(startAfterCursor);
    }
    final snapshot = await q.get();
    final actions =
        snapshot.docs.map((doc) {
          final data = Map<String, dynamic>.from(doc.data());
          data['id'] = doc.id;
          if (data['performedAt'] != null && data['performedAt'] is Timestamp) {
            data['performedAt'] =
                _timestampToDateTime(data['performedAt']).toIso8601String();
          }
          return EnrollmentAction.fromJson(data);
        }).toList();
    final nextPageCursor = snapshot.docs.isNotEmpty ? snapshot.docs.last : null;
    return (actions: actions, nextPageCursor: nextPageCursor);
  }

  /// 액션 히스토리 1건 추가 (재등록/횟수조정/기간연장/취소/메모 등)
  /// performedAt은 서버 시간(FieldValue.serverTimestamp)으로 저장 (클라이언트 시간 비신뢰)
  Future<void> addActionToHistory(
    String enrollmentId,
    EnrollmentAction action,
  ) async {
    final ref =
        _firestore
            .collection('enrollments')
            .doc(enrollmentId)
            .collection('actionHistory')
            .doc();
    final json = action.toJson();
    json['performedAt'] = FieldValue.serverTimestamp();
    await ref.set(json);
    await FirestoreUtils.waitForServerAck();
  }

  /// Enrollment 생성
  ///
  /// [enrollment] 생성할 enrollment 객체 (id가 없으면 자동 생성)
  ///
  /// Returns: 생성된 enrollment 또는 null
  Future<CourseEnrollment?> createEnrollment(
    CourseEnrollment enrollment,
  ) async {
    try {
      debugPrint('🔥 [EnrollmentService] enrollment 생성 시작');
      debugPrint('🔥 [EnrollmentService] userId: ${enrollment.userId}');
      debugPrint('🔥 [EnrollmentService] courseId: ${enrollment.courseId}');
      debugPrint('🔥 [EnrollmentService] placeId: ${enrollment.placeId}');
      debugPrint(
        '🔥 [EnrollmentService] totalReservations: ${enrollment.totalReservations}',
      );
      debugPrint('🔥 [EnrollmentService] validFrom: ${enrollment.validFrom}');
      debugPrint('🔥 [EnrollmentService] validUntil: ${enrollment.validUntil}');

      // ID가 없으면 고정 ID 생성 (중복 방지: userId+placeId+courseId)
      CourseEnrollment enrollmentToCreate = enrollment;
      if (enrollment.id.isEmpty) {
        final deterministicId =
            '${enrollment.userId}_${enrollment.placeId}_${enrollment.courseId}';
        enrollmentToCreate = enrollment.copyWith(id: deterministicId);
        debugPrint(
          '✨ [EnrollmentService] enrollment ID 자동 생성: ${enrollmentToCreate.id}',
        );
      }

      await _createEnrollmentDirect(enrollmentToCreate);

      debugPrint(
        '✅ [EnrollmentService] enrollment 생성 완료: ${enrollmentToCreate.id}',
      );
      return enrollmentToCreate;
    } catch (e) {
      debugPrint('❌ [EnrollmentService] enrollment 생성 실패: $e');
      return null;
    }
  }

  /// Enrollment 업데이트
  ///
  /// [enrollment] 업데이트할 enrollment 객체
  ///
  /// Returns: 업데이트 성공 여부
  Future<bool> updateEnrollment(CourseEnrollment enrollment) async {
    try {
      debugPrint('🔥 [EnrollmentService] enrollment 업데이트 시작');
      debugPrint('🔥 [EnrollmentService] enrollmentId: ${enrollment.id}');
      debugPrint('🔥 [EnrollmentService] userId: ${enrollment.userId}');
      debugPrint('🔥 [EnrollmentService] courseId: ${enrollment.courseId}');
      debugPrint(
        '🔥 [EnrollmentService] remainingReservations: ${enrollment.remainingReservations}',
      );
      debugPrint('🔥 [EnrollmentService] validFrom: ${enrollment.validFrom}');
      debugPrint('🔥 [EnrollmentService] validUntil: ${enrollment.validUntil}');

      await _updateEnrollmentDirect(enrollment);

      debugPrint('✅ [EnrollmentService] enrollment 업데이트 완료: ${enrollment.id}');
      return true;
    } catch (e) {
      debugPrint('❌ [EnrollmentService] enrollment 업데이트 실패: $e');
      return false;
    }
  }

  /// 멤버에게 코스 등록 (여러 코스 일괄 등록)
  ///
  /// [userId] 사용자 ID
  /// [placeId] 플레이스 ID
  /// [courseEnrollments] 코스별 등록 설정 목록 (courseId, totalReservations, validFrom, validUntil, adminDisplayName 포함 가능)
  /// [courses] 코스 목록 (검증 및 기본값 사용)
  /// [adminDisplayName] 관리자 표시 이름 (enrollment 저장 시 사용, 누락 방지)
  ///
  /// Returns: 등록 성공 여부
  Future<bool> enrollMemberToCourses({
    required String userId,
    required String placeId,
    required List<Map<String, dynamic>> courseEnrollments,
    required List<dynamic> courses, // Course 객체 리스트
    String? adminDisplayName,
  }) async {
    try {
      debugPrint('🔥 [EnrollmentService] 멤버 코스 등록 시작');
      debugPrint('🔥 [EnrollmentService] userId: $userId, placeId: $placeId');
      debugPrint('🔥 [EnrollmentService] 코스 개수: ${courseEnrollments.length}');

      final now = TimezoneUtils.getSeoulDateTime();
      int successCount = 0;
      int failCount = 0;

      for (final courseEnrollmentData in courseEnrollments) {
        try {
          final courseId = courseEnrollmentData['courseId'] as String;
          debugPrint('📚 [EnrollmentService] 코스 등록 처리: $courseId');

          // 코스 찾기
          final course = courses.firstWhere(
            (c) => (c as dynamic).id == courseId,
            orElse: () => throw Exception('코스를 찾을 수 없습니다: $courseId'),
          );
          final courseName = (course as dynamic).name;
          final defaultTotalReservations =
              (course as dynamic).defaultTotalReservations ?? 0;
          debugPrint('✅ [EnrollmentService] 코스 확인: $courseName ($courseId)');

          // 설정값 추출
          final totalReservations =
              courseEnrollmentData['totalReservations'] as int? ??
              defaultTotalReservations;

          // validFrom = 등록 시점(enrolledAt)과 동일하게 유지
          final DateTime validFrom = now;
          DateTime validUntil;
          if (courseEnrollmentData['validUntil'] != null) {
            validUntil = DateTime.parse(
              courseEnrollmentData['validUntil'] as String,
            );
            validUntil = TimezoneUtils.getSeoulEndOfDay(validUntil);
            debugPrint('📅 [EnrollmentService] validUntil 설정값 사용 (validFrom=등록 시점)');
          } else {
            validUntil = TimezoneUtils.getSeoulEndOfDay(
              now.add(const Duration(days: 365)),
            );
            debugPrint('📅 [EnrollmentService] 유효기간 기본값 사용 (validFrom=등록 시점)');
          }

          // 유효성 검사
          if (totalReservations < 0 || validUntil.isBefore(validFrom)) {
            debugPrint(
              '❌ [EnrollmentService] 유효하지 않은 설정: totalReservations=$totalReservations, validFrom=$validFrom, validUntil=$validUntil',
            );
            failCount++;
            continue;
          }

          // ✅ 고정 ID로 중복 생성 방지
          final enrollmentId = '${userId}_${placeId}_$courseId';

          // adminDisplayName: courseEnrollments 항목 또는 메서드 인자 사용 (누락 방지)
          final displayName =
              (courseEnrollmentData['adminDisplayName'] as String?)?.trim() ??
              (adminDisplayName ?? '').trim();
          final enrollment = CourseEnrollment(
            id: enrollmentId,
            userId: userId,
            courseId: courseId,
            placeId: placeId,
            userName: displayName,
            adminDisplayName: displayName,
            enrolledAt: now,
            totalEnrollmentCount: 1,
            validFrom: validFrom,
            validUntil: validUntil,
            totalReservations: totalReservations,
            remainingReservations: totalReservations,
          );

          debugPrint('✨ [EnrollmentService] enrollment 생성: ${enrollment.id}');
          await _createEnrollmentDirect(enrollment);
          successCount++;
          debugPrint('✅ [EnrollmentService] enrollment 생성 완료');
        } catch (e) {
          debugPrint('❌ [EnrollmentService] 코스 등록 실패: $e');
          failCount++;
        }
      }

      debugPrint(
        '✅ [EnrollmentService] 멤버 코스 등록 완료: 성공 $successCount개, 실패 $failCount개',
      );
      return failCount == 0;
    } catch (e) {
      debugPrint('❌ [EnrollmentService] 멤버 코스 등록 실패: $e');
      return false;
    }
  }

  // ==================== Firestore 직접 접근 메서드 ====================

  /// 등록 정보 생성 (Firestore 직접 접근)
  /// ✅ 트랜잭션으로 원자적 저장 보장 (enrollment 문서 + 서브컬렉션 모두 성공하거나 모두 실패)
  Future<CourseEnrollment> _createEnrollmentDirect(
    CourseEnrollment enrollment,
  ) async {
    final docRef = _firestore.collection('enrollments').doc(enrollment.id);
    // 수강 유효기간: validFrom = 등록 시점 그대로, validUntil = 마감일 23:59:59로 저장
    final validUntil = TimezoneUtils.getSeoulEndOfDay(enrollment.validUntil);
    final json = enrollment.toJson();

    // DateTime 필드를 Timestamp로 변환
    json['enrolledAt'] = _dateTimeToTimestamp(enrollment.enrolledAt);
    json['validFrom'] = _dateTimeToTimestamp(enrollment.validFrom);
    json['validUntil'] = _dateTimeToTimestamp(validUntil);

    // ✅ 트랜잭션으로 원자적 저장 (enrollment 문서 + 서브컬렉션 모두 성공하거나 모두 실패)
    await _firestore.runTransaction((transaction) async {
      // ✅ 트랜잭션 내부에서 중복 확인 (race condition 방지)
      final existing = await transaction.get(docRef);
      if (existing.exists) {
        throw Exception('Enrollment already exists: ${enrollment.id}');
      }

      // enrollment 문서 저장 (액션 히스토리는 actionHistory 서브컬렉션에 온디멘드 저장)
      transaction.set(docRef, json);
    });
    await FirestoreUtils.waitForServerAck();

    return enrollment;
  }

  /// 등록 정보 업데이트 (Firestore 직접 접근)
  /// 주의: 히스토리 데이터는 서브컬렉션에 저장되므로 이 메서드에서는 기본 정보만 업데이트
  Future<CourseEnrollment> _updateEnrollmentDirect(
    CourseEnrollment enrollment,
  ) async {
    final docRef = _firestore.collection('enrollments').doc(enrollment.id);
    // 수강 유효기간: validFrom = 등록 시점 그대로, validUntil = 마감일 23:59:59로 저장
    final validUntil = TimezoneUtils.getSeoulEndOfDay(enrollment.validUntil);
    final json = enrollment.toJson();

    // DateTime 필드를 Timestamp로 변환
    json['enrolledAt'] = _dateTimeToTimestamp(enrollment.enrolledAt);
    json['validFrom'] = _dateTimeToTimestamp(enrollment.validFrom);
    json['validUntil'] = _dateTimeToTimestamp(validUntil);

    // enrollment 문서 업데이트 (기본 정보만)
    await docRef.update(json);
    await FirestoreUtils.waitForServerAck();
    return enrollment;
  }

  /// 리버트 시 Firestore 로컬 캐시·펜딩 큐를 원래 enrollment로 덮어씁니다.
  /// (큐에서 실패한 쓰기를 "제거"하는 API는 없으므로, 같은 문서에 이전 값으로 다시 씀)
  Future<void> overwriteEnrollmentForRevert(CourseEnrollment oldEnrollment) async {
    final docRef = _firestore.collection('enrollments').doc(oldEnrollment.id);
    final validUntil = TimezoneUtils.getSeoulEndOfDay(oldEnrollment.validUntil);
    final json = Map<String, dynamic>.from(oldEnrollment.toJson());
    json['enrolledAt'] = _dateTimeToTimestamp(oldEnrollment.enrolledAt);
    json['validFrom'] = _dateTimeToTimestamp(oldEnrollment.validFrom);
    json['validUntil'] = _dateTimeToTimestamp(validUntil);
    await FirestoreUtils.overwritePendingWrite(docRef, json);
  }

  /// 재등록: enrollment 업데이트 + actionHistory에 액션 1건 추가
  Future<void> reenrollWithHistory({
    required CourseEnrollment updatedEnrollment,
    required EnrollmentAction action,
  }) async {
    await _updateEnrollmentDirect(updatedEnrollment);
    await addActionToHistory(updatedEnrollment.id, action);
  }

  /// enrollment 업데이트 + actionHistory에 액션 1건 추가
  Future<void> updateEnrollmentWithAdminAction({
    required CourseEnrollment updatedEnrollment,
    required EnrollmentAction action,
  }) async {
    await _updateEnrollmentDirect(updatedEnrollment);
    await addActionToHistory(updatedEnrollment.id, action);
  }

  /// 수강 취소: enrollment 업데이트 + actionHistory에 액션 1건 추가
  Future<void> cancelEnrollmentWithHistory({
    required CourseEnrollment updatedEnrollment,
    required EnrollmentAction action,
  }) async {
    await _updateEnrollmentDirect(updatedEnrollment);
    await addActionToHistory(updatedEnrollment.id, action);
  }

  /// 코스 등록(수강) 취소 (Cloud Function 호출, 관리자)
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

  /// 사용자별 등록 정보 조회
  /// [placeId]가 제공되면 해당 플레이스의 enrollments만 필터링 (서버 사이드 필터링)
  Stream<List<CourseEnrollment>> watchUserEnrollments(
    String userId, {
    String? placeId,
  }) {
    var query = _firestore
        .collection('enrollments')
        .where('userId', isEqualTo: userId);

    // placeId가 제공되면 서버 사이드 필터링 추가
    if (placeId != null) {
      query = query.where('placeId', isEqualTo: placeId);
    }

    return query.snapshots().map((snapshot) {
      return snapshot.docs.map(_courseEnrollmentFromDoc).toList();
    });
  }

  /// 특정 userId 목록의 enrollments만 구독. 최대 30명(whereIn 한도).
  Stream<List<CourseEnrollment>> watchEnrollmentsForUserIds(
    String placeId,
    List<String> userIds,
  ) {
    if (placeId.isEmpty || userIds.isEmpty) return Stream.value([]);
    final ids = userIds.toSet().where((s) => s.isNotEmpty).take(30).toList();
    if (ids.isEmpty) return Stream.value([]);

    return _firestore
        .collection('enrollments')
        .where('placeId', isEqualTo: placeId)
        .where('userId', whereIn: ids)
        .snapshots()
        .map(
          (s) => s.docs.map(_courseEnrollmentFromDoc).toList(),
        );
  }

  /// 플레이스별 전체 enrollments 구독 (멤버관리 통합 뷰용) — 비용 높음, watchEnrollmentsForUserIds 권장
  Stream<List<CourseEnrollment>> watchEnrollmentsByPlace(String placeId) {
    if (placeId.isEmpty) return Stream.value([]);
    return _firestore
        .collection('enrollments')
        .where('placeId', isEqualTo: placeId)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs.map(_courseEnrollmentFromDoc).toList(),
        );
  }

  /// 플레이스별 멤버 userId 목록 (enrollment 단일 소스 — placeMemberships 미사용)
  Stream<List<String>> watchPlaceMemberUserIds(String placeId) {
    return _firestore
        .collection('enrollments')
        .where('placeId', isEqualTo: placeId)
        .snapshots()
        .map((snapshot) {
          final userIds = <String>{};
          for (final doc in snapshot.docs) {
            final uid = doc.data()['userId'] as String?;
            if (uid != null && uid.isNotEmpty) userIds.add(uid);
          }
          return userIds.toList();
        });
  }

  /// 플레이스별 관리자 표시 이름 맵 (enrollment.adminDisplayName)
  Stream<Map<String, String>> watchEnrollmentAdminDisplayNamesByPlace(
    String placeId,
  ) {
    return _firestore
        .collection('enrollments')
        .where('placeId', isEqualTo: placeId)
        .snapshots()
        .map((snapshot) {
          final map = <String, String>{};
          for (final doc in snapshot.docs) {
            final data = doc.data();
            final userId = data['userId'] as String?;
            final name =
                data['adminDisplayName'] as String? ??
                data['displayName'] as String?;
            if (userId == null || userId.isEmpty) continue;
            final trimmed = (name ?? '').trim();
            if (trimmed.isNotEmpty && !map.containsKey(userId)) {
              map[userId] = trimmed;
            }
          }
          return map;
        });
  }

  /// (userId, placeId)의 모든 enrollment에 adminDisplayName 일괄 업데이트
  Future<void> updateAdminDisplayNameForUserInPlace(
    String placeId,
    String userId,
    String adminDisplayName,
  ) async {
    final snapshot =
        await _firestore
            .collection('enrollments')
            .where('userId', isEqualTo: userId)
            .where('placeId', isEqualTo: placeId)
            .get();
    final batch = _firestore.batch();
    for (final doc in snapshot.docs) {
      batch.update(doc.reference, {'adminDisplayName': adminDisplayName});
    }
    if (snapshot.docs.isNotEmpty) {
      await batch.commit();
    }
  }

  /// 연장 요청 기능 제거됨. 호환용 빈 스트림.
  Stream<List<CourseEnrollment>> watchExtensionRequests(String placeId) =>
      Stream.value(const <CourseEnrollment>[]);

  /// 연장 요청 기능 제거됨. 호환용 빈 스트림.
  Stream<List<CourseEnrollment>> watchExtensionRequestsByCourseIds({
    required List<String> courseIds,
    String? placeId,
  }) => Stream.value(const <CourseEnrollment>[]);

  /// enrollment 문서 삭제 전에 actionHistory 서브컬렉션 삭제 (고아 문서 방지)
  Future<void> _deleteActionHistoryForEnrollment(
    DocumentReference enrollmentRef,
  ) async {
    const batchSize = 400;
    while (true) {
      final snap =
          await enrollmentRef
              .collection('actionHistory')
              .limit(batchSize)
              .get();
      if (snap.docs.isEmpty) return;
      final batch = _firestore.batch();
      for (final doc in snap.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();
      if (snap.docs.length < batchSize) return;
    }
  }

  /// 코스별 enrollments 삭제 (페이지네이션 사용)
  ///
  /// 대규모 데이터(10,000명 이상)도 메모리 효율적으로 처리합니다.
  /// 페이지네이션을 사용하여 작은 단위로 나눠서 조회하고 삭제합니다.
  /// 각 enrollment의 actionHistory 서브컬렉션을 먼저 삭제한 뒤 enrollment를 삭제합니다.
  Future<void> deleteEnrollmentsByCourse(
    String placeId,
    String courseId,
  ) async {
    const pageSize = 500; // 한 번에 조회할 문서 수
    DocumentSnapshot? lastDoc;
    int totalDeleted = 0;

    while (true) {
      // 페이지네이션 쿼리
      var query = _firestore
          .collection('enrollments')
          .where('courseId', isEqualTo: courseId)
          .where('placeId', isEqualTo: placeId)
          .limit(pageSize);

      // 이전 페이지의 마지막 문서부터 시작
      if (lastDoc != null) {
        query = query.startAfterDocument(lastDoc);
      }

      final snapshot = await query.get();

      // 더 이상 문서가 없으면 종료
      if (snapshot.docs.isEmpty) {
        break;
      }

      // 각 enrollment의 actionHistory 서브컬렉션 먼저 삭제
      for (final doc in snapshot.docs) {
        await _deleteActionHistoryForEnrollment(doc.reference);
      }

      // 배치 삭제 (Firestore 배치는 최대 500개까지)
      final batch = _firestore.batch();
      for (var doc in snapshot.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();

      totalDeleted += snapshot.docs.length;
      debugPrint(
        '🗑️ [EnrollmentService] 코스 enrollments 삭제 진행: $totalDeleted개 삭제됨',
      );

      // 마지막 문서 저장 (다음 페이지를 위해)
      lastDoc = snapshot.docs.last;

      // 마지막 페이지인 경우 종료
      if (snapshot.docs.length < pageSize) {
        break;
      }
    }

    debugPrint('✅ [EnrollmentService] 코스 enrollments 삭제 완료: 총 $totalDeleted개');
  }

  /// 특정 사용자와 플레이스의 모든 enrollments 삭제 (페이지네이션 사용)
  ///
  /// 멤버 삭제 시 해당 멤버의 모든 코스 등록 정보를 삭제합니다.
  /// 대규모 데이터(10,000명 이상)도 메모리 효율적으로 처리합니다.
  /// 페이지네이션을 사용하여 작은 단위로 나눠서 조회하고 삭제합니다.
  /// 각 enrollment의 actionHistory 서브컬렉션을 먼저 삭제한 뒤 enrollment를 삭제합니다.
  Future<void> deleteEnrollmentsByUserAndPlace(
    String userId,
    String placeId,
  ) async {
    const pageSize = 500; // 한 번에 조회할 문서 수
    DocumentSnapshot? lastDoc;
    int totalDeleted = 0;

    while (true) {
      // 페이지네이션 쿼리
      var query = _firestore
          .collection('enrollments')
          .where('userId', isEqualTo: userId)
          .where('placeId', isEqualTo: placeId)
          .limit(pageSize);

      // 이전 페이지의 마지막 문서부터 시작
      if (lastDoc != null) {
        query = query.startAfterDocument(lastDoc);
      }

      final snapshot = await query.get();

      // 더 이상 문서가 없으면 종료
      if (snapshot.docs.isEmpty) {
        break;
      }

      // 각 enrollment의 actionHistory 서브컬렉션 먼저 삭제
      for (final doc in snapshot.docs) {
        await _deleteActionHistoryForEnrollment(doc.reference);
      }

      // 배치 삭제 (Firestore 배치는 최대 500개까지)
      final batch = _firestore.batch();
      for (var doc in snapshot.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();

      totalDeleted += snapshot.docs.length;
      debugPrint(
        '🗑️ [EnrollmentService] 멤버 enrollments 삭제 진행: $totalDeleted개 삭제됨',
      );

      // 마지막 문서 저장 (다음 페이지를 위해)
      lastDoc = snapshot.docs.last;

      // 마지막 페이지인 경우 종료
      if (snapshot.docs.length < pageSize) {
        break;
      }
    }

    debugPrint(
      '✅ [EnrollmentService] 멤버 enrollments 삭제 완료: 총 $totalDeleted개 (userId: $userId, placeId: $placeId)',
    );
  }

  /// 코스별 등록 조회 (enrollments 단일 소스)
  Stream<List<CourseEnrollment>> watchCourseMembers({
    required String courseId,
    String? placeId,
    bool? isActive,
  }) {
    final normalizedCourseId = courseId.trim();
    if (normalizedCourseId.isEmpty) {
      return Stream.value(const <CourseEnrollment>[]);
    }

    var query = _firestore
        .collection('enrollments')
        .where('courseId', isEqualTo: normalizedCourseId);

    if (placeId != null && placeId.trim().isNotEmpty) {
      query = query.where('placeId', isEqualTo: placeId.trim());
    }

    return query.snapshots().map((snapshot) {
      if (kDebugMode) {
        debugPrint(
          '[EnrollmentService] watchCourseMembers courseId=$normalizedCourseId '
          'placeId=$placeId docs=${snapshot.docs.length}',
        );
      }
      final list = snapshot.docs.map(_courseEnrollmentFromDoc).toList();
      if (isActive == null) return list;
      final now = TimezoneUtils.getSeoulDateTime();
      return list.where((e) {
        final active =
            e.validFrom.isBefore(now) &&
            e.validUntil.isAfter(now) &&
            e.remainingReservations > 0;
        return active == isActive;
      }).toList();
    });
  }

  /// 플레이스별 등록 조회 (enrollments 단일 소스)
  Stream<List<CourseEnrollment>> watchPlaceCourseMembers({
    required String placeId,
    String? courseId,
    bool? isActive,
  }) {
    var query = _firestore
        .collection('enrollments')
        .where('placeId', isEqualTo: placeId);

    if (courseId != null && courseId.trim().isNotEmpty) {
      query = query.where('courseId', isEqualTo: courseId.trim());
    }

    return query.snapshots().map((snapshot) {
      final list = snapshot.docs.map(_courseEnrollmentFromDoc).toList();
      if (isActive == null) return list;
      return list.where((e) => e.canReserve == isActive).toList();
    });
  }

  // ==================== 액션 히스토리 (actionHistory만 사용) ====================
  // addActionToHistory, watchActionHistory 위에 정의됨.

  // (재등록 이력·연장 요청 메서드 제거됨 — actionHistory로 통일)
}
