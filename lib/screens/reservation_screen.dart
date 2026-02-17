import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_colors.dart';
import '../models/course.dart';
import 'admin/widgets/calendar_screen.dart';
import '../providers/place_provider.dart';
import '../providers/course_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/enrollment_provider.dart';
import '../providers/reservation_provider.dart';
import '../providers/reservation_summary_provider.dart';
import '../models/course_override.dart';
import '../utils/calendar_utils.dart';
import '../utils/session_slot_builder.dart';
import '../utils/timezone_utils.dart';
import '../widgets/cached_image_widget.dart';
import '../utils/local_storage_util.dart';
import '../utils/snackbar_util.dart';

class ReservationScreen extends StatefulWidget {
  final Map<String, dynamic>? highlightNewSession;
  final VoidCallback? onHighlightConsumed;

  const ReservationScreen({
    super.key,
    this.highlightNewSession,
    this.onHighlightConsumed,
  });

  @override
  State<ReservationScreen> createState() => _ReservationScreenState();
}

class _ReservationScreenState extends State<ReservationScreen> {
  String selectedTime = '12시';
  String selectedSeat = '전체 좌석';
  final TextEditingController _searchController = TextEditingController();
  final StorageService _storageService = StorageService();
  Set<String> _favoriteCourses = {};
  String? _loadingCourseId; // 예약하기 클릭 시 해당 코스 로딩 중

  @override
  void initState() {
    super.initState();
    // 빌드 완료 후 데이터 로드 (setState during build 에러 방지)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadDataIfNeeded().then((_) {
        _tryOpenCalendarForHighlight();
      });
      _loadFavorites();
    });
  }

  @override
  void didUpdateWidget(ReservationScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.highlightNewSession != null &&
        widget.highlightNewSession != oldWidget.highlightNewSession) {
      _tryOpenCalendarForHighlight();
    }
  }

  void _tryOpenCalendarForHighlight() {
    final highlight = widget.highlightNewSession;
    if (highlight == null || widget.onHighlightConsumed == null) return;
    final courseId = highlight['courseId'] as String?;
    final placeId = highlight['placeId'] as String?;
    if (courseId == null || placeId == null) return;

    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final currentPlace = placeProvider.currentPlace;
    if (currentPlace?.id != placeId) return;

    final course = courseProvider.getCourse(courseId);
    if (course == null) return;

    widget.onHighlightConsumed!();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (context) =>
                CalendarScreen(course: course, highlightSession: highlight),
      ),
    );
  }

  /// 즐겨찾기 목록 로드
  Future<void> _loadFavorites() async {
    final favorites = await _storageService.getFavoriteCourses();
    if (mounted) {
      setState(() {
        _favoriteCourses = favorites.toSet();
      });
    }
  }

  /// 즐겨찾기 토글
  Future<void> _toggleFavorite(String courseId) async {
    final wasFavorite = _favoriteCourses.contains(courseId);
    await _storageService.toggleFavoriteCourse(courseId);
    if (mounted) {
      setState(() {
        if (wasFavorite) {
          _favoriteCourses.remove(courseId);
        } else {
          _favoriteCourses.add(courseId);
        }
      });

      try {
        // 스낵바 표시
        if (wasFavorite) {
          SnackbarUtil.showInfo(context, '즐겨찾기에서 제거되었습니다');
        } else {
          SnackbarUtil.showSuccess(context, '즐겨찾기에 추가되었습니다');
        }
      } catch (e) {
        // 코스를 찾을 수 없는 경우
        if (wasFavorite) {
          SnackbarUtil.showInfo(context, '즐겨찾기에서 제거되었습니다');
        } else {
          SnackbarUtil.showSuccess(context, '즐겨찾기에 추가되었습니다');
        }
      }
    }
  }

  /// 데이터가 로드되지 않았으면 로드
  Future<void> _loadDataIfNeeded() async {
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final enrollmentProvider = Provider.of<EnrollmentProvider>(
      context,
      listen: false,
    );
    final reservationProvider = Provider.of<ReservationProvider>(
      context,
      listen: false,
    );

    // PlaceProvider에 현재 플레이스가 있는지 확인
    final currentPlace = placeProvider.currentPlace;
    if (currentPlace == null) return;

    try {
      // 코스 로드 (정기일정·요일 변경 반영을 위해 화면 진입 시마다 최신 목록 갱신)
      await courseProvider.loadCourses(currentPlace.id, forceRefresh: true);

      // enrollment 로드 (정렬/예약 버튼 활성화에 사용)
      final userId = authProvider.currentUser?.userId;
      if (userId != null) {
        // ✅ "예약 가능 여부"는 enrollment(남은 횟수/유효기간) + reservation(이미 예약 여부)
        // 두 스트림이 동시에 최신이어야 UI가 틀어지지 않는다.
        // Provider 내부에서 (userId/placeId 동일 시) 중복 구독을 방지하므로 항상 호출해도 안전.
        await reservationProvider.loadUserReservations(
          userId: userId,
          placeId: currentPlace.id,
        );
        await enrollmentProvider.loadUserEnrollments(
          userId: userId,
          placeId: currentPlace.id,
        );
      }
    } catch (e) {
      // 에러 발생 시에도 계속 진행
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // 필터링된 코스 목록
  List<Course> filteredCourses(
    List<Course> courses, {
    required Map<String, dynamic> enrollmentsByCourseId,
  }) {
    final searchQuery = _searchController.text.trim().toLowerCase();
    List<Course> filtered;

    if (searchQuery.isEmpty) {
      // unmodifiable list를 수정 가능한 리스트로 복사
      filtered = List.from(courses);
    } else {
      filtered =
          courses
              .where(
                (course) => course.name.toLowerCase().contains(searchQuery),
              )
              .toList();
    }

    // 정렬 우선순위:
    // 1) 즐겨찾기
    // 2) 등록한 코스(enrollment 존재)
    filtered.sort((a, b) {
      final aIsFavorite = _favoriteCourses.contains(a.id);
      final bIsFavorite = _favoriteCourses.contains(b.id);

      if (aIsFavorite && !bIsFavorite) return -1;
      if (!aIsFavorite && bIsFavorite) return 1;

      final aIsEnrolled = enrollmentsByCourseId.containsKey(a.id);
      final bIsEnrolled = enrollmentsByCourseId.containsKey(b.id);
      if (aIsEnrolled && !bIsEnrolled) return -1;
      if (!aIsEnrolled && bIsEnrolled) return 1;

      // tie-breaker: 이름 기준(정렬 안정성 확보)
      return a.name.compareTo(b.name);
    });

    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    final courseProvider = Provider.of<CourseProvider>(context);
    final enrollmentProvider = Provider.of<EnrollmentProvider>(context);
    final filtered = filteredCourses(
      courseProvider.courses,
      enrollmentsByCourseId: enrollmentProvider.enrollmentsByCourseId,
    );

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      body: SafeArea(
        child: Column(
          children: [
            // 코스 리스트
            Expanded(child: _buildCourseList(filtered)),
          ],
        ),
      ),
    );
  }

  // 코스 리스트 목록
  Widget _buildCourseList(List<Course> courses) {
    // 코스가 없는 경우 빈 상태 UI 표시
    if (courses.isEmpty) {
      return _buildEmptyState();
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      itemCount: courses.length,
      itemBuilder: (context, index) {
        final course = courses[index];
        return _buildCourseCard(course);
      },
    );
  }

  // 빈 상태 UI
  Widget _buildEmptyState() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      itemCount: 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Container(
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: AppColors.backgroundWhite,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 헤더
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.backgroundLight,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(16),
                    ),
                  ),
                  child: Text(
                    '개설된 코스가 없습니다',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),

                // 빈 캘린더 영역
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    height: 200,
                    child: Center(
                      child: Text(
                        '관리자가 코스를 등록하지 않았어요',
                        style: TextStyle(
                          fontSize: 16,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  // 코스 카드
  Widget _buildCourseCard(Course course) {
    final courseColor = course.colorValue;
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final currentPlace = placeProvider.currentPlace;
    final isFavorite = _favoriteCourses.contains(course.id);
    final enrollmentProvider = Provider.of<EnrollmentProvider>(
      context,
      listen: false,
    );
    final isEnrolled = enrollmentProvider.enrollmentsByCourseId.containsKey(
      course.id,
    );

    void openCalendar() async {
      if (_loadingCourseId != null) return;
      final placeId = currentPlace?.id;
      if (placeId == null || placeId.isEmpty) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => CalendarScreen(course: course),
          ),
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

        // summary_provider 초기화 대기 (스트림 emit 또는 타임아웃)
        const timeout = Duration(seconds: 5);
        final deadline = DateTime.now().add(timeout);
        while (summaryProvider.isLoading && DateTime.now().isBefore(deadline)) {
          await Future.delayed(const Duration(milliseconds: 50));
          if (!mounted) return;
        }
      } catch (_) {
        // 실패해도 화면 이동
      } finally {
        if (mounted) {
          setState(() => _loadingCourseId = null);
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => CalendarScreen(course: course),
            ),
          );
        }
      }
    }

    final isLoadingButton = _loadingCourseId == course.id;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: openCalendar, // ✅ 카드 전체 탭으로도 예약 화면 이동
        child: Container(
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: AppColors.backgroundWhite,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 상단: 플레이스 정보
                    Row(
                      children: [
                        // 플레이스 로고 + 이름
                        Expanded(
                          child: Row(
                            children: [
                              // 원형 로고 (과목 이미지 우선, 없으면 플레이스 이미지) - 이중 테두리
                              Container(
                                width: 80,
                                height: 80,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: AppColors.textSecondary.withOpacity(
                                      0.25,
                                    ),
                                    width: 2,
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: AppColors.backgroundLight,
                                      shape: BoxShape.circle,
                                    ),
                                    child: ClipOval(
                                      child: () {
                                        if (course.imageUrl != null &&
                                            course.imageUrl!.isNotEmpty) {
                                          return CourseImageWidget(
                                            imageUrl: course.imageUrl!,
                                            width: 80,
                                            height: 80,
                                          );
                                        }
                                        // 기본 텍스트
                                        return Container(
                                          width: 80,
                                          height: 80,
                                          decoration: BoxDecoration(
                                            color: AppColors.backgroundLight,
                                            shape: BoxShape.circle,
                                          ),
                                          child: Center(
                                            child: Text(
                                              course.name.substring(0, 1),
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 18,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        );
                                      }(),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 26),
                    // 코스명 (큰 제목)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            course.name,
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textPrimary,
                              letterSpacing: -0.5,
                              height: 1.2,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),
                          // 설명
                          if (course.description.isNotEmpty)
                            Text(
                              course.description,
                              style: TextStyle(
                                fontSize: 17,
                                color: AppColors.textPrimary.withOpacity(0.8),
                                fontWeight: FontWeight.w500,
                                letterSpacing: -0.2,
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          const SizedBox(height: 10),
                          // 하단: 요일 태그 + 예약하기 버튼
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // 왼쪽: 요일 태그
                              Expanded(
                                child: _buildDayChips(
                                  course.availableDayNames,
                                  courseColor,
                                ),
                              ),
                              const SizedBox(width: 12),
                              // 오른쪽: 예약하기 버튼 (로딩 중에도 너비 유지)
                              GestureDetector(
                                onTap: isLoadingButton ? null : openCalendar,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 26,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color:
                                        isEnrolled
                                            ? Colors.black
                                            : Colors.black12,
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: SizedBox(
                                    width: 84,
                                    height: 24,
                                    child: Center(
                                      child:
                                          isLoadingButton
                                              ? SizedBox(
                                                width: 20,
                                                height: 20,
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 2.5,
                                                  valueColor:
                                                      AlwaysStoppedAnimation<
                                                        Color
                                                      >(
                                                        isEnrolled
                                                            ? Colors.white
                                                            : AppColors
                                                                .textSecondary,
                                                      ),
                                                ),
                                              )
                                              : Text(
                                                '예약하기',
                                                style: TextStyle(
                                                  fontSize: 18,
                                                  fontWeight: FontWeight.w600,
                                                  color:
                                                      isEnrolled
                                                          ? Colors.white
                                                          : AppColors
                                                              .textSecondary,
                                                  letterSpacing: -0.2,
                                                ),
                                              ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // 오른쪽 위 하트 아이콘
              Positioned(
                top: 8,
                right: 8,
                child: GestureDetector(
                  onTap: () => _toggleFavorite(course.id),
                  child: Container(
                    padding: const EdgeInsets.all(6),

                    child: Icon(
                      isFavorite ? Icons.favorite : Icons.favorite_border,
                      size: 20,
                      color:
                          isFavorite
                              ? const Color.fromARGB(255, 255, 79, 67)
                              : AppColors.textSecondary.withOpacity(0.6),
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

  // 요일 칩 위젯 (태그 스타일)
  Widget _buildDayChips(List<String> dayNames, Color courseColor) {
    // 모든 요일(월~일)이 있으면 "매일" 표시
    const allDays = ['월', '화', '수', '목', '금', '토', '일'];
    final hasAllDays = allDays.every((day) => dayNames.contains(day));

    if (hasAllDays) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.backgroundLight,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          '매일',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.2,
          ),
        ),
      );
    }

    // 일부 요일만 있으면 태그로 표시
    return Wrap(
      spacing: 4,
      runSpacing: 8,
      children:
          dayNames.map((dayName) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.backgroundLight,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                dayName,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.2,
                ),
              ),
            );
          }).toList(),
    );
  }
}
