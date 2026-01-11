import 'package:cloud_firestore/cloud_firestore.dart';

/// 관리자가 미리 등록한 멤버 모델
///
/// 사용자가 로그인 시 전화번호로 자동 매칭되어 플레이스 멤버십 생성
class PendingMember {
  final String id;
  final String placeId;
  final String phoneNumber;
  final String? name; // 선택적 (관리자가 입력한 이름)
  final String createdBy; // 관리자 ID
  final DateTime createdAt;
  final bool autoApprove; // 자동 승인 여부
  final List<String>? courseIds; // 초대된 코스 ID 목록
  final List<Map<String, dynamic>>? courseEnrollments; // 코스별 등록 정보

  PendingMember({
    required this.id,
    required this.placeId,
    required this.phoneNumber,
    this.name,
    required this.createdBy,
    required this.createdAt,
    this.autoApprove = true,
    this.courseIds,
    this.courseEnrollments,
  });

  /// 복사본 생성
  PendingMember copyWith({
    String? id,
    String? placeId,
    String? phoneNumber,
    String? name,
    String? createdBy,
    DateTime? createdAt,
    bool? autoApprove,
    List<String>? courseIds,
    List<Map<String, dynamic>>? courseEnrollments,
  }) {
    return PendingMember(
      id: id ?? this.id,
      placeId: placeId ?? this.placeId,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      name: name ?? this.name,
      createdBy: createdBy ?? this.createdBy,
      createdAt: createdAt ?? this.createdAt,
      autoApprove: autoApprove ?? this.autoApprove,
      courseIds: courseIds ?? this.courseIds,
      courseEnrollments: courseEnrollments ?? this.courseEnrollments,
    );
  }

  /// JSON 변환
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'placeId': placeId,
      'phoneNumber': phoneNumber,
      'name': name,
      'createdBy': createdBy,
      'createdAt': createdAt.toIso8601String(),
      'autoApprove': autoApprove,
      'courseIds': courseIds,
      'courseEnrollments': courseEnrollments,
    };
  }

  /// JSON에서 생성
  factory PendingMember.fromJson(Map<String, dynamic> json) {
    final courseIdsData = json['courseIds'];
    final courseIds = courseIdsData != null
        ? (courseIdsData as List<dynamic>).map((e) => e.toString()).toList()
        : null;

    // courseEnrollments 필드 처리
    final courseEnrollmentsData = json['courseEnrollments'];
    List<Map<String, dynamic>>? courseEnrollments;
    if (courseEnrollmentsData != null) {
      if (courseEnrollmentsData is List) {
        courseEnrollments = courseEnrollmentsData
            .map((e) => e as Map<String, dynamic>)
            .toList();
      } else if (courseEnrollmentsData is Map) {
        // Map 형태로 저장된 경우 (인덱스가 키인 경우) List로 변환
        courseEnrollments = courseEnrollmentsData.values
            .map((e) => e as Map<String, dynamic>)
            .toList();
      }
    }

    // createdAt 필드 처리 (Timestamp 또는 String)
    DateTime createdAt;
    final createdAtData = json['createdAt'];
    if (createdAtData is Timestamp) {
      createdAt = createdAtData.toDate();
    } else if (createdAtData is String) {
      createdAt = DateTime.parse(createdAtData);
    } else {
      throw Exception('Invalid createdAt format: ${createdAtData.runtimeType}');
    }

    return PendingMember(
      id: json['id'] as String,
      placeId: json['placeId'] as String,
      phoneNumber: json['phoneNumber'] as String,
      name: json['name'] as String?,
      createdBy: json['createdBy'] as String,
      createdAt: createdAt,
      autoApprove: json['autoApprove'] as bool? ?? true,
      courseIds: courseIds,
      courseEnrollments: courseEnrollments,
    );
  }

  @override
  String toString() {
    return 'PendingMember(placeId: $placeId, phoneNumber: $phoneNumber, autoApprove: $autoApprove)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PendingMember &&
        other.placeId == placeId &&
        other.phoneNumber == phoneNumber;
  }

  @override
  int get hashCode => placeId.hashCode ^ phoneNumber.hashCode;
}
