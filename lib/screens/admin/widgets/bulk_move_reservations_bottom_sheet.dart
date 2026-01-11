import 'package:flutter/material.dart';
import '../../../models/course.dart';
import '../../../models/reservation.dart';
import '../../../theme/app_colors.dart';
import '../../../services/firestore_service.dart';
import '../../../widgets/compact_calendar_widget.dart';
import '../../../utils/snackbar_util.dart';
import '../../../widgets/common_dialog.dart';

/// 세션의 모든 예약자를 일괄 이동하는 바텀시트
class BulkMoveReservationsBottomSheet extends StatefulWidget {
  final Course course;
  final CourseSession sourceSession;
  final DateTime sourceDate;
  final List<Reservation> reservations;
  final VoidCallback? onMoved;

  const BulkMoveReservationsBottomSheet({
    super.key,
    required this.course,
    required this.sourceSession,
    required this.sourceDate,
    required this.reservations,
    this.onMoved,
  });

  @override
  State<BulkMoveReservationsBottomSheet> createState() =>
      _BulkMoveReservationsBottomSheetState();
}

class _BulkMoveReservationsBottomSheetState
    extends State<BulkMoveReservationsBottomSheet> {
  final FirestoreService _firestoreService = FirestoreService();
  CourseSession? _selectedTargetSession;
  DateTime? _selectedTargetDate;
  bool _isMoving = false;
  int _movedCount = 0;
  int _failedCount = 0;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 헤더
          Row(
            children: [
              Expanded(
                child: Text(
                  '예약자 일괄 이동',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
                color: AppColors.textSecondary,
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 안내 메시지
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.backgroundLight,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  color: AppColors.primaryGreen,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${widget.reservations.length}명의 예약자를 이동할 세션을 선택하세요',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          // 현재 세션 정보
          Text(
            '현재 세션',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          _buildSessionInfo(
            widget.sourceSession,
            widget.sourceDate,
            isSource: true,
          ),
          const SizedBox(height: 24),
          // 이동할 세션 선택
          Text(
            '이동할 세션 선택',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            height: 300,
            decoration: BoxDecoration(
              color: AppColors.backgroundLight,
              borderRadius: BorderRadius.circular(12),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: CompactCalendarWidget(
                courses: [widget.course],
                usage: CompactCalendarUsage.adminSelectNewSlot,
                weekOffset: 0,
                height: 300,
                onSessionTap: (course, session, date) {
                  setState(() {
                    // 같은 세션이면 선택 해제
                    if (_selectedTargetSession != null &&
                        _selectedTargetDate != null &&
                        _selectedTargetSession!.dayOfWeek ==
                            session.dayOfWeek &&
                        _selectedTargetSession!.startTime ==
                            session.startTime &&
                        _selectedTargetDate!.year == date.year &&
                        _selectedTargetDate!.month == date.month &&
                        _selectedTargetDate!.day == date.day) {
                      _selectedTargetSession = null;
                      _selectedTargetDate = null;
                    } else {
                      _selectedTargetSession = session;
                      _selectedTargetDate = date;
                    }
                  });
                },
                hideCourseSelector: true,
                adminSelectionMode: true,
                currentReservationDayOfWeek: widget.sourceSession.dayOfWeek,
                currentReservationStartTime: widget.sourceSession.startTime,
                currentReservationDate: widget.sourceDate,
              ),
            ),
          ),
          if (_selectedTargetSession != null &&
              _selectedTargetDate != null) ...[
            const SizedBox(height: 16),
            _buildSessionInfo(
              _selectedTargetSession!,
              _selectedTargetDate!,
              isSource: false,
            ),
          ],
          const SizedBox(height: 24),
          // 이동 버튼
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed:
                  (_isMoving ||
                      _selectedTargetSession == null ||
                      _selectedTargetDate == null)
                  ? null
                  : _moveAllReservations,
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
              child: _isMoving
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '이동 중... ($_movedCount/${widget.reservations.length})',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    )
                  : Text(
                      '${widget.reservations.length}명 일괄 이동',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionInfo(
    CourseSession session,
    DateTime date, {
    required bool isSource,
  }) {
    final weekdays = ['월', '화', '수', '목', '금', '토', '일'];
    final weekday = weekdays[date.weekday - 1];
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isSource
            ? AppColors.backgroundLight
            : AppColors.primaryGreen.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSource ? AppColors.borderLight : AppColors.primaryGreen,
          width: isSource ? 1 : 2,
        ),
      ),
      child: Row(
        children: [
          Icon(
            isSource ? Icons.arrow_upward : Icons.arrow_downward,
            color: isSource ? AppColors.textSecondary : AppColors.primaryGreen,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$dateStr ($weekday) ${session.startTime}~${session.endTime}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isSource
                    ? AppColors.textPrimary
                    : AppColors.primaryGreen,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _moveAllReservations() async {
    if (_selectedTargetSession == null || _selectedTargetDate == null) return;

    // 같은 세션으로 이동하려는 경우
    if (_selectedTargetSession!.dayOfWeek == widget.sourceSession.dayOfWeek &&
        _selectedTargetSession!.startTime == widget.sourceSession.startTime &&
        _selectedTargetDate!.year == widget.sourceDate.year &&
        _selectedTargetDate!.month == widget.sourceDate.month &&
        _selectedTargetDate!.day == widget.sourceDate.day) {
      SnackbarUtil.showError(context, '같은 세션으로는 이동할 수 없습니다.');
      return;
    }

    final confirmed = await CommonDialog.show(
      context: context,
      title: '일괄 이동',
      message: '${widget.reservations.length}명의 예약자를 선택한 세션으로 이동하시겠습니까?',
      cancelText: '취소',
      confirmText: '이동',
      confirmButtonColor: AppColors.primaryGreen,
    );

    if (confirmed != true) return;

    setState(() {
      _isMoving = true;
      _movedCount = 0;
      _failedCount = 0;
    });

    // 모든 예약자를 순차적으로 이동
    for (final reservation in widget.reservations) {
      try {
        await _firestoreService.moveReservationWithinCourse(
          reservationId: reservation.id,
          placeId: reservation.placeId,
          newDayOfWeek: _selectedTargetSession!.dayOfWeek,
          newStartTime: _selectedTargetSession!.startTime,
          newReservedDate: _selectedTargetDate!,
        );
        setState(() {
          _movedCount++;
        });
      } catch (e) {
        setState(() {
          _failedCount++;
        });
        // 개별 실패는 로그만 남기고 계속 진행
        debugPrint('Failed to move reservation ${reservation.id}: $e');
      }
    }

    if (!mounted) return;

    setState(() {
      _isMoving = false;
    });

    // 결과 표시
    if (_failedCount == 0) {
      SnackbarUtil.showSuccess(
        context,
        '${widget.reservations.length}명의 예약자가 이동되었습니다.',
      );
      widget.onMoved?.call();
      Navigator.of(context).pop();
    } else {
      SnackbarUtil.showError(
        context,
        '$_movedCount명 이동 완료, $_failedCount명 이동 실패',
      );
      // 일부라도 성공했으면 콜백 호출
      if (_movedCount > 0) {
        widget.onMoved?.call();
      }
    }
  }
}
