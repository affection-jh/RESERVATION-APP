import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/course.dart';
import '../../models/reservation.dart';
import '../../models/session_reservation.dart';
import '../../providers/reservation_provider.dart';
import '../../providers/enrollment_provider.dart';
import '../../providers/place_provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/firestore_service.dart';
import '../../theme/app_colors.dart';
import '../../widgets/common_dialog.dart';
import '../../utils/snackbar_util.dart';

/// 유저 예약 관리 바텀시트 (예약 취소/생성)
class UserReservationManageBottomSheet extends StatefulWidget {
  final Course course;
  final CourseSession session;
  final DateTime date;
  final Reservation? reservation; // null이면 예약 없음
  final VoidCallback? onReservationCancelled;
  final VoidCallback? onReservationCreated;

  const UserReservationManageBottomSheet({
    super.key,
    required this.course,
    required this.session,
    required this.date,
    this.reservation,
    this.onReservationCancelled,
    this.onReservationCreated,
  });

  static void show({
    required BuildContext context,
    required Course course,
    required CourseSession session,
    required DateTime date,
    Reservation? reservation,
    VoidCallback? onReservationCancelled,
    VoidCallback? onReservationCreated,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.7),
      isDismissible: true,
      enableDrag: true,
      builder: (context) => UserReservationManageBottomSheet(
        course: course,
        session: session,
        date: date,
        reservation: reservation,
        onReservationCancelled: onReservationCancelled,
        onReservationCreated: onReservationCreated,
      ),
    );
  }

  @override
  State<UserReservationManageBottomSheet> createState() =>
      _UserReservationManageBottomSheetState();
}

class _UserReservationManageBottomSheetState
    extends State<UserReservationManageBottomSheet> {
  final FirestoreService _firestoreService = FirestoreService();
  StreamSubscription<SessionReservation?>? _sessionReservationSub;
  SessionReservation? _sessionReservation;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _subscribeSessionReservation();
  }

  @override
  void dispose() {
    _sessionReservationSub?.cancel();
    super.dispose();
  }

  void _subscribeSessionReservation() {
    _sessionReservationSub?.cancel();

    _sessionReservationSub = _firestoreService
        .watchSessionReservation(
          courseId: widget.course.id,
          dayOfWeek: widget.session.dayOfWeek,
          startTime: widget.session.startTime,
          date: widget.date,
        )
        .listen(
          (sr) {
            if (!mounted) return;
            setState(() {
              _sessionReservation = sr;
            });
          },
          onError: (_) {
            if (!mounted) return;
            setState(() {
              _sessionReservation = null;
            });
          },
        );
  }

  // 요일 이름 변환
  String _getDayName(int dayOfWeek) {
    const days = ['', '월', '화', '수', '목', '금', '토', '일'];
    if (dayOfWeek >= 1 && dayOfWeek <= 7) {
      return days[dayOfWeek];
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final enrollmentProvider = Provider.of<EnrollmentProvider>(context);
    final enrollment =
        enrollmentProvider.enrollmentsByCourseId[widget.course.id];
    final remainingReservations = enrollment?.remainingReservations ?? 0;

    // 실시간 남은 자리 계산
    final totalSeats =
        _sessionReservation?.capacity ??
        widget.session.getCapacityForDate(widget.date);
    final reservedCount = _sessionReservation?.reservedCount ?? 0;
    final availableSeats = (totalSeats - reservedCount).clamp(0, totalSeats);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: const BoxDecoration(color: Colors.transparent),
      child: Stack(
        children: [
          // 배경 탭 시 닫기
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
                if (_isSubmitting) return;
                Navigator.of(context).pop();
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
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.9,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.backgroundWhite,
                    borderRadius: BorderRadius.circular(30),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 제목과 닫기 버튼
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                widget.course.name,
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.textPrimary,
                                  letterSpacing: -0.5,
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: _isSubmitting
                                  ? null
                                  : () => Navigator.of(context).pop(),
                              icon: const Icon(
                                Icons.close,
                                color: AppColors.textSecondary,
                                size: 24,
                              ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // 날짜/시간 정보
                        Text(
                          '${_getDayName(widget.date.weekday)}요일 ${widget.date.day}일 • ${widget.session.startTime} ~ ${widget.session.endTime}',
                          style: TextStyle(
                            fontSize: 16,
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),

                        // 남은 자리 섹션 (실시간 업데이트)
                        Text(
                          '남은 자리',
                          style: TextStyle(
                            fontSize: 14,
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '$availableSeats / $totalSeats',
                          style: const TextStyle(
                            fontSize: 44,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                            letterSpacing: -1,
                          ),
                        ),
                        const SizedBox(height: 32),

                        // 나의 남은 횟수 섹션
                        Text(
                          '나의 남은 횟수',
                          style: TextStyle(
                            fontSize: 14,
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${remainingReservations}회',
                          style: const TextStyle(
                            fontSize: 44,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                            letterSpacing: -1,
                          ),
                        ),
                        const SizedBox(height: 32),

                        // 버튼들
                        if (widget.reservation != null)
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: _isSubmitting
                                  ? null
                                  : _showCancelDialog,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.textPrimary
                                    .withOpacity(0.1),
                                foregroundColor: AppColors.textPrimary,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                elevation: 0,
                              ),
                              child: const Text(
                                '예약 취소',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          )
                        else
                          Row(
                            children: [
                              // 취소 버튼
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: _isSubmitting
                                      ? null
                                      : () => Navigator.of(context).pop(),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.backgroundWhite,
                                    foregroundColor: AppColors.textPrimary,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 16,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20),
                                      side: BorderSide(
                                        color: AppColors.borderLight,
                                        width: 1,
                                      ),
                                    ),
                                    elevation: 0,
                                  ),
                                  child: const Text(
                                    '취소',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              // 예약하기 버튼
                              Expanded(
                                child: ElevatedButton(
                                  onPressed:
                                      availableSeats > 0 &&
                                          remainingReservations > 0
                                      ? () async {
                                          if (_isSubmitting) return;
                                          setState(() {
                                            _isSubmitting = true;
                                          });
                                          final ok = await _createReservation();
                                          if (!mounted) return;
                                          if (ok) {
                                            Navigator.of(context).pop();
                                          } else {
                                            setState(() {
                                              _isSubmitting = false;
                                            });
                                          }
                                        }
                                      : null,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor:
                                        availableSeats > 0 &&
                                            remainingReservations > 0
                                        ? AppColors.textPrimary
                                        : AppColors.textPrimary.withOpacity(
                                            0.3,
                                          ),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 16,
                                    ),
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
                                            valueColor:
                                                AlwaysStoppedAnimation<Color>(
                                                  Colors.white,
                                                ),
                                          ),
                                        )
                                      : const Text(
                                          '예약하기',
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
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
            ),
          ),
        ],
      ),
    );
  }

  Future<bool> _createReservation() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final placeId = placeProvider.currentPlace?.id;
    final userId = authProvider.currentUser?.userId;

    if (placeId == null || userId == null) {
      SnackbarUtil.showError(context, '로그인이 필요합니다.');
      return false;
    }

    try {
      await Provider.of<ReservationProvider>(
        context,
        listen: false,
      ).createReservation(
        Reservation(
          id: '',
          userId: userId,
          courseId: widget.course.id,
          placeId: placeId,
          dayOfWeek: widget.session.dayOfWeek,
          startTime: widget.session.startTime,
          reservedAt: DateTime.now(),
          reservedDate: DateTime(
            widget.date.year,
            widget.date.month,
            widget.date.day,
          ),
        ),
      );

      if (!mounted) return false;
      widget.onReservationCreated?.call();
      SnackbarUtil.showSuccess(context, '예약이 완료되었습니다.');
      return true;
    } catch (e) {
      if (!mounted) return false;
      SnackbarUtil.showError(context, '예약 중 오류가 발생했습니다: $e');
      return false;
    }
  }

  void _showCancelDialog() {
    CommonDialog.show(
      context: context,
      title: '예약 취소',
      message: '예약을 취소하시겠습니까?',
      cancelText: '취소',
      confirmText: '예약 취소',
      confirmButtonColor: Colors.red,
      onConfirm: () async {
        // 다이얼로그 닫기
        Navigator.of(context).pop();

        final reservation = widget.reservation;
        if (reservation == null) return;

        try {
          if (!mounted) return;
          setState(() {
            _isSubmitting = true;
          });
          await Provider.of<ReservationProvider>(
            context,
            listen: false,
          ).deleteReservation(
            reservationId: reservation.id,
            placeId: reservation.placeId,
          );

          if (!mounted) return;
          Navigator.of(context).pop(); // 바텀시트 닫기
          widget.onReservationCancelled?.call();
          SnackbarUtil.showSuccess(context, '예약이 취소되었습니다.');
        } catch (e) {
          if (!mounted) return;
          SnackbarUtil.showError(context, '예약 취소 중 오류가 발생했습니다: $e');
          setState(() {
            _isSubmitting = false;
          });
        }
      },
    );
  }
}
