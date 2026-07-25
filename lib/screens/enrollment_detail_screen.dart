import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/course.dart';
import '../models/course_enrollment.dart';
import '../models/enrollment_action.dart';
import '../models/enrollment_timeline_item.dart';
import '../providers/enrollment_provider.dart';
import '../providers/enrollment_timeline_provider.dart';
import '../utils/enrollment_timeline_display.dart';
import '../theme/app_colors.dart';
import '../widgets/cached_image_widget.dart';

/// 등록 상세 정보 화면 (일반 유저용)
class EnrollmentDetailScreen extends StatelessWidget {
  final Course course;
  final CourseEnrollment enrollment;
  final VoidCallback? onExtensionRequested;

  const EnrollmentDetailScreen({
    super.key,
    required this.course,
    required this.enrollment,
    this.onExtensionRequested,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundWhite,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, size: 24),
          onPressed: () => Navigator.of(context).pop(),
          color: AppColors.textPrimary,
        ),
      ),
      body: _EnrollmentDetailContent(course: course, enrollment: enrollment),
    );
  }
}

class _EnrollmentDetailContent extends StatefulWidget {
  final Course course;
  final CourseEnrollment enrollment;

  const _EnrollmentDetailContent({
    required this.course,
    required this.enrollment,
  });

  @override
  State<_EnrollmentDetailContent> createState() =>
      _EnrollmentDetailContentState();
}

class _EnrollmentDetailContentState extends State<_EnrollmentDetailContent> {
  String? _selectedTimelineFilter;
  int _timelineDisplayLimit = 3;

  String _formatDate(DateTime date) {
    return '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<EnrollmentProvider>(
      builder: (context, enrollmentProvider, _) {
        final latestEnrollment =
            enrollmentProvider.enrollmentsByCourseId[widget
                .enrollment
                .courseId] ??
            widget.enrollment;

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 코스 사진 + 코스명 (게이지 바 위)
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (widget.course.imageUrl != null &&
                      widget.course.imageUrl!.isNotEmpty)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: CourseImageWidget(
                        imageUrl: widget.course.imageUrl,
                        width: 72,
                        height: 72,
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  if (widget.course.imageUrl != null &&
                      widget.course.imageUrl!.isNotEmpty)
                    const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          widget.course.name,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        if (widget.course.description.isNotEmpty) ...[
                          Text(
                            widget.course.description,
                            style: TextStyle(
                              fontSize: 14,
                              color: AppColors.textSecondary,
                              height: 1.4,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 48),

              // 정보 칩들
              _buildInfoChip(
                '남은 횟수',
                '${latestEnrollment.remainingReservations} / ${latestEnrollment.totalReservations}',
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildInfoChip(
                    '등록일',
                    _formatDate(latestEnrollment.enrolledAt),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      '-',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  _buildInfoChip(
                    '마감일',
                    _formatDate(latestEnrollment.validUntil),
                  ),
                ],
              ),
              const SizedBox(height: 48),
              // 히스토리 (관리자 enrollment_detail과 동일 UI, 일반 유저용)
              _buildTimelineSection(context),
              const SizedBox(height: 58),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTimelineSection(BuildContext context) {
    return Consumer<EnrollmentTimelineProvider>(
      builder: (context, provider, _) {
        if (provider.isLoading) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '히스토리',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.primaryGreen,
                    ),
                  ),
                ),
              ),
            ],
          );
        }
        if (provider.error != null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '히스토리',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '내역을 불러오지 못했어요.',
                style: TextStyle(fontSize: 15, color: AppColors.textSecondary),
              ),
            ],
          );
        }
        final allItems = provider.timelineItems;
        final availableFilters = <String>{};
        for (final item in allItems) {
          availableFilters.add(_getTimelineFilterCategory(item));
        }

        List<EnrollmentTimelineItem> filteredItems = allItems;
        if (_selectedTimelineFilter != null) {
          filteredItems =
              allItems
                  .where(
                    (item) =>
                        _getTimelineFilterCategory(item) ==
                        _selectedTimelineFilter,
                  )
                  .toList();
        }

        if (filteredItems.isEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '히스토리',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '아직 히스토리가 없어요.',
                style: TextStyle(fontSize: 15, color: AppColors.textSecondary),
              ),
            ],
          );
        }

        final totalCount = filteredItems.length;
        final displayItems = filteredItems.take(_timelineDisplayLimit).toList();
        final hasMore = totalCount > _timelineDisplayLimit;

        final isExpanded = _timelineDisplayLimit > 3;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '히스토리',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (isExpanded)
                  _buildExpandCollapseChip(
                    label: '접기',
                    onTap: () => setState(() => _timelineDisplayLimit = 3),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (availableFilters.isNotEmpty) ...[
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildTimelineFilterChip(
                      label: '전체',
                      isSelected: _selectedTimelineFilter == null,
                      onTap:
                          () => setState(() => _selectedTimelineFilter = null),
                    ),
                    const SizedBox(width: 4),
                    ...availableFilters.map((filter) {
                      return Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: _buildTimelineFilterChip(
                          label: filter,
                          isSelected: _selectedTimelineFilter == filter,
                          onTap:
                              () => setState(
                                () => _selectedTimelineFilter = filter,
                              ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 22),
            ],
            _buildTimelineContainer(displayItems, hasMore),
            if (hasMore) ...[
              const SizedBox(height: 12),
              _buildExpandCollapseChip(
                label: '펼치기 ',
                onTap: () => setState(() => _timelineDisplayLimit += 20),
              ),
            ],
            if (isExpanded) ...[
              const SizedBox(height: 12),
              _buildExpandCollapseChip(
                label: '접기',
                onTap: () => setState(() => _timelineDisplayLimit = 3),
              ),
            ],
          ],
        );
      },
    );
  }

  String _getTimelineFilterCategory(EnrollmentTimelineItem item) {
    return EnrollmentTimelineDisplay.filterCategory(item);
  }

  /// 펼치기/접기 전용 칩 (필터 칩과 약간 다른 스타일)
  Widget _buildExpandCollapseChip({
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.primaryGreen.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.primaryGreen,
          ),
        ),
      ),
    );
  }

  Widget _buildTimelineFilterChip({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color:
              isSelected
                  ? AppColors.primaryGreen
                  : const Color.fromARGB(255, 238, 238, 238),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: isSelected ? Colors.white : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildTimelineContainer(
    List<EnrollmentTimelineItem> items,
    bool hasMore,
  ) {
    if (items.isEmpty) return const SizedBox.shrink();

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 5,
          top: 0,
          bottom: 0,
          child: Container(width: 2, color: AppColors.borderLight),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children:
                items.asMap().entries.map((entry) {
                  final index = entry.key;
                  final item = entry.value;
                  final isLast = index == items.length - 1 && !hasMore;
                  return _buildTimelineItem(item, isLast);
                }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildTimelineItem(EnrollmentTimelineItem item, bool isLast) {
    final color = switch (item) {
      ActionTimelineItem(:final action) => _getTimelineItemColor(
        action.actionType,
      ),
      _ => AppColors.textSecondary,
    };

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
          child: EnrollmentTimelineDisplay.buildTimelineEntry(item: item),
        ),
        Positioned(
          left: -18,
          top: 1,
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
        Positioned(
          left: -9,
          top: 5,
          child: Container(width: 9, height: 2, color: AppColors.borderLight),
        ),
      ],
    );
  }

  Color _getTimelineItemColor(EnrollmentActionType type) {
    switch (type) {
      case EnrollmentActionType.cancel:
        return const Color.fromARGB(255, 253, 115, 105);
      case EnrollmentActionType.adjustCount:
      case EnrollmentActionType.periodAdjust:
      case EnrollmentActionType.reenroll:
      case EnrollmentActionType.reservationCreate:
      case EnrollmentActionType.reservationMove:
      case EnrollmentActionType.reservationCancel:
        return const Color.fromARGB(255, 59, 59, 59);
      default:
        return AppColors.textSecondary;
    }
  }

  Widget _buildInfoChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.textSecondary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 15,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            value,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
