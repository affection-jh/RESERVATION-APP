import 'package:flutter/foundation.dart';
import '../models/notification.dart';
import '../services/firestore_service.dart';

/// 알림 관리 Provider
class NotificationProvider with ChangeNotifier {
  final FirestoreService _firestoreService = FirestoreService();

  List<AppNotification> _notifications = [];
  bool _isLoading = false;
  String? _error;

  List<AppNotification> get notifications => List.unmodifiable(_notifications);
  bool get isLoading => _isLoading;
  String? get error => _error;

  // 읽지 않은 알림 개수
  int get unreadCount => _notifications.where((n) => !n.isRead).length;

  /// 사용자 알림 목록 로드 (역할별)
  Future<void> loadNotifications(String userId, {bool isAdmin = false}) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _notifications = await _firestoreService.getUserNotifications(
        userId,
        isAdmin: isAdmin,
      );
      _error = null;
    } catch (e) {
      // 자세한 오류 메시지는 로그에만 기록하고, UI에는 간단한 메시지만 표시
      debugPrint('[NotificationProvider] 알림 로드 실패: $e');
      _error = null; // 오류를 null로 설정하여 UI에 오류 메시지 표시하지 않음
      _notifications = []; // 빈 리스트로 설정하여 "알림이 없습니다" 메시지 표시
    } finally {
      _isLoading = false;
      notifyListeners();
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
      final unreadNotifications = _notifications
          .where((n) => !n.isRead)
          .toList();
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
      _notifications = _notifications
          .where((n) => n.id != notificationId)
          .toList();
      notifyListeners();
    } catch (e) {
      debugPrint('[NotificationProvider] deleteNotification 오류: $e');
      // 오류 발생 시 조용히 처리 (UI에 오류 표시하지 않음)
    }
  }

  /// 새 알림 추가 (FCM 수신 시 사용)
  /// [notificationId] 알림 ID
  /// [currentUserId] 현재 로그인한 사용자 ID (보안 검증용)
  /// [isAdmin] 관리자 알림인지 여부 (보안 검증용)
  Future<void> addNotificationFromId(
    String notificationId,
    String currentUserId,
    bool isAdmin,
  ) async {
    try {
      // 이미 존재하는 알림인지 확인
      if (_notifications.any((n) => n.id == notificationId)) {
        return;
      }

      // Firestore에서 알림 조회
      final notification = await _firestoreService.getNotificationById(
        notificationId,
      );
      if (notification != null) {
        // 보안 검증: 현재 사용자의 알림인지 확인
        if (notification.userId != currentUserId) {
          debugPrint(
            '[NotificationProvider] addNotificationFromId: 알림 사용자 불일치 (알림: ${notification.userId}, 현재: $currentUserId)',
          );
          return;
        }

        // 관리자 알림 여부 확인
        if (notification.isAdminNotification != isAdmin) {
          debugPrint(
            '[NotificationProvider] addNotificationFromId: 알림 타입 불일치 (알림: ${notification.isAdminNotification}, 현재: $isAdmin)',
          );
          return;
        }

        // 최신 알림을 맨 앞에 추가
        _notifications.insert(0, notification);
        // createdAt 기준으로 정렬 (최신순)
        _notifications.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        // 최대 100개까지만 유지 (메모리 관리)
        if (_notifications.length > 100) {
          _notifications = _notifications.take(100).toList();
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[NotificationProvider] addNotificationFromId error: $e');
      // 에러가 발생해도 조용히 처리 (FCM 수신은 계속 진행)
    }
  }

  /// 데이터 초기화
  void clear() {
    _notifications = [];
    _isLoading = false;
    _error = null;
    notifyListeners();
  }
}
