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

  /// 슬라이딩 윈도우: 첫 번째 보이는 인덱스 추정용 아이템 높이(px)
  static const double _estimatedItemHeight = 64;

  /// 코스별 탭 진입 시 복원 한 번만 수행 (플레이스별)
  String? _courseTabRestoredForPlaceId;

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

    final currentPlace = placeProvider.currentPlace;
    if (currentPlace == null) return;

    try {
      if (courseProvider.courses.isEmpty) {
        await courseProvider.loadCourses(currentPlace.id);
      }
      memberProvider.setPlaceId(currentPlace.id);
    } catch (e) {
      debugPrint('[AdminMemberScreen] Error loading data: $e');
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    // 스트림은 자동으로 취소되므로 명시적 취소 불필요
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final memberProvider = Provider.of<MemberProvider>(context);
    final courseProvider = Provider.of<CourseProvider>(context);
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final placeId = placeProvider.currentPlace?.id;

    // 과목 키워드 검색용 코스명 맵 동기화 (빌드 중 notifyListeners 금지 → 프레임 후 실행)
    if (courseProvider.courses.isNotEmpty) {
      final courseMap = {for (var c in courseProvider.courses) c.id: c.name};
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        Provider.of<MemberProvider>(context, listen: false)
            .setCourseNamesForSearch(courseMap);
      });
    }

    // 코스별 탭 진입 시 선택이 비어 있으면 SharedPreferences 복원 또는 첫 코스 선택
    if (memberProvider.selectedTab == 1 &&
        memberProvider.selectedCourseIds.isEmpty &&
        courseProvider.courses.isNotEmpty &&
        placeId != null &&
        placeId != _courseTabRestoredForPlaceId) {
      _courseTabRestoredForPlaceId = placeId;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final mp = Provider.of<MemberProvider>(context, listen: false);
        final cp = Provider.of<CourseProvider>(context, listen: false);
        final pid = placeProvider.currentPlace?.id;
        if (pid == null || cp.courses.isEmpty) return;
        if (mp.selectedCourseIds.isNotEmpty) return;
        await mp.restoreCourseSelectionForCourseTab(
          pid,
          cp.courses.map((c) => c.id).toList(),
        );
      });
    }

    return Column(
      children: [
        SizedBox(height: 4),

        _buildTabs(),
        _buildSearchBar(),

        // 코스 선택 (코스별 탭일 때만)
        AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          child:
              memberProvider.selectedTab == 1
                  ? _buildCourseSelector(memberProvider, courseProvider.courses)
                  : const SizedBox.shrink(),
        ),
        Expanded(
          child:
              memberProvider.selectedTab == 1 &&
                      memberProvider.selectedCourseIds.isNotEmpty
                  ? _buildCourseMemberList(
                    memberProvider,
                    courseProvider.courses,
                  )
                  : memberProvider.isLoading
                  ? const Center(
                    child: CircularProgressIndicator(
                      color: AppColors.primaryGreen,
                    ),
                  )
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
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
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
                suffixIcon: Icon(
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

  // 탭
  Widget _buildTabs() {
    final memberProvider = Provider.of<MemberProvider>(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 16),
      child: DefaultTapbar(
        labels: ['전체', '코스별'],
        selectedIndex: memberProvider.selectedTab,
        onTabChanged: (index) {
          memberProvider.setSelectedTab(index);
        },
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
    List<Course> courses,
  ) {
    final selectedCourses =
        courses
            .where((c) => memberProvider.selectedCourseIds.contains(c.id))
            .toList();
    final firstSelectedCourse =
        selectedCourses.isNotEmpty ? selectedCourses.first : null;
    final remainingCount =
        selectedCourses.length > 1 ? selectedCourses.length - 1 : 0;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
          // 카테고리 헤더 (코스별 + 선택 코스명 + 필터 아이콘)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      memberProvider.setCourseSelectorExpanded(
                        !memberProvider.isCourseSelectorExpanded,
                      );
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Row(
                      children: [
                        Text(
                          '코스별',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            color: AppColors.primaryGreen,
                          ),
                        ),
                        const SizedBox(width: 8),
                        AnimatedRotation(
                          turns:
                              memberProvider.isCourseSelectorExpanded
                                  ? 0.0
                                  : 0.5,
                          duration: const Duration(milliseconds: 200),
                          child: Icon(
                            Icons.keyboard_arrow_down,
                            color: AppColors.primaryGreen,
                            size: 22,
                          ),
                        ),
                        if (!memberProvider.isCourseSelectorExpanded &&
                            firstSelectedCourse != null)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(left: 12),
                              child: Text(
                                remainingCount > 0
                                    ? '${firstSelectedCourse.name} 외 $remainingCount'
                                    : firstSelectedCourse.name,
                                style: TextStyle(
                                  fontSize: 16,
                                  color: AppColors.textSecondary,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
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
                memberProvider.isCourseSelectorExpanded
                    ? Container(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final course in courses)
                            _buildCourseFilterButton(memberProvider, course),
                        ],
                      ),
                    )
                    : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  // 코스 필터 버튼 (단일 선택 + SharedPreferences 저장)
  Widget _buildCourseFilterButton(
    MemberProvider memberProvider,
    Course course,
  ) {
    final isSelected = memberProvider.selectedCourseIds.contains(course.id);
    return GestureDetector(
      onTap: () {
        memberProvider.selectSingleCourseForCourseTab(course.id);
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
        onSortChanged: (v) => memberProvider.setCourseSortBy(v),
        onSortOrderChanged: (v) => memberProvider.setCourseSortAscending(v),
        courseForDirectDetail: course,
        sortFilterInParent: true,
      );
    } else {
      final list = memberProvider.listForCourseTab;
      if (list.isEmpty) {
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
          if (n is ScrollUpdateNotification) {
            final m = n.metrics;
            final firstVisible =
                (m.pixels / _estimatedItemHeight).floor().clamp(0, 99999);
            memberProvider.setVisibleRange(firstVisible);
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
                final firstVisible =
                    (m.pixels / _estimatedItemHeight).floor().clamp(0, 99999);
                memberProvider.setVisibleRange(firstVisible);
                if (m.pixels >= m.maxScrollExtent - _loadMoreThreshold &&
                    memberProvider.hasMoreMembers &&
                    !memberProvider.isLoadingMore) {
                  Provider.of<MemberProvider>(context, listen: false)
                      .loadMoreMembers();
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
                  child: MemberCard(member: v, onMemberTapped: () {}),
                );
              },
            ),
          ),
        ),
      ],
    );
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
          final phoneNumber = (memberData['phoneNumber'] as String? ?? '').trim();

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
          final courseEnrollments = rawEnrollments is List<dynamic>
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
            courseEnrollments: courseEnrollments.isEmpty ? null : courseEnrollments,
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
          SnackbarUtil.showInfo(context, '${successCount}명 성공, ${failCount}명 실패');
        }
        if (!mounted) return;
        final memberProvider = Provider.of<MemberProvider>(
          context,
          listen: false,
        );
        memberProvider.setPlaceId(placeId);
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
