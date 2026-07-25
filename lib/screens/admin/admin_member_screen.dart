import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:reservation/widgets/defualt_tapbar.dart';
import '../../providers/auth_provider.dart';
import '../../theme/app_colors.dart';
import 'widgets/shared_widgets.dart';
import 'widgets/course_member_list_content.dart';
import 'widgets/member_edit_bottom_sheet.dart';
import 'widgets/member_registration_screen.dart';
import 'widgets/member_card_focus_overlay.dart';
import '../../../models/course.dart';
import '../../models/member_view.dart';

import '../../providers/member_provider.dart';
import '../../providers/course_provider.dart';
import '../../providers/place_provider.dart';
import '../../utils/text_field_decoration_util.dart';

import '../../services/member_service.dart';
import '../../utils/snackbar_util.dart';

class AdminMemberScreen extends StatefulWidget {
  const AdminMemberScreen({super.key});

  @override
  State<AdminMemberScreen> createState() => _AdminMemberScreenState();
}

class _AdminMemberScreenState extends State<AdminMemberScreen> {
  final TextEditingController _searchController = TextEditingController();

  /// 무한 스크롤: 하단 이 거리(px) 내 접근 시 추가 로드
  static const double _loadMoreThreshold = 200;

  /// 코스별 탭: 위로 스크롤 시 코스 칩 영역 접기
  static const double _courseSelectorScrollThreshold = 12;

  bool _courseSelectorCompactByScroll = false;
  double _lastCourseListScrollOffset = 0;

  /// 플레이스별 마지막 탭/칩 복원 1회
  String? _memberPrefsRestoredForPlaceId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadDataIfNeeded();
    });
  }

  /// Provider가 검색어를 비웠을 때만 TextField 동기화 (입력 중 덮어쓰기 방지)
  void _syncSearchFromProvider(MemberProvider mp) {
    if (mp.searchQuery.isEmpty && _searchController.text.isNotEmpty) {
      _searchController.clear();
    }
  }

  /// 데이터가 로드되지 않았으면 로드
  Future<void> _loadDataIfNeeded() async {
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final memberProvider = Provider.of<MemberProvider>(context, listen: false);
    final authProvider = Provider.of<AuthProvider>(context, listen: false);

    final currentPlace = placeProvider.currentPlace;
    if (currentPlace == null) return;

    try {
      if (courseProvider.courses.isEmpty) {
        await courseProvider.loadCourses(currentPlace.id);
      }
      final isSubManager = authProvider.isSubManagerForPlace(currentPlace.id);
      memberProvider.setPlaceId(
        currentPlace.id,
        isSubManagerForPlace: isSubManager,
      );

      // 마지막 탭 + 칩을 prefs→캐시에 올린 뒤 한 번에 적용
      if (_memberPrefsRestoredForPlaceId != currentPlace.id) {
        _memberPrefsRestoredForPlaceId = currentPlace.id;
        final courseIds = courseProvider.courses.map((c) => c.id).toList();
        await memberProvider.hydrateMemberUiPrefs(
          currentPlace.id,
          validCourseIds: courseIds,
          isSubManager: isSubManager,
        );
      } else if (isSubManager && memberProvider.selectedTab == 0) {
        memberProvider.setSelectedTab(1);
      }
    } catch (e) {
      debugPrint('[AdminMemberScreen] Error loading data: $e');
    }
  }

  void _resetCourseSelectorScrollState() {
    _courseSelectorCompactByScroll = false;
    _lastCourseListScrollOffset = 0;
  }

  void _expandCourseSelectorPanel() {
    final memberProvider = Provider.of<MemberProvider>(context, listen: false);
    if (!_courseSelectorCompactByScroll &&
        memberProvider.isCourseSelectorExpanded) {
      return;
    }
    setState(_resetCourseSelectorScrollState);
    memberProvider.setCourseSelectorExpanded(true);
  }

  bool _onCourseMemberListScroll(ScrollNotification notification) {
    final isScrollUpdate = notification is ScrollUpdateNotification;
    final isScrollEnd = notification is ScrollEndNotification;
    if (!isScrollUpdate && !isScrollEnd) return false;

    final metrics = notification.metrics;
    if (!metrics.hasPixels) return false;

    final current = metrics.pixels;

    if (current <= 0) {
      _expandCourseSelectorPanel();
      _lastCourseListScrollOffset = current;
      return false;
    }

    if (!isScrollUpdate) {
      _lastCourseListScrollOffset = current;
      return false;
    }

    final delta = current - _lastCourseListScrollOffset;

    if (delta > _courseSelectorScrollThreshold) {
      if (!_courseSelectorCompactByScroll) {
        setState(() => _courseSelectorCompactByScroll = true);
      }
    } else if (delta < -_courseSelectorScrollThreshold) {
      _expandCourseSelectorPanel();
    }

    _lastCourseListScrollOffset = current;
    return false;
  }

  @override
  void dispose() {
    _searchController.dispose();
    // 스트림 없음 — Provider.clear()만 필요
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final memberProvider = Provider.of<MemberProvider>(context);
    final courseProvider = Provider.of<CourseProvider>(context);
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final placeId = placeProvider.currentPlace?.id;
    final isSubManager =
        placeId != null && authProvider.isSubManagerForPlace(placeId);
    final showCourseTab = memberProvider.selectedTab == 1;
    final showInactiveTab = memberProvider.selectedTab == 2;
    // 비활성 탭 코스 패널: 주매니저만 (부매니저는 패널 없음)
    final showInactiveCoursePanel = showInactiveTab && !isSubManager;
    final showCourseSelector = showCourseTab || showInactiveCoursePanel;
    final placeMember =
        placeId != null ? authProvider.getPlaceMemberForPlace(placeId) : null;
    final coursesForTab =
        isSubManager && placeMember != null
            ? courseProvider.courses
                .where((c) => placeMember.manageableCourseIds.contains(c.id))
                .toList()
            : courseProvider.courses;

    // 과목 키워드 검색용 코스명 맵 동기화 (빌드 중 notifyListeners 금지 → 프레임 후 실행)
    if (courseProvider.courses.isNotEmpty) {
      final courseMap = {for (var c in courseProvider.courses) c.id: c.name};
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        Provider.of<MemberProvider>(
          context,
          listen: false,
        ).setCourseNamesForSearch(courseMap);
      });
    }

    // 코스별 탭: 선택이 비어 있으면 캐시로 즉시 복원
    if (showCourseTab &&
        memberProvider.selectedCourseIds.isEmpty &&
        coursesForTab.isNotEmpty) {
      final validCourseIds = coursesForTab.map((c) => c.id).toList();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final mp = Provider.of<MemberProvider>(context, listen: false);
        if (mp.selectedTab != 1) return;
        if (mp.selectedCourseIds.isNotEmpty) return;
        mp.applyCourseTabSelectionFromCache(validCourseIds);
      });
    }

    return Column(
      children: [
        SizedBox(height: 4),

        _buildTabs(),
        _buildSearchBar(),

        // 코스 선택: 코스별 탭, 또는 비활성 탭(주매니저만)
        AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          child:
              showCourseSelector
                  ? _buildCourseSelector(
                    memberProvider,
                    coursesForTab,
                    compactByScroll: _courseSelectorCompactByScroll,
                    isInactiveTab: showInactiveTab,
                  )
                  : const SizedBox.shrink(),
        ),
        Expanded(
          child:
              memberProvider.isLoading
                  ? const Center(
                    child: CircularProgressIndicator(
                      color: AppColors.primaryGreen,
                    ),
                  )
                  : showInactiveTab
                  ? _buildInactiveMemberList(
                    memberProvider,
                    coursesForTab,
                    showCoursePanel: showInactiveCoursePanel,
                  )
                  : showCourseTab && memberProvider.selectedCourseIds.isNotEmpty
                  ? _buildCourseMemberList(memberProvider, coursesForTab)
                  : showCourseTab
                  ? _buildEmptyMemberState(context, '코스를 선택해주세요')
                  : _buildMemberList(memberProvider),
        ),
      ],
    );
  }

  // 검색 바
  Widget _buildSearchBar() {
    final mp = Provider.of<MemberProvider>(context);
    _syncSearchFromProvider(mp);
    return Container(
      padding: const EdgeInsets.only(left: 20, right: 20, top: 2, bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              decoration: TextFieldDecorationUtil.standardDecoration(
                hintText: '멤버 검색하기',
                borderRadius: 20,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
              ).copyWith(
                suffixIcon:
                    mp.isSearchLoading
                        ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                        : Icon(
                          Icons.search,
                          color: AppColors.primaryGreen,
                          size: 24,
                        ),
                hintStyle: TextStyle(
                  fontSize: 16,
                  color: AppColors.textSecondary.withOpacity(0.8),
                  fontWeight: FontWeight.w600,
                ),
                fillColor: const Color.fromARGB(255, 235, 235, 235),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
                errorBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
                focusedErrorBorder: OutlineInputBorder(),
              ),
              style: TextStyle(fontSize: 16, color: AppColors.textPrimary),
              onChanged: (value) {
                Provider.of<MemberProvider>(
                  context,
                  listen: false,
                ).setSearchQuery(value);
              },
            ),
          ),
          if (Provider.of<MemberProvider>(context).searchQuery.isNotEmpty) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: () {
                _searchController.clear();
                Provider.of<MemberProvider>(
                  context,
                  listen: false,
                ).setSearchQuery('');
              },
              child: Text(
                '취소',
                style: TextStyle(fontSize: 16, color: AppColors.textSecondary),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // 탭 (부매니저일 때는 '전체' 탭 숨김)
  Widget _buildTabs() {
    final memberProvider = Provider.of<MemberProvider>(context);
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final placeId = placeProvider.currentPlace?.id;
    final isSubManager =
        placeId != null && authProvider.isSubManagerForPlace(placeId);

    final onCourseTab = memberProvider.selectedTab == 1;
    final onInactiveTab = memberProvider.selectedTab == 2;
    final hasCourseSelection = memberProvider.selectedCourseIds.isNotEmpty;
    // 로딩 중 (0)→(N) 깜빡임 방지: 카운트는 로드 완료 후 한 번에 표시
    final showCounts = !memberProvider.isLoading;

    String allTabLabel() {
      if (onCourseTab || onInactiveTab) return '전체';
      if (!showCounts) return '전체';
      return '전체(${memberProvider.listForAllTab.length})';
    }

    String courseTabLabel() {
      if (!hasCourseSelection) return '코스별';
      if (!onCourseTab) return '코스별';
      if (!showCounts) return '코스별';
      return '코스별(${memberProvider.listForCourseTab.length})';
    }

    String inactiveTabLabel() {
      if (!onInactiveTab) return '비활성';
      if (!showCounts) return '비활성';
      final courseId =
          memberProvider.selectedCourseIds.length == 1
              ? memberProvider.selectedCourseIds.first
              : null;
      // 주매니저: 미선택=모든 코스 비활성(전체), 선택=해당 코스 비활성
      // 부매니저: 비활이 하나라도 있는 멤버
      final count =
          memberProvider
              .listForInactiveTab(
                courseId: isSubManager ? null : courseId,
                fullyInactiveOnly: !isSubManager && courseId == null,
              )
              .length;
      return '비활성($count)';
    }

    final labels =
        isSubManager
            ? [courseTabLabel(), inactiveTabLabel()]
            : [allTabLabel(), courseTabLabel(), inactiveTabLabel()];

    int uiSelectedIndex() {
      if (isSubManager) {
        return memberProvider.selectedTab == 2 ? 1 : 0;
      }
      return memberProvider.selectedTab.clamp(0, 2);
    }

    void onUiTabChanged(int index) {
      final courseProvider = Provider.of<CourseProvider>(context, listen: false);
      final ids = courseProvider.courses.map((c) => c.id).toList();

      if (isSubManager) {
        // 0=코스별(1), 1=비활성(2)
        final nextTab = index == 0 ? 1 : 2;
        if (nextTab == 1) {
          memberProvider.applyCourseTabSelectionFromCache(ids, notify: false);
        }
        memberProvider.setSelectedTab(nextTab);
        return;
      }
      if (index == 0) {
        setState(_resetCourseSelectorScrollState);
      }
      if (index == 1) {
        // 코스별: 캐시된 칩을 탭 전환과 한 프레임에 적용
        setState(_resetCourseSelectorScrollState);
        memberProvider.applyCourseTabSelectionFromCache(ids, notify: false);
      }
      if (index == 2) {
        // 비활성: 열린 패널 + 캐시된 칩을 탭 전환과 한 프레임에 적용
        setState(_resetCourseSelectorScrollState);
        memberProvider.setCourseSelectorExpanded(true);
        memberProvider.applyInactiveTabSelectionFromCache(ids, notify: false);
      }
      memberProvider.setSelectedTab(index);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
      child: DefaultTapbar(
        labels: labels,
        selectedIndex: uiSelectedIndex(),
        onTabChanged:
            isSubManager && labels.length == 1 ? (_) {} : onUiTabChanged,
        showIndicator: false,
        trailing: IconButton(
          icon: Icon(Icons.add_circle, color: AppColors.primaryGreen, size: 34),
          onPressed: () => _showMemberEditor(context),
        ),
      ),
    );
  }

  // 코스 선택기 (카테고리 섹션)
  Widget _buildCourseSelector(
    MemberProvider memberProvider,
    List<Course> courses, {
    bool compactByScroll = false,
    bool isInactiveTab = false,
  }) {
    final selectedCourses =
        courses
            .where((c) => memberProvider.selectedCourseIds.contains(c.id))
            .toList();
    final firstSelectedCourse =
        selectedCourses.isNotEmpty ? selectedCourses.first : null;
    final remainingCount =
        selectedCourses.length > 1 ? selectedCourses.length - 1 : 0;
    final showCourseChips =
        !compactByScroll && memberProvider.isCourseSelectorExpanded;
    final isSimpleHeader = !showCourseChips;
    // 비활성 탭: 선택이 없으면 '전체'로 표기
    final emptyLabel = isInactiveTab ? '전체' : '코스별';
    final headerCourseLabel =
        firstSelectedCourse == null
            ? emptyLabel
            : remainingCount > 0
            ? '${firstSelectedCourse.name} 외 $remainingCount'
            : firstSelectedCourse.name;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 헤더: 펼침 = 코스별+▼ / 간단 = 과목명+▼+필터
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      if (isSimpleHeader) {
                        if (compactByScroll) {
                          setState(_resetCourseSelectorScrollState);
                        }
                        memberProvider.setCourseSelectorExpanded(true);
                        return;
                      }
                      memberProvider.setCourseSelectorExpanded(false);
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            isSimpleHeader ? headerCourseLabel : '코스별',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              color: AppColors.primaryGreen,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        AnimatedRotation(
                          turns: showCourseChips ? 0.0 : 0.5,
                          duration: const Duration(milliseconds: 200),
                          child: Icon(
                            Icons.keyboard_arrow_down,
                            color: AppColors.primaryGreen,
                            size: 22,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (selectedCourses.length == 1)
                  CourseMemberListContent.buildSortFilterDropdown(
                    sortBy: memberProvider.courseSortBy,
                    sortAscending: memberProvider.courseSortAscending,
                    onSortChanged: (v) => memberProvider.setCourseSortBy(v),
                    onSortOrderChanged:
                        (v) => memberProvider.setCourseSortAscending(v),
                  ),
              ],
            ),
          ),
          // 코스 필터 버튼들 (애니메이션과 함께)
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            child:
                showCourseChips
                    ? Container(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (isInactiveTab)
                            _buildAllCoursesFilterButton(memberProvider),
                          for (final course in courses)
                            _buildCourseFilterButton(
                              memberProvider,
                              course,
                              isInactiveTab: isInactiveTab,
                            ),
                        ],
                      ),
                    )
                    : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  // 비활성 탭 전용 '전체' 칩 (선택 해제 = 전체 비활성)
  Widget _buildAllCoursesFilterButton(MemberProvider memberProvider) {
    final isSelected = memberProvider.selectedCourseIds.isEmpty;
    return GestureDetector(
      onTap: () => memberProvider.selectInactiveCourseFilter(null),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.textPrimary : AppColors.backgroundLight,
          borderRadius: BorderRadius.circular(20),
        ),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 200),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color:
                isSelected ? AppColors.backgroundWhite : AppColors.textPrimary,
          ),
          child: const Text('전체'),
        ),
      ),
    );
  }

  // 코스 필터 버튼 (단일 선택 + SharedPreferences 저장)
  Widget _buildCourseFilterButton(
    MemberProvider memberProvider,
    Course course, {
    bool isInactiveTab = false,
  }) {
    final isSelected = memberProvider.selectedCourseIds.contains(course.id);
    return GestureDetector(
      onTap: () {
        if (isInactiveTab) {
          memberProvider.selectInactiveCourseFilter(course.id);
        } else {
          memberProvider.selectSingleCourseForCourseTab(course.id);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.textPrimary : AppColors.backgroundLight,
          borderRadius: BorderRadius.circular(20),
        ),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 200),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color:
                isSelected ? AppColors.backgroundWhite : AppColors.textPrimary,
          ),
          child: Text(course.name),
        ),
      ),
    );
  }

  Widget _buildCourseMemberList(
    MemberProvider memberProvider,
    List<Course> courses,
  ) {
    final selectedCourseIds = memberProvider.selectedCourseIds.toList();

    if (selectedCourseIds.isEmpty) {
      return Center(
        child: Text(
          '코스를 선택해주세요.',
          style: TextStyle(
            color: AppColors.textSecondary.withOpacity(0.8),
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    // 단일 코스 선택 시 (공통 위젯: enrollments + pendingMembers 동일 소스·동일 UI)
    // 멤버 탭 시 바텀시트 대신 EnrollmentDetailScreen으로 바로 이동
    if (selectedCourseIds.length == 1) {
      final selectedCourseId = selectedCourseIds.first;
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final placeId = placeProvider.currentPlace?.id;
      final course = courses.where((c) => c.id == selectedCourseId).firstOrNull;

      return CourseMemberListContent(
        logLabel: 'AdminMember(single)',
        courseId: selectedCourseId,
        placeId: placeId,
        searchQuery: memberProvider.searchQuery,
        sortBy: memberProvider.courseSortBy,
        sortAscending: memberProvider.courseSortAscending,
        showCourseEnrollmentDetail: true,
        onLoadMore: () => memberProvider.loadMoreMembers(),
        emptyMessage:
            memberProvider.searchQuery.isNotEmpty
                ? '검색 결과가 없어요.'
                : '등록된 멤버가 없어요.',
        showEmptyCta: memberProvider.searchQuery.isEmpty,
        onMemberTapped: () {},
        onMemberLongPressed:
            (member, rect) => _onMemberLongPress(
              member: member,
              cardRect: rect,
              courseId: selectedCourseId,
              showCourseDetail: true,
            ),
        onSortChanged: (v) => memberProvider.setCourseSortBy(v),
        onSortOrderChanged: (v) => memberProvider.setCourseSortAscending(v),
        courseForDirectDetail: course,
        sortFilterInParent: true,
        onListScroll: _onCourseMemberListScroll,
      );
    } else {
      final list = memberProvider.listForCourseTab;
      if (list.isEmpty) {
        if (memberProvider.isSearchLoading) {
          return const Center(child: CircularProgressIndicator());
        }
        return Center(
          child: _buildEmptyMemberState(
            context,
            memberProvider.searchQuery.isNotEmpty
                ? '검색 결과가 없어요.'
                : '등록된 멤버가 없어요.',
            showCta: memberProvider.searchQuery.isEmpty,
          ),
        );
      }
      return NotificationListener<ScrollNotification>(
        onNotification: (n) {
          _onCourseMemberListScroll(n);
          if (n is ScrollUpdateNotification) {
            final m = n.metrics;
            if (m.pixels >= m.maxScrollExtent - _loadMoreThreshold &&
                memberProvider.hasMoreMembers &&
                !memberProvider.isLoadingMore) {
              memberProvider.loadMoreMembers();
            }
          }
          return false;
        },
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 0),
          itemCount: list.length + (memberProvider.isLoadingMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index >= list.length) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.primaryGreen,
                    ),
                  ),
                ),
              );
            }
            final v = list[index];
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: MemberCard(
                member: v,
                onMemberTapped: () {},
                onMemberLongPressed:
                    (rect) => _onMemberLongPress(
                      member: v,
                      cardRect: rect,
                      courseId: null,
                      showCourseDetail: false,
                    ),
                showCourseEnrollmentDetail: false,
              ),
            );
          },
        ),
      );
    }
  }

  Widget _buildMemberList(MemberProvider memberProvider) {
    final list = memberProvider.listForAllTab;
    if (list.isEmpty) {
      if (memberProvider.isSearchLoading) {
        return const Center(child: CircularProgressIndicator());
      }
      return Center(
        child: _buildEmptyMemberState(
          context,
          memberProvider.searchQuery.isNotEmpty
              ? '검색 결과가 없어요.'
              : '등록된 멤버가 없어요.',
          showCta: memberProvider.searchQuery.isEmpty,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollUpdateNotification) {
                final m = notification.metrics;
                if (m.pixels >= m.maxScrollExtent - _loadMoreThreshold &&
                    memberProvider.hasMoreMembers &&
                    !memberProvider.isLoadingMore) {
                  Provider.of<MemberProvider>(
                    context,
                    listen: false,
                  ).loadMoreMembers();
                }
              }
              return false;
            },
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 0),
              itemCount: list.length + (memberProvider.isLoadingMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= list.length) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.primaryGreen,
                        ),
                      ),
                    ),
                  );
                }
                final v = list[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: MemberCard(
                    member: v,
                    onMemberTapped: () {},
                    onMemberLongPressed:
                        (rect) => _onMemberLongPress(
                          member: v,
                          cardRect: rect,
                          courseId: null,
                          showCourseDetail: false,
                        ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInactiveMemberList(
    MemberProvider memberProvider,
    List<Course> courses, {
    required bool showCoursePanel,
  }) {
    // 주매니저: 선택 없음 = '전체'(모든 코스에서 비활성), 선택 = 해당 코스 비활성
    // 부매니저(패널 없음): 비활이 하나라도 있는 멤버
    final String? courseId =
        showCoursePanel && memberProvider.selectedCourseIds.length == 1
            ? memberProvider.selectedCourseIds.first
            : null;
    final fullyInactiveOnly = showCoursePanel && courseId == null;

    final list = memberProvider.listForInactiveTab(
      courseId: courseId,
      fullyInactiveOnly: fullyInactiveOnly,
    );
    if (list.isEmpty) {
      if (memberProvider.isSearchLoading) {
        return const Center(child: CircularProgressIndicator());
      }
      return Center(
        child: _buildEmptyMemberState(
          context,
          memberProvider.searchQuery.isNotEmpty
              ? '검색 결과가 없어요.'
              : '비활성 멤버가 없어요.',
        ),
      );
    }

    final course =
        courseId == null
            ? null
            : courses.where((c) => c.id == courseId).firstOrNull;

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (showCoursePanel) _onCourseMemberListScroll(n);
        return false;
      },
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 0),
        itemCount: list.length,
        itemBuilder: (context, index) {
          final v = list[index];
          // 코스 스코프면 enrollment 붙여 코스별과 동일하게 횟수/기간 표시
          final member =
              courseId == null
                  ? v
                  : v.copyWith(
                    enrollment: memberProvider.getEnrollmentForUserAndCourse(
                      v.userId,
                      courseId,
                    ),
                  );
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: MemberCard(
              member: member,
              onMemberTapped: () {},
              showCourseEnrollmentDetail: courseId != null,
              courseForDirectDetail: course,
              onMemberLongPressed:
                  (rect) => _onMemberLongPress(
                    member: member,
                    cardRect: rect,
                    courseId: courseId,
                    showCourseDetail: courseId != null,
                    fromInactiveTab: true,
                  ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _onMemberLongPress({
    required MemberView member,
    required Rect cardRect,
    required String? courseId,
    required bool showCourseDetail,
    bool fromInactiveTab = false,
  }) async {
    if (member.isPending) {
      SnackbarUtil.showInfo(context, '가입 대기 멤버는 비활성할 수 없습니다.');
      return;
    }

    final memberProvider = Provider.of<MemberProvider>(context, listen: false);
    final scopedCourseId =
        (courseId != null && courseId.isNotEmpty) ? courseId : null;
    final isCourseScope = scopedCourseId != null;
    final enrollment =
        isCourseScope
            ? memberProvider.getEnrollmentForUserAndCourse(
              member.userId,
              scopedCourseId,
            )
            : null;
    final initialMemo =
        isCourseScope
            ? (enrollment?.inactiveMemo ?? '')
            : (member.inactiveMemo ?? '');

    final isCurrentlyInactive =
        isCourseScope
            ? member.inactiveCourseIds.contains(scopedCourseId)
            : member.isPlaceInactive ||
                (fromInactiveTab && member.inactiveCourseIds.isNotEmpty);

    final canDeactivate =
        isCourseScope
            ? memberProvider.canDeactivateForCourse(
              member.userId,
              scopedCourseId,
            )
            : memberProvider.canDeactivateAtPlace(member.userId);

    final result = await MemberCardFocusOverlay.show(
      context: context,
      cardRect: cardRect,
      member: member,
      showCourseDetail: showCourseDetail,
      canDeactivate: canDeactivate,
      isCurrentlyInactive: isCurrentlyInactive,
      initialMemo: initialMemo,
    );
    if (!mounted || result == null) return;

    if (result.isDeactivateOrReactivate) {
      if (fromInactiveTab && !member.isPlaceInactive) {
        await _reactivateFromInactiveTab(member);
      } else {
        await _toggleInactive(
          member: member,
          courseId: scopedCourseId,
          makeInactive: !isCurrentlyInactive,
        );
      }
      return;
    }

    if (result.memoText != null) {
      final ok = await memberProvider.setInactiveMemo(
        userId: member.userId,
        memo: result.memoText,
        courseId: scopedCourseId,
      );
      if (!mounted) return;
      if (ok) {
        SnackbarUtil.showSuccess(context, '메모를 저장했습니다.');
      } else {
        SnackbarUtil.showInfo(context, '메모 저장에 실패했습니다.');
      }
    }
  }

  Future<void> _reactivateFromInactiveTab(MemberView member) async {
    final memberProvider = Provider.of<MemberProvider>(context, listen: false);
    if (member.isPlaceInactive) {
      await _toggleInactive(
        member: member,
        courseId: null,
        makeInactive: false,
      );
      return;
    }
    var anyOk = false;
    for (final courseId in member.inactiveCourseIds) {
      final ok = await memberProvider.setCourseInactive(
        userId: member.userId,
        courseId: courseId,
        isInactive: false,
      );
      anyOk = anyOk || ok;
    }
    if (!mounted) return;
    if (anyOk) {
      SnackbarUtil.showSuccess(context, '활성으로 복구했습니다.');
    } else {
      SnackbarUtil.showInfo(context, '처리에 실패했습니다.');
    }
  }

  Future<void> _toggleInactive({
    required MemberView member,
    required String? courseId,
    required bool makeInactive,
  }) async {
    final memberProvider = Provider.of<MemberProvider>(context, listen: false);
    final isCourseScope = courseId != null && courseId.isNotEmpty;

    final ok =
        isCourseScope
            ? await memberProvider.setCourseInactive(
              userId: member.userId,
              courseId: courseId!,
              isInactive: makeInactive,
            )
            : await memberProvider.setPlaceInactive(
              userId: member.userId,
              isInactive: makeInactive,
            );

    if (!mounted) return;
    if (ok) {
      SnackbarUtil.showSuccess(
        context,
        makeInactive ? '비활성 처리했습니다.' : '활성으로 복구했습니다.',
      );
    } else {
      SnackbarUtil.showInfo(
        context,
        makeInactive ? '유효기간·남은 횟수를 확인해주세요.' : '처리에 실패했습니다.',
      );
    }
  }

  /// 멤버 없음/검색 결과 없음 빈 상태 (member_detail_bottom_sheet CTA 디자인과 동일)
  Widget _buildEmptyMemberState(
    BuildContext context,
    String message, {
    bool showCta = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: TextStyle(
              fontSize: 16,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showMemberEditor(
    BuildContext context, {
    MemberView? existing,
  }) async {
    // 기존 멤버 수정 모드인 경우 기존 로직 사용
    if (existing != null) {
      await _showSingleMemberEditor(context, existing: existing);
      return;
    }

    // 새 멤버 등록 시 코스가 없으면 안내 후 리턴
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    if (courseProvider.courses.isEmpty) {
      SnackbarUtil.showInfo(context, '먼저 코스를 개설해주세요.');
      return;
    }

    // 새 멤버 등록 - 사이드 패널로 이동
    await Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder:
            (context, animation, secondaryAnimation) =>
                MemberRegistrationScreen(
                  onSave: (memberList) async {
                    await _registerMembers(context, memberList);
                  },
                ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          const curve = Curves.easeInOut;

          var tween = Tween(
            begin: begin,
            end: end,
          ).chain(CurveTween(curve: curve));

          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  // 기존 멤버 수정용 함수
  Future<void> _showSingleMemberEditor(
    BuildContext context, {
    required MemberView existing,
  }) async {
    await MemberEditBottomSheet.show(context, existing: existing);
  }

  // NOTE: 엑셀 일괄등록 UI는 현재 미사용(기능 미구현). 필요 시 다시 활성화.

  /// 멤버 등록 처리 (Firebase 연동)
  Future<void> _registerMembers(
    BuildContext context,
    List<Map<String, dynamic>> memberList,
  ) async {
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final placeId = placeProvider.currentPlace?.id;

    // placeId가 null이면 로그인 상태 문제 - 재로그인 필요
    if (placeId == null) {
      SnackbarUtil.showInfo(context, '플레이스 정보를 불러올 수 없습니다. 다시 로그인해주세요.');
      // 로그인 화면으로 이동하거나 재로그인 유도
      return;
    }

    // 관리자 인증 확인
    final currentUser = authProvider.currentUser;
    if (!authProvider.isAuthenticated || currentUser == null) {
      SnackbarUtil.showInfo(context, '로그인이 필요합니다. 다시 로그인해주세요.');
      return;
    }

    final adminId = currentUser.userId;
    try {
      debugPrint('🔥 [멤버 등록 시작] 총 ${memberList.length}명 등록 시도');
      debugPrint('🔥 [플레이스 ID] $placeId');
      debugPrint('🔥 [관리자 ID] $adminId');

      int successCount = 0;
      int failCount = 0;

      final courseProvider = Provider.of<CourseProvider>(
        context,
        listen: false,
      );
      final memberService = MemberService();

      for (final memberData in memberList) {
        try {
          final name = (memberData['name'] as String? ?? '').trim();
          final phoneNumber =
              (memberData['phoneNumber'] as String? ?? '').trim();

          debugPrint('📥 [멤버 데이터 수신] 이름: $name, 전화번호: $phoneNumber');
          debugPrint('📥 [멤버 데이터 전체] $memberData');

          // 필수 필드 검증
          if (name.isEmpty || phoneNumber.isEmpty) {
            debugPrint('❌ [검증 실패] 이름 또는 전화번호가 비어있음');
            failCount++;
            continue;
          }

          // courseEnrollments 추출 (null이면 빈 리스트로 처리)
          final rawEnrollments = memberData['courseEnrollments'];
          final courseEnrollments =
              rawEnrollments is List<dynamic>
                  ? rawEnrollments
                      .whereType<Map<String, dynamic>>()
                      .cast<Map<String, dynamic>>()
                      .toList()
                  : <Map<String, dynamic>>[];

          // MemberService를 사용하여 멤버 등록
          final success = await memberService.registerMember(
            placeId: placeId,
            adminId: adminId,
            name: name,
            phoneNumber: phoneNumber,
            courseEnrollments:
                courseEnrollments.isEmpty ? null : courseEnrollments,
            courses: courseProvider.courses,
          );

          if (success) {
            debugPrint('✅ [멤버 등록 성공] $name ($phoneNumber)');
            successCount++;
          } else {
            debugPrint('❌ [멤버 등록 실패] $name ($phoneNumber)');
            failCount++;
          }
        } catch (e) {
          failCount++;
          debugPrint('❌ [멤버 등록 실패] $e');
          debugPrint('❌ [스택 트레이스] ${StackTrace.current}');
        }
      }

      debugPrint('🔥 [멤버 등록 완료] 성공: $successCount명, 실패: $failCount명');

      if (!mounted) return;
      // 결과 메시지 표시 및 프로바이더 동기화 (여기서 null 등 예외 나도 오류 스낵바는 띄우지 않음)
      try {
        if (failCount == 0) {
          SnackbarUtil.showSuccess(context, '${successCount}명의 멤버가 등록되었습니다.');
        } else {
          SnackbarUtil.showInfo(
            context,
            '${successCount}명 성공, ${failCount}명 실패',
          );
        }
        if (!mounted) return;
        final memberProvider = Provider.of<MemberProvider>(
          context,
          listen: false,
        );
        memberProvider.setPlaceId(placeId, force: true);
      } catch (e2) {
        debugPrint('❌ [멤버 등록] 결과 표시/반영 중 오류 (무시): $e2');
        // 등록은 성공했으므로 오류 스낵바는 띄우지 않음
      }
    } catch (e, st) {
      debugPrint('❌ [멤버 등록] 오류: $e');
      debugPrint('❌ [멤버 등록] 스택: $st');
      if (mounted) {
        final msg = e.toString().trim();
        if (msg.isNotEmpty && msg != 'null') {
          SnackbarUtil.showInfo(context, '멤버 등록 중 오류가 발생했습니다: $msg');
        }
      }
    }
  }
}
