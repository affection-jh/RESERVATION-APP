import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:provider/provider.dart';
import 'firebase_options.dart';
import 'screens/home_screen.dart';
import 'screens/reservation_screen.dart';
import 'screens/admin_screen.dart';
import 'screens/my_page_screen.dart';
import 'screens/phone_number_input_screen.dart';
import 'screens/verification_code_screen.dart';
import 'screens/name_input_screen.dart';
import 'screens/place_waiting_screen.dart';
import 'screens/notification_screen.dart';
import 'screens/app_startup_screen.dart';
import 'screens/webview_screen.dart';
import 'theme/app_colors.dart';
import 'widgets/bottom_nav_bar.dart';
import 'providers/place_provider.dart';
import 'providers/course_provider.dart';
import 'providers/reservation_provider.dart';
import 'providers/member_provider.dart';
import 'providers/story_provider.dart';
import 'providers/notification_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/enrollment_provider.dart';
import 'providers/reservation_summary_provider.dart';
import 'services/fcm_service.dart';
import 'utils/navigator_key.dart';
import 'widgets/reservation_feedback_listener.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

/// 앱 전역 상수 (버전 등)
abstract class AppConfig {
  static const String appVersion = '1.0.5';
}

// 백그라운드 메시지 핸들러 (최상위 함수로 선언, 앱이 백그라운드/종료일 때만 호출)
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await FcmService.backgroundMessageHandler(message);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // 백그라운드 메시지 핸들러 등록
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  runApp(const MyApp());
}

/// 앱이 포그라운드로 복귀할 때 알림 목록 재로드 (백그라운드에서 수신한 FCM 반영)
class _AppLifecycleNotifier extends StatefulWidget {
  final Widget child;

  const _AppLifecycleNotifier({required this.child});

  @override
  State<_AppLifecycleNotifier> createState() => _AppLifecycleNotifierState();
}

class _AppLifecycleNotifierState extends State<_AppLifecycleNotifier>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _reloadNotificationsOnResume();
  }

  void _reloadNotificationsOnResume() {
    if (!mounted) return;
    try {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final notificationProvider = Provider.of<NotificationProvider>(
        context,
        listen: false,
      );
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final placeId = placeProvider.currentPlace?.id;
      final user = authProvider.currentUser;
      if (user == null) return;

      // currentAdmin == currentUser 이므로 진입 시 저장된 알림 컨텍스트 사용
      // (매니저라도 멤버 홈이면 isAdmin=false)
      final isAdmin = notificationProvider.isAdminNotificationContext;

      // 유저 정보 기준으로 FCM 토큰 없으면 재발급 후 저장
      authProvider.ensureFcmTokenSaved().catchError(
        (e) => debugPrint('[AppLifecycle] FCM 토큰 저장 실패: $e'),
      );

      notificationProvider
          .refreshUnreadBadge(user.userId, isAdmin: isAdmin, placeId: placeId)
          .catchError((e) => debugPrint('[AppLifecycle] 알림 배지 갱신 실패: $e'));
    } catch (e) {
      debugPrint('[AppLifecycle] 알림 재로드 오류: $e');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => PlaceProvider()),
        ChangeNotifierProvider(create: (_) => CourseProvider()),
        ChangeNotifierProvider(create: (_) => ReservationProvider()),
        ChangeNotifierProvider(create: (_) => EnrollmentProvider()),
        ChangeNotifierProvider(create: (_) => MemberProvider()),
        ChangeNotifierProvider(create: (_) => ReservationSummaryProvider()),
        ChangeNotifierProvider(create: (_) => StoryProvider()),
        ChangeNotifierProvider(create: (_) => NotificationProvider()),
      ],
      child: _AppLifecycleNotifier(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: [routeObserver],
          title: '바로예약',
          builder: (context, child) {
            return MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(1.0)),
              child: child!,
            );
          },
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.light(
              primary: AppColors.primaryGreen,
              secondary: AppColors.secondaryBrown,
              surface: AppColors.backgroundWhite,
              background: AppColors.backgroundLight,
              onPrimary: Colors.white,
              onSecondary: Colors.white,
              onSurface: AppColors.textPrimary,
              onBackground: AppColors.textPrimary,
              onError: Colors.white,
            ),
            scaffoldBackgroundColor: AppColors.backgroundLight,
            appBarTheme: AppBarTheme(
              backgroundColor: AppColors.backgroundWhite,
              foregroundColor: AppColors.textPrimary,
              elevation: 0,
              iconTheme: const IconThemeData(color: AppColors.textPrimary),
            ),
          ),
          initialRoute: '/',
          routes: {
            '/': (context) => const AppStartupScreen(),
            '/phone-number': (context) {
              return PhoneNumberInputScreen();
            },
            '/verification-code': (context) {
              final args = ModalRoute.of(context)?.settings.arguments;
              if (args is Map<String, dynamic>) {
                return VerificationCodeScreen(
                  phoneNumber: args['phoneNumber'] ?? '',
                  isPlaceRegistrationFlow:
                      args['isPlaceRegistrationFlow'] ?? false,
                );
              } else if (args is String) {
                return VerificationCodeScreen(phoneNumber: args);
              } else {
                return VerificationCodeScreen(phoneNumber: '');
              }
            },
            '/name-input': (context) {
              final args =
                  ModalRoute.of(context)?.settings.arguments
                      as Map<String, dynamic>?;
              return NameInputScreen(
                phoneNumber: args?['phoneNumber'] ?? '',
                smsCode: args?['smsCode'] ?? '',
              );
            },
            '/place-waiting': (context) {
              final args = ModalRoute.of(context)?.settings.arguments;
              String phoneNumber = '';
              bool skipAutoEnter = false;
              if (args is Map) {
                phoneNumber = (args['phoneNumber'] as String?) ?? '';
                skipAutoEnter = args['skipAutoEnter'] == true;
              } else if (args is String) {
                phoneNumber = args;
              }
              return PlaceWaitingScreen(
                phoneNumber: phoneNumber,
                skipAutoEnter: skipAutoEnter,
              );
            },
            '/main': (context) {
              // arguments로 초기 탭 인덱스 또는 예약 정보 받기
              final args = ModalRoute.of(context)?.settings.arguments;
              int initialIndex = 0;
              Map<String, dynamic>? highlightReservation;
              Map<String, dynamic>? highlightNewSession;

              if (args is int) {
                initialIndex = args;
              } else if (args is Map<String, dynamic>) {
                initialIndex = args['initialIndex'] as int? ?? 0;
                highlightReservation =
                    args['highlightReservation'] as Map<String, dynamic>?;
                highlightNewSession =
                    args['highlightNewSession'] as Map<String, dynamic>?;
              }

              return MainScreen(
                initialIndex: initialIndex,
                highlightReservation: highlightReservation,
                highlightNewSession: highlightNewSession,
              );
            },
            '/admin': (context) => const AdminScreen(),
            '/notifications': (context) => const NotificationScreen(),
            '/webview': (context) {
              final args =
                  ModalRoute.of(context)?.settings.arguments
                      as Map<String, dynamic>?;
              return WebViewScreen(
                url: args?['url'] ?? '',
                title: args?['title'] ?? '웹페이지',
              );
            },
          },
        ),
      ),
    );
  }
}

class MainScreen extends StatefulWidget {
  final int initialIndex; // 초기 탭 인덱스
  final Map<String, dynamic>? highlightReservation; // 강조할 예약 정보
  final Map<String, dynamic>?
  highlightNewSession; // 새 수업 일정 알림 → 예약 화면에서 해당 세션 표시

  const MainScreen({
    super.key,
    this.initialIndex = 0, // 기본값: 홈
    this.highlightReservation,
    this.highlightNewSession,
  });

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  late int _currentIndex;
  bool _isInitialDataLoaded = false;

  // "명시적으로 마이페이지로 이동"했을 때만 1회 소비되는 하이라이트 데이터
  Map<String, dynamic>? _pendingHighlightReservation;
  Map<String, dynamic>? _pendingHighlightNewSession;

  @override
  void initState() {
    super.initState();
    _pendingHighlightReservation = widget.highlightReservation;
    _pendingHighlightNewSession = widget.highlightNewSession;
    _currentIndex = widget.initialIndex.clamp(0, 2);
    // Provider load → notifyListeners()가 첫 build 중에 발생하면
    // "setState() or markNeedsBuild() called during build"가 터질 수 있어서
    // 첫 프레임 이후로 미룬다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadInitialData();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // auth/place가 나중에 세팅되는 케이스(자동로그인/플레이스 선택)에서
    // initState 때 한 번 스킵되면 구독이 영원히 시작되지 않는 문제 방지.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadInitialData();
    });
  }

  /// 초기 데이터 일괄 로드
  ///
  /// AppStartupScreen에서 이미 데이터를 로드했을 수 있으므로,
  /// Provider의 중복 로드 방지 로직에 의존합니다.
  Future<void> _loadInitialData() async {
    if (_isInitialDataLoaded) return;

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final storyProvider = Provider.of<StoryProvider>(context, listen: false);

    final reservationProvider = Provider.of<ReservationProvider>(
      context,
      listen: false,
    );
    final enrollmentProvider = Provider.of<EnrollmentProvider>(
      context,
      listen: false,
    );

    // place가 아직 준비되지 않았으면 완료 플래그를 세우지 않고 다음 기회를 기다린다.
    final currentPlace = placeProvider.currentPlace;
    if (currentPlace == null) return;

    try {
      // 메인 진입 시에는 "구독/필수 데이터" 위주로 안전하게 로드한다.
      // (이미 로드되어 있으면 스킵)
      final futures = <Future<void>>[];

      // ✅ 로그인 없이도 세션 브라우징 가능 (Apple App Store 가이드라인 준수)
      if (courseProvider.courses.isEmpty) {
        futures.add(courseProvider.loadCourses(currentPlace.id));
      }
      if (storyProvider.stories.isEmpty) {
        futures.add(storyProvider.loadStories(currentPlace.id));
      }

      // 계정 기반 기능(예약/등록)은 로그인된 경우에만 로드
      final currentUser = authProvider.currentUser;
      if (currentUser != null) {
        // 항상 구독 보장 (Provider 내부에서 중복 구독 방지)
        futures.add(
          reservationProvider.loadUserReservations(
            userId: currentUser.userId,
            placeId: currentPlace.id,
          ),
        );
        futures.add(
          enrollmentProvider.loadUserEnrollments(
            userId: currentUser.userId,
            placeId: currentPlace.id,
          ),
        );
      }

      if (futures.isNotEmpty) {
        await Future.wait(futures);
      }

      _isInitialDataLoaded = true;
    } catch (e) {
      // 에러 발생 시에도 계속 진행 (각 화면에서 개별 처리)
      _isInitialDataLoaded = true;
    }
  }

  void _onTabTapped(int index) {
    setState(() {
      _currentIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        // 뒤로가기 제스처 차단 (홈 화면이 첫 화면이므로)
        // 필요시 앱 종료 다이얼로그를 표시할 수 있음
      },
      child: Scaffold(
        body: ReservationFeedbackListener(
          child: IndexedStack(
            index: _currentIndex,
            children: [
              const HomeScreen(), // 0: 홈
              ReservationScreen(
                highlightNewSession:
                    _currentIndex == 1 ? _pendingHighlightNewSession : null,
                onHighlightConsumed: () {
                  if (_pendingHighlightNewSession != null) {
                    setState(() => _pendingHighlightNewSession = null);
                  }
                },
              ), // 1: 예약
              // 2: 마이페이지
              //
              // ⚠️ 바텀 네비로 마이페이지에 "그냥 들어왔을 때"는 하이라이트 애니메이션을 촉발하지 않는다.
              // 하이라이트는 명시적으로 전달된 경우에만 1회 실행되고 소비된다.
              MyPageScreen(
                highlightReservation:
                    _currentIndex == 2 ? _pendingHighlightReservation : null,
              ),
            ],
          ),
        ),
        bottomNavigationBar: BottomNavBar(
          currentIndex: _currentIndex,
          onTap: _onTabTapped,
        ),
      ),
    );
  }
}

// 임시 화면들

class AdminLoginScreen extends StatelessWidget {
  const AdminLoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('관리자 로그인'),
      ),
      body: const Center(child: Text('관리자 로그인 화면')),
    );
  }
}
