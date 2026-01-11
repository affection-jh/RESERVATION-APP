import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reservation/utils/text_field_decoration_util.dart';
import '../../../models/course.dart';
import '../../../models/user.dart';
import '../../../theme/app_colors.dart';
import '../../../providers/member_provider.dart';
import '../../../providers/auth_provider.dart';

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
      builder: (context) => MemberSelectionSidePanel(
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

          // 필터링: 해당 코스에 등록한 멤버만, 이미 예약한 멤버는 제외
          final allMembers = memberProvider.members;
          final filteredMembers = allMembers.where((user) {
            // 1. 해당 코스에 등록되어 있는지 확인
            final isEnrolled = user.isEnrolledInCourse(widget.course.id);
            if (!isEnrolled) return false;

            // 2. 이미 예약한 멤버는 제외
            final isAlreadyReserved = widget.existingReservationUserIds
                .contains(user.userId);
            if (isAlreadyReserved) return false;

            return true;
          }).toList();

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
      final name = user.name.toLowerCase();
      final phone = user.phoneNumber.toLowerCase();
      return name.contains(query) || phone.contains(query);
    }).toList();
  }

  bool get _isCapacityFull {
    return widget.reservedCount >= widget.totalCapacity;
  }

  bool get _isExceedingCapacity {
    final remainingCapacity = widget.totalCapacity - widget.reservedCount;
    return _selectedUserIds.length > remainingCapacity;
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final screenHeight = MediaQuery.of(context).size.height;
    final maxHeight = screenHeight * 0.9;

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
                        decoration:
                            TextFieldDecorationUtil.standardDecoration(
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
                    // 멤버 리스트
                    Flexible(
                      child: _isLoading
                          ? Center(
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
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
                                          ? '추가할 수 있는 멤버가 없어요'
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
                              shrinkWrap: true,
                              itemCount: _filteredMembers.length,
                              separatorBuilder: (context, index) => Divider(
                                height: 1,
                                color: AppColors.borderLight.withOpacity(0.5),
                              ),
                              itemBuilder: (context, index) {
                                final user = _filteredMembers[index];
                                return _buildMemberItem(user);
                              },
                            ),
                    ),
                    // 하단 버튼 영역
                    if (!_isLoading && _filteredMembers.isNotEmpty)
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
                            // 설명 텍스트
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _selectedUserIds.isEmpty
                                      ? '멤버를 선택해주세요'
                                      : '${_selectedUserIds.length}명 선택됨',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                                if (_selectedUserIds.isNotEmpty &&
                                    _isExceedingCapacity)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      '수용인원을 초과합니다',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.red,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            // 추가하기 버튼
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                onPressed: _selectedUserIds.isEmpty
                                    ? null
                                    : () {
                                        final selectedUsers = _allMembers
                                            .where(
                                              (user) => _selectedUserIds
                                                  .contains(user.userId),
                                            )
                                            .toList();
                                        widget.onMembersSelected(selectedUsers);
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
                                  _isCapacityFull ? '관리자 권한으로 추가' : '추가하기',
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
    final canReserve = user.canReserveCourse(widget.course.id);
    final remaining = user.getRemainingReservations(widget.course.id);

    return InkWell(
      onTap: canReserve
          ? () {
              setState(() {
                if (isSelected) {
                  _selectedUserIds.remove(user.userId);
                } else {
                  _selectedUserIds.add(user.userId);
                }
              });
            }
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            // 원형 체크박스
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected
                      ? AppColors.primaryGreen
                      : (canReserve
                            ? AppColors.borderLight
                            : AppColors.borderLight.withOpacity(0.5)),
                  width: 2,
                ),
                color: isSelected ? AppColors.primaryGreen : Colors.transparent,
              ),
              child: isSelected
                  ? Icon(Icons.check, size: 16, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 12),
            // 멤버 정보
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.name,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: canReserve
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    user.phoneNumber,
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    canReserve ? '남은 횟수: $remaining' : '남은 횟수가 없어 추가할 수 없음',
                    style: TextStyle(
                      fontSize: 12,
                      color: canReserve ? AppColors.textSecondary : Colors.red,
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
