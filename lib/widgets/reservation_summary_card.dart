import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../models/session_reservation.dart';
import '../models/course.dart';
import '../models/course_enrollment.dart';
import '../utils/timezone_utils.dart';

/// 홈용 수강 요약 카드: 남은 횟수·유효기간·다가오는 예약 표시.
/// 디자인 구조: "내 예약" 섹션과 동일 (타이틀 행 + 카드, 첫/마지막 카드 좌우 마진 20)
/// 코스가 여러 개면 가로 스와이프(PageView)로 모두 표시.
class ReservationSummaryCard extends StatefulWidget {
  final bool isLoggedIn;
  final List<CourseEnrollment> enrollments;
  final List<SessionReservation> reservations;
  final List<Course> courses;
  final VoidCallback onTap;

  /// 카드 탭 시 등록 상세 화면으로 이동 (미제공 시 onCourseTap/onTap 사용)
  final void Function(Course course, CourseEnrollment enrollment)? onCardTap;

  /// 예약하기 버튼 탭 시 해당 코스 예약 화면으로 이동 (미제공 시 onTap 사용)
  final void Function(Course course)? onCourseTap;

  /// 예약하기 로딩 중인 코스 ID (버튼에 인디케이터 표시)
  final String? loadingCourseId;

  const ReservationSummaryCard({
    super.key,
    required this.isLoggedIn,
    required this.enrollments,
    required this.reservations,
    required this.courses,
    required this.onTap,
    this.onCardTap,
    this.onCourseTap,
    this.loadingCourseId,
  });

  @override
  State<ReservationSummaryCard> createState() => _ReservationSummaryCardState();
}

class _ReservationSummaryCardState extends State<ReservationSummaryCard> {
  late PageController _pageController;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 1.0);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Row(
            children: [
              Text(
                '내 코스',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              if (widget.isLoggedIn && widget.enrollments.isNotEmpty)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(
                    widget.enrollments.length,
                    (index) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color:
                              index == _currentPage
                                  ? AppColors.primaryGreen
                                  : AppColors.primaryGreen.withOpacity(0.3),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),

        const SizedBox(height: 12),
        // 카드 영역: 왼쪽 패딩 최소, 카드 간 간격은 item padding으로
        _buildCardContent(context),
      ],
    );
  }

  Widget _buildCardContent(BuildContext context) {
    if (widget.enrollments.isEmpty) {
      return _buildEmptyCard(context);
    }

    // 여러 코스: 가로 스와이프
    return SizedBox(
      height: 200,
      child: PageView.builder(
        controller: _pageController,
        onPageChanged: (index) => setState(() => _currentPage = index),

        itemCount: widget.enrollments.length,
        itemBuilder: (context, index) {
          const gap = 16.0;
          final isFirst = index == 0;
          final isLast = index == widget.enrollments.length - 1;
          final enrollment = widget.enrollments[index];
          return Padding(
            padding: EdgeInsets.only(
              left: isFirst ? 16 : gap,
              right: isLast ? 16 : gap,
            ),
            child: _buildSingleCard(
              context,
              enrollment,
              loadingCourseId: widget.loadingCourseId,
            ),
          );
        },
      ),
    );
  }

  Widget _buildSingleCard(
    BuildContext context,
    CourseEnrollment enrollment, {
    String? loadingCourseId,
  }) {
    final courseNamesByCourseId = {
      for (final c in widget.courses) c.id: c.name,
    };
    Course? course;
    for (final c in widget.courses) {
      if (c.id == enrollment.courseId) {
        course = c;
        break;
      }
    }
    final courseName = courseNamesByCourseId[enrollment.courseId] ?? '수강';
    final remaining = enrollment.remainingReservations;
    final validUntilStr =
        '${_formatFullDate(TimezoneUtils.getSeoulDateOnly(enrollment.validUntil))}까지';

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          onTap: () {
            if (widget.onCardTap != null && course != null) {
              widget.onCardTap!(course, enrollment);
            } else if (widget.onCourseTap != null && course != null) {
              widget.onCourseTap!(course);
            } else {
              widget.onTap();
            }
          },
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.only(
              top: 24,
              bottom: 16,
              left: 16,
              right: 16,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  courseName,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: Text(
                    validUntilStr,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textSecondary.withOpacity(0.9),
                    ),
                  ),
                ),
                const SizedBox(height: 48),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.backgroundLight,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        '$remaining회 남음',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primaryGreen,
                          letterSpacing: -0.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: () {
                        if (loadingCourseId != null) return;
                        if (widget.onCourseTap != null && course != null) {
                          widget.onCourseTap!(course);
                        } else {
                          widget.onTap();
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: const Color.fromARGB(255, 0, 0, 0),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: SizedBox(
                          width: 84,
                          height: 24,
                          child: Center(
                            child:
                                loadingCourseId == course?.id
                                    ? SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.5,
                                        valueColor:
                                            const AlwaysStoppedAnimation<Color>(
                                              Colors.white,
                                            ),
                                      ),
                                    )
                                    : const Text(
                                      '예약하기',
                                      style: TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white,
                                        letterSpacing: -0.2,
                                      ),
                                    ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyCard(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 100, horizontal: 16),
        decoration: BoxDecoration(
          color: AppColors.backgroundWhite,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '수강 중인 코스가 없어요',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: AppColors.textSecondary.withOpacity(0.8),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  String _formatFullDate(DateTime date) {
    return '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';
  }
}
