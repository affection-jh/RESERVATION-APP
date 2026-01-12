import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
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
import '../../models/course_member.dart';
import '../../utils/text_field_decoration_util.dart';
import '../../services/member_service.dart';
import '../../services/user_service.dart';
import '../../services/enrollment_service.dart';
import '../../utils/snackbar_util.dart';

class AdminMemberScreen extends StatefulWidget {
  const AdminMemberScreen({super.key});

  @override
  State<AdminMemberScreen> createState() => _AdminMemberScreenState();
}

class _AdminMemberScreenState extends State<AdminMemberScreen> {
  // 검색 및 필터 상태
  String _searchQuery = '';
  int _selectedTab = 0; // 0: 전체, 1: 코스별, 2: 요청, 3: 활성
  final Set<String> _selectedCourseIds = {}; // 중복 선택 가능
  bool _isCourseSelectorExpanded = true; // 코스 선택기 펼침/접힘 상태
  final TextEditingController _searchController = TextEditingController();

  // 연장 요청 스트림 캐싱 (구독 재시작 방지)
  Stream<List<CourseEnrollment>>? _cachedExtensionRequestsStream;
  String? _cachedStreamPlaceId;
  List<String>? _cachedStreamCourseIds;

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
    if (currentPlace == null) {
      debugPrint('[AdminMemberScreen] currentPlace is null');
      return;
    }

    try {
      // AdminScreen에서 로드하지 않은 경우에만 로드
      if (courseProvider.courses.isEmpty) {
        debugPrint(
          '[AdminMemberScreen] Loading courses for placeId=${currentPlace.id}',
        );
        await courseProvider.loadCourses(currentPlace.id);
      }

      // 멤버는 항상 로드 (구독이 제대로 되도록)
      debugPrint(
        '[AdminMemberScreen] Loading members for placeId=${currentPlace.id}',
      );
      debugPrint(
        '[AdminMemberScreen] Current members count: ${memberProvider.members.length}',
      );
      debugPrint(
        '[AdminMemberScreen] Current pendingMembers count: ${memberProvider.pendingMembers.length}',
      );
      await memberProvider.loadMembers(currentPlace.id);
      debugPrint(
        '[AdminMemberScreen] After loadMembers - members count: ${memberProvider.members.length}',
      );
      debugPrint(
        '[AdminMemberScreen] After loadMembers - pendingMembers count: ${memberProvider.pendingMembers.length}',
      );
    } catch (e) {
      debugPrint('[AdminMemberScreen] Error loading data: $e');
      // 에러 발생 시에도 계속 진행
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    // 스트림은 자동으로 취소되므로 명시적 취소 불필요
    super.dispose();
  }

  // 리스트 비교 헬퍼
  bool _listsEqual(List<String>? a, List<String>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // 필터링된 멤버 목록
  List<User> _filteredMembers(List<User> members) {
    var filtered = members;

    // 탭별 필터는 각 빌더에서 처리 (요청 탭은 _buildRequestMemberList에서 처리)

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

        // 멤버 리스트
        // 코스별 탭일 때는 courseMembers 컬렉션 직접 조회 + pendingMembers
        // 요청 탭일 때는 연장 요청이 있는 멤버만 조회
        // 활성 탭일 때는 활성 enrollments를 가진 멤버만 조회
        Expanded(
          child: _selectedTab == 1 && _selectedCourseIds.isNotEmpty
              ? _buildCourseMemberList(memberProvider, courseProvider.courses)
              : _selectedTab == 2
              ? _buildRequestMemberList(memberProvider)
              : _selectedTab == 3
              ? _buildActiveMemberList(memberProvider)
              : memberProvider.isLoading
              ? const Center(
                  child: CircularProgressIndicator(
                    color: AppColors.primaryGreen,
                  ),
                )
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
        labels: ['전체', '코스별', '요청', '활성'],
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
  // 주의: enrollments는 users 문서에 없으므로 빈 배열 반환
  // 실제 enrollments는 enrollments 컬렉션에서 조회해야 함
  MemberData _userToMemberData(User user) {
    // users 문서의 enrollments 필드는 더 이상 사용하지 않음
    // 실제 enrollments는 enrollments 컬렉션에서 조회해야 하지만,
    // MemberData에는 enrolledCourseIds만 필요하므로 빈 배열 반환
    // (코스별 탭에서는 courseMembers에서 이미 필터링됨)
    return MemberData(
      userId: user.userId,
      name: user.name,
      phoneNumber: user.phoneNumber,
      role: '일반',
      isActive: true,
      pendingExtensionRequests: 0, // enrollments 컬렉션에서 조회 필요
      enrolledCourseIds: [], // enrollments 컬렉션에서 조회 필요
    );
  }

  // PendingMember를 MemberData로 변환 (임시 User로 표시)
  MemberData _pendingMemberToMemberData(PendingMember pendingMember) {
    // ⚠️ courseIds 제거: courseEnrollments에서 유도
    final enrolledCourseIds = pendingMember.derivedCourseIds;

    return MemberData(
      userId: 'pending_${pendingMember.id}', // 임시 ID
      name: pendingMember.name ?? '이름 없음',
      phoneNumber: pendingMember.phoneNumber,
      role: '대기중', // pending 상태 표시
      isActive: false, // 아직 로그인하지 않음
      pendingExtensionRequests: 0,
      enrolledCourseIds: enrolledCourseIds,
    );
  }

  // 코스별 멤버 리스트 (courseMembers 컬렉션 직접 조회 + pendingMembers)
  Widget _buildCourseMemberList(
    MemberProvider memberProvider,
    List<Course> courses,
  ) {
    // 선택된 모든 코스의 멤버를 조회
    final selectedCourseIds = _selectedCourseIds.toList();

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

    // 단일 코스 선택 시
    if (selectedCourseIds.length == 1) {
      final selectedCourseId = selectedCourseIds.first;

      return StreamBuilder<List<User>>(
        stream: memberProvider.watchCourseMembers(selectedCourseId),
        builder: (context, snapshot) {
          // 기존 데이터가 있으면 먼저 표시 (탭 전환 시 로딩 제거)
          final courseMembers = snapshot.hasData ? snapshot.data! : <User>[];

          if (snapshot.hasError) {
            return Center(
              child: Text(
                '오류가 발생했습니다: ${snapshot.error}',
                style: TextStyle(
                  color: AppColors.textSecondary.withOpacity(0.8),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            );
          }

          // pendingMembers도 포함 (선택된 코스에 등록된 것만)
          final placeProvider = Provider.of<PlaceProvider>(
            context,
            listen: false,
          );
          final placeId = placeProvider.currentPlace?.id;
          final pendingMembers = placeId != null
              ? memberProvider.pendingMembers.where((pm) {
                  // ⚠️ courseIds 제거: courseEnrollments에서 유도
                  final courseIds = pm.derivedCourseIds;
                  return courseIds.contains(selectedCourseId);
                }).toList()
              : <PendingMember>[];

          // pendingMembers를 User로 변환
          final pendingAsUsers = pendingMembers.map((pm) {
            return User(
              userId: 'pending_${pm.id}',
              name: pm.name ?? '이름 없음',
              phoneNumber: pm.phoneNumber,
              placeIds: [pm.placeId],
              enrollments: const [], // enrollments 필드 사용 안 함
              reservations: const [],
              notificationsEnabled: false,
              createdAt: pm.createdAt,
              updatedAt: null,
            );
          }).toList();

          // courseMembers + pendingMembers 합치기
          final allMembers = [...courseMembers, ...pendingAsUsers];
          final filteredMembers = _filteredMembers(allMembers);

          if (filteredMembers.isEmpty) {
            return Center(
              child: Text(
                _searchQuery.isNotEmpty ? '검색 결과가 없어요.' : '등록된 멤버가 없어요.',
                style: TextStyle(
                  color: AppColors.textSecondary.withOpacity(0.8),
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
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
        },
      );
    } else {
      // 여러 코스 선택 시: 첫 번째 코스를 기준으로 하고 나머지는 클라이언트 사이드에서 필터링
      // (실시간 업데이트를 위해 첫 번째 코스의 Stream 사용)
      final firstCourseId = selectedCourseIds.first;

      return StreamBuilder<List<User>>(
        stream: memberProvider.watchCourseMembers(firstCourseId),
        builder: (context, snapshot) {
          // 기존 데이터가 있으면 먼저 표시 (탭 전환 시 로딩 제거)
          final courseMembers = snapshot.hasData ? snapshot.data! : <User>[];

          if (snapshot.hasError) {
            return Center(
              child: Text(
                '오류가 발생했습니다: ${snapshot.error}',
                style: TextStyle(
                  color: AppColors.textSecondary.withOpacity(0.8),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            );
          }

          // pendingMembers도 포함 (선택된 코스 중 하나라도 등록된 것만)
          final placeProvider = Provider.of<PlaceProvider>(
            context,
            listen: false,
          );
          final placeId = placeProvider.currentPlace?.id;
          final pendingMembers = placeId != null
              ? memberProvider.pendingMembers.where((pm) {
                  // ⚠️ courseIds 제거: courseEnrollments에서 유도
                  final courseIds = pm.derivedCourseIds;
                  return selectedCourseIds.any(
                    (courseId) => courseIds.contains(courseId),
                  );
                }).toList()
              : <PendingMember>[];

          // pendingMembers를 User로 변환
          final pendingAsUsers = pendingMembers.map((pm) {
            return User(
              userId: 'pending_${pm.id}',
              name: pm.name ?? '이름 없음',
              phoneNumber: pm.phoneNumber,
              placeIds: [pm.placeId],
              enrollments: const [], // enrollments 필드 사용 안 함
              reservations: const [],
              notificationsEnabled: false,
              createdAt: pm.createdAt,
              updatedAt: null,
            );
          }).toList();

          // courseMembers + pendingMembers 합치기
          final allMembers = [...courseMembers, ...pendingAsUsers];
          final filteredMembers = _filteredMembers(allMembers);

          if (filteredMembers.isEmpty) {
            return Center(
              child: Text(
                _searchQuery.isNotEmpty ? '검색 결과가 없어요.' : '등록된 멤버가 없어요.',
                style: TextStyle(
                  color: AppColors.textSecondary.withOpacity(0.8),
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
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
        },
      );
    }
  }

  // 요청 탭: 연장 요청이 있는 멤버만 표시
  Widget _buildRequestMemberList(MemberProvider memberProvider) {
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final placeId = placeProvider.currentPlace?.id;
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);

    if (placeId == null) {
      return Center(
        child: Text(
          '플레이스를 찾을 수 없습니다.',
          style: TextStyle(
            color: AppColors.textSecondary.withOpacity(0.8),
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    final enrollmentService = EnrollmentService();
    final courseIds = courseProvider.courses.map((c) => c.id).toList();

    // 스트림 캐싱: placeId와 courseIds가 변경되었을 때만 새 스트림 생성
    final courseIdsSorted = List<String>.from(courseIds)..sort();
    if (_cachedExtensionRequestsStream == null ||
        _cachedStreamPlaceId != placeId ||
        !_listsEqual(_cachedStreamCourseIds, courseIdsSorted)) {
      _cachedExtensionRequestsStream = enrollmentService
          .watchExtensionRequestsByCourseIds(
            courseIds: courseIds,
            placeId: placeId,
          );
      _cachedStreamPlaceId = placeId;
      _cachedStreamCourseIds = courseIdsSorted;
    }

    return StreamBuilder<List<CourseEnrollment>>(
      stream: _cachedExtensionRequestsStream,
      builder: (context, snapshot) {
        // 기존 데이터가 있으면 먼저 표시 (탭 전환 시 로딩 제거)
        final enrollmentsWithRequests = snapshot.hasData
            ? snapshot.data!
            : <CourseEnrollment>[];

        if (snapshot.hasError) {
          return Center(
            child: Text(
              '오류가 발생했습니다: ${snapshot.error}',
              style: TextStyle(
                color: AppColors.textSecondary.withOpacity(0.8),
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          );
        }

        // userId 중복 제거 (여러 코스에 연장 요청이 있어도 한 번만 표시)
        final requestUserIds = enrollmentsWithRequests
            .map((e) => e.userId)
            .where((id) => id.isNotEmpty && !id.startsWith('pending_'))
            .toSet()
            .toList();

        if (requestUserIds.isEmpty) {
          return Center(
            child: Text(
              _searchQuery.isNotEmpty ? '검색 결과가 없어요.' : '요청이 있는 멤버가 없어요.',
              style: TextStyle(
                color: AppColors.textSecondary.withOpacity(0.8),
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          );
        }

        // ⚠️ MemberProvider.members는 "courseMembers 기반"이라
        // 남은 횟수 0/만료 등의 케이스에서 누락될 수 있음.
        // 요청탭은 enrollment 기준으로 userId를 확보했으므로, 누락된 유저는 직접 조회해서 보강한다.
        final byId = <String, User>{
          for (final u in memberProvider.members) u.userId: u,
        };
        final missingIds = <String>[];
        for (final id in requestUserIds) {
          if (!byId.containsKey(id)) {
            missingIds.add(id);
          }
        }

        // enrollmentsWithRequests를 userId별로 그룹화 (buildList에서 사용)
        final enrollmentsByUserId = <String, List<CourseEnrollment>>{};
        for (final enrollment in enrollmentsWithRequests) {
          enrollmentsByUserId
              .putIfAbsent(enrollment.userId, () => [])
              .add(enrollment);
        }

        Widget buildListWithRequests(List<User> users) {
          final filteredMembers = _filteredMembers(users);
          if (filteredMembers.isEmpty) {
            return Center(
              child: Text(
                _searchQuery.isNotEmpty ? '검색 결과가 없어요.' : '요청이 있는 멤버가 없어요.',
                style: TextStyle(
                  color: AppColors.textSecondary.withOpacity(0.8),
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
              // 해당 멤버의 연장 요청 찾기
              final memberEnrollments =
                  enrollmentsByUserId[member.userId] ?? [];
              final extensionRequestCount = memberEnrollments.length;
              final courseNames = memberEnrollments
                  .map((e) => e.courseName ?? '알 수 없음')
                  .where((name) => name.isNotEmpty)
                  .toSet()
                  .toList();

              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: MemberCard(
                  member: _userToMemberData(member),
                  onMemberTapped: () {},
                  extensionRequestInfo: extensionRequestCount > 0
                      ? ExtensionRequestInfo(
                          count: extensionRequestCount,
                          courseNames: courseNames,
                        )
                      : null,
                ),
              );
            },
          );
        }

        if (missingIds.isEmpty) {
          // requestUserIds 순서대로 정렬
          final ordered = requestUserIds
              .map((id) => byId[id])
              .whereType<User>()
              .toList();
          return buildListWithRequests(ordered);
        }

        final userService = UserService();
        return FutureBuilder<List<User>>(
          future: userService.getUsersByIds(missingIds),
          builder: (context, userSnap) {
            // 기존 데이터가 있으면 먼저 표시 (탭 전환 시 로딩 제거)
            final fetched = userSnap.hasData ? userSnap.data! : const <User>[];

            // 기존 데이터가 없고 로딩 중일 때만 빈 화면 표시
            if (userSnap.connectionState == ConnectionState.waiting &&
                byId.isEmpty &&
                fetched.isEmpty) {
              return const SizedBox.shrink();
            }
            final mergedById = <String, User>{
              ...byId,
              for (final u in fetched) u.userId: u,
            };
            final ordered = requestUserIds
                .map((id) => mergedById[id])
                .whereType<User>()
                .toList();

            if (userSnap.hasError && ordered.isEmpty) {
              return Center(
                child: Text(
                  '요청 멤버 정보를 불러오지 못했어요: ${userSnap.error}',
                  style: TextStyle(
                    color: AppColors.textSecondary.withOpacity(0.8),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              );
            }

            return buildListWithRequests(ordered);
          },
        );
      },
    );
  }

  // 활성 멤버 리스트 (유효기간 남고 횟수 남은 멤버만, pending members 포함)
  Widget _buildActiveMemberList(MemberProvider memberProvider) {
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final placeId = placeProvider.currentPlace?.id;

    if (placeId == null) {
      return Center(
        child: Text(
          '플레이스를 찾을 수 없습니다.',
          style: TextStyle(
            color: AppColors.textSecondary.withOpacity(0.8),
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    final enrollmentService = EnrollmentService();

    return StreamBuilder<List<CourseMember>>(
      stream: enrollmentService.watchPlaceCourseMembers(
        placeId: placeId,
        isActive: true, // 활성 멤버만 조회
      ),
      builder: (context, snapshot) {
        // 기존 데이터가 있으면 먼저 표시 (탭 전환 시 로딩 제거)
        final activeCourseMembers = snapshot.hasData
            ? snapshot.data!
            : <CourseMember>[];

        if (snapshot.hasError) {
          return Center(
            child: Text(
              '오류가 발생했습니다: ${snapshot.error}',
              style: TextStyle(
                color: AppColors.textSecondary.withOpacity(0.8),
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          );
        }

        // userId 중복 제거
        final activeUserIds = activeCourseMembers
            .map((cm) => cm.userId)
            .where((id) => id.isNotEmpty && !id.startsWith('pending_'))
            .toSet()
            .toList();

        // 활성 멤버 필터링
        final activeMembers = memberProvider.members
            .where((user) => activeUserIds.contains(user.userId))
            .toList();

        // pending members도 포함 (유효기간과 횟수 확인)
        final placeProvider = Provider.of<PlaceProvider>(
          context,
          listen: false,
        );
        final placeId = placeProvider.currentPlace?.id;
        final now = DateTime.now();

        final activePendingMembers = placeId != null
            ? memberProvider.pendingMembers.where((pm) {
                // courseEnrollments에서 유효기간과 횟수 확인
                final courseEnrollments = pm.courseEnrollments ?? [];
                return courseEnrollments.any((enrollment) {
                  final validUntil = enrollment['validUntil'];
                  if (validUntil == null) return false;

                  DateTime validUntilDate;
                  if (validUntil is Timestamp) {
                    validUntilDate = validUntil.toDate();
                  } else if (validUntil is String) {
                    validUntilDate = DateTime.parse(validUntil);
                  } else {
                    return false;
                  }

                  // 유효기간이 만료되지 않았고 횟수가 남아있는지 확인
                  // pending member는 remainingReservations가 없을 수 있으므로
                  // totalReservations를 기본값으로 사용
                  final totalReservations =
                      enrollment['totalReservations'] as int? ?? 0;
                  final remainingReservations =
                      enrollment['remainingReservations'] as int? ??
                      totalReservations; // remainingReservations가 없으면 totalReservations 사용
                  return now.isBefore(validUntilDate) &&
                      remainingReservations > 0;
                });
              }).toList()
            : <PendingMember>[];

        // pending members를 User로 변환
        final activePendingAsUsers = activePendingMembers.map((pm) {
          return User(
            userId: 'pending_${pm.id}',
            name: pm.name ?? '이름 없음',
            phoneNumber: pm.phoneNumber,
            placeIds: [pm.placeId],
            enrollments: const [], // enrollments 필드 사용 안 함
            reservations: const [],
            notificationsEnabled: false,
            createdAt: pm.createdAt,
            updatedAt: null,
          );
        }).toList();

        // 활성 멤버 + 활성 pending members 합치기
        final allActiveMembers = [...activeMembers, ...activePendingAsUsers];

        // 검색 필터 적용
        final filteredMembers = _filteredMembers(allActiveMembers);

        if (filteredMembers.isEmpty) {
          return Center(
            child: Text(
              _searchQuery.isNotEmpty ? '검색 결과가 없어요.' : '활성 멤버가 없어요.',
              style: TextStyle(
                color: AppColors.textSecondary.withOpacity(0.8),
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
                        activePendingMembers.firstWhere(
                          (pm) => 'pending_${pm.id}' == member.userId,
                        ),
                      )
                    : _userToMemberData(member),
                onMemberTapped: () {},
              ),
            );
          },
        );
      },
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
      // ⚠️ courseIds 제거: courseEnrollments에서 유도
      final courseIds = pm.derivedCourseIds;
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
            color: AppColors.textSecondary.withOpacity(0.8),
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
      // MemberProvider는 스트림을 사용하지만, 즉시 동기화를 보장하기 위해 명시적 새로고침
      final memberProvider = Provider.of<MemberProvider>(
        context,
        listen: false,
      );
      await memberProvider.loadMembers(placeId);
    } catch (e) {
      SnackbarUtil.showError(context, '멤버 등록 중 오류가 발생했습니다: $e');
    }
  }
}
