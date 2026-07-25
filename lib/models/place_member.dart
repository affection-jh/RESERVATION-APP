import '../utils/timezone_utils.dart';
import '../utils/firestore_utils.dart';

/// 플레이스 내 멤버 역할
/// - manager: 플레이스 전체 및 모든 코스 접근·편집
/// - subManager: 특정 코스에만 제한된 매니저
/// - member: 일반 사용자
enum PlaceMemberRole { manager, subManager, member }

/// places/{placeId}/members/{uid} 문서 모델
/// 관리자(매니저·부매니저) 및 일반 사용자 정보를 통일된 구조로 관리
/// [placeId] collectionGroup 조회 시 경로에서 추출 (문서에는 없음)
class PlaceMember {
  final String userId;
  final String? placeId; // 경로 컨텍스트 (places/{placeId}/members)
  final String? adminDisplayName;
  final String? phoneNumber;
  final PlaceMemberRole role;
  final List<String> manageableCourseIds;
  final DateTime createdAt;
  final DateTime? updatedAt;

  /// 전체 탭에서 비활성 처리 시 true → 전체/모든 코스별에서 숨김
  final bool isInactive;

  /// 비활성/관리용 메모 (플레이스 단위)
  final String? inactiveMemo;

  PlaceMember({
    required this.userId,
    this.placeId,
    required this.role,
    this.adminDisplayName,
    this.phoneNumber,
    this.manageableCourseIds = const [],
    required this.createdAt,
    this.updatedAt,
    this.isInactive = false,
    this.inactiveMemo,
  });

  bool get isManager => role == PlaceMemberRole.manager;
  bool get isSubManager => role == PlaceMemberRole.subManager;
  bool get isMember => role == PlaceMemberRole.member;
  bool get canManagePlace => isManager || isSubManager;

  PlaceMember copyWith({
    String? userId,
    String? placeId,
    PlaceMemberRole? role,
    String? adminDisplayName,
    String? phoneNumber,
    List<String>? manageableCourseIds,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isInactive,
    String? inactiveMemo,
    bool clearInactiveMemo = false,
  }) {
    return PlaceMember(
      userId: userId ?? this.userId,
      placeId: placeId ?? this.placeId,
      role: role ?? this.role,
      adminDisplayName: adminDisplayName ?? this.adminDisplayName,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      manageableCourseIds:
          manageableCourseIds ?? List.from(this.manageableCourseIds),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isInactive: isInactive ?? this.isInactive,
      inactiveMemo:
          clearInactiveMemo ? null : (inactiveMemo ?? this.inactiveMemo),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'role': role.name,
      'adminDisplayName': adminDisplayName,
      'phoneNumber': phoneNumber,
      'manageableCourseIds': manageableCourseIds,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
      'isInactive': isInactive,
      if (inactiveMemo != null) 'inactiveMemo': inactiveMemo,
    };
  }

  factory PlaceMember.fromJson(Map<String, dynamic> json) {
    final roleRaw = json['role']?.toString().toLowerCase();
    final role = roleRaw == 'manager'
        ? PlaceMemberRole.manager
        : roleRaw == 'submanager'
            ? PlaceMemberRole.subManager
            : PlaceMemberRole.member;
    // List<String> 보장 (Firestore null/비리스트 시 빈 리스트)
    List<String> manageableCourseIds = const [];
    final rawManageable = json['manageableCourseIds'];
    if (rawManageable is List) {
      manageableCourseIds = rawManageable.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
    } else {
      final rawCourseIds = json['courseIds'];
      if (rawCourseIds is List) {
        manageableCourseIds = rawCourseIds.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
      }
    }
    return PlaceMember(
      userId: json['userId'] as String,
      placeId: json['placeId'] as String?,
      role: role,
      adminDisplayName: (json['adminDisplayName'] as String?) ?? (json['displayName'] as String?),
      phoneNumber: json['phoneNumber'] as String?,
      manageableCourseIds: manageableCourseIds,
      createdAt:
          json['createdAt'] != null
              ? FirestoreUtils.timestampToDateTime(json['createdAt'])
              : TimezoneUtils.getSeoulDateTime(),
      updatedAt:
          json['updatedAt'] != null
              ? FirestoreUtils.timestampToDateTime(json['updatedAt'])
              : null,
      isInactive: json['isInactive'] == true,
      inactiveMemo: json['inactiveMemo'] as String?,
    );
  }
}
