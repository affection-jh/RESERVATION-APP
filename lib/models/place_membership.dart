/// 플레이스 멤버십 모델
///
/// 사용자가 특정 플레이스의 멤버가 되기 위한 가입 요청 및 상태 관리
class PlaceMembership {
  final String id;
  final String userId;
  final String placeId;
  final PlaceMembershipStatus status;
  final DateTime requestedAt; // 가입 요청 시간
  final DateTime? approvedAt; // 승인 시간
  final DateTime? rejectedAt; // 거부 시간
  final String? rejectedReason; // 거부 사유
  final String? invitedBy; // 초대한 관리자 ID (pendingMembers에서 자동 매칭된 경우)

  PlaceMembership({
    required this.id,
    required this.userId,
    required this.placeId,
    required this.status,
    required this.requestedAt,
    this.approvedAt,
    this.rejectedAt,
    this.rejectedReason,
    this.invitedBy,
  });

  /// 승인 상태인지 확인
  bool get isApproved => status == PlaceMembershipStatus.approved;

  /// 대기 상태인지 확인
  bool get isPending => status == PlaceMembershipStatus.pending;

  /// 거부 상태인지 확인
  bool get isRejected => status == PlaceMembershipStatus.rejected;

  /// 복사본 생성
  PlaceMembership copyWith({
    String? id,
    String? userId,
    String? placeId,
    PlaceMembershipStatus? status,
    DateTime? requestedAt,
    DateTime? approvedAt,
    DateTime? rejectedAt,
    String? rejectedReason,
    String? invitedBy,
  }) {
    return PlaceMembership(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      placeId: placeId ?? this.placeId,
      status: status ?? this.status,
      requestedAt: requestedAt ?? this.requestedAt,
      approvedAt: approvedAt ?? this.approvedAt,
      rejectedAt: rejectedAt ?? this.rejectedAt,
      rejectedReason: rejectedReason ?? this.rejectedReason,
      invitedBy: invitedBy ?? this.invitedBy,
    );
  }

  /// JSON 변환
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'userId': userId,
      'placeId': placeId,
      'status': status.name,
      'requestedAt': requestedAt.toIso8601String(),
      'approvedAt': approvedAt?.toIso8601String(),
      'rejectedAt': rejectedAt?.toIso8601String(),
      'rejectedReason': rejectedReason,
      'invitedBy': invitedBy,
    };
  }

  /// JSON에서 생성
  factory PlaceMembership.fromJson(Map<String, dynamic> json) {
    return PlaceMembership(
      id: json['id'] as String,
      userId: json['userId'] as String,
      placeId: json['placeId'] as String,
      status: PlaceMembershipStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => PlaceMembershipStatus.pending,
      ),
      requestedAt: DateTime.parse(json['requestedAt'] as String),
      approvedAt: json['approvedAt'] != null
          ? DateTime.parse(json['approvedAt'] as String)
          : null,
      rejectedAt: json['rejectedAt'] != null
          ? DateTime.parse(json['rejectedAt'] as String)
          : null,
      rejectedReason: json['rejectedReason'] as String?,
      invitedBy: json['invitedBy'] as String?,
    );
  }

  @override
  String toString() {
    return 'PlaceMembership(userId: $userId, placeId: $placeId, status: $status)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PlaceMembership &&
        other.userId == userId &&
        other.placeId == placeId;
  }

  @override
  int get hashCode => userId.hashCode ^ placeId.hashCode;
}

/// 플레이스 멤버십 상태
enum PlaceMembershipStatus {
  pending, // 승인 대기
  approved, // 승인됨
  rejected, // 거부됨
}
