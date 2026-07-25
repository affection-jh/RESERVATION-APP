import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../utils/navigator_key.dart';
import '../providers/notification_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/member_provider.dart';
import '../providers/course_provider.dart';
import '../providers/enrollment_provider.dart';
import '../providers/place_provider.dart';
import '../screens/admin/widgets/enrollment_detail_screen.dart';
import 'dart:async';

/// Firebase Cloud Messaging 서비스
/// FCM 토큰 관리 및 푸시 알림 수신 처리
class FcmService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<RemoteMessage>? _foregroundMessageSubscription;
  StreamSubscription<RemoteMessage>? _messageOpenedSubscription;
  bool _isInitialized = false;

  /// 현재 로그인 사용자. 로그아웃 시 null.
  /// onTokenRefresh 클로저가 이전 UID를 붙잡지 않도록 필드로 관리한다.
  String? _boundUserId;

  /// FCM 초기화 및 토큰 저장
  /// 사용자와 관리자 모두 동일하게 처리
  Future<void> initialize(String userId) async {
    debugPrint(
      '[FcmService] initialize() called, userId=$userId, _isInitialized=$_isInitialized, bound=$_boundUserId',
    );
    // 계정 전환 시에도 갱신 리스너가 새 UID로 저장하도록 항상 바인딩
    _boundUserId = userId;

    if (_isInitialized) {
      debugPrint('[FcmService] 이미 초기화됨 → 토큰만 Firestore에 저장');
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
    debugPrint(
      '[FcmService] requestPermission 결과: authorizationStatus=${settings.authorizationStatus}',
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional) {
      debugPrint('[FcmService] FCM 권한 승인됨 → 토큰 저장 및 핸들러 설정');

      // FCM 토큰 가져오기 및 저장
      await _saveTokenToFirestore(userId);

      // 토큰 갱신 리스너 — 항상 현재 _boundUserId 사용 (계정 전환 대응)
      _tokenRefreshSubscription?.cancel();
      _tokenRefreshSubscription = _messaging.onTokenRefresh.listen((newToken) {
        final uid = _boundUserId;
        final masked =
            newToken.length > 12
                ? '${newToken.substring(0, 6)}...${newToken.substring(newToken.length - 6)}'
                : newToken;
        debugPrint('[FcmService] FCM 토큰 갱신됨: $masked boundUserId=$uid');
        if (uid == null || uid.isEmpty) {
          debugPrint('[FcmService] 로그아웃 상태 → 토큰 갱신 저장 스킵');
          return;
        }
        _saveTokenToFirestore(uid, token: newToken);
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

    // 포그라운드: 로그 + 빨간 점 갱신만 (알림 UI는 띄우지 않음)
    _foregroundMessageSubscription = FirebaseMessaging.onMessage.listen((
      RemoteMessage message,
    ) {
      debugPrint(
        '[FCM Foreground] messageId=${message.messageId} notificationId=${message.data['notificationId']}',
      );
      try {
        _addNotificationToProvider(message.data);
      } catch (e) {
        debugPrint('[FCM Foreground] addNotificationToProvider error: $e');
      }
    });

    // 알림 탭 (백그라운드에서 알림 눌러 앱 연 경우)
    _messageOpenedSubscription = FirebaseMessaging.onMessageOpenedApp.listen((
      RemoteMessage message,
    ) {
      debugPrint('[FCM] onMessageOpenedApp messageId=${message.messageId}');
      try {
        _addNotificationToProvider(message.data);
        _handleNotificationTap(message.data);
      } catch (e) {
        debugPrint('[FCM] onMessageOpenedApp error: $e');
      }
    });
  }

  /// NotificationProvider에 새 알림 추가 → 빨간 점 갱신 (context 없으면 최대 3회 재시도)
  void _addNotificationToProvider(
    Map<String, dynamic>? data, {
    int retryCount = 0,
  }) {
    final notificationId = data?['notificationId'];
    if (notificationId == null || notificationId is! String) return;

    final context = navigatorKey.currentContext;
    if (context == null) {
      if (retryCount < 3) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _addNotificationToProvider(data, retryCount: retryCount + 1);
        });
      }
      return;
    }
    try {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final notificationProvider = Provider.of<NotificationProvider>(
        context,
        listen: false,
      );
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final currentUser = authProvider.currentUser;
      // 배지·목록과 동일 컨텍스트 (멤버 홈에서 관리자 알림으로 배지 오탐 방지)
      final isAdmin = notificationProvider.isAdminNotificationContext;
      final userId = currentUser?.userId;
      if (userId == null) return;

      final placeId = placeProvider.currentPlace?.id;
      notificationProvider
          .addNotificationFromId(
            notificationId,
            userId,
            isAdmin,
            placeId: placeId,
          )
          .catchError(
            (e) => debugPrint('[FCM] addNotificationFromId error: $e'),
          );
    } catch (e) {
      debugPrint('[FCM] _addNotificationToProvider error: $e');
    }
  }

  /// iOS에서 APNS 지연 시 동기 대기 후 재시도 (2초, 5초)
  static const List<int> _iosApnsRetryDelays = [2, 5]; // 1+2회 재시도용

  /// 유저 정보 로드 시 등에서 호출. 토큰이 없거나 갱신 필요 시 재발급 후 저장.
  Future<void> ensureTokenForUser(String userId) async {
    await _saveTokenToFirestore(userId);
  }

  /// FCM 토큰을 Firestore에 저장. [token]이 있으면 그대로 저장, 없으면 getToken() 호출(동기 재시도).
  Future<void> _saveTokenToFirestore(String userId, {String? token}) async {
    debugPrint(
      '[FcmService] _saveTokenToFirestore() userId=$userId, tokenProvided=${token != null}',
    );
    final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
    debugPrint('[FcmService] platform=${isIOS ? "iOS" : "Android"}');

    // 호출자가 토큰을 넘긴 경우(예: onTokenRefresh) → 재시도 없이 바로 저장
    if (token != null && token.isNotEmpty) {
      await _writeTokenToFirestore(userId, token);
      return;
    }

    // 토큰 발급: iOS는 APNS 대기 후 동기 재시도
    String? fcmToken;
    const maxAttempts = 4; // 1회 시도 + 3회 재시도

    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      if (attempt > 0 && isIOS) {
        final idx = (attempt - 1).clamp(0, _iosApnsRetryDelays.length - 1);
        final delaySec = _iosApnsRetryDelays[idx];
        debugPrint(
          '[FcmService] ${delaySec}초 대기 후 재시도 (${attempt + 1}/$maxAttempts)',
        );
        await Future.delayed(Duration(seconds: delaySec));
      }

      try {
        if (isIOS && attempt == 0) {
          final apns = await _messaging.getAPNSToken();
          debugPrint('[FcmService] APNS 토큰: ${apns != null ? "있음" : "대기 중"}');
        }
        fcmToken = await _messaging.getToken();
        if (fcmToken != null && fcmToken.isNotEmpty) break;
      } catch (e) {
        final isApnsNotSet = e.toString().contains('apns-token-not-set');
        if (isIOS && isApnsNotSet && attempt == maxAttempts - 1) {
          debugPrint(
            '[FcmService] iOS 푸시 토큰을 사용할 수 없습니다. '
            '실기기: Firebase 콘솔 → Cloud Messaging → APNs 인증 키 등록을 확인해 주세요.',
          );
        } else if (!isIOS || !isApnsNotSet) {
          debugPrint('[FcmService] getToken 오류: $e');
        }
      }
    }

    if (fcmToken == null || fcmToken.isEmpty) {
      debugPrint('[FcmService] FCM 토큰을 가져오지 못했습니다.');
      return;
    }

    final masked =
        fcmToken.length > 12
            ? '${fcmToken.substring(0, 6)}...${fcmToken.substring(fcmToken.length - 6)}'
            : fcmToken;
    debugPrint('[FcmService] FCM 토큰 획득됨 len=${fcmToken.length} masked=$masked');

    await _writeTokenToFirestore(userId, fcmToken);
  }

  Future<void> _writeTokenToFirestore(String userId, String fcmToken) async {
    try {
      await _firestore.runTransaction((transaction) async {
        final userRef = _firestore.collection('users').doc(userId);
        transaction.set(userRef, {
          'fcmToken': fcmToken,
          'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

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
      debugPrint('[FcmService] FCM 토큰 Firestore 저장 완료 userId=$userId');
    } catch (e, stack) {
      debugPrint('[FcmService] FCM 토큰 저장 실패: $e');
      debugPrint('[FcmService] stack: $stack');
    }
  }

  /// 로그아웃 시: 이 기기 토큰을 해당 유저 문서에서만 제거
  ///
  /// 기기 FCM 토큰(`FirebaseMessaging.deleteToken`)은 지우지 않는다.
  /// 지우면 즉시 새 토큰이 발급되며, 계정 전환 직후 이전 UID로 저장되는
  /// 레이스/permission-denied가 생기고, 잘못된 토큰이 남을 수 있다.
  Future<void> deleteToken(String userId) async {
    // 갱신 리스너가 로그아웃된 UID로 쓰지 않도록 먼저 해제
    if (_boundUserId == userId) {
      _boundUserId = null;
    }

    try {
      String? token;
      try {
        token = await _messaging.getToken();
      } catch (e) {
        debugPrint('[FcmService] getToken (logout) 실패: $e');
      }

      await _firestore.runTransaction((transaction) async {
        final userRef = _firestore.collection('users').doc(userId);
        transaction.set(userRef, {
          'fcmToken': FieldValue.delete(),
          'fcmTokenUpdatedAt': FieldValue.delete(),
        }, SetOptions(merge: true));

        if (token != null && token.isNotEmpty) {
          final tokenRef = _firestore
              .collection('users')
              .doc(userId)
              .collection('fcmTokens')
              .doc(token);
          transaction.delete(tokenRef);
        }
      });
      debugPrint(
        '[FcmService] 로그아웃: Firestore FCM 토큰 제거 완료 userId=$userId '
        '(기기 토큰은 유지)',
      );
    } catch (e) {
      debugPrint('[FcmService] FCM 토큰 삭제 실패: $e');
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
      memberProvider.setPlaceId(placeId);
      final member = memberProvider.getMemberView(userId);
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

      // EnrollmentDetailScreen으로 이동 (지정된 탭으로)
      if (context.mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder:
                (context) => EnrollmentDetailScreen(
                  member: member,
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

  /// 앱이 종료된 상태에서 알림 탭으로 열렸는지 확인
  Future<void> checkInitialMessage() async {
    try {
      final message = await _messaging.getInitialMessage();
      if (message != null) {
        debugPrint(
          '[FCM] getInitialMessage (앱 종료 상태에서 알림 탭으로 실행) messageId=${message.messageId}',
        );
        _addNotificationToProvider(message.data);
        _handleNotificationTap(message.data);
      }
    } catch (e) {
      debugPrint('[FCM] checkInitialMessage error: $e');
    }
  }

  /// 백그라운드/종료 상태 수신 (OS가 notification payload 있으면 자동 표시 → 앱 복귀 시 loadNotifications로 빨간 점 갱신)
  static Future<void> backgroundMessageHandler(RemoteMessage message) async {
    debugPrint(
      '[FCM Background] messageId=${message.messageId} notificationId=${message.data['notificationId']}',
    );
  }

  /// 리소스 정리
  void dispose() {
    _tokenRefreshSubscription?.cancel();
    _foregroundMessageSubscription?.cancel();
    _messageOpenedSubscription?.cancel();
    _tokenRefreshSubscription = null;
    _foregroundMessageSubscription = null;
    _messageOpenedSubscription = null;
    _boundUserId = null;
    _isInitialized = false;
  }
}
