import 'package:cloud_firestore/cloud_firestore.dart';

/// 알림 타입
enum NotificationType {
  reservation, // 예약 관련
  system, // 시스템 알림
}

/// 알림 모델
class AppNotification {
  final String id;
  final String userId;
  final String? placeId;
  final NotificationType type;
  final String title;
  final String body;
  final DateTime createdAt;
  final bool isRead;
  final bool isAdminNotification; // 관리자용 알림 여부
  final Map<String, dynamic>? data; // 추가 데이터 (예: reservationId, noticeId 등)

  AppNotification({
    required this.id,
    required this.userId,
    this.placeId,
    required this.type,
    required this.title,
    required this.body,
    required this.createdAt,
    this.isRead = false,
    this.isAdminNotification = false, // 기본값: 일반 사용자 알림
    this.data,
  });

  // JSON 변환
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'userId': userId,
      'placeId': placeId,
      'type': type.name,
      'title': title,
      'body': body,
      'createdAt': Timestamp.fromDate(createdAt),
      'isRead': isRead,
      'isAdminNotification': isAdminNotification,
      'data': data,
    };
  }

  // JSON에서 생성
  factory AppNotification.fromJson(Map<String, dynamic> json) {
    // createdAt 변환 (FirestoreService는 이미 DateTime으로 변환해 넘길 수 있음)
    DateTime createdAt;
    if (json['createdAt'] is String) {
      createdAt = DateTime.parse(json['createdAt'] as String);
    } else if (json['createdAt'] is Timestamp) {
      createdAt = (json['createdAt'] as Timestamp).toDate();
    } else if (json['createdAt'] is DateTime) {
      createdAt = json['createdAt'] as DateTime;
    } else {
      createdAt = DateTime.now();
    }

    // type 변환
    NotificationType type;
    try {
      type = NotificationType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => NotificationType.system,
      );
    } catch (e) {
      type = NotificationType.system;
    }

    return AppNotification(
      id: json['id'] as String,
      userId: json['userId'] as String,
      placeId: json['placeId'] as String?,
      type: type,
      title: json['title'] as String,
      body: json['body'] as String,
      createdAt: createdAt,
      isRead: json['isRead'] as bool? ?? false,
      isAdminNotification: json['isAdminNotification'] as bool? ?? false,
      data: json['data'] as Map<String, dynamic>?,
    );
  }

  // 읽음 처리
  AppNotification markAsRead() {
    return AppNotification(
      id: id,
      userId: userId,
      placeId: placeId,
      type: type,
      title: title,
      body: body,
      createdAt: createdAt,
      isRead: true,
      isAdminNotification: isAdminNotification,
      data: data,
    );
  }

  // 복사본 생성
  AppNotification copyWith({
    String? id,
    String? userId,
    String? placeId,
    NotificationType? type,
    String? title,
    String? body,
    DateTime? createdAt,
    bool? isRead,
    bool? isAdminNotification,
    Map<String, dynamic>? data,
  }) {
    return AppNotification(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      placeId: placeId ?? this.placeId,
      type: type ?? this.type,
      title: title ?? this.title,
      body: body ?? this.body,
      createdAt: createdAt ?? this.createdAt,
      isRead: isRead ?? this.isRead,
      isAdminNotification: isAdminNotification ?? this.isAdminNotification,
      data: data ?? this.data,
    );
  }
}
