import '../utils/timezone_utils.dart';

/// 어드민 유저 모델
class AdminUser {
  final String userId;
  final String name;
  final String phoneNumber;
  final String? authPin; // 관리자 인증 PIN (해시화된 값)
  final List<String> placeIds; // 관리하는 플레이스들
  final String? lastAccessedPlaceId; // 최근 접속한 플레이스 ID
  final bool notificationsEnabled; // 알림 설정
  final DateTime createdAt;
  final DateTime? updatedAt;

  AdminUser({
    required this.userId,
    required this.name,
    required this.phoneNumber,
    this.authPin,
    this.placeIds = const [],
    this.lastAccessedPlaceId,
    this.notificationsEnabled = true, // 기본값: 알림 켜짐
    required this.createdAt,
    this.updatedAt,
  });

  // 특정 플레이스를 관리하는지 확인
  bool managesPlace(String placeId) {
    return placeIds.contains(placeId);
  }

  // 플레이스 추가
  AdminUser addPlace(String placeId) {
    if (placeIds.contains(placeId)) {
      return this;
    }
    return copyWith(
      placeIds: [...placeIds, placeId],
      updatedAt: TimezoneUtils.getSeoulDateTime(),
    );
  }

  // 플레이스 제거
  AdminUser removePlace(String placeId) {
    return copyWith(placeIds: placeIds.where((id) => id != placeId).toList());
  }

  // 정보 업데이트
  AdminUser updateProfile({
    String? name,
    String? phoneNumber,
    bool? notificationsEnabled,
  }) {
    return copyWith(
      name: name ?? this.name,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      updatedAt: TimezoneUtils.getSeoulDateTime(),
    );
  }

  // 복사본 생성
  AdminUser copyWith({
    String? userId,
    String? name,
    String? phoneNumber,
    String? authPin,
    List<String>? placeIds,
    String? lastAccessedPlaceId,
    bool? notificationsEnabled,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return AdminUser(
      userId: userId ?? this.userId,
      name: name ?? this.name,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      authPin: authPin ?? this.authPin,
      placeIds: placeIds ?? this.placeIds,
      lastAccessedPlaceId: lastAccessedPlaceId ?? this.lastAccessedPlaceId,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  // JSON 변환
  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'name': name,
      'phoneNumber': phoneNumber,
      'authPin': authPin,
      'placeIds': placeIds,
      'lastAccessedPlaceId': lastAccessedPlaceId,
      'notificationsEnabled': notificationsEnabled,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
    };
  }

  // JSON에서 생성
  factory AdminUser.fromJson(Map<String, dynamic> json) {
    return AdminUser(
      userId: json['userId'] as String,
      name: json['name'] as String,
      phoneNumber: json['phoneNumber'] as String,
      authPin: json['authPin'] as String?,
      placeIds: (json['placeIds'] as List?)?.cast<String>() ?? [],
      lastAccessedPlaceId: json['lastAccessedPlaceId'] as String?,
      notificationsEnabled: json['notificationsEnabled'] as bool? ?? true,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: json['updatedAt'] != null
          ? DateTime.parse(json['updatedAt'] as String)
          : null,
    );
  }

  @override
  String toString() {
    return 'AdminUser(userId: $userId, name: $name, places: ${placeIds.length})';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AdminUser && other.userId == userId;
  }

  @override
  int get hashCode => userId.hashCode;
}
