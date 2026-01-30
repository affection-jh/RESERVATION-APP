import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reservation/utils/text_field_decoration_util.dart';
import '../../../models/course.dart';
import '../../../models/user.dart';
import '../../../models/course_enrollment.dart';
import '../../../theme/app_colors.dart';
import '../../../providers/member_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../utils/format_utils.dart';

/// 멤버 선택 바텀시트
class MemberSelectionSidePanel extends StatefulWidget {
  final Course course;
  final int totalCapacity;
  final int reservedCount;
  final List<String> existingReservationUserIds; // 이미 예약한 멤버 ID 목록
  final Function(List<User> users) onMembersSelected;

  const MemberSelectionSidePanel({
    super.key,
    required this.course,
    required this.totalCapacity,
    required this.reservedCount,
    required this.existingReservationUserIds,
    required this.onMembersSelected,
  });

  static void show({
    required BuildContext context,
    required Course course,
    required int totalCapacity,
    required int reservedCount,
    required List<String> existingReservationUserIds,
    required Function(List<User> users) onMembersSelected,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.7),
      isDismissible: true,
      enableDrag: true,
      builder:
          (context) => MemberSelectionSidePanel(
            course: course,
            totalCapacity: totalCapacity,
            reservedCount: reservedCount,
            existingReservationUserIds: existingReservationUserIds,
            onMembersSelected: onMembersSelected,
          ),
    );
  }

  @override
  State<MemberSelectionSidePanel> createState() =>
      _MemberSelectionSidePanelState();
}

class _MemberSelectionSidePanelState extends State<MemberSelectionSidePanel> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<User> _allMembers = [];
  Set<String> _selectedUserIds = {}; // 선택된 멤버 ID들
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadMembers();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text;
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadMembers() async {
    setState(() => _isLoading = true);

    try {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final memberProvider = Provider.of<MemberProvider>(
        context,
        listen: false,
      );

      // 관리자 정보에서 플레이스 ID 가져오기
      if (authProvider.currentAdmin != null) {
        final admin = authProvider.currentAdmin!;
        if (admin.placeIds.isNotEmpty) {
          final placeId = admin.lastAccessedPlaceId ?? admin.placeIds.first;
          await memberProvider.loadMembers(placeId);

          // 전체 멤버 표시 (members + pendingMembers)
          final allMembers = memberProvider.members;

          // pendingMembers를 User로 변환
          final pendingMembers = memberProvider.pendingMembers;
          final pendingAsUsers =
              pendingMembers.map((pm) {
                // courseEnrollments를 CourseEnrollment 리스트로 변환
                final enrollments = <CourseEnrollment>[];
                if (pm.courseEnrollments != null &&
                    pm.courseEnrollments!.isNotEmpty) {
                  for (final enrollmentData in pm.courseEnrollments!) {
                    try {
                      final courseId = enrollmentData['courseId']?.toString();
                      if (courseId == null || courseId.isEmpty) continue;

                      final totalReservations =
                          enrollmentData['totalReservations'] as int? ?? 10;
                      final remainingReservations =
                          enrollmentData['remainingReservations'] as int? ??
                          totalReservations;

                      DateTime validFrom;
                      if (enrollmentData['validFrom'] != null) {
                        if (enrollmentData['validFrom'] is String) {
                          validFrom = DateTime.parse(
                            enrollmentData['validFrom'] as String,
                          );
                        } else {
                          validFrom = pm.createdAt;
                        }
                      } else {
                        validFrom = pm.createdAt;
                      }

                      DateTime validUntil;
                      if (enrollmentData['validUntil'] != null) {
                        if (enrollmentData['validUntil'] is String) {
                          validUntil = DateTime.parse(
                            enrollmentData['validUntil'] as String,
                          );
                        } else {
                          validUntil = pm.createdAt.add(
                            const Duration(days: 365),
                          );
                        }
                      } else {
                        validUntil = pm.createdAt.add(
                          const Duration(days: 365),
                        );
                      }

                      enrollments.add(
                        CourseEnrollment(
                          id: 'pending_${pm.id}_$courseId',
                          userId: 'pending_${pm.id}',
                          courseId: courseId,
                          placeId: pm.placeId,
                          enrolledAt: pm.createdAt,
                          validFrom: validFrom,
                          validUntil: validUntil,
                          totalReservations: totalReservations,
                          remainingReservations: remainingReservations,
                        ),
                      );
                    } catch (e) {
                      // 변환 실패 시 스킵
                      debugPrint('Failed to convert courseEnrollment: $e');
                    }
                  }
                } else {
                  // courseEnrollments가 없으면 derivedCourseIds 사용 (하위 호환)
                  final courseIds = pm.derivedCourseIds;
                  for (final courseId in courseIds) {
                    enrollments.add(
                      CourseEnrollment(
                        id: 'pending_${pm.id}_$courseId',
                        userId: 'pending_${pm.id}',
                        courseId: courseId,
                        placeId: pm.placeId,
                        enrolledAt: pm.createdAt,
                        validFrom: pm.createdAt,
                        validUntil: pm.createdAt.add(const Duration(days: 365)),
                        totalReservations: 10,
                        remainingReservations: 10,
                      ),
                    );
                  }
                }

                return User(
                  userId: 'pending_${pm.id}',
                  name: pm.name ?? '이름 없음',
                  phoneNumber: pm.phoneNumber,
                  placeIds: [pm.placeId],
                  enrollments: enrollments,
                  reservations: const [],
                  notificationsEnabled: false,
                  createdAt: pm.createdAt,
                  updatedAt: null,
                );
              }).toList();

          // members + pendingMembers 합치기
          final combinedMembers = [...allMembers, ...pendingAsUsers];

          // 이미 예약한 멤버는 제외
          final filteredMembers =
              combinedMembers
                  .where(
                    (user) =>
                        !widget.existingReservationUserIds.contains(
                          user.userId,
                        ),
                  )
                  .toList();

          setState(() {
            _allMembers = filteredMembers;
            _isLoading = false;
          });
          return;
        }
      }

      setState(() {
        _allMembers = [];
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _allMembers = [];
        _isLoading = false;
      });
    }
  }

  List<User> get _filteredMembers {
    if (_searchQuery.isEmpty) {
      return _allMembers;
    }
    final query = _searchQuery.toLowerCase();
    return _allMembers.where((user) {
      // 이름과 전화번호 둘 다 검색 지원 (관리자가 생성한 이름)
      final name = user.name.toLowerCase();
      final phone = user.phoneNumber.toLowerCase();
      return name.contains(query) || phone.contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final screenHeight = MediaQuery.of(context).size.height;
    final maxHeight = screenHeight * 0.7;

    return Container(
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: const BoxDecoration(color: Colors.transparent),
      child: Stack(
        children: [
          // 배경 탭 시 닫기
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(color: Colors.transparent),
            ),
          ),
          // 바텀시트 컨텐츠
          Align(
            alignment: Alignment.bottomCenter,
            child: GestureDetector(
              onTap: () {},
              child: Container(
                constraints: BoxConstraints(maxHeight: maxHeight),
                decoration: BoxDecoration(
                  color: AppColors.backgroundWhite,
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 16),
                    // 검색 바
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: TextField(
                        controller: _searchController,
                        decoration: TextFieldDecorationUtil.standardDecoration(
                          hintText: '검색해서 추가하기',
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                        ).copyWith(
                          prefixIcon: Icon(
                            Icons.search,
                            color: AppColors.textSecondary,
                            size: 20,
                          ),
                          suffixIcon: IconButton(
                            icon: Icon(
                              Icons.close,
                              color: AppColors.textSecondary,
                              size: 20,
                            ),
                            onPressed: () {
                              if (_searchQuery.isNotEmpty) {
                                // 검색어가 있으면 검색어 지우기
                                _searchController.clear();
                              } else {
                                // 검색어가 없으면 바텀시트 닫기
                                Navigator.of(context).pop();
                              }
                            },
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // 멤버 리스트 (고정 높이로 요동 방지)
                    Expanded(
                      child:
                          _isLoading
                              ? Center(
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                    color: AppColors.primaryGreen,
                                  ),
                                ),
                              )
                              : _filteredMembers.isEmpty
                              ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(40),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        _searchQuery.isEmpty
                                            ? '추가 할 수 있는 멤버가 없어요'
                                            : '검색 결과가 없습니다',
                                        style: TextStyle(
                                          fontSize: 16,
                                          color: AppColors.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                              : ListView.separated(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                ),
                                shrinkWrap: false,
                                itemCount: _filteredMembers.length,
                                separatorBuilder:
                                    (context, index) => Divider(
                                      height: 1,
                                      color: AppColors.borderLight.withOpacity(
                                        0.5,
                                      ),
                                    ),
                                itemBuilder: (context, index) {
                                  final user = _filteredMembers[index];
                                  return _buildMemberItem(user);
                                },
                              ),
                    ),
                    // 하단 버튼 영역 (항상 표시하여 높이 고정)
                    if (!_isLoading)
                      Container(
                        padding: EdgeInsets.only(
                          left: 20,
                          right: 20,
                          top: 12,
                          bottom: 20 + bottomInset,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.backgroundWhite,
                          border: Border(
                            top: BorderSide(
                              color: AppColors.borderLight.withOpacity(0.5),
                              width: 1,
                            ),
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 0),
                            // 추가하기 버튼
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                onPressed:
                                    _selectedUserIds.isEmpty
                                        ? null
                                        : () {
                                          final selectedUsers =
                                              _allMembers
                                                  .where(
                                                    (user) => _selectedUserIds
                                                        .contains(user.userId),
                                                  )
                                                  .toList();
                                          widget.onMembersSelected(
                                            selectedUsers,
                                          );
                                          Navigator.of(context).pop();
                                        },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.primaryGreen,
                                  foregroundColor: Colors.white,
                                  disabledBackgroundColor:
                                      AppColors.backgroundLight,
                                  disabledForegroundColor:
                                      AppColors.textSecondary,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 16,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  elevation: 0,
                                ),
                                child: Text(
                                  '추가하기',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMemberItem(User user) {
    final isSelected = _selectedUserIds.contains(user.userId);
    final isEnrolled = user.isEnrolledInCourse(widget.course.id);
    final remaining = user.getRemainingReservations(widget.course.id);

    // 관리자 권한으로 모든 멤버 선택 가능 (등록 여부와 관계없이)
    return InkWell(
      onTap: () {
        setState(() {
          if (isSelected) {
            _selectedUserIds.remove(user.userId);
          } else {
            _selectedUserIds.add(user.userId);
          }
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
        child: Row(
          children: [
            // 원형 체크박스
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color:
                      isSelected
                          ? AppColors.primaryGreen
                          : AppColors.borderLight,
                  width: 2,
                ),
                color: isSelected ? AppColors.primaryGreen : Colors.transparent,
              ),
              child:
                  isSelected
                      ? Icon(Icons.check, size: 16, color: Colors.white)
                      : null,
            ),
            const SizedBox(width: 12),
            // 멤버 정보
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        user.name,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      if (isEnrolled) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.primaryGreen,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '등록됨',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    FormatUtils.formatPhoneNumber(user.phoneNumber),
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    isEnrolled ? '남은 횟수: $remaining' : '이 코스에 등록되지 않음',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary.withOpacity(0.6),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
