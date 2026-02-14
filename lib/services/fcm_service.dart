import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../widgets/push_notification_overlay.dart';
import '../utils/navigator_key.dart';
import '../providers/notification_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/member_provider.dart';
import '../providers/course_provider.dart';
import '../providers/enrollment_provider.dart';
import '../providers/place_provider.dart';
import '../screens/admin/widgets/enrollment_detail_screen.dart';
import '../models/admin_models.dart';
import 'dart:async';
import 'dart:convert';

/// Firebase Cloud Messaging 서비스
/// FCM 토큰 관리 및 푸시 알림 수신 처리
class FcmService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<RemoteMessage>? _foregroundMessageSubscription;
  StreamSubscription<RemoteMessage>? _messageOpenedSubscription;
  bool _isInitialized = false;

  static String _safeTruncate(String value, {int max = 80}) {
    if (value.length <= max) return value;
    return '${value.substring(0, max)}...(${value.length})';
  }

  static String _prettyJson(Object? obj) {
    try {
      return const JsonEncoder.withIndent('  ').convert(obj);
    } catch (_) {
      return obj?.toString() ?? '';
    }
  }

  /// FCM 로그를 터미널에서 쉽게 찾기 위한 블록 로그
  static void logRemoteMessage(RemoteMessage message, {required String event}) {
    final now = DateTime.now().toIso8601String();
    final title = message.notification?.title ?? '';
    final body = message.notification?.body ?? '';
    final data = message.data;
    final notificationId = data['notificationId'];
    final type = data['type'];

    debugPrint('');
    debugPrint('==================== FCM [$event] ====================');
    debugPrint('time: $now');
    debugPrint('messageId: ${message.messageId ?? '-'}');
    debugPrint('sentTime: ${message.sentTime?.toIso8601String() ?? '-'}');
    debugPrint('from: ${message.from ?? '-'}');
    debugPrint('notificationId: ${notificationId ?? '-'}');
    debugPrint('type: ${type ?? '-'}');
    debugPrint('title: ${_safeTruncate(title)}');
    debugPrint('body: ${_safeTruncate(body, max: 160)}');
    debugPrint('data:\n${_prettyJson(data)}');
    debugPrint('======================================================');
    debugPrint('');
  }

  static void logData(Map<String, dynamic>? data, {required String event}) {
    final now = DateTime.now().toIso8601String();
    final notificationId = data?['notificationId'];
    final type = data?['type'];

    debugPrint('');
    debugPrint('==================== FCM [$event] ====================');
    debugPrint('time: $now');
    debugPrint('notificationId: ${notificationId ?? '-'}');
    debugPrint('type: ${type ?? '-'}');
    debugPrint('data:\n${_prettyJson(data ?? const {})}');
    debugPrint('======================================================');
    debugPrint('');
  }

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
      debugPrint('[FcmService] FCM 권한 승인됨');

      // FCM 토큰 가져오기 및 저장
      await _saveTokenToFirestore(userId);

      // 토큰 갱신 리스너
      _tokenRefreshSubscription = _messaging.onTokenRefresh.listen((newToken) {
        final masked =
            newToken.length > 12
                ? '${newToken.substring(0, 6)}...${newToken.substring(newToken.length - 6)}'
                : newToken;
        debugPrint('[FcmService] FCM 토큰 갱신됨: $masked');
        _saveTokenToFirestore(userId, token: newToken);
      });

      // 포그라운드 메시지 핸들러 설정 (한 번만)
      _setupForegroundHandlers();

      _isInitialized = true;
      debugPrint('[FcmService] FCM 초기화 완료');
    } else {
      debugPrint(
        '[FcmService] FCM 권한이 거부되었습니다. 상태: ${settings.authorizationStatus}',
      );
    }
  }

  /// 포그라운드 메시지 핸들러 설정
  void _setupForegroundHandlers() {
    // 이미 설정되어 있으면 중복 등록 방지
    if (_foregroundMessageSubscription != null ||
        _messageOpenedSubscription != null) {
      debugPrint('[FcmService] 포그라운드 핸들러가 이미 설정되어 있습니다.');
      return;
    }

    // 포그라운드 메시지 핸들러
    _foregroundMessageSubscription = FirebaseMessaging.onMessage.listen((
      RemoteMessage message,
    ) {
      logRemoteMessage(message, event: 'FOREGROUND_RECEIVED');

      try {
        // NotificationProvider에 새 알림 추가 (먼저 실행하여 빨간 닷 즉시 표시)
        _addNotificationToProvider(message.data);
        // 포그라운드 알림 UI 표시 (스낵바처럼 상단에)
        _showForegroundNotification(message);
      } catch (e) {
        debugPrint('[FcmService] 포그라운드 알림 처리 오류: $e');
      }
    });

    // 알림 클릭 핸들러
    _messageOpenedSubscription = FirebaseMessaging.onMessageOpenedApp.listen((
      RemoteMessage message,
    ) {
      logRemoteMessage(message, event: 'TAP_OPENED_APP');
      try {
        _handleNotificationTap(message.data);
      } catch (e) {
        debugPrint('[FcmService] 알림 클릭 처리 오류: $e');
      }
    });

    debugPrint('[FcmService] 포그라운드 핸들러 설정 완료');
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
        final placeProvider = Provider.of<PlaceProvider>(
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

        // 현재 플레이스 ID 가져오기
        final currentPlace = placeProvider.currentPlace;
        final placeId = currentPlace?.id;

        // 비동기로 실행하되 await하지 않음 (즉시 반환하여 UI가 블로킹되지 않도록)
        // addNotificationFromId 내부에서 notifyListeners()가 호출되므로 빨간 닷이 즉시 표시됨
        notificationProvider
            .addNotificationFromId(
              notificationId,
              userId,
              isAdmin,
              placeId: placeId,
            )
            .catchError((e) {
              debugPrint('[FcmService] _addNotificationToProvider error: $e');
            });
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

      // ✅ 트랜잭션으로 원자적 저장 (users 문서 + 서브컬렉션)
      await _firestore.runTransaction((transaction) async {
        final userRef = _firestore.collection('users').doc(userId);
        transaction.update(userRef, {
          'fcmToken': fcmToken,
          'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
        });

        final tokenRef = _firestore
            .collection('users')
            .doc(userId)
            .collection('fcmTokens')
            .doc(fcmToken);
        transaction.set(tokenRef, {
          'token': fcmToken,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });

      debugPrint('[FcmService] FCM 토큰이 저장되었습니다: $fcmToken');
    } catch (e) {
      debugPrint('[FcmService] FCM 토큰 저장 실패: $e');
    }
  }

  /// FCM 토큰 삭제 (로그아웃 시)
  Future<void> deleteToken(String userId) async {
    try {
      final token = await _messaging.getToken();
      if (token != null) {
        // ✅ 트랜잭션으로 원자적 삭제 (users 문서 + 서브컬렉션)
        await _firestore.runTransaction((transaction) async {
          final userRef = _firestore.collection('users').doc(userId);
          transaction.update(userRef, {'fcmToken': FieldValue.delete()});

          final tokenRef = _firestore
              .collection('users')
              .doc(userId)
              .collection('fcmTokens')
              .doc(token);
          transaction.delete(tokenRef);
        });

        // 디바이스에서도 토큰 삭제
        await _messaging.deleteToken();
        debugPrint('[FcmService] FCM 토큰 삭제 완료');
      }
    } catch (e) {
      debugPrint('[FcmService] FCM 토큰 삭제 실패: $e');
    }
  }

  /// 포그라운드 알림 UI 표시 (스낵바처럼 상단에)
  void _showForegroundNotification(RemoteMessage message) {
    final context = navigatorKey.currentContext;
    if (context == null) {
      debugPrint('[FcmService] context가 없어 포그라운드 알림을 표시할 수 없습니다.');
      return;
    }

    final title = message.notification?.title ?? '알림';
    final body = message.notification?.body ?? '';

    if (title.isEmpty && body.isEmpty) {
      debugPrint('[FcmService] 알림 제목과 본문이 모두 비어있습니다.');
      return;
    }

    debugPrint('[FcmService] 포그라운드 알림 표시: $title');

    // PushNotificationOverlay를 사용하여 알림 표시 (스낵바처럼 상단에)
    try {
      PushNotificationOverlay.show(
        context: context,
        title: title,
        body: body,
        onTap: () {
          _handleNotificationTap(message.data);
        },
      );
    } catch (e) {
      debugPrint('[FcmService] 포그라운드 알림 표시 오류: $e');
    }
  }

  /// 알림 탭 처리
  Future<void> _handleNotificationTap(Map<String, dynamic>? data) async {
    final context = navigatorKey.currentContext;
    if (context == null) return;

    // 연장 요청 알림인지 확인 (enrollmentId, userId, courseId, placeId가 모두 있는 경우)
    final enrollmentId = data?['enrollmentId'] as String?;
    final userId = data?['userId'] as String?;
    final courseId = data?['courseId'] as String?;
    final placeId = data?['placeId'] as String?;
    final notificationId = data?['notificationId'] as String?;

    // 알림 타입 확인
    final notificationType = data?['type'] as String?;

    // 연장 요청 알림인 경우 enrollment 상세 화면으로 이동
    if (enrollmentId != null &&
        userId != null &&
        courseId != null &&
        placeId != null) {
      // 연장 요청: 탭 1
      final initialTabIndex = 1;

      debugPrint(
        '[FcmService] 연장 요청 알림 클릭: enrollmentId=$enrollmentId, userId=$userId, courseId=$courseId, tabIndex=$initialTabIndex',
      );

      try {
        // 알림 읽은 처리
        if (notificationId != null) {
          await _markNotificationAsRead(notificationId, context);
        }

        // enrollment 상세 화면으로 이동
        await _navigateToEnrollmentDetail(
          context: context,
          enrollmentId: enrollmentId,
          userId: userId,
          courseId: courseId,
          placeId: placeId,
          initialTabIndex: initialTabIndex,
        );
        return;
      } catch (e) {
        debugPrint('[FcmService] enrollment 상세 화면 이동 오류: $e');
        // 오류 발생 시 일반 알림 화면으로 이동
      }
    }

    // 스토리 알림인 경우 스토리 상세 화면으로 이동
    if (notificationType == 'story') {
      final storyId = data?['storyId'] as String?;
      final storyPlaceId = data?['placeId'] as String?;
      if (storyId != null && storyPlaceId != null) {
        try {
          // 알림 읽은 처리
          if (notificationId != null) {
            await _markNotificationAsRead(notificationId, context);
          }

          // 홈 화면으로 이동 (스토리는 홈 화면에서 확인 가능)
          Navigator.of(context).pushNamedAndRemoveUntil(
            '/main',
            (route) => false,
            arguments: {'initialIndex': 0}, // 홈 탭
          );
          return;
        } catch (e) {
          debugPrint('[FcmService] 스토리 화면 이동 오류: $e');
        }
      }
    }

    // 프로모션 알림인 경우 홈 화면으로 이동
    if (notificationType == 'promotion') {
      try {
        // 알림 읽은 처리
        if (notificationId != null) {
          await _markNotificationAsRead(notificationId, context);
        }

        // 홈 화면으로 이동
        Navigator.of(context).pushNamedAndRemoveUntil(
          '/main',
          (route) => false,
          arguments: {'initialIndex': 0}, // 홈 탭
        );
        return;
      } catch (e) {
        debugPrint('[FcmService] 프로모션 화면 이동 오류: $e');
      }
    }

    // 일반 알림인 경우 알림 화면으로 이동
    if (notificationId != null) {
      // 알림 읽은 처리
      await _markNotificationAsRead(notificationId, context);
      Navigator.of(context).pushNamed('/notifications');
    }
  }

  /// 알림 읽은 처리
  Future<void> _markNotificationAsRead(
    String notificationId,
    BuildContext context,
  ) async {
    try {
      final notificationProvider = Provider.of<NotificationProvider>(
        context,
        listen: false,
      );

      await notificationProvider.markAsRead(notificationId);
      debugPrint('[FcmService] 알림 읽은 처리 완료: $notificationId');
    } catch (e) {
      debugPrint('[FcmService] 알림 읽은 처리 오류: $e');
    }
  }

  /// Enrollment 상세 화면으로 이동
  Future<void> _navigateToEnrollmentDetail({
    required BuildContext context,
    required String enrollmentId,
    required String userId,
    required String courseId,
    required String placeId,
    int initialTabIndex = 1, // 기본값: 연장 탭 (1)
  }) async {
    try {
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final memberProvider = Provider.of<MemberProvider>(
        context,
        listen: false,
      );
      final courseProvider = Provider.of<CourseProvider>(
        context,
        listen: false,
      );
      final enrollmentProvider = Provider.of<EnrollmentProvider>(
        context,
        listen: false,
      );

      // 현재 플레이스 확인
      final currentPlace = placeProvider.currentPlace;
      if (currentPlace?.id != placeId) {
        debugPrint(
          '[FcmService] 플레이스 불일치: current=${currentPlace?.id}, required=$placeId',
        );
        // 플레이스를 변경하거나 오류 메시지 표시
        return;
      }

      // 멤버 조회
      await memberProvider.loadMembers(placeId);
      final member = memberProvider.getMember(userId);
      if (member == null) {
        debugPrint('[FcmService] 멤버를 찾을 수 없습니다: $userId');
        return;
      }

      // 코스 조회
      await courseProvider.loadCourses(placeId);
      final course = courseProvider.courses.firstWhere(
        (c) => c.id == courseId,
        orElse: () => courseProvider.courses.first,
      );

      // Enrollment 조회
      await enrollmentProvider.loadUserEnrollments(
        userId: userId,
        placeId: placeId,
      );
      final enrollment = enrollmentProvider.enrollments.firstWhere(
        (e) => e.id == enrollmentId,
        orElse: () => throw Exception('Enrollment not found'),
      );

      // MemberData 생성
      final memberData = MemberData(
        userId: member.userId,
        name: member.name,
        phoneNumber: member.phoneNumber,
        role: 'user', // 관리자 여부는 adminUsers 등 별도 소스에서 조회
        isActive: true,
        pendingExtensionRequests: member.pendingExtensionRequests.length,
        enrolledCourseIds: member.enrollments.map((e) => e.courseId).toList(),
      );

      // EnrollmentDetailScreen으로 이동 (지정된 탭으로)
      if (context.mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder:
                (context) => EnrollmentDetailScreen(
                  member: memberData,
                  enrollment: enrollment,
                  course: course,
                ),
          ),
        );
      }
    } catch (e) {
      debugPrint('[FcmService] enrollment 상세 화면 이동 오류: $e');
      rethrow;
    }
  }

  /// 앱이 종료된 상태에서 알림 클릭으로 열렸는지 확인
  Future<void> checkInitialMessage() async {
    try {
      final message = await _messaging.getInitialMessage();
      if (message != null) {
        logRemoteMessage(message, event: 'TAP_LAUNCH_FROM_TERMINATED');
        _handleNotificationTap(message.data);
      }
    } catch (e) {
      debugPrint('[FcmService] 초기 메시지 확인 오류: $e');
    }
  }

  /// 백그라운드 메시지 핸들러 설정
  static Future<void> backgroundMessageHandler(RemoteMessage message) async {
    logRemoteMessage(message, event: 'BACKGROUND_RECEIVED');
  }

  /// 리소스 정리
  void dispose() {
    _tokenRefreshSubscription?.cancel();
    _foregroundMessageSubscription?.cancel();
    _messageOpenedSubscription?.cancel();
    _tokenRefreshSubscription = null;
    _foregroundMessageSubscription = null;
    _messageOpenedSubscription = null;
    _isInitialized = false;
  }
}
