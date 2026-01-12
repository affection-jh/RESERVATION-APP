import 'package:flutter/material.dart';
import '../../models/course.dart';
import '../../models/course_enrollment.dart';
import '../../theme/app_colors.dart';
import 'extension_request_bottom_sheet.dart';

/// 등록 상세 정보 바텀시트
class EnrollmentDetailBottomSheet extends StatefulWidget {
  final Course course;
  final CourseEnrollment enrollment;
  final VoidCallback? onExtensionRequested;

  const EnrollmentDetailBottomSheet({
    super.key,
    required this.course,
    required this.enrollment,
    this.onExtensionRequested,
  });

  @override
  State<EnrollmentDetailBottomSheet> createState() =>
      _EnrollmentDetailBottomSheetState();
}

class _EnrollmentDetailBottomSheetState
    extends State<EnrollmentDetailBottomSheet> {
  // 날짜 포맷팅
  String _formatDate(DateTime date) {
    return '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';
  }

  // 남은 횟수 비율 계산
  double get _progress {
    return widget.enrollment.totalReservations > 0
        ? widget.enrollment.remainingReservations /
              widget.enrollment.totalReservations
        : 0.0;
  }

  @override
  Widget build(BuildContext context) {
    final dayNames = ['', '월', '화', '수', '목', '금', '토', '일'];
    final days = widget.course.availableDays.map((d) => dayNames[d]).toList();
    final daysText = days.length == 7 ? '매일' : days.join(', ');

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: Colors.transparent,
      body: Container(
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
                  decoration: BoxDecoration(
                    color: AppColors.backgroundWhite,
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(20),
                    ),
                  ),
                  padding: const EdgeInsets.only(left: 24, right: 24, top: 0),
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.of(context).viewInsets.bottom + 32,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 제목
                          Padding(
                            padding: const EdgeInsets.only(top: 28),
                            child: Row(
                              children: [
                                Text(
                                  widget.course.name,
                                  style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                                Spacer(),
                                // 연장 요청 아이콘 (send 아이콘)
                                if (widget.enrollment.id.isNotEmpty &&
                                    widget.enrollment.remainingReservations >
                                        0 &&
                                    !widget.enrollment.isExpired &&
                                    !widget
                                        .enrollment
                                        .hasPendingExtensionRequest)
                                  IconButton(
                                    onPressed: () {
                                      // 이전 바텀시트 닫기
                                      Navigator.of(context).pop();
                                      // 새로운 바텀시트 열기
                                      ExtensionRequestBottomSheet.show(
                                        context: context,
                                        enrollmentId: widget.enrollment.id,
                                        enrollment: widget.enrollment,
                                        course: widget.course,
                                        onRequestSubmitted: () {
                                          widget.onExtensionRequested?.call();
                                        },
                                      );
                                    },
                                    icon: Icon(
                                      Icons.send,
                                      color: AppColors.primaryGreen,
                                      size: 24,
                                    ),
                                    tooltip: '연장 요청',
                                  ),
                                IconButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  icon: Icon(
                                    Icons.close,
                                    color: AppColors.textSecondary,
                                    size: 24,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),

                          // 남은 횟수 게이지
                          Padding(
                            padding: const EdgeInsets.only(right: 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      '남은 횟수',
                                      style: TextStyle(
                                        fontSize: 16,
                                        color: AppColors.textSecondary,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    Text(
                                      '${widget.enrollment.remainingReservations} / ${widget.enrollment.totalReservations}',
                                      style: TextStyle(
                                        fontSize: 16,
                                        color: AppColors.textPrimary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Container(
                                  height: 10,
                                  decoration: BoxDecoration(
                                    color: AppColors.backgroundLight,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Stack(
                                    children: [
                                      // 배경
                                      Container(
                                        decoration: BoxDecoration(
                                          color: AppColors.backgroundLight,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                      ),
                                      // 진행 바
                                      FractionallySizedBox(
                                        alignment: Alignment.centerLeft,
                                        widthFactor: _progress > 0
                                            ? _progress
                                            : 0.02, // 최소 2% 너비로 보이게
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: widget.course.colorValue,
                                            borderRadius: BorderRadius.circular(
                                              12,
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
                          const SizedBox(height: 28),

                          // 정보 칩들
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 요일 (위에)
                              _buildInfoChip(
                                '요일',
                                daysText,
                                AppColors.textSecondary,
                              ),
                              const SizedBox(height: 8),
                              // 등록일 - 마감일 (아래에 나란히)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _buildInfoChip(
                                    '등록일',
                                    _formatDate(widget.enrollment.enrolledAt),
                                    AppColors.textSecondary,
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
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
                                    _formatDate(widget.enrollment.validUntil),
                                    AppColors.textSecondary,
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoChip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
