import 'package:flutter/foundation.dart';
import '../models/notification.dart';
import '../services/firestore_service.dart';

/// 알림 관리 Provider
class NotificationProvider with ChangeNotifier {
  final FirestoreService _firestoreService = FirestoreService();

  List<AppNotification> _notifications = [];
  bool _isLoading = false;
  String? _error;
  String? _currentPlaceId; // 현재 플레이스 ID 저장

  List<AppNotification> get notifications => List.unmodifiable(_notifications);
  bool get isLoading => _isLoading;
  String? get error => _error;

  // 읽지 않은 알림 개수 (현재 플레이스에 맞는 것만)
  int get unreadCount {
    return _notifications.where((n) {
      // 플레이스 필터링: placeId가 null이거나 현재 플레이스와 일치
      if (_currentPlaceId != null && n.placeId != null) {
        if (n.placeId != _currentPlaceId) {
          return false;
        }
      }
      return !n.isRead;
    }).length;
  }

  /// 사용자 알림 목록 로드 (역할별, 플레이스별) — 일회성 조회, 실시간은 FCM 수신 시 addNotificationFromId
  Future<void> loadNotifications(
    String userId, {
    bool isAdmin = false,
    String? placeId,
  }) async {
    debugPrint('[NotificationProvider] loadNotifications() start userId=$userId isAdmin=$isAdmin placeId=$placeId');
    _isLoading = true;
    _error = null;
    _currentPlaceId = placeId;
    notifyListeners();

    try {
      final allNotifications = await _firestoreService.getUserNotifications(
        userId,
        isAdmin: isAdmin,
      );
      debugPrint('[NotificationProvider] getUserNotifications 반환 개수: ${allNotifications.length}');

      if (placeId != null) {
        _notifications =
            allNotifications
                .where((n) => n.placeId == null || n.placeId == placeId)
                .toList();
        debugPrint('[NotificationProvider] placeId 필터 후 개수: ${_notifications.length}');
      } else {
        _notifications = allNotifications;
      }

      _error = null;
    } catch (e) {
      debugPrint('[NotificationProvider] 알림 로드 실패: $e');
      _error = null;
      _notifications = [];
    } finally {
      _isLoading = false;
      notifyListeners();
      debugPrint('[NotificationProvider] loadNotifications() end notifications.length=${_notifications.length}');
    }
  }

  /// 알림 읽음 처리
  Future<void> markAsRead(String notificationId) async {
    try {
      final index = _notifications.indexWhere((n) => n.id == notificationId);
      if (index == -1) return;

      final notification = _notifications[index];
      if (notification.isRead) return;

      await _firestoreService.markNotificationAsRead(notificationId);
      _notifications[index] = notification.markAsRead();
      notifyListeners();
    } catch (e) {
      debugPrint('[NotificationProvider] markAsRead 오류: $e');
      // 오류 발생 시 조용히 처리 (UI에 오류 표시하지 않음)
    }
  }

  /// 모든 알림 읽음 처리
  Future<void> markAllAsRead() async {
    try {
      final unreadNotifications =
          _notifications.where((n) => !n.isRead).toList();
      if (unreadNotifications.isEmpty) return;

      await _firestoreService.markAllNotificationsAsRead(
        unreadNotifications.map((n) => n.id).toList(),
      );

      _notifications = _notifications.map((n) => n.markAsRead()).toList();
      notifyListeners();
    } catch (e) {
      debugPrint('[NotificationProvider] markAllAsRead 오류: $e');
      // 오류 발생 시 조용히 처리 (UI에 오류 표시하지 않음)
    }
  }

  /// 알림 삭제
  Future<void> deleteNotification(String notificationId) async {
    try {
      await _firestoreService.deleteNotification(notificationId);
      _notifications =
          _notifications.where((n) => n.id != notificationId).toList();
      notifyListeners();
    } catch (e) {
      debugPrint('[NotificationProvider] deleteNotification 오류: $e');
      // 오류 발생 시 조용히 처리 (UI에 오류 표시하지 않음)
    }
  }

  /// 모든 알림 삭제
  Future<void> deleteAllNotifications() async {
    if (_notifications.isEmpty) return;
    try {
      final ids = _notifications.map((n) => n.id).toList();
      await _firestoreService.deleteNotifications(ids);
      _notifications = [];
      notifyListeners();
    } catch (e) {
      debugPrint('[NotificationProvider] deleteAllNotifications 오류: $e');
      rethrow;
    }
  }

  /// 새 알림 추가 (FCM 수신 시 사용)
  Future<void> addNotificationFromId(
    String notificationId,
    String currentUserId,
    bool isAdmin, {
    String? placeId,
  }) async {
    debugPrint('[NotificationProvider] addNotificationFromId() notificationId=$notificationId currentUserId=$currentUserId isAdmin=$isAdmin placeId=$placeId');
    try {
      if (_notifications.any((n) => n.id == notificationId)) {
        debugPrint('[NotificationProvider] addNotificationFromId 이미 존재 → 스킵');
        return;
      }

      final notification = await _firestoreService.getNotificationById(
        notificationId,
      );
      if (notification == null) {
        debugPrint('[NotificationProvider] addNotificationFromId Firestore에서 알림 없음 (doc 없거나 파싱 실패)');
        return;
      }
      debugPrint('[NotificationProvider] addNotificationFromId Firestore 조회됨 userId=${notification.userId} isAdminNotification=${notification.isAdminNotification} placeId=${notification.placeId}');

      if (notification.userId != currentUserId) {
        debugPrint('[NotificationProvider] addNotificationFromId 알림 사용자 불일치 → 스킵');
        return;
      }

      if (notification.isAdminNotification != isAdmin) {
        debugPrint('[NotificationProvider] addNotificationFromId 알림 타입 불일치 → 스킵');
        return;
      }

      if (placeId != null && notification.placeId != null) {
        if (notification.placeId != placeId) {
          debugPrint('[NotificationProvider] addNotificationFromId 알림 플레이스 불일치 → 스킵');
          return;
        }
      }

      _notifications.insert(0, notification);
      _notifications.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      if (_notifications.length > 100) {
        _notifications = _notifications.take(100).toList();
      }
      notifyListeners();
      debugPrint('[NotificationProvider] addNotificationFromId 추가 완료, 목록 개수=${_notifications.length}');
    } catch (e) {
      debugPrint('[NotificationProvider] addNotificationFromId error: $e');
    }
  }

  /// 데이터 초기화
  void clear() {
    _notifications = [];
    _isLoading = false;
    _error = null;
    _currentPlaceId = null;
    notifyListeners();
  }
}
