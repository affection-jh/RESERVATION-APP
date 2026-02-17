class User {
  final String userId;
  /// 유저 본인이 설정한 표시 이름 (관리자 설정 이름과 독립)
  final String username;
  final String phoneNumber;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String? currentPlaceId;
  final bool notificationsEnabled;

  User({
    required this.userId,
    required this.username,
    required this.phoneNumber,
    required this.createdAt,
    this.updatedAt,
    this.currentPlaceId,
    this.notificationsEnabled = true,
  });

  /// 호환용: 현재 플레이스만 설정 (실제 관리 플레이스는 PlaceMember로 관리)
  User addPlace(String placeId) => copyWith(currentPlaceId: placeId);
  User removePlace(String placeId) =>
      currentPlaceId == placeId ? copyWith(currentPlaceId: null) : this;

  User copyWith({
    String? username,
    String? phoneNumber,
    bool? notificationsEnabled,
    String? currentPlaceId,
    DateTime? updatedAt,
  }) {
    return User(
      userId: userId,
      username: username ?? this.username,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      currentPlaceId: currentPlaceId ?? this.currentPlaceId,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'username': username,
      'phoneNumber': phoneNumber,
      'notificationsEnabled': notificationsEnabled,
      'currentPlaceId': currentPlaceId,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
    };
  }

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      userId: json['userId'] ?? '',
      username: (json['username'] ?? json['name'])?.toString() ?? '',
      phoneNumber: json['phoneNumber'] ?? '',
      notificationsEnabled: json['notificationsEnabled'] ?? true,
      currentPlaceId: json['currentPlaceId'],
      createdAt:
          json['createdAt'] != null
              ? DateTime.parse(json['createdAt'])
              : DateTime.now(),
      updatedAt:
          json['updatedAt'] != null ? DateTime.parse(json['updatedAt']) : null,
    );
  }
}
