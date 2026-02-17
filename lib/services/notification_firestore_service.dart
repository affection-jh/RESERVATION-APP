import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/notification.dart';
import '../utils/firestore_utils.dart';

/// 알림 Firestore (users/{userId}/notifications)
class NotificationFirestoreService {
  static final NotificationFirestoreService _instance =
      NotificationFirestoreService._internal();
  factory NotificationFirestoreService() => _instance;
  NotificationFirestoreService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

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

  static const int _defaultLimit = 100;

  Future<List<AppNotification>> getUserNotifications(
    String userId, {
    bool isAdmin = false,
    int limit = _defaultLimit,
  }) async {
    final snapshot = await _col(userId)
        .where('isAdminNotification', isEqualTo: isAdmin)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .get();
    return _docsToList(snapshot.docs, userId);
  }

  Stream<List<AppNotification>> watchUserNotifications(
    String userId, {
    bool isAdmin = false,
    int limit = _defaultLimit,
  }) {
    return _col(userId)
        .where('isAdminNotification', isEqualTo: isAdmin)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snapshot) => _docsToList(snapshot.docs, userId));
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
