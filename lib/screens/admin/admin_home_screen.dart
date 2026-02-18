import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../theme/app_colors.dart';
import '../../widgets/story_card.dart';
import '../../widgets/place_switch_widget.dart'
    show PlaceSwitchWidget, navigateToPlaceWaitingScreen;
import '../../widgets/compact_calendar_widget.dart';
import '../../widgets/week_tab_bar.dart';
import '../../widgets/notification_icon_widget.dart';
import 'widgets/session_detail_screen.dart';
import 'widgets/story_add_screen.dart';
import 'widgets/course_add_flow.dart';
import 'widgets/weekly_override_schedule_screen.dart';
import 'widgets/empty_state_card.dart';
import '../../providers/place_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/course_provider.dart';
import '../../models/story.dart';
import '../../providers/story_provider.dart';
import '../../models/course.dart';
import '../../services/firestore_service.dart';
import '../../utils/week_range_calculator.dart';
import '../../utils/local_storage_util.dart';
import '../../utils/timezone_utils.dart';
import '../../utils/reservation_policy_engine.dart';
import '../../models/course_policy.dart';

class AdminHomeScreen extends StatefulWidget {
  const AdminHomeScreen({super.key});

  @override
  State<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _AdminHomeScreenState extends State<AdminHomeScreen>
    with AutomaticKeepAliveClientMixin {
  int _selectedTab = 0; // 0: 스토리, 1: 프로모션
  int _selectedWeekTab = 0; // 0: 이번주, 1: 다음주, 2: 다다음주
  int _storyPageIndex = 0;

  // 캘린더 관련
  final GlobalKey _calendarKey = GlobalKey();
  Course? _selectedCourse; // 선택된 코스

  // 데이터 로드 완료 플래그 (플레이스별로 관리)
  String? _loadedPlaceId;

  // 정책 기반 주차 범위
  final FirestoreService _firestoreService = FirestoreService();
  List<int> _availableWeekOffsets = [0, 1, 2]; // 기본값: 이번주, 다음주, 다다음주
  CoursePolicy? _currentCoursePolicy; // 현재 코스의 정책
  String? _bookingWeekOpensPlaceId;
  String? _bookingWeekOpensCourseId;
  Set<String> _lastOpenedWeekStartDates = {};

  @override
  bool get wantKeepAlive => true; // 상태 유지 활성화

  @override
  void initState() {
    super.initState();
    // 빌드 완료 후 데이터 로드 (setState during build 에러 방지)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadDataIfNeeded();
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  /// 데이터가 로드되지 않았으면 로드
  Future<void> _loadDataIfNeeded() async {
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final storyProvider = Provider.of<StoryProvider>(context, listen: false);

    final currentPlace = placeProvider.currentPlace;
    if (currentPlace == null) return;

    // 이미 현재 플레이스의 데이터를 로드했으면 다시 로드하지 않음
    if (_loadedPlaceId == currentPlace.id) return;

    try {
      // StoryProvider에서 중복 로드 방지하므로 항상 호출해도 됨
      await Future.wait([
        courseProvider.loadCourses(currentPlace.id),
        storyProvider.loadStories(currentPlace.id),
      ]);

      // 비정기 일정 구독 시작 (현재 주차 포함)
      final now = TimezoneUtils.getSeoulDateTime();
      final daysFromMonday = now.weekday - 1;
      final thisWeekMonday = now.subtract(Duration(days: daysFromMonday));
      final weekStartDates = List.generate(3, (i) {
        final weekStart = thisWeekMonday.add(Duration(days: 7 * i));
        return TimezoneUtils.formatDateToSeoul(weekStart);
      });
      courseProvider.subscribeToOverrides(currentPlace.id, weekStartDates);

      // 저장된 마지막 선택 코스 또는 첫 번째 코스의 정책 기반 주차 범위 계산
      if (courseProvider.courses.isNotEmpty) {
        Course? initialCourse;
        try {
          // 저장된 마지막 선택 코스 ID 가져오기
          final storageService = StorageService();
          final lastCourseId = await storageService.getLastSelectedCourseId(
            currentPlace.id,
            scope: StorageService.scopeAdmin,
          );

          if (lastCourseId != null) {
            // 저장된 코스가 현재 코스 목록에 있는지 확인
            initialCourse = courseProvider.courses.firstWhere(
              (course) => course.id == lastCourseId,
              orElse: () => courseProvider.courses.first,
            );
          } else {
            // 저장된 코스가 없으면 첫 번째 코스 선택
            initialCourse = courseProvider.courses.first;
          }
        } catch (_) {
          // 에러 발생 시 첫 번째 코스 선택
          initialCourse = courseProvider.courses.first;
        }

        // 초기 코스의 정책에 따라 주차 범위 설정
        await _calculateWeekOffsetsForCourse(initialCourse, currentPlace.id);
        // 미리 열린 주차 구독 시작
        _subscribeBookingWeekOpens(initialCourse, currentPlace.id);
      } else {
        setState(() => _availableWeekOffsets = [0, 1, 2]);
      }

      // 데이터 로드 완료 표시
      if (mounted) {
        setState(() {
          _loadedPlaceId = currentPlace.id;
        });
      }
    } catch (e) {
      // 에러 발생 시에도 계속 진행
      debugPrint('스토리 로드 실패: $e');
    }
  }

  /// 선택된 코스의 정책을 확인하여 주차 범위 계산
  Future<void> _calculateWeekOffsetsForCourse(
    Course? course,
    String placeId,
  ) async {
    if (course == null) {
      setState(() {
        _availableWeekOffsets = [0, 1, 2];
        _currentCoursePolicy = null;
      });
      return;
    }

    try {
      final policy = await _firestoreService.getCoursePolicy(
        courseId: course.id,
        placeId: placeId,
      );
      _currentCoursePolicy = policy;
      _updateAvailableWeekOffsets(
        policy,
        placeId: placeId,
        courseId: course.id,
      );
    } catch (_) {
      // 정책 로드 실패 시 기본값 사용
      if (mounted) {
        setState(() {
          _availableWeekOffsets = [0, 1, 2];
          _currentCoursePolicy = null;
        });
      }
    }
  }

  /// 정책 기반 주차 범위 계산 (미리 열린 주차 포함)
  void _updateAvailableWeekOffsets(
    CoursePolicy? policy, {
    String? placeId,
    String? courseId,
  }) {
    if (policy == null) {
      setState(() => _availableWeekOffsets = [0, 1, 2]);
      return;
    }

    final openedWeekStartDates =
        (placeId != null && courseId != null)
            ? Provider.of<CourseProvider>(
              context,
              listen: false,
            ).getBookingWeekOpens(placeId, courseId)
            : <String>{};

    // 정책 기반 기본 주차 범위
    final baseOffsets = WeekRangeCalculator.getAvailableWeekOffsets(policy);
    final now = TimezoneUtils.getSeoulDateTime();
    final daysFromMonday = now.weekday - 1;
    final thisWeekMonday = now.subtract(Duration(days: daysFromMonday));

    // 미리 열린 주차의 weekOffset 계산 (관리자가 "미리 예약 열기"로 연 주)
    final openedOffsets = <int>{};
    for (final weekStartDateStr in openedWeekStartDates) {
      try {
        final parts = weekStartDateStr.split('-');
        final weekStartDate = DateTime(
          int.parse(parts[0]),
          int.parse(parts[1]),
          int.parse(parts[2]),
        );
        final diffDays = weekStartDate.difference(thisWeekMonday).inDays;
        final weekOffset = (diffDays / 7).round();
        if (weekOffset >= 0) {
          openedOffsets.add(weekOffset);
        }
      } catch (_) {
        // 날짜 파싱 실패 시 스킵
      }
    }

    // 정책상 "지금 시점에 실제로 열린" 주차만 탭에 표시 (잠긴 주차 제거)
    // - 미리 열린 주차(bookingWeekOpens)는 항상 포함
    // - weeklyRelease: 해당 주의 오픈 시각(release)이 지났을 때만 포함
    // - rollingWindow: baseOffsets 그대로 사용
    final actuallyOpenedOffsets = <int>{};
    if (policy.openStrategy.type == BookingOpenStrategyType.weeklyRelease) {
      for (final offset in baseOffsets) {
        if (openedOffsets.contains(offset)) {
          actuallyOpenedOffsets.add(offset);
          continue;
        }
        final weekMonday = thisWeekMonday.add(Duration(days: 7 * offset));
        final eligibility = ReservationPolicyEngine.evaluateReservation(
          now: now,
          policy: policy,
          sessionDate: weekMonday,
          startTime: '09:00',
          capacity: 1,
          reservedCount: 0,
          enrollmentCanReserve: true,
        );
        if (eligibility.reason != ReservationLockReason.notOpenedYet) {
          actuallyOpenedOffsets.add(offset);
        }
      }
    } else {
      actuallyOpenedOffsets.addAll(baseOffsets);
    }
    actuallyOpenedOffsets.addAll(openedOffsets);

    final sortedOffsets = actuallyOpenedOffsets.toList()..sort();
    final finalOffsets =
        sortedOffsets.isEmpty ? <int>[0] : sortedOffsets;

    if (mounted) {
      setState(() {
        _availableWeekOffsets = finalOffsets;
        // 선택된 탭이 범위를 벗어나면 조정
        if (_selectedWeekTab >= _availableWeekOffsets.length) {
          _selectedWeekTab = _availableWeekOffsets.length - 1;
        }
      });
    }
  }

  /// 미리 열린 주차 구독 (CourseProvider에서 단일 구독 공유)
  void _subscribeBookingWeekOpens(Course? course, String placeId) {
    if (course == null) return;
    _bookingWeekOpensPlaceId = placeId;
    _bookingWeekOpensCourseId = course.id;
    Provider.of<CourseProvider>(
      context,
      listen: false,
    ).subscribeToBookingWeekOpens(placeId, course.id);
    if (_currentCoursePolicy != null) {
      _updateAvailableWeekOffsets(
        _currentCoursePolicy,
        placeId: placeId,
        courseId: course.id,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin을 위해 필요
    final courseProvider = context.watch<CourseProvider>();
    if (_currentCoursePolicy != null &&
        _bookingWeekOpensPlaceId != null &&
        _bookingWeekOpensCourseId != null) {
      final currentOpened = courseProvider.getBookingWeekOpens(
        _bookingWeekOpensPlaceId!,
        _bookingWeekOpensCourseId!,
      );
      final openedChanged =
          currentOpened.length != _lastOpenedWeekStartDates.length ||
          currentOpened.any((e) => !_lastOpenedWeekStartDates.contains(e));
      if (openedChanged) {
        _lastOpenedWeekStartDates = Set.from(currentOpened);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _updateAvailableWeekOffsets(
            _currentCoursePolicy,
            placeId: _bookingWeekOpensPlaceId,
            courseId: _bookingWeekOpensCourseId,
          );
        });
      }
    }

    // 플레이스 변경 감지하여 데이터 다시 로드
    final placeProvider = Provider.of<PlaceProvider>(context);
    final currentPlaceId = placeProvider.currentPlace?.id;
    if (currentPlaceId != null && _loadedPlaceId != currentPlaceId) {
      // 플레이스가 변경되었으면 로드 플래그 리셋
      _loadedPlaceId = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadDataIfNeeded();
      });
    }

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      body: Column(
        children: [
          // 메인 콘텐츠
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildPlacesSection(context),
                  const SizedBox(height: 36),

                  WeekTabBar(
                    showDot: true,
                    selectedIndex: _selectedWeekTab,
                    onTabChanged: (index) {
                      setState(() {
                        _selectedWeekTab = index;
                      });
                    },
                    availableWeekOffsets: _availableWeekOffsets,
                    trailing: Consumer2<CourseProvider, AuthProvider>(
                      builder: (context, courseProvider, authProvider, _) {
                        final placeId = Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id;
                        final isSubManager = placeId != null && authProvider.isSubManagerForPlace(placeId);
                        final placeMember = placeId != null ? authProvider.getPlaceMemberForPlace(placeId) : null;
                        final manageableIds = placeMember?.manageableCourseIds ?? [];
                        final hasManageableCourses = isSubManager
                            ? courseProvider.courses.any((c) => manageableIds.contains(c.id))
                            : true;
                        if (isSubManager && !hasManageableCourses) return const SizedBox.shrink();
                        final isEmpty = courseProvider.courses.isEmpty;
                        return IconButton(
                          icon:
                              isEmpty && !isSubManager
                                  ? Icon(
                                    Icons.add_circle,
                                    color: AppColors.primaryGreen,
                                    size: 34,
                                  )
                                  : Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: const BoxDecoration(
                                      color: AppColors.primaryGreen,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Icons.edit,
                                      color: Colors.white,
                                      size: 18,
                                    ),
                                  ),
                          onPressed: () {
                            if (isEmpty && !isSubManager) {
                              _showCourseAddFlow(context);
                            } else {
                              _showWeeklyOverrideSchedule(context);
                            }
                          },
                        );
                      },
                    ),
                  ),

                  const SizedBox(height: 16),

                  // 캘린더
                  _buildCalendarSection(),

                  const SizedBox(height: 52),

                  // 탭
                  _buildTabs(),

                  const SizedBox(height: 10),

                  // 탭에 따른 콘텐츠
                  _selectedTab == 0 ? _buildStoryCards() : _buildStoryCards(),

                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ],
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
            authProvider.currentManagerUser != null;
        // 로그인 안 되어 있어도 나가기 버튼 표시
        final showExitButton = place != null && (!isLoggedIn || isUnregistered);

        return Row(
          children: [
            Expanded(
              child: PlaceSwitchWidget(
                enabled: true,
                showDescription: false,
                padding: EdgeInsets.zero,
                heroTagSuffix: 'admin_home',
                isAdminContext: true,
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

  // 캘린더 섹션 (부매니저: 관리 코스만 노출)
  Widget _buildCalendarSection() {
    return Consumer3<CourseProvider, PlaceProvider, AuthProvider>(
      builder: (context, courseProvider, placeProvider, authProvider, child) {
        final placeId = placeProvider.currentPlace?.id;
        final isSubManager = placeId != null && authProvider.isSubManagerForPlace(placeId);
        final placeMember = placeId != null ? authProvider.getPlaceMemberForPlace(placeId) : null;
        final coursesForCalendar = isSubManager && placeMember != null
            ? courseProvider.courses
                .where((c) => placeMember.manageableCourseIds.contains(c.id))
                .toList()
            : courseProvider.courses;

        if (coursesForCalendar.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: EmptyStateCard(
              title: isSubManager ? '관리 중인 코스가 없어요' : '아직 코스가 없어요',
              buttonText: isSubManager ? null : '코스 추가하기',
              onPressed: isSubManager ? null : () => _showCourseAddFlow(context),
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Container(
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
            clipBehavior: Clip.antiAlias,
            child: CompactCalendarWidget(
              key: _calendarKey,
              courses: coursesForCalendar,
              usage: CompactCalendarUsage.adminNavigate,
              weekOffset: _selectedWeekTab,
              availableWeekOffsets: _availableWeekOffsets,
              height: 500,
              onSwipeToPrevWeek:
                  _availableWeekOffsets.length > 1 && _selectedWeekTab > 0
                      ? () {
                        setState(() => _selectedWeekTab--);
                      }
                      : null,
              onSwipeToNextWeek:
                  _availableWeekOffsets.length > 1 &&
                          _selectedWeekTab < _availableWeekOffsets.length - 1
                      ? () {
                        setState(() => _selectedWeekTab++);
                      }
                      : null,
              onSessionTap: (course, session, date) {
                final pid = placeProvider.currentPlace?.id;
                if (pid == null) return;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder:
                        (context) => SessionDetailScreen(
                          course: course,
                          session: session,
                          date: date,
                          placeId: pid,
                        ),
                  ),
                );
              },
              onAddCourseTap: isSubManager ? null : () => _showCourseAddFlow(context),
              onCourseSelected: (Course? course) {
                final pid = placeProvider.currentPlace?.id;
                WidgetsBinding.instance.addPostFrameCallback((_) async {
                  if (!mounted) return;
                  setState(() {
                    _selectedCourse = course;
                  });
                  if (pid != null) {
                    await _calculateWeekOffsetsForCourse(course, pid);
                    _subscribeBookingWeekOpens(course, pid);
                  }
                });
              },
            ),
          ),
        );
      },
    );
  }

  // 스토리 카드들 (스토리 탭)
  Widget _buildStoryCards() {
    final storyProvider = Provider.of<StoryProvider>(context);
    final stories = storyProvider.stories;

    if (stories.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: EmptyStateCard(
          title: '아직 스토리가 없어요',
          buttonText: '스토리 추가하기',
          onPressed: () => _showStoryAddScreen(context),
        ),
      );
    }

    // 스토리가 1개일 때와 2개 이상일 때 다른 레이아웃
    if (stories.length == 1) {
      // 1개일 때: 화면 너비를 거의 다 채워서 표시 (왼쪽만 패딩)
      return SizedBox(
        height: 300,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _buildEditableStoryCard(stories[0], 0),
        ),
      );
    } else {
      // 2개 이상일 때: 옆 카드가 살짝 보이게
      return SizedBox(
        height: 300,
        child: PageView.builder(
          padEnds: false,
          controller: PageController(
            initialPage: _storyPageIndex,
            viewportFraction: 0.92, // 카드가 화면의 92%를 차지하여 옆 카드가 보이게
          ),
          onPageChanged: (index) {
            setState(() {
              _storyPageIndex = index;
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
              child: _buildEditableStoryCard(stories[index], index),
            );
          },
        ),
      );
    }
  }

  // 편집 가능한 스토리 카드
  Widget _buildEditableStoryCard(Story story, int index) {
    return StoryCard(
      title: story.title,
      content: story.content,
      date: _formatDate(story.createdAt),
      imageUrls: story.imageUrls,
      backgroundImageUrl: story.backgroundImageUrl,
      onTap: () {
        final storyProvider = Provider.of<StoryProvider>(
          context,
          listen: false,
        );

        Navigator.of(context).push(
          MaterialPageRoute(
            builder:
                (context) => StoryAddScreen(
                  existingStory: _storyToStoryData(story),
                  onSave: (StoryData updatedStory) async {
                    final updated = Story(
                      id: story.id,
                      placeId: story.placeId,
                      title: updatedStory.title,
                      content: updatedStory.content,
                      createdAt: story.createdAt,
                      imageUrls: updatedStory.imageUrls,
                      backgroundImageUrl: updatedStory.backgroundImageUrl,
                    );
                    await storyProvider.updateStory(updated);
                  },
                  onDelete: () async {
                    await storyProvider.deleteStory(story.placeId, story.id);
                  },
                ),
          ),
        );
      },
    );
  }

  // 코스 등록 플로우 표시
  void _showCourseAddFlow(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (context) => CourseAddFlow(
              onComplete: (course) {
                // CourseAddFlow 내부에서 정책 설정 및 최종 등록 처리
                // 여기서는 아무것도 하지 않음
              },
            ),
      ),
    );
  }

  // 비정기 일정 편집 화면 표시 (부매니저: 관리 코스만 전달)
  Future<void> _showWeeklyOverrideSchedule(BuildContext context) async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final placeId = placeProvider.currentPlace?.id;
    final isSubManager = placeId != null && authProvider.isSubManagerForPlace(placeId);
    final placeMember = placeId != null ? authProvider.getPlaceMemberForPlace(placeId) : null;
    final allowedCourseIds = isSubManager && placeMember != null
        ? placeMember.manageableCourseIds
        : null;

    final result = await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (context) => WeeklyOverrideScheduleScreen(
              weekOffset: _selectedWeekTab,
              selectedCourseId: _selectedCourse?.id,
              allowedCourseIds: allowedCourseIds,
            ),
      ),
    );

    // 저장 성공 시 데이터 다시 로드
    if (result == true && mounted) {
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final courseProvider = Provider.of<CourseProvider>(
        context,
        listen: false,
      );
      final currentPlace = placeProvider.currentPlace;

      if (currentPlace != null) {
        // 코스 데이터 다시 로드하여 비정기 일정 반영
        await courseProvider.loadCourses(currentPlace.id);

        // 현재 주차 비정기 일정 즉시 새로고침 (스트림 수신 전 UI 반영)
        final now = TimezoneUtils.getSeoulDateTime();
        final daysFromMonday = now.weekday - 1;
        final thisWeekMonday = now.subtract(Duration(days: daysFromMonday));
        final currentWeekStart = thisWeekMonday.add(
          Duration(days: 7 * _selectedWeekTab),
        );
        final weekStartDate = TimezoneUtils.formatDateToSeoul(currentWeekStart);
        await courseProvider.refreshOverridesForWeek(
          currentPlace.id,
          weekStartDate,
        );

        // 비정기 일정 구독 시작 (현재 주차 포함)
        final weekStartDates = List.generate(3, (i) {
          final weekStart = thisWeekMonday.add(Duration(days: 7 * i));
          return TimezoneUtils.formatDateToSeoul(weekStart);
        });
        courseProvider.subscribeToOverrides(currentPlace.id, weekStartDates);

        // 캘린더 위젯 강제 리빌드 및 뷰포트 업데이트
        setState(() {
          // 상태 변경으로 캘린더가 다시 빌드되도록 함
        });
      }
    }
  }

  // 스토리 추가 화면 표시
  void _showStoryAddScreen(BuildContext context) {
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final storyProvider = Provider.of<StoryProvider>(context, listen: false);
    final currentPlace = placeProvider.currentPlace;

    if (currentPlace == null) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (context) => StoryAddScreen(
              existingStory: null,
              onSave: (StoryData storyData) async {
                await storyProvider.createStory(
                  placeId: currentPlace.id,
                  title: storyData.title,
                  content: storyData.content,
                  imageUrls: storyData.imageUrls,
                  backgroundImageUrl: storyData.backgroundImageUrl,
                );
              },
            ),
      ),
    );
  }

  // 탭
  Widget _buildTabs() {
    final storyProvider = Provider.of<StoryProvider>(context);
    final stories = storyProvider.stories;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          // 스토리가 없으면 "스토리" 텍스트, 있으면 점 인디케이터 표시
          if (stories.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8.0, left: 4),
              child: Text(
                '스토리',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
            )
          else
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
                          _storyPageIndex == index
                              ? AppColors.primaryGreen
                              : AppColors.primaryGreen.withOpacity(0.3),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),

          Spacer(),
          IconButton(
            icon: Icon(
              Icons.add_circle,
              color: AppColors.primaryGreen,
              size: 34,
            ),
            onPressed: () => _showStoryAddScreen(context),
          ),
        ],
      ),
    );
  }

  // Helper 메서드들
  String _formatDate(DateTime date) {
    return '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';
  }

  StoryData _storyToStoryData(Story story) {
    return StoryData(
      title: story.title,
      content: story.content,
      date: _formatDate(story.createdAt),
      imageUrls: story.imageUrls,
      backgroundImageUrl: story.backgroundImageUrl,
    );
  }
}
