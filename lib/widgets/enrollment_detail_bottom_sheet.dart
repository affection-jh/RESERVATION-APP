import 'package:flutter/material.dart';
import '../../models/course.dart';
import '../../models/course_enrollment.dart';
import '../../theme/app_colors.dart';
import '../../utils/snackbar_util.dart';

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
  final TextEditingController _reasonController = TextEditingController();
  bool _isRequesting = false;
  bool _isExpanded = false;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

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

  // 연장 요청 상태 텍스트
  String get _extensionStatusText {
    final request = widget.enrollment.extensionRequest;
    if (request == null) return '';
    switch (request.status) {
      case ExtensionRequestStatus.pending:
        return '대기 중';
      case ExtensionRequestStatus.approved:
        return '승인됨';
      case ExtensionRequestStatus.rejected:
        return '거부됨';
    }
  }

  // 연장 요청 상태 색상
  Color get _extensionStatusColor {
    final request = widget.enrollment.extensionRequest;
    if (request == null) return AppColors.textSecondary;
    switch (request.status) {
      case ExtensionRequestStatus.pending:
        return Colors.orange;
      case ExtensionRequestStatus.approved:
        return AppColors.primaryGreen;
      case ExtensionRequestStatus.rejected:
        return Colors.red;
    }
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
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.85,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.backgroundWhite,
                    borderRadius: BorderRadius.circular(30),
                  ),
                  padding: const EdgeInsets.only(
                    left: 24,
                    right: 24,
                    top: 0,
                    bottom: 32,
                  ),
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.of(context).viewInsets.bottom,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 제목
                          Padding(
                            padding: const EdgeInsets.only(top: 32),
                            child: Text(
                              widget.course.name,
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: AppColors.textPrimary,
                              ),
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
                                        fontSize: 15,
                                        color: AppColors.textSecondary,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    Text(
                                      '${widget.enrollment.remainingReservations} / ${widget.enrollment.totalReservations}',
                                      style: TextStyle(
                                        fontSize: 15,
                                        color: AppColors.textPrimary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Container(
                                  height: 20,
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
                                widget.course.colorValue,
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
                          const SizedBox(height: 50),

                          // 연장 요청 상태 표시
                          if (widget.enrollment.extensionRequest != null) ...[
                            const SizedBox(height: 20),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: _extensionStatusColor.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: _extensionStatusColor.withOpacity(0.3),
                                  width: 1,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    widget
                                                .enrollment
                                                .extensionRequest!
                                                .status ==
                                            ExtensionRequestStatus.approved
                                        ? Icons.check_circle
                                        : widget
                                                  .enrollment
                                                  .extensionRequest!
                                                  .status ==
                                              ExtensionRequestStatus.rejected
                                        ? Icons.cancel
                                        : Icons.access_time,
                                    color: _extensionStatusColor,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      '연장 요청 ${_extensionStatusText}',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: _extensionStatusColor,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],

                          // 연장 요청 또는 재등록 버튼
                          const SizedBox(height: 24),
                          // 횟수가 남았고 유효기간 내라면 연장 요청 버튼
                          if (widget.enrollment.remainingReservations > 0 &&
                              !widget.enrollment.isExpired &&
                              !widget
                                  .enrollment
                                  .hasPendingExtensionRequest) ...[
                            // 연장 요청 버튼 (접혀있을 때만 표시)
                            if (!_isExpanded)
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  onPressed: () {
                                    setState(() {
                                      _isExpanded = true;
                                    });
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: widget.course.colorValue,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 16,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    elevation: 0,
                                  ),
                                  child: const Text(
                                    '연장 요청',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            // 사유 입력 섹션 (애니메이션)
                            AnimatedSize(
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeInOut,
                              child: _isExpanded
                                  ? Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '연장 사유',
                                          style: TextStyle(
                                            fontSize: 14,
                                            color: AppColors.textSecondary,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        TextField(
                                          controller: _reasonController,
                                          maxLines: 4,
                                          decoration: InputDecoration(
                                            hintText: '사유를 입력하세요',
                                            hintStyle: TextStyle(
                                              color: AppColors.textLight,
                                              fontSize: 14,
                                            ),
                                            border: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              borderSide: BorderSide(
                                                color: AppColors.borderLight,
                                                width: 1,
                                              ),
                                            ),
                                            enabledBorder: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              borderSide: BorderSide(
                                                color: AppColors.borderLight,
                                                width: 1,
                                              ),
                                            ),
                                            focusedBorder: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              borderSide: BorderSide(
                                                color: widget.course.colorValue,
                                                width: 2,
                                              ),
                                            ),
                                            contentPadding:
                                                const EdgeInsets.all(16),
                                          ),
                                          style: TextStyle(
                                            fontSize: 14,
                                            color: AppColors.textPrimary,
                                          ),
                                        ),
                                        const SizedBox(height: 12),
                                        Row(
                                          children: [
                                            Expanded(
                                              child: OutlinedButton(
                                                onPressed: () {
                                                  setState(() {
                                                    _isExpanded = false;
                                                    _reasonController.clear();
                                                  });
                                                },
                                                style: OutlinedButton.styleFrom(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        vertical: 14,
                                                      ),
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          12,
                                                        ),
                                                  ),
                                                  side: BorderSide(
                                                    color:
                                                        AppColors.borderLight,
                                                  ),
                                                ),
                                                child: Text(
                                                  '취소',
                                                  style: TextStyle(
                                                    fontSize: 16,
                                                    fontWeight: FontWeight.w600,
                                                    color:
                                                        AppColors.textSecondary,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              flex: 2,
                                              child: ElevatedButton(
                                                onPressed: _isRequesting
                                                    ? null
                                                    : () {
                                                        if (_reasonController
                                                            .text
                                                            .trim()
                                                            .isEmpty) {
                                                          SnackbarUtil.showError(
                                                            context,
                                                            '사유를 입력해주세요',
                                                          );
                                                          return;
                                                        }
                                                        _requestExtension(
                                                          _reasonController.text
                                                              .trim(),
                                                        );
                                                      },
                                                style: ElevatedButton.styleFrom(
                                                  backgroundColor:
                                                      AppColors.primaryGreen,
                                                  foregroundColor: Colors.white,
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        vertical: 14,
                                                      ),
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          12,
                                                        ),
                                                  ),
                                                  elevation: 0,
                                                ),
                                                child: _isRequesting
                                                    ? const SizedBox(
                                                        height: 20,
                                                        width: 20,
                                                        child: CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                          valueColor:
                                                              AlwaysStoppedAnimation<
                                                                Color
                                                              >(Colors.white),
                                                        ),
                                                      )
                                                    : Text(
                                                        '요청하기',
                                                        style: TextStyle(
                                                          fontSize: 16,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                        ),
                                                      ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ],
                          // 횟수가 다 되면 재등록 버튼
                          if (widget.enrollment.remainingReservations == 0) ...[
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                onPressed: () {
                                  // TODO: 재등록 기능 구현
                                  SnackbarUtil.showInfo(
                                    context,
                                    '재등록 기능은 준비 중입니다.',
                                  );
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.primaryGreen,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 16,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  elevation: 0,
                                ),
                                child: const Text(
                                  '재등록하기',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ],
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
              fontSize: 13,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  void _requestExtension(String reason) {
    setState(() {
      _isRequesting = true;
    });

    // TODO: 실제 연장 요청 로직 구현
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() {
          _isRequesting = false;
          _isExpanded = false;
        });
        _reasonController.clear();
        widget.onExtensionRequested?.call();
        SnackbarUtil.showSuccess(context, '연장 요청이 접수되었습니다.');
      }
    });
  }
}
