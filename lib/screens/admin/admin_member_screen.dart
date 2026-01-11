import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:reservation/widgets/defualt_tapbar.dart';
import '../../providers/auth_provider.dart';
import '../../theme/app_colors.dart';
import '../../models/admin_models.dart';
import 'widgets/admin_shared_widgets.dart';
import 'widgets/member_edit_bottom_sheet.dart';
import 'widgets/member_registration_screen.dart';
import '../../../models/course.dart';
import '../../providers/member_provider.dart';
import '../../providers/course_provider.dart';
import '../../providers/place_provider.dart';
import '../../models/user.dart';
import '../../models/pending_member.dart';
import '../../models/course_enrollment.dart';
import '../../utils/text_field_decoration_util.dart';
import '../../services/member_service.dart';
import '../../utils/snackbar_util.dart';

class AdminMemberScreen extends StatefulWidget {
  const AdminMemberScreen({super.key});

  @override
  State<AdminMemberScreen> createState() => _AdminMemberScreenState();
}

class _AdminMemberScreenState extends State<AdminMemberScreen> {
  // 검색 및 필터 상태
  String _searchQuery = '';
  int _selectedTab = 0; // 0: 전체, 1: 코스별, 2: 요청
  final Set<String> _selectedCourseIds = {}; // 중복 선택 가능
  bool _isCourseSelectorExpanded = true; // 코스 선택기 펼침/접힘 상태
  final TextEditingController _searchController = TextEditingController();

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
    final memberProvider = Provider.of<MemberProvider>(context, listen: false);

    final currentPlace = placeProvider.currentPlace;
    if (currentPlace == null) return;

    try {
      // AdminScreen에서 로드하지 않은 경우에만 로드
      if (courseProvider.courses.isEmpty) {
        await courseProvider.loadCourses(currentPlace.id);
      }
      if (memberProvider.members.isEmpty) {
        await memberProvider.loadMembers(currentPlace.id);
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

  // 필터링된 멤버 목록
  List<User> _filteredMembers(List<User> members) {
    var filtered = members;

    // 탭별 필터
    if (_selectedTab == 2) {
      // 요청 탭: 연장 요청이 있는 멤버만
      filtered = filtered.where((user) {
        return user.pendingExtensionRequests.isNotEmpty;
      }).toList();
    }

    // 코스별 필터 (코스별 탭일 때만)
    if (_selectedTab == 1) {
      if (_selectedCourseIds.isNotEmpty) {
        // 선택된 코스에 등록된 멤버만 필터링
        filtered = filtered.where((user) {
          // 유효한 enrollment 중에서 선택된 코스 ID와 일치하는 것이 있는지 확인
          final enrolledCourseIds = user.enrollments
              .where((e) => e.isValid)
              .map((e) => e.courseId)
              .toSet();
          // 선택된 코스 중 하나라도 등록되어 있으면 표시
          return _selectedCourseIds.any(
            (courseId) => enrolledCourseIds.contains(courseId),
          );
        }).toList();
      } else {
        // 코스가 선택되지 않았으면 모든 멤버 표시
        // (또는 아무것도 표시하지 않을 수도 있지만, 현재는 모든 멤버 표시)
      }
    }

    // 검색 필터
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      filtered = filtered.where((user) {
        return user.name.toLowerCase().contains(query) ||
            user.phoneNumber.toLowerCase().contains(query);
      }).toList();
    }

    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    final memberProvider = Provider.of<MemberProvider>(context);
    final courseProvider = Provider.of<CourseProvider>(context);

    return Column(
      children: [
        SizedBox(height: 4),

        _buildTabs(),
        _buildSearchBar(),

        // 코스 선택 (코스별 탭일 때만, 높이 애니메이션과 함께)
        AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          child: _selectedTab == 1
              ? _buildCourseSelector(courses: courseProvider.courses)
              : const SizedBox.shrink(),
        ),
        // 검색 바

        // 멤버 리스트 (users + pendingMembers)
        Expanded(
          child: memberProvider.isLoading
              ? const Center(child: CircularProgressIndicator())
              : _buildMemberList(
                  memberProvider.members,
                  memberProvider.pendingMembers,
                ),
        ),
      ],
    );
  }

  // 검색 바
  Widget _buildSearchBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              decoration:
                  TextFieldDecorationUtil.standardDecoration(
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
                setState(() {
                  _searchQuery = value;
                });
              },
            ),
          ),
          if (_searchQuery.isNotEmpty) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: () {
                _searchController.clear();
                setState(() {
                  _searchQuery = '';
                });
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 16),
      child: DefaultTapbar(
        labels: ['전체', '코스별', '요청'],
        selectedIndex: _selectedTab,
        onTabChanged: (index) {
          setState(() {
            _selectedTab = index;
          });
        },
        trailing: IconButton(
          icon: Icon(Icons.add_circle, color: AppColors.primaryGreen, size: 34),
          onPressed: () => _showMemberEditor(context),
        ),
      ),
    );
  }

  // 코스 선택기 (카테고리 섹션)
  Widget _buildCourseSelector({required List<Course> courses}) {
    // 선택된 코스 정보
    final selectedCourses = courses
        .where((c) => _selectedCourseIds.contains(c.id))
        .toList();
    final firstSelectedCourse = selectedCourses.isNotEmpty
        ? selectedCourses.first
        : null;
    final remainingCount = selectedCourses.length > 1
        ? selectedCourses.length - 1
        : 0;

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
          // 카테고리 헤더
          GestureDetector(
            onTap: () {
              setState(() {
                _isCourseSelectorExpanded = !_isCourseSelectorExpanded;
              });
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                    turns: _isCourseSelectorExpanded ? 0.0 : 0.5,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      color: AppColors.primaryGreen,
                      size: 22,
                    ),
                  ),
                  // 접혔을 때 선택된 코스명 표시
                  if (!_isCourseSelectorExpanded && firstSelectedCourse != null)
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
          // 코스 필터 버튼들 (애니메이션과 함께)
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            child: _isCourseSelectorExpanded
                ? Container(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final course in courses)
                          _buildCourseFilterButton(course),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  // 코스 필터 버튼
  Widget _buildCourseFilterButton(Course course) {
    final isSelected = _selectedCourseIds.contains(course.id);
    return GestureDetector(
      onTap: () {
        setState(() {
          if (isSelected) {
            _selectedCourseIds.remove(course.id);
          } else {
            _selectedCourseIds.add(course.id);
          }
        });
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
            color: isSelected
                ? AppColors.backgroundWhite
                : AppColors.textPrimary,
          ),
          child: Text(course.name),
        ),
      ),
    );
  }

  // User를 MemberData로 변환
  MemberData _userToMemberData(User user) {
    final pendingRequests = user.pendingExtensionRequests.length;
    final enrolledCourseIds = user.enrollments
        .where((e) => e.isValid)
        .map((e) => e.courseId)
        .toList();

    return MemberData(
      userId: user.userId,
      name: user.name,
      email: user.email ?? '',
      phoneNumber: user.phoneNumber,
      role: '일반',
      isActive: true,
      pendingExtensionRequests: pendingRequests,
      enrolledCourseIds: enrolledCourseIds,
    );
  }

  // PendingMember를 MemberData로 변환 (임시 User로 표시)
  MemberData _pendingMemberToMemberData(PendingMember pendingMember) {
    final courseIds = (pendingMember as dynamic).courseIds as List<dynamic>?;
    final enrolledCourseIds =
        courseIds?.map((e) => e.toString()).toList() ?? [];

    return MemberData(
      userId: 'pending_${pendingMember.id}', // 임시 ID
      name: pendingMember.name ?? '이름 없음',
      email: '',
      phoneNumber: pendingMember.phoneNumber,
      role: '대기중', // pending 상태 표시
      isActive: false, // 아직 로그인하지 않음
      pendingExtensionRequests: 0,
      enrolledCourseIds: enrolledCourseIds,
    );
  }

  // 멤버 리스트 (users + pendingMembers)
  Widget _buildMemberList(
    List<User> members,
    List<PendingMember> pendingMembers,
  ) {
    // pendingMembers를 User로 변환 (임시)
    final pendingAsUsers = pendingMembers.map((pm) {
      // PendingMember를 User로 변환 (임시)
      final courseIds = pm.courseIds ?? [];
      final enrollments = courseIds.map((courseId) {
        return CourseEnrollment(
          id: 'pending_${pm.id}_$courseId',
          userId: 'pending_${pm.id}',
          courseId: courseId.toString(),
          placeId: pm.placeId,
          enrolledAt: pm.createdAt,
          validFrom: pm.createdAt,
          validUntil: pm.createdAt.add(const Duration(days: 365)),
          totalReservations: 10,
          remainingReservations: 10,
        );
      }).toList();

      return User(
        userId: 'pending_${pm.id}',
        name: pm.name ?? '이름 없음',
        phoneNumber: pm.phoneNumber,
        email: null,
        placeIds: [pm.placeId],
        enrollments: enrollments,
        reservations: [],
        notificationsEnabled: false,
        createdAt: pm.createdAt,
        updatedAt: null,
      );
    }).toList();

    // users와 pendingMembers 합치기
    final allMembers = [...members, ...pendingAsUsers];
    final filteredMembers = _filteredMembers(allMembers);

    if (filteredMembers.isEmpty) {
      return Center(
        child: Text(
          _searchQuery.isNotEmpty ? '검색 결과가 없어요.' : '등록된 멤버가 없어요.',
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 0),
      itemCount: filteredMembers.length,
      itemBuilder: (context, index) {
        final member = filteredMembers[index];
        final isPending = member.userId.startsWith('pending_');

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: MemberCard(
            member: isPending
                ? _pendingMemberToMemberData(
                    pendingMembers.firstWhere(
                      (pm) => 'pending_${pm.id}' == member.userId,
                    ),
                  )
                : _userToMemberData(member),
            onMemberTapped: () {},
          ),
        );
      },
    );
  }

  Future<void> _showMemberEditor(
    BuildContext context, {
    MemberData? existing,
  }) async {
    // 기존 멤버 수정 모드인 경우 기존 로직 사용
    if (existing != null) {
      await _showSingleMemberEditor(context, existing: existing);
      return;
    }

    // 새 멤버 등록 - 사이드 패널로 이동
    await Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
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
    required MemberData existing,
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
      SnackbarUtil.showError(context, '플레이스 정보를 불러올 수 없습니다. 다시 로그인해주세요.');
      // 로그인 화면으로 이동하거나 재로그인 유도
      return;
    }

    // 관리자 인증 확인
    if (!authProvider.isAuthenticated || authProvider.currentAdmin == null) {
      SnackbarUtil.showError(context, '로그인이 필요합니다. 다시 로그인해주세요.');
      return;
    }

    try {
      debugPrint('🔥 [멤버 등록 시작] 총 ${memberList.length}명 등록 시도');
      debugPrint('🔥 [플레이스 ID] $placeId');
      debugPrint('🔥 [관리자 ID] ${authProvider.currentAdmin!.userId}');

      int successCount = 0;
      int failCount = 0;

      final adminId = authProvider.currentAdmin!.userId;
      final courseProvider = Provider.of<CourseProvider>(
        context,
        listen: false,
      );
      final memberService = MemberService();

      for (final memberData in memberList) {
        try {
          final name = (memberData['name'] as String).trim();
          final phoneNumber = (memberData['phoneNumber'] as String).trim();

          debugPrint('📥 [멤버 데이터 수신] 이름: $name, 전화번호: $phoneNumber');
          debugPrint('📥 [멤버 데이터 전체] $memberData');

          // 필수 필드 검증
          if (name.isEmpty || phoneNumber.isEmpty) {
            debugPrint('❌ [검증 실패] 이름 또는 전화번호가 비어있음');
            failCount++;
            continue;
          }

          // courseEnrollments 추출
          final courseEnrollments =
              memberData['courseEnrollments'] as List<Map<String, dynamic>>?;

          // MemberService를 사용하여 멤버 등록
          final success = await memberService.registerMember(
            placeId: placeId,
            adminId: adminId,
            name: name,
            phoneNumber: phoneNumber,
            courseEnrollments: courseEnrollments,
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

      // 결과 메시지 표시
      if (failCount == 0) {
        SnackbarUtil.showSuccess(context, '${successCount}명의 멤버가 등록되었습니다.');
      } else {
        SnackbarUtil.showError(
          context,
          '${successCount}명 성공, ${failCount}명 실패',
        );
      }

      // 트랜잭션 완료 후 프로바이더 상태 동기화
      // MemberProvider는 watchUsersByPlace Stream을 사용하므로
      // Firestore 변경사항이 자동으로 반영됨 (트랜잭션 완료 후)
      // 명시적 새로고침은 불필요하지만, 필요시 아래 주석 해제
      // final memberProvider = Provider.of<MemberProvider>(context, listen: false);
      // await memberProvider.loadMembers(placeId);
    } catch (e) {
      SnackbarUtil.showError(context, '멤버 등록 중 오류가 발생했습니다: $e');
    }
  }
}
