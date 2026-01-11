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
import 'screens/admin/admin_pin_register_screen.dart';
import 'screens/admin/admin_pin_input_screen.dart';
import 'screens/app_startup_screen.dart';
import 'screens/webview_screen.dart';
import 'theme/app_colors.dart';
import 'widgets/bottom_nav_bar.dart';
import 'providers/place_provider.dart';
import 'providers/course_provider.dart';
import 'providers/reservation_provider.dart';
import 'providers/member_provider.dart';
import 'providers/story_provider.dart';
import 'providers/promotion_provider.dart';
import 'providers/notification_provider.dart';
import 'providers/admin_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/enrollment_provider.dart';
import 'services/fcm_service.dart';
import 'utils/navigator_key.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

// 테스터 모드 플래그 (static 변수)
class AppConfig {
  static bool isTesterMode = false;
}

// 백그라운드 메시지 핸들러 (최상위 함수로 선언)
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
        ChangeNotifierProvider(create: (_) => StoryProvider()),
        ChangeNotifierProvider(create: (_) => PromotionProvider()),
        ChangeNotifierProvider(create: (_) => NotificationProvider()),
        ChangeNotifierProvider(create: (_) => AdminProvider()),
      ],
      child: MaterialApp(
        navigatorKey: navigatorKey,
        title: '기차 예약',
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
            leadingWidth: 56,
            iconTheme: const IconThemeData(color: AppColors.textPrimary),
          ),
        ),
        initialRoute: '/',
        routes: {
          '/': (context) => const AppStartupScreen(),
          '/phone-number': (context) => const PhoneNumberInputScreen(),
          '/verification-code': (context) {
            final args = ModalRoute.of(context)?.settings.arguments;
            final phoneNumber = args is String ? args : '';
            return VerificationCodeScreen(phoneNumber: phoneNumber);
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
            final phoneNumber = args is String ? args : '';
            return PlaceWaitingScreen(phoneNumber: phoneNumber);
          },
          '/main': (context) {
            // arguments로 초기 탭 인덱스 또는 예약 정보 받기
            final args = ModalRoute.of(context)?.settings.arguments;
            int initialIndex = 0;
            Map<String, dynamic>? highlightReservation;

            if (args is int) {
              initialIndex = args;
            } else if (args is Map<String, dynamic>) {
              initialIndex = args['initialIndex'] as int? ?? 0;
              highlightReservation =
                  args['highlightReservation'] as Map<String, dynamic>?;
            }

            return MainScreen(
              initialIndex: initialIndex,
              highlightReservation: highlightReservation,
            );
          },
          '/admin-register': (context) {
            final args =
                ModalRoute.of(context)?.settings.arguments
                    as Map<String, dynamic>?;
            return AdminPinRegisterScreen(
              phoneNumber: args?['phoneNumber'] ?? '',
              verificationCode: args?['verificationCode'] ?? '',
            );
          },
          '/admin-pin-input': (context) {
            final args =
                ModalRoute.of(context)?.settings.arguments
                    as Map<String, dynamic>?;
            return AdminPinInputScreen(
              phoneNumber: args?['phoneNumber'] ?? '',
              verificationCode: args?['verificationCode'] ?? '',
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
    );
  }
}

class MainScreen extends StatefulWidget {
  final int initialIndex; // 초기 탭 인덱스
  final Map<String, dynamic>? highlightReservation; // 강조할 예약 정보

  const MainScreen({
    super.key,
    this.initialIndex = 0, // 기본값: 홈
    this.highlightReservation,
  });

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  late int _currentIndex;
  bool _isInitialDataLoaded = false;

  List<Widget> get _screens => [
    const HomeScreen(), // 0: 홈
    const ReservationScreen(), // 1: 예약
    MyPageScreen(highlightReservation: widget.highlightReservation), // 2: 마이페이지
  ];

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, _screens.length - 1);
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
    final promotionProvider = Provider.of<PromotionProvider>(
      context,
      listen: false,
    );
    final reservationProvider = Provider.of<ReservationProvider>(
      context,
      listen: false,
    );
    final enrollmentProvider = Provider.of<EnrollmentProvider>(
      context,
      listen: false,
    );

    // user/place가 아직 준비되지 않았으면 완료 플래그를 세우지 않고 다음 기회를 기다린다.
    if (authProvider.currentUser == null) return;
    final currentPlace = placeProvider.currentPlace;
    if (currentPlace == null) return;

    try {
      // 메인 진입 시에는 "구독/필수 데이터" 위주로 안전하게 로드한다.
      // (이미 로드되어 있으면 스킵)
      final futures = <Future<void>>[];

      if (courseProvider.courses.isEmpty) {
        futures.add(courseProvider.loadCourses(currentPlace.id));
      }
      if (storyProvider.stories.isEmpty) {
        futures.add(storyProvider.loadStories(currentPlace.id));
      }
      if (promotionProvider.promotions.isEmpty) {
        futures.add(promotionProvider.loadPromotions(currentPlace.id));
      }
      // 항상 구독 보장 (Provider 내부에서 중복 구독 방지)
      futures.add(
        reservationProvider.loadUserReservations(
          userId: authProvider.currentUser!.userId,
          placeId: currentPlace.id,
        ),
      );
      futures.add(
        enrollmentProvider.loadUserEnrollments(
          userId: authProvider.currentUser!.userId,
          placeId: currentPlace.id,
        ),
      );

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
        body: _screens[_currentIndex],
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
