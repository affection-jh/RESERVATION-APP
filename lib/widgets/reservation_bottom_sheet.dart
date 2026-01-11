import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/course.dart';
import '../models/reservation.dart';
import '../providers/enrollment_provider.dart';
import '../theme/app_colors.dart';
import '../utils/snackbar_util.dart';

class ReservationBottomSheet extends StatefulWidget {
  final String activityName;
  final String date;
  final String startTime;
  final String endTime;
  final int availableSeats;
  final int totalSeats;
  final int remainingReservations;
  final Course? course; // 코스 정보 (유효기간 조회용)
  final Future<Reservation> Function()? onConfirm;
  final VoidCallback? onCancel;

  const ReservationBottomSheet({
    super.key,
    required this.activityName,
    required this.date,
    required this.startTime,
    required this.endTime,
    required this.availableSeats,
    required this.totalSeats,
    this.remainingReservations = 0,
    this.course,
    this.onConfirm,
    this.onCancel,
  });

  static Future<Reservation?> show({
    required BuildContext context,
    required String activityName,
    required String date,
    required String startTime,
    required String endTime,
    required int availableSeats,
    required int totalSeats,
    int remainingReservations = 0,
    Course? course,
    Future<Reservation> Function()? onConfirm,
    VoidCallback? onCancel,
  }) {
    return showModalBottomSheet<Reservation?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.7),
      builder: (context) => ReservationBottomSheet(
        activityName: activityName,
        date: date,
        startTime: startTime,
        endTime: endTime,
        availableSeats: availableSeats,
        totalSeats: totalSeats,
        remainingReservations: remainingReservations,
        course: course,
        onConfirm: onConfirm,
        onCancel: onCancel,
      ),
    );
  }

  @override
  State<ReservationBottomSheet> createState() => _ReservationBottomSheetState();
}

class _ReservationBottomSheetState extends State<ReservationBottomSheet> {
  bool _isSubmitting = false;

  Future<void> _handleConfirm() async {
    if (_isSubmitting) return;
    if (widget.remainingReservations <= 0) return;
    if (widget.onConfirm == null) return;

    setState(() {
      _isSubmitting = true;
    });

    try {
      final created = await widget.onConfirm!.call();
      if (!mounted) return;
      Navigator.of(context).pop<Reservation>(created);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
      });
      // 애플 스타일의 에러 메시지 표시
      final errorMessage = _getErrorMessage(e);
      SnackbarUtil.showError(context, errorMessage);
    }
  }

  String _getErrorMessage(dynamic error) {
    final errorString = error.toString().toLowerCase();
    if (errorString.contains('network') || errorString.contains('connection')) {
      return '네트워크 연결을 확인해주세요';
    }
    if (errorString.contains('timeout')) {
      return '요청 시간이 초과되었습니다';
    }
    if (errorString.contains('permission') || errorString.contains('권한')) {
      return '예약 권한이 없습니다';
    }
    if (errorString.contains('full') || errorString.contains('자리')) {
      return '예약 가능한 자리가 없습니다';
    }
    if (errorString.contains('expired') || errorString.contains('만료')) {
      return '예약 가능한 횟수가 없습니다';
    }
    return '예약 중 오류가 발생했습니다';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
      decoration: const BoxDecoration(color: Colors.transparent),
      child: Stack(
        children: [
          // 배경 탭 시 닫기
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
                if (_isSubmitting) return;
                Navigator.of(context).pop();
                widget.onCancel?.call();
              },
              child: Container(color: Colors.transparent),
            ),
          ),
          // 바텀시트 컨텐츠
          Align(
            alignment: Alignment.bottomCenter,
            child: GestureDetector(
              onTap: () {},
              child: PopScope(
                canPop: !_isSubmitting,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.backgroundWhite,
                    borderRadius: BorderRadius.circular(30),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 24,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 예약 상세 정보
                      _buildReservationDetails(context),

                      const SizedBox(height: 32),

                      // 남은 자리 정보
                      _buildAvailableSeatsInfo(),

                      const SizedBox(height: 24),

                      // 구분선
                      Divider(
                        height: 1,
                        thickness: 0.5,
                        color: AppColors.borderLight,
                      ),

                      const SizedBox(height: 24),

                      // 내 남은 횟수 및 유효기간 정보
                      if (widget.course != null) _buildEnrollmentInfo(context),

                      if (widget.course != null) const SizedBox(height: 32),

                      const SizedBox(height: 24),

                      // 액션 버튼
                      _buildActionButtons(context),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 예약 상세 정보 위젯
  Widget _buildReservationDetails(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 코스/활동명
        Row(
          children: [
            Text(
              widget.activityName,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            Spacer(),
            GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Icon(Icons.close, size: 20, color: AppColors.textPrimary),
            ),
          ],
        ),
        const SizedBox(height: 12),

        Row(
          children: [
            // 날짜
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.backgroundLight,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Text(
                widget.date,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            // 시간
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.backgroundLight,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                '${widget.startTime} - ${widget.endTime}',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  // 남은 자리 정보 위젯
  Widget _buildAvailableSeatsInfo() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '남은 자리',
          style: TextStyle(fontSize: 16, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '${widget.availableSeats} ',
              style: TextStyle(
                fontSize: 44,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            Text(
              '/ ${widget.totalSeats}',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: AppColors.textLight.withOpacity(0.8),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // 등록 정보 위젯 (남은 횟수 + 유효기간)
  Widget _buildEnrollmentInfo(BuildContext context) {
    final enrollmentProvider = Provider.of<EnrollmentProvider>(context);
    final enrollment = widget.course != null
        ? enrollmentProvider.enrollmentsByCourseId[widget.course!.id]
        : null;

    if (enrollment == null) {
      return const SizedBox.shrink();
    }

    final actualRemainingReservations = enrollment.remainingReservations;

    // 유효기간 포맷팅
    String formatDate(DateTime date) {
      return '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';
    }

    // 예약 후 남은 횟수 계산
    final afterReservationCount = (actualRemainingReservations - 1).clamp(
      0,
      actualRemainingReservations,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 남은 횟수 (현재)
        Text(
          '나의 남은 횟수',
          style: TextStyle(fontSize: 16, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '$actualRemainingReservations회',
              style: TextStyle(
                fontSize: 44,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
                letterSpacing: -1,
              ),
            ),
            if (actualRemainingReservations > 0) ...[
              const SizedBox(width: 12),
              Icon(
                Icons.arrow_forward_ios,
                size: 20,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 4),
              Text(
                '${afterReservationCount}회',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '(예약 후)',
                style: TextStyle(
                  fontSize: 16,
                  color: AppColors.textSecondary.withOpacity(0.8),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 34),
        // 유효기간
        Text(
          '유효기간',
          style: TextStyle(fontSize: 16, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            // 시작일
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.backgroundLight,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                formatDate(enrollment.validFrom),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 4),
            const Text(
              '-',
              style: TextStyle(fontSize: 16, color: AppColors.textSecondary),
            ),
            const SizedBox(width: 4),
            // 마감일
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.backgroundLight,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                formatDate(enrollment.validUntil),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // 액션 버튼 위젯
  Widget _buildActionButtons(BuildContext context) {
    final canReserve = widget.remainingReservations > 0 && !_isSubmitting;

    return Row(
      children: [
        // 취소 버튼
        Expanded(
          flex: 1,
          child: ElevatedButton(
            onPressed: _isSubmitting
                ? null
                : () {
                    Navigator.of(context).pop();
                    widget.onCancel?.call();
                  },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.textPrimary.withOpacity(0.03),
              foregroundColor: AppColors.textPrimary,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              elevation: 0,
            ),
            child: const Text(
              '취소',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
          ),
        ),
        const SizedBox(width: 12),

        // 예약하기 버튼
        Expanded(
          flex: 2,
          child: ElevatedButton(
            onPressed: canReserve ? _handleConfirm : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: canReserve
                  ? AppColors.primaryGreen
                  : AppColors.textPrimary.withOpacity(0.1),
              foregroundColor: canReserve
                  ? Colors.white
                  : AppColors.textSecondary,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              elevation: 0,
            ),
            child: _isSubmitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : const Text(
                    '예약하기',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
          ),
        ),
      ],
    );
  }
}
