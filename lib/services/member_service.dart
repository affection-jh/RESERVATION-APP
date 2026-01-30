import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
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

  /// 전화번호 기반으로 일관된 userId 생성
  /// (⚠️ 사용 금지)
  /// 과거에 phone_ 접두사로 가짜 userId를 만들었는데,
  /// Firebase Auth UID와 불일치해서 enrollments/placeMemberships가 "2유저"로 갈라지는 원인이 됨.

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
      final courseIds =
          courseEnrollments != null
              ? courseEnrollments.map((e) => e['courseId'] as String).toList()
              : <String>[];

      debugPrint(
        '🔥 [MemberService] courseIds: $courseIds (개수: ${courseIds.length})',
      );
      debugPrint('🔥 [MemberService] courseEnrollments: $courseEnrollments');

      // 성능 최적화: 코스 조회를 Map으로 캐싱 (O(1) 접근)
      final courseMap = <String, dynamic>{};
      for (final course in courses) {
        final courseId = (course as dynamic).id as String;
        courseMap[courseId] = course;
      }

      // 성능 최적화: courseEnrollments를 Map으로 변환 (빠른 조회)
      final courseEnrollmentMap = <String, Map<String, dynamic>>{};
      if (courseEnrollments != null) {
        for (final enrollment in courseEnrollments) {
          final courseId = enrollment['courseId'] as String;
          courseEnrollmentMap[courseId] = enrollment;
        }
      }

      // pendingMembers 중복 체크 (트랜잭션 전에 확인)
      final pendingId = '${placeId}_$normalizedPhone';
      final pendingRef = _firestore.collection('pendingMembers').doc(pendingId);
      final pendingDoc = await pendingRef.get();

      if (pendingDoc.exists) {
        final pendingData = pendingDoc.data();
        final status = pendingData?['status'] as String?;
        // status가 null이거나 'approved'인 경우 중복으로 간주
        if (status == null || status == 'approved') {
          debugPrint('❌ [MemberService] 이미 등록된 pendingMember입니다: $pendingId');
          return false;
        }
      }

      // User 조회
      debugPrint('🔍 [MemberService] User 조회 시작');
      final userQuery = _firestore
          .collection('users')
          .where('phoneNumber', isEqualTo: normalizedPhone)
          .limit(1);
      final userSnapshot = await userQuery.get();
      debugPrint('🔍 [MemberService] User 조회 결과: ${userSnapshot.docs.length}개');

      String? existingUserId;
      final hasRealUser = userSnapshot.docs.isNotEmpty;
      if (hasRealUser) {
        existingUserId = userSnapshot.docs.first.id;
        debugPrint('✅ [MemberService] 기존 사용자 발견: $existingUserId');
      } else {
        debugPrint(
          'ℹ️ [MemberService] 신규 사용자: users 문서가 아직 없음 (로그인 후 자동 매칭 예정)',
        );
        existingUserId = null;
      }

      // 기존 enrollments 확인 (User가 존재하는 경우에만)
      final existingEnrollmentIds = <String>{};
      if (courseIds.isNotEmpty && hasRealUser && existingUserId != null) {
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
      debugPrint('🔥 [MemberService] 트랜잭션 시작');
      await _firestore.runTransaction((tx) async {
        // ========== 1단계: 모든 읽기 작업 먼저 수행 ==========
        // 1-1. pendingMembers 읽기
        final existingPending = await tx.get(pendingRef);
        debugPrint(
          '🔍 [MemberService] pendingMembers 존재 여부: ${existingPending.exists}',
        );

        // 1-2. User 읽기 (존재하는 경우에만)
        DocumentReference? userRef;
        DocumentSnapshot? userDoc;
        if (existingUserId != null) {
          userRef = _firestore.collection('users').doc(existingUserId);
          userDoc = await tx.get(userRef);
          debugPrint('🔍 [MemberService] User 존재 여부: ${userDoc.exists}');
        } else {
          debugPrint(
            '🔍 [MemberService] User 문서 없음: enrollments는 생성하지 않고 pendingMembers만 저장',
          );
        }

        // 1-3. placeMembership 읽기 (존재하는 경우에만)
        // - 불변조건: enrollments(=courseMembers)가 있으면 placeMembership도 반드시 존재해야 한다.
        // - 과거 랜덤 docId로 생성된 placeMembership과 충돌을 피하기 위해,
        //   여기서는 "고정 docId"로 하나를 보장한다. (중복 placeMembership이 있어도 placeId set으로 안전)
        DocumentReference? membershipRef;
        DocumentSnapshot? membershipDoc;
        if (existingUserId != null) {
          final membershipId = '${existingUserId}_$placeId';
          membershipRef = _firestore
              .collection('placeMemberships')
              .doc(membershipId);
          membershipDoc = await tx.get(membershipRef);
          debugPrint(
            '🔍 [MemberService] placeMembership 존재 여부: ${membershipDoc.exists}',
          );
        }

        // 1-4. 모든 enrollments 읽기 (트랜잭션 규칙: 모든 read가 write보다 먼저)
        final enrollmentRefs = <String, DocumentReference>{};
        final enrollmentDocs = <String, DocumentSnapshot>{};
        if (courseIds.isNotEmpty && existingUserId != null) {
          for (final courseId in courseIds) {
            // 트랜잭션 외부에서 이미 확인한 경우 스킵
            if (existingEnrollmentIds.contains(courseId)) {
              debugPrint(
                '⏭️ [MemberService] enrollment 스킵 (트랜잭션 외부 확인): $courseId',
              );
              continue;
            }

            final enrollmentId = '${existingUserId}_${placeId}_$courseId';
            final enrollmentRef = _firestore
                .collection('enrollments')
                .doc(enrollmentId);
            enrollmentRefs[courseId] = enrollmentRef;
            enrollmentDocs[courseId] = await tx.get(enrollmentRef);

            if (enrollmentDocs[courseId]!.exists) {
              debugPrint(
                '⏭️ [MemberService] enrollment 이미 존재 (트랜잭션 내부 확인): $courseId',
              );
            }
          }
        }

        // ========== 2단계: 모든 쓰기 작업 수행 ==========
        // 2-1. pendingMembers 생성/업데이트 (User가 존재하지 않는 경우에만)
        if (existingUserId == null && courseIds.isNotEmpty) {
          debugPrint('📝 [MemberService] pendingMembers 생성/업데이트 시작');
          final now = TimezoneUtils.getSeoulDateTime();

          // courseEnrollments 배열 생성
          final courseEnrollmentsList = <Map<String, dynamic>>[];
          for (final courseId in courseIds) {
            final courseEnrollmentConfig = courseEnrollmentMap[courseId];
            final course = courseMap[courseId];

            if (course == null) {
              debugPrint('⚠️ [MemberService] 코스를 찾을 수 없음: $courseId');
              continue;
            }

            final defaultTotalReservations =
                (course as dynamic).defaultTotalReservations ?? 0;

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
            } else {
              validFrom = now;
              validUntil = now.add(const Duration(days: 365));
            }

            courseEnrollmentsList.add({
              'courseId': courseId,
              'totalReservations': totalReservations,
              'remainingReservations':
                  totalReservations, // 초기값은 totalReservations와 동일
              'validFrom': validFrom.toIso8601String(),
              'validUntil': validUntil.toIso8601String(),
            });
          }

          // pendingMembers 문서 생성/업데이트
          // ⚠️ courseIds 제거: courseEnrollments에서만 유도
          final pendingData = <String, dynamic>{
            'placeId': placeId,
            'phoneNumber': normalizedPhone,
            'name': name,
            'courseEnrollments': courseEnrollmentsList,
            'createdAt': _firestoreService.dateTimeToTimestamp(now),
            'updatedAt': _firestoreService.dateTimeToTimestamp(now),
          };

          if (existingPending.exists) {
            // 기존 pendingMembers 업데이트
            // ⚠️ courseIds 제거: courseEnrollments에서만 유도
            tx.update(pendingRef, {
              'name': name,
              'courseEnrollments': courseEnrollmentsList,
              'updatedAt': _firestoreService.dateTimeToTimestamp(now),
            });
            debugPrint('✅ [MemberService] pendingMembers 업데이트 완료');
          } else {
            // 새 pendingMembers 생성
            tx.set(pendingRef, pendingData);
            debugPrint('✅ [MemberService] pendingMembers 생성 완료');
          }
        }

        // 2-2. placeMembership 보장 (User가 존재하는 경우에만)
        if (existingUserId != null &&
            membershipRef != null &&
            membershipDoc != null &&
            !membershipDoc.exists) {
          debugPrint('📝 [MemberService] placeMembership 생성 시작');
          final now = TimezoneUtils.getSeoulDateTime();
          final membership = PlaceMembership(
            id: membershipRef.id,
            userId: existingUserId,
            placeId: placeId,
            requestedAt: now,
            approvedAt: now, // status 제거로 항상 멤버
            invitedBy: adminId,
          );

          final membershipData = membership.toJson();
          final ts = _firestoreService.dateTimeToTimestamp(now);
          membershipData['requestedAt'] = ts;
          membershipData['approvedAt'] = ts;
          tx.set(membershipRef, membershipData);
          debugPrint('✅ [MemberService] placeMembership 생성 완료');
        }

        // 2-3. users 문서는 관리자/클라이언트가 타인 uid로 생성/수정할 수 없음 (rules).
        // 따라서 여기서는 users 문서를 만들거나 수정하지 않는다.
        if (existingUserId != null) {
          debugPrint('✅ [MemberService] 기존 User 사용: $existingUserId');
        }

        // 2-4. enrollments 생성
        // ✅ users 문서(=실제 Firebase UID)가 있는 경우에만 enrollments를 만든다.
        // users가 없는 상태에서 phone_... 같은 가짜 userId로 enrollments를 만들면
        // 나중에 로그인한 실제 유저와 데이터가 분리된다.
        if (courseIds.isNotEmpty && existingUserId != null) {
          debugPrint('📚 [MemberService] enrollments 생성 시작');
          final enrollmentTime = TimezoneUtils.getSeoulDateTime();

          for (final courseId in courseIds) {
            // 이미 읽은 enrollment 문서 확인
            final enrollmentDoc = enrollmentDocs[courseId];
            if (enrollmentDoc == null) {
              // 트랜잭션 외부에서 이미 확인한 경우 스킵
              continue;
            }

            if (enrollmentDoc.exists) {
              // 트랜잭션 내부에서 확인한 경우 스킵
              continue;
            }

            final enrollmentRef = enrollmentRefs[courseId]!;
            final enrollmentId = '${existingUserId}_${placeId}_$courseId';

            // 코스 찾기 (캐시된 Map 사용 - O(1) 접근)
            final course = courseMap[courseId];
            if (course == null) {
              throw Exception('코스를 찾을 수 없습니다: $courseId');
            }
            final courseName = (course as dynamic).name;
            final defaultTotalReservations =
                (course as dynamic).defaultTotalReservations ?? 0;
            debugPrint('✅ [MemberService] 코스 확인: $courseName ($courseId)');

            // courseEnrollments에서 설정 찾기 (캐시된 Map 사용 - O(1) 접근)
            final courseEnrollmentConfig = courseEnrollmentMap[courseId];
            if (courseEnrollmentConfig != null) {
              debugPrint('✅ [MemberService] courseEnrollmentConfig 발견');
            } else {
              debugPrint(
                '⚠️ [MemberService] courseEnrollmentConfig 없음, 기본값 사용',
              );
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

            // ✅ 고정 ID 사용으로 중복 생성 완전 방지
            final enrollment = CourseEnrollment(
              id: enrollmentId,
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

            debugPrint('✨ [MemberService] enrollment 생성: $enrollmentId');
            debugPrint('✨ [MemberService] enrollment 데이터: $enrollmentData');
            tx.set(enrollmentRef, enrollmentData);
          }
        }
      });

      // 트랜잭션 완료 후 pushMessage 전송 (User가 존재하는 경우에만)
      if (existingUserId != null) {
        try {
          debugPrint('📤 [MemberService] 초대 요청 pushMessage 전송 시작');
          final callable = FirebaseFunctions.instance.httpsCallable(
            'sendInvitation',
          );
          await callable.call({
            'userId': existingUserId,
            'placeId': placeId,
            'phoneNumber': normalizedPhone,
            'name': name,
          });
          debugPrint('✅ [MemberService] 초대 요청 pushMessage 전송 완료');
        } catch (e) {
          debugPrint('⚠️ [MemberService] pushMessage 전송 실패 (무시): $e');
          // pushMessage 전송 실패해도 멤버 등록은 성공으로 처리
        }
      } else {
        debugPrint(
          'ℹ️ [MemberService] User가 없어 pushMessage 전송 스킵 (로그인 후 자동 매칭 예정)',
        );
      }

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

      if (user != null) {
        debugPrint('✅ [MemberService] User 발견: ${user.userId}');

        // 이름이 같으면 업데이트 불필요
        if (user.name == newName) {
          debugPrint('ℹ️ [MemberService] 이름이 동일하여 업데이트 불필요');
          return user;
        }

        // 이름 업데이트
        final updatedUser = user.copyWith(
          name: newName,
          updatedAt: TimezoneUtils.getSeoulDateTime(),
        );

        debugPrint('📝 [MemberService] User 업데이트 시작');
        await _userService.updateUserDirect(updatedUser);
        debugPrint('✅ [MemberService] User 업데이트 완료');

        return updatedUser;
      }

      // User가 없으면 pending 멤버 확인
      debugPrint('🔍 [MemberService] User 없음, pendingMembers 조회 시작');
      final pendingQuery = _firestore
          .collection('pendingMembers')
          .where('phoneNumber', isEqualTo: normalizedPhone);
      final pendingSnapshot = await pendingQuery.get();

      if (pendingSnapshot.docs.isEmpty) {
        debugPrint('❌ [MemberService] User와 pendingMembers 모두 찾을 수 없음');
        return null;
      }

      // pending 멤버 이름 업데이트 (여러 플레이스에 있을 수 있으므로 모두 업데이트)
      debugPrint(
        '✅ [MemberService] pendingMembers 발견: ${pendingSnapshot.docs.length}개',
      );
      final batch = _firestore.batch();
      for (final doc in pendingSnapshot.docs) {
        final data = doc.data();
        final currentName = data['name'] as String? ?? '';
        if (currentName != newName) {
          batch.update(doc.reference, {
            'name': newName,
            'updatedAt': FieldValue.serverTimestamp(),
          });
          debugPrint(
            '📝 [MemberService] pendingMembers 업데이트: ${doc.id} ($currentName -> $newName)',
          );
        }
      }
      await batch.commit();
      debugPrint('✅ [MemberService] pendingMembers 업데이트 완료');

      // User 객체로 변환하여 반환 (첫 번째 pending 멤버 기준)
      final firstPending = pendingSnapshot.docs.first.data();
      return User(
        userId: 'pending_${pendingSnapshot.docs.first.id}',
        name: newName,
        phoneNumber: normalizedPhone,
        placeIds: [firstPending['placeId'] as String? ?? ''],
        enrollments: const [],
        reservations: const [],
        notificationsEnabled: false,
        createdAt:
            (firstPending['createdAt'] as Timestamp?)?.toDate() ??
            TimezoneUtils.getSeoulDateTime(),
        updatedAt: TimezoneUtils.getSeoulDateTime(),
      );
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

      // placeMembership 확인 및 생성 (없으면 생성)
      final firestore = _firestoreService.firestore;
      final membershipQuery = firestore
          .collection('placeMemberships')
          .where('userId', isEqualTo: user.userId)
          .where('placeId', isEqualTo: placeId)
          .limit(1);

      final membershipSnapshot = await membershipQuery.get();
      if (membershipSnapshot.docs.isEmpty) {
        debugPrint('📝 [MemberService] placeMembership 없음, 생성 시작');
        final now = TimezoneUtils.getSeoulDateTime();
        // 고정 ID로 중복 생성 방지 (cancelEnrollment/회원탈퇴 정합성 유지)
        final membershipRef = firestore
            .collection('placeMemberships')
            .doc('${user.userId}_$placeId');

        final membership = PlaceMembership(
          id: membershipRef.id,
          userId: user.userId,
          placeId: placeId,
          requestedAt: now,
          approvedAt: now, // status 제거로 항상 approvedAt 설정
        );

        final membershipData = membership.toJson();
        final timestamp = _firestoreService.dateTimeToTimestamp(now);
        // Firestore에 저장할 때는 Timestamp로 변환
        membershipData['requestedAt'] = timestamp;
        membershipData['approvedAt'] = timestamp;

        await membershipRef.set(membershipData);
        debugPrint('✅ [MemberService] placeMembership 생성 완료');
      } else {
        debugPrint('✅ [MemberService] placeMembership 이미 존재');
      }

      // 이름 업데이트
      User updatedUser = user;
      if (user.name != name) {
        debugPrint('📝 [MemberService] 이름 업데이트: ${user.name} -> $name');
        updatedUser = user.copyWith(
          name: name,
          updatedAt: TimezoneUtils.getSeoulDateTime(),
        );
        await _userService.updateUserDirect(updatedUser);
        debugPrint('✅ [MemberService] 이름 업데이트 완료');
      }

      // 코스 등록 업데이트
      final now = TimezoneUtils.getSeoulDateTime();
      final currentEnrolledCourseIds =
          updatedUser.enrollments
              .where((e) => e.isValid && e.placeId == placeId)
              .map((e) => e.courseId)
              .toSet();

      debugPrint('📋 [MemberService] 현재 등록된 코스: $currentEnrolledCourseIds');
      debugPrint('📋 [MemberService] 선택된 코스: $selectedCourseIds');

      // 추가할 코스들
      final coursesToAdd =
          selectedCourseIds
              .where((courseId) => !currentEnrolledCourseIds.contains(courseId))
              .toList();

      // 제거할 코스들
      final coursesToRemove =
          currentEnrolledCourseIds
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
          // ✅ cancelEnrollment Cloud Function과 동일한 고정 ID 패턴 사용
          id: '${updatedUser.userId}_${placeId}_$courseId',
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

      // 코스 등록 제거 (수강취소: enrollment 완전 삭제, placeMembership 유지)
      for (final courseId in coursesToRemove) {
        debugPrint('🗑️ [MemberService] 코스 제거 시작: $courseId');
        try {
          final callable = FirebaseFunctions.instance.httpsCallable(
            'cancelEnrollment',
          );
          await callable.call({
            'placeId': placeId,
            'userId': updatedUser.userId,
            'courseId': courseId,
            'cascade': false,
          });
          debugPrint('✅ [MemberService] enrollment 삭제 완료: $courseId');
        } catch (e) {
          debugPrint('❌ [MemberService] enrollment 삭제 실패: $e');
          rethrow;
        }
      }

      // 주의: User 문서에는 enrollments 필드를 저장하지 않으므로,
      // 코스 변경만으로 users 문서를 업데이트할 필요가 없다. (placeIds 등 부수 필드 오염 방지)

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
          return snapshot.docs
              .map((doc) {
                try {
                  final data = doc.data();
                  // doc.id를 data에 포함 (PendingMember.fromJson에서 id 필요)
                  data['id'] = doc.id;

                  // 필수 필드 검증
                  if (data['placeId'] == null || data['phoneNumber'] == null) {
                    debugPrint(
                      '[MemberService] watchPendingMembersByPlace: 필수 필드 누락 - placeId: ${data['placeId']}, phoneNumber: ${data['phoneNumber']}',
                    );
                    return null;
                  }

                  // Timestamp를 DateTime으로 변환
                  if (data['createdAt'] != null) {
                    data['createdAt'] =
                        _timestampToDateTime(
                          data['createdAt'],
                        ).toIso8601String();
                  }
                  if (data['updatedAt'] != null) {
                    data['updatedAt'] =
                        _timestampToDateTime(
                          data['updatedAt'],
                        ).toIso8601String();
                  }

                  // createdBy가 null이면 빈 문자열로 설정 (기본값)
                  if (data['createdBy'] == null) {
                    data['createdBy'] = '';
                  }

                  return PendingMember.fromJson(data);
                } catch (e) {
                  debugPrint(
                    '[MemberService] watchPendingMembersByPlace: 파싱 에러 - docId: ${doc.id}, error: $e',
                  );
                  return null;
                }
              })
              .whereType<PendingMember>()
              .toList();
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

        List<Map<String, dynamic>> courseEnrollments;
        if (rawCourseEnrollments is List && rawCourseEnrollments.isNotEmpty) {
          courseEnrollments =
              rawCourseEnrollments
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList();
        } else {
          // courseEnrollments가 없으면 현재 코스만 생성
          courseEnrollments = [
            <String, dynamic>{'courseId': courseId},
          ];
        }

        final idx = courseEnrollments.indexWhere(
          (e) => e['courseId']?.toString() == courseId,
        );
        final Map<String, dynamic> current =
            idx >= 0
                ? courseEnrollments[idx]
                : <String, dynamic>{'courseId': courseId};

        if (totalReservations != null) {
          current['totalReservations'] = totalReservations;
          // 기존 데이터에 remainingReservations가 없거나, total이 변경된 경우 안전하게 보정
          final currentRemainingRaw = current['remainingReservations'];
          final currentRemaining =
              currentRemainingRaw is int
                  ? currentRemainingRaw
                  : (currentRemainingRaw is num
                      ? currentRemainingRaw.toInt()
                      : int.tryParse('$currentRemainingRaw'));
          if (currentRemaining == null ||
              currentRemaining > totalReservations) {
            current['remainingReservations'] = totalReservations;
          }
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

        // ⚠️ courseIds 제거: courseEnrollments만 저장
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

          // ⚠️ courseIds 제거: courseEnrollments에서만 확인
          final rawCourseEnrollments = data['courseEnrollments'];
          List<Map<String, dynamic>>? courseEnrollments;
          if (rawCourseEnrollments is List) {
            courseEnrollments =
                rawCourseEnrollments
                    .map((e) => Map<String, dynamic>.from(e as Map))
                    .toList();

            // courseEnrollments에서 해당 코스 제거
            final beforeCount = courseEnrollments.length;
            courseEnrollments.removeWhere(
              (e) => e['courseId']?.toString() == courseId,
            );

            if (beforeCount > courseEnrollments.length) {
              // 코스가 제거되었으면 업데이트
              removedCount++;
              batchOperationCount++;

              if (courseEnrollments.isEmpty) {
                // courseEnrollments가 비어있으면 pendingMember 삭제
                batch.delete(doc.reference);
              } else {
                // courseEnrollments가 있으면 업데이트
                batch.update(doc.reference, {
                  'courseEnrollments': courseEnrollments,
                  'updatedAt': FieldValue.serverTimestamp(),
                });
              }
            }
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
      debugPrint('🗑️ [MemberService] removeCourseFromPendingMembers 시작');
      debugPrint(
        '🗑️ [MemberService] placeId=$placeId, phoneNumber=$phoneNumber, courseId=$courseId, keepPendingMember=$keepPendingMember',
      );

      final normalizedPhone = _normalizePhone(phoneNumber);
      final pendingId = '${placeId}_$normalizedPhone';
      final pendingRef = _firestore.collection('pendingMembers').doc(pendingId);

      debugPrint('🗑️ [MemberService] pendingId=$pendingId');

      await _firestore.runTransaction((tx) async {
        final existingPending = await tx.get(pendingRef);
        debugPrint(
          '🗑️ [MemberService] pendingMembers 문서 존재 여부: ${existingPending.exists}',
        );

        if (existingPending.exists) {
          final existingData = existingPending.data()!;

          // ⚠️ courseIds 제거: courseEnrollments에서만 확인
          final rawCourseEnrollments = existingData['courseEnrollments'];
          debugPrint(
            '🗑️ [MemberService] 기존 courseEnrollments: $rawCourseEnrollments',
          );

          List<Map<String, dynamic>>? courseEnrollments;
          if (rawCourseEnrollments is List) {
            courseEnrollments =
                rawCourseEnrollments
                    .map((e) => Map<String, dynamic>.from(e as Map))
                    .toList();
            final beforeCount = courseEnrollments.length;
            courseEnrollments.removeWhere(
              (e) => e['courseId']?.toString() == courseId,
            );
            final afterCount = courseEnrollments.length;
            debugPrint(
              '🗑️ [MemberService] courseEnrollments 제거: $beforeCount -> $afterCount',
            );
          }

          // ⚠️ 단순화: courseEnrollments만 업데이트 (빈 배열이어도 업데이트)
          final finalCourseEnrollments =
              courseEnrollments ?? <Map<String, dynamic>>[];
          debugPrint(
            '🗑️ [MemberService] pendingMembers 문서 업데이트: courseEnrollments=$finalCourseEnrollments',
          );
          tx.update(pendingRef, {
            'courseEnrollments': finalCourseEnrollments,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        } else {
          debugPrint(
            '⚠️ [MemberService] pendingMembers 문서가 존재하지 않음: $pendingId',
          );
        }
      });

      debugPrint('✅ [MemberService] removeCourseFromPendingMembers 완료');
      return true;
    } catch (e) {
      debugPrint('❌ [MemberService] pendingMembers에서 코스 제거 실패: $e');
      return false;
    }
  }

  // ==================== 통합 코스 등록 메서드 ====================

  /// 멤버에게 코스 등록 (pending/일반 멤버 자동 분기 처리)
  ///
  /// ⚠️ 중요: 이 메서드는 pending 멤버와 일반 멤버를 자동으로 구분하여 처리합니다.
  /// - pending 멤버: pendingMembers의 courseEnrollments만 업데이트
  /// - 일반 멤버: enrollments 컬렉션에 생성
  ///
  /// [userId] 사용자 ID (pending_로 시작하면 pending 멤버)
  /// [placeId] 플레이스 ID
  /// [phoneNumber] 전화번호 (pending 멤버 업데이트용)
  /// [courseEnrollments] 코스별 등록 설정 목록
  /// [courses] 코스 목록
  /// [adminId] 관리자 ID (pending 멤버 등록용, 선택적)
  ///
  /// Returns: 등록 성공 여부
  Future<bool> enrollMemberToCourseOrUpdatePending({
    required String userId,
    required String placeId,
    required String phoneNumber,
    required List<Map<String, dynamic>> courseEnrollments,
    required List<dynamic> courses,
    String? adminId,
  }) async {
    try {
      final isPending = userId.startsWith('pending_');

      if (isPending) {
        // ⚠️ pending 멤버: pendingMembers만 업데이트
        debugPrint('📝 [MemberService] pending 멤버 코스 등록: pendingMembers 업데이트');

        // 각 코스에 대해 pendingMembers 업데이트
        for (final courseEnrollmentData in courseEnrollments) {
          final courseId = courseEnrollmentData['courseId'] as String;
          final totalReservations =
              courseEnrollmentData['totalReservations'] as int?;
          final validFromStr = courseEnrollmentData['validFrom'] as String?;
          final validUntilStr = courseEnrollmentData['validUntil'] as String?;

          DateTime? validFrom;
          DateTime? validUntil;
          if (validFromStr != null && validUntilStr != null) {
            validFrom = DateTime.parse(validFromStr);
            validUntil = DateTime.parse(validUntilStr);
          }

          final success = await updatePendingCourseEnrollmentConfig(
            placeId: placeId,
            phoneNumber: phoneNumber,
            courseId: courseId,
            totalReservations: totalReservations,
            validFrom: validFrom,
            validUntil: validUntil,
          );

          if (!success) {
            debugPrint('❌ [MemberService] pending 멤버 코스 등록 실패: $courseId');
            // 에러 메시지를 더 친화적으로 변경하기 위해 예외를 던짐
            throw Exception('이미 등록되어 있습니다.');
          }
        }

        debugPrint('✅ [MemberService] pending 멤버 코스 등록 완료');
        return true;
      } else {
        // 일반 멤버: enrollments 생성
        debugPrint('📝 [MemberService] 일반 멤버 코스 등록: enrollments 생성');
        return await _enrollmentService.enrollMemberToCourses(
          userId: userId,
          placeId: placeId,
          courseEnrollments: courseEnrollments,
          courses: courses,
        );
      }
    } catch (e) {
      debugPrint('❌ [MemberService] 멤버 코스 등록 실패: $e');
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
              data['requestedAt'] =
                  _timestampToDateTime(data['requestedAt']).toIso8601String();
            }
            if (data['approvedAt'] != null) {
              data['approvedAt'] =
                  _timestampToDateTime(data['approvedAt']).toIso8601String();
            }
            if (data['rejectedAt'] != null) {
              data['rejectedAt'] =
                  _timestampToDateTime(data['rejectedAt']).toIso8601String();
            }
            return PlaceMembership.fromJson(data);
          }).toList();
        });
  }

  // Helper 메서드
  DateTime _timestampToDateTime(dynamic timestamp) {
    if (timestamp == null) return TimezoneUtils.getSeoulDateTime();
    if (timestamp is Timestamp) return timestamp.toDate();
    if (timestamp is String) return DateTime.parse(timestamp);
    throw Exception('Invalid timestamp format');
  }
}
