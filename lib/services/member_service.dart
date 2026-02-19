import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import '../models/course_enrollment.dart';
import '../models/member_view.dart';
import '../models/pending_member.dart';
import '../models/place_member.dart';
import '../models/user.dart';
import '../utils/phone_utils.dart';
import '../utils/timezone_utils.dart';
import 'firestore_service.dart';
import 'auth_service.dart';
import 'enrollment_service.dart';
import 'user_service.dart';

/// 멤버 관련 Firebase 작업을 관리하는 서비스
/// - places/{placeId}/members, pendingMembers, MemberView 병합, 등록/이름/코스 등록
class MemberService {
  final FirestoreService _firestoreService = FirestoreService();
  final EnrollmentService _enrollmentService = EnrollmentService();
  final UserService _userService = UserService();
  FirebaseFirestore get _firestore => _firestoreService.firestore;

  // ==================== places/{placeId}/members ====================

  /// [uid]가 멤버로 속한 모든 플레이스 조회 (실시간)
  Stream<List<PlaceMember>> watchPlaceMembershipsForUser(String uid) {
    if (uid.isEmpty) return Stream.value([]);
    return _firestore
        .collectionGroup('members')
        .where('userId', isEqualTo: uid)
        .snapshots()
        .map((snapshot) {
          final list = <PlaceMember>[];
          for (final doc in snapshot.docs) {
            final path = doc.reference.path;
            final segments = path.split('/');
            if (segments.length >= 4 &&
                segments[0] == 'places' &&
                segments[2] == 'members') {
              final placeId = segments[1];
              final data = doc.data();
              data['userId'] = doc.id;
              try {
                final m = PlaceMember.fromJson(Map<String, dynamic>.from(data));
                list.add(m.copyWith(placeId: placeId));
              } catch (e) {
                debugPrint('[MemberService] members 파싱 실패 $placeId: $e');
              }
            }
          }
          return list;
        });
  }

  /// [uid]가 멤버로 속한 모든 플레이스 조회 (1회)
  Future<List<PlaceMember>> getPlaceMembershipsForUser(String uid) async {
    if (uid.isEmpty) return [];
    try {
      final snapshot =
          await _firestore
              .collectionGroup('members')
              .where('userId', isEqualTo: uid)
              .get();
      final list = <PlaceMember>[];
      for (final doc in snapshot.docs) {
        final path = doc.reference.path;
        final segments = path.split('/');
        if (segments.length >= 4 &&
            segments[0] == 'places' &&
            segments[2] == 'members') {
          final placeId = segments[1];
          final data = doc.data();
          data['userId'] = doc.id;
          final m = PlaceMember.fromJson(Map<String, dynamic>.from(data));
          list.add(m.copyWith(placeId: placeId));
        }
      }
      return list;
    } catch (e) {
      debugPrint('[MemberService] getPlaceMembershipsForUser 실패: $e');
      return [];
    }
  }

  static const int _defaultPageSize = 100;
  static int get pageSize => _defaultPageSize;

  /// 세그먼트(구간) 단위 멤버 실시간 구독. 슬라이딩 윈도우용.
  /// [startAfter] null이면 첫 세그먼트, 있으면 해당 doc 이후부터.
  /// (members, lastDoc) — lastDoc은 다음 세그먼트 startAfter용.
  /// 30으로 설정 시 whereIn(30) 한 번에 enrollment 구독 가능.
  static const int segmentSize = 30;

  Stream<(List<PlaceMember>, DocumentSnapshot?)> watchPlaceMembersSegment(
    String placeId, {
    DocumentSnapshot? startAfter,
    int limit = segmentSize,
  }) {
    if (placeId.isEmpty) return Stream.value((<PlaceMember>[], null));
    var query = _firestore
        .collection('places')
        .doc(placeId)
        .collection('members')
        .orderBy(FieldPath.documentId)
        .limit(limit);
    if (startAfter != null) {
      query = query.startAfterDocument(startAfter);
    }
    return query.snapshots().map((snapshot) {
      final list = <PlaceMember>[];
      for (final doc in snapshot.docs) {
        if (doc.data().isEmpty) continue;
        final data = Map<String, dynamic>.from(doc.data());
        data['userId'] = doc.id;
        try {
          list.add(PlaceMember.fromJson(data));
        } catch (e) {
          debugPrint(
            '[MemberService] watchPlaceMembersSegment 파싱 실패 ${doc.id}: $e',
          );
        }
      }
      final lastDoc =
          snapshot.docs.isNotEmpty ? snapshot.docs.last : null;
      return (list, lastDoc);
    });
  }

  /// 특정 플레이스의 멤버 구독 (places/{placeId}/members) — 하위 호환
  Stream<List<PlaceMember>> watchPlaceMembers(
    String placeId, {
    int limit = _defaultPageSize,
  }) =>
      watchPlaceMembersSegment(placeId, limit: limit).map((p) => p.$1);

  /// 멤버 추가 페이지 로드 (100개 단위). startAfter가 null이면 첫 페이지.
  /// Returns (members, lastDoc for next page). lastDoc is null if no more.
  Future<(List<PlaceMember>, DocumentSnapshot?)> getPlaceMembersPage(
    String placeId, {
    DocumentSnapshot? startAfter,
    int limit = _defaultPageSize,
  }) async {
    if (placeId.isEmpty) return (<PlaceMember>[], null);
    var query = _firestore
        .collection('places')
        .doc(placeId)
        .collection('members')
        .orderBy(FieldPath.documentId)
        .limit(limit);
    if (startAfter != null) {
      query = query.startAfterDocument(startAfter);
    }
    final snapshot = await query.get();
    final list = <PlaceMember>[];
    for (final doc in snapshot.docs) {
      if (doc.data().isEmpty) continue;
      try {
        final data = Map<String, dynamic>.from(doc.data());
        data['userId'] = doc.id;
        list.add(PlaceMember.fromJson(data));
      } catch (e) {
        debugPrint('[MemberService] getPlaceMembersPage 파싱 실패 ${doc.id}: $e');
      }
    }
    final lastDoc =
        snapshot.docs.isNotEmpty ? snapshot.docs.last : null;
    return (list, lastDoc);
  }

  /// 특정 userId 목록(최대 30개)에 해당하는 place 멤버 스트림. 부매니저 30명 롤링 윈도우용.
  Stream<List<PlaceMember>> watchPlaceMembersByUserIds(
    String placeId,
    List<String> userIds,
  ) {
    if (placeId.isEmpty || userIds.isEmpty) {
      return Stream.value([]);
    }
    final chunk = userIds.take(30).toList();
    return _firestore
        .collection('places')
        .doc(placeId)
        .collection('members')
        .where(FieldPath.documentId, whereIn: chunk)
        .snapshots()
        .map((snapshot) {
      final list = <PlaceMember>[];
      for (final doc in snapshot.docs) {
        if (doc.data().isEmpty) continue;
        try {
          final data = Map<String, dynamic>.from(doc.data());
          data['userId'] = doc.id;
          list.add(PlaceMember.fromJson(data));
        } catch (e) {
          debugPrint(
            '[MemberService] watchPlaceMembersByUserIds 파싱 실패 ${doc.id}: $e',
          );
        }
      }
      return list;
    });
  }

  /// 여러 userId에 해당하는 PlaceMember 목록 조회 (부매니저 코스별 로드용). Firestore 'in' 최대 30개씩 청크.
  Future<List<PlaceMember>> getPlaceMembersByUserIds(
    String placeId,
    List<String> userIds,
  ) async {
    if (placeId.isEmpty || userIds.isEmpty) return [];
    final distinct = userIds.toSet().toList();
    final list = <PlaceMember>[];
    const chunkSize = 30;
    for (var i = 0; i < distinct.length; i += chunkSize) {
      final chunk = distinct.skip(i).take(chunkSize).toList();
      final snapshot = await _firestore
          .collection('places')
          .doc(placeId)
          .collection('members')
          .where(FieldPath.documentId, whereIn: chunk)
          .get();
      for (final doc in snapshot.docs) {
        if (doc.data().isEmpty) continue;
        try {
          final data = Map<String, dynamic>.from(doc.data());
          data['userId'] = doc.id;
          list.add(PlaceMember.fromJson(data));
        } catch (e) {
          debugPrint('[MemberService] getPlaceMembersByUserIds 파싱 실패 ${doc.id}: $e');
        }
      }
    }
    return list;
  }

  Future<PlaceMember?> getPlaceMember(String placeId, String uid) async {
    try {
      final doc =
          await _firestore
              .collection('places')
              .doc(placeId)
              .collection('members')
              .doc(uid)
              .get();
      if (!doc.exists || doc.data() == null) return null;
      final data = Map<String, dynamic>.from(doc.data()!);
      data['userId'] = doc.id;
      return PlaceMember.fromJson(data);
    } catch (e) {
      debugPrint('[MemberService] getPlaceMember 실패: $e');
      return null;
    }
  }

  Future<void> setPlaceMember(
    String placeId,
    String uid,
    PlaceMember member,
  ) async {
    final ref = _firestore
        .collection('places')
        .doc(placeId)
        .collection('members')
        .doc(uid);
    final json = member.toJson();
    // userId 저장 (collectionGroup 쿼리용)
    await ref.set(json);
  }

  Future<void> removePlaceMember(String placeId, String uid) async {
    await _firestore
        .collection('places')
        .doc(placeId)
        .collection('members')
        .doc(uid)
        .delete();
  }

  /// 로그인 후 이 유저가 속한 플레이스 ID 목록 (매니저/부매니저만, 또는 전체)
  Future<List<String>> getPlaceIdsForUser(
    String uid, {
    bool managersOnly = false,
  }) async {
    final members = await getPlaceMembershipsForUser(uid);
    if (managersOnly) {
      return members
          .where((m) => m.canManagePlace)
          .map((m) => m.placeId!)
          .where((id) => id.isNotEmpty)
          .toList();
    }
    return members.map((m) => m.placeId).whereType<String>().toList();
  }

  // ==================== MemberView (members + pendingMembers) ====================

  /// placeId 기준 members + pendingMembers를 합쳐 MemberView 스트림 (UI용)
  Stream<List<MemberView>> watchMemberViews(String placeId, {int membersLimit = _defaultPageSize}) {
    if (placeId.isEmpty) return Stream.value([]);
    List<PlaceMember> lastMembers = [];
    List<PendingMember> lastPending = [];
    final controller = StreamController<List<MemberView>>.broadcast();

    void emit() {
      final views = <MemberView>[];
      for (final m in lastMembers) {
        views.add(MemberView.fromPlaceMember(m));
      }
      for (final p in lastPending) {
        views.add(MemberView.fromPendingMember(p));
      }
      if (!controller.isClosed) controller.add(views);
    }

    final sub1 = watchPlaceMembers(placeId, limit: membersLimit).listen(
      (list) {
        lastMembers = list;
        emit();
      },
      onError: (e) {
        debugPrint('[MemberService] watchPlaceMembers error: $e');
      },
    );
    final sub2 = watchPendingMembersByPlace(placeId, limit: membersLimit).listen(
      (list) {
        lastPending = list;
        emit();
      },
      onError: (e) {
        debugPrint('[MemberService] watchPendingMembers error: $e');
      },
    );

    controller.onCancel = () {
      sub1.cancel();
      sub2.cancel();
      if (!controller.isClosed) controller.close();
    };
    return controller.stream;
  }

  /// placeId 기준 enrollments 스트림
  Stream<List<CourseEnrollment>> watchEnrollmentsByPlace(String placeId) {
    return _enrollmentService.watchEnrollmentsByPlace(placeId);
  }

  /// 슬라이딩 윈도우: 현재 로드된 멤버 userId 목록에 한해 enrollments 구독
  Stream<List<CourseEnrollment>> watchEnrollmentsForUserIds(
    String placeId,
    List<String> userIds,
  ) {
    return _enrollmentService.watchEnrollmentsForUserIds(placeId, userIds);
  }

  /// 전화번호 정규화 (숫자만 추출, 82로 시작하면 0으로 변환)
  String _normalizePhone(String phoneNumber) {
    return PhoneUtils.normalizeForStorage(phoneNumber);
  }

  /// places/{placeId}/pendingMembers/{inviteId} 참조. inviteId = placeId_normalizedPhone
  DocumentReference _pendingRef(String placeId, String normalizedPhone) {
    final inviteId = '${placeId}_$normalizedPhone';
    return _firestore
        .collection('places')
        .doc(placeId)
        .collection('pendingMembers')
        .doc(inviteId);
  }

  /// pending 멤버의 role만 변경 (예: 전체 매니저 초대 해제 시 role 'manager' → 'member')
  /// [pendingDocId] userId가 'pending_xxx'일 때 'xxx' 부분 (placeId_normalizedPhone)
  Future<bool> updatePendingMemberRole(
    String placeId,
    String pendingDocId,
    String role,
  ) async {
    try {
      final ref = _firestore
          .collection('places')
          .doc(placeId)
          .collection('pendingMembers')
          .doc(pendingDocId);
      await ref.update({
        'role': role,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return true;
    } catch (e) {
      debugPrint('❌ [MemberService] updatePendingMemberRole 실패: $e');
      return false;
    }
  }

  /// 부매니저가 관리 코스 0개일 때 일반 멤버로 전락 (서버에서 role·manageableCourseIds 갱신)
  Future<bool> demoteSubManagerToMemberIfNoCourses(String placeId) async {
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('demoteSubManagerToMemberIfNoCourses')
          .call({'placeId': placeId});
      final data = result.data as Map<String, dynamic>?;
      return data != null && data['demoted'] == true;
    } catch (e) {
      debugPrint('❌ [MemberService] demoteSubManagerToMemberIfNoCourses 실패: $e');
      return false;
    }
  }

  /// 코스별 부매니저 초대 (inviteSubManagerForCourse Callable)
  /// 기존 pending이 subManager면 managedCourseIds에 courseId 추가, 없으면 새 pending 생성.
  /// 기존 일반 멤버면 부매니저로 승격(manageableCourseIds 추가, role: subManager).
  /// 실패 시 [FirebaseFunctionsException]을 그대로 전달해 호출부에서 스낵바 등 처리 가능.
  Future<bool> inviteSubManagerForCourse({
    required String placeId,
    required String courseId,
    required String phoneNumber,
    String? adminDisplayName,
  }) async {
    final normalized = _normalizePhone(phoneNumber);
    if (normalized.length != 11) return false;
    final result = await FirebaseFunctions.instance
        .httpsCallable('inviteSubManagerForCourse')
        .call({
      'placeId': placeId,
      'courseId': courseId,
      'phoneNumber': normalized,
      if (adminDisplayName != null && adminDisplayName.trim().isNotEmpty)
        'adminDisplayName': adminDisplayName.trim(),
    });
    final data = result.data as Map<String, dynamic>?;
    return data != null && data['success'] == true;
  }

  /// 전체 매니저 초대 (전화번호 직접 입력, 코스매니저와 동일 우선순위: pending → users/members → pending 생성)
  Future<bool> inviteFullManager({
    required String placeId,
    required String phoneNumber,
    String? adminDisplayName,
  }) async {
    final normalized = _normalizePhone(phoneNumber);
    if (normalized.length != 11) return false;
    final result = await FirebaseFunctions.instance
        .httpsCallable('inviteFullManager')
        .call({
      'placeId': placeId,
      'phoneNumber': normalized,
      if (adminDisplayName != null && adminDisplayName.trim().isNotEmpty)
        'adminDisplayName': adminDisplayName.trim(),
    });
    final data = result.data as Map<String, dynamic>?;
    return data != null && data['success'] == true;
  }

  /// 코스별 부매니저 지정 취소 (manageableCourseIds / allowedCourseIds에서 해당 코스 제거)
  /// [targetUserId] members 문서 id 또는 pending이면 'pending_${pendingDocId}'
  Future<bool> removeSubManagerFromCourse({
    required String placeId,
    required String courseId,
    required String targetUserId,
  }) async {
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('removeSubManagerFromCourse')
          .call({
        'placeId': placeId,
        'courseId': courseId,
        'targetUserId': targetUserId,
      });
      final data = result.data as Map<String, dynamic>?;
      return data != null && data['success'] == true && data['removed'] == true;
    } catch (e) {
      debugPrint('❌ [MemberService] removeSubManagerFromCourse 실패: $e');
      return false;
    }
  }

  /// 멤버 등록 (초대 토큰 생성 및/또는 enrollments 생성)
  ///
  /// User 없으면: places/{placeId}/pendingMembers에 초대 토큰만 생성 (phoneNumber, invitedBy, role, allowedCourseIds, createdAt).
  /// User 있으면: enrollments만 생성.
  ///
  /// [placeId] 플레이스 ID
  /// [adminId] 초대한 관리자 ID (invitedBy)
  /// [name] 미사용 (pending 단순화로 저장 안 함)
  /// [phoneNumber] 전화번호
  /// [courseEnrollments] 코스별 설정 (pending에는 courseId 목록만 allowedCourseIds로 저장)
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

      // courseEnrollments에서 courseIds 추출 (null/빈 값 무시)
      final rawList = courseEnrollments ?? <Map<String, dynamic>>[];
      final courseIds = <String>[
        for (final e in rawList)
          if (e['courseId'] != null && (e['courseId'] as String).trim().isNotEmpty)
            (e['courseId'] as String).trim(),
      ];

      debugPrint(
        '🔥 [MemberService] courseIds: $courseIds (개수: ${courseIds.length})',
      );
      debugPrint('🔥 [MemberService] courseEnrollments: $courseEnrollments');

      // 성능 최적화: 코스 조회를 Map으로 캐싱 (O(1) 접근). null 항목 무시.
      final courseMap = <String, dynamic>{};
      if (courses.isNotEmpty) {
        for (final course in courses) {
          if (course == null) continue;
          final id = (course as dynamic).id;
          if (id != null && id is String) courseMap[id] = course;
        }
      }

      // 성능 최적화: courseEnrollments를 Map으로 변환 (빠른 조회)
      final courseEnrollmentMap = <String, Map<String, dynamic>>{};
      for (final enrollment in rawList) {
        final courseId = enrollment['courseId'];
        if (courseId != null && courseId is String && courseId.trim().isNotEmpty) {
          courseEnrollmentMap[courseId.trim()] = enrollment;
        }
      }

      final pendingRef = _pendingRef(placeId, normalizedPhone);
      final pendingDoc = await pendingRef.get();
      if (pendingDoc.exists) {
        debugPrint(
          '❌ [MemberService] 이미 해당 전화번호로 초대됨: $placeId / $normalizedPhone',
        );
        return false;
      }

      // Cloud Function으로 처리 (클라이언트 Firestore 권한 이슈 회피)
      // - 기존 사용자: enrollments + place member
      // - 미가입: places/{placeId}/pendingMembers
      debugPrint('🔥 [MemberService] registerMemberByAdmin 호출');
      final enrollmentPayload = <Map<String, dynamic>>[];
      for (final courseId in courseIds) {
        final config = courseEnrollmentMap[courseId];
        final course = courseMap[courseId];
        final defaultTotal = course != null
            ? ((course as dynamic).defaultTotalReservations as int?) ?? 10
            : 10;
        final total = config?['totalReservations'];
        enrollmentPayload.add({
          'courseId': courseId,
          'totalReservations': (total is int) ? total : (total is num) ? total.toInt() : defaultTotal,
          'validFrom': config?['validFrom']?.toString(),
          'validUntil': config?['validUntil']?.toString(),
        });
      }

      final result = await FirebaseFunctions.instance
          .httpsCallable('registerMemberByAdmin')
          .call({
            'placeId': placeId,
            'phoneNumber': phoneNumber,
            'name': name.trim(),
            'courseEnrollments': enrollmentPayload,
          });
      final data = result.data as Map<String, dynamic>?;
      if (data == null || data['success'] != true) {
        debugPrint('❌ [MemberService] registerMemberByAdmin 실패');
        return false;
      }
      // sendInvitation Cloud Function은 미구현이므로 호출하지 않음 (기존 사용자는 로그인 시 자동 매칭)
      final existingUser = data['existingUser'] as bool? ?? false;
      if (existingUser) {
        debugPrint(
          'ℹ️ [MemberService] 기존 사용자 등록됨 (로그인 시 자동 매칭)',
        );
      }

      debugPrint('✅ [MemberService] 멤버 등록 완료');
      return true;
    } catch (e) {
      debugPrint('❌ [MemberService] 멤버 등록 실패: $e');
      return false;
    }
  }

  /// 멤버 표시 이름 업데이트 (관리자용)
  ///
  /// Firestore rules 상 타인 `users` 문서는 수정이 막혀있을 수 있으므로,
  /// enrollment.adminDisplayName(관리자에게 보이는 이름)으로 저장한다.
  ///
  /// [placeId] 플레이스 ID
  /// [phoneNumber] 전화번호
  /// [newName] 새로운 표시 이름
  ///
  /// Returns: 업데이트 성공 여부
  Future<bool> updateMemberName({
    required String placeId,
    required String phoneNumber,
    required String newName,
  }) async {
    try {
      debugPrint('🔥 [MemberService] 멤버 이름 업데이트 시작');
      debugPrint(
        '🔥 [MemberService] placeId: $placeId, phoneNumber: $phoneNumber, newName: $newName',
      );

      // 전화번호 정규화
      final normalizedPhone = _normalizePhone(phoneNumber);
      if (normalizedPhone.length != 11) {
        debugPrint('❌ [MemberService] 전화번호 형식 오류: $normalizedPhone');
        return false;
      }

      // User 찾기
      debugPrint('🔍 [MemberService] User 조회 시작');
      final authService = AuthService();
      final user = await authService.findUserByPhone(normalizedPhone);

      if (user != null) {
        debugPrint('✅ [MemberService] User 발견: ${user.userId}');

        final trimmed = newName.trim();
        if (trimmed.isEmpty) {
          debugPrint('❌ [MemberService] newName empty');
          return false;
        }

        // places/{placeId}/members/{userId}의 adminDisplayName 업데이트 (MemberView 소스)
        final memberRef = _firestore
            .collection('places')
            .doc(placeId)
            .collection('members')
            .doc(user.userId);
        await memberRef.set({
          'adminDisplayName': trimmed,
          'updatedAt': Timestamp.fromDate(TimezoneUtils.getSeoulDateTime()),
        }, SetOptions(merge: true));
        debugPrint('✅ [MemberService] place/members adminDisplayName 업데이트 완료');

        await _enrollmentService.updateAdminDisplayNameForUserInPlace(
          placeId,
          user.userId,
          trimmed,
        );
        debugPrint('✅ [MemberService] enrollment adminDisplayName 업데이트 완료');

        // 관리자가 본인을 수정할 때: users 컬렉션 name도 동기화
        final authUid = AuthService().currentFirebaseUser?.uid;
        if (authUid == user.userId) {
          final now = TimezoneUtils.getSeoulDateTime();
          final updatedUser = user.copyWith(username: trimmed, updatedAt: now);
          await _userService.updateUserDirect(updatedUser);
          debugPrint('✅ [MemberService] users 컬렉션 이름 동기화 완료 (본인)');
        }
        return true;
      }

      final trimmed = newName.trim();
      if (trimmed.isEmpty) {
        return false;
      }
      final pendingRef = _pendingRef(placeId, normalizedPhone);
      final pendingSnap = await pendingRef.get();
      if (!pendingSnap.exists) {
        return false;
      }
      await pendingRef.update({'adminDisplayName': trimmed});

      return true;
    } catch (e) {
      debugPrint('❌ [MemberService] 멤버 이름 업데이트 실패: $e');
      return false;
    }
  }

  /// 관리자 본인이 설정에서 이름 변경 시: 모든 소속 플레이스의 members.adminDisplayName 동기화
  /// (users 컬렉션은 호출측에서 이미 업데이트한 뒤 호출)
  Future<void> updateMemberDisplayNameInAllPlaces(
    String userId,
    String newName,
  ) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;

    final memberships = await getPlaceMembershipsForUser(userId);
    final now = TimezoneUtils.getSeoulDateTime();

    for (final m in memberships) {
      final placeId = m.placeId;
      if (placeId == null || placeId.isEmpty) continue;
      try {
        final memberRef = _firestore
            .collection('places')
            .doc(placeId)
            .collection('members')
            .doc(userId);
        await memberRef.set({
          'adminDisplayName': trimmed,
          'updatedAt': Timestamp.fromDate(now),
        }, SetOptions(merge: true));
        await _enrollmentService.updateAdminDisplayNameForUserInPlace(
          placeId,
          userId,
          trimmed,
        );
      } catch (e) {
        debugPrint(
          '[MemberService] updateMemberDisplayNameInAllPlaces placeId=$placeId: $e',
        );
      }
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
      if (user.username != name) {
        updatedUser = user.copyWith(
          username: name,
          updatedAt: TimezoneUtils.getSeoulDateTime(),
        );
        await _userService.updateUserDirect(updatedUser);
        debugPrint('✅ [MemberService] 이름 업데이트 완료');
      }
      final trimmedName = name.trim();
      if (trimmedName.isNotEmpty) {
        await _enrollmentService.updateAdminDisplayNameForUserInPlace(
          placeId,
          updatedUser.userId,
          trimmedName,
        );
      }

      // 코스 등록 업데이트
      final now = TimezoneUtils.getSeoulDateTime();
      final currentEnrollments =
          await _enrollmentService
              .watchUserEnrollments(updatedUser.userId, placeId: placeId)
              .first;
      final currentEnrolledCourseIds =
          currentEnrollments
              .where((e) => e.isValid)
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

        final displayName = name.trim().isNotEmpty ? name.trim() : '';
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
          adminDisplayName: displayName,
          userName: displayName,
        );

        debugPrint('✨ [MemberService] enrollment 생성: ${enrollment.id}');
        await _enrollmentService.createEnrollment(enrollment);
        debugPrint('✅ [MemberService] enrollment 생성 완료');
      }

      // 코스 등록 제거 (수강취소: enrollment 완전 삭제)
      for (final courseId in coursesToRemove) {
        debugPrint('🗑️ [MemberService] 코스 제거 시작: $courseId');
        try {
          await _enrollmentService.cancelEnrollment(
            placeId: placeId,
            userId: updatedUser.userId,
            courseId: courseId,
            cascade: false,
          );
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

  /// 플레이스별 pendingMembers 조회 (places/{placeId}/pendingMembers)
  Stream<List<PendingMember>> watchPendingMembersByPlace(
    String placeId, {
    int limit = _defaultPageSize,
  }) {
    return _firestore
        .collection('places')
        .doc(placeId)
        .collection('pendingMembers')
        .orderBy(FieldPath.documentId)
        .limit(limit)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs
              .map((doc) {
                try {
                  final data = doc.data();
                  if (data['phoneNumber'] == null) {
                    debugPrint(
                      '[MemberService] watchPendingMembersByPlace: phoneNumber 누락 - docId: ${doc.id}',
                    );
                    return null;
                  }
                  return PendingMember.fromJson(
                    data,
                    docId: doc.id,
                    placeId: placeId,
                  );
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

  /// 플레이스별 멤버 userId 목록 (enrollment 단일 소스)
  Stream<List<String>> watchPlaceMemberUserIds(String placeId) {
    return _enrollmentService.watchPlaceMemberUserIds(placeId);
  }

  /// 플레이스별 관리자 표시 이름(adminDisplayName) 맵
  Stream<Map<String, String>> watchPlaceMembershipDisplayNamesByPlace(
    String placeId,
  ) {
    return _enrollmentService.watchEnrollmentAdminDisplayNamesByPlace(placeId);
  }

  /// pendingMembers의 courseEnrollments에서 해당 코스의 totalReservations, remainingReservations, validFrom, validUntil 업데이트
  Future<bool> updatePendingCourseEnrollmentConfig({
    required String placeId,
    required String phoneNumber,
    required String courseId,
    int? totalReservations,
    int? remainingReservations,
    DateTime? validFrom,
    DateTime? validUntil,
  }) async {
    try {
      final normalizedPhone = _normalizePhone(phoneNumber);
      final pendingRef = _pendingRef(placeId, normalizedPhone);
      final snap = await pendingRef.get();
      if (!snap.exists) {
        debugPrint('❌ [MemberService] updatePendingCourseEnrollmentConfig: pending 문서 없음');
        return false;
      }
      final data = snap.data() as Map<String, dynamic>?;
      if (data == null) return false;

      final raw = data['courseEnrollments'];
      if (raw is! List || raw.isEmpty) {
        debugPrint('❌ [MemberService] updatePendingCourseEnrollmentConfig: courseEnrollments 없음');
        return false;
      }

      final courseEnrollments = List<Map<String, dynamic>>.from(
        raw.map((e) => Map<String, dynamic>.from(e is Map ? e : {})),
      );
      int foundIndex = -1;
      for (int i = 0; i < courseEnrollments.length; i++) {
        if ((courseEnrollments[i]['courseId'] as String?) == courseId) {
          foundIndex = i;
          break;
        }
      }
      if (foundIndex < 0) {
        debugPrint('❌ [MemberService] updatePendingCourseEnrollmentConfig: 해당 코스 없음');
        return false;
      }

      final item = courseEnrollments[foundIndex];
      final newTotal = totalReservations ?? (item['totalReservations'] as int? ?? 0);
      final newRemaining = remainingReservations ?? newTotal;
      final now = Timestamp.now();

      courseEnrollments[foundIndex] = {
        ...item,
        'totalReservations': newTotal,
        'remainingReservations': newRemaining,
        if (validFrom != null) 'validFrom': Timestamp.fromDate(validFrom),
        if (validUntil != null) 'validUntil': Timestamp.fromDate(validUntil),
        'updatedAt': now,
      };

      await pendingRef.update({'courseEnrollments': courseEnrollments});
      debugPrint('✅ [MemberService] updatePendingCourseEnrollmentConfig 완료: total=$newTotal, remaining=$newRemaining');
      return true;
    } catch (e) {
      debugPrint('❌ [MemberService] updatePendingCourseEnrollmentConfig 실패: $e');
      return false;
    }
  }

  /// pendingMembers에서 특정 코스 제거 (플레이스 전체). managedCourseIds + allowedCourseIds + courseEnrollments에서 제거.
  Future<int> removeCourseFromAllPendingMembers({
    required String placeId,
    required String courseId,
  }) async {
    try {
      int updatedCount = 0;
      final snapshot =
          await _firestore
              .collection('places')
              .doc(placeId)
              .collection('pendingMembers')
              .get();

      final batch = _firestore.batch();
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final rawManaged = data['managedCourseIds'];
        final managedList =
            rawManaged is List ? rawManaged.map((e) => e.toString()).toList() : <String>[];
        final hasInManaged = managedList.contains(courseId);
        final nextManaged = managedList.where((e) => e != courseId).toList();

        final raw = data['allowedCourseIds'];
        final list =
            raw is List ? raw.map((e) => e.toString()).toList() : <String>[];
        final hasInAllowed = list.contains(courseId);
        final nextAllowed = list.where((e) => e != courseId).toList();

        final rawEnrollments = data['courseEnrollments'];
        List<dynamic> nextEnrollments;
        if (rawEnrollments is List) {
          nextEnrollments = rawEnrollments
              .where((e) =>
                  (e is Map ? e['courseId']?.toString() : null) != courseId)
              .toList();
        } else {
          nextEnrollments = [];
        }
        final hasInEnrollments = rawEnrollments is List &&
            rawEnrollments.length != nextEnrollments.length;

        if (!hasInManaged && !hasInAllowed && !hasInEnrollments) continue;

        final updates = <String, dynamic>{};
        if (hasInManaged) updates['managedCourseIds'] = nextManaged;
        if (hasInAllowed) updates['allowedCourseIds'] = nextAllowed;
        if (hasInEnrollments) {
          updates['courseEnrollments'] = nextEnrollments
              .map((e) => e is Map ? Map<String, dynamic>.from(e) : e)
              .toList();
        }
        batch.update(doc.reference, updates);
        updatedCount++;
      }
      if (updatedCount > 0) await batch.commit();
      debugPrint('✅ [MemberService] pendingMembers에서 코스 제거 완료: $updatedCount개');
      return updatedCount;
    } catch (e) {
      debugPrint('❌ [MemberService] pendingMembers에서 코스 제거 실패: $e');
      rethrow;
    }
  }

  /// pendingMembers에서 특정 코스 제거 (managedCourseIds + allowedCourseIds + courseEnrollments에서 제거)
  Future<bool> removeCourseFromPendingMembers({
    required String placeId,
    required String phoneNumber,
    required String courseId,
    bool keepPendingMember = false,
  }) async {
    try {
      final normalizedPhone = _normalizePhone(phoneNumber);
      final pendingRef = _pendingRef(placeId, normalizedPhone);
      final snap = await pendingRef.get();
      if (!snap.exists) return true;
      final data = snap.data() as Map<String, dynamic>?;
      if (data == null) return true;

      final rawManaged = data['managedCourseIds'];
      final managedList =
          rawManaged is List ? rawManaged.map((e) => e.toString()).toList() : <String>[];
      final hasInManaged = managedList.contains(courseId);
      final nextManaged = managedList.where((e) => e != courseId).toList();

      final raw = data['allowedCourseIds'];
      final allowedList =
          raw is List ? raw.map((e) => e.toString()).toList() : <String>[];
      final hasInAllowed = allowedList.contains(courseId);
      final nextAllowed = allowedList.where((e) => e != courseId).toList();

      final rawEnrollments = data['courseEnrollments'];
      List<dynamic> nextEnrollments;
      int originalCount = 0;
      if (rawEnrollments is List) {
        final list = rawEnrollments;
        originalCount = list.length;
        nextEnrollments = list
            .where((e) =>
                (e is Map ? e['courseId']?.toString() : null) != courseId)
            .toList();
      } else {
        nextEnrollments = [];
      }
      final hasInEnrollments = originalCount != nextEnrollments.length;

      if (!hasInManaged && !hasInAllowed && !hasInEnrollments) return true;

      final updates = <String, dynamic>{};
      if (hasInManaged) updates['managedCourseIds'] = nextManaged;
      if (hasInAllowed) updates['allowedCourseIds'] = nextAllowed;
      if (hasInEnrollments) {
        updates['courseEnrollments'] =
            nextEnrollments.map((e) => e is Map ? Map<String, dynamic>.from(e) : e).toList();
      }
      await pendingRef.update(updates);
      return true;
    } catch (e) {
      debugPrint('❌ [MemberService] removeCourseFromPendingMembers 실패: $e');
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
  /// [adminDisplayName] 관리자 표시 이름 (enrollment 생성 시 저장, 누락 방지)
  ///
  /// Returns: 등록 성공 여부
  Future<bool> enrollMemberToCourseOrUpdatePending({
    required String userId,
    required String placeId,
    required String phoneNumber,
    required List<Map<String, dynamic>> courseEnrollments,
    required List<dynamic> courses,
    String? adminId,
    String? adminDisplayName,
  }) async {
    try {
      final isPending = userId.startsWith('pending_');

      if (isPending) {
        // pending: courseEnrollments에 수강 설정 저장 (관리코스(managedCourseIds)와 분리)
        final normalizedPhone = _normalizePhone(phoneNumber);
        final ref = _pendingRef(placeId, normalizedPhone);
        final snap = await ref.get();
        if (!snap.exists) {
          debugPrint('❌ [MemberService] pending 문서 없음');
          return false;
        }
        final data = snap.data() as Map<String, dynamic>?;
        if (data == null) return false;
        final existingRaw = data['courseEnrollments'];
        final existing =
            existingRaw is List
                ? existingRaw
                    .whereType<dynamic>()
                    .map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{})
                    .where((m) => (m['courseId'] as String?)?.trim().isNotEmpty == true)
                    .toList()
                : <Map<String, dynamic>>[];

        final byCourse = <String, Map<String, dynamic>>{
          for (final e in existing) (e['courseId'] as String).trim(): e,
        };
        for (final ce in courseEnrollments) {
          final id = (ce['courseId'] as String?)?.trim();
          if (id == null || id.isEmpty) continue;
          byCourse[id] = {
            ...byCourse[id] ?? <String, dynamic>{'courseId': id},
            ...ce,
          };
        }
        await ref.update({'courseEnrollments': byCourse.values.toList()});
        debugPrint('✅ [MemberService] pending courseEnrollments 업데이트 완료');
        return true;
      } else {
        // 일반 멤버: Cloud Function으로 enrollment 생성 (클라이언트 permission-denied 회피)
        debugPrint('📝 [MemberService] 일반 멤버 코스 등록: addEnrollmentForExistingMember 호출');
        final payload = <Map<String, dynamic>>[];
        for (final ce in courseEnrollments) {
          final courseId = ce['courseId'] as String?;
          if (courseId == null || courseId.isEmpty) continue;
          dynamic course;
          try {
            course = courses.firstWhere(
              (c) => (c as dynamic).id == courseId,
              orElse: () => null,
            );
          } catch (_) {
            course = null;
          }
          final defaultTotal = (course as dynamic)?.defaultTotalReservations ?? 10;
          payload.add({
            'courseId': courseId,
            'totalReservations': ce['totalReservations'] ?? defaultTotal,
            'validFrom': ce['validFrom']?.toString(),
            'validUntil': ce['validUntil']?.toString(),
          });
        }
        if (payload.isEmpty) {
          debugPrint('❌ [MemberService] 등록할 코스 없음');
          return false;
        }
        final result = await FirebaseFunctions.instance
            .httpsCallable('addEnrollmentForExistingMember')
            .call({
          'placeId': placeId,
          'userId': userId,
          'courseEnrollments': payload,
          'adminDisplayName': (adminDisplayName ?? '').trim(),
        });
        final data = result.data as Map<String, dynamic>?;
        final success = data != null && data['success'] == true;
        if (success) {
          debugPrint('✅ [MemberService] addEnrollmentForExistingMember 성공: ${data['added']}개');
        }
        return success;
      }
    } catch (e) {
      debugPrint('❌ [MemberService] 멤버 코스 등록 실패: $e');
      return false;
    }
  }

  // ==================== Place IDs (enrollment + pending) ====================

  /// pendingMembers에서 전화번호로 초대된 플레이스 ID 목록 구독
  Stream<List<String>> watchPendingPlaceIds(String phoneNumber) {
    final normalized = _normalizePhone(phoneNumber);
    if (normalized.isEmpty || normalized.length != 11) {
      return Stream.value([]);
    }
    return _firestore
        .collectionGroup('pendingMembers')
        .where('phoneNumber', isEqualTo: normalized)
        .snapshots()
        .map((snapshot) {
          final placeIds = <String>{};
          for (final doc in snapshot.docs) {
            final path = doc.reference.path;
            final parts = path.split('/');
            if (parts.length >= 2 && parts[0] == 'places') {
              placeIds.add(parts[1]);
            }
          }
          return placeIds.toList();
        });
  }

  /// enrollment + pending 통합: 접근 가능 플레이스 ID 실시간 구독
  ///
  /// 비용: Firestore 실시간 리스너 2개(enrollments + pendingMembers). 호출 측에서
  /// dispose 시 반드시 subscription.cancel() 해야 리스너 해제·누수 방지.
  Stream<List<String>> watchUserPlaceIdsIncludingPending(
    String userId, {
    String? phoneNumber,
  }) {
    if (userId.isEmpty) {
      return Stream.value([]);
    }

    final controller = StreamController<List<String>>.broadcast();
    List<String> lastEnrollment = [];
    List<String> lastPending = [];
    void emit() {
      if (controller.isClosed) return;
      final merged = <String>{...lastEnrollment, ...lastPending};
      controller.add(merged.toList());
    }

    final sub1 = watchUserPlaceIds(userId).listen(
      (ids) {
        lastEnrollment = ids;
        emit();
      },
      onError: (Object e, StackTrace st) {
        debugPrint('[MemberService] watchUserPlaceIds error (빈 목록으로 계속): $e');
        lastEnrollment = [];
        emit();
      },
    );

    final hasPhone = phoneNumber != null && phoneNumber.trim().isNotEmpty;
    StreamSubscription<List<String>>? sub2;
    if (hasPhone) {
      sub2 = watchPendingPlaceIds(phoneNumber).listen(
        (ids) {
          lastPending = ids;
          emit();
        },
        onError: (Object e, StackTrace st) {
          debugPrint(
            '[MemberService] watchPendingPlaceIds error (빈 목록으로 계속): $e',
          );
          lastPending = [];
          emit();
        },
      );
    } else {
      emit();
    }

    controller.onCancel = () {
      sub1.cancel();
      sub2?.cancel();
      if (!controller.isClosed) {
        controller.close();
      }
    };
    return controller.stream;
  }

  /// 사용자별 접근 가능 플레이스 ID 실시간 구독 (places/{placeId}/members 기준)
  ///
  /// DB 구조상 "플레이스 소속 멤버"는 members 서브컬렉션으로 관리하므로,
  /// enrollment가 아닌 collectionGroup('members')를 소스로 사용.
  Stream<List<String>> watchUserPlaceIds(String userId) {
    return watchPlaceMembershipsForUser(userId).map((members) {
      final ids =
          members
              .map((m) => m.placeId)
              .whereType<String>()
              .where((id) => id.isNotEmpty)
              .toSet();
      return ids.toList();
    });
  }
}
