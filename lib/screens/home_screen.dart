import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../theme/app_colors.dart';
import '../widgets/story_card.dart';
import 'story/story_detail_screen.dart';
import '../models/reservation.dart';
import '../models/course.dart';
import '../providers/place_provider.dart';
import '../providers/reservation_provider.dart';
import '../providers/story_provider.dart' show StoryProvider;
import '../providers/auth_provider.dart';
import '../providers/course_provider.dart';
import '../providers/enrollment_provider.dart';
import '../utils/timezone_utils.dart';
import '../widgets/place_switch_widget.dart'
    show PlaceSwitchWidget, navigateToPlaceWaitingScreen;
import '../widgets/notification_icon_widget.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentReservationPage = 0; // 현재 예약 카드 페이지
  final PageController _reservationPageController = PageController();
  final PageController _storyPageController = PageController(
    viewportFraction: 0.92, // 카드가 화면의 92%를 차지하여 옆 카드가 보이게
    keepPage: true, // 페이지 상태 유지
  ); // 스토리 페이지 컨트롤러
  int _currentStoryIndex = 0; // 현재 스토리 페이지 인덱스
  bool _isDataLoaded = false;

  // 디자인 상수
  static const double _cardHeight = 200.0;
  static const double _cardBorderRadius = 20.0;
  static const double _chipBorderRadius = 12.0;
  static const double _chipHorizontalPadding = 10.0;
  static const double _chipVerticalPadding = 6.0;
  static const double _dateFontSize = 20.0; // 날짜 크게
  static const double _spacingSmall = 8.0;
  static const double _spacingMedium = 16.0;
  static const double _cardElevation = 2.0;
  static const double _cardShadowBlur = 8.0;
  static const double _cardShadowOpacity = 0.08;

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
    _reservationPageController.dispose();
    _storyPageController.dispose();
    super.dispose();
  }

  // 최근 예약 리스트 가져오기 (최대 5개)
  List<Map<String, dynamic>> _getRecentReservations(
    List<Reservation> reservations,
    List<Course> courses,
  ) {
    // ReservationProvider에서 "임박한 예약 우선" 정렬이 이미 들어오므로 그 순서를 유지한다.
    // 요구사항:
    // - 기본은 최대 5개
    // - 단, "모두 미완료(=예정)" 상태라면 제한 없이 전부 보여준다
    final now = TimezoneUtils.getSeoulDateTime();

    bool isUpcoming(Reservation r) {
      final parts = r.startTime.split(':');
      final h = int.tryParse(parts[0].trim()) ?? 0;
      final m = (parts.length > 1) ? (int.tryParse(parts[1].trim()) ?? 0) : 0;
      final start = DateTime(
        r.reservedDate.year,
        r.reservedDate.month,
        r.reservedDate.day,
        h.clamp(0, 23),
        m.clamp(0, 59),
      );
      return !start.isBefore(now);
    }

    final hasCompleted = reservations.any((r) => !isUpcoming(r));
    final recentReservations =
        hasCompleted
            ? reservations.take(5).toList()
            : List<Reservation>.from(reservations);

    // 코스 정보와 함께 매핑
    return recentReservations.map((reservation) {
      final course = courses.firstWhere(
        (c) => c.id == reservation.courseId,
        orElse:
            () => Course(
              description: '',
              id: reservation.courseId,
              name: '알 수 없는 코스',
              color: 0xFF087044,
              sessions: [],
            ),
      );
      return {'reservation': reservation, 'course': course};
    }).toList();
  }

  // 요일 이름 변환
  String _getDayName(int dayOfWeek) {
    const days = ['', '월', '화', '수', '목', '금', '토', '일'];
    if (dayOfWeek >= 1 && dayOfWeek <= 7) {
      return days[dayOfWeek];
    }
    return '';
  }

  // 날짜 포맷팅
  String _formatDate(DateTime date) {
    return '${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';
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

              // 제목 섹션
              _buildTitleSection(placeProvider),

              const SizedBox(height: 30),

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
        final isLoggedIn = authProvider.currentUser != null ||
            authProvider.currentAdmin != null;
        // 로그인 안 되어 있어도 나가기 버튼 표시
        final showExitButton =
            place != null && (!isLoggedIn || isUnregistered);

        return Row(
          children: [
            Expanded(
              child: PlaceSwitchWidget(
                enabled: false,
                showDescription: false,
                padding: EdgeInsets.zero,
                heroTagSuffix: 'home',
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
            const SizedBox(width: 20),
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
          fontSize: 28,
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
      return SizedBox(
        key: key,
        height: 180,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: 2,
          itemBuilder: (context, index) {
            if (index == 0) {
              // 첫 번째 카드: 없습니다 메시지
              return Container(
                width: 320,
                margin: const EdgeInsets.only(right: 12),
                padding: const EdgeInsets.all(16),
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
                  ],
                ),
              );
            } else {
              // 두 번째 카드: 빈 카드
              return Container(
                width: 320,
                margin: const EdgeInsets.only(right: 12),
                padding: const EdgeInsets.all(16),
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
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '새로운 스토리를\n기다리고 있어요',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textLight,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              );
            }
          },
        ),
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

  // 최근 이용 섹션
  Widget _buildRecentUsageSection() {
    final reservationProvider = Provider.of<ReservationProvider>(context);
    final courseProvider = Provider.of<CourseProvider>(context);
    final authProvider = Provider.of<AuthProvider>(context);

    // ✅ Apple App Store 가이드라인 5.1.1 준수: 로그인 안 되어 있어도 섹션 표시
    final isLoggedIn = authProvider.currentUser != null;

    final reservations =
        isLoggedIn ? reservationProvider.reservations : <Reservation>[];
    final courses = courseProvider.courses;
    final allReservations =
        isLoggedIn
            ? _getRecentReservations(reservations, courses)
            : <Map<String, dynamic>>[];
    final totalCount = allReservations.length;
    final currentIndex =
        totalCount > 0
            ? _currentReservationPage + 1
            : 0; // 현재 보고 있는 카드 인덱스 (1부터 시작)

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '내 예약',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),

              // ✅ 로그인된 경우에만 페이지 인디케이터 표시
              if (isLoggedIn && totalCount > 0)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(
                      totalCount,
                      (index) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color:
                                index == currentIndex - 1
                                    ? AppColors.primaryGreen
                                    : AppColors.primaryGreen.withOpacity(0.3),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _buildRecentUsageCard(),
      ],
    );
  }

  // 최근 이용 카드
  Widget _buildRecentUsageCard() {
    final reservationProvider = Provider.of<ReservationProvider>(context);
    final courseProvider = Provider.of<CourseProvider>(context);
    final authProvider = Provider.of<AuthProvider>(context);

    // ✅ 로그인 안 되어 있어도 빈 상태 카드 표시
    final isLoggedIn = authProvider.currentUser != null;

    final reservations =
        isLoggedIn ? reservationProvider.reservations : <Reservation>[];
    final courses = courseProvider.courses;

    final recentReservations =
        isLoggedIn
            ? _getRecentReservations(reservations, courses)
            : <Map<String, dynamic>>[];

    // 리스트가 줄어들 때(취소 직후 등) 현재 페이지 인덱스가 범위를 벗어나면 안정적으로 보정
    final totalCount = recentReservations.length;
    if (totalCount == 0) {
      if (_currentReservationPage != 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _currentReservationPage = 0;
          });
        });
      }
    } else if (_currentReservationPage > totalCount - 1) {
      final nextIndex = totalCount - 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _currentReservationPage = nextIndex;
        });
        try {
          _reservationPageController.jumpToPage(nextIndex);
        } catch (_) {
          // controller attach 타이밍 이슈는 무시 (다음 프레임에서 자연히 안정화)
        }
      });
    }

    // ✅ 로그인 안 되어 있거나 예약이 없으면 빈 상태 카드 표시
    if (!isLoggedIn || recentReservations.isEmpty) {
      return SizedBox(
        height: _cardHeight,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 0),
          itemCount: 1,
          itemBuilder: (context, index) {
            // 첫 번째 카드: 없습니다 메시지
            return Container(
              width: MediaQuery.of(context).size.width * 0.9,
              margin: const EdgeInsets.only(right: 12, left: 16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.backgroundWhite,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '예약 내역이 없어요',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary.withOpacity(0.6),
                    ),
                    textAlign: TextAlign.center,
                  ),

                  const SizedBox(height: 10),
                  Center(
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.of(context).pushNamedAndRemoveUntil(
                          '/main',
                          (route) => false,
                          arguments: 1, // 예약 탭 인덱스
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primaryGreen,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 16,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        elevation: 0,
                      ),
                      child: const Text(
                        '예약하러가기',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
    }

    return SizedBox(
      height: _cardHeight,
      child: PageView(
        controller: _reservationPageController,
        onPageChanged: (index) {
          setState(() {
            _currentReservationPage = index;
          });
        },
        children:
            recentReservations.map((data) {
              final reservation = data['reservation'] as Reservation;
              final course = data['course'] as Course;

              // 오늘 날짜 (시간 제외)
              final todayDate = TimezoneUtils.getSeoulToday();
              final reservationDate = TimezoneUtils.getSeoulDateOnly(
                reservation.reservedDate,
              );

              // 지난 예약인지 확인
              final isPast = reservationDate.isBefore(todayDate);

              return GestureDetector(
                onTap: () {
                  // 마이페이지로 이동하면서 예약 정보 전달 (명시적 클릭)
                  Navigator.of(context).pushNamedAndRemoveUntil(
                    '/main',
                    (route) => false,
                    arguments: {
                      'initialIndex': 2, // 마이페이지 탭 인덱스
                      'highlightReservation': {
                        'reservationId': reservation.id,
                        'courseId': reservation.courseId,
                        'dayOfWeek': reservation.dayOfWeek,
                        'startTime': reservation.startTime,
                        'reservedDate': reservation.reservedDate,
                        'shouldShowBottomSheet': true, // 명시적 클릭이므로 바텀시트 표시
                      },
                    },
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: _spacingMedium,
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(_spacingMedium),
                    decoration: BoxDecoration(
                      color: AppColors.backgroundWhite,
                      borderRadius: BorderRadius.circular(_cardBorderRadius),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(_cardShadowOpacity),
                          blurRadius: _cardShadowBlur,
                          offset: Offset(0, _cardElevation),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(height: 10),
                        // 상단: 시간 및 날짜 정보 (크게)
                        _buildReservationInfo(reservation),
                        const Spacer(),
                        // 하단: 코스명 칩 + 상태 칩
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            _buildCourseNameChip(course.name),
                            const SizedBox(width: _spacingSmall),
                            _buildStatusChip(isPast),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
      ),
    );
  }

  // 과목명 칩 위젯 (애플 스타일)
  Widget _buildCourseNameChip(String courseName) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: _chipHorizontalPadding + 6,
        vertical: _chipVerticalPadding,
      ),
      decoration: BoxDecoration(
        color: AppColors.backgroundLight,
        borderRadius: BorderRadius.circular(_chipBorderRadius),
      ),
      child: Text(
        courseName,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: AppColors.primaryGreen,
          letterSpacing: -0.2,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  // 상태 칩 위젯 (애플 스타일)
  Widget _buildStatusChip(bool isPast) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: _chipHorizontalPadding,
        vertical: _chipVerticalPadding,
      ),
      decoration: BoxDecoration(
        color: isPast ? AppColors.backgroundLight : AppColors.primaryGreen,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            isPast ? '완료됨' : '예정',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: isPast ? AppColors.textSecondary : Colors.white,
              letterSpacing: -0.2,
            ),
          ),
        ],
      ),
    );
  }

  // 예약 정보 위젯
  Widget _buildReservationInfo(Reservation reservation) {
    final timeText = _formatTime(reservation.startTime);
    final dateText =
        '${_formatDate(reservation.reservedDate)} ${_getDayName(reservation.dayOfWeek)}요일';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 시간 (크게)
        Text(
          timeText,
          style: GoogleFonts.lato(
            fontSize: 34,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),

        // 날짜 (크게)
        Text(
          dateText,
          style: TextStyle(
            fontSize: _dateFontSize,
            fontWeight: FontWeight.w500,
            color: AppColors.textSecondary.withOpacity(0.9),
          ),
        ),
      ],
    );
  }

  // 시간 포맷팅 (AM/PM 제거)
  String _formatTime(String startTime) {
    // startTime이 "9" 또는 "9 AM" 형식일 수 있으므로 처리
    final timeStr = startTime.trim();

    // "AM" 또는 "PM" 제거
    final cleanedTime = timeStr.trim();

    // 숫자만 있는 경우 ":00" 추가
    final hour = int.tryParse(cleanedTime);
    if (hour != null) {
      return '$hour:00';
    }

    // 이미 ":"가 포함되어 있으면 그대로 반환
    if (cleanedTime.contains(':')) {
      return cleanedTime;
    }

    // 파싱 실패 시 원본 반환
    return cleanedTime;
  }

  // Helper 메서드들
  String _formatStoryDate(DateTime date) {
    return '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';
  }
}
