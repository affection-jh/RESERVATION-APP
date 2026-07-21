import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:reservation/utils/timezone_utils.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';
import '../models/place.dart';
import '../models/user.dart';
import '../models/course.dart';
import '../widgets/splash_screen.dart';
import '../screens/admin_screen.dart';
import 'place_waiting_screen.dart';
import '../main.dart' show MainScreen;
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/place_provider.dart';
import '../providers/story_provider.dart';
import '../providers/notification_provider.dart';
import '../providers/course_provider.dart';
import '../providers/reservation_summary_provider.dart';
import '../models/course_override.dart';
import '../utils/calendar_utils.dart';
import '../utils/session_slot_builder.dart';
import '../utils/local_storage_util.dart';

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
  /// [override]가 주어지면 그 시간만 보장 (PlaceSwitch 직후 즉시 전환용)
  Future<void> _ensureMinLoadingTime([Duration? override]) async {
    final duration = override ?? _minLoadingDuration;
    if (duration == Duration.zero) return;
    final elapsed = TimezoneUtils.getSeoulDateTime().difference(_startTime);
    if (elapsed < duration) {
      await Future.delayed(duration - elapsed);
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

      // requireManual이 true이고 lastEntryMode가 'admin'이면 유저 로그인 후 매니저 여부로 분기
      if (requireManual && firebaseUser != null && lastEntryMode == 'admin') {
        debugPrint(
          '[AppStartup._checkAutoLogin] requireManualEntrySelection=true && lastEntryMode=admin → 유저 로그인 후 매니저 여부 확인',
        );
        final userResult = await authService.checkUserAutoLogin();
        if (userResult != null) {
          final authProvider = Provider.of<AuthProvider>(
            context,
            listen: false,
          );
          authProvider.setCurrentUser(userResult.user);
          await authProvider.loadPlaceMembershipsForCurrentUser();
          authProvider.startWatchingPlaceMemberships();
          if (authProvider.isManagerMode) {
            debugPrint('[AppStartup._checkAutoLogin] 매니저 → 관리자 홈으로 이동');
            await _ensureMinLoadingTime();
            if (!mounted) return;
            final lastPlace = await authService.getLastAccessedPlaceId();
            await _prepareAdminScreenWithUser(userResult.user, lastPlace);
            return;
          }
        }
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

      AuthResult? userResult;
      userResult = await authService.checkUserAutoLogin();
      debugPrint(
        '[AppStartup._checkAutoLogin] 자동 로그인 결과: ${userResult != null ? "성공" : "실패"}',
      );

      if (!mounted) {
        debugPrint('[AppStartup._checkAutoLogin] 위젯이 마운트되지 않음');
        return;
      }

      if (userResult != null) {
        debugPrint('[AppStartup._checkAutoLogin] 자동 로그인 성공');
        final authProvider = Provider.of<AuthProvider>(context, listen: false);
        final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
        authProvider.setCurrentUser(userResult.user);
        await authProvider.loadPlaceMembershipsForCurrentUser();
        authProvider.startWatchingPlaceMemberships();

        // PlaceSwitch에서 전환한 경우, 이미 설정된 currentPlace를 우선 사용 (선택한 장소로 정확히 이동)
        // (가입 직후 플레이스 생성 시 서버 members 반영 전이라 placeIds에 없을 수 있음)
        var approvedIds = List<String>.from(userResult.placeIds);
        if (placeProvider.currentPlace != null) {
          final id = placeProvider.currentPlace!.id;
          if (!approvedIds.contains(id)) {
            approvedIds = [...approvedIds, id];
            debugPrint('[AppStartup] PlaceSwitch에서 설정된 플레이스 반영: $id');
          }
        }
        // PlaceSwitch에서 온 경우 선택한 플레이스 우선, 아니면 서버/로컬 마지막 접속
        final preferredPlaceId =
            placeProvider.currentPlace?.id ?? userResult.lastAccessedPlaceId;
        authProvider.setApprovedPlaceIds(approvedIds);

        // 접근 가능한 모든 플레이스를 PlaceProvider에 미리 로드 (PlaceSwitch 캐시 기반 동작용)
        final allPlaceIds = [
          ...approvedIds,
          ...authProvider.managedPlaceIdsFromMemberships,
        ].toSet().toList();
        if (allPlaceIds.isNotEmpty) {
          await placeProvider.loadPlaces(allPlaceIds);
        }

        await _ensureMinLoadingTime();
        if (!mounted) return;

        if (lastEntryMode == 'admin' && authProvider.isManagerMode) {
          // PlaceSwitch에서 선택한 플레이스 우선
          final lastPlace =
              placeProvider.currentPlace?.id ??
              await authService.getLastAccessedPlaceId();
          await _prepareAdminScreenWithUser(userResult.user, lastPlace);
          return;
        }

        final resultForUser = AuthResult(
          user: userResult.user,
          role: userResult.role,
          placeIds: approvedIds,
          lastAccessedPlaceId: preferredPlaceId,
        );
        final fromPlaceSwitch = placeProvider.currentPlace != null;
        if (fromPlaceSwitch) {
          await _ensureMinLoadingTime(Duration.zero);
        } else {
          await _ensureMinLoadingTime();
        }
        if (!mounted) return;
        await _prepareUserScreen(resultForUser, fromPlaceSwitch: fromPlaceSwitch);
        return;
      }

      // 2) 자동 로그인 실패 → 플레이스 브라우징 화면 (Apple App Store 가이드라인 준수)
      debugPrint('[AppStartup._checkAutoLogin] 자동 로그인 실패');
      // ✅ 로그인 없이도 플레이스 브라우징 가능하도록 PlaceWaitingScreen으로 이동
      // (계정 기반이 아닌 기능은 자유롭게 접근 가능해야 함)
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
          '[AppStartup._checkAutoLogin] Firebase 세션 없음 → PlaceWaitingScreen으로 이동 (플레이스 브라우징)',
        );
        // 로그인 없이도 플레이스 브라우징 가능
        setState(() {
          _targetScreen = const PlaceWaitingScreen(phoneNumber: '');
        });
        _hideSplash();
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
          // 로그인 없이도 플레이스 브라우징 가능
          setState(() {
            _targetScreen = const PlaceWaitingScreen(phoneNumber: '');
          });
          _hideSplash();
        }
      }
    }
  }

  /// 사용자 화면 준비
  /// [fromPlaceSwitch] true면 PlaceSwitch에서 일반 모드로 온 경우 — 스플래시 최소화로 바로 전환
  Future<void> _prepareUserScreen(AuthResult result, {bool fromPlaceSwitch = false}) async {
    debugPrint(
      '[AppStartup] _prepareUserScreen: hasApprovedPlaces=${result.hasApprovedPlaces}, lastAccessedPlaceId=${result.lastAccessedPlaceId}',
    );

    String? targetPlaceId = result.lastAccessedPlaceId;
    // ✅ 접근 가능 플레이스는 members 기준(placeIds) — 매니저도 같은 플레이스에 멤버면 멤버 뷰 진입 가능
    final isLastPlaceApproved =
        targetPlaceId != null && result.placeIds.contains(targetPlaceId);
    if (targetPlaceId != null) {
      debugPrint(
        '[AppStartup] _prepareUserScreen: 마지막 플레이스($targetPlaceId) 승인 여부(members 기준): $isLastPlaceApproved',
      );
    }

    // 마지막 접속 플레이스가 없거나 승인되지 않았으면
    // 승인된 플레이스 중 첫 번째를 사용
    if (targetPlaceId == null || !isLastPlaceApproved) {
      if (result.hasApprovedPlaces) {
        targetPlaceId = result.placeIds.first;
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

      // 연관된 모든 플레이스 로드 (병렬 처리)
      final allPlaceIds = result.placeIds.toSet();
      if (allPlaceIds.isNotEmpty) {
        await placeProvider.loadPlaces(allPlaceIds.toList());
      }

      // 현재 플레이스 정보 가져오기 (loadPlaces로 이미 로드된 경우 Firestore 재호출 생략)
      Place? place =
          allPlaceIds.contains(targetPlaceId)
              ? placeProvider.getPlace(targetPlaceId)
              : await firestoreService
                  .getPlace(targetPlaceId)
                  .timeout(const Duration(seconds: 6));
      if (place != null) {
        // 플레이스가 유효할 때만 설정 (삭제된 플레이스면 null → 아래에서 waiting으로 폴백)
        placeProvider.setCurrentPlace(place);
        // AuthService에 플레이스 설정 (마지막 접속 플레이스 저장)
        await authService.setCurrentPlace(place);

        final storyProvider = Provider.of<StoryProvider>(
          // ignore: use_build_context_synchronously
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
            .refreshUnreadBadge(userId, isAdmin: false, placeId: place.id)
            .catchError((e) {
              debugPrint('[AppStartup] 알림 배지 갱신 실패: $e');
            });

        try {
          await Future.wait([
            storyProvider.loadStories(place.id),
          ]).timeout(const Duration(seconds: 6));
        } catch (e) {
          debugPrint(
            '[AppStartup._prepareUserScreen] preload timeout/error: $e',
          );
        }

        // ✅ StoryCard의 CachedNetworkImage와 동일한 캐시 키로 프리캐시
        // 모든 스토리의 모든 이미지(일반 이미지 + 배경 이미지)를 프리캐시
        final imageUrls =
            <String>{
              for (final s in storyProvider.stories) ...s.imageUrls,
            }.where((u) => u.trim().isNotEmpty).toList();

        final backgroundImageUrls =
            <String>{
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
      debugPrint('[AppStartup._prepareUserScreen] 플레이스 로드 실패: $e');
    }

    // 최소 로딩 시간 보장 후 스플래시 숨김 (PlaceSwitch 직후는 즉시 전환)
    await _ensureMinLoadingTime(fromPlaceSwitch ? Duration.zero : null);
    if (!mounted) return;

    // 플레이스가 유효한지 확인 (삭제된 플레이스면 currentPlace가 null → waiting으로 폴백)
    final placeProviderForCheck = Provider.of<PlaceProvider>(
      context,
      listen: false,
    );
    if (placeProviderForCheck.currentPlace == null) {
      debugPrint(
        '[AppStartup._prepareUserScreen] 유효한 플레이스 없음 → PlaceWaitingScreen 폴백',
      );
      final firebasePhone =
          AuthService().currentFirebaseUser?.phoneNumber ?? '';
      setState(() {
        _targetScreen = PlaceWaitingScreen(phoneNumber: firebasePhone);
      });
      _hideSplash();
      return;
    }

    debugPrint(
      '[AppStartup] _prepareUserScreen: target=MainScreen (placeId=$targetPlaceId)',
    );
    setState(() {
      _targetScreen = const MainScreen();
    });
    _hideSplash();
  }

  /// 관리자 화면 준비 (User + PlaceMember 기반)
  Future<void> _prepareAdminScreenWithUser(
    User user,
    String? lastAccessedPlaceId,
  ) async {
    debugPrint(
      '[AppStartup] _prepareAdminScreenWithUser userId=${user.userId}',
    );
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final managedIds = authProvider.managedPlaceIdsFromMemberships;
    debugPrint(
      '[AppStartup] 관리 플레이스 IDs: $managedIds, 마지막 접속: $lastAccessedPlaceId',
    );

    // 플레이스 전환 시 "일반 멤버로 들어가기"도 보이도록 멤버 플레이스 ID 동기화
    authProvider.setApprovedPlaceIds(authProvider.placeIdsFromPlaceMemberships);

    await AuthService().clearRequireManualEntrySelection();

    if (managedIds.isEmpty) {
      debugPrint('[AppStartup] 관리 플레이스 없음 → PlaceWaitingScreen');
      if (mounted) {
        setState(() {
          _targetScreen = PlaceWaitingScreen(phoneNumber: user.phoneNumber);
        });
        _hideSplash();
      }
      return;
    }

    String? targetPlaceId = lastAccessedPlaceId;
    if (targetPlaceId != null && !managedIds.contains(targetPlaceId)) {
      targetPlaceId = managedIds.first;
    } else if (targetPlaceId == null) {
      targetPlaceId = managedIds.first;
    }

    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final notificationProvider = Provider.of<NotificationProvider>(
      context,
      listen: false,
    );
    notificationProvider
        .refreshUnreadBadge(user.userId, isAdmin: true)
        .catchError((e) {
      debugPrint('[AppStartup] 관리자 알림 배지 갱신 실패: $e');
        });

    try {
      // 캐시 우선 (앱 시작 시 이미 loadPlaces로 로드됨)
      Place? place = placeProvider.getPlace(targetPlaceId);
      if (place == null) {
        place = await FirestoreService().getPlace(targetPlaceId);
      }
      if (place != null && mounted) {
        placeProvider.setCurrentPlace(place);
        await AuthService().updateLastAccessedPlace(place.id);

        // 스플래시 동안 현재 지정 코스의 summary 선로딩 → 진입 시 N/M 이미 채워진 상태
        await _preloadReservationSummaryForAdmin(place.id);

        setState(() {
          _targetScreen = const AdminScreen();
        });
        _hideSplash();
        return;
      }
    } catch (e, stackTrace) {
      debugPrint('[AppStartup] 플레이스 로드 실패: $e $stackTrace');
    }

    if (mounted) {
      setState(() {
        _targetScreen = PlaceWaitingScreen(phoneNumber: user.phoneNumber);
      });
      _hideSplash();
    }
  }

  /// 관리자 진입 시 현재 지정 코스의 예약 요약 선로딩
  Future<void> _preloadReservationSummaryForAdmin(String placeId) async {
    if (!mounted) return;
    try {
      final courseProvider =
          Provider.of<CourseProvider>(context, listen: false);
      final summaryProvider =
          Provider.of<ReservationSummaryProvider>(context, listen: false);

      await courseProvider.loadCourses(placeId);
      final courses = courseProvider.courses;
      if (courses.isEmpty) return;

      Course course;
      final lastCourseId = await StorageService().getLastSelectedCourseId(
        placeId,
        scope: StorageService.scopeAdmin,
      );
      if (lastCourseId != null) {
        course = courses.firstWhere(
          (c) => c.id == lastCourseId,
          orElse: () => courses.first,
        );
      } else {
        course = courses.first;
      }

      final now = TimezoneUtils.getSeoulDateTime();
      final offsets = [0, 1, 2];
      final firstWeekStart = CalendarUtils.weekStartFrom(now, 0);
      final lastWeekStart = CalendarUtils.weekStartFrom(now, 2);
      final startDate = DateTime(
        firstWeekStart.year,
        firstWeekStart.month,
        firstWeekStart.day,
      );
      final endDate = lastWeekStart.add(const Duration(days: 6));
      final firstWeekStartStr = CalendarUtils.formatDateYMD(firstWeekStart);

      summaryProvider.setContext(
        placeId: placeId,
        courseId: course.id,
        startDate: startDate,
        endDate: endDate,
        weekStartDate: firstWeekStartStr,
      );

      final weekStartDates = offsets
          .map((o) => CalendarUtils.formatDateYMD(CalendarUtils.weekStartFrom(now, o)))
          .toList();
      courseProvider.subscribeToOverrides(placeId, weekStartDates);

      for (var i = 0; i < offsets.length; i++) {
        final ws = CalendarUtils.weekStartFrom(now, offsets[i]);
        final weekStartDate = weekStartDates[i];
        final startDateWs = DateTime(ws.year, ws.month, ws.day);
        final overridesForCourse = courseProvider
            .getOverridesForWeek(weekStartDate)
            .where((o) => o.courseId == course.id)
            .toList();
        summaryProvider.updateOverridesForWeek(weekStartDate, overridesForCourse);
        final byDate = <String, List<CourseOverride>>{};
        for (final o in overridesForCourse) {
          byDate.putIfAbsent(o.date, () => <CourseOverride>[]).add(o);
        }
        final slots = SessionSlotBuilder.buildSlotsForWeek(
          placeId: placeId,
          course: course,
          startDate: startDateWs,
          overridesByDate: byDate,
          getCapacityOverride: summaryProvider.getCapacityOverride,
        );
        summaryProvider.updateSessionSlots(weekStartDate, slots);
      }
    } catch (e) {
      debugPrint('[AppStartup] ReservationSummary 선로딩 실패: $e');
    }
  }

  /// 스플래시 숨기기 (페이드 아웃)
  /// 로딩 완료 후 UI 안정화 시간 대기 후 페이드아웃
  void _hideSplash() async {
    if (!mounted) return;
    // UI 안정화 시간 대기
    await Future.delayed(const Duration(milliseconds: 200));
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
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          child: IgnorePointer(
            ignoring: !_showSplash,
            child: const SplashScreen(),
          ),
        ),
      ],
    );
  }
}
