import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_colors.dart';
import '../widgets/story_card.dart';
import '../models/reservation.dart';
import '../models/course.dart';
import '../providers/place_provider.dart';
import '../providers/reservation_provider.dart';
import '../providers/story_provider.dart' show StoryProvider;
import '../providers/promotion_provider.dart' show PromotionProvider;
import '../providers/auth_provider.dart';
import '../providers/course_provider.dart';
import '../providers/enrollment_provider.dart';
import '../utils/timezone_utils.dart';
import '../widgets/place_switch_widget.dart';
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
    final promotionProvider = Provider.of<PromotionProvider>(
      context,
      listen: false,
    );
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
      if (promotionProvider.promotions.isEmpty) {
        await promotionProvider.loadPromotions(currentPlace.id);
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
    // reservedAt 기준으로 정렬 (최신순)
    final sortedReservations = List<Reservation>.from(reservations)
      ..sort((a, b) => b.reservedAt.compareTo(a.reservedAt));

    // 최대 5개만 가져오기
    final recentReservations = sortedReservations.take(5).toList();

    // 코스 정보와 함께 매핑
    return recentReservations.map((reservation) {
      final course = courses.firstWhere(
        (c) => c.id == reservation.courseId,
        orElse: () => Course(
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
    final authProvider = Provider.of<AuthProvider>(context);

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

              const SizedBox(height: 20),

              // 탭
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
                        position:
                            Tween<Offset>(
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

              const SizedBox(height: 42),

              // 최근 이용 섹션
              if (authProvider.currentUser != null) _buildRecentUsageSection(),

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlacesSection(BuildContext context) {
    return Row(
      children: [
        // PlaceSwitchWidget
        Expanded(
          child: PlaceSwitchWidget(
            enabled: false,
            showDescription: false,
            padding: EdgeInsets.zero,
          ),
        ),
        // 알림 아이콘
        const SizedBox(width: 12),
        NotificationIconWidget(),
        const SizedBox(width: 20),
      ],
    );
  }

  // 제목 섹션
  Widget _buildTitleSection(PlaceProvider placeProvider) {
    final place = placeProvider.currentPlace;
    final greetingText = place?.greetingText ?? '안녕하세요,\n리퀘스트를 추천해 드려요';
    final highlightedText = place?.highlightedText;
    final highlightColor = place?.highlightColorValue != null
        ? Color(place!.highlightColorValue!)
        : AppColors.primaryGreen.withOpacity(0.3);

    // 형광펜 효과가 있는 경우
    if (highlightedText != null && highlightedText.isNotEmpty) {
      final parts = greetingText.split(highlightedText);
      if (parts.length == 2) {
        // 형광펜으로 강조할 텍스트가 있는 경우
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: parts[0],
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                WidgetSpan(
                  child: Container(
                    decoration: BoxDecoration(
                      color: highlightColor,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    child: Text(
                      highlightedText,
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ),
                TextSpan(
                  text: parts[1],
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        );
      }
    }

    // 형광펜 효과가 없는 경우 기본 텍스트
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
                      '#',
                      style: TextStyle(
                        fontSize: 35,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primaryGreen,
                      ),
                    ),
                    Text(
                      '아직 스토리가 없어요',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w400,
                        color: AppColors.textPrimary,
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
                    Icon(
                      Icons.notifications_outlined,
                      size: 48,
                      color: AppColors.textSecondary.withOpacity(0.5),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '새로운 스토리를\n기다리고 있어요',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textSecondary,
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
          padding: const EdgeInsets.only(left: 16),
          child: StoryCard(
            title: stories[0].title,
            content: stories[0].content,
            date: _formatStoryDate(stories[0].createdAt),
            imageUrls: stories[0].imageUrls,
            backgroundImageUrl: stories[0].backgroundImageUrl,
            placeName: currentPlace?.name,
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
                      color: _currentStoryIndex == index
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

    if (authProvider.currentUser == null) {
      return const SizedBox.shrink();
    }

    final reservations = reservationProvider.reservations;
    final courses = courseProvider.courses;
    final allReservations = _getRecentReservations(reservations, courses);
    final totalCount = allReservations.length;
    final currentIndex = totalCount > 0
        ? _currentReservationPage + 1
        : 0; // 현재 보고 있는 카드 인덱스 (1부터 시작)

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
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
                          color: index == currentIndex - 1
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
    final enrollmentProvider = Provider.of<EnrollmentProvider>(context);
    final authProvider = Provider.of<AuthProvider>(context);

    if (authProvider.currentUser == null) {
      return const SizedBox.shrink();
    }

    final reservations = reservationProvider.reservations;
    final courses = courseProvider.courses;
    final enrollmentsByCourseId = enrollmentProvider.enrollmentsByCourseId;
    final recentReservations = _getRecentReservations(reservations, courses);

    if (recentReservations.isEmpty) {
      return SizedBox(
        height: 250,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 4),
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
      height: 280,
      child: PageView(
        controller: _reservationPageController,
        onPageChanged: (index) {
          setState(() {
            _currentReservationPage = index;
          });
        },

        children: recentReservations.map((data) {
          final reservation = data['reservation'] as Reservation;
          final course = data['course'] as Course;

          // 오늘 날짜 (시간 제외)
          final today = TimezoneUtils.getSeoulDateTime();
          final todayDate = DateTime(today.year, today.month, today.day);
          final reservationDate = DateTime(
            reservation.reservedDate.year,
            reservation.reservedDate.month,
            reservation.reservedDate.day,
          );

          // 지난 예약인지 확인
          final isPast = reservationDate.isBefore(todayDate);

          final titleColor = isPast
              ? AppColors.textSecondary
              : AppColors.textPrimary;

          // 해당 코스의 enrollment 정보 조회 (최적화: Map 조회)
          final enrollment = enrollmentsByCourseId[reservation.courseId];
          final hasEnrollment = enrollment != null && enrollment.isValid;
          final remainingCount = enrollment?.remainingReservations ?? 0;
          final totalCount = enrollment?.totalReservations ?? 0;
          final progressValue = totalCount > 0
              ? (remainingCount / totalCount).clamp(0.0, 1.0)
              : 0.0;

          return GestureDetector(
            onTap: () {
              // 마이페이지로 이동하면서 예약 정보 전달
              Navigator.of(context).pushNamedAndRemoveUntil(
                '/main',
                (route) => false,
                arguments: {
                  'initialIndex': 2, // 마이페이지 탭 인덱스 (0: 홈, 1: 예약, 2: 마이페이지)
                  'highlightReservation': {
                    'reservationId': reservation.id,
                    'courseId': reservation.courseId,
                    'dayOfWeek': reservation.dayOfWeek,
                    'startTime': reservation.startTime,
                    'reservedDate': reservation.reservedDate,
                  },
                },
              );
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.backgroundWhite,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text(
                          course.name,
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: titleColor,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Spacer(),
                        Icon(
                          Icons.arrow_forward_ios,
                          size: 16,
                          color: AppColors.textSecondary,
                        ),
                        SizedBox(width: 4),
                      ],
                    ), // 칩 (방문 전 / 완료됨)
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isPast
                            ? Colors.transparent
                            : AppColors.primaryGreen,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isPast
                              ? AppColors.textSecondary
                              : AppColors.primaryGreen,
                          width: 1,
                        ),
                      ),
                      child: Text(
                        isPast ? '완료됨' : '방문 전',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isPast
                              ? AppColors.textSecondary
                              : Colors.white,
                        ),
                      ),
                    ),

                    Spacer(),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${reservation.startTime} AM ',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w500,
                            color: AppColors.textSecondary,
                          ),
                        ),

                        // 남은 횟수 정보
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_formatDate(reservation.reservedDate)} ${_getDayName(reservation.dayOfWeek)}요일',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w500,
                                color: AppColors.textSecondary,
                              ),
                            ),
                            SizedBox(height: 12),

                            // 게이지 바와 횟수 (enrollment 정보가 있을 때만 표시)
                            if (hasEnrollment)
                              Row(
                                children: [
                                  Expanded(
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: LinearProgressIndicator(
                                        value: progressValue,
                                        minHeight: 20,
                                        backgroundColor:
                                            AppColors.backgroundLight,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                              isPast
                                                  ? AppColors.textSecondary
                                                  : AppColors.primaryGreen,
                                            ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    '$remainingCount / $totalCount',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: isPast
                                          ? AppColors.textSecondary
                                          : AppColors.primaryGreen,
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
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

  // Helper 메서드들
  String _formatStoryDate(DateTime date) {
    return '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';
  }
}
