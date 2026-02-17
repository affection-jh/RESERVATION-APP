import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reservation/utils/text_field_decoration_util.dart';
import '../../../models/course.dart';
import '../../../models/member_view.dart';
import '../../../models/course_enrollment.dart';
import '../../../theme/app_colors.dart';
import '../../../providers/member_provider.dart';
import '../../../utils/format_utils.dart';

/// 멤버 선택 바텀시트 (예약 추가용)
///
/// 【데이터 소스】
/// - totalCapacity, reservedCount: ReservationSummaryProvider (reservationSummary 구독)
/// - existingReservationUserIds: watchSessionReservations (reservations 구독) → 이미 예약한 유저 제외
/// - 멤버 목록: MemberProvider (places/{placeId}/members)
///
/// SessionDetailScreen에서 호출. N/M은 reservationSummary, 예약자 목록(누가)은 reservations.
class MemberSelectionSidePanel extends StatefulWidget {
  final String placeId;
  final Course course;
  final int totalCapacity;
  final int reservedCount;
  final List<String> existingReservationUserIds;
  final Function(List<MemberView> members) onMembersSelected;

  const MemberSelectionSidePanel({
    super.key,
    required this.placeId,
    required this.course,
    required this.totalCapacity,
    required this.reservedCount,
    required this.existingReservationUserIds,
    required this.onMembersSelected,
  });

  static void show({
    required BuildContext context,
    required String placeId,
    required Course course,
    required int totalCapacity,
    required int reservedCount,
    required List<String> existingReservationUserIds,
    required Function(List<MemberView> members) onMembersSelected,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.7),
      isDismissible: true,
      enableDrag: true,
      useSafeArea: true,
      builder:
          (context) => MemberSelectionSidePanel(
            placeId: placeId,
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
  Set<String> _selectedUserIds = {};

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text);
    });
    // Provider 업데이트는 빌드 완료 후로 미룸 (setState during build 방지)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final memberProvider = Provider.of<MemberProvider>(
        context,
        listen: false,
      );
      memberProvider.setPlaceId(widget.placeId);
      memberProvider.setSelectedCourseId(widget.course.id);
      memberProvider.setShowPending(true);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<MemberView> _getDisplayMembers(MemberProvider memberProvider) {
    final all = memberProvider.allMembers;
    return all
        .where((v) => !widget.existingReservationUserIds.contains(v.userId))
        .toList();
  }

  List<MemberView> _filterBySearch(List<MemberView> members, String query) {
    if (query.isEmpty) return members;
    final q = query.trim().toLowerCase();
    final digitsOnly = q.replaceAll(RegExp(r'[^\d]'), '');
    return members.where((v) {
      final name = (v.adminDisplayName).trim().toLowerCase();
      final phone = v.phoneNumber.replaceAll(RegExp(r'[^\d]'), '');
      final nameMatch = name.contains(q);
      final phoneMatch = digitsOnly.isNotEmpty && phone.contains(digitsOnly);
      return nameMatch || phoneMatch;
    }).toList();
  }

  /// 코스별 남은 횟수 (MemberProvider.enrollments 단일 소스 — 멤버관리 등과 동일)
  int _getRemainingForCourse(MemberView v, List<CourseEnrollment> enrollments) {
    final matches =
        enrollments
            .where(
              (e) => e.userId == v.userId && e.courseId == widget.course.id,
            )
            .toList();
    if (matches.isEmpty) return 0;
    return matches.first.remainingReservations;
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final viewInsetsBottom = mq.viewInsets.bottom;
    final paddingBottom = mq.padding.bottom;
    final screenHeight = mq.size.height;

    // 처음 올라온 높이 85% 유지 (키보드 여부와 관계없이 동일)
    final panelHeight = screenHeight * 0.85;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsetsBottom),
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          // 배경 탭 시 닫기
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
          ),
          // 패널: 정석 Column(헤더 | 본문(Expanded) | 푸터), 높이 85% 고정
          Material(
            color: Colors.transparent,
            child: Container(
              height: panelHeight,
              decoration: BoxDecoration(
                color: AppColors.backgroundWhite,
                borderRadius: BorderRadius.circular(30),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  _buildHeader(),
                  _buildBody(),
                  _buildFooter(paddingBottom),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 상단: 검색창만 (고정 높이)
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: TextField(
        controller: _searchController,
        decoration: TextFieldDecorationUtil.standardDecoration(
          hintText: '추가할 멤버 검색하기',
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
            icon: Icon(Icons.close, color: AppColors.textSecondary, size: 20),
            onPressed: () {
              if (_searchQuery.isNotEmpty) {
                _searchController.clear();
              } else {
                Navigator.of(context).pop();
              }
            },
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ),
      ),
    );
  }

  /// 중간: 리스트 영역 (Expanded로 남는 공간 전부)
  Widget _buildBody() {
    return Expanded(
      child: Consumer<MemberProvider>(
        builder: (context, memberProvider, _) {
          final displayList = _getDisplayMembers(memberProvider);
          final filtered = _filterBySearch(displayList, _searchQuery);

          if (memberProvider.isLoading) {
            return Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: AppColors.primaryGreen,
                ),
              ),
            );
          }
          if (filtered.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(40),
                child: Text(
                  _searchQuery.isEmpty ? '추가할 수 있는 멤버가 없어요' : '검색 결과가 없습니다',
                  style: TextStyle(
                    fontSize: 16,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: filtered.length,
            separatorBuilder:
                (_, __) => Divider(
                  height: 1,
                  color: AppColors.borderLight.withOpacity(0.5),
                ),
            itemBuilder: (context, index) {
              final member = filtered[index];
              return _buildMemberItem(member, memberProvider);
            },
          );
        },
      ),
    );
  }

  /// 하단: 추가하기 버튼 (고정)
  Widget _buildFooter(double paddingBottom) {
    return Consumer<MemberProvider>(
      builder: (context, memberProvider, _) {
        if (memberProvider.isLoading) return const SizedBox.shrink();
        final displayList = _getDisplayMembers(memberProvider);
        return Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + paddingBottom),
          decoration: BoxDecoration(
            color: AppColors.backgroundWhite,
            border: Border(
              top: BorderSide(
                color: AppColors.borderLight.withOpacity(0.5),
                width: 1,
              ),
            ),
          ),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed:
                  _selectedUserIds.isEmpty
                      ? null
                      : () {
                        final selected =
                            displayList
                                .where(
                                  (v) => _selectedUserIds.contains(v.userId),
                                )
                                .toList();
                        // 시트를 먼저 닫은 뒤 콜백 호출 (배치 추가 시에도 확실히 닫힘)
                        if (context.mounted) {
                          Navigator.of(context).pop();
                        }
                        widget.onMembersSelected(selected);
                      },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryGreen,
                foregroundColor: Colors.white,
                disabledBackgroundColor: AppColors.backgroundLight,
                disabledForegroundColor: AppColors.textSecondary,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                elevation: 0,
              ),
              child: const Text(
                '추가하기',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildMemberItem(MemberView member, MemberProvider memberProvider) {
    final isSelected = _selectedUserIds.contains(member.userId);
    final isEnrolled = member.enrolledCourseIds.contains(widget.course.id);
    final remaining =
        isEnrolled
            ? _getRemainingForCourse(member, memberProvider.enrollments)
            : 0;

    return InkWell(
      onTap: () {
        setState(() {
          if (isSelected) {
            _selectedUserIds.remove(member.userId);
          } else {
            _selectedUserIds.add(member.userId);
          }
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
        child: Row(
          children: [
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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        member.adminDisplayName,
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
                              fontSize: 13,
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
                    FormatUtils.formatPhoneNumber(member.phoneNumber),
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.textSecondary.withOpacity(0.8),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    isEnrolled ? '남은 횟수: $remaining' : '이 코스에 등록되지 않음',
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.textSecondary.withOpacity(0.8),
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
