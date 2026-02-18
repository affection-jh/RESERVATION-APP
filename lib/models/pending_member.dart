import 'package:cloud_firestore/cloud_firestore.dart';

import 'place_member.dart';

/// 초대 토큰 (가입/수락 전 임시 상태)
///
/// places/{placeId}/pendingMembers/{inviteId}
/// - 계약·멤버 아님. 초대만 저장.
/// - totalReservations, validFrom, enrollments, 상태 히스토리 없음.
/// - adminDisplayName: 관리자가 지정한 표시 이름 (UI용, 가입 시 member로 이관)
class PendingMember {
  /// 문서 ID (inviteId). 보통 placeId_phoneNumber
  final String id;
  final String placeId;
  final String phoneNumber;
  final String invitedBy;
  final PlaceMemberRole role;
  /// (레거시) subManager일 때만 사용. manager/member는 []
  /// ⚠️ 과거에는 "수강 코스"를 임시로 담는 용도로도 사용되어 혼용 이슈가 있었음.
  final List<String> allowedCourseIds;
  /// subManager가 관리하는 코스 ID 목록 (관리코스 단일 소스)
  final List<String> managedCourseIds;
  /// courseEnrollments 배열의 courseId 목록 (멤버 등록 시 등장, allowedCourseIds와 병합하여 수강 리스트 표시)
  final List<String> courseIdsFromEnrollments;
  /// 관리자 지정 표시 이름 (가입 시 member로 이관)
  final String? adminDisplayName;
  final DateTime createdAt;

  PendingMember({
    required this.id,
    required this.placeId,
    required this.phoneNumber,
    required this.invitedBy,
    required this.role,
    this.allowedCourseIds = const [],
    this.managedCourseIds = const [],
    this.courseIdsFromEnrollments = const [],
    this.adminDisplayName,
    required this.createdAt,
  });

  /// 초대된 코스 ID (subManager: managedCourseIds 우선, 없으면 allowedCourseIds. 그 외: [])
  List<String> get derivedCourseIds =>
      managedCourseIds.isNotEmpty ? managedCourseIds : allowedCourseIds;

  /// 표시용: (관리코스 + 레거시 allowed) ∪ courseEnrollments의 courseId
  List<String> get effectiveCourseIds {
    final set = <String>{
      ...managedCourseIds,
      ...allowedCourseIds,
      ...courseIdsFromEnrollments,
    };
    return set.toList();
  }

  PendingMember copyWith({
    String? id,
    String? placeId,
    String? phoneNumber,
    String? invitedBy,
    PlaceMemberRole? role,
    List<String>? allowedCourseIds,
    List<String>? managedCourseIds,
    List<String>? courseIdsFromEnrollments,
    String? adminDisplayName,
    DateTime? createdAt,
  }) {
    return PendingMember(
      id: id ?? this.id,
      placeId: placeId ?? this.placeId,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      invitedBy: invitedBy ?? this.invitedBy,
      role: role ?? this.role,
      allowedCourseIds: allowedCourseIds ?? this.allowedCourseIds,
      managedCourseIds: managedCourseIds ?? this.managedCourseIds,
      courseIdsFromEnrollments: courseIdsFromEnrollments ?? this.courseIdsFromEnrollments,
      adminDisplayName: adminDisplayName ?? this.adminDisplayName,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'phoneNumber': phoneNumber,
      'invitedBy': invitedBy,
      'role': role.name,
      'allowedCourseIds': allowedCourseIds,
      'managedCourseIds': managedCourseIds,
      'adminDisplayName': adminDisplayName,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  static PlaceMemberRole _roleFromJson(dynamic v) {
    if (v == null) return PlaceMemberRole.member;
    final s = v.toString().toLowerCase();
    switch (s) {
      case 'manager':
        return PlaceMemberRole.manager;
      case 'submanager':
        return PlaceMemberRole.subManager;
      default:
        return PlaceMemberRole.member;
    }
  }

  factory PendingMember.fromJson(Map<String, dynamic> json, {String? docId, String? placeId}) {
    final id = docId ?? json['id'] as String? ?? '';
    final pId = placeId ?? json['placeId'] as String? ?? '';

    DateTime createdAt;
    final createdAtData = json['createdAt'];
    if (createdAtData is Timestamp) {
      createdAt = createdAtData.toDate();
    } else if (createdAtData is String) {
      createdAt = DateTime.parse(createdAtData);
    } else {
      createdAt = DateTime.now();
    }

    final rawIds = json['allowedCourseIds'];
    final allowedCourseIds = rawIds is List
        ? rawIds.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
        : <String>[];

    final rawManaged = json['managedCourseIds'];
    final managedCourseIds = rawManaged is List
        ? rawManaged.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
        : <String>[];

    final rawEnrollments = json['courseEnrollments'];
    final courseIdsFromEnrollments = rawEnrollments is List
        ? (rawEnrollments)
            .map((e) => (e is Map ? e['courseId'] : e)?.toString())
            .whereType<String>()
            .where((s) => s.isNotEmpty)
            .toList()
        : <String>[];

    final rawAdmin = (json['adminDisplayName'] as String?)?.trim();
    final adminDisplayName = rawAdmin != null && rawAdmin.isNotEmpty ? rawAdmin : null;

    return PendingMember(
      id: id,
      placeId: pId,
      phoneNumber: json['phoneNumber'] as String? ?? '',
      invitedBy: json['invitedBy'] as String? ?? '',
      role: _roleFromJson(json['role']),
      allowedCourseIds: allowedCourseIds,
      managedCourseIds: managedCourseIds,
      courseIdsFromEnrollments: courseIdsFromEnrollments,
      adminDisplayName: adminDisplayName,
      createdAt: createdAt,
    );
  }

  @override
  String toString() =>
      'PendingMember(placeId: $placeId, phoneNumber: $phoneNumber, role: ${role.name})';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PendingMember && other.id == id && other.placeId == placeId;
  }

  @override
  int get hashCode => Object.hash(id, placeId);
}
