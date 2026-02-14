import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/course_enrollment.dart';
import '../models/course_member.dart';
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
    data['enrolledAt'] = _timestampToDateTime(
      data['enrolledAt'],
    ).toIso8601String();
    data['validFrom'] = _timestampToDateTime(
      data['validFrom'],
    ).toIso8601String();
    data['validUntil'] = _timestampToDateTime(
      data['validUntil'],
    ).toIso8601String();

    // extensionRequests의 timestamp 변환
    if (data['extensionRequests'] != null) {
      final requests = data['extensionRequests'] as List;
      for (var i = 0; i < requests.length; i++) {
        final request = requests[i] as Map<String, dynamic>;
        request['requestedAt'] = _timestampToDateTime(
          request['requestedAt'],
        ).toIso8601String();
        if (request['approvedAt'] != null) {
          request['approvedAt'] = _timestampToDateTime(
            request['approvedAt'],
          ).toIso8601String();
        }
        if (request['rejectedAt'] != null) {
          request['rejectedAt'] = _timestampToDateTime(
            request['rejectedAt'],
          ).toIso8601String();
        }
      }
    }

    // 하위 호환성: extensionRequest도 변환
    // 서브컬렉션 사용 시 denormalized 필드 extensionRequest를 extensionRequests 배열로 변환
    if (data['extensionRequest'] != null) {
      final request = data['extensionRequest'] as Map<String, dynamic>;
      // id 필드가 없으면 추가 (denormalized 필드에는 id가 있을 수 있음)
      if (request['id'] == null) {
        request['id'] = 'req_${DateTime.now().millisecondsSinceEpoch}';
      }
      request['requestedAt'] = _timestampToDateTime(
        request['requestedAt'],
      ).toIso8601String();
      if (request['approvedAt'] != null) {
        request['approvedAt'] = _timestampToDateTime(
          request['approvedAt'],
        ).toIso8601String();
      }
      if (request['rejectedAt'] != null) {
        request['rejectedAt'] = _timestampToDateTime(
          request['rejectedAt'],
        ).toIso8601String();
      }

      // extensionRequest가 있으면 extensionRequests 배열에 추가 (서브컬렉션 대신 denormalized 필드 사용)
      // fromJson에서 extensionRequest를 extensionRequests로 변환하지만, 둘 다 있을 때를 대비해 여기서도 처리
      if (data['extensionRequests'] == null) {
        data['extensionRequests'] = [request];
      } else {
        // 이미 배열이 있으면 합치기 (중복 제거)
        final existing = data['extensionRequests'] as List;
        final requestId = request['id'] as String?;
        if (requestId != null &&
            !existing.any((r) => (r as Map)['id'] == requestId)) {
          existing.add(request);
        }
      }
    }

    return CourseEnrollment.fromJson(data);
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
  /// [courseEnrollments] 코스별 등록 설정 목록 (courseId, totalReservations, validFrom, validUntil 포함)
  /// [courses] 코스 목록 (검증 및 기본값 사용)
  ///
  /// Returns: 등록 성공 여부
  Future<bool> enrollMemberToCourses({
    required String userId,
    required String placeId,
    required List<Map<String, dynamic>> courseEnrollments,
    required List<dynamic> courses, // Course 객체 리스트
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

          DateTime validFrom;
          DateTime validUntil;
          if (courseEnrollmentData['validFrom'] != null &&
              courseEnrollmentData['validUntil'] != null) {
            validFrom = DateTime.parse(
              courseEnrollmentData['validFrom'] as String,
            );
            validUntil = DateTime.parse(
              courseEnrollmentData['validUntil'] as String,
            );
            debugPrint('📅 [EnrollmentService] 유효기간 설정값 사용');
          } else {
            validFrom = now;
            validUntil = now.add(const Duration(days: 365));
            debugPrint('📅 [EnrollmentService] 유효기간 기본값 사용');
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

          final enrollment = CourseEnrollment(
            id: enrollmentId,
            userId: userId,
            courseId: courseId,
            placeId: placeId,
            enrolledAt: now, // 현재 등록일
            totalEnrollmentCount: 1, // 첫 등록
            validFrom: validFrom,
            validUntil: validUntil,
            totalReservations: totalReservations,
            remainingReservations: totalReservations,
            reenrollmentHistory: [
              ReenrollmentRecord(
                enrollmentNumber: 1,
                totalReservations: totalReservations,
                enrolledAt: now,
                validFrom: validFrom,
                validUntil: validUntil,
              ),
            ],
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
    final json = enrollment.toJson();

    // DateTime 필드를 Timestamp로 변환
    json['enrolledAt'] = _dateTimeToTimestamp(enrollment.enrolledAt);
    json['validFrom'] = _dateTimeToTimestamp(enrollment.validFrom);
    json['validUntil'] = _dateTimeToTimestamp(enrollment.validUntil);

    // 히스토리 데이터는 서브컬렉션에 저장하므로 문서에서 제거
    json.remove('reenrollmentHistory');
    json.remove('adminActions');
    json.remove('extensionRequests');
    json.remove('extensionRequest'); // 하위 호환성 필드도 제거

    // ✅ 트랜잭션으로 원자적 저장 (enrollment 문서 + 서브컬렉션 모두 성공하거나 모두 실패)
    await _firestore.runTransaction((transaction) async {
      // ✅ 트랜잭션 내부에서 중복 확인 (race condition 방지)
      final existing = await transaction.get(docRef);
      if (existing.exists) {
        throw Exception('Enrollment already exists: ${enrollment.id}');
      }

      // enrollment 문서 저장
      transaction.set(docRef, json);

      // 재등록 이력 저장
      for (final record in enrollment.reenrollmentHistory) {
        final recordRef = docRef.collection('reenrollmentHistory').doc();
        transaction.set(recordRef, {
          'enrollmentNumber': record.enrollmentNumber,
          'totalReservations': record.totalReservations,
          'enrolledAt': _dateTimeToTimestamp(record.enrolledAt),
          'validFrom': _dateTimeToTimestamp(record.validFrom),
          'validUntil': _dateTimeToTimestamp(record.validUntil),
          'cancelledAt': record.cancelledAt != null
              ? _dateTimeToTimestamp(record.cancelledAt!)
              : null,
        });
      }

      // 관리자 액션 저장
      for (final action in enrollment.adminActions) {
        final actionRef = docRef.collection('adminActions').doc(action.id);
        transaction.set(actionRef, {
          'actionType': action.actionType.name,
          'performedAt': _dateTimeToTimestamp(action.performedAt),
          'performedBy': action.performedBy,
          'details': action.details,
          'oldValue': action.oldValue,
          'newValue': action.newValue,
        });
      }

      // 연장 요청 저장
      for (final request in enrollment.extensionRequests) {
        final requestRef = docRef
            .collection('extensionRequests')
            .doc(request.id);
        transaction.set(requestRef, {
          'requestedAt': _dateTimeToTimestamp(request.requestedAt),
          'reason': request.reason,
          'status': request.status.name,
          'approvedAt': request.approvedAt != null
              ? _dateTimeToTimestamp(request.approvedAt!)
              : null,
          'rejectedAt': request.rejectedAt != null
              ? _dateTimeToTimestamp(request.rejectedAt!)
              : null,
          'rejectionReason': request.rejectionReason,
        });
      }
    });

    return enrollment;
  }

  /// 등록 정보 업데이트 (Firestore 직접 접근)
  /// 주의: 히스토리 데이터는 서브컬렉션에 저장되므로 이 메서드에서는 기본 정보만 업데이트
  Future<CourseEnrollment> _updateEnrollmentDirect(
    CourseEnrollment enrollment,
  ) async {
    final docRef = _firestore.collection('enrollments').doc(enrollment.id);
    final json = enrollment.toJson();

    // DateTime 필드를 Timestamp로 변환
    json['enrolledAt'] = _dateTimeToTimestamp(enrollment.enrolledAt);
    json['validFrom'] = _dateTimeToTimestamp(enrollment.validFrom);
    json['validUntil'] = _dateTimeToTimestamp(enrollment.validUntil);

    // 히스토리 데이터는 서브컬렉션에 저장하므로 문서에서 제거
    json.remove('reenrollmentHistory');
    json.remove('adminActions');
    json.remove('extensionRequests');
    json.remove('extensionRequest'); // 하위 호환성 필드도 제거
    json.remove('reenrollmentRequests'); // 배열은 서브컬렉션에 저장
    json.remove('reenrollmentRequest'); // marker도 제거

    // enrollment 문서 업데이트 (기본 정보만)
    await docRef.update(json);
    return enrollment;
  }

  /// 재등록 처리 (트랜잭션으로 원자적 저장)
  ///
  /// enrollment 업데이트 + 재등록 이력 2개 추가 + 관리자 액션 추가를 하나의 트랜잭션으로 처리
  /// 재등록은 관리자만 처리할 수 있음
  ///
  /// [extensionRequestUpdate]가 제공되면 연장 요청 상태도 함께 업데이트 (원자적 처리)
  Future<void> reenrollWithHistory({
    required CourseEnrollment updatedEnrollment,
    required ReenrollmentRecord oldRecord, // 기존 등록 정보
    required ReenrollmentRecord newRecord, // 새 재등록 정보
    required AdminAction adminAction,
    ExtensionRequestUpdate? extensionRequestUpdate,
  }) async {
    await _firestore.runTransaction((transaction) async {
      final docRef = _firestore
          .collection('enrollments')
          .doc(updatedEnrollment.id);

      // ⚠️ 중요: Firestore 트랜잭션 규칙 - 모든 읽기를 먼저 수행해야 함
      // 1. 모든 읽기 작업 먼저 수행
      DocumentSnapshot? requestSnap;
      DocumentSnapshot? enrollmentSnap;

      if (extensionRequestUpdate != null) {
        final requestRef = docRef
            .collection('extensionRequests')
            .doc(extensionRequestUpdate.requestId);

        // 연장 요청 문서 읽기
        requestSnap = await transaction.get(requestRef);
        if (!requestSnap.exists) {
          throw Exception(
            'Extension request not found: ${extensionRequestUpdate.requestId}',
          );
        }

        // 동시성 문제 해결: 현재 상태가 pending인지 확인
        final requestData = requestSnap.data() as Map<String, dynamic>;
        final currentStatus = requestData['status'] as String?;
        if (currentStatus != ExtensionRequestStatus.pending.name) {
          throw Exception(
            'Extension request is not pending. Current status: $currentStatus',
          );
        }

        // enrollment 문서 읽기 (denormalized marker 확인용)
        enrollmentSnap = await transaction.get(docRef);
      }

      // 2. 모든 쓰기 작업 수행
      // enrollment 문서 업데이트
      final json = updatedEnrollment.toJson();
      json['enrolledAt'] = _dateTimeToTimestamp(updatedEnrollment.enrolledAt);
      json['validFrom'] = _dateTimeToTimestamp(updatedEnrollment.validFrom);
      json['validUntil'] = _dateTimeToTimestamp(updatedEnrollment.validUntil);
      json.remove('reenrollmentHistory');
      json.remove('adminActions');
      json.remove('extensionRequests');
      json.remove('extensionRequest');
      json.remove('reenrollmentRequests');
      json.remove('reenrollmentRequest');

      transaction.update(docRef, json);

      // 기존 등록 정보를 히스토리에 추가
      final oldRecordRef = docRef.collection('reenrollmentHistory').doc();
      transaction.set(oldRecordRef, {
        'enrollmentNumber': oldRecord.enrollmentNumber,
        'totalReservations': oldRecord.totalReservations,
        'enrolledAt': _dateTimeToTimestamp(oldRecord.enrolledAt),
        'validFrom': _dateTimeToTimestamp(oldRecord.validFrom),
        'validUntil': _dateTimeToTimestamp(oldRecord.validUntil),
        'cancelledAt': oldRecord.cancelledAt != null
            ? _dateTimeToTimestamp(oldRecord.cancelledAt!)
            : null,
      });

      // 새 재등록 정보를 히스토리에 추가
      final newRecordRef = docRef.collection('reenrollmentHistory').doc();
      transaction.set(newRecordRef, {
        'enrollmentNumber': newRecord.enrollmentNumber,
        'totalReservations': newRecord.totalReservations,
        'enrolledAt': _dateTimeToTimestamp(newRecord.enrolledAt),
        'validFrom': _dateTimeToTimestamp(newRecord.validFrom),
        'validUntil': _dateTimeToTimestamp(newRecord.validUntil),
        'cancelledAt': newRecord.cancelledAt != null
            ? _dateTimeToTimestamp(newRecord.cancelledAt!)
            : null,
      });

      // 관리자 액션 추가
      final actionRef = docRef.collection('adminActions').doc(adminAction.id);
      transaction.set(actionRef, {
        'actionType': adminAction.actionType.name,
        'performedAt': _dateTimeToTimestamp(adminAction.performedAt),
        'performedBy': adminAction.performedBy,
        'details': adminAction.details,
        'oldValue': adminAction.oldValue,
        'newValue': adminAction.newValue,
      });

      // 연장 요청 상태 업데이트 (제공된 경우)
      if (extensionRequestUpdate != null && requestSnap != null) {
        final requestRef = docRef
            .collection('extensionRequests')
            .doc(extensionRequestUpdate.requestId);

        final now = TimezoneUtils.getSeoulDateTime();
        final updateMap = <String, dynamic>{
          'status': extensionRequestUpdate.status.name,
          'approvedAt':
              extensionRequestUpdate.status == ExtensionRequestStatus.approved
              ? _dateTimeToTimestamp(now)
              : null,
          'rejectedAt':
              extensionRequestUpdate.status == ExtensionRequestStatus.rejected
              ? _dateTimeToTimestamp(now)
              : null,
          'rejectionReason':
              extensionRequestUpdate.status == ExtensionRequestStatus.rejected
              ? extensionRequestUpdate.rejectionReason
              : null,
        };
        transaction.update(requestRef, updateMap);

        // denormalized marker도 업데이트 (이미 읽은 enrollmentSnap 사용)
        if (enrollmentSnap != null && enrollmentSnap.exists) {
          final data = enrollmentSnap.data() as Map<String, dynamic>?;
          if (data != null) {
            final marker = data['extensionRequest'];
            final markerId = marker is Map ? marker['id']?.toString() : null;
            if (markerId == extensionRequestUpdate.requestId) {
              transaction.update(docRef, {
                'extensionRequest': {
                  ...(marker as Map<String, dynamic>).map(
                    (k, v) => MapEntry(k.toString(), v),
                  ),
                  'status': extensionRequestUpdate.status.name,
                  'approvedAt': updateMap['approvedAt'],
                  'rejectedAt': updateMap['rejectedAt'],
                  'rejectionReason': updateMap['rejectionReason'],
                },
              });
            }
          }
        }
      }
    });
  }

  /// enrollment 업데이트 + 관리자 액션 추가 (트랜잭션)
  ///
  /// [extensionRequestUpdate]가 제공되면 연장 요청 상태도 함께 업데이트 (원자적 처리)
  Future<void> updateEnrollmentWithAdminAction({
    required CourseEnrollment updatedEnrollment,
    required AdminAction adminAction,
    ExtensionRequestUpdate? extensionRequestUpdate,
  }) async {
    await _firestore.runTransaction((transaction) async {
      final docRef = _firestore
          .collection('enrollments')
          .doc(updatedEnrollment.id);

      // ⚠️ 중요: Firestore 트랜잭션 규칙 - 모든 읽기를 먼저 수행해야 함
      // 1. 모든 읽기 작업 먼저 수행
      DocumentSnapshot? requestSnap;
      DocumentSnapshot? enrollmentSnap;

      if (extensionRequestUpdate != null) {
        final requestRef = docRef
            .collection('extensionRequests')
            .doc(extensionRequestUpdate.requestId);

        // 연장 요청 문서 읽기
        requestSnap = await transaction.get(requestRef);
        if (!requestSnap.exists) {
          throw Exception(
            'Extension request not found: ${extensionRequestUpdate.requestId}',
          );
        }

        // 동시성 문제 해결: 현재 상태가 pending인지 확인
        final requestData = requestSnap.data() as Map<String, dynamic>;
        final currentStatus = requestData['status'] as String?;
        if (currentStatus != ExtensionRequestStatus.pending.name) {
          throw Exception(
            'Extension request is not pending. Current status: $currentStatus',
          );
        }

        // enrollment 문서 읽기 (denormalized marker 확인용)
        enrollmentSnap = await transaction.get(docRef);
      }

      // 2. 모든 쓰기 작업 수행
      // enrollment 문서 업데이트
      final json = updatedEnrollment.toJson();
      json['enrolledAt'] = _dateTimeToTimestamp(updatedEnrollment.enrolledAt);
      json['validFrom'] = _dateTimeToTimestamp(updatedEnrollment.validFrom);
      json['validUntil'] = _dateTimeToTimestamp(updatedEnrollment.validUntil);
      json.remove('reenrollmentHistory');
      json.remove('adminActions');
      json.remove('extensionRequests');
      json.remove('extensionRequest');
      json.remove('reenrollmentRequests'); // 배열은 서브컬렉션에 저장
      json.remove('reenrollmentRequest'); // marker도 제거

      transaction.update(docRef, json);

      // 관리자 액션 추가
      final actionRef = docRef.collection('adminActions').doc(adminAction.id);
      transaction.set(actionRef, {
        'actionType': adminAction.actionType.name,
        'performedAt': _dateTimeToTimestamp(adminAction.performedAt),
        'performedBy': adminAction.performedBy,
        'details': adminAction.details,
        'oldValue': adminAction.oldValue,
        'newValue': adminAction.newValue,
      });

      // 연장 요청 상태 업데이트 (제공된 경우)
      if (extensionRequestUpdate != null && requestSnap != null) {
        final requestRef = docRef
            .collection('extensionRequests')
            .doc(extensionRequestUpdate.requestId);

        final now = TimezoneUtils.getSeoulDateTime();
        final updateMap = <String, dynamic>{
          'status': extensionRequestUpdate.status.name,
          'approvedAt':
              extensionRequestUpdate.status == ExtensionRequestStatus.approved
              ? _dateTimeToTimestamp(now)
              : null,
          'rejectedAt':
              extensionRequestUpdate.status == ExtensionRequestStatus.rejected
              ? _dateTimeToTimestamp(now)
              : null,
          'rejectionReason':
              extensionRequestUpdate.status == ExtensionRequestStatus.rejected
              ? extensionRequestUpdate.rejectionReason
              : null,
        };
        transaction.update(requestRef, updateMap);

        // denormalized marker도 업데이트 (이미 읽은 enrollmentSnap 사용)
        if (enrollmentSnap != null && enrollmentSnap.exists) {
          final data = enrollmentSnap.data() as Map<String, dynamic>?;
          if (data != null) {
            final marker = data['extensionRequest'];
            final markerId = marker is Map ? marker['id']?.toString() : null;
            if (markerId == extensionRequestUpdate.requestId) {
              transaction.update(docRef, {
                'extensionRequest': {
                  ...(marker as Map<String, dynamic>).map(
                    (k, v) => MapEntry(k.toString(), v),
                  ),
                  'status': extensionRequestUpdate.status.name,
                  'approvedAt': updateMap['approvedAt'],
                  'rejectedAt': updateMap['rejectedAt'],
                  'rejectionReason': updateMap['rejectionReason'],
                },
              });
            }
          }
        }
      }
    });
  }

  /// enrollment 업데이트 + 재등록 이력 추가 + 관리자 액션 추가 (트랜잭션)
  Future<void> cancelEnrollmentWithHistory({
    required CourseEnrollment updatedEnrollment,
    required ReenrollmentRecord cancelledRecord,
    required AdminAction adminAction,
  }) async {
    await _firestore.runTransaction((transaction) async {
      final docRef = _firestore
          .collection('enrollments')
          .doc(updatedEnrollment.id);

      // enrollment 문서 업데이트
      final json = updatedEnrollment.toJson();
      json['enrolledAt'] = _dateTimeToTimestamp(updatedEnrollment.enrolledAt);
      json['validFrom'] = _dateTimeToTimestamp(updatedEnrollment.validFrom);
      json['validUntil'] = _dateTimeToTimestamp(updatedEnrollment.validUntil);
      json.remove('reenrollmentHistory');
      json.remove('adminActions');
      json.remove('extensionRequests');
      json.remove('extensionRequest');
      json.remove('reenrollmentRequests'); // 배열은 서브컬렉션에 저장
      json.remove('reenrollmentRequest'); // marker도 제거

      transaction.update(docRef, json);

      // 취소된 재등록 이력 추가
      final recordRef = docRef.collection('reenrollmentHistory').doc();
      transaction.set(recordRef, {
        'enrollmentNumber': cancelledRecord.enrollmentNumber,
        'totalReservations': cancelledRecord.totalReservations,
        'enrolledAt': _dateTimeToTimestamp(cancelledRecord.enrolledAt),
        'validFrom': _dateTimeToTimestamp(cancelledRecord.validFrom),
        'validUntil': _dateTimeToTimestamp(cancelledRecord.validUntil),
        'cancelledAt': cancelledRecord.cancelledAt != null
            ? _dateTimeToTimestamp(cancelledRecord.cancelledAt!)
            : null,
      });

      // 관리자 액션 추가
      final actionRef = docRef.collection('adminActions').doc(adminAction.id);
      transaction.set(actionRef, {
        'actionType': adminAction.actionType.name,
        'performedAt': _dateTimeToTimestamp(adminAction.performedAt),
        'performedBy': adminAction.performedBy,
        'details': adminAction.details,
        'oldValue': adminAction.oldValue,
        'newValue': adminAction.newValue,
      });
    });
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

  /// 연장 요청 목록 조회 (플레이스별)
  ///
  /// 연장 요청(ExtensionRequest)이 pending 상태인 enrollments를 반환합니다.
  ///
  /// 주의: 클라이언트 사이드 필터링 사용 (인덱스 불필요)
  Stream<List<CourseEnrollment>> watchExtensionRequests(String placeId) {
    return _firestore
        .collection('enrollments')
        .where('placeId', isEqualTo: placeId)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs
              .map(_courseEnrollmentFromDoc)
              .where((enrollment) => enrollment.hasPendingExtensionRequest)
              .toList();
        });
  }

  /// 연장 요청 목록 조회 (코스ID 목록 기반)
  ///
  /// enrollment 문서에 placeId 필드가 없거나 불완전한 경우에도,
  /// "해당 플레이스의 코스ID 목록"으로 요청을 안정적으로 조회할 수 있습니다.
  Stream<List<CourseEnrollment>> watchExtensionRequestsByCourseIds({
    required List<String> courseIds,
    String? placeId,
  }) {
    final normalized = courseIds.where((e) => e.isNotEmpty).toSet().toList();

    if (normalized.isEmpty) {
      return Stream.value(const <CourseEnrollment>[]);
    }

    // Firestore whereIn 최대 10개 제한
    const chunkSize = 10;
    final chunks = <List<String>>[];
    for (var i = 0; i < normalized.length; i += chunkSize) {
      chunks.add(
        normalized.sublist(
          i,
          i + chunkSize > normalized.length ? normalized.length : i + chunkSize,
        ),
      );
    }

    return Stream.multi((controller) {
      final latestByChunk = <int, List<CourseEnrollment>>{};
      final subs = <StreamSubscription>[];

      void emit() {
        final byId = <String, CourseEnrollment>{};
        for (final list in latestByChunk.values) {
          for (final e in list) {
            byId[e.id] = e;
          }
        }
        final result = byId.values.toList();
        controller.add(result);
      }

      for (var idx = 0; idx < chunks.length; idx++) {
        final chunk = chunks[idx];
        var query = _firestore
            .collection('enrollments')
            .where('courseId', whereIn: chunk);

        // placeId가 제공되면 필터링 추가
        if (placeId != null) {
          query = query.where('placeId', isEqualTo: placeId);
        }

        final sub = query.snapshots().listen((snapshot) {
          final allEnrollments = snapshot.docs
              .map(_courseEnrollmentFromDoc)
              .toList();
          final withRequests = allEnrollments
              .where((e) => e.hasPendingExtensionRequest)
              .toList();
          latestByChunk[idx] = withRequests;
          emit();
        }, onError: controller.addError);
        subs.add(sub);
      }

      controller.onCancel = () async {
        for (final s in subs) {
          await s.cancel();
        }
      };
    }, isBroadcast: true);
  }

  /// 코스별 enrollments 삭제 (페이지네이션 사용)
  ///
  /// 대규모 데이터(10,000명 이상)도 메모리 효율적으로 처리합니다.
  /// 페이지네이션을 사용하여 작은 단위로 나눠서 조회하고 삭제합니다.
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

  /// 코스별 멤버 조회 (enrollments 컬렉션 기준 — 단일 소스)
  ///
  /// [placeId]가 있으면 해당 플레이스의 enrollment만 조회합니다.
  /// 없으면 courseId만으로 조회(다중 플레이스 시 placeId 전달 권장).
  Stream<List<CourseMember>> watchCourseMembers({
    required String courseId,
    String? placeId,
    bool? isActive,
  }) {
    final normalizedCourseId = courseId.trim();
    if (normalizedCourseId.isEmpty) {
      return Stream.value(const <CourseMember>[]);
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
      return snapshot.docs.map((doc) {
        final data = doc.data();
        final id = doc.id;
        final userId = (data['userId'] ?? '').toString();
        final courseIdVal = (data['courseId'] ?? '').toString();
        final placeIdVal = (data['placeId'] ?? '').toString();
        final enrolledAt = _timestampToDateTime(data['enrolledAt']);
        return CourseMember(
          id: id,
          userId: userId,
          courseId: courseIdVal,
          placeId: placeIdVal,
          enrollmentId: id,
          enrolledAt: enrolledAt,
          isActive: true,
          createdAt: enrolledAt,
          updatedAt: null,
        );
      }).toList();
    });
  }

  /// 플레이스별 코스 멤버 조회
  Stream<List<CourseMember>> watchPlaceCourseMembers({
    required String placeId,
    String? courseId,
    bool? isActive,
  }) {
    var query =
        _firestore
                .collection('courseMembers')
                .where('placeId', isEqualTo: placeId)
            as dynamic;

    if (courseId != null) {
      query = query.where('courseId', isEqualTo: courseId);
    }

    if (isActive != null) {
      query = query.where('isActive', isEqualTo: isActive);
    }

    return (query.snapshots() as Stream<QuerySnapshot<Map<String, dynamic>>>)
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            final data = doc.data();
            data['enrolledAt'] = _timestampToDateTime(
              data['enrolledAt'],
            ).toIso8601String();
            data['createdAt'] = _timestampToDateTime(
              data['createdAt'],
            ).toIso8601String();
            if (data['updatedAt'] != null) {
              data['updatedAt'] = _timestampToDateTime(
                data['updatedAt'],
              ).toIso8601String();
            }
            return CourseMember.fromJson(data);
          }).toList();
        });
  }

  // ==================== 서브컬렉션: 재등록 이력 ====================

  /// 재등록 이력 추가 (서브컬렉션)
  Future<void> addReenrollmentRecord({
    required String enrollmentId,
    required ReenrollmentRecord record,
  }) async {
    try {
      final recordRef = _firestore
          .collection('enrollments')
          .doc(enrollmentId)
          .collection('reenrollmentHistory')
          .doc();

      await recordRef.set({
        'enrollmentNumber': record.enrollmentNumber,
        'totalReservations': record.totalReservations,
        'enrolledAt': _dateTimeToTimestamp(record.enrolledAt),
        'validFrom': _dateTimeToTimestamp(record.validFrom),
        'validUntil': _dateTimeToTimestamp(record.validUntil),
        'cancelledAt': record.cancelledAt != null
            ? _dateTimeToTimestamp(record.cancelledAt!)
            : null,
      });
    } catch (e) {
      debugPrint('❌ [EnrollmentService] 재등록 이력 추가 실패: $e');
      rethrow;
    }
  }

  /// 재등록 이력 조회 (페이지네이션 지원)
  Future<List<ReenrollmentRecord>> getReenrollmentHistory({
    required String enrollmentId,
    int limit = 20,
    DocumentSnapshot? startAfter,
  }) async {
    try {
      var query = _firestore
          .collection('enrollments')
          .doc(enrollmentId)
          .collection('reenrollmentHistory')
          .orderBy('enrolledAt', descending: true)
          .limit(limit);

      if (startAfter != null) {
        query = query.startAfterDocument(startAfter);
      }

      final snapshot = await query.get();
      return snapshot.docs.map((doc) {
        final data = doc.data();
        return ReenrollmentRecord(
          enrollmentNumber: data['enrollmentNumber'] as int,
          totalReservations: data['totalReservations'] as int,
          enrolledAt: _timestampToDateTime(data['enrolledAt']),
          validFrom: _timestampToDateTime(data['validFrom']),
          validUntil: _timestampToDateTime(data['validUntil']),
          cancelledAt: data['cancelledAt'] != null
              ? _timestampToDateTime(data['cancelledAt'])
              : null,
        );
      }).toList();
    } catch (e) {
      debugPrint('❌ [EnrollmentService] 재등록 이력 조회 실패: $e');
      return [];
    }
  }

  /// 재등록 이력 실시간 구독 (페이지네이션 지원)
  Stream<List<ReenrollmentRecord>> watchReenrollmentHistory({
    required String enrollmentId,
    int limit = 20,
  }) {
    return _firestore
        .collection('enrollments')
        .doc(enrollmentId)
        .collection('reenrollmentHistory')
        .orderBy('enrolledAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            final data = doc.data();
            return ReenrollmentRecord(
              enrollmentNumber: data['enrollmentNumber'] as int,
              totalReservations: data['totalReservations'] as int,
              enrolledAt: _timestampToDateTime(data['enrolledAt']),
              validFrom: _timestampToDateTime(data['validFrom']),
              validUntil: _timestampToDateTime(data['validUntil']),
              cancelledAt: data['cancelledAt'] != null
                  ? _timestampToDateTime(data['cancelledAt'])
                  : null,
            );
          }).toList();
        });
  }

  // ==================== 서브컬렉션: 관리자 액션 ====================

  /// 관리자 액션 추가 (서브컬렉션)
  Future<void> addAdminAction({
    required String enrollmentId,
    required AdminAction action,
  }) async {
    try {
      final actionRef = _firestore
          .collection('enrollments')
          .doc(enrollmentId)
          .collection('adminActions')
          .doc(action.id);

      await actionRef.set({
        'actionType': action.actionType.name,
        'performedAt': _dateTimeToTimestamp(action.performedAt),
        'performedBy': action.performedBy,
        'details': action.details,
        'oldValue': action.oldValue,
        'newValue': action.newValue,
      });
    } catch (e) {
      debugPrint('❌ [EnrollmentService] 관리자 액션 추가 실패: $e');
      rethrow;
    }
  }

  /// 관리자 액션 조회 (페이지네이션 지원)
  Future<List<AdminAction>> getAdminActions({
    required String enrollmentId,
    int limit = 20,
    DocumentSnapshot? startAfter,
  }) async {
    try {
      var query = _firestore
          .collection('enrollments')
          .doc(enrollmentId)
          .collection('adminActions')
          .orderBy('performedAt', descending: true)
          .limit(limit);

      if (startAfter != null) {
        query = query.startAfterDocument(startAfter);
      }

      final snapshot = await query.get();
      return snapshot.docs.map((doc) {
        final data = doc.data();
        return AdminAction(
          id: doc.id,
          actionType: AdminActionType.values.firstWhere(
            (e) => e.name == data['actionType'],
            orElse: () => AdminActionType.other,
          ),
          performedAt: _timestampToDateTime(data['performedAt']),
          performedBy: data['performedBy'] as String,
          details: data['details'] as String?,
          oldValue: data['oldValue'] as Map<String, dynamic>?,
          newValue: data['newValue'] as Map<String, dynamic>?,
        );
      }).toList();
    } catch (e) {
      debugPrint('❌ [EnrollmentService] 관리자 액션 조회 실패: $e');
      return [];
    }
  }

  /// 관리자 액션 실시간 구독 (페이지네이션 지원)
  Stream<List<AdminAction>> watchAdminActions({
    required String enrollmentId,
    int limit = 20,
  }) {
    return _firestore
        .collection('enrollments')
        .doc(enrollmentId)
        .collection('adminActions')
        .orderBy('performedAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            final data = doc.data();
            return AdminAction(
              id: doc.id,
              actionType: AdminActionType.values.firstWhere(
                (e) => e.name == data['actionType'],
                orElse: () => AdminActionType.other,
              ),
              performedAt: _timestampToDateTime(data['performedAt']),
              performedBy: data['performedBy'] as String,
              details: data['details'] as String?,
              oldValue: data['oldValue'] as Map<String, dynamic>?,
              newValue: data['newValue'] as Map<String, dynamic>?,
            );
          }).toList();
        });
  }

  // ==================== 서브컬렉션: 연장 요청 ====================

  /// 연장 요청 추가 (서브컬렉션)
  Future<void> addExtensionRequest({
    required String enrollmentId,
    required ExtensionRequest request,
  }) async {
    try {
      final requestRef = _firestore
          .collection('enrollments')
          .doc(enrollmentId)
          .collection('extensionRequests')
          .doc(request.id);

      await requestRef.set({
        'requestedAt': _dateTimeToTimestamp(request.requestedAt),
        'reason': request.reason,
        'status': request.status.name,
        'approvedAt': request.approvedAt != null
            ? _dateTimeToTimestamp(request.approvedAt!)
            : null,
        'rejectedAt': request.rejectedAt != null
            ? _dateTimeToTimestamp(request.rejectedAt!)
            : null,
        'rejectionReason': request.rejectionReason,
      });
    } catch (e) {
      debugPrint('❌ [EnrollmentService] 연장 요청 추가 실패: $e');
      rethrow;
    }
  }

  /// 연장 요청 추가 + enrollment 문서에 최신 요청(denormalized)도 함께 기록
  ///
  /// 목적:
  /// - 사용자 앱/관리자 화면에서 "요청 상태"를 빠르게 표시
  /// - 서버 재조회 시에도 요청 상태가 유지되도록 함
  ///
  /// 저장 위치:
  /// - enrollments/{enrollmentId}/extensionRequests/{requestId}
  /// - enrollments/{enrollmentId}.extensionRequest (legacy/denormalized)
  Future<void> addExtensionRequestWithEnrollmentMarker({
    required String enrollmentId,
    required ExtensionRequest request,
  }) async {
    try {
      final enrollmentRef = _firestore
          .collection('enrollments')
          .doc(enrollmentId);
      final requestRef = enrollmentRef
          .collection('extensionRequests')
          .doc(request.id);

      // 중복 요청 방지: 트랜잭션 전에 서브컬렉션에서 pending 요청 확인
      final existingRequestsSnapshot = await enrollmentRef
          .collection('extensionRequests')
          .where('status', isEqualTo: ExtensionRequestStatus.pending.name)
          .limit(1)
          .get();
      if (existingRequestsSnapshot.docs.isNotEmpty) {
        throw Exception('이미 진행 중인 연장 요청이 있습니다. 승인 또는 거절 후 다시 요청해주세요.');
      }

      await _firestore.runTransaction((tx) async {
        final enrollmentSnap = await tx.get(enrollmentRef);
        if (!enrollmentSnap.exists) {
          throw Exception('Enrollment not found: $enrollmentId');
        }

        // 중복 요청 방지: marker에서도 pending 요청 확인 (이중 체크)
        final data = enrollmentSnap.data();
        final marker = data?['extensionRequest'];
        if (marker is Map) {
          final markerStatus = marker['status'] as String?;
          if (markerStatus == ExtensionRequestStatus.pending.name) {
            throw Exception('이미 진행 중인 연장 요청이 있습니다. 승인 또는 거절 후 다시 요청해주세요.');
          }
        }

        tx.set(requestRef, {
          'requestedAt': _dateTimeToTimestamp(request.requestedAt),
          'reason': request.reason,
          'status': request.status.name,
          'approvedAt': request.approvedAt != null
              ? _dateTimeToTimestamp(request.approvedAt!)
              : null,
          'rejectedAt': request.rejectedAt != null
              ? _dateTimeToTimestamp(request.rejectedAt!)
              : null,
          'rejectionReason': request.rejectionReason,
        });

        // denormalized: 가장 최근 요청 1개만 유지
        tx.update(enrollmentRef, {
          'extensionRequest': {
            'id': request.id,
            'requestedAt': _dateTimeToTimestamp(request.requestedAt),
            'reason': request.reason,
            'status': request.status.name,
            'approvedAt': request.approvedAt != null
                ? _dateTimeToTimestamp(request.approvedAt!)
                : null,
            'rejectedAt': request.rejectedAt != null
                ? _dateTimeToTimestamp(request.rejectedAt!)
                : null,
            'rejectionReason': request.rejectionReason,
          },
        });
      });
    } catch (e) {
      debugPrint('❌ [EnrollmentService] 연장 요청 추가(마커 포함) 실패: $e');
      rethrow;
    }
  }

  /// 연장 요청 상태 업데이트 (서브컬렉션) + enrollment의 denormalized marker 동기화
  ///
  /// 관리자 승인/거절 처리에 사용.
  Future<void> updateExtensionRequestStatusWithEnrollmentMarker({
    required String enrollmentId,
    required String requestId,
    required ExtensionRequestStatus status,
    String? rejectionReason,
  }) async {
    try {
      final enrollmentRef = _firestore
          .collection('enrollments')
          .doc(enrollmentId);
      final requestRef = enrollmentRef
          .collection('extensionRequests')
          .doc(requestId);

      await _firestore.runTransaction((tx) async {
        final enrollmentSnap = await tx.get(enrollmentRef);
        if (!enrollmentSnap.exists) {
          throw Exception('Enrollment not found: $enrollmentId');
        }

        final requestSnap = await tx.get(requestRef);
        if (!requestSnap.exists) {
          throw Exception('Extension request not found: $requestId');
        }

        // 동시성 문제 해결: 현재 상태가 pending인지 확인
        final requestData = requestSnap.data() as Map<String, dynamic>;
        final currentStatus = requestData['status'] as String?;
        if (currentStatus != ExtensionRequestStatus.pending.name) {
          throw Exception(
            'Extension request is not pending. Current status: $currentStatus',
          );
        }

        final now = TimezoneUtils.getSeoulDateTime();
        final updateMap = <String, dynamic>{
          'status': status.name,
          'approvedAt': status == ExtensionRequestStatus.approved
              ? _dateTimeToTimestamp(now)
              : null,
          'rejectedAt': status == ExtensionRequestStatus.rejected
              ? _dateTimeToTimestamp(now)
              : null,
          'rejectionReason': status == ExtensionRequestStatus.rejected
              ? rejectionReason
              : null,
        };
        tx.update(requestRef, updateMap);

        // denormalized marker도 동일 requestId일 때만 업데이트
        final data = enrollmentSnap.data();
        final marker = data?['extensionRequest'];
        final markerId = marker is Map ? marker['id']?.toString() : null;
        if (markerId == requestId) {
          tx.update(enrollmentRef, {
            'extensionRequest': {
              ...(marker as Map).map((k, v) => MapEntry(k.toString(), v)),
              'status': status.name,
              'approvedAt': updateMap['approvedAt'],
              'rejectedAt': updateMap['rejectedAt'],
              'rejectionReason': updateMap['rejectionReason'],
            },
          });
        }
      });
    } catch (e) {
      debugPrint('❌ [EnrollmentService] 연장 요청 상태 업데이트 실패: $e');
      rethrow;
    }
  }

  /// 연장 요청 조회 (페이지네이션 지원)
  Future<List<ExtensionRequest>> getExtensionRequests({
    required String enrollmentId,
    int limit = 20,
    DocumentSnapshot? startAfter,
  }) async {
    try {
      var query = _firestore
          .collection('enrollments')
          .doc(enrollmentId)
          .collection('extensionRequests')
          .orderBy('requestedAt', descending: true)
          .limit(limit);

      if (startAfter != null) {
        query = query.startAfterDocument(startAfter);
      }

      final snapshot = await query.get();
      return snapshot.docs.map((doc) {
        final data = doc.data();
        return ExtensionRequest(
          id: doc.id,
          requestedAt: _timestampToDateTime(data['requestedAt']),
          reason: data['reason'] as String,
          status: ExtensionRequestStatus.values.firstWhere(
            (e) => e.name == data['status'],
            orElse: () => ExtensionRequestStatus.pending,
          ),
          approvedAt: data['approvedAt'] != null
              ? _timestampToDateTime(data['approvedAt'])
              : null,
          rejectedAt: data['rejectedAt'] != null
              ? _timestampToDateTime(data['rejectedAt'])
              : null,
          rejectionReason: data['rejectionReason'] as String?,
        );
      }).toList();
    } catch (e) {
      debugPrint('❌ [EnrollmentService] 연장 요청 조회 실패: $e');
      return [];
    }
  }

  /// 연장 요청 실시간 구독 (서브컬렉션, 페이지네이션 지원)
  Stream<List<ExtensionRequest>> watchEnrollmentExtensionRequests({
    required String enrollmentId,
    int limit = 20,
  }) {
    return _firestore
        .collection('enrollments')
        .doc(enrollmentId)
        .collection('extensionRequests')
        .orderBy('requestedAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            final data = doc.data();
            return ExtensionRequest(
              id: doc.id,
              requestedAt: _timestampToDateTime(data['requestedAt']),
              reason: data['reason'] as String,
              status: ExtensionRequestStatus.values.firstWhere(
                (e) => e.name == data['status'],
                orElse: () => ExtensionRequestStatus.pending,
              ),
              approvedAt: data['approvedAt'] != null
                  ? _timestampToDateTime(data['approvedAt'])
                  : null,
              rejectedAt: data['rejectedAt'] != null
                  ? _timestampToDateTime(data['rejectedAt'])
                  : null,
              rejectionReason: data['rejectionReason'] as String?,
            );
          }).toList();
        });
  }
}

/// 연장 요청 상태 업데이트 정보
class ExtensionRequestUpdate {
  final String requestId;
  final ExtensionRequestStatus status;
  final String? rejectionReason;

  ExtensionRequestUpdate({
    required this.requestId,
    required this.status,
    this.rejectionReason,
  });
}
