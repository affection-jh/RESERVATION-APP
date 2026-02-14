import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_colors.dart';
import '../widgets/compact_calendar_widget.dart';
import '../models/course.dart';
import '../models/reservation.dart';
import '../models/course_enrollment.dart';
import '../widgets/user_reservation_manage_bottom_sheet.dart';
import '../widgets/enrollment_detail_bottom_sheet.dart';
import '../widgets/place_switch_widget.dart';
import '../widgets/profile_settings_widget.dart'
    show UserProfileInfoSection, SettingsItemsBuilder;
import '../widgets/notification_settings_dialog.dart';
import '../widgets/name_edit_bottom_sheet.dart';
import '../providers/reservation_provider.dart';
import '../providers/course_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/place_provider.dart';

import '../providers/enrollment_provider.dart';
import '../utils/snackbar_util.dart';
import '../widgets/cached_image_widget.dart';
import '../widgets/week_tab_bar.dart';
import '../utils/timezone_utils.dart';
import 'package:cloud_functions/cloud_functions.dart';

class MyPageScreen extends StatefulWidget {
  final Map<String, dynamic>? highlightReservation; // 강조할 예약 정보

  const MyPageScreen({super.key, this.highlightReservation});

  @override
  State<MyPageScreen> createState() => _MyPageScreenState();
}

class _MyPageScreenState extends State<MyPageScreen> {
  bool _shouldHighlightReservation = false;
  Reservation? _highlightedReservation;
  Course? _highlightedCourse;
  CourseSession? _highlightedSession;
  DateTime? _highlightedDate;
  int _selectedWeekTab = 0;

  List<int> _computeAvailableWeekOffsets(
    List<Reservation> reservations, {
    DateTime? extraDateToInclude,
  }) {
    // 현재 주차는 항상 포함 (예약이 없어도)
    final Set<int> weekOffsets = {0};

    final now = TimezoneUtils.getSeoulDateTime();
    final thisWeekMonday = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: now.weekday - DateTime.monday));

    // highlightReservation 등으로 전달된 날짜의 주차도 포함 (예: 취소 알림으로 해당 주차 표시)
    if (extraDateToInclude != null) {
      final d = DateTime(
        extraDateToInclude.year,
        extraDateToInclude.month,
        extraDateToInclude.day,
      );
      final diffDays = d.difference(thisWeekMonday).inDays;
      final w = (diffDays / 7).floor();
      if (w >= 0) weekOffsets.add(w);
    }

    if (reservations.isEmpty) {
      return weekOffsets.toList()..sort();
    }

    // 예약이 있는 주차 추출
    int maxWeekOffset = 0;
    for (final r in reservations) {
      final d = DateTime(
        r.reservedDate.year,
        r.reservedDate.month,
        r.reservedDate.day,
      );
      final diffDays = d.difference(thisWeekMonday).inDays;
      final w = (diffDays / 7).floor();
      if (w >= 0) {
        // 현재 주차 이후의 예약만 포함
        weekOffsets.add(w);
        if (w > maxWeekOffset) {
          maxWeekOffset = w;
        }
      }
    }

    // 현재 주차부터 가장 먼 예약 주차까지 모든 주차 포함
    // 예: 예약이 3주 후에만 있으면 [0, 1, 2, 3] 모두 포함
    for (int i = 0; i <= maxWeekOffset; i++) {
      weekOffsets.add(i);
    }

    final sortedOffsets = weekOffsets.toList()..sort();
    return sortedOffsets;
  }

  bool _hasReservationsInWeekOffset(
    List<Reservation> reservations,
    int weekOffset,
  ) {
    if (reservations.isEmpty) return false;

    final now = TimezoneUtils.getSeoulDateTime();
    final thisWeekMonday = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: now.weekday - DateTime.monday));

    final weekStart = thisWeekMonday.add(Duration(days: 7 * weekOffset));
    final weekStartOnly = DateTime(
      weekStart.year,
      weekStart.month,
      weekStart.day,
    );
    final weekEndOnly = weekStartOnly.add(const Duration(days: 6));

    for (final r in reservations) {
      final d = TimezoneUtils.getSeoulDateOnly(r.reservedDate);
      final inRange =
          (d.isAtSameMomentAs(weekStartOnly) || d.isAfter(weekStartOnly)) &&
          (d.isAtSameMomentAs(weekEndOnly) || d.isBefore(weekEndOnly));
      if (inRange) return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _init();
      // 초기 로드 시 현재 선택된 주차의 비정기 세션 정보 로드
      _loadOverridesForWeek(0);
    });
  }

  Future<void> _init() async {
    await _loadData();
    if (!mounted) return;
    // highlightReservation이 있어도 자동으로 애니메이션을 시작하지 않음
    // 명시적으로 클릭한 경우(shouldShowBottomSheet가 true)에만 애니메이션 적용
    if (widget.highlightReservation != null) {
      // shouldShowBottomSheet 플래그 확인 - 명시적으로 클릭한 경우에만 애니메이션 실행
      final shouldShowBottomSheet =
          widget.highlightReservation!['shouldShowBottomSheet'] == true;

      // 명시적으로 클릭한 경우에만 애니메이션 실행
      if (shouldShowBottomSheet) {
        _processHighlightReservationWithRetry(
          shouldShowBottomSheet: shouldShowBottomSheet,
        );
      }
      // 탭 전환 등으로 넘어온 경우는 애니메이션 실행하지 않음
    }
  }

  Future<void> _loadData() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final reservationProvider = Provider.of<ReservationProvider>(
      context,
      listen: false,
    );
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final enrollmentProvider = Provider.of<EnrollmentProvider>(
      context,
      listen: false,
    );

    // 사용자 정보 확인
    if (authProvider.currentUser == null) return;

    // PlaceProvider에 현재 플레이스가 있는지 확인
    var currentPlace = placeProvider.currentPlace;

    // 플레이스가 없으면 placeMemberships에서 첫 번째 플레이스 로드
    if (currentPlace == null) {
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final approvedPlaceIds = authProvider.approvedPlaceIds;
      if (approvedPlaceIds.isNotEmpty) {
        final firstPlaceId = approvedPlaceIds.first;
        await placeProvider.loadPlace(firstPlaceId);
        currentPlace = placeProvider.currentPlace;
      }
    }

    if (currentPlace == null) return;

    try {
      // 코스가 로드되지 않았으면 로드
      if (courseProvider.courses.isEmpty) {
        await courseProvider.loadCourses(currentPlace.id);
      }

      // 예약이 로드되지 않았으면 로드
      if (reservationProvider.reservations.isEmpty) {
        await reservationProvider.loadUserReservations(
          userId: authProvider.currentUser!.userId,
          placeId: currentPlace.id,
        );
      }

      // enrollment 로드 (정책 엔진에 반영)
      await enrollmentProvider.loadUserEnrollments(
        userId: authProvider.currentUser!.userId,
        placeId: currentPlace.id,
      );

      // 비정기 세션 정보는 탭 변경 시 동적으로 로드 (성능 최적화)
      // 초기 로드 시에는 현재 선택된 주차만 로드
    } catch (e) {
      // 에러 발생 시에도 계속 진행
    }
  }

  /// 특정 주차의 비정기 세션 정보 로드
  void _loadOverridesForWeek(int weekOffset) {
    if (!mounted) return;

    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final currentPlace = placeProvider.currentPlace;

    if (currentPlace == null) return;

    final now = TimezoneUtils.getSeoulDateTime();
    final thisWeekMonday = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: now.weekday - DateTime.monday));

    final weekStart = thisWeekMonday.add(Duration(days: 7 * weekOffset));
    final weekStartDate = TimezoneUtils.formatDateToSeoul(weekStart);

    // 해당 주차의 비정기 세션 정보 구독 (이미 구독 중이면 재구독하지 않음)
    courseProvider.subscribeToOverrides(currentPlace.id, [weekStartDate]);
  }

  /// 예약 날짜로부터 주차 오프셋 계산
  int _calculateWeekOffset(DateTime reservationDate) {
    final now = TimezoneUtils.getSeoulDateTime();
    final thisWeekMonday = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: now.weekday - DateTime.monday));

    final targetDate = DateTime(
      reservationDate.year,
      reservationDate.month,
      reservationDate.day,
    );

    final diffDays = targetDate.difference(thisWeekMonday).inDays;
    return (diffDays / 7).floor();
  }

  void _processHighlightReservationWithRetry({
    int attempt = 0,
    bool shouldShowBottomSheet = false,
  }) {
    if (!mounted) return;
    if (widget.highlightReservation == null) return;
    if (attempt > 10) return; // 0.2s * 10 = 최대 ~2초 대기

    final reservationProvider = Provider.of<ReservationProvider>(
      context,
      listen: false,
    );
    final reservationInfo = widget.highlightReservation!;
    final userReservations = reservationProvider.reservations;

    // 먼저 해당 예약의 주차로 탭 이동
    final targetDate = reservationInfo['reservedDate'] as DateTime?;
    if (targetDate == null) return;

    final weekOffset = _calculateWeekOffset(targetDate);

    // availableWeekOffsets 계산 (해당 주차 포함)
    final availableWeekOffsets = _computeAvailableWeekOffsets(
      userReservations,
      extraDateToInclude: targetDate,
    );

    // 해당 주차로 탭 이동
    final tabIndex = availableWeekOffsets.indexOf(weekOffset);
    if (tabIndex >= 0 && tabIndex != _selectedWeekTab) {
      setState(() {
        _selectedWeekTab = tabIndex;
      });
    }

    // 예약 전체 정보가 없으면 주차만 설정하고 종료 (week-only 모드)
    final courseId = reservationInfo['courseId'];
    final dayOfWeek = reservationInfo['dayOfWeek'] as int?;
    final startTime = reservationInfo['startTime'] as String?;
    final hasFullInfo = courseId != null && dayOfWeek != null && startTime != null;

    if (!hasFullInfo) return; // 주차 설정 완료

    final Reservation? match = userReservations.cast<Reservation?>().firstWhere(
      (r) =>
          r != null &&
          r.courseId == courseId &&
          r.dayOfWeek == dayOfWeek &&
          r.startTime == startTime &&
          r.reservedDate.year == targetDate.year &&
          r.reservedDate.month == targetDate.month &&
          r.reservedDate.day == targetDate.day,
      orElse: () => null,
    );

    if (match == null) {
      Future.delayed(const Duration(milliseconds: 200), () {
        _processHighlightReservationWithRetry(
          attempt: attempt + 1,
          shouldShowBottomSheet: shouldShowBottomSheet,
        );
      });
      return;
    }

    // 탭 이동 후 약간의 지연을 두고 애니메이션 실행
    // 위젯이 완전히 빌드된 후에 애니메이션을 시작하도록 충분한 지연
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        _processHighlightReservation(
          shouldShowBottomSheet: shouldShowBottomSheet,
        );
      }
    });
  }

  // 사용자가 예약한 코스만 필터링
  List<Course> _getUserCourses(
    List<Reservation> reservations,
    List<Course> courses,
  ) {
    final reservedCourseIds = reservations.map((r) => r.courseId).toSet();

    // 예약한 코스만 필터링
    return courses.where((course) {
      return reservedCourseIds.contains(course.id);
    }).toList();
  }

  // 강조할 예약 처리
  void _processHighlightReservation({bool shouldShowBottomSheet = false}) {
    if (widget.highlightReservation == null) return;

    // 명시적으로 클릭한 경우(shouldShowBottomSheet가 true)에만 애니메이션 실행
    if (!shouldShowBottomSheet) {
      // 탭 전환 등으로 넘어온 경우는 애니메이션 실행하지 않음
      return;
    }

    final reservationProvider = Provider.of<ReservationProvider>(
      context,
      listen: false,
    );
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final userReservations = reservationProvider.reservations;
    final courses = courseProvider.courses;

    // 예약 찾기
    final reservationInfo = widget.highlightReservation!;
    final reservation = userReservations.firstWhere(
      (r) =>
          r.courseId == reservationInfo['courseId'] &&
          r.dayOfWeek == reservationInfo['dayOfWeek'] &&
          r.startTime == reservationInfo['startTime'] &&
          r.reservedDate.year ==
              (reservationInfo['reservedDate'] as DateTime).year &&
          r.reservedDate.month ==
              (reservationInfo['reservedDate'] as DateTime).month &&
          r.reservedDate.day ==
              (reservationInfo['reservedDate'] as DateTime).day,
      orElse:
          () =>
              userReservations.isNotEmpty
                  ? userReservations.first
                  : Reservation(
                    id: '',
                    userId: '',
                    courseId: '',
                    placeId: '',
                    dayOfWeek: 0,
                    startTime: '',
                    reservedAt: DateTime.now(),
                    reservedDate: DateTime.now(),
                  ),
    );

    final course = courses.firstWhere(
      (c) => c.id == reservation.courseId,
      orElse:
          () =>
              courses.isNotEmpty
                  ? courses.first
                  : Course(
                    description: '',
                    id: reservation.courseId,
                    name: '',
                    color: 0xFF087044,
                    sessions: [],
                  ),
    );

    final session = course.findSession(
      reservation.dayOfWeek,
      reservation.startTime,
    );

    CourseSession? effectiveSession = session;

    // 정기 세션이 없는 경우(비정기/override 세션) override에서 찾아서 세션 구성
    if (effectiveSession == null) {
      final reservationDateOnly = TimezoneUtils.getSeoulDateOnly(
        reservation.reservedDate,
      );
      final monday = reservationDateOnly.subtract(
        Duration(days: reservationDateOnly.weekday - DateTime.monday),
      );
      final weekStartDateString = TimezoneUtils.formatDateToSeoul(monday);
      final overrides = courseProvider.getOverridesForWeek(weekStartDateString);
      final dateString = TimezoneUtils.formatDateToSeoul(reservationDateOnly);

      for (final o in overrides) {
        if (o.courseId != reservation.courseId) continue;
        if (o.date != dateString) continue;
        if (o.dayOfWeek != reservation.dayOfWeek) continue;
        if (o.startTime != reservation.startTime) continue;
        if (o.isCancelled == true) continue;
        if (o.startTime == null || o.endTime == null) continue;
        effectiveSession = CourseSession(
          dayOfWeek: o.dayOfWeek,
          startTime: o.startTime!,
          endTime: o.endTime!,
          capacity: o.capacity ?? 0,
        );
        break;
      }
    }

    if (effectiveSession == null) return;

    setState(() {
      _shouldHighlightReservation = true;
      _highlightedReservation = reservation;
      _highlightedCourse = course;
      _highlightedSession = effectiveSession;
      _highlightedDate = reservation.reservedDate;
    });

    // 애니메이션 후 바텀시트 표시 (명시적으로 요청한 경우에만)
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) {
        setState(() {
          _shouldHighlightReservation = false;
        });
        _showReservationBottomSheet();
      }
    });
  }

  // 예약 바텀시트 표시
  void _showReservationBottomSheet() {
    if (_highlightedCourse == null ||
        _highlightedSession == null ||
        _highlightedDate == null)
      return;

    UserReservationManageBottomSheet.show(
      context: context,
      course: _highlightedCourse!,
      session: _highlightedSession!,
      date: _highlightedDate!,
      reservation: _highlightedReservation,
      onReservationCancelled: () {
        setState(() {});
      },
    );
  }

  // 세션 클릭 핸들러
  void _onSessionTap(Course course, CourseSession session, DateTime date) {
    final reservationProvider = Provider.of<ReservationProvider>(
      context,
      listen: false,
    );
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final authProvider = Provider.of<AuthProvider>(context, listen: false);

    final userReservations = reservationProvider.reservations;

    // 해당 세션의 사용자 예약 찾기
    final reservation = userReservations.firstWhere(
      (r) =>
          r.courseId == course.id &&
          r.dayOfWeek == session.dayOfWeek &&
          r.startTime == session.startTime &&
          r.reservedDate.year == date.year &&
          r.reservedDate.month == date.month &&
          r.reservedDate.day == date.day,
      orElse: () {
        final placeId = placeProvider.currentPlace?.id ?? '';
        final userId = authProvider.currentUser?.userId ?? '';
        return Reservation(
          id: '',
          userId: userId,
          courseId: course.id,
          placeId: placeId,
          dayOfWeek: session.dayOfWeek,
          startTime: session.startTime,
          reservedAt: DateTime.now(),
          reservedDate: date,
        );
      },
    );

    // 예약 관리 바텀시트 표시
    UserReservationManageBottomSheet.show(
      context: context,
      course: course,
      session: session,
      date: date,
      reservation:
          userReservations.any(
                (r) =>
                    r.courseId == course.id &&
                    r.dayOfWeek == session.dayOfWeek &&
                    r.startTime == session.startTime &&
                    r.reservedDate.year == date.year &&
                    r.reservedDate.month == date.month &&
                    r.reservedDate.day == date.day,
              )
              ? reservation
              : null,
      onReservationCancelled: () {
        setState(() {});
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final reservationProvider = Provider.of<ReservationProvider>(context);
    final courseProvider = Provider.of<CourseProvider>(context);

    final userReservations = reservationProvider.reservations;
    final availableWeekOffsets = _computeAvailableWeekOffsets(userReservations);
    if (_selectedWeekTab >= availableWeekOffsets.length) {
      _selectedWeekTab = availableWeekOffsets.length - 1;
    }
    final userCourses = _getUserCourses(
      userReservations,
      courseProvider.courses,
    );

    final selectedWeekOffset =
        availableWeekOffsets.isNotEmpty
            ? availableWeekOffsets[_selectedWeekTab]
            : 0;
    final hasAnyReservationInSelectedWeek = _hasReservationsInWeekOffset(
      userReservations,
      selectedWeekOffset,
    );

    // 현재 선택된 주차의 비정기 세션 정보 로드 (build 시마다 확인)
    if (availableWeekOffsets.isNotEmpty) {
      final currentWeekOffset = availableWeekOffsets[_selectedWeekTab];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadOverridesForWeek(currentWeekOffset);
      });
    }

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                // 메인 콘텐츠
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 플레이스 정보
                        _buildPlaceInfoSection(),

                        const SizedBox(height: 34),

                        // 주차 이동 탭 (최소 4주 이후까지)
                        if (userReservations.isNotEmpty) ...[
                          WeekTabBar(
                            selectedIndex: _selectedWeekTab,
                            onTabChanged: (index) {
                              setState(() {
                                _selectedWeekTab = index;
                              });
                              // 탭 변경 시 해당 주차의 비정기 세션 정보 로드
                              _loadOverridesForWeek(
                                availableWeekOffsets[index],
                              );
                            },
                            availableWeekOffsets: availableWeekOffsets,
                            showDot: true,
                          ),
                          const SizedBox(height: 12),
                        ],

                        // 캘린더 위젯 (일정보기 모드) - 카드 스타일
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Container(
                            decoration: BoxDecoration(
                              color: AppColors.backgroundWhite,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: CompactCalendarWidget(
                              courses: userCourses,
                              usage:
                                  CompactCalendarUsage
                                      .userWeeklyReservationsView,
                              weekOffset: selectedWeekOffset,
                              // ✅ 선택된 주차에 예약이 없으면 100px로 축소
                              height:
                                  hasAnyReservationInSelectedWeek ? 500 : 100,
                              onSessionTap: _onSessionTap,
                              hideCourseSelector: true, // 일정보기 모드에서는 드롭다운 숨김
                              weeklyViewMode: true, // 일정보기 모드 활성화
                              userReservations:
                                  userReservations, // 사용자 예약 리스트 전달
                              highlightReservation:
                                  _shouldHighlightReservation &&
                                          _highlightedReservation != null &&
                                          _highlightedCourse != null &&
                                          _highlightedSession != null &&
                                          _highlightedDate != null
                                      ? {
                                        'reservationId':
                                            _highlightedReservation!.id,
                                        'courseId': _highlightedCourse!.id,
                                        'dayOfWeek':
                                            _highlightedSession!.dayOfWeek,
                                        'startTime':
                                            _highlightedSession!.startTime,
                                        'reservedDate': _highlightedDate!,
                                      }
                                      : null,
                            ),
                          ),
                        ),

                        const SizedBox(height: 32),

                        // 수강 중인 코스 섹션
                        _buildEnrolledCoursesSection(),

                        const SizedBox(height: 32),

                        // 마이프로필 섹션
                        Builder(
                          builder: (context) {
                            final authProvider = Provider.of<AuthProvider>(
                              context,
                            );
                            final user = authProvider.currentUser;
                            final isLoggedIn = user != null;
                            final isNotificationEnabled =
                                user?.notificationsEnabled ?? true;

                            return UserProfileInfoSection(
                              headerTitle: '마이프로필',
                              profileName:
                                  isLoggedIn ? (user.name) : '로그인이 필요합니다',
                              profilePhoneNumber:
                                  isLoggedIn
                                      ? (user.phoneNumber)
                                      : '로그인하고 모든 기능을 이용하세요',
                              onProfileTap: () {
                                if (!isLoggedIn) {
                                  Navigator.of(
                                    context,
                                  ).pushNamed('/phone-number');
                                  return;
                                }
                                // ✅ 로그인된 경우 이름 변경 바텀시트 (Firestore users 반영)
                                NameEditBottomSheet.show(
                                  context: context,
                                  initialName: user.name,
                                );
                              },
                              profileBottomWidget: const PlaceSwitchWidget(
                                heroTagSuffix: 'my_page_profile',
                                showExitWhenUnregistered: true,
                              ),
                              settingsItems: SettingsItemsBuilder.buildSettingsItems(
                                context: context,
                                isNotificationEnabled: isNotificationEnabled,
                                onNotificationTap: () async {
                                  final result =
                                      await NotificationSettingsDialog.show(
                                        context: context,
                                        initialValue: isNotificationEnabled,
                                      );
                                  if (result == true && context.mounted) {
                                    // 다이얼로그에서 설정이 변경되었으면 화면 새로고침
                                    setState(() {});
                                  }
                                },
                                // ✅ 로그인 안 된 경우 로그아웃/회원탈퇴 버튼 숨김
                                onLogout:
                                    isLoggedIn
                                        ? () async {
                                          await authProvider.logout();
                                        }
                                        : null, // null이면 로그아웃 항목이 표시되지 않음
                                onWithdraw:
                                    isLoggedIn
                                        ? () async {
                                          final authProvider =
                                              Provider.of<AuthProvider>(
                                                context,
                                                listen: false,
                                              );
                                          final user = authProvider.currentUser;

                                          if (user == null) {
                                            SnackbarUtil.showInfo(
                                              context,
                                              '사용자 정보를 찾을 수 없습니다.',
                                            );
                                            return;
                                          }

                                          SnackbarUtil.showLoading(
                                            context,
                                            '탈퇴중',
                                          );

                                          try {
                                            final functions =
                                                FirebaseFunctions.instance;
                                            final deleteAccountCallable =
                                                functions.httpsCallable(
                                                  'deleteUserAccount',
                                                );

                                            await deleteAccountCallable.call({
                                              'userId': user.userId,
                                            });

                                            await authProvider.logout();

                                            if (context.mounted) {
                                              SnackbarUtil.showSuccess(
                                                context,
                                                '회원탈퇴가 완료되었습니다.',
                                              );
                                              Navigator.pushNamedAndRemoveUntil(
                                                context,
                                                '/',
                                                (route) => false,
                                              );
                                            }
                                          } catch (e) {
                                            if (context.mounted) {
                                              String message =
                                                  '회원탈퇴 중 오류가 발생했습니다.';
                                              if (e
                                                      is FirebaseFunctionsException &&
                                                  (e.message ?? '')
                                                      .trim()
                                                      .isNotEmpty) {
                                                message = e.message!.trim();
                                              } else {
                                                try {
                                                  final msg =
                                                      (e as dynamic).message
                                                          ?.toString();
                                                  if (msg != null &&
                                                      msg.trim().isNotEmpty) {
                                                    message = msg.trim();
                                                  }
                                                } catch (_) {}
                                              }
                                              SnackbarUtil.showInfo(
                                                context,
                                                message,
                                              );
                                            }
                                          }
                                        }
                                        : null, // null이면 회원탈퇴 항목이 표시되지 않음
                              ),
                            );
                          },
                        ),

                        const SizedBox(height: 32),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 플레이스 정보 섹션 (나가기 버튼은 프로필 쪽 한 곳에서만 표시)
  Widget _buildPlaceInfoSection() {
    final authProvider = Provider.of<AuthProvider>(context);
    return PlaceSwitchWidget(
      enabled: authProvider.currentUser != null,
      showDescription: true,
      heroTagSuffix: 'my_page',
      showExitWhenUnregistered: false,
    );
  }

  // 수강 중인 코스 섹션
  Widget _buildEnrolledCoursesSection() {
    final courseProvider = Provider.of<CourseProvider>(context);
    final enrollmentProvider = Provider.of<EnrollmentProvider>(context);
    final courses = courseProvider.courses;

    // 유효기간 내 등록 정보만 표시 (남은 횟수 0이어도 "수강 중"은 유지되어야 함)
    // 일회성(1회석) 등록은 수강 중인 코스 목록에 노출하지 않음 (알 수 없는 코스 + 재등록 필요 방지)
    final validEnrollments =
        enrollmentProvider.enrollments
            .where((e) => e.isValid && !e.isOneTime)
            .toList()
          ..sort((a, b) => a.validUntil.compareTo(b.validUntil));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 섹션 제목
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            '수강 중인 코스',
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.bold,
              color: AppColors.primaryGreen,
            ),
          ),
        ),
        const SizedBox(height: 6),
        if (validEnrollments.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              decoration: BoxDecoration(
                color: AppColors.backgroundWhite,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '수강 중인 코스가 없어요',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondary.withOpacity(0.7),
                ),
              ),
            ),
          )
        else
          // 코스 카드 리스트
          ...validEnrollments.map((enrollment) {
            // 코스 정보 찾기 (데이터 정합성 보장)
            final course = courses.firstWhere(
              (c) => c.id == enrollment.courseId,
              orElse:
                  () => Course(
                    id: enrollment.courseId,
                    name: '알 수 없는 코스',
                    description: '',
                    color: 0xFF087044,
                    sessions: [],
                  ),
            );
            return _buildEnrolledCourseCard(course, enrollment);
          }).toList(),
      ],
    );
  }

  // 수강 중인 코스 카드
  Widget _buildEnrolledCourseCard(Course course, CourseEnrollment enrollment) {
    // 재등록 필요 여부 확인
    final needsReenrollment =
        enrollment.isExpired || enrollment.remainingReservations == 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            _showEnrollmentDetailBottomSheet(course, enrollment);
          },
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.backgroundWhite,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    // 코스 이미지
                    CourseImageWidget(
                      imageUrl: course.imageUrl,
                      width: 100,
                      height: 100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    const SizedBox(width: 16),
                    // 코스 정보
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 코스 이름
                          SizedBox(height: 6),
                          Text(
                            course.name,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: AppColors.primaryGreen,
                              letterSpacing: -0.5,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),

                          // 코스 설명
                          Padding(
                            padding: const EdgeInsets.only(right: 10, top: 4),
                            child: Text(
                              course.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                color: AppColors.primaryGreen.withOpacity(0.8),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // 재등록 필요 칩 (오른쪽 상단)
              if (needsReenrollment)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.reservedGrey.withOpacity(0.8),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '재등록 필요',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.reservedTextGrey,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // 등록 상세 정보 바텀시트 표시
  void _showEnrollmentDetailBottomSheet(
    Course course,
    CourseEnrollment enrollment,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.7),
      isDismissible: true,
      enableDrag: true,
      useSafeArea: true,
      builder:
          (context) => EnrollmentDetailBottomSheet(
            course: course,
            enrollment: enrollment,
            onExtensionRequested: () {
              setState(() {});
            },
          ),
    );
  }
}
