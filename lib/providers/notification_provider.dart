import 'package:flutter/foundation.dart';
import '../models/notification.dart';
import '../services/firestore_service.dart';
import '../services/notification_firestore_service.dart';

/// 알림 Provider — 배지(미읽음 count) + 목록 페이지네이션 (구독 없음)
class NotificationProvider with ChangeNotifier {
  final FirestoreService _firestore = FirestoreService();

  List<AppNotification> _notifications = [];
  int _unreadCount = 0;
  bool _unreadCountLoaded = false;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasLoadedOnce = false;
  bool _hasMoreFromServer = false;
  Object? _nextPageCursor;
  String? _error;
  String? _currentUserId;
  String? _currentPlaceId;
  bool? _lastLoadIsAdmin;

  List<AppNotification> get notifications => List.unmodifiable(_notifications);
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasLoadedOnce => _hasLoadedOnce;
  bool get hasMoreNotifications => _hasMoreFromServer;
  String? get error => _error;

  /// 빨간 점 — Firestore 조회 완료 후에만 true로 표시
  int get unreadCount => _unreadCount;
  bool get unreadCountLoaded => _unreadCountLoaded;
  bool get showUnreadBadge => _unreadCountLoaded && _unreadCount > 0;

  /// 현재 세션이 관리자/멤버 중 어느 알림을 보는지 (배지·목록·FCM 공통)
  /// null이면 아직 한 번도 로드하지 않음 → 멤버(false)로 취급
  bool get isAdminNotificationContext => _lastLoadIsAdmin ?? false;

  void _setContext({
    required String userId,
    bool isAdmin = false,
    String? placeId,
  }) {
    final changed =
        _currentUserId != userId ||
        _currentPlaceId != placeId ||
        _lastLoadIsAdmin != isAdmin;
    _currentUserId = userId;
    _currentPlaceId = placeId;
    _lastLoadIsAdmin = isAdmin;
    if (changed) {
      _notifications = [];
      _hasLoadedOnce = false;
      _nextPageCursor = null;
      _hasMoreFromServer = false;
      _unreadCount = 0;
      _unreadCountLoaded = false;
    }
  }

  List<AppNotification> _filterByPlace(List<AppNotification> items) {
    if (_currentPlaceId == null) return items;
    return items
        .where((n) => NotificationFirestoreService.matchesPlace(n, _currentPlaceId))
        .toList();
  }

  bool _countsForBadge(AppNotification n) =>
      NotificationFirestoreService.matchesPlace(n, _currentPlaceId);

  /// 배지만 갱신 (앱 시작·복귀·플레이스 전환)
  Future<void> refreshUnreadBadge(
    String userId, {
    bool isAdmin = false,
    String? placeId,
  }) async {
    _setContext(userId: userId, isAdmin: isAdmin, placeId: placeId);
    // 조회 완료 전엔 절대 배지 표시하지 않음
    _unreadCount = 0;
    _unreadCountLoaded = false;
    notifyListeners();

    // 플레이스 미확정이면 배지 숨김 (전역 count로 오탐 방지)
    if (placeId == null || placeId.isEmpty) {
      _unreadCountLoaded = true;
      notifyListeners();
      return;
    }

    try {
      _unreadCount = await _firestore.getUnreadNotificationCount(
        userId,
        isAdmin: isAdmin,
        placeId: placeId,
      );
      _unreadCountLoaded = true;
      _error = null;
      if (kDebugMode) {
        debugPrint(
          '[NotificationProvider] badge isAdmin=$isAdmin placeId=$placeId unread=$_unreadCount',
        );
      }
    } catch (e) {
      _unreadCount = 0;
      _unreadCountLoaded = false;
      if (kDebugMode) {
        debugPrint('[NotificationProvider] refreshUnreadBadge: $e');
      }
    }
    notifyListeners();
  }

  /// 알림 목록 1페이지 로드 (+ 배지 동기화)
  Future<void> loadNotifications(
    String userId, {
    bool isAdmin = false,
    String? placeId,
    bool forceRefresh = false,
    bool clearExisting = true,
  }) async {
    _setContext(userId: userId, isAdmin: isAdmin, placeId: placeId);

    if (clearExisting) {
      _notifications = [];
      _hasLoadedOnce = false;
      _nextPageCursor = null;
      _hasMoreFromServer = false;
    } else if (forceRefresh) {
      _nextPageCursor = null;
      _hasMoreFromServer = false;
    }

    _isLoading = true;
    _error = null;
    _unreadCount = 0;
    _unreadCountLoaded = false;
    notifyListeners();

    try {
      final page = await _firestore.getUserNotificationsPage(
        userId,
        isAdmin: isAdmin,
        placeId: placeId,
      );
      _notifications = _filterByPlace(page.items);
      _nextPageCursor = page.nextPageCursor;
      _hasMoreFromServer =
          page.fetchedCount >= NotificationFirestoreService.defaultPageSize &&
          page.nextPageCursor != null;

      if (placeId == null || placeId.isEmpty) {
        _unreadCount = 0;
      } else {
        _unreadCount = await _firestore.getUnreadNotificationCount(
          userId,
          isAdmin: isAdmin,
          placeId: placeId,
        );
        // 목록이 비면 배지도 끔 (count/목록 isAdmin·place 불일치 방지)
        if (_notifications.isEmpty && !_hasMoreFromServer) {
          _unreadCount = 0;
        }
      }
      _unreadCountLoaded = true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[NotificationProvider] loadNotifications: $e');
      }
      if (clearExisting) _notifications = [];
      _error = e.toString();
    } finally {
      _isLoading = false;
      _hasLoadedOnce = true;
      notifyListeners();
    }
  }

  Future<void> loadMoreNotifications() async {
    final userId = _currentUserId;
    if (userId == null || _isLoadingMore || !_hasMoreFromServer) return;
    if (_nextPageCursor == null) return;

    _isLoadingMore = true;
    notifyListeners();

    try {
      final page = await _firestore.getUserNotificationsPage(
        userId,
        isAdmin: _lastLoadIsAdmin ?? false,
        placeId: _currentPlaceId,
        startAfterCursor: _nextPageCursor,
      );
      final existingIds = _notifications.map((n) => n.id).toSet();
      final merged = [
        ..._notifications,
        ..._filterByPlace(page.items).where((n) => !existingIds.contains(n.id)),
      ];
      _notifications = merged;
      _nextPageCursor = page.nextPageCursor;
      _hasMoreFromServer =
          page.fetchedCount >= NotificationFirestoreService.defaultPageSize &&
          page.nextPageCursor != null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[NotificationProvider] loadMoreNotifications: $e');
      }
    } finally {
      _isLoadingMore = false;
      notifyListeners();
    }
  }

  Future<void> markAsRead(String notificationId) async {
    final userId = _currentUserId;
    if (userId == null) return;
    final i = _notifications.indexWhere((n) => n.id == notificationId);
    AppNotification? target;
    if (i != -1) {
      target = _notifications[i];
      if (target.isRead) return;
    }
    try {
      await _firestore.markNotificationAsRead(notificationId, userId);
      if (i != -1 && target != null) {
        _notifications[i] = target.markAsRead();
      }
      if (target != null && !target.isRead && _countsForBadge(target)) {
        _unreadCount = (_unreadCount - 1).clamp(0, 999999);
      } else if (target == null) {
        await refreshUnreadBadge(
          userId,
          isAdmin: _lastLoadIsAdmin ?? false,
          placeId: _currentPlaceId,
        );
        return;
      }
      notifyListeners();
    } catch (e) {
      if (kDebugMode) debugPrint('[NotificationProvider] markAsRead: $e');
    }
  }

  Future<void> markAllAsRead() async {
    final userId = _currentUserId;
    if (userId == null) return;
    final unread =
        _notifications.where((n) => !n.isRead && _countsForBadge(n)).toList();
    if (unread.isEmpty) return;
    try {
      await _firestore.markAllNotificationsAsRead(
        unread.map((n) => n.id).toList(),
        userId,
      );
      _notifications = _notifications.map((n) => n.markAsRead()).toList();
      _unreadCount = (_unreadCount - unread.length).clamp(0, 999999);
      notifyListeners();
    } catch (e) {
      if (kDebugMode) debugPrint('[NotificationProvider] markAllAsRead: $e');
    }
  }

  Future<void> deleteNotification(String notificationId) async {
    final userId = _currentUserId;
    if (userId == null) return;
    final removed = _notifications.where((n) => n.id == notificationId).toList();
    try {
      await _firestore.deleteNotification(notificationId, userId);
      _notifications =
          _notifications.where((n) => n.id != notificationId).toList();
      if (removed.isNotEmpty &&
          !removed.first.isRead &&
          _countsForBadge(removed.first)) {
        _unreadCount = (_unreadCount - 1).clamp(0, 999999);
      }
      notifyListeners();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[NotificationProvider] deleteNotification: $e');
      }
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
      _unreadCount = 0;
      _nextPageCursor = null;
      _hasMoreFromServer = false;
      notifyListeners();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[NotificationProvider] deleteAllNotifications: $e');
      }
      rethrow;
    }
  }

  /// FCM 수신 시 — 배지 즉시 반영, 목록은 로드된 경우에만 prepend
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
          notification.isAdminNotification != isAdmin) {
        return;
      }

      _setContext(userId: currentUserId, isAdmin: isAdmin, placeId: placeId);
      if (!NotificationFirestoreService.matchesPlace(notification, placeId)) {
        return;
      }

      if (_hasLoadedOnce) {
        _notifications = [notification, ..._notifications]
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        notifyListeners();
      }

      if (!notification.isRead) {
        // 로컬 가산 대신 서버 count로 재동기화 (오탐 배지 방지)
        await refreshUnreadBadge(
          currentUserId,
          isAdmin: isAdmin,
          placeId: placeId,
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[NotificationProvider] addNotificationFromId: $e');
      }
    }
  }

  void clear() {
    _notifications = [];
    _unreadCount = 0;
    _unreadCountLoaded = false;
    _isLoading = false;
    _isLoadingMore = false;
    _hasLoadedOnce = false;
    _hasMoreFromServer = false;
    _nextPageCursor = null;
    _error = null;
    _currentUserId = null;
    _currentPlaceId = null;
    _lastLoadIsAdmin = null;
    notifyListeners();
  }
}
