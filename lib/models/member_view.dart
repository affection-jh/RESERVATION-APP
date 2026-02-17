import 'course_enrollment.dart';
import 'place_member.dart';

/// 멤버관리 화면용 통합 읽기 전용 View 모델
///
/// DB는 분리 유지 (members / enrollments / pendingMembers)
/// UI는 이 모델 하나로만 다룸.
///
/// 관리자 화면 표시 이름: [adminDisplayName]만 사용 (관리자가 설정한 이름).
///
/// 한 멤버가 여러 코스에 등록: [enrolledCourseIds]로 등록된 코스 ID 목록 (Provider에서 채움)
/// 서브매니저: [role] == subManager, [manageableCourseIds]에 관리 가능한 코스만 포함. UI에서 역할·권한 분기용.
class MemberView {
  final String userId;

  /// 관리자가 설정한 표시 이름. 관리자 화면에서는 이 값만 표시한다.
  final String adminDisplayName;
  final String phoneNumber;
  final PlaceMemberRole role;

  /// 이 멤버가 등록된 코스 ID 목록 (한 멤버 여러 코스 등록 커버. Provider에서 enrollments 기준으로 채움)
  final List<String> enrolledCourseIds;

  /// 부매니저일 때만 의미 있음. 관리 가능한 코스 ID 목록. manager면 [](전체), member면 []
  final List<String> manageableCourseIds;

  /// 코스별 보기일 때만 사용 (selectedCourseId에 해당하는 enrollment)
  final CourseEnrollment? enrollment;
  final bool isPending;

  const MemberView({
    required this.userId,
    required this.adminDisplayName,
    required this.phoneNumber,
    required this.role,
    this.enrolledCourseIds = const [],
    this.manageableCourseIds = const [],
    this.enrollment,
    this.isPending = false,
  });

  bool get isManager => role == PlaceMemberRole.manager;
  bool get isSubManager => role == PlaceMemberRole.subManager;
  bool get isMember => role == PlaceMemberRole.member;

  /// 매니저 또는 부매니저 (관리자 화면 접근·편집 가능)
  bool get canManagePlace => isManager || isSubManager;

  // --- UI 표시용 (기존 MemberData 호환) ---
  /// 관리자 화면 표시 이름 (adminDisplayName과 동일)
  String get name => adminDisplayName;

  /// 역할 한글 라벨: '대기중' | '매니저' | '부매니저' | '일반'
  String get roleDisplay =>
      isPending
          ? '가입 대기중'
          : isManager
          ? '매니저'
          : isSubManager
          ? '부매니저'
          : '일반';

  /// 예약 가능 여부 (대기중이 아니고 enrollment.canReserve)
  bool get isActive => !isPending && (enrollment?.canReserve ?? false);

  /// 연장 요청 대기 수 (현재 0, 필요 시 확장)
  int get pendingExtensionRequests => 0;
  bool get hasPendingRequests => pendingExtensionRequests > 0;

  /// 재등록 필요 (등록은 있으나 예약 불가, e.g. 기간 만료)
  bool get needsReenrollment => enrollment != null && !(enrollment!.canReserve);

  MemberView copyWith({
    String? userId,
    String? adminDisplayName,
    String? phoneNumber,
    PlaceMemberRole? role,
    List<String>? enrolledCourseIds,
    List<String>? manageableCourseIds,
    CourseEnrollment? enrollment,
    bool? isPending,
  }) {
    return MemberView(
      userId: userId ?? this.userId,
      adminDisplayName: adminDisplayName ?? this.adminDisplayName,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      role: role ?? this.role,
      enrolledCourseIds: enrolledCourseIds ?? this.enrolledCourseIds,
      manageableCourseIds: manageableCourseIds ?? this.manageableCourseIds,
      enrollment: enrollment ?? this.enrollment,
      isPending: isPending ?? this.isPending,
    );
  }
}
