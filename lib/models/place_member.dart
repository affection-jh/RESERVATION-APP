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

  PlaceMember({
    required this.userId,
    this.placeId,
    required this.role,
    this.adminDisplayName,
    this.phoneNumber,
    this.manageableCourseIds = const [],
    required this.createdAt,
    this.updatedAt,
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
    };
  }

  factory PlaceMember.fromJson(Map<String, dynamic> json) {
    return PlaceMember(
      userId: json['userId'] as String,
      placeId: json['placeId'] as String?,
      role: PlaceMemberRole.values.firstWhere(
        (e) => e.name == json['role'],
        orElse: () => PlaceMemberRole.member,
      ),
      adminDisplayName: (json['adminDisplayName'] as String?) ?? (json['displayName'] as String?),
      phoneNumber: json['phoneNumber'] as String?,
      manageableCourseIds:
          ((json['manageableCourseIds'] as List<dynamic>?)
                  ?.map((e) => e.toString())
                  .toList() ??
              (json['courseIds'] as List<dynamic>?)
                  ?.map((e) => e.toString())
                  .toList()) ??
          [], // 하위 호환: null이면 []
      createdAt:
          json['createdAt'] != null
              ? FirestoreUtils.timestampToDateTime(json['createdAt'])
              : TimezoneUtils.getSeoulDateTime(),
      updatedAt:
          json['updatedAt'] != null
              ? FirestoreUtils.timestampToDateTime(json['updatedAt'])
              : null,
    );
  }
}
