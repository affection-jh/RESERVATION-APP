import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:reservation/utils/timezone_utils.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';
import '../models/user.dart';
import '../widgets/splash_screen.dart';
import 'phone_number_input_screen.dart';
import '../screens/admin_screen.dart';
import 'place_waiting_screen.dart';
import '../main.dart' show MainScreen;
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/place_provider.dart';
import '../providers/story_provider.dart';
import '../providers/promotion_provider.dart';
import '../providers/notification_provider.dart';

/// 앱 시작 화면
///
/// 자동 로그인 체크 및 적절한 화면으로 라우팅
class AppStartupScreen extends StatefulWidget {
  const AppStartupScreen({super.key});

  @override
  State<AppStartupScreen> createState() => _AppStartupScreenState();
}

class _AppStartupScreenState extends State<AppStartupScreen> {
  bool _showSplash = true;
  Widget? _targetScreen; // 로딩 완료 후 표시할 화면
  DateTime _startTime = TimezoneUtils.getSeoulDateTime();
  static const Duration _minLoadingDuration = Duration(milliseconds: 2000);

  @override
  void initState() {
    super.initState();
    _startTime = TimezoneUtils.getSeoulDateTime();
    // ⚠️ 중요: Provider들이 아직 첫 build 중일 때 notifyListeners()가 발생하면
    // "setState() or markNeedsBuild() called during build" 어설션이 터질 수 있음.
    // 자동 로그인/데이터 로드는 첫 프레임 이후로 미룬다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _checkAutoLogin();
    });
  }

  /// 최소 로딩 시간을 보장한 후 네비게이션 허용
  Future<void> _ensureMinLoadingTime() async {
    final elapsed = TimezoneUtils.getSeoulDateTime().difference(_startTime);
    if (elapsed < _minLoadingDuration) {
      await Future.delayed(_minLoadingDuration - elapsed);
    }
  }

  Future<void> _checkAutoLogin() async {
    debugPrint('[AppStartup._checkAutoLogin] 자동 로그인 확인 시작');
    try {
      final authService = AuthService();

      // ✅ 자동 로그인 시 "마지막 접속 모드 + 플레이스"로 복원한다.
      // - lastEntryMode == 'admin'  → 관리자 자동로그인 먼저 시도
      // - lastEntryMode == 'member' → 일반(멤버) 자동로그인 먼저 시도
      final lastEntryMode = await authService.getLastEntryMode();
      debugPrint('[AppStartup._checkAutoLogin] lastEntryMode=$lastEntryMode');

      // ✅ 전화번호 인증 직후(명시적 재로그인)는 자동 분기 금지:
      // 단, lastEntryMode가 'admin'이고 관리자 자동 로그인이 성공하면 관리자 홈으로 이동
      final requireManual = await authService.requiresManualEntrySelection();
      final firebaseUser = authService.currentFirebaseUser;

      // requireManual이 true이고 lastEntryMode가 'admin'이면 관리자 자동 로그인 먼저 시도
      if (requireManual && firebaseUser != null && lastEntryMode == 'admin') {
        debugPrint(
          '[AppStartup._checkAutoLogin] requireManualEntrySelection=true && lastEntryMode=admin → 관리자 자동 로그인 시도',
        );
        final adminResult = await authService.checkAdminAutoLogin();
        if (adminResult != null) {
          debugPrint('[AppStartup._checkAutoLogin] 관리자 자동 로그인 성공 → 관리자 홈으로 이동');
          await _ensureMinLoadingTime();
          if (!mounted) return;
          await _prepareAdminScreen(adminResult);
          return;
        } else {
          debugPrint(
            '[AppStartup._checkAutoLogin] 관리자 자동 로그인 실패 → PlaceWaitingScreen으로 이동',
          );
          await _ensureMinLoadingTime();
          if (!mounted) return;
          setState(() {
            _targetScreen = PlaceWaitingScreen(
              phoneNumber: firebaseUser.phoneNumber ?? '',
            );
          });
          _hideSplash();
          return;
        }
      }

      // requireManual이 true이고 lastEntryMode가 'admin'이 아니면 PlaceWaitingScreen으로 이동
      if (requireManual && firebaseUser != null) {
        debugPrint(
          '[AppStartup._checkAutoLogin] requireManualEntrySelection=true → PlaceWaitingScreen으로 고정',
        );
        await _ensureMinLoadingTime();
        if (!mounted) return;
        setState(() {
          _targetScreen = PlaceWaitingScreen(
            phoneNumber: firebaseUser.phoneNumber ?? '',
          );
        });
        _hideSplash();
        return;
      }

      AdminAutoLoginResult? adminResult;
      AuthResult? userResult;

      Future<AdminAutoLoginResult?> tryAdmin() async {
        debugPrint('[AppStartup._checkAutoLogin] 관리자 자동 로그인 확인 시작');
        final r = await authService.checkAdminAutoLogin();
        debugPrint(
          '[AppStartup._checkAutoLogin] 관리자 자동 로그인 결과: ${r != null ? "성공" : "실패"}',
        );
        return r;
      }

      Future<AuthResult?> tryUser() async {
        debugPrint('[AppStartup._checkAutoLogin] 일반 사용자 자동 로그인 확인 시작');
        // 관리자도 일반 사용자로 로그인 가능 (다른 플레이스의 멤버가 될 수 있음)
        final r = await authService.checkUserAutoLogin();
        debugPrint(
          '[AppStartup._checkAutoLogin] 일반 사용자 자동 로그인 결과: ${r != null ? "성공" : "실패"}',
        );
        return r;
      }

      // 1) lastEntryMode 우선 시도
      if (lastEntryMode == 'admin') {
        adminResult = await tryAdmin();
        if (adminResult == null) {
          userResult = await tryUser();
        }
      } else if (lastEntryMode == 'member') {
        userResult = await tryUser();
        if (userResult == null) {
          adminResult = await tryAdmin();
        }
      } else {
        // lastEntryMode가 없으면 일반 사용자 → 관리자 순으로 시도 (관리자 우선 판단 제거)
        userResult = await tryUser();
        if (userResult == null) {
          adminResult = await tryAdmin();
        }
      }

      if (!mounted) {
        debugPrint('[AppStartup._checkAutoLogin] 위젯이 마운트되지 않음');
        return;
      }

      if (adminResult != null) {
        debugPrint('[AppStartup._checkAutoLogin] 관리자 자동 로그인 성공, 관리자 화면 준비');
        await _ensureMinLoadingTime();
        if (!mounted) return;
        await _prepareAdminScreen(adminResult);
        return;
      }

      if (userResult != null) {
        // 일반 사용자 자동 로그인 성공 (관리자 포함)
        debugPrint('[AppStartup._checkAutoLogin] 일반 사용자 자동 로그인 성공');
        // AuthProvider에 사용자 정보 설정
        final authProvider = Provider.of<AuthProvider>(context, listen: false);
        // ✅ 유저(멤버) 플로우로 들어올 때는 항상 "현재 관리자 모드"를 해제한다.
        // linkedAdmin은 유지되므로, 필요 시 PlaceSwitchWidget에서 다시 관리자 모드로 전환 가능.
        authProvider.clearCurrentAdmin();

        // ✅ "관리자 플레이스(관리)" + "멤버 플레이스(승인)"를 스플래시에서 한 번만 로드한다.
        // - 관리자인 동시에 멤버인 경우도 있으므로, 관리자 정보를 currentAdmin으로 바로 전환하지 않는다.
        // - PlaceSwitchWidget에서 멤버/관리자 모드를 독립적으로 토글할 수 있도록 linkedAdmin + adminManagedPlaceIds로 보관한다.

        // 관리자인 경우(역할이 admin으로 판정된 경우)도 linkedAdmin으로 보관
        if (userResult.role == UserRole.admin) {
          debugPrint('[AppStartup._checkAutoLogin] 관리자 역할 감지, 관리자 정보 조회');
          final admin = await authService.findAdminByPhone(
            userResult.user.phoneNumber,
          );
          if (admin != null) {
            debugPrint(
              '[AppStartup._checkAutoLogin] 관리자 정보 설정: ${admin.userId}',
            );
            authProvider.setLinkedAdmin(admin);
            try {
              final managedIds = await FirestoreService()
                  .getManagedPlaceIdsByAdminId(admin.userId);
              debugPrint('[AppStartup] 관리자 관리 플레이스 ID 목록: $managedIds');
              authProvider.setAdminManagedPlaceIds(managedIds);

              // ✅ 관리자이지만 "멤버십(승인/대기)"가 0개인 경우:
              // 기존 유저 플로우(_prepareUserScreen)는 PlaceWaiting으로 떨어지므로,
              // 관리자 자동 로그인 플로우로 전환해서 관리자 홈으로 보낸다.
              final hasAnyMembership =
                  userResult.approvedMemberships.isNotEmpty ||
                  userResult.pendingMemberships.isNotEmpty;
              if (!hasAnyMembership && managedIds.isNotEmpty) {
                // ✅ lastEntryMode 최우선:
                // - 마지막이 member였다면 다음도 member로 유지 (강제 admin 전환 금지)
                // - 마지막이 admin이었거나 기록이 없으면, 기존 동작대로 admin 홈으로 전환 허용
                final shouldForceAdmin =
                    lastEntryMode == null || lastEntryMode == 'admin';
                if (!shouldForceAdmin) {
                  debugPrint(
                    '[AppStartup._checkAutoLogin] lastEntryMode=member → 관리자 플로우 자동 전환 스킵 (유저 플로우 유지)',
                  );
                } else {
                  debugPrint(
                    '[AppStartup._checkAutoLogin] 관리자(멤버십 0) + 관리 플레이스 존재 → 관리자 플로우로 전환',
                  );
                  final adminResult = await authService.checkAdminAutoLogin();
                  if (adminResult != null) {
                    await _ensureMinLoadingTime();
                    if (!mounted) return;
                    await _prepareAdminScreen(adminResult);
                    return;
                  }
                  debugPrint(
                    '[AppStartup._checkAutoLogin] 관리자 플로우 전환 실패 → 유저 플로우 계속',
                  );
                }
              }
            } catch (e) {
              debugPrint('[AppStartup] 관리자 관리 플레이스 로드 실패: $e');
              authProvider.setAdminManagedPlaceIds([]);
            }
          } else {
            debugPrint('[AppStartup._checkAutoLogin] 관리자 정보를 찾을 수 없음');
            authProvider.setLinkedAdmin(null);
            authProvider.setAdminManagedPlaceIds([]);
          }
        } else {
          // 일반 사용자인 경우, 같은 전화번호로 관리자 계정이 있는지 확인
          debugPrint('[AppStartup._checkAutoLogin] 일반 사용자 - 연결된 관리자 계정 확인');
          try {
            final linkedAdmin = await authService.findAdminByPhone(
              userResult.user.phoneNumber,
            );
            if (linkedAdmin != null) {
              debugPrint(
                '[AppStartup._checkAutoLogin] 연결된 관리자 계정 발견: ${linkedAdmin.userId}',
              );
              authProvider.setLinkedAdmin(linkedAdmin);
              try {
                final managedIds = await FirestoreService()
                    .getManagedPlaceIdsByAdminId(linkedAdmin.userId);
                debugPrint('[AppStartup] 관리자 관리 플레이스 ID 목록: $managedIds');
                authProvider.setAdminManagedPlaceIds(managedIds);
              } catch (e) {
                debugPrint('[AppStartup] 관리자 관리 플레이스 로드 실패: $e');
                authProvider.setAdminManagedPlaceIds([]);
              }
            } else {
              debugPrint('[AppStartup._checkAutoLogin] 연결된 관리자 계정 없음');
              authProvider.setLinkedAdmin(null);
              authProvider.setAdminManagedPlaceIds([]);
            }
          } catch (e) {
            debugPrint('[AppStartup._checkAutoLogin] 연결된 관리자 계정 확인 실패: $e');
            authProvider.setLinkedAdmin(null);
            authProvider.setAdminManagedPlaceIds([]);
          }
        }

        authProvider.setCurrentUser(userResult.user);

        // 승인된 플레이스 ID 목록 설정 (스플래시에서 한 번만)
        // approvedMemberships + pendingMemberships 모두 포함
        final allMemberPlaceIds = <String>{
          ...userResult.approvedMemberships.map((m) => m.placeId),
          ...userResult.pendingMemberships.map((m) => m.placeId),
        }.toList();
        debugPrint(
          '[AppStartup] 승인된 플레이스 멤버십 개수: ${userResult.approvedMemberships.length}',
        );
        debugPrint(
          '[AppStartup] 대기 중인 플레이스 멤버십 개수: ${userResult.pendingMemberships.length}',
        );
        debugPrint('[AppStartup] 전체 플레이스 ID 목록 (승인+대기): $allMemberPlaceIds');
        authProvider.setApprovedPlaceIds(allMemberPlaceIds);

        // FCM 초기화 (자동 로그인 시) - context가 준비된 후에 처리
        // MainScreen이 빌드된 후에 FCM을 초기화하도록 변경

        // _prepareUserScreen 내부에서 (승인 플레이스 존재 시) 최소 로딩 시간 보장 후 화면 전환함
        if (!mounted) return;
        await _prepareUserScreen(userResult);
        return;
      }

      // 2) 자동 로그인 실패 → 전화번호 입력 화면
      debugPrint('[AppStartup._checkAutoLogin] 자동 로그인 실패');
      // ✅ Firebase Auth 세션이 살아있으면 phone input으로 보내지 말고 Waiting으로 보낸다.
      // (Firestore/네트워크 이슈로 사용자 조회가 실패해도 "로그인 화면으로 튀는" UX를 방지)
      final firebaseUser2 = authService.currentFirebaseUser;
      await _ensureMinLoadingTime();
      if (!mounted) return;
      if (firebaseUser2 != null) {
        debugPrint(
          '[AppStartup._checkAutoLogin] Firebase 세션 존재 → PlaceWaitingScreen으로 폴백',
        );
        setState(() {
          _targetScreen = PlaceWaitingScreen(
            phoneNumber: firebaseUser2.phoneNumber ?? '',
          );
        });
        _hideSplash();
      } else {
        debugPrint(
          '[AppStartup._checkAutoLogin] Firebase 세션 없음 → PhoneNumberInputScreen으로 이동',
        );
        _preparePhoneInputScreen();
      }
    } catch (e, stackTrace) {
      debugPrint('[AppStartup._checkAutoLogin] ❌ 에러 발생: $e');
      debugPrint('[AppStartup._checkAutoLogin] 스택 트레이스: $stackTrace');
      if (mounted) {
        // 인증 세션이 살아있는데도 phone input으로 튀는 걸 방지:
        // (데이터 로드/플러그인 이슈 등 "인증 외 예외"는 세션을 깨면 안 됨)
        final authService = AuthService();
        final firebaseUser = authService.currentFirebaseUser;
        await _ensureMinLoadingTime();
        if (!mounted) return;
        if (firebaseUser != null) {
          setState(() {
            _targetScreen = PlaceWaitingScreen(
              phoneNumber: firebaseUser.phoneNumber ?? '',
            );
          });
          _hideSplash();
        } else {
          _preparePhoneInputScreen();
        }
      }
    }
  }

  /// 전화번호 입력 화면 준비
  void _preparePhoneInputScreen() {
    debugPrint('[AppStartup] _preparePhoneInputScreen');
    setState(() {
      _targetScreen = const PhoneNumberInputScreen();
    });
    _hideSplash();
  }

  /// 사용자 화면 준비
  Future<void> _prepareUserScreen(AuthResult result) async {
    debugPrint(
      '[AppStartup] _prepareUserScreen: hasApprovedPlaces=${result.hasApprovedPlaces}, lastAccessedPlaceId=${result.lastAccessedPlaceId}',
    );

    String? targetPlaceId = result.lastAccessedPlaceId;
    bool isLastPlaceApproved = false;

    // ✅ 마지막 접속 플레이스가 있으면, Firestore에서 실제 승인 여부 확인
    if (targetPlaceId != null) {
      try {
        final firestoreService = FirestoreService();
        final firestore = firestoreService.firestore;

        // placeMemberships 컬렉션에서 userId와 placeId로 멤버십 확인 (status 제거로 모든 멤버십이 승인된 것으로 처리)
        final membershipQuery = await firestore
            .collection('placeMemberships')
            .where('userId', isEqualTo: result.user.userId)
            .where('placeId', isEqualTo: targetPlaceId)
            .limit(1)
            .get();

        isLastPlaceApproved = membershipQuery.docs.isNotEmpty;
        debugPrint(
          '[AppStartup] _prepareUserScreen: 마지막 플레이스($targetPlaceId) 승인 여부 확인: $isLastPlaceApproved',
        );
      } catch (e) {
        debugPrint('[AppStartup] _prepareUserScreen: 멤버십 확인 실패: $e');
        // 확인 실패 시 approvedMemberships에서 확인 (폴백)
        isLastPlaceApproved = result.approvedMemberships.any(
          (m) => m.placeId == targetPlaceId,
        );
      }
    }

    // 마지막 접속 플레이스가 없거나 승인되지 않았으면
    // 승인된 플레이스 중 첫 번째를 사용
    if (targetPlaceId == null || !isLastPlaceApproved) {
      if (result.hasApprovedPlaces) {
        targetPlaceId = result.approvedMemberships.first.placeId;
        debugPrint(
          '[AppStartup] _prepareUserScreen: 마지막 플레이스 사용 불가 → 첫 번째 승인된 플레이스 사용: $targetPlaceId',
        );
      } else {
        // 승인된 플레이스도 없고 마지막 접속 플레이스도 없으면 대기 화면으로
        debugPrint(
          '[AppStartup] _prepareUserScreen: 승인된 플레이스 없음 → PlaceWaitingScreen',
        );
        final firebasePhone =
            AuthService().currentFirebaseUser?.phoneNumber ?? '';
        setState(() {
          _targetScreen = PlaceWaitingScreen(phoneNumber: firebasePhone);
        });
        _hideSplash();
        return;
      }
    } else {
      debugPrint(
        '[AppStartup] _prepareUserScreen: 마지막 플레이스($targetPlaceId) 승인됨 → 사용',
      );
    }

    // 플레이스 로드 및 설정
    try {
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final authService = AuthService();
      final firestoreService = FirestoreService();

      // 플레이스 정보 가져오기
      final place = await firestoreService
          .getPlace(targetPlaceId)
          .timeout(const Duration(seconds: 6));
      if (place != null) {
        // PlaceProvider에 플레이스 설정
        placeProvider.setCurrentPlace(place);
        // AuthService에 플레이스 설정 (마지막 접속 플레이스 저장)
        await authService.setCurrentPlace(place);

        final storyProvider = Provider.of<StoryProvider>(
          context,
          listen: false,
        );
        final promotionProvider = Provider.of<PromotionProvider>(
          context,
          listen: false,
        );
        final notificationProvider = Provider.of<NotificationProvider>(
          context,
          listen: false,
        );

        // ✅ 스플래시 동안 "첫 홈 화면" 체감에 중요한 데이터만 선로딩
        // (courses/reservations/enrollments는 MainScreen에서 post-frame으로 로드)
        // 알림은 비동기로 로드 (블로킹하지 않음)
        final userId = result.user.userId;
        notificationProvider
            .loadNotifications(userId, isAdmin: false)
            .catchError((e) {
              debugPrint('[AppStartup] 알림 로드 실패: $e');
            });

        try {
          await Future.wait([
            storyProvider.loadStories(place.id),
            promotionProvider.loadPromotions(place.id),
          ]).timeout(const Duration(seconds: 6));
        } catch (e) {
          debugPrint(
            '[AppStartup._prepareUserScreen] preload timeout/error: $e',
          );
        }

        // ✅ StoryCard의 CachedNetworkImage와 동일한 캐시 키로 프리캐시
        // 모든 스토리의 모든 이미지(일반 이미지 + 배경 이미지)를 프리캐시
        final imageUrls = <String>{
          for (final s in storyProvider.stories) ...s.imageUrls,
        }.where((u) => u.trim().isNotEmpty).toList();

        final backgroundImageUrls = <String>{
          for (final s in storyProvider.stories)
            if (s.backgroundImageUrl != null &&
                s.backgroundImageUrl!.isNotEmpty)
              s.backgroundImageUrl!,
        }.where((u) => u.trim().isNotEmpty).toList();

        final allUrls = [...imageUrls, ...backgroundImageUrls];

        if (allUrls.isNotEmpty) {
          await Future.any([
            Future.wait(
              allUrls.map((u) async {
                try {
                  // ✅ CachedNetworkImageProvider를 사용하여 캐시 키 일치
                  // StoryCard의 cacheKey와 동일하게 URL을 캐시 키로 사용
                  await precacheImage(CachedNetworkImageProvider(u), context);
                } catch (_) {
                  // ignore
                }
              }),
            ),
            Future.delayed(const Duration(seconds: 3)), // 3초 타임아웃
          ]);
        }
      }
    } catch (e) {
      // 플레이스 로드 실패 시 그냥 진행 (메인 화면에서 처리)
      debugPrint('[AppStartup._prepareUserScreen] 플레이스 로드 실패: $e');
    }

    // 최소 로딩 시간 보장 후 스플래시 숨김
    await _ensureMinLoadingTime();
    if (!mounted) return;

    debugPrint(
      '[AppStartup] _prepareUserScreen: target=MainScreen (placeId=$targetPlaceId)',
    );
    setState(() {
      _targetScreen = const MainScreen();
    });
    _hideSplash();
  }

  /// 관리자 화면 준비
  Future<void> _prepareAdminScreen(AdminAutoLoginResult result) async {
    debugPrint('[AppStartup] _prepareAdminScreen');
    debugPrint('[AppStartup._navigateToAdminScreen] 시작');
    debugPrint(
      '[AppStartup._navigateToAdminScreen] 관리자 ID: ${result.admin.userId}',
    );
    debugPrint(
      '[AppStartup._navigateToAdminScreen] 플레이스 IDs: ${result.admin.placeIds}',
    );
    debugPrint(
      '[AppStartup._navigateToAdminScreen] 마지막 접속 플레이스: ${result.lastAccessedPlaceId}',
    );

    // AuthProvider에 관리자 정보 설정
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    authProvider.setCurrentAdmin(result.admin);
    debugPrint(
      '[AppStartup._navigateToAdminScreen] AuthProvider에 관리자 정보 설정 완료',
    );

    // ✅ 관리자 자동 로그인 경로에서도 "멤버 전환"을 위해 currentUser/linkedAdmin을 준비한다.
    // - PlaceSwitchWidget에서 멤버 모드 전환 시 currentUser가 필요함
    // - Firestore에 users 문서가 없을 수도 있으므로, 없으면 최소 user 모델로 폴백
    authProvider.setLinkedAdmin(result.admin);
    try {
      final authService = AuthService();
      final user =
          await authService.findUserByPhone(result.admin.phoneNumber) ??
          User(
            userId: result.admin.userId,
            name: result.admin.name,
            phoneNumber: result.admin.phoneNumber,
            createdAt: TimezoneUtils.getSeoulDateTime(),
            updatedAt: TimezoneUtils.getSeoulDateTime(),
          );
      authProvider.setCurrentUser(user);
    } catch (e) {
      // users 조회 실패해도 관리자 화면 진입은 막지 않는다.
      authProvider.setCurrentUser(
        User(
          userId: result.admin.userId,
          name: result.admin.name,
          phoneNumber: result.admin.phoneNumber,
          createdAt: TimezoneUtils.getSeoulDateTime(),
          updatedAt: TimezoneUtils.getSeoulDateTime(),
        ),
      );
    }

    // ✅ PlaceSwitchWidget에서 사용하는 "관리 플레이스/승인 플레이스" 캐시도 함께 세팅
    // - 관리자 자동 로그인 경로에서는 _checkAutoLogin(userResult) 분기가 아니어서
    //   adminManagedPlaceIds/approvedPlaceIds가 비어 있을 수 있다.
    // - 관리 플레이스는 AdminUser.placeIds를 우선 사용한다.
    authProvider.setAdminManagedPlaceIds(result.admin.placeIds);
    // - 멤버 플레이스는 placeMemberships에서 조회 (approved + pending)
    try {
      final firestore = FirestoreService().firestore;
      // ✅ whereIn은 복합 인덱스 요구/제약으로 인해 예기치 않게 실패하거나 비는 케이스가 있어,
      // 먼저 userId로만 가져온 뒤 status는 클라이언트에서 필터링한다.
      final snap = await firestore
          .collection('placeMemberships')
          .where('userId', isEqualTo: result.admin.userId)
          .get();

      final memberPlaceIds = <String>{};
      // status 제거로 모든 멤버십이 승인된 것으로 처리
      for (final d in snap.docs) {
        final data = d.data();
        final placeId = (data['placeId'] as String?) ?? '';
        if (placeId.trim().isNotEmpty) memberPlaceIds.add(placeId);
      }

      debugPrint(
        '[AppStartup] 관리자 경로 placeMemberships docs=${snap.docs.length}, memberPlaceIds=${memberPlaceIds.toList()}',
      );
      authProvider.setApprovedPlaceIds(memberPlaceIds.toList());
    } catch (e) {
      debugPrint('[AppStartup] 관리자 경로 멤버 플레이스 로드 실패: $e');
      authProvider.setApprovedPlaceIds([]);
    }

    // 관리자 자동 로그인 성공 → requireManualEntrySelection 플래그 클리어
    final authService = AuthService();
    await authService.clearRequireManualEntrySelection();
    debugPrint(
      '[AppStartup._navigateToAdminScreen] requireManualEntrySelection 플래그 클리어 완료',
    );

    // 플레이스가 없으면 waiting screen으로 이동 (플레이스 등록은 수동으로 진행)
    if (result.admin.placeIds.isEmpty) {
      debugPrint(
        '[AppStartup._navigateToAdminScreen] 플레이스가 없어서 waiting screen으로 이동',
      );
      setState(() {
        _targetScreen = PlaceWaitingScreen(
          phoneNumber: result.admin.phoneNumber,
        );
      });
      _hideSplash();
      return;
    }

    // 마지막 접속 플레이스 확인
    String? targetPlaceId = result.lastAccessedPlaceId;

    // 마지막 접속 플레이스가 관리자의 플레이스 목록에 있는지 확인
    if (targetPlaceId != null) {
      final isValidPlace = result.admin.placeIds.contains(targetPlaceId);
      if (!isValidPlace) {
        // 마지막 접속 플레이스가 유효하지 않으면 첫 번째 플레이스 사용
        targetPlaceId = result.admin.placeIds.first;
        debugPrint(
          '[AppStartup._navigateToAdminScreen] 마지막 접속 플레이스가 유효하지 않아 첫 번째 플레이스 사용: $targetPlaceId',
        );
      } else {
        debugPrint(
          '[AppStartup._navigateToAdminScreen] 마지막 접속 플레이스 사용: $targetPlaceId',
        );
      }
    } else {
      // 마지막 접속 플레이스가 없으면 첫 번째 플레이스 사용
      targetPlaceId = result.admin.placeIds.first;
      debugPrint(
        '[AppStartup._navigateToAdminScreen] 마지막 접속 플레이스가 없어서 첫 번째 플레이스 사용: $targetPlaceId',
      );
    }

    // 플레이스 로드 및 설정
    try {
      debugPrint(
        '[AppStartup._navigateToAdminScreen] 플레이스 로드 시작: $targetPlaceId',
      );
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final authService = AuthService();
      final firestoreService = FirestoreService();
      final notificationProvider = Provider.of<NotificationProvider>(
        context,
        listen: false,
      );

      // 알림 비동기 로드 (블로킹하지 않음)
      final adminUserId = result.admin.userId;
      notificationProvider
          .loadNotifications(adminUserId, isAdmin: true)
          .catchError((e) {
            debugPrint('[AppStartup] 관리자 알림 로드 실패: $e');
          });

      // 플레이스 정보 가져오기
      debugPrint(
        '[AppStartup._navigateToAdminScreen] firestoreService.getPlace 호출 전',
      );
      final place = await firestoreService.getPlace(targetPlaceId);
      debugPrint(
        '[AppStartup._navigateToAdminScreen] firestoreService.getPlace 호출 후, place: ${place != null ? "존재" : "null"}',
      );

      if (place != null) {
        debugPrint(
          '[AppStartup._navigateToAdminScreen] 플레이스 로드 성공: ${place.name}',
        );
        // PlaceProvider에 플레이스 설정
        placeProvider.setCurrentPlace(place);
        debugPrint(
          '[AppStartup._navigateToAdminScreen] PlaceProvider에 플레이스 설정 완료',
        );
        // AuthService에 플레이스 설정 (마지막 접속 플레이스 저장)
        await authService.updateLastAccessedPlace(place.id);
        debugPrint(
          '[AppStartup._navigateToAdminScreen] AuthService에 마지막 접속 플레이스 저장 완료',
        );
      } else {
        // 플레이스를 찾을 수 없는 경우 로그 출력
        debugPrint(
          '[AppStartup._navigateToAdminScreen] ⚠️ 플레이스를 찾을 수 없습니다: $targetPlaceId',
        );
      }
    } catch (e, stackTrace) {
      // 플레이스 로드 실패 시 에러 로그 출력
      debugPrint('[AppStartup._navigateToAdminScreen] ❌ 플레이스 로드 실패: $e');
      debugPrint('[AppStartup._navigateToAdminScreen] 스택 트레이스: $stackTrace');
      // 에러가 발생해도 관리자 홈으로 이동 (AdminScreen에서 처리)
    }

    debugPrint('[AppStartup._navigateToAdminScreen] 관리자 홈으로 이동');
    setState(() {
      _targetScreen = const AdminScreen();
    });
    _hideSplash();
  }

  /// 스플래시 숨기기 (페이드 아웃)
  void _hideSplash() {
    if (!mounted) return;
    setState(() {
      _showSplash = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 실제 화면을 먼저 렌더링하고, 그 위에 스플래시를 오버레이
    // 스플래시가 사라지면 이미 렌더링된 화면이 자연스럽게 보임
    return Stack(
      children: [
        // 실제 화면 (스플래시 아래에서 미리 렌더링)
        // IndexedStack이 이미 그려지고 있어야 하므로, 화면을 미리 생성
        if (_targetScreen != null) Positioned.fill(child: _targetScreen!),
        // 스플래시 오버레이 (페이드 아웃만, 네비게이션 없음)
        AnimatedOpacity(
          opacity: _showSplash ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 300),
          child: IgnorePointer(
            ignoring: !_showSplash,
            child: const SplashScreen(),
          ),
        ),
      ],
    );
  }
}
