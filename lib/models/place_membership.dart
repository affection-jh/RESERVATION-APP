/// 플레이스 멤버십 모델
///
/// 사용자가 특정 플레이스의 멤버임을 나타내는 모델
/// status 필드 제거: 항상 멤버인 것만 들어가게 함
class PlaceMembership {
  final String id;
  final String userId;
  final String placeId;
  final DateTime requestedAt; // 가입 요청 시간
  final DateTime? approvedAt; // 승인 시간
  final String? invitedBy; // 초대한 관리자 ID

  PlaceMembership({
    required this.id,
    required this.userId,
    required this.placeId,
    required this.requestedAt,
    this.approvedAt,
    this.invitedBy,
  });

  /// 항상 승인된 상태 (status 제거로 항상 멤버)
  bool get isApproved => true;

  /// 복사본 생성
  PlaceMembership copyWith({
    String? id,
    String? userId,
    String? placeId,
    DateTime? requestedAt,
    DateTime? approvedAt,
    String? invitedBy,
  }) {
    return PlaceMembership(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      placeId: placeId ?? this.placeId,
      requestedAt: requestedAt ?? this.requestedAt,
      approvedAt: approvedAt ?? this.approvedAt,
      invitedBy: invitedBy ?? this.invitedBy,
    );
  }

  /// JSON 변환
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'userId': userId,
      'placeId': placeId,
      'requestedAt': requestedAt.toIso8601String(),
      'approvedAt': approvedAt?.toIso8601String(),
      'invitedBy': invitedBy,
    };
  }

  /// JSON에서 생성
  factory PlaceMembership.fromJson(Map<String, dynamic> json) {
    return PlaceMembership(
      id: json['id'] as String,
      userId: json['userId'] as String,
      placeId: json['placeId'] as String,
      requestedAt: DateTime.parse(json['requestedAt'] as String),
      approvedAt: json['approvedAt'] != null
          ? DateTime.parse(json['approvedAt'] as String)
          : null,
      invitedBy: json['invitedBy'] as String?,
    );
  }

  @override
  String toString() {
    return 'PlaceMembership(userId: $userId, placeId: $placeId)';
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
