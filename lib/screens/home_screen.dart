import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_colors.dart';
import '../widgets/story_card.dart';
import 'story/story_detail_screen.dart';
import '../models/session_reservation.dart';
import '../models/course.dart';
import '../models/course_enrollment.dart';
import '../providers/place_provider.dart';
import '../providers/reservation_provider.dart';
import '../providers/story_provider.dart' show StoryProvider;
import '../providers/auth_provider.dart';
import '../providers/course_provider.dart';
import '../providers/enrollment_provider.dart';
import '../widgets/place_switch_widget.dart'
    show PlaceSwitchWidget, navigateToPlaceWaitingScreen;
import '../widgets/notification_icon_widget.dart';
import '../providers/reservation_summary_provider.dart';
import '../models/course_override.dart';
import '../utils/calendar_utils.dart';
import '../utils/session_slot_builder.dart';
import '../utils/timezone_utils.dart';
import '../widgets/reservation_summary_card.dart';
import '../providers/enrollment_timeline_provider.dart';
import 'admin/widgets/calendar_screen.dart';
import 'enrollment_detail_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _loadingCourseId; // 예약하기 클릭 시 해당 코스 로딩 중
  final PageController _storyPageController = PageController(
    viewportFraction: 0.92, // 카드가 화면의 92%를 차지하여 옆 카드가 보이게
    keepPage: true, // 페이지 상태 유지
  ); // 스토리 페이지 컨트롤러
  int _currentStoryIndex = 0; // 현재 스토리 페이지 인덱스
  bool _isDataLoaded = false;

  @override
  void initState() {
    super.initState();
    // initState 중 Provider notify가 build-phase와 겹치면
    // "setState() or markNeedsBuild() called during build"가 날 수 있어
    // 첫 프레임 이후로 미룬다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadDataIfNeeded();
    });
  }

  /// 데이터가 로드되지 않았으면 로드
  Future<void> _loadDataIfNeeded() async {
    if (_isDataLoaded) return;

    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final storyProvider = Provider.of<StoryProvider>(context, listen: false);
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final reservationProvider = Provider.of<ReservationProvider>(
      context,
      listen: false,
    );
    final enrollmentProvider = Provider.of<EnrollmentProvider>(
      context,
      listen: false,
    );
    final authProvider = Provider.of<AuthProvider>(context, listen: false);

    final currentPlace = placeProvider.currentPlace;
    if (currentPlace == null) return;

    try {
      // MainScreen에서 로드하지 않은 경우에만 로드
      if (storyProvider.stories.isEmpty) {
        await storyProvider.loadStories(currentPlace.id);
      }
      if (courseProvider.courses.isEmpty) {
        await courseProvider.loadCourses(currentPlace.id);
      }
      if (authProvider.currentUser != null) {
        // 항상 구독 보장 (Provider 내부에서 중복 구독 방지)
        await reservationProvider.loadUserReservations(
          userId: authProvider.currentUser!.userId,
          placeId: currentPlace.id,
        );
        await enrollmentProvider.loadUserEnrollments(
          userId: authProvider.currentUser!.userId,
          placeId: currentPlace.id,
        );
      }

      _isDataLoaded = true;
    } catch (e) {
      // 에러 발생 시에도 계속 진행
    }
  }

  @override
  void dispose() {
    _storyPageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final placeProvider = Provider.of<PlaceProvider>(context);

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 헤더
              _buildPlacesSection(context),

              const SizedBox(height: 24),

              // 제목 섹션 (환영메시지 숨기기 체크 시 미표시)
              if (!(placeProvider.currentPlace?.hideGreeting ?? false)) ...[
                _buildTitleSection(placeProvider),
                const SizedBox(height: 30),
              ],

              // 최근 이용 섹션 (로그인 여부와 관계없이 표시)
              _buildRecentUsageSection(),

              // 탭
              const SizedBox(height: 52),
              _buildTabs(),
              const SizedBox(height: 20),
              // 탭에 따른 콘텐츠
              AnimatedSize(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  switchInCurve: Curves.easeInOut,
                  switchOutCurve: Curves.easeInOut,
                  transitionBuilder: (child, animation) {
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0.1, 0),
                          end: Offset.zero,
                        ).animate(
                          CurvedAnimation(
                            parent: animation,
                            curve: Curves.easeInOut,
                          ),
                        ),
                        child: child,
                      ),
                    );
                  },
                  child: _buildStoryCards(key: const ValueKey('story')),
                ),
              ),

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlacesSection(BuildContext context) {
    return Consumer2<PlaceProvider, AuthProvider>(
      builder: (context, placeProvider, authProvider, _) {
        final place = placeProvider.currentPlace;
        final memberIds = authProvider.approvedPlaceIds;
        final adminIds = authProvider.adminManagedPlaceIds;
        final isUnregistered =
            place != null &&
            !memberIds.contains(place.id) &&
            !adminIds.contains(place.id);
        final isLoggedIn =
            authProvider.currentUser != null ||
            authProvider.currentAdmin != null;
        // 로그인 안 되어 있어도 나가기 버튼 표시
        final showExitButton = place != null && (!isLoggedIn || isUnregistered);

        return Row(
          children: [
            Expanded(
              child: PlaceSwitchWidget(
                enabled: false,
                showDescription: false,
                padding: EdgeInsets.zero,
                heroTagSuffix: 'home',
                isAdminContext: false,
                hideChevron: true,
              ),
            ),
            const SizedBox(width: 12),
            if (showExitButton)
              TextButton(
                onPressed:
                    () => navigateToPlaceWaitingScreen(context, authProvider),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Icon(
                  Icons.logout,
                  size: 24,
                  color: AppColors.primaryGreen,
                ),
              )
            else
              const NotificationIconWidget(),
            SizedBox(width: showExitButton ? 10 : 20),
          ],
        );
      },
    );
  }

  // 제목 섹션
  Widget _buildTitleSection(PlaceProvider placeProvider) {
    final place = placeProvider.currentPlace;
    final greetingText = place?.greetingText ?? '안녕하세요';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Text(
        greetingText,
        style: TextStyle(
          fontSize: 26,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }

  // 스토리 카드들 (스토리 탭)
  Widget _buildStoryCards({Key? key}) {
    final storyProvider = Provider.of<StoryProvider>(context);
    final placeProvider = Provider.of<PlaceProvider>(context);
    final stories = storyProvider.stories;
    final currentPlace = placeProvider.currentPlace;

    if (stories.isEmpty) {
      return Column(
        key: key,
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              '스토리',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              padding: const EdgeInsets.symmetric(
                vertical: 100,
                horizontal: 16,
              ),
              decoration: BoxDecoration(
                color: AppColors.backgroundWhite,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '아직 스토리가 없어요',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textSecondary.withOpacity(0.8),
                    ),
                    textAlign: TextAlign.center,
                  ),

                  Center(child: SizedBox()),
                ],
              ),
            ),
          ),
        ],
      );
    }

    // 스토리가 1개일 때와 2개 이상일 때 다른 레이아웃
    if (stories.length == 1) {
      // 1개일 때: 화면 너비를 거의 다 채워서 표시 (왼쪽만 패딩)
      return SizedBox(
        key: key,
        height: 330,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: StoryCard(
            title: stories[0].title,
            content: stories[0].content,
            date: _formatStoryDate(stories[0].createdAt),
            imageUrls: stories[0].imageUrls,
            backgroundImageUrl: stories[0].backgroundImageUrl,
            placeName: currentPlace?.name,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder:
                      (_) => StoryDetailScreen(
                        story: stories[0],
                        place: currentPlace,
                      ),
                ),
              );
            },
          ),
        ),
      );
    } else {
      // 2개 이상일 때: 옆 카드가 살짝 보이게
      return SizedBox(
        key: key,
        height: 330,
        child: PageView.builder(
          padEnds: false,
          controller: _storyPageController,
          onPageChanged: (index) {
            setState(() {
              _currentStoryIndex = index;
            });
          },
          itemCount: stories.length,
          itemBuilder: (context, index) {
            final isLast = index == stories.length - 1;
            return Padding(
              padding: EdgeInsets.only(
                left: index == 0 ? 16 : 4,
                right: isLast ? 16 : 4,
              ),
              child: StoryCard(
                title: stories[index].title,
                content: stories[index].content,
                date: _formatStoryDate(stories[index].createdAt),
                imageUrls: stories[index].imageUrls,
                backgroundImageUrl: stories[index].backgroundImageUrl,
                placeName: currentPlace?.name,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder:
                          (_) => StoryDetailScreen(
                            story: stories[index],
                            place: currentPlace,
                          ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      );
    }
  }

  // 탭
  Widget _buildTabs() {
    final storyProvider = Provider.of<StoryProvider>(context);
    final stories = storyProvider.stories;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          // 스토리 개수만큼 점 표시
          if (stories.isNotEmpty)
            Row(
              children: List.generate(
                stories.length,
                (index) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color:
                          _currentStoryIndex == index
                              ? AppColors.primaryGreen
                              : AppColors.primaryGreen.withOpacity(0.3),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 홈용 예약 요약 섹션: ReservationSummaryCard 위젯 주입
  Widget _buildRecentUsageSection() {
    return Consumer4<
      AuthProvider,
      EnrollmentProvider,
      ReservationProvider,
      CourseProvider
    >(
      builder: (
        context,
        auth,
        enrollmentProvider,
        reservationProvider,
        courseProvider,
        _,
      ) {
        final isLoggedIn = auth.currentUser != null;
        final enrollments =
            isLoggedIn ? enrollmentProvider.enrollments : <CourseEnrollment>[];
        final courses = courseProvider.courses;
        final reservations =
            isLoggedIn
                ? reservationProvider.reservations
                : <SessionReservation>[];

        return ReservationSummaryCard(
          isLoggedIn: isLoggedIn,
          enrollments: enrollments,
          reservations: reservations,
          courses: courses,
          onTap: () {
            if (isLoggedIn && enrollments.isNotEmpty) {
              Navigator.of(context).pushNamedAndRemoveUntil(
                '/main',
                (route) => false,
                arguments: 2,
              );
            }
          },
          onCardTap: (course, enrollment) {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder:
                    (context) =>
                        ChangeNotifierProvider<EnrollmentTimelineProvider>(
                          create:
                              (_) =>
                                  EnrollmentTimelineProvider()
                                    ..watchTimeline(enrollment),
                          child: EnrollmentDetailScreen(
                            course: course,
                            enrollment: enrollment,
                            onExtensionRequested: () {
                              if (context.mounted) setState(() {});
                            },
                          ),
                        ),
              ),
            );
          },
          loadingCourseId: _loadingCourseId,
          onCourseTap: (course) => _openCalendarWithPreload(course),
        );
      },
    );
  }

  Future<void> _openCalendarWithPreload(Course course) async {
    if (_loadingCourseId != null) return;
    final placeId =
        Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id;
    if (placeId == null || placeId.isEmpty) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (context) => CalendarScreen(course: course)),
      );
      return;
    }

    setState(() => _loadingCourseId = course.id);
    try {
      final summaryProvider = Provider.of<ReservationSummaryProvider>(
        context,
        listen: false,
      );
      final courseProvider = Provider.of<CourseProvider>(
        context,
        listen: false,
      );

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

      final weekStartDates =
          offsets
              .map(
                (o) => CalendarUtils.formatDateYMD(
                  CalendarUtils.weekStartFrom(now, o),
                ),
              )
              .toList();
      courseProvider.subscribeToOverrides(placeId, weekStartDates);

      for (var i = 0; i < offsets.length; i++) {
        final ws = CalendarUtils.weekStartFrom(now, offsets[i]);
        final weekStartDate = weekStartDates[i];
        final startDateWs = DateTime(ws.year, ws.month, ws.day);
        final overridesForCourse =
            courseProvider
                .getOverridesForWeek(weekStartDate)
                .where((o) => o.courseId == course.id)
                .toList();
        summaryProvider.updateOverridesForWeek(
          weekStartDate,
          overridesForCourse,
        );
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

      const timeout = Duration(seconds: 5);
      final deadline = DateTime.now().add(timeout);
      while (summaryProvider.isLoading && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 50));
        if (!mounted) return;
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _loadingCourseId = null);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => CalendarScreen(course: course)),
    );
  }

  // Helper 메서드들
  String _formatStoryDate(DateTime date) {
    return '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';
  }
}
