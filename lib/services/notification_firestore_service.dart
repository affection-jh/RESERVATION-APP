import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/notification.dart';
import '../utils/firestore_utils.dart';

/// 알림 Firestore (users/{userId}/notifications) — 온디멘드·페이지네이션만
class NotificationFirestoreService {
  static final NotificationFirestoreService _instance =
      NotificationFirestoreService._internal();
  factory NotificationFirestoreService() => _instance;
  NotificationFirestoreService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static const int defaultPageSize = 30;
  static const int _unreadScanLimit = 200;

  CollectionReference<Map<String, dynamic>> _col(String userId) =>
      _firestore.collection('users').doc(userId).collection('notifications');

  List<AppNotification> _docsToList(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    String userId,
  ) {
    return docs.map((doc) {
      final data = Map<String, dynamic>.from(doc.data());
      data['id'] = doc.id;
      data['userId'] = userId;
      if (data['createdAt'] != null) {
        data['createdAt'] =
            FirestoreUtils.timestampToDateTime(data['createdAt']);
      }
      return AppNotification.fromJson(data);
    }).toList();
  }

  static bool matchesPlace(AppNotification n, String? placeId) {
    if (placeId == null) return true;
    // 현재 플레이스만 (placeId 없는 알림은 전역으로 취급하지 않음 → 오탐 배지 방지)
    return n.placeId == placeId;
  }

  Future<({List<AppNotification> items, Object? nextPageCursor, int fetchedCount})>
  getUserNotificationsPage(
    String userId, {
    bool isAdmin = false,
    String? placeId,
    int limit = defaultPageSize,
    Object? startAfterCursor,
  }) async {
    Query<Map<String, dynamic>> base = _col(userId).where(
      'isAdminNotification',
      isEqualTo: isAdmin,
    );
    if (placeId != null && placeId.isNotEmpty) {
      base = base.where('placeId', isEqualTo: placeId);
    }
    Query<Map<String, dynamic>> query = base
        .orderBy('createdAt', descending: true)
        .limit(limit);
    if (startAfterCursor is DocumentSnapshot<Map<String, dynamic>>) {
      query = query.startAfterDocument(startAfterCursor);
    }

    try {
      final snapshot = await query.get();
      final items = _docsToList(snapshot.docs, userId);
      final nextPageCursor =
          snapshot.docs.isNotEmpty ? snapshot.docs.last : null;
      return (
        items: items,
        nextPageCursor: nextPageCursor,
        fetchedCount: snapshot.docs.length,
      );
    } catch (e) {
      // placeId 복합 인덱스 미준비 시: place 없이 조회 후 클라이언트 필터
      if (placeId == null || placeId.isEmpty) rethrow;
      if (kDebugMode) {
        debugPrint(
          '[NotificationFirestoreService] list by place fallback: $e',
        );
      }
      Query<Map<String, dynamic>> fallback = _col(userId)
          .where('isAdminNotification', isEqualTo: isAdmin)
          .orderBy('createdAt', descending: true)
          .limit(limit);
      if (startAfterCursor is DocumentSnapshot<Map<String, dynamic>>) {
        fallback = fallback.startAfterDocument(startAfterCursor);
      }
      final snapshot = await fallback.get();
      final items = _docsToList(snapshot.docs, userId)
          .where((n) => n.placeId == placeId)
          .toList();
      final nextPageCursor =
          snapshot.docs.isNotEmpty ? snapshot.docs.last : null;
      return (
        items: items,
        nextPageCursor: nextPageCursor,
        fetchedCount: snapshot.docs.length,
      );
    }
  }

  /// 미읽음 개수 (현재 플레이스 필터 적용). 배지용 — 목록 페이지와 분리.
  Future<int> getUnreadNotificationCount(
    String userId, {
    bool isAdmin = false,
    String? placeId,
  }) async {
    if (placeId == null) {
      final snapshot = await _col(userId)
          .where('isAdminNotification', isEqualTo: isAdmin)
          .where('isRead', isEqualTo: false)
          .count()
          .get();
      return snapshot.count ?? 0;
    }

    // placeId 지정 시: 해당 플레이스 미읽음만 (equality count — 인덱스 자동/복합)
    try {
      final snapshot = await _col(userId)
          .where('isAdminNotification', isEqualTo: isAdmin)
          .where('isRead', isEqualTo: false)
          .where('placeId', isEqualTo: placeId)
          .count()
          .get();
      return snapshot.count ?? 0;
    } catch (e) {
      // 인덱스 미준비 시 스캔 폴백
      if (kDebugMode) {
        debugPrint(
          '[NotificationFirestoreService] unread count by place fallback: $e',
        );
      }
      final snapshot = await _col(userId)
          .where('isAdminNotification', isEqualTo: isAdmin)
          .where('isRead', isEqualTo: false)
          .orderBy('createdAt', descending: true)
          .limit(_unreadScanLimit)
          .get();
      return _docsToList(snapshot.docs, userId)
          .where((n) => n.placeId == placeId)
          .length;
    }
  }

  Future<AppNotification?> getNotificationById(
    String notificationId,
    String userId,
  ) async {
    try {
      final doc = await _col(userId).doc(notificationId).get();
      if (!doc.exists || doc.data() == null) return null;
      final data = Map<String, dynamic>.from(doc.data()!);
      data['id'] = doc.id;
      data['userId'] = userId;
      if (data['createdAt'] != null) {
        data['createdAt'] =
            FirestoreUtils.timestampToDateTime(data['createdAt']);
      }
      return AppNotification.fromJson(data);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[NotificationFirestoreService] getNotificationById: $e');
      }
      return null;
    }
  }

  Future<void> markNotificationAsRead(
    String notificationId,
    String userId,
  ) async {
    await _col(userId).doc(notificationId).update({'isRead': true});
  }

  Future<void> markAllNotificationsAsRead(
    List<String> notificationIds,
    String userId,
  ) async {
    if (notificationIds.isEmpty) return;
    final batch = _firestore.batch();
    final col = _col(userId);
    for (final id in notificationIds) {
      batch.update(col.doc(id), {'isRead': true});
    }
    await batch.commit();
  }

  Future<void> deleteNotification(
    String notificationId,
    String userId,
  ) async {
    await _col(userId).doc(notificationId).delete();
  }

  Future<void> deleteNotifications(
    List<String> notificationIds,
    String userId,
  ) async {
    if (notificationIds.isEmpty) return;
    final batch = _firestore.batch();
    final col = _col(userId);
    for (final id in notificationIds) {
      batch.delete(col.doc(id));
    }
    await batch.commit();
  }

  Future<AppNotification> createNotification(
    AppNotification notification,
  ) async {
    await _col(notification.userId).doc(notification.id).set({
      ...notification.toJson(),
      'createdAt': FirestoreUtils.dateTimeToTimestamp(notification.createdAt),
    });
    return notification;
  }
}
