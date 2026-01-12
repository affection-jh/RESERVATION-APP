import 'package:flutter/material.dart';
import '../../../models/course.dart';
import '../../../models/reservation.dart';
import '../../../models/user.dart';
import '../../../theme/app_colors.dart';
import 'bulk_move_reservations_bottom_sheet.dart';
import '../../../utils/snackbar_util.dart';
import '../../../widgets/common_dialog.dart';
import '../../../providers/reservation_provider.dart';
import '../../../utils/navigator_key.dart';
import 'package:provider/provider.dart';

/// 예약 관리 간단 바텀시트 (예약 취소, 예약 변경 버튼만)
class ReservationManageBottomSheet extends StatelessWidget {
  final Course course;
  final CourseSession sourceSession;
  final DateTime sourceDate;
  final Reservation reservation;
  final User? user;
  final VoidCallback? onCancelled;
  final VoidCallback? onMoved;

  const ReservationManageBottomSheet({
    super.key,
    required this.course,
    required this.sourceSession,
    required this.sourceDate,
    required this.reservation,
    this.user,
    this.onCancelled,
    this.onMoved,
  });

  static void show({
    required BuildContext context,
    required Course course,
    required CourseSession sourceSession,
    required DateTime sourceDate,
    required Reservation reservation,
    User? user,
    VoidCallback? onCancelled,
    VoidCallback? onMoved,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.7),
      isDismissible: true,
      enableDrag: true,
      builder: (context) => ReservationManageBottomSheet(
        course: course,
        sourceSession: sourceSession,
        sourceDate: sourceDate,
        reservation: reservation,
        user: user,
        onCancelled: onCancelled,
        onMoved: onMoved,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
                decoration: BoxDecoration(
                  color: AppColors.backgroundWhite,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
                ),
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 헤더
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
                      children: [
                        Expanded(
                          child: Text(
                    '예약 관리',
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
                    ),
                    const SizedBox(height: 24),
          // 현재 세션 정보
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                      Text(
                  '현재 세션',
                        style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textSecondary.withOpacity(0.9),
                        ),
                      ),
                      const SizedBox(height: 8),
                _buildSessionInfo(),
              ],
                            ),
                          ),
          const SizedBox(height: 34),
          // 액션 버튼들
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                    onPressed: () => _handleCancel(context),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.red,
                                side: const BorderSide(color: Colors.red),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                              ),
                              child: const Text(
                                '예약 취소',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: ElevatedButton(
                    onPressed: () => _handleMove(context),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primaryGreen,
                                foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                elevation: 0,
                              ),
                              child: const Text(
                                '예약 변경시키기',
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
    );
  }

  Widget _buildSessionInfo() {
    final weekdays = ['월', '화', '수', '목', '금', '토', '일'];
    final weekday = weekdays[sourceDate.weekday - 1];
    final dateStr =
        '${sourceDate.year}-${sourceDate.month.toString().padLeft(2, '0')}-${sourceDate.day.toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.backgroundLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$dateStr ($weekday) ${sourceSession.startTime}~${sourceSession.endTime}',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
      ),
    );
  }

  Future<void> _handleCancel(BuildContext context) async {
    // 바텀시트를 먼저 닫기
    Navigator.of(context).pop();

    // 바텀시트가 닫힌 후 다이얼로그 표시
    await Future.delayed(const Duration(milliseconds: 300));

    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;

    // 다이얼로그 띄우기
    final confirmed = await CommonDialog.show(
      context: ctx,
      title: '예약 취소',
      message: '${user?.name ?? "예약자"}님의 예약을 취소하시겠습니까?',
      cancelText: '취소',
      confirmText: '예약 취소',
      confirmButtonColor: Colors.red,
    );

    if (confirmed != true) return;

    try {
      final rp = Provider.of<ReservationProvider>(ctx, listen: false);
      await rp.cancelReservation(reservation);
      onCancelled?.call();
    } catch (e) {
      final errorCtx = navigatorKey.currentContext;
      if (errorCtx != null) {
        SnackbarUtil.showError(errorCtx, '예약 취소 중 오류가 발생했습니다: $e');
      }
    }
  }

  void _handleMove(BuildContext context) {
    // 현재 바텀시트 닫기
    Navigator.of(context).pop();

    // 바텀시트가 닫힌 후 예약 변경 바텀시트 표시
    Future.delayed(const Duration(milliseconds: 300), () {
      final ctx = navigatorKey.currentContext;
      if (ctx == null) return;

      showModalBottomSheet(
        context: ctx,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withOpacity(0.7),
        isDismissible: true,
        enableDrag: true,
        builder: (context) => BulkMoveReservationsBottomSheet(
          course: course,
          sourceSession: sourceSession,
          sourceDate: sourceDate,
          reservations: [reservation],
          user: user,
          onMoved: () {
            onMoved?.call();
          },
          onCancelled: () {
            onCancelled?.call();
          },
        ),
      );
    });
  }
}
