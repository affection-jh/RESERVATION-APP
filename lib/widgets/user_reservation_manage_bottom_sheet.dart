import 'dart:async';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/course.dart';
import '../../models/session_reservation.dart';
import '../../providers/reservation_provider.dart';
import '../../providers/enrollment_provider.dart';
import '../../providers/place_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/course_provider.dart';
import '../../theme/app_colors.dart';
import '../../widgets/common_dialog.dart';
import '../../utils/snackbar_util.dart';
import '../../utils/navigator_key.dart';
import '../../utils/timezone_utils.dart';

/// 유저 예약 관리 바텀시트 (예약 취소/생성)
class UserReservationManageBottomSheet extends StatefulWidget {
  final Course course;
  final CourseSession session;
  final DateTime date;
  final SessionReservation? reservation; // null이면 예약 없음
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
    SessionReservation? reservation,
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
      useSafeArea: true,
      builder:
          (context) => UserReservationManageBottomSheet(
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
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _ensurePolicyLoaded();
  }

  /// 정책이 없으면 로드
  Future<void> _ensurePolicyLoaded() async {
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final placeId = placeProvider.currentPlace?.id;

    if (placeId != null &&
        courseProvider.getCoursePolicy(widget.course.id) == null) {
      await courseProvider.loadCoursePolicy(widget.course.id, placeId);
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  // 요일 이름 변환
  String _getDayName(int dayOfWeek) {
    const days = ['', '월', '화', '수', '목', '금', '토', '일'];
    if (dayOfWeek >= 1 && dayOfWeek <= 7) {
      return days[dayOfWeek];
    }
    return '';
  }

  /// 취소 가능 여부 체크 (정책 기반)
  bool _canCancelReservation() {
    if (widget.reservation == null) return false;

    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final placeId = placeProvider.currentPlace?.id;

    if (placeId == null) return false;

    // 정책 가져오기 (없으면 기본값 60분 사용)
    final policy = courseProvider.getCoursePolicy(widget.course.id);
    final closeBeforeMinutes = policy?.closeBeforeMinutes ?? 60;

    // 세션 시작 시간 계산
    final now = TimezoneUtils.getSeoulDateTime();
    final sessionStartTime = TimezoneUtils.combineDateAndTimeSeoul(
      widget.date,
      widget.session.startTime,
    );

    // 세션 시작 N분 전까지 취소 가능
    final closeAt = sessionStartTime.subtract(
      Duration(minutes: closeBeforeMinutes),
    );

    // 현재 시간이 마감 시간 이후면 취소 불가
    return now.isBefore(closeAt);
  }

  /// 취소 불가 에러 메시지 생성
  String _getCancellationErrorMessage() {
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final policy = courseProvider.getCoursePolicy(widget.course.id);
    final closeBeforeMinutes = policy?.closeBeforeMinutes ?? 60;

    // 시간 단위 계산
    final hours = closeBeforeMinutes ~/ 60;
    final minutes = closeBeforeMinutes % 60;

    String timeText;
    if (hours > 0 && minutes > 0) {
      timeText = '${hours}시간 ${minutes}분';
    } else if (hours > 0) {
      timeText = '${hours}시간';
    } else {
      timeText = '${minutes}분';
    }

    return '시작 ${timeText} 전까지만 취소할 수 있어요';
  }

  @override
  Widget build(BuildContext context) {
    final enrollmentProvider = Provider.of<EnrollmentProvider>(context);
    final enrollment =
        enrollmentProvider.enrollmentsByCourseId[widget.course.id];
    final remainingReservations = enrollment?.remainingReservations ?? 0;
    final totalReservations = enrollment?.totalReservations ?? remainingReservations;

    // 취소 가능 여부 체크
    final canCancel =
        widget.reservation != null ? _canCancelReservation() : false;

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
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(30),
                    ),
                  ),
                  padding: EdgeInsets.only(
                    left: 20,
                    right: 20,
                    top: 12,
                    bottom: 12 + MediaQuery.of(context).padding.bottom,
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
                        const SizedBox(height: 24),

                        // 남은 예약 횟수 (n/m, 구독/남은 자리 미표시)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '남은 예약 횟수',
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
                                    '$remainingReservations',
                                    style: TextStyle(
                                      fontSize: 44,
                                      fontWeight: FontWeight.bold,
                                      color: AppColors.textPrimary,
                                      letterSpacing: -1,
                                    ),
                                  ),
                                  Text(
                                    ' / $totalReservations',
                                    style: TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.bold,
                                      color: AppColors.textLight.withOpacity(0.8),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 42),
                            ],
                          ),
                        ),

                        // 버튼들
                        if (widget.reservation != null) ...[
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed:
                                  _isSubmitting || !canCancel
                                      ? null
                                      : _cancelReservation,
                              style: ElevatedButton.styleFrom(
                                backgroundColor:
                                    canCancel
                                        ? AppColors.textPrimary.withOpacity(0.1)
                                        : AppColors.textPrimary.withOpacity(
                                          0.05,
                                        ),
                                foregroundColor:
                                    canCancel
                                        ? AppColors.textPrimary
                                        : AppColors.textSecondary,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 18,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                elevation: 0,
                              ),
                              child: Text(
                                canCancel ? '예약 취소' : '취소 불가',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          if (!canCancel) ...[
                            const SizedBox(height: 8),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              child: Text(
                                _getCancellationErrorMessage(),
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textSecondary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ] else
                          Row(
                            children: [
                              // 취소 버튼
                              Expanded(
                                child: ElevatedButton(
                                  onPressed:
                                      _isSubmitting
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
                                      remainingReservations > 0
                                          ? () async {
                                            if (_isSubmitting) return;
                                            setState(() {
                                              _isSubmitting = true;
                                            });
                                            final ok =
                                                await _createReservation();
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
                                        remainingReservations > 0
                                            ? AppColors.textPrimary
                                            : AppColors.textPrimary.withOpacity(
                                              0.3,
                                            ),
                                    foregroundColor: Colors.white,
                                    disabledForegroundColor:
                                        AppColors.textSecondary,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 16,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    elevation: 0,
                                  ),
                                  child:
                                      _isSubmitting
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
      SnackbarUtil.showInfo(context, '로그인이 필요합니다.');
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
        SessionReservation(
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
      SnackbarUtil.showInfo(context, '예약 중 오류가 발생했습니다.');
      return false;
    }
  }

  Future<void> _cancelReservation() async {
    final reservation = widget.reservation;
    if (reservation == null) return;

    // 취소 가능 여부 재확인
    if (!_canCancelReservation()) {
      SnackbarUtil.showInfo(context, _getCancellationErrorMessage());
      return;
    }

    // 바텀시트를 먼저 내리고, 닫힌 후 다이얼로그 표시
    Navigator.of(context).pop();
    await Future.delayed(const Duration(milliseconds: 150));

    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;

    final dayName = _getDayName(widget.date.weekday);
    final confirmed = await CommonDialog.show(
      context: ctx,
      title: '예약 취소',
      message:
          '${dayName}요일 ${widget.date.day}일 ${widget.session.startTime} - ${widget.session.endTime}\n'
          '예약을 취소하시겠습니까?',
      cancelText: '취소',
      confirmText: '예약 취소',
      confirmButtonColor: Colors.red,
    );
    if (confirmed != true) return;

    final rp = Provider.of<ReservationProvider>(ctx, listen: false);

    try {
      await rp.cancelReservation(reservation);
      widget.onReservationCancelled?.call();
      // 성공 피드백은 CalendarScreen/MyPageScreen의 operationEvents에서 처리됨
    } on FirebaseFunctionsException catch (e) {
      debugPrint('[UserReservationManageBottomSheet] 예약 취소 실패: $e');
      final ctx = navigatorKey.currentContext;
      if (ctx != null) {
        final msg =
            e.code == 'permission-denied'
                ? '예약 취소에 대한 권한이 없습니다.'
                : '예약 취소 중 오류가 발생했습니다.';
        SnackbarUtil.showInfo(ctx, msg);
      }
    } catch (e) {
      debugPrint('[UserReservationManageBottomSheet] 예약 취소 실패: $e');
      final ctx = navigatorKey.currentContext;
      if (ctx != null) {
        SnackbarUtil.showInfo(ctx, '예약 취소 중 오류가 발생했습니다.');
      }
    }
  }
}
