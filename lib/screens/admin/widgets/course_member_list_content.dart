import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../theme/app_colors.dart';
import '../../../models/member_view.dart';
import '../../../models/course.dart';
import '../../../providers/member_provider.dart';
import '../../../providers/place_provider.dart';
import 'shared_widgets.dart';

/// 이름, 전화번호(숫자만/공백·하이픈 무시)로 검색. 전체/코스별 동일 로직.
List<MemberView> _filterBySearch(List<MemberView> list, String searchQuery) {
  final q = searchQuery.trim();
  if (q.isEmpty) return list;
  final lower = q.toLowerCase();
  final digitsOnly = q.replaceAll(RegExp(r'[^\d]'), '');
  final keywords =
      lower.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  return list.where((v) {
    final name = v.adminDisplayName.trim().toLowerCase();
    final phone = v.phoneNumber.replaceAll(RegExp(r'[^\d]'), '');
    final nameMatch = name.contains(lower);
    final phoneMatch = digitsOnly.isNotEmpty && phone.contains(digitsOnly);
    final matchFull = nameMatch || phoneMatch;
    if (keywords.isEmpty) return matchFull;
    final matchKeywords = keywords.every((kw) {
      final kwDigits = kw.replaceAll(RegExp(r'[^\d]'), '');
      return name.contains(kw) ||
          (kwDigits.isNotEmpty && phone.contains(kwDigits));
    });
    return matchFull || matchKeywords;
  }).toList();
}

/// sortBy: 0=남은횟수, 1=유효기한, 3=최신등록순
/// ascending: 0,1에서만 사용. 2,3,4는 고정(최신/많은 순)
List<MemberView> _sortCourseMembers(
  List<MemberView> list,
  int sortBy, {
  bool ascending = true,
}) {
  list = List.from(list);
  final order = ascending ? 1 : -1;
  list.sort((a, b) {
    if (a.isPending && b.isPending) return 0;
    if (a.isPending) return 1;
    if (b.isPending) return -1;
    switch (sortBy) {
      case 0: // 남은 횟수
        final ar = a.enrollment?.remainingReservations ?? 0;
        final br = b.enrollment?.remainingReservations ?? 0;
        return ar.compareTo(br) * order;
      case 1: // 유효기한
        final av = a.enrollment?.validUntil ?? DateTime(2099);
        final bv = b.enrollment?.validUntil ?? DateTime(2099);
        return av.compareTo(bv) * order;
      case 2: // 최신 가입순 (enrolledAt 내림차순)
      case 3: // 최신 등록순 (enrolledAt 내림차순)
        final ad = a.enrollment?.enrolledAt ?? DateTime(2000);
        final bd = b.enrollment?.enrolledAt ?? DateTime(2000);
        return bd.compareTo(ad); // 최신 먼저
      case 4: // 재등록 많은 순
        final ac = a.enrollment?.totalEnrollmentCount ?? 0;
        final bc = b.enrollment?.totalEnrollmentCount ?? 0;
        return bc.compareTo(ac); // 많은 쪽 먼저
      default:
        return 0;
    }
  });
  return list;
}

// ===== 코스별 멤버 리스트 (MemberView + pending) =====

/// 코스별 보기와 코스 상세에서 공통 사용. 동일한 데이터(enrollment + pending) + 동일한 표시 방식.
class CourseMemberListContent extends StatelessWidget {
  /// 로그에서 호출 위치 구분용 (예: 'AdminMember', 'CourseDetail')
  final String logLabel;
  final String courseId;
  final String? placeId;
  final String searchQuery;
  final String emptyMessage;
  final bool showEmptyCta;
  final VoidCallback? onMemberTapped;
  final EdgeInsets? listPadding;

  /// true: SingleChildScrollView 안에서 사용(코스 상세). false: Expanded 안에서 스크롤(코스별 탭).
  final bool shrinkWrap;

  /// 코스 상세용: 헤더 "멤버(N명)" + 추가 버튼 표시
  final bool showHeaderWithCount;
  final String Function(int count)? headerTitleBuilder;
  final VoidCallback? onAddTap;

  /// 멤버 카드 배경색 (미지정 시 MemberCard 기본값 사용)
  final Color? cardBackgroundColor;

  /// 코스별: 0=횟수순, 1=기간순
  final int sortBy;

  /// 코스별 정렬 방향: true=오름차순, false=내림차순
  final bool sortAscending;

  /// 코스별 멤버카드에 해당 코스 남은기간·횟수 표시
  final bool showCourseEnrollmentDetail;
  final void Function(int)? onSortChanged;
  final void Function(bool)? onSortOrderChanged;

  /// 코스별 보기에서 탭 시 바텀시트 대신 EnrollmentDetailScreen으로 바로 이동할 때 전달
  final Course? courseForDirectDetail;

  /// true: 정렬 필터는 부모(코스별 섹션 헤더)에 있음. 여기선 정렬 행 미표시.
  final bool sortFilterInParent;

  /// 스크롤 하단 근처에서 호출 (무한 스크롤용)
  final VoidCallback? onLoadMore;

  /// 멤버 리스트 스크롤 알림 (코스별 탭 헤더 접기 등)
  final bool Function(ScrollNotification notification)? onListScroll;

  /// true면 첫 멤버카드 상단 라운드 제거 (코스 선택 패널과 이어질 때)
  final bool flattenFirstCardTop;

  const CourseMemberListContent({
    super.key,
    this.logLabel = 'CourseMemberListContent',
    required this.courseId,
    this.placeId,
    this.searchQuery = '',
    this.emptyMessage = '등록된 멤버가 없어요.',
    this.showEmptyCta = false,
    this.onMemberTapped,
    this.listPadding,
    this.shrinkWrap = false,
    this.showHeaderWithCount = false,
    this.headerTitleBuilder,
    this.onAddTap,
    this.cardBackgroundColor,
    this.sortBy = 0,
    this.sortAscending = true,
    this.showCourseEnrollmentDetail = false,
    this.onSortChanged,
    this.onSortOrderChanged,
    this.courseForDirectDetail,
    this.sortFilterInParent = false,
    this.onLoadMore,
    this.onListScroll,
    this.flattenFirstCardTop = false,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer2<MemberProvider, PlaceProvider>(
      builder: (context, memberProvider, placeProvider, child) {
        // 단일 코스 선택 시 MemberProvider의 전체 검색(횟수, 대기중, 과목 등) 적용
        final useProviderFilter =
            memberProvider.selectedTab == 1 &&
            memberProvider.selectedCourseIds.length == 1 &&
            memberProvider.selectedCourseIds.first == courseId;

        final List<MemberView> filtered;
        final int totalCount;
        if (useProviderFilter) {
          filtered = memberProvider.listForCourseTab;
          totalCount = filtered.length;
        } else {
          final enrolled = memberProvider.getMembersForCourse(courseId);
          final pendingForCourse =
              memberProvider.allMembers
                  .where(
                    (v) => v.isPending && v.relatedCourseIds.contains(courseId),
                  )
                  .toList();
          var all = <MemberView>[...enrolled, ...pendingForCourse];
          all = _filterBySearch(all, searchQuery);
          all = _sortCourseMembers(all, sortBy, ascending: sortAscending);
          filtered = all;
          totalCount = enrolled.length + pendingForCourse.length;
        }

        if (filtered.isEmpty) {
          if (memberProvider.isSearchLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          final emptyContent = Padding(
            padding: listPadding ?? const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  emptyMessage,
                  style: TextStyle(
                    fontSize: 16,
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          );
          if (showHeaderWithCount) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(context, totalCount),
                const SizedBox(height: 16),
                emptyContent,
              ],
            );
          }
          return Center(child: emptyContent);
        }

        final sortRow =
            (!sortFilterInParent &&
                    onSortChanged != null &&
                    onSortOrderChanged != null)
                ? Padding(
                  padding: const EdgeInsets.only(
                    left: 16,
                    right: 16,
                    top: 18,
                    bottom: 4,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      buildSortFilterDropdown(
                        sortBy: sortBy,
                        sortAscending: sortAscending,
                        onSortChanged: onSortChanged!,
                        onSortOrderChanged: onSortOrderChanged!,
                      ),
                    ],
                  ),
                )
                : null;

        const loadMoreThreshold = 200.0;

        final listView = NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            onListScroll?.call(notification);
            if (!shrinkWrap && notification is ScrollUpdateNotification) {
              final m = notification.metrics;
              if (onLoadMore != null &&
                  m.pixels >= m.maxScrollExtent - loadMoreThreshold &&
                  memberProvider.hasMoreMembers &&
                  !memberProvider.isLoadingMore) {
                onLoadMore!();
              }
            }
            return false;
          },
          child: ListView.builder(
            padding:
                listPadding ??
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            shrinkWrap: shrinkWrap,
            physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
            itemCount:
                filtered.length +
                (memberProvider.isLoadingMore && onLoadMore != null ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= filtered.length) {
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
              final v = filtered[index];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: MemberCard(
                  backgroundColor: cardBackgroundColor,
                  member: v,
                  onMemberTapped: onMemberTapped ?? () {},
                  showCourseEnrollmentDetail: showCourseEnrollmentDetail,
                  courseForDirectDetail: courseForDirectDetail,
                ),
              );
            },
          ),
        );

        final listContent =
            sortRow != null
                ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize:
                      shrinkWrap ? MainAxisSize.min : MainAxisSize.max,
                  children: [
                    sortRow,
                    if (shrinkWrap) listView else Expanded(child: listView),
                  ],
                )
                : listView;

        if (showHeaderWithCount) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(context, totalCount),
              const SizedBox(height: 16),
              listContent,
            ],
          );
        }
        return listContent;
      },
    );
  }

  /// 필터 아이콘 탭 시 정렬 기준 선택 드롭다운 (코스별 섹션 헤더 등에서 재사용)
  static Widget buildSortFilterDropdown({
    required int sortBy,
    required bool sortAscending,
    required void Function(int) onSortChanged,
    required void Function(bool) onSortOrderChanged,
  }) {
    return PopupMenuButton<(int, bool)>(
      icon: Icon(
        Icons.filter_list_rounded,
        size: 24,
        color: AppColors.textSecondary,
      ),
      padding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      offset: const Offset(0, 40),
      onSelected: (value) {
        onSortChanged(value.$1);
        onSortOrderChanged(value.$2);
      },
      itemBuilder:
          (context) => [
            _filterItem((0, false), '남은 횟수 많은 순', sortBy, sortAscending),
            _filterItem((0, true), '남은 횟수 적은 순', sortBy, sortAscending),
            _filterItem((1, true), '유효기한 짧은 순', sortBy, sortAscending),
            _filterItem((1, false), '유효기한 긴 순', sortBy, sortAscending),
            _filterItem((3, false), '최신 등록순', sortBy, sortAscending),
          ],
    );
  }

  static PopupMenuItem<(int, bool)> _filterItem(
    (int, bool) value,
    String label,
    int sortBy,
    bool sortAscending,
  ) {
    final selected =
        sortBy == value.$1 &&
        (value.$1 <= 1 ? sortAscending == value.$2 : true);
    return PopupMenuItem<(int, bool)>(
      value: value,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 15,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: selected ? AppColors.primaryGreen : AppColors.textPrimary,
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, int totalCount) {
    final title =
        headerTitleBuilder != null
            ? headerTitleBuilder!(totalCount)
            : '멤버($totalCount명)';
    return Row(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        const Spacer(),
        if (onAddTap != null)
          GestureDetector(
            onTap: onAddTap,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Icon(
                Icons.add_circle,
                color: AppColors.primaryGreen,
                size: 30,
              ),
            ),
          ),
      ],
    );
  }
}
