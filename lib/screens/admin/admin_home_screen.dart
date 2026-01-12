import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../theme/app_colors.dart';
import '../../widgets/story_card.dart';
import '../../widgets/place_switch_widget.dart';
import '../../widgets/compact_calendar_widget.dart';
import '../../widgets/week_tab_bar.dart';
import '../../widgets/notification_icon_widget.dart';
import '../../models/admin_models.dart';
import 'widgets/session_detail_screen.dart';
import 'widgets/story_add_screen.dart';
import 'widgets/course_add_flow.dart';
import '../../providers/place_provider.dart';
import '../../providers/course_provider.dart';
import '../../providers/story_provider.dart' show Story, StoryProvider;
import '../../models/course.dart';
import '../../services/firestore_service.dart';
import '../../utils/week_range_calculator.dart';

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

  // 데이터 로드 완료 플래그 (플레이스별로 관리)
  String? _loadedPlaceId;

  // 정책 기반 주차 범위
  final FirestoreService _firestoreService = FirestoreService();
  List<int> _availableWeekOffsets = [0, 1, 2]; // 기본값: 이번주, 다음주, 다다음주

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

      // 정책 기반 주차 범위 계산
      await _calculateWeekOffsets(courseProvider.courses, currentPlace.id);

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

  /// 모든 코스의 정책을 확인하여 최대 주차 범위 계산
  Future<void> _calculateWeekOffsets(
    List<Course> courses,
    String placeId,
  ) async {
    if (courses.isEmpty) {
      setState(() => _availableWeekOffsets = [0, 1, 2]);
      return;
    }

    int maxWeekOffset = 0;
    for (final course in courses) {
      try {
        final policy = await _firestoreService.getCoursePolicy(
          courseId: course.id,
          placeId: placeId,
        );
        final offsets = WeekRangeCalculator.getAvailableWeekOffsets(policy);
        if (offsets.isNotEmpty) {
          final max = offsets.reduce((a, b) => a > b ? a : b);
          if (max > maxWeekOffset) maxWeekOffset = max;
        }
      } catch (_) {
        // 정책 로드 실패 시 기본값 사용
      }
    }

    // 최대 주차 범위로 리스트 생성 (최소 3개, 최대 8개)
    final maxWeeks = (maxWeekOffset + 1).clamp(3, 8);
    if (mounted) {
      setState(() {
        _availableWeekOffsets = List.generate(maxWeeks, (i) => i);
        // 선택된 탭이 범위를 벗어나면 조정
        if (_selectedWeekTab >= _availableWeekOffsets.length) {
          _selectedWeekTab = _availableWeekOffsets.length - 1;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin을 위해 필요

    // 플레이스 변경 감지하여 데이터 다시 로드
    final placeProvider = Provider.of<PlaceProvider>(context);
    final currentPlaceId = placeProvider.currentPlace?.id;
    if (currentPlaceId != null && _loadedPlaceId != currentPlaceId) {
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
                    trailing: IconButton(
                      icon: Icon(
                        Icons.add_circle,
                        color: AppColors.primaryGreen,
                        size: 34,
                      ),
                      onPressed: () => _showCourseAddFlow(context),
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

  // 캘린더 섹션
  Widget _buildCalendarSection() {
    // Consumer를 사용하여 CourseProvider 변경 시에만 리빌드
    return Consumer<CourseProvider>(
      builder: (context, courseProvider, child) {
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
              courses: courseProvider.courses,
              usage: CompactCalendarUsage.adminNavigate,
              weekOffset: _selectedWeekTab,
              height: 450,
              onSessionTap: (course, session, date) {
                final placeId = Provider.of<PlaceProvider>(
                  context,
                  listen: false,
                ).currentPlace?.id;
                if (placeId == null) return;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => SessionDetailScreen(
                      course: course,
                      session: session,
                      date: date,
                      placeId: placeId,
                    ),
                  ),
                );
              },
              onAddCourseTap: () => _showCourseAddFlow(context),
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
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Container(
          height: 330,
          decoration: BoxDecoration(
            color: AppColors.backgroundWhite,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '아직 스토리가 없어요',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
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
            builder: (context) => StoryAddScreen(
              existingStory: _storyToStoryData(story),
              onSave: (updatedStory) async {
                // StoryData를 Story로 변환하여 업데이트
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
                await storyProvider.deleteStory(story.id);
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
        builder: (context) => CourseAddFlow(
          onComplete: (course) {
            // CourseAddFlow 내부에서 정책 설정 및 최종 등록 처리
            // 여기서는 아무것도 하지 않음
          },
        ),
      ),
    );
  }

  // 스토리 추가 화면 표시
  void _showStoryAddScreen(BuildContext context) {
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final storyProvider = Provider.of<StoryProvider>(context, listen: false);
    final currentPlace = placeProvider.currentPlace;

    if (currentPlace == null) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => StoryAddScreen(
          existingStory: null, // 새 스토리 추가
          onSave: (storyData) async {
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
                      color: _storyPageIndex == index
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
