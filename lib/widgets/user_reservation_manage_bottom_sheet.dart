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
import '../../utils/navigator_key.dart';

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
      // ✅ 스와이프(내려서 닫기) / 바깥 탭 닫기 지원
      // 처리 중이어도 백그라운드에서 서버 처리는 계속 진행되며,
      // 캘린더/리스트 UI에서 "진행 중" 표시로 피드백을 제공한다.
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
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
      decoration: const BoxDecoration(color: Colors.transparent),
      child: Stack(
        children: [
          // 배경 탭 시 닫기
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
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
                canPop: true,
                child: Container(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.9,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.backgroundWhite,
                    borderRadius: BorderRadius.circular(30),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(height: 10),
                        // 제목과 닫기 버튼
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Row(
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
                                onPressed: () => Navigator.of(context).pop(),
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
                        ),

                        // 날짜/시간 정보 (칩 형태)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.backgroundLight,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 윗줄: 요일과 날짜
                              Text(
                                '${_getDayName(widget.date.weekday)}요일 ${widget.date.day}일',
                                style: TextStyle(
                                  fontSize: 17,
                                  color: AppColors.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              // 아래줄: 시간
                              Text(
                                '${widget.session.startTime} ~ ${widget.session.endTime}',
                                style: TextStyle(
                                  fontSize: 15,
                                  color: AppColors.textSecondary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 30),

                        // 남은 자리 섹션 (실시간 업데이트)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '남은 자리',
                                style: TextStyle(
                                  fontSize: 15,
                                  color: AppColors.textSecondary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),

                              const SizedBox(height: 8),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.baseline,
                                textBaseline: TextBaseline.alphabetic,
                                children: [
                                  Text(
                                    '${availableSeats} ',
                                    style: TextStyle(
                                      fontSize: 44,
                                      fontWeight: FontWeight.bold,
                                      color: AppColors.textPrimary,
                                    ),
                                  ),
                                  Text(
                                    '/ ${totalSeats}',
                                    style: TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.bold,
                                      color: AppColors.textLight.withOpacity(
                                        0.8,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 32),

                              // 나의 남은 횟수 섹션
                              Text(
                                '남은 예약 횟수',
                                style: TextStyle(
                                  fontSize: 15,
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
                              const SizedBox(height: 52),
                            ],
                          ),
                        ),

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
                                  vertical: 18,
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
                                              AppColors.primaryGreen,
                                            ),
                                      ),
                                    )
                                  : const Text(
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
                                      vertical: 18,
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
                                                  AppColors.primaryGreen,
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
                        const SizedBox(height: 10),
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

    debugPrint('[UserReservationManageBottomSheet] _createReservation start');
    debugPrint(
      '[UserReservationManageBottomSheet] placeId(from PlaceProvider): $placeId',
    );
    debugPrint(
      '[UserReservationManageBottomSheet] userId(from AuthProvider): $userId',
    );
    debugPrint(
      '[UserReservationManageBottomSheet] courseId: ${widget.course.id}',
    );
    debugPrint(
      '[UserReservationManageBottomSheet] session: dayOfWeek=${widget.session.dayOfWeek} start=${widget.session.startTime}',
    );
    debugPrint('[UserReservationManageBottomSheet] date: ${widget.date}');

    if (placeId == null || userId == null) {
      debugPrint(
        '[UserReservationManageBottomSheet] _createReservation abort: placeId or userId is null',
      );
      SnackbarUtil.showError(context, '로그인이 필요합니다.');
      return false;
    }

    try {
      debugPrint(
        '[UserReservationManageBottomSheet] ReservationProvider.createReservation 호출 시작',
      );
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
      debugPrint(
        '[UserReservationManageBottomSheet] ReservationProvider.createReservation 성공',
      );

      if (!mounted) return false;
      widget.onReservationCreated?.call();
      SnackbarUtil.showSuccess(context, '예약이 완료되었습니다.');
      return true;
    } catch (e) {
      debugPrint(
        '[UserReservationManageBottomSheet] _createReservation failed: $e',
      );
      if (!mounted) return false;
      SnackbarUtil.showError(context, '예약 중 오류가 발생했습니다: $e');
      return false;
    }
  }

  void _showCancelDialog() {
    debugPrint('[UserReservationManageBottomSheet] _showCancelDialog open');
    // 바텀시트 먼저 닫기
    Navigator.of(context).pop();

    // 다이얼로그 띄우기
    CommonDialog.show(
      context: context,
      title: '예약 취소',
      message: '예약을 취소하시겠습니까?',
      cancelText: '취소',
      confirmText: '예약 취소',
      confirmButtonColor: Colors.red,
      onCancel: () {
        // 취소 시 바텀시트 다시 열기 (롤백)
        if (mounted) {
          UserReservationManageBottomSheet.show(
            context: context,
            course: widget.course,
            session: widget.session,
            date: widget.date,
            reservation: widget.reservation,
            onReservationCancelled: widget.onReservationCancelled,
            onReservationCreated: widget.onReservationCreated,
          );
        }
      },
      onConfirm: () async {
        debugPrint('[UserReservationManageBottomSheet] cancel confirm pressed');
        // ⚠️ CommonDialog 내부에서 이미 다이얼로그는 닫힘.
        // 여기서 Navigator.pop(context)를 호출하면 바텀시트까지 닫혀버릴 수 있음.
        final reservation = widget.reservation;
        if (reservation == null) {
          debugPrint(
            '[UserReservationManageBottomSheet] cancel abort: widget.reservation is null',
          );
          return;
        }

        // 바텀시트를 닫은 후 context 사용을 위해 rootContext 저장
        final rootContext = navigatorKey.currentContext ?? context;

        try {
          debugPrint('[UserReservationManageBottomSheet] cancel submit start');
          debugPrint(
            '[UserReservationManageBottomSheet] cancel target reservationId=${reservation.id} userId=${reservation.userId} placeId=${reservation.placeId} courseId=${reservation.courseId}',
          );
          debugPrint(
            '[UserReservationManageBottomSheet] cancel target date=${reservation.reservedDate} dayOfWeek=${reservation.dayOfWeek} startTime=${reservation.startTime}',
          );

          // 예약 취소 진행 중 로딩 다이얼로그
          showDialog(
            context: rootContext,
            barrierDismissible: false,
            builder: (_) {
              return WillPopScope(
                onWillPop: () async => false,
                child: const Center(
                  child: CircularProgressIndicator(
                    color: AppColors.primaryGreen,
                  ),
                ),
              );
            },
          );

          await Provider.of<ReservationProvider>(
            context,
            listen: false,
          ).cancelReservation(reservation);
          debugPrint(
            '[UserReservationManageBottomSheet] ReservationProvider.deleteReservation success',
          );

          // 로딩 다이얼로그 닫기
          if (rootContext.mounted) {
            Navigator.of(rootContext, rootNavigator: true).pop();
          }

          // 바텀시트는 이미 닫혔으므로 다시 열지 않음
          widget.onReservationCancelled?.call();
          if (mounted) {
            SnackbarUtil.showSuccess(context, '예약이 취소되었습니다.');
          } else {
            // 바텀시트가 닫힌 상태여도 사용자에게 피드백은 필요함 (전역 context 사용)
            final ctx = navigatorKey.currentContext;
            if (ctx != null) {
              SnackbarUtil.showSuccess(ctx, '예약이 취소되었습니다.');
            }
          }
          debugPrint(
            '[UserReservationManageBottomSheet] cancel flow done -> bottom sheet closed',
          );
        } catch (e) {
          debugPrint(
            '[UserReservationManageBottomSheet] cancel flow failed: $e',
          );

          // 로딩 다이얼로그가 떠있으면 닫기
          if (rootContext.mounted) {
            try {
              Navigator.of(rootContext, rootNavigator: true).pop();
            } catch (_) {}
          }

          if (!mounted) return;
          SnackbarUtil.showError(context, '예약 취소 중 오류가 발생했습니다: $e');
          // 에러 발생 시 바텀시트 다시 열기
          UserReservationManageBottomSheet.show(
            context: context,
            course: widget.course,
            session: widget.session,
            date: widget.date,
            reservation: widget.reservation,
            onReservationCancelled: widget.onReservationCancelled,
            onReservationCreated: widget.onReservationCreated,
          );
          debugPrint('[UserReservationManageBottomSheet] cancel submit end');
        }
      },
    );
  }
}
