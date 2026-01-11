import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../widgets/push_notification_overlay.dart';
import '../utils/navigator_key.dart';
import '../providers/notification_provider.dart';
import '../providers/auth_provider.dart';
import 'dart:async';

/// Firebase Cloud Messaging 서비스
/// FCM 토큰 관리 및 푸시 알림 수신 처리
class FcmService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  StreamSubscription<String>? _tokenRefreshSubscription;
  bool _isInitialized = false;

  /// FCM 초기화 및 토큰 저장
  /// 사용자와 관리자 모두 동일하게 처리
  Future<void> initialize(String userId) async {
    if (_isInitialized) {
      // 이미 초기화된 경우 토큰만 업데이트
      await _saveTokenToFirestore(userId);
      return;
    }

    // 알림 권한 요청
    NotificationSettings settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional) {
      // FCM 토큰 가져오기 및 저장
      await _saveTokenToFirestore(userId);

      // 토큰 갱신 리스너
      _tokenRefreshSubscription = _messaging.onTokenRefresh.listen((newToken) {
        _saveTokenToFirestore(userId, token: newToken);
      });

      // 포그라운드 메시지 핸들러 설정 (한 번만)
      _setupForegroundHandlers();

      _isInitialized = true;
    } else {
      print('FCM 권한이 거부되었습니다.');
    }
  }

  /// 포그라운드 메시지 핸들러 설정
  void _setupForegroundHandlers() {
    // 포그라운드 메시지 핸들러
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      print('포그라운드 메시지 수신: ${message.notification?.title}');
      _showForegroundNotification(message);
      // NotificationProvider에 새 알림 추가
      _addNotificationToProvider(message.data);
    });

    // 알림 클릭 핸들러
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      print('알림 클릭: ${message.data}');
      _handleNotificationTap(message.data);
    });
  }

  /// NotificationProvider에 새 알림 추가
  void _addNotificationToProvider(Map<String, dynamic>? data) {
    final context = navigatorKey.currentContext;
    if (context == null) return;

    final notificationId = data?['notificationId'];
    if (notificationId != null && notificationId is String) {
      try {
        final authProvider = Provider.of<AuthProvider>(context, listen: false);
        final notificationProvider = Provider.of<NotificationProvider>(
          context,
          listen: false,
        );

        // 현재 로그인한 사용자 정보 확인
        final currentAdmin = authProvider.currentAdmin;
        final currentUser = authProvider.currentUser;
        final isAdmin = currentAdmin != null;
        final userId = currentAdmin?.userId ?? currentUser?.userId;

        if (userId == null) {
          print('[FcmService] _addNotificationToProvider: 사용자 정보 없음');
          return;
        }

        notificationProvider.addNotificationFromId(
          notificationId,
          userId,
          isAdmin,
        );
      } catch (e) {
        print('[FcmService] _addNotificationToProvider error: $e');
      }
    }
  }

  /// FCM 토큰을 Firestore에 저장
  Future<void> _saveTokenToFirestore(String userId, {String? token}) async {
    try {
      // iOS에서 APNS 토큰 먼저 요청 (FCM 토큰을 얻기 위해 필요)
      // 시뮬레이터에서는 APNS 토큰을 받을 수 없으므로 오류는 무시
      try {
        await _messaging.getAPNSToken();
      } catch (e) {
        // iOS 시뮬레이터에서는 APNS 토큰 오류가 정상이므로 조용히 처리
        debugPrint('[FcmService] APNS 토큰 요청 (시뮬레이터일 수 있음): $e');
      }

      final fcmToken = token ?? await _messaging.getToken();
      if (fcmToken == null) {
        print('FCM 토큰을 가져올 수 없습니다.');
        return;
      }

      // users 컬렉션에 FCM 토큰 저장
      await _firestore.collection('users').doc(userId).update({
        'fcmToken': fcmToken,
        'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
      });

      // fcmTokens 서브컬렉션에도 저장 (토큰별 조회를 위해)
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('fcmTokens')
          .doc(fcmToken)
          .set({
            'token': fcmToken,
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          });

      print('FCM 토큰이 저장되었습니다: $fcmToken');
    } catch (e) {
      print('FCM 토큰 저장 실패: $e');
    }
  }

  /// FCM 토큰 삭제 (로그아웃 시)
  Future<void> deleteToken(String userId) async {
    try {
      final token = await _messaging.getToken();
      if (token != null) {
        // users 문서에서 토큰 제거
        await _firestore.collection('users').doc(userId).update({
          'fcmToken': FieldValue.delete(),
        });

        // fcmTokens 서브컬렉션에서도 삭제
        await _firestore
            .collection('users')
            .doc(userId)
            .collection('fcmTokens')
            .doc(token)
            .delete();

        // 디바이스에서도 토큰 삭제
        await _messaging.deleteToken();
      }
    } catch (e) {
      print('FCM 토큰 삭제 실패: $e');
    }
  }

  /// 포그라운드 알림 UI 표시
  void _showForegroundNotification(RemoteMessage message) {
    final context = navigatorKey.currentContext;
    if (context == null) {
      return;
    }

    final title = message.notification?.title ?? '알림';
    final body = message.notification?.body ?? '';

    // PushNotificationOverlay를 사용하여 알림 표시
    PushNotificationOverlay.show(
      context: context,
      title: title,
      body: body,
      onTap: () {
        _handleNotificationTap(message.data);
      },
    );
  }

  /// 알림 탭 처리
  void _handleNotificationTap(Map<String, dynamic>? data) {
    final context = navigatorKey.currentContext;
    if (context == null) return;

    // notificationId가 있으면 알림 화면으로 이동
    final notificationId = data?['notificationId'];
    if (notificationId != null) {
      Navigator.of(context).pushNamed('/notifications');
    }
  }

  /// 앱이 종료된 상태에서 알림 클릭으로 열렸는지 확인
  Future<void> checkInitialMessage() async {
    final message = await _messaging.getInitialMessage();
    if (message != null) {
      print('앱 종료 상태에서 알림 클릭으로 열림: ${message.data}');
      _handleNotificationTap(message.data);
    }
  }

  /// 백그라운드 메시지 핸들러 설정
  static Future<void> backgroundMessageHandler(RemoteMessage message) async {
    print('백그라운드 메시지 수신: ${message.messageId}');
    print('제목: ${message.notification?.title}');
    print('본문: ${message.notification?.body}');
    print('데이터: ${message.data}');
  }

  /// 리소스 정리
  void dispose() {
    _tokenRefreshSubscription?.cancel();
    _isInitialized = false;
  }
}
