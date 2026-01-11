import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../models/course_enrollment.dart';
import '../models/pending_member.dart';
import '../models/user.dart';
import '../models/place_membership.dart';
import '../utils/timezone_utils.dart';
import 'firestore_service.dart';
import 'auth_service.dart';
import 'enrollment_service.dart';
import 'user_service.dart';

/// 멤버 관련 Firebase 작업을 관리하는 서비스
class MemberService {
  final FirestoreService _firestoreService = FirestoreService();
  final EnrollmentService _enrollmentService = EnrollmentService();
  final UserService _userService = UserService();
  FirebaseFirestore get _firestore => _firestoreService.firestore;

  /// 전화번호 정규화 (숫자만 추출, 82로 시작하면 0으로 변환)
  String _normalizePhone(String phoneNumber) {
    var digits = phoneNumber.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.startsWith('82')) {
      digits = '0${digits.substring(2)}';
    }
    if (!digits.startsWith('0')) {
      digits = '0$digits';
    }
    return digits;
  }

  /// 멤버 등록 (pendingMembers 및 enrollments 생성)
  ///
  /// [placeId] 플레이스 ID
  /// [adminId] 관리자 ID
  /// [name] 멤버 이름
  /// [phoneNumber] 전화번호
  /// [courseEnrollments] 코스별 등록 설정 목록 (courseId, totalReservations, validFrom, validUntil 포함)
  /// [courses] 코스 목록 (검증 및 기본값 사용)
  ///
  /// Returns: 등록 성공 여부
  Future<bool> registerMember({
    required String placeId,
    required String adminId,
    required String name,
    required String phoneNumber,
    required List<Map<String, dynamic>>? courseEnrollments,
    required List<dynamic> courses, // Course 객체 리스트
  }) async {
    try {
      debugPrint('🔥 [MemberService] 멤버 등록 시작');
      debugPrint('🔥 [MemberService] placeId: $placeId, adminId: $adminId');
      debugPrint('🔥 [MemberService] name: $name, phoneNumber: $phoneNumber');

      // 전화번호 정규화
      final normalizedPhone = _normalizePhone(phoneNumber);
      if (normalizedPhone.length != 11) {
        debugPrint('❌ [MemberService] 전화번호 형식 오류: $normalizedPhone');
        return false;
      }

      // courseEnrollments에서 courseIds 추출
      final courseIds = courseEnrollments != null
          ? courseEnrollments.map((e) => e['courseId'] as String).toList()
          : <String>[];

      debugPrint(
        '🔥 [MemberService] courseIds: $courseIds (개수: ${courseIds.length})',
      );
      debugPrint('🔥 [MemberService] courseEnrollments: $courseEnrollments');

      // User 조회
      debugPrint('🔍 [MemberService] User 조회 시작');
      final userQuery = _firestore
          .collection('users')
          .where('phoneNumber', isEqualTo: normalizedPhone)
          .limit(1);
      final userSnapshot = await userQuery.get();
      debugPrint('🔍 [MemberService] User 조회 결과: ${userSnapshot.docs.length}개');

      String? existingUserId;
      if (userSnapshot.docs.isNotEmpty) {
        existingUserId = userSnapshot.docs.first.id;
        debugPrint('✅ [MemberService] 기존 사용자 발견: $existingUserId');
      } else {
        debugPrint('ℹ️ [MemberService] 신규 사용자');
      }

      // 기존 enrollments 확인
      final existingEnrollmentIds = <String>{};
      if (courseIds.isNotEmpty && existingUserId != null) {
        debugPrint('🔍 [MemberService] 기존 enrollments 조회 시작');
        final existingEnrollmentQuery = _firestore
            .collection('enrollments')
            .where('userId', isEqualTo: existingUserId)
            .where('placeId', isEqualTo: placeId)
            .where('courseId', whereIn: courseIds);

        final existingEnrollmentSnapshot = await existingEnrollmentQuery.get();
        debugPrint(
          '🔍 [MemberService] 기존 enrollments 조회 결과: ${existingEnrollmentSnapshot.docs.length}개',
        );

        for (final doc in existingEnrollmentSnapshot.docs) {
          final data = doc.data();
          final courseId = data['courseId'] as String?;
          if (courseId != null) {
            existingEnrollmentIds.add(courseId);
            debugPrint('⏭️ [MemberService] 기존 enrollment 발견: $courseId');
          }
        }
      }

      // 트랜잭션으로 처리
      final pendingId = '${placeId}_$normalizedPhone';
      final pendingRef = _firestore.collection('pendingMembers').doc(pendingId);

      debugPrint('🔥 [MemberService] 트랜잭션 시작');
      await _firestore.runTransaction((tx) async {
        // 1. pendingMembers 생성/업데이트
        final existingPending = await tx.get(pendingRef);
        debugPrint(
          '🔍 [MemberService] pendingMembers 존재 여부: ${existingPending.exists}',
        );

        if (existingPending.exists) {
          debugPrint('🔄 [MemberService] pendingMembers 업데이트');
          final updateData = <String, dynamic>{
            'name': name,
            'autoApprove': true,
            'courseIds': courseIds,
            'updatedAt': FieldValue.serverTimestamp(),
          };
          if (courseEnrollments != null) {
            updateData['courseEnrollments'] = courseEnrollments;
            debugPrint('📝 [MemberService] courseEnrollments 저장');
          }
          debugPrint('📝 [MemberService] 업데이트 데이터: $updateData');
          tx.update(pendingRef, updateData);
        } else {
          debugPrint('✨ [MemberService] pendingMembers 생성');
          final pending = PendingMember(
            id: pendingId,
            placeId: placeId,
            phoneNumber: normalizedPhone,
            name: name,
            createdBy: adminId,
            createdAt: DateTime.now(),
            autoApprove: true,
          );

          final payload = <String, dynamic>{
            ...pending.toJson(),
            'createdAt': FieldValue.serverTimestamp(),
            'courseIds': courseIds,
          };
          if (courseEnrollments != null) {
            payload['courseEnrollments'] = courseEnrollments;
            debugPrint('📝 [MemberService] courseEnrollments 저장');
          }
          debugPrint('📝 [MemberService] 생성 데이터: $payload');
          tx.set(pendingRef, payload);
        }

        // 2. 기존 User가 있으면 enrollments 생성
        if (existingUserId != null && courseIds.isNotEmpty) {
          debugPrint('📚 [MemberService] enrollments 생성 시작');
          final enrollmentTime = TimezoneUtils.getSeoulDateTime();

          for (final courseId in courseIds) {
            if (existingEnrollmentIds.contains(courseId)) {
              debugPrint('⏭️ [MemberService] enrollment 스킵: $courseId');
              continue;
            }

            // 코스 찾기
            final course = courses.firstWhere(
              (c) => (c as dynamic).id == courseId,
              orElse: () => throw Exception('코스를 찾을 수 없습니다: $courseId'),
            );
            final courseName = (course as dynamic).name;
            final defaultTotalReservations =
                (course as dynamic).defaultTotalReservations ?? 0;
            debugPrint('✅ [MemberService] 코스 확인: $courseName ($courseId)');

            // courseEnrollments에서 설정 찾기
            Map<String, dynamic>? courseEnrollmentConfig;
            if (courseEnrollments != null) {
              try {
                final found = courseEnrollments.firstWhere(
                  (e) => e['courseId'] == courseId,
                );
                courseEnrollmentConfig = found as Map<String, dynamic>?;
                debugPrint('✅ [MemberService] courseEnrollmentConfig 발견');
              } catch (e) {
                debugPrint(
                  '⚠️ [MemberService] courseEnrollmentConfig 없음, 기본값 사용',
                );
                courseEnrollmentConfig = null;
              }
            }

            // Enrollment 생성
            final totalReservations =
                courseEnrollmentConfig?['totalReservations'] as int? ??
                defaultTotalReservations;

            DateTime validFrom;
            DateTime validUntil;
            if (courseEnrollmentConfig?['validFrom'] != null &&
                courseEnrollmentConfig?['validUntil'] != null) {
              validFrom = DateTime.parse(
                courseEnrollmentConfig!['validFrom'] as String,
              );
              validUntil = DateTime.parse(
                courseEnrollmentConfig['validUntil'] as String,
              );
              debugPrint('📅 [MemberService] 유효기간 설정값 사용');
            } else {
              validFrom = enrollmentTime;
              validUntil = enrollmentTime.add(const Duration(days: 365));
              debugPrint('📅 [MemberService] 유효기간 기본값 사용');
            }

            final enrollmentRef = _firestore.collection('enrollments').doc();
            final enrollment = CourseEnrollment(
              id: enrollmentRef.id,
              userId: existingUserId,
              courseId: courseId,
              placeId: placeId,
              enrolledAt: enrollmentTime,
              validFrom: validFrom,
              validUntil: validUntil,
              totalReservations: totalReservations,
              remainingReservations: totalReservations,
            );

            final enrollmentData = enrollment.toJson();
            enrollmentData['enrolledAt'] = _firestoreService
                .dateTimeToTimestamp(enrollmentTime);
            enrollmentData['validFrom'] = _firestoreService.dateTimeToTimestamp(
              validFrom,
            );
            enrollmentData['validUntil'] = _firestoreService
                .dateTimeToTimestamp(validUntil);

            debugPrint('✨ [MemberService] enrollment 생성: ${enrollmentRef.id}');
            debugPrint('✨ [MemberService] enrollment 데이터: $enrollmentData');
            tx.set(enrollmentRef, enrollmentData);
          }
        }
      });

      debugPrint('✅ [MemberService] 멤버 등록 완료');
      return true;
    } catch (e) {
      debugPrint('❌ [MemberService] 멤버 등록 실패: $e');
      return false;
    }
  }

  /// 멤버 이름 업데이트
  ///
  /// [phoneNumber] 전화번호
  /// [newName] 새로운 이름
  ///
  /// Returns: 업데이트된 User 또는 null
  Future<User?> updateMemberName({
    required String phoneNumber,
    required String newName,
  }) async {
    try {
      debugPrint('🔥 [MemberService] 멤버 이름 업데이트 시작');
      debugPrint(
        '🔥 [MemberService] phoneNumber: $phoneNumber, newName: $newName',
      );

      // 전화번호 정규화
      final normalizedPhone = _normalizePhone(phoneNumber);
      if (normalizedPhone.length != 11) {
        debugPrint('❌ [MemberService] 전화번호 형식 오류: $normalizedPhone');
        return null;
      }

      // User 찾기
      debugPrint('🔍 [MemberService] User 조회 시작');
      final authService = AuthService();
      final user = await authService.findUserByPhone(normalizedPhone);

      if (user == null) {
        debugPrint('❌ [MemberService] User를 찾을 수 없음');
        return null;
      }

      debugPrint('✅ [MemberService] User 발견: ${user.userId}');

      // 이름이 같으면 업데이트 불필요
      if (user.name == newName) {
        debugPrint('ℹ️ [MemberService] 이름이 동일하여 업데이트 불필요');
        return user;
      }

      // 이름 업데이트
      final updatedUser = user.copyWith(
        name: newName,
        updatedAt: DateTime.now(),
      );

      debugPrint('📝 [MemberService] User 업데이트 시작');
      await _userService.updateUserDirect(updatedUser);
      debugPrint('✅ [MemberService] User 업데이트 완료');

      return updatedUser;
    } catch (e) {
      debugPrint('❌ [MemberService] 멤버 이름 업데이트 실패: $e');
      return null;
    }
  }

  /// 멤버 정보 업데이트 (이름 및 코스 등록)
  ///
  /// [phoneNumber] 전화번호
  /// [name] 멤버 이름
  /// [placeId] 플레이스 ID
  /// [selectedCourseIds] 선택된 코스 ID 목록
  /// [courses] 코스 목록 (검증 및 기본값 사용)
  ///
  /// Returns: 업데이트된 User 또는 null
  Future<User?> updateMember({
    required String phoneNumber,
    required String name,
    required String placeId,
    required Set<String> selectedCourseIds,
    required List<dynamic> courses, // Course 객체 리스트
  }) async {
    try {
      debugPrint('🔥 [MemberService] 멤버 정보 업데이트 시작');
      debugPrint('🔥 [MemberService] phoneNumber: $phoneNumber, name: $name');
      debugPrint(
        '🔥 [MemberService] placeId: $placeId, selectedCourseIds: $selectedCourseIds',
      );

      // 전화번호 정규화
      final normalizedPhone = _normalizePhone(phoneNumber);
      if (normalizedPhone.length != 11) {
        debugPrint('❌ [MemberService] 전화번호 형식 오류: $normalizedPhone');
        return null;
      }

      // User 찾기
      debugPrint('🔍 [MemberService] User 조회 시작');
      final authService = AuthService();
      final user = await authService.findUserByPhone(normalizedPhone);

      if (user == null) {
        debugPrint('❌ [MemberService] User를 찾을 수 없음');
        return null;
      }

      debugPrint('✅ [MemberService] User 발견: ${user.userId}');

      // 이름 업데이트
      User updatedUser = user;
      if (user.name != name) {
        debugPrint('📝 [MemberService] 이름 업데이트: ${user.name} -> $name');
        updatedUser = user.copyWith(name: name, updatedAt: DateTime.now());
        await _userService.updateUserDirect(updatedUser);
        debugPrint('✅ [MemberService] 이름 업데이트 완료');
      }

      // 코스 등록 업데이트
      final now = TimezoneUtils.getSeoulDateTime();
      final currentEnrolledCourseIds = updatedUser.enrollments
          .where((e) => e.isValid && e.placeId == placeId)
          .map((e) => e.courseId)
          .toSet();

      debugPrint('📋 [MemberService] 현재 등록된 코스: $currentEnrolledCourseIds');
      debugPrint('📋 [MemberService] 선택된 코스: $selectedCourseIds');

      // 추가할 코스들
      final coursesToAdd = selectedCourseIds
          .where((courseId) => !currentEnrolledCourseIds.contains(courseId))
          .toList();

      // 제거할 코스들
      final coursesToRemove = currentEnrolledCourseIds
          .where((courseId) => !selectedCourseIds.contains(courseId))
          .toList();

      debugPrint('➕ [MemberService] 추가할 코스: $coursesToAdd');
      debugPrint('➖ [MemberService] 제거할 코스: $coursesToRemove');

      // 새 코스 등록
      for (final courseId in coursesToAdd) {
        debugPrint('📚 [MemberService] 코스 등록 시작: $courseId');

        // 코스 찾기
        final course = courses.firstWhere(
          (c) => (c as dynamic).id == courseId,
          orElse: () => throw Exception('코스를 찾을 수 없습니다: $courseId'),
        );
        final courseName = (course as dynamic).name;
        final defaultTotalReservations =
            (course as dynamic).defaultTotalReservations ?? 0;
        debugPrint('✅ [MemberService] 코스 확인: $courseName ($courseId)');

        final enrollment = CourseEnrollment(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          userId: updatedUser.userId,
          courseId: courseId,
          placeId: placeId,
          enrolledAt: now,
          validFrom: now,
          validUntil: now.add(const Duration(days: 365)),
          totalReservations: defaultTotalReservations,
          remainingReservations: defaultTotalReservations,
        );

        debugPrint('✨ [MemberService] enrollment 생성: ${enrollment.id}');
        await _enrollmentService.createEnrollment(enrollment);
        updatedUser = updatedUser.addEnrollment(enrollment);
        debugPrint('✅ [MemberService] enrollment 생성 완료');
      }

      // 코스 등록 제거 (유효 기간을 만료시킴)
      for (final courseId in coursesToRemove) {
        debugPrint('🗑️ [MemberService] 코스 제거 시작: $courseId');

        final enrollment = updatedUser.getEnrollment(courseId);
        if (enrollment != null) {
          // 현재 등록 정보를 히스토리에 추가 (취소 기록)
          final currentHistory = List<ReenrollmentRecord>.from(
            enrollment.reenrollmentHistory,
          );
          currentHistory.add(
            ReenrollmentRecord(
              enrollmentNumber: enrollment.totalEnrollmentCount,
              totalReservations: enrollment.totalReservations,
              enrolledAt: enrollment.enrolledAt,
              validFrom: enrollment.validFrom,
              validUntil: enrollment.validUntil,
              cancelledAt: now, // 취소일 기록
            ),
          );

          // 유효 기간을 과거로 설정하여 만료 처리 (히스토리는 유지)
          final expiredEnrollment = enrollment.copyWith(
            validUntil: now.subtract(const Duration(days: 1)),
            reenrollmentHistory: currentHistory,
          );

          debugPrint('📝 [MemberService] enrollment 만료 처리: ${enrollment.id}');
          await _enrollmentService.updateEnrollment(expiredEnrollment);
          updatedUser = updatedUser.updateEnrollment(expiredEnrollment);
          debugPrint('✅ [MemberService] enrollment 만료 처리 완료');
        }
      }

      // User 업데이트 (코스 변경이 있었을 때만)
      if (coursesToAdd.isNotEmpty || coursesToRemove.isNotEmpty) {
        debugPrint('📝 [MemberService] User 최종 업데이트');
        await _userService.updateUserDirect(updatedUser);
        debugPrint('✅ [MemberService] User 최종 업데이트 완료');
      }

      debugPrint('✅ [MemberService] 멤버 정보 업데이트 완료');
      return updatedUser;
    } catch (e) {
      debugPrint('❌ [MemberService] 멤버 정보 업데이트 실패: $e');
      return null;
    }
  }

  // ==================== PendingMembers ====================

  /// 플레이스별 pendingMembers 조회 (관리자 화면용)
  Stream<List<PendingMember>> watchPendingMembersByPlace(String placeId) {
    return _firestore
        .collection('pendingMembers')
        .where('placeId', isEqualTo: placeId)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            final data = doc.data();
            // Timestamp를 DateTime으로 변환
            if (data['createdAt'] != null) {
              data['createdAt'] = _timestampToDateTime(
                data['createdAt'],
              ).toIso8601String();
            }
            if (data['updatedAt'] != null) {
              data['updatedAt'] = _timestampToDateTime(
                data['updatedAt'],
              ).toIso8601String();
            }
            return PendingMember.fromJson(data);
          }).toList();
        });
  }

  /// pendingMembers의 courseEnrollments에서 특정 코스 설정만 업데이트
  ///
  /// [placeId] 플레이스 ID
  /// [phoneNumber] 전화번호 (정규화됨)
  /// [courseId] 코스 ID
  /// [totalReservations] 총 예약 횟수 (선택적)
  /// [validFrom] 유효 시작일 (선택적)
  /// [validUntil] 유효 종료일 (선택적)
  ///
  /// Returns: 업데이트 성공 여부
  Future<bool> updatePendingCourseEnrollmentConfig({
    required String placeId,
    required String phoneNumber,
    required String courseId,
    int? totalReservations,
    DateTime? validFrom,
    DateTime? validUntil,
  }) async {
    try {
      final normalizedPhone = _normalizePhone(phoneNumber);
      final pendingId = '${placeId}_$normalizedPhone';
      final pendingRef = _firestore.collection('pendingMembers').doc(pendingId);

      await _firestore.runTransaction((tx) async {
        final snap = await tx.get(pendingRef);
        if (!snap.exists) {
          // pending 문서가 없으면 업데이트 불가
          throw Exception('pendingMembers 문서를 찾을 수 없습니다.');
        }

        final data = snap.data() as Map<String, dynamic>;
        final rawCourseEnrollments = data['courseEnrollments'];
        final rawCourseIds = data['courseIds'];

        List<Map<String, dynamic>> courseEnrollments;
        if (rawCourseEnrollments is List) {
          courseEnrollments = rawCourseEnrollments
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        } else if (rawCourseIds is List) {
          // courseEnrollments가 없으면 courseIds 기반으로 생성 (다른 코스 유지)
          courseEnrollments = rawCourseIds
              .map((e) => <String, dynamic>{'courseId': e.toString()})
              .toList();
        } else {
          // 둘 다 없으면 현재 코스만 생성
          courseEnrollments = [
            <String, dynamic>{'courseId': courseId},
          ];
        }

        final idx = courseEnrollments.indexWhere(
          (e) => e['courseId']?.toString() == courseId,
        );
        final Map<String, dynamic> current = idx >= 0
            ? courseEnrollments[idx]
            : <String, dynamic>{'courseId': courseId};

        if (totalReservations != null) {
          current['totalReservations'] = totalReservations;
        }
        if (validFrom != null) {
          current['validFrom'] = validFrom.toIso8601String();
        }
        if (validUntil != null) {
          current['validUntil'] = validUntil.toIso8601String();
        }

        if (idx >= 0) {
          courseEnrollments[idx] = current;
        } else {
          courseEnrollments.add(current);
        }

        tx.update(pendingRef, {
          'courseEnrollments': courseEnrollments,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });

      return true;
    } catch (e) {
      debugPrint('pendingMembers courseEnrollment 업데이트 실패: $e');
      return false;
    }
  }

  /// pendingMembers에서 특정 코스 제거 (플레이스 전체)
  ///
  /// [placeId] 플레이스 ID
  /// [courseId] 제거할 코스 ID
  ///
  /// Returns: 제거된 pendingMembers 수
  Future<int> removeCourseFromAllPendingMembers({
    required String placeId,
    required String courseId,
  }) async {
    try {
      int removedCount = 0;
      const pageSize = 500;
      DocumentSnapshot? lastDoc;

      while (true) {
        // 페이지네이션 쿼리
        var query = _firestore
            .collection('pendingMembers')
            .where('placeId', isEqualTo: placeId)
            .limit(pageSize);

        if (lastDoc != null) {
          query = query.startAfterDocument(lastDoc);
        }

        final snapshot = await query.get();

        if (snapshot.docs.isEmpty) {
          break;
        }

        // 배치 업데이트
        final batch = _firestore.batch();
        int batchOperationCount = 0; // 이 배치의 작업 수

        for (var doc in snapshot.docs) {
          final data = doc.data();
          final courseIds =
              (data['courseIds'] as List<dynamic>?)
                  ?.map((e) => e.toString())
                  .toList() ??
              <String>[];

          // courseEnrollments에서도 제거
          final rawCourseEnrollments = data['courseEnrollments'];
          List<Map<String, dynamic>>? courseEnrollments;
          if (rawCourseEnrollments is List) {
            courseEnrollments = rawCourseEnrollments
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
            courseEnrollments.removeWhere(
              (e) => e['courseId']?.toString() == courseId,
            );
          }

          // courseIds에서 제거
          if (courseIds.contains(courseId)) {
            courseIds.remove(courseId);
            removedCount++;
            batchOperationCount++;

            if (courseIds.isEmpty) {
              // courseIds가 비어있으면 pendingMember 삭제
              batch.delete(doc.reference);
            } else {
              // courseIds가 있으면 업데이트
              final updateData = <String, dynamic>{
                'courseIds': courseIds,
                'updatedAt': FieldValue.serverTimestamp(),
              };
              if (courseEnrollments != null && courseEnrollments.isNotEmpty) {
                updateData['courseEnrollments'] = courseEnrollments;
              } else if (courseEnrollments != null &&
                  courseEnrollments.isEmpty) {
                updateData['courseEnrollments'] = <Map<String, dynamic>>[];
              }
              batch.update(doc.reference, updateData);
            }
          } else if (courseEnrollments != null &&
              courseEnrollments.any(
                (e) => e['courseId']?.toString() == courseId,
              )) {
            // courseIds에는 없지만 courseEnrollments에만 있는 경우
            removedCount++;
            batchOperationCount++;
            final updateData = <String, dynamic>{
              'courseEnrollments': courseEnrollments,
              'updatedAt': FieldValue.serverTimestamp(),
            };
            batch.update(doc.reference, updateData);
          }
        }

        // 배치에 작업이 있으면 commit
        if (batchOperationCount > 0) {
          await batch.commit();
        }

        lastDoc = snapshot.docs.last;

        if (snapshot.docs.length < pageSize) {
          break;
        }
      }

      debugPrint('✅ [MemberService] pendingMembers에서 코스 제거 완료: $removedCount개');
      return removedCount;
    } catch (e) {
      debugPrint('❌ [MemberService] pendingMembers에서 코스 제거 실패: $e');
      rethrow;
    }
  }

  /// pendingMembers에서 특정 코스 제거
  ///
  /// [placeId] 플레이스 ID
  /// [phoneNumber] 전화번호 (정규화됨)
  /// [courseId] 제거할 코스 ID
  /// [keepPendingMember] true이면 courseIds가 비어있어도 pendingMember를 유지 (기본값: false)
  ///
  /// Returns: 제거 성공 여부
  Future<bool> removeCourseFromPendingMembers({
    required String placeId,
    required String phoneNumber,
    required String courseId,
    bool keepPendingMember = false,
  }) async {
    try {
      final normalizedPhone = _normalizePhone(phoneNumber);
      final pendingId = '${placeId}_$normalizedPhone';
      final pendingRef = _firestore.collection('pendingMembers').doc(pendingId);

      await _firestore.runTransaction((tx) async {
        final existingPending = await tx.get(pendingRef);
        if (existingPending.exists) {
          final existingData = existingPending.data()!;
          final existingCourseIds =
              (existingData['courseIds'] as List<dynamic>?)
                  ?.map((e) => e.toString())
                  .toList() ??
              <String>[];

          // courseEnrollments에서도 제거
          final rawCourseEnrollments = existingData['courseEnrollments'];
          List<Map<String, dynamic>>? courseEnrollments;
          if (rawCourseEnrollments is List) {
            courseEnrollments = rawCourseEnrollments
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
            courseEnrollments.removeWhere(
              (e) => e['courseId']?.toString() == courseId,
            );
          }

          existingCourseIds.remove(courseId);

          if (existingCourseIds.isEmpty && !keepPendingMember) {
            // courseIds가 비어있고 keepPendingMember가 false면 pendingMembers 삭제
            tx.delete(pendingRef);
          } else {
            // courseIds가 비어있지 않거나 keepPendingMember가 true면 업데이트만 수행
            final updateData = <String, dynamic>{
              'courseIds': existingCourseIds,
              'updatedAt': FieldValue.serverTimestamp(),
            };
            if (courseEnrollments != null && courseEnrollments.isNotEmpty) {
              updateData['courseEnrollments'] = courseEnrollments;
            } else if (courseEnrollments != null && courseEnrollments.isEmpty) {
              // courseEnrollments가 비어있으면 빈 배열로 설정
              updateData['courseEnrollments'] = <Map<String, dynamic>>[];
            }
            tx.update(pendingRef, updateData);
          }
        }
      });

      return true;
    } catch (e) {
      debugPrint('pendingMembers에서 코스 제거 실패: $e');
      return false;
    }
  }

  // ==================== Place Memberships ====================

  /// 사용자별 플레이스 멤버십 실시간 구독
  Stream<List<PlaceMembership>> watchUserMemberships(String userId) {
    return _firestore
        .collection('placeMemberships')
        .where('userId', isEqualTo: userId)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            final data = doc.data();
            // Timestamp 변환
            if (data['requestedAt'] != null) {
              data['requestedAt'] = _timestampToDateTime(
                data['requestedAt'],
              ).toIso8601String();
            }
            if (data['approvedAt'] != null) {
              data['approvedAt'] = _timestampToDateTime(
                data['approvedAt'],
              ).toIso8601String();
            }
            if (data['rejectedAt'] != null) {
              data['rejectedAt'] = _timestampToDateTime(
                data['rejectedAt'],
              ).toIso8601String();
            }
            return PlaceMembership.fromJson(data);
          }).toList();
        });
  }

  // Helper 메서드
  DateTime _timestampToDateTime(dynamic timestamp) {
    if (timestamp == null) return DateTime.now();
    if (timestamp is Timestamp) return timestamp.toDate();
    if (timestamp is String) return DateTime.parse(timestamp);
    throw Exception('Invalid timestamp format');
  }
}
