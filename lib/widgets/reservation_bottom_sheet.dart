import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:provider/provider.dart';
import '../models/course.dart';
import '../models/session_reservation.dart';
import '../providers/enrollment_provider.dart';
import '../theme/app_colors.dart';
import '../utils/error_message_util.dart';
import '../utils/navigator_key.dart';
import '../utils/snackbar_util.dart';
import '../widgets/common_dialog.dart';

class SessionReservationBottomSheet extends StatefulWidget {
  final String activityName;
  final String date;
  final String startTime;
  final String endTime;
  final int availableSeats;
  final int totalSeats;
  final int remainingSessionReservations;
  final Course? course; // 코스 정보 (유효기간 조회용)
  final Future<SessionReservation> Function()? onConfirm;
  final VoidCallback? onCancel;

  /// 관리자 강제 추가: 마감 임박/정원초과 시 force로 재시도 가능
  final bool canForceAdd;
  final Future<SessionReservation> Function()? onForceConfirm;

  const SessionReservationBottomSheet({
    super.key,
    required this.activityName,
    required this.date,
    required this.startTime,
    required this.endTime,
    required this.availableSeats,
    required this.totalSeats,
    this.remainingSessionReservations = 0,
    this.course,
    this.onConfirm,
    this.onCancel,
    this.canForceAdd = false,
    this.onForceConfirm,
  });

  static Future<SessionReservation?> show({
    required BuildContext context,
    required String activityName,
    required String date,
    required String startTime,
    required String endTime,
    required int availableSeats,
    required int totalSeats,
    int remainingSessionReservations = 0,
    Course? course,
    Future<SessionReservation> Function()? onConfirm,
    VoidCallback? onCancel,
    bool canForceAdd = false,
    Future<SessionReservation> Function()? onForceConfirm,
  }) {
    return showModalBottomSheet<SessionReservation?>(
      context: context,
      isScrollControlled: true,
      // ✅ 스와이프(내려서 닫기) / 바깥 탭 닫기 지원
      // 처리 중이어도 백그라운드에서 서버 처리는 계속 진행되며,
      // 캘린더/리스트 UI에서 "진행 중" 표시로 피드백을 제공한다.
      isDismissible: true,
      enableDrag: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.7),
      useSafeArea: true,
      builder:
          (context) => SessionReservationBottomSheet(
            activityName: activityName,
            date: date,
            startTime: startTime,
            endTime: endTime,
            availableSeats: availableSeats,
            totalSeats: totalSeats,
            remainingSessionReservations: remainingSessionReservations,
            course: course,
            onConfirm: onConfirm,
            onCancel: onCancel,
            canForceAdd: canForceAdd,
            onForceConfirm: onForceConfirm,
          ),
    );
  }

  @override
  State<SessionReservationBottomSheet> createState() =>
      _SessionReservationBottomSheetState();
}

class _SessionReservationBottomSheetState
    extends State<SessionReservationBottomSheet> {
  bool _isSubmitting = false;

  Future<void> _handleConfirm() async {
    if (_isSubmitting) {
      debugPrint('[SessionReservationBottomSheet] 이미 예약 처리 중입니다.');
      return;
    }
    if (widget.remainingSessionReservations <= 0) {
      debugPrint(
        '[SessionReservationBottomSheet] 남은 횟수가 없습니다: ${widget.remainingSessionReservations}',
      );
      return;
    }
    if (widget.onConfirm == null) {
      debugPrint('[SessionReservationBottomSheet] onConfirm 콜백이 없습니다.');
      return;
    }

    debugPrint('[SessionReservationBottomSheet] 예약 시작');
    debugPrint('[SessionReservationBottomSheet] 활동명: ${widget.activityName}');
    debugPrint('[SessionReservationBottomSheet] 날짜: ${widget.date}');
    debugPrint(
      '[SessionReservationBottomSheet] 시간: ${widget.startTime} - ${widget.endTime}',
    );
    debugPrint(
      '[SessionReservationBottomSheet] 남은 자리: ${widget.availableSeats} / ${widget.totalSeats}',
    );
    debugPrint(
      '[SessionReservationBottomSheet] 내 남은 횟수: ${widget.remainingSessionReservations}',
    );
    if (widget.course != null) {
      debugPrint('[SessionReservationBottomSheet] 코스 ID: ${widget.course!.id}');
      debugPrint('[SessionReservationBottomSheet] 코스명: ${widget.course!.name}');
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      debugPrint('[SessionReservationBottomSheet] onConfirm 콜백 호출 시작');
      final created = await widget.onConfirm!.call();
      debugPrint('[SessionReservationBottomSheet] 예약 생성 성공: ${created.id}');
      if (!mounted) {
        debugPrint('[SessionReservationBottomSheet] 위젯이 unmount되었습니다.');
        return;
      }
      Navigator.of(context).pop<SessionReservation>(created);
    } catch (e, stackTrace) {
      debugPrint('[SessionReservationBottomSheet] 예약 생성 실패');
      debugPrint('[SessionReservationBottomSheet] 에러 타입: ${e.runtimeType}');
      debugPrint('[SessionReservationBottomSheet] 에러 메시지: $e');
      debugPrint('[SessionReservationBottomSheet] 스택 트레이스: $stackTrace');

      final errorMessage = _getErrorMessage(e);
      if (!mounted) {
        final safeCtx = navigatorKey.currentContext;
        if (safeCtx != null) {
          SnackbarUtil.showInfo(safeCtx, errorMessage);
        }
        debugPrint('[SessionReservationBottomSheet] 위젯이 unmount되었습니다 (에러 후).');
        return;
      }
      setState(() {
        _isSubmitting = false;
      });
      final isForceable =
          widget.canForceAdd &&
          widget.onForceConfirm != null &&
          _isForceableError(e, errorMessage);

      if (isForceable) {
        final confirmed = await CommonDialog.show(
          context: context,
          title: '관리자 강제 추가',
          message:
              '예약이 마감되었습니다.\n'
              '관리자 권한으로 강제 추가하시겠습니까?',
          cancelText: '취소',
          confirmText: '강제 추가',
        );
        if (confirmed == true && mounted && widget.onForceConfirm != null) {
          setState(() {
            _isSubmitting = true;
          });
          try {
            final created = await widget.onForceConfirm!();
            if (!mounted) return;
            Navigator.of(context).pop<SessionReservation>(created);
          } catch (e2) {
            if (!mounted) return;
            setState(() {
              _isSubmitting = false;
            });
            SnackbarUtil.showInfo(context, _getErrorMessage(e2));
          }
          return;
        }
      }

      SnackbarUtil.showInfo(context, errorMessage);
    }
  }

  bool _isForceableError(dynamic error, String message) {
    if (error is FirebaseFunctionsException &&
        (error.code == 'failed-precondition' ||
            error.code == 'resource-exhausted')) {
      return message.contains('세션 시작') ||
          message.contains('예약 가능한 인원이 없습니다') ||
          message.contains('아직 예약 오픈 전');
    }
    return false;
  }

  String _getErrorMessage(dynamic error) {
    // Firebase Functions 예외는 code로 1차 분기 (가장 정확함)
    if (error is FirebaseFunctionsException) {
      final code = error.code.toLowerCase();
      // 서버(createSessionReservation)에서 이미 예약된 세션이면 already-exists로 내려옴
      if (code == 'already-exists') {
        return '이미 예약된 세션입니다';
      }
      if (code == 'permission-denied' || code == 'unauthenticated') {
        return '예약 권한이 없습니다';
      }
      if (code == 'failed-precondition') {
        final msg = (error.message ?? '').trim();
        if (msg.isNotEmpty) return ErrorMessageUtil.toUserFriendlyMessage(msg);
      }
      final msg = (error.message ?? '').trim();
      if (msg.isNotEmpty) return ErrorMessageUtil.toUserFriendlyMessage(msg);
    }

    final friendly = ErrorMessageUtil.toUserFriendlyMessage(error.toString());
    return friendly == '오류가 발생했습니다. 잠시 후 다시 시도해주세요.'
        ? '예약 중 오류가 발생했습니다'
        : friendly;
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
                canPop: true,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.backgroundWhite,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(30),
                      topRight: Radius.circular(30),
                    ),
                  ),
                  padding: EdgeInsets.only(
                    left: 24,
                    right: 24,
                    top: 24,
                    bottom: 24 + MediaQuery.of(context).padding.bottom,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 예약 상세 정보
                      _buildSessionReservationDetails(context),

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
  Widget _buildSessionReservationDetails(BuildContext context) {
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
              onTap: () {
                if (_isSubmitting) return;
                Navigator.of(context).pop();
              },
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
    final enrollment =
        widget.course != null
            ? enrollmentProvider.enrollmentsByCourseId[widget.course!.id]
            : null;

    if (enrollment == null) {
      return const SizedBox.shrink();
    }

    final actualRemainingSessionReservations = enrollment.remainingReservations;

    // 유효기간 포맷팅
    String formatDate(DateTime date) {
      return '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';
    }

    // 예약 후 남은 횟수 계산
    final afterSessionReservationCount = (actualRemainingSessionReservations -
            1)
        .clamp(0, actualRemainingSessionReservations);

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
              '$actualRemainingSessionReservations회',
              style: TextStyle(
                fontSize: 44,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
                letterSpacing: -1,
              ),
            ),
            if (actualRemainingSessionReservations > 0) ...[
              const SizedBox(width: 12),
              Icon(
                Icons.arrow_forward_ios,
                size: 20,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 4),
              Text(
                '${afterSessionReservationCount}회',
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
    final canReserve =
        widget.remainingSessionReservations > 0 && !_isSubmitting;

    return Row(
      children: [
        // 취소 버튼
        Expanded(
          flex: 1,
          child: ElevatedButton(
            onPressed:
                _isSubmitting
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
              backgroundColor:
                  canReserve
                      ? AppColors.primaryGreen
                      : AppColors.textPrimary.withOpacity(0.1),
              foregroundColor:
                  canReserve ? Colors.white : AppColors.textSecondary,
              padding: const EdgeInsets.symmetric(vertical: 14),
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
                        valueColor: AlwaysStoppedAnimation<Color>(
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
    );
  }
}
