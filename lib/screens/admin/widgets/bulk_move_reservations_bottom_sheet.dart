import 'package:flutter/material.dart';
import '../../../models/course.dart';
import '../../../models/reservation.dart';
import '../../../models/user.dart';
import '../../../theme/app_colors.dart';
import '../../../services/firestore_service.dart';
import '../../../widgets/compact_calendar_widget.dart';
import '../../../utils/snackbar_util.dart';
import '../../../widgets/common_dialog.dart';
import '../../../widgets/week_tab_bar.dart';
import '../../../utils/week_range_calculator.dart';
import '../../../utils/timezone_utils.dart';
import '../../../utils/navigator_key.dart';
import '../../../utils/text_field_decoration_util.dart';

/// 예약 이동 바텀시트 (개별/일괄 공통)
class BulkMoveReservationsBottomSheet extends StatefulWidget {
  final Course course;
  final CourseSession sourceSession;
  final DateTime sourceDate;
  final List<Reservation> reservations;
  final User? user; // 개별 예약 시 예약자 정보
  final VoidCallback? onMoved;
  final VoidCallback? onCancelled; // 취소 콜백

  const BulkMoveReservationsBottomSheet({
    super.key,
    required this.course,
    required this.sourceSession,
    required this.sourceDate,
    required this.reservations,
    this.user,
    this.onMoved,
    this.onCancelled,
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
  int _weekOffset = 0; // 0: 이번주, 1: 다음주, 2: 다다음주
  final List<int> _availableWeekOffsets = [0, 1, 2]; // 기본: 이번주, 다음주, 다다음주
  final TextEditingController _customWeekController = TextEditingController();
  bool _isUsingCustomWeek = false; // 커스텀 주차 사용 여부
  bool _isCustomWeekExpanded = false; // 커스텀 주차 입력 영역 펼침 여부

  bool get _isSingleReservation => widget.reservations.length == 1;

  @override
  void dispose() {
    _customWeekController.dispose();
    super.dispose();
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
                    _isSingleReservation ? '예약 변경' : '예약자 일괄 이동',
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
                _buildSessionInfo(
                  widget.sourceSession,
                  widget.sourceDate,
                  isSource: true,
                ),
                const SizedBox(height: 30), // 이동할 세션 선택
                Text(
                  '이동할 세션 선택',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textSecondary.withOpacity(0.9),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          // 주차 선택 탭바 (기본 3주) + 화살표 토글 버튼
          WeekTabBar(
            selectedIndex: _isUsingCustomWeek
                ? -1
                : _availableWeekOffsets
                      .indexOf(_weekOffset)
                      .clamp(0, _availableWeekOffsets.length - 1),
            onTabChanged: (index) {
              if (index < _availableWeekOffsets.length) {
                setState(() {
                  _weekOffset = _availableWeekOffsets[index];
                  _isUsingCustomWeek = false;
                  _customWeekController.clear();
                  // 주차 변경 시 선택된 세션 초기화
                  _selectedTargetSession = null;
                  _selectedTargetDate = null;
                });
              }
            },
            availableWeekOffsets: _availableWeekOffsets,
            trailing: GestureDetector(
              onTap: () {
                setState(() {
                  if (_isCustomWeekExpanded) {
                    // 닫을 때 이번주로 돌리기
                    _isCustomWeekExpanded = false;
                    _weekOffset = 0;
                    _isUsingCustomWeek = false;
                    _customWeekController.clear();
                    _selectedTargetSession = null;
                    _selectedTargetDate = null;
                  } else {
                    // 열 때
                    _isCustomWeekExpanded = true;
                  }
                });
              },
              child: Icon(
                _isCustomWeekExpanded
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
                color: AppColors.textSecondary,
                size: 24,
              ),
            ),
          ),

          // 커스텀 주차 입력 필드 (토글 가능)
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            child: _isCustomWeekExpanded
                ? Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        children: [
                          SizedBox(width: 42),
                          Text(
                            '또는 ',
                            style: TextStyle(
                              fontSize: 16,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _customWeekController,
                              keyboardType: TextInputType.number,
                              decoration:
                                  TextFieldDecorationUtil.standardDecoration(
                                    hintText: '몇 주 후',
                                    borderRadius: 12,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                  ),
                              style: TextStyle(
                                fontSize: 16,
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                              onChanged: (value) {
                                final weekNum = int.tryParse(value);
                                if (weekNum != null) {
                                  setState(() {
                                    if (weekNum == 1) {
                                      // 1 입력 시 다음주로
                                      _weekOffset = 1;
                                      _isUsingCustomWeek = false;
                                    } else if (weekNum == 2) {
                                      // 2 입력 시 다다음주로
                                      _weekOffset = 2;
                                      _isUsingCustomWeek = false;
                                    } else if (weekNum >= 3) {
                                      // 3 이상은 커스텀 주차
                                      _weekOffset = weekNum;
                                      _isUsingCustomWeek = true;
                                    }
                                    // 주차 변경 시 선택된 세션 초기화
                                    _selectedTargetSession = null;
                                    _selectedTargetDate = null;
                                  });
                                } else if (value.isEmpty) {
                                  setState(() {
                                    _isUsingCustomWeek = false;
                                    _weekOffset = 0;
                                    _selectedTargetSession = null;
                                    _selectedTargetDate = null;
                                  });
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '주 후',
                            style: TextStyle(
                              fontSize: 16,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),

          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            height: 300,
            decoration: BoxDecoration(color: AppColors.backgroundLight),
            child: ClipRRect(
              child: CompactCalendarWidget(
                courses: [widget.course],
                usage: CompactCalendarUsage.adminSelectNewSlot,
                weekOffset: _weekOffset,
                height: 400,
                onSessionTap: (course, session, date) {
                  // 정확히 같은 세션(요일+시간+날짜)으로는 이동 불가
                  if (session.dayOfWeek == widget.sourceSession.dayOfWeek &&
                      session.startTime == widget.sourceSession.startTime &&
                      date.year == widget.sourceDate.year &&
                      date.month == widget.sourceDate.month &&
                      date.day == widget.sourceDate.day) {
                    return;
                  }
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
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            child: _selectedTargetSession != null && _selectedTargetDate != null
                ? Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: _buildSessionInfo(
                      _selectedTargetSession!,
                      _selectedTargetDate!,
                      isSource: false,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          const SizedBox(height: 12),
          // 액션 버튼들
          if (_isSingleReservation) ...[
            // 개별 예약: 변경 버튼만
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
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
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              AppColors.primaryGreen,
                            ),
                          ),
                        )
                      : Text(
                          _getMoveButtonText(),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
            ),
          ] else ...[
            // 일괄 이동 버튼
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
                                AppColors.primaryGreen,
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

    // 주차 정보 계산
    final now = TimezoneUtils.getSeoulToday();
    final daysFromMonday = now.weekday - 1;
    final thisWeekMonday = now.subtract(Duration(days: daysFromMonday));
    final sessionWeekMonday = date.subtract(Duration(days: date.weekday - 1));
    final weekDiff = (sessionWeekMonday.difference(thisWeekMonday).inDays / 7)
        .round();
    final weekLabel = WeekRangeCalculator.getWeekLabel(weekDiff);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isSource
            ? AppColors.backgroundLight
            : AppColors.primaryGreen.withOpacity(0.1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$dateStr ($weekday) ${session.startTime}~${session.endTime}',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: isSource
                        ? AppColors.textPrimary
                        : AppColors.primaryGreen,
                  ),
                ),
              ),
            ],
          ),
          if (!isSource) ...[
            const SizedBox(height: 2),
            Text(
              weekLabel,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _getMoveButtonText() {
    if (_selectedTargetSession == null || _selectedTargetDate == null) {
      return '예약 변경시키기';
    }
    final weekdays = ['월', '화', '수', '목', '금', '토', '일'];
    final weekday = weekdays[_selectedTargetDate!.weekday - 1];
    final month = _selectedTargetDate!.month.toString().padLeft(2, '0');
    final day = _selectedTargetDate!.day.toString().padLeft(2, '0');
    return '$month/$day ($weekday)으로 변경시키기';
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

    // 바텀시트를 먼저 닫기
    Navigator.of(context).pop();

    // 바텀시트가 닫힌 후 다이얼로그 표시
    await Future.delayed(const Duration(milliseconds: 300));

    if (!mounted) return;

    // 취소 확인 다이얼로그
    final confirmed = await CommonDialog.show(
      context: context,
      title: _isSingleReservation ? '예약 변경' : '일괄 이동',
      message: _isSingleReservation
          ? '예약을 변경하시겠습니까?'
          : '${widget.reservations.length}명의 예약자를 선택한 세션으로 이동하시겠습니까?',
      cancelText: '취소',
      confirmText: _isSingleReservation ? '확인' : '이동',
      confirmButtonColor: AppColors.primaryGreen,
    );

    if (confirmed != true) return;

    setState(() {
      _isMoving = true;
      _movedCount = 0;
    });

    try {
      // 개별/일괄 모두 batchMoveReservations 사용 (관리자 권한으로 정원 초과 이동 가능)
      final result = await _firestoreService.batchMoveReservations(
        reservationIds: widget.reservations.map((r) => r.id).toList(),
        placeId: widget.reservations.first.placeId,
        newDayOfWeek: _selectedTargetSession!.dayOfWeek,
        newStartTime: _selectedTargetSession!.startTime,
        newReservedDate: _selectedTargetDate!,
      );

      final movedCount = result['movedCount'] as int? ?? 0;
      final results = result['results'] as List<dynamic>? ?? [];
      final failedCount = results
          .where((r) => (r as Map)['success'] != true)
          .length;

      if (!mounted) return;

      // 결과 표시
      if (failedCount == 0) {
        SnackbarUtil.showSuccess(
          context,
          _isSingleReservation ? '예약이 변경되었습니다.' : '$movedCount명의 예약자가 이동되었습니다.',
        );
        widget.onMoved?.call();
      } else {
        SnackbarUtil.showError(
          context,
          '$movedCount명 이동 완료, $failedCount명 이동 실패',
        );
        // 일부라도 성공했으면 콜백 호출
        if (movedCount > 0) {
          widget.onMoved?.call();
        }
      }
    } catch (e) {
      final ctx = navigatorKey.currentContext;
      if (ctx != null) {
        SnackbarUtil.showError(
          ctx,
          _isSingleReservation
              ? '예약 변경 중 오류가 발생했습니다: $e'
              : '일괄 이동 중 오류가 발생했습니다: $e',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isMoving = false;
        });
      }
    }
  }
}
