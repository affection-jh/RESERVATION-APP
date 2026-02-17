import 'package:flutter/foundation.dart';
import '../models/notification.dart';
import '../services/firestore_service.dart';

/// 알림 관리 Provider (일회성 로드 + FCM 수신 시 추가)
class NotificationProvider with ChangeNotifier {
  final FirestoreService _firestore = FirestoreService();

  List<AppNotification> _notifications = [];
  bool _isLoading = false;
  String? _error;
  String? _currentUserId;
  String? _currentPlaceId;
  bool? _lastLoadIsAdmin;
  DateTime? _lastLoadTime;

  List<AppNotification> get notifications => List.unmodifiable(_notifications);
  bool get isLoading => _isLoading;
  String? get error => _error;

  int get unreadCount =>
      _notifications.where((n) {
        if (_currentPlaceId != null &&
            n.placeId != null &&
            n.placeId != _currentPlaceId) {
          return false;
        }
        return !n.isRead;
      }).length;

  Future<void> loadNotifications(
    String userId, {
    bool isAdmin = false,
    String? placeId,
    bool forceRefresh = false,
  }) async {
    // 동일 파라미터 + 30초 이내 재호출 시 Firestore 재요청 생략
    if (!forceRefresh &&
        _currentUserId == userId &&
        _currentPlaceId == placeId &&
        _lastLoadIsAdmin == isAdmin &&
        _lastLoadTime != null &&
        DateTime.now().difference(_lastLoadTime!) <
            const Duration(seconds: 30)) {
      return;
    }

    _isLoading = true;
    _error = null;
    _currentUserId = userId;
    _currentPlaceId = placeId;
    _lastLoadIsAdmin = isAdmin;
    notifyListeners();

    try {
      final all = await _firestore.getUserNotifications(
        userId,
        isAdmin: isAdmin,
      );
      _notifications =
          placeId == null
              ? all
              : all
                  .where((n) => n.placeId == null || n.placeId == placeId)
                  .toList();
    } catch (e) {
      if (kDebugMode)
        debugPrint('[NotificationProvider] loadNotifications: $e');
      _notifications = [];
    } finally {
      _isLoading = false;
      _lastLoadTime = DateTime.now();
      notifyListeners();
    }
  }

  Future<void> markAsRead(String notificationId) async {
    final userId = _currentUserId;
    if (userId == null) return;
    final i = _notifications.indexWhere((n) => n.id == notificationId);
    if (i == -1) return;
    final n = _notifications[i];
    if (n.isRead) return;
    try {
      await _firestore.markNotificationAsRead(notificationId, userId);
      _notifications[i] = n.markAsRead();
      notifyListeners();
    } catch (e) {
      if (kDebugMode) debugPrint('[NotificationProvider] markAsRead: $e');
    }
  }

  Future<void> markAllAsRead() async {
    final userId = _currentUserId;
    if (userId == null) return;
    final unread = _notifications.where((n) => !n.isRead).toList();
    if (unread.isEmpty) return;
    try {
      await _firestore.markAllNotificationsAsRead(
        unread.map((n) => n.id).toList(),
        userId,
      );
      _notifications = _notifications.map((n) => n.markAsRead()).toList();
      notifyListeners();
    } catch (e) {
      if (kDebugMode) debugPrint('[NotificationProvider] markAllAsRead: $e');
    }
  }

  Future<void> deleteNotification(String notificationId) async {
    final userId = _currentUserId;
    if (userId == null) return;
    try {
      await _firestore.deleteNotification(notificationId, userId);
      _notifications =
          _notifications.where((n) => n.id != notificationId).toList();
      notifyListeners();
    } catch (e) {
      if (kDebugMode)
        debugPrint('[NotificationProvider] deleteNotification: $e');
    }
  }

  Future<void> deleteAllNotifications() async {
    if (_notifications.isEmpty) return;
    final userId = _currentUserId;
    if (userId == null) return;
    try {
      final ids = _notifications.map((n) => n.id).toList();
      await _firestore.deleteNotifications(ids, userId);
      _notifications = [];
      notifyListeners();
    } catch (e) {
      if (kDebugMode)
        debugPrint('[NotificationProvider] deleteAllNotifications: $e');
      rethrow;
    }
  }

  /// FCM 수신 시 알림 문서 조회 후 목록에 추가
  Future<void> addNotificationFromId(
    String notificationId,
    String currentUserId,
    bool isAdmin, {
    String? placeId,
  }) async {
    if (_notifications.any((n) => n.id == notificationId)) return;
    try {
      final notification = await _firestore.getNotificationById(
        notificationId,
        currentUserId,
      );
      if (notification == null) return;
      if (notification.userId != currentUserId ||
          notification.isAdminNotification != isAdmin)
        return;
      if (placeId != null &&
          notification.placeId != null &&
          notification.placeId != placeId)
        return;

      _notifications = [notification, ..._notifications]
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      if (_notifications.length > 100) {
        _notifications = _notifications.take(100).toList();
      }
      notifyListeners();
    } catch (e) {
      if (kDebugMode)
        debugPrint('[NotificationProvider] addNotificationFromId: $e');
    }
  }

  void clear() {
    _notifications = [];
    _isLoading = false;
    _error = null;
    _currentUserId = null;
    _currentPlaceId = null;
    _lastLoadIsAdmin = null;
    _lastLoadTime = null;
    notifyListeners();
  }
}
