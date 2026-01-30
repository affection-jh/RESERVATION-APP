import 'package:flutter/material.dart';
import '../../../models/course.dart';
import '../../../models/reservation.dart';
import '../../../models/user.dart';
import '../../../theme/app_colors.dart';
import '../../../services/firestore_service.dart';
import '../../../services/user_service.dart';
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
  final Function(Set<String>)? onMovingStarted; // 이동 시작 시 예약 ID 목록 전달
  final Function(String)? onMovingCompleted; // 개별 예약 이동 완료 시
  final Function()? onAllMovingCompleted; // 모든 이동 완료 시

  const BulkMoveReservationsBottomSheet({
    super.key,
    required this.course,
    required this.sourceSession,
    required this.sourceDate,
    required this.reservations,
    this.user,
    this.onMoved,
    this.onCancelled,
    this.onMovingStarted,
    this.onMovingCompleted,
    this.onAllMovingCompleted,
  });

  @override
  State<BulkMoveReservationsBottomSheet> createState() =>
      _BulkMoveReservationsBottomSheetState();
}

class _BulkMoveReservationsBottomSheetState
    extends State<BulkMoveReservationsBottomSheet> {
  final FirestoreService _firestoreService = FirestoreService();
  final UserService _userService = UserService();
  CourseSession? _selectedTargetSession;
  DateTime? _selectedTargetDate;
  bool _isMoving = false;
  int _movedCount = 0;
  int _weekOffset = 0; // 0: 이번주, 1: 다음주, 2: 다다음주
  final List<int> _availableWeekOffsets = [0, 1, 2]; // 기본: 이번주, 다음주, 다다음주
  final TextEditingController _customWeekController = TextEditingController();
  bool _isUsingCustomWeek = false; // 커스텀 주차 사용 여부
  bool _isCustomWeekExpanded = false; // 커스텀 주차 입력 영역 펼침 여부

  // 예약자별 로딩 상태 및 사용자 정보
  Map<String, User> _userCache = {};
  Set<String> _loadingReservationIds = {}; // 이동 중인 예약 ID들
  bool _isMovingInBackground = false; // 백그라운드에서 이동 중인지
  bool _isLoadingWeek = false; // 주차 변경 중 로딩 상태

  bool get _isSingleReservation => widget.reservations.length == 1;

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  Future<void> _loadUserData() async {
    final userIds =
        widget.reservations
            .map((r) => r.userId)
            .where((id) => id.isNotEmpty && !_userCache.containsKey(id))
            .toSet()
            .toList();

    if (userIds.isEmpty) return;

    try {
      final users = await _userService.getUsersByIds(userIds);
      if (mounted) {
        setState(() {
          for (final user in users) {
            _userCache[user.userId] = user;
          }
        });
      }
    } catch (_) {
      // ignore
    }
  }

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
                  onPressed: () {
                    // 이동 중이면 백그라운드에서 계속 진행
                    if (_isMoving) {
                      _isMovingInBackground = true;
                      Navigator.of(context).pop();
                    } else {
                      Navigator.of(context).pop();
                    }
                  },
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
            selectedIndex:
                _isUsingCustomWeek
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
                  _isLoadingWeek = true; // 로딩 시작
                });
                // 로딩 해제 (데이터 로드 시간 고려)
                Future.delayed(const Duration(milliseconds: 500), () {
                  if (mounted) {
                    setState(() {
                      _isLoadingWeek = false;
                    });
                  }
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
                    if (_weekOffset != 0) {
                      _weekOffset = 0;
                      _isLoadingWeek = true; // 로딩 시작
                      // 로딩 해제 (데이터 로드 시간 고려)
                      Future.delayed(const Duration(milliseconds: 500), () {
                        if (mounted) {
                          setState(() {
                            _isLoadingWeek = false;
                          });
                        }
                      });
                    }
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
            child:
                _isCustomWeekExpanded
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
                                      contentPadding:
                                          const EdgeInsets.symmetric(
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
                                      _isLoadingWeek = true; // 로딩 시작
                                    });
                                    // 로딩 해제 (데이터 로드 시간 고려)
                                    Future.delayed(
                                      const Duration(milliseconds: 500),
                                      () {
                                        if (mounted) {
                                          setState(() {
                                            _isLoadingWeek = false;
                                          });
                                        }
                                      },
                                    );
                                  } else if (value.isEmpty) {
                                    setState(() {
                                      _isUsingCustomWeek = false;
                                      _weekOffset = 0;
                                      _selectedTargetSession = null;
                                      _selectedTargetDate = null;
                                      _isLoadingWeek = true; // 로딩 시작
                                    });
                                    // 로딩 해제 (데이터 로드 시간 고려)
                                    Future.delayed(
                                      const Duration(milliseconds: 500),
                                      () {
                                        if (mounted) {
                                          setState(() {
                                            _isLoadingWeek = false;
                                          });
                                        }
                                      },
                                    );
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
            child: Stack(
              children: [
                ClipRRect(
                  child: CompactCalendarWidget(
                    courses: [widget.course],
                    usage: CompactCalendarUsage.adminSelectNewSlot,
                    weekOffset: _weekOffset,
                    height: 400,
                    onSessionTap: (course, session, date) async {
                      // 정확히 같은 세션(요일+시간+날짜)으로는 이동 불가
                      if (session.dayOfWeek == widget.sourceSession.dayOfWeek &&
                          session.startTime == widget.sourceSession.startTime &&
                          date.year == widget.sourceDate.year &&
                          date.month == widget.sourceDate.month &&
                          date.day == widget.sourceDate.day) {
                        return;
                      }

                      // 지나간 세션인지 확인
                      final now = TimezoneUtils.getSeoulDateTime();
                      final sessionDateTime =
                          TimezoneUtils.combineDateAndTimeSeoul(
                            date,
                            session.startTime,
                          );
                      final isPastSession = sessionDateTime.isBefore(now);

                      if (isPastSession) {
                        SnackbarUtil.showError(
                          context,
                          '지나간 세션으로는 이동할 수 없습니다.',
                        );
                        return;
                      }

                      // 꽉 찬 세션인지 확인
                      final sessionReservation = await _firestoreService
                          .getSessionReservation(
                            courseId: course.id,
                            dayOfWeek: session.dayOfWeek,
                            startTime: session.startTime,
                            date: date,
                          );

                      final capacity =
                          sessionReservation?.capacity ??
                          session.getCapacityForDate(date);
                      final reservedCount =
                          sessionReservation?.reservedCount ?? 0;
                      final isFull = reservedCount >= capacity;

                      // 꽉 찬 세션인 경우 다이얼로그로 확인
                      if (isFull) {
                        final confirmed = await CommonDialog.show(
                          context: context,
                          title: '정원 마감',
                          message:
                              '정원이 마감된 세션입니다. 그래도 이동하시겠습니까?\n\n현재: $reservedCount / $capacity',
                          cancelText: '취소',
                          confirmText: '이동',
                          confirmButtonColor: Colors.red,
                        );

                        if (confirmed != true) {
                          return; // 취소하면 선택하지 않음
                        }
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
                    selectedSessionDayOfWeek: _selectedTargetSession?.dayOfWeek,
                    selectedSessionStartTime: _selectedTargetSession?.startTime,
                    selectedSessionDate: _selectedTargetDate,
                  ),
                ),
                // 주차 변경 로딩 오버레이
                if (_isLoadingWeek)
                  Container(
                    color: AppColors.backgroundLight.withOpacity(0.8),
                    child: const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primaryGreen,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            child:
                _selectedTargetSession != null && _selectedTargetDate != null
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
                  child:
                      _isMoving
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
                child:
                    _isMoving
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
    final weekDiff =
        (sessionWeekMonday.difference(thisWeekMonday).inDays / 7).round();
    final weekLabel = WeekRangeCalculator.getWeekLabel(weekDiff);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:
            isSource
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
                    color:
                        isSource
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

    // 취소 확인 다이얼로그 (바텀시트 닫기 전에 표시)
    final confirmed = await CommonDialog.show(
      context: context,
      title: _isSingleReservation ? '예약 변경' : '일괄 이동',
      message:
          _isSingleReservation
              ? '예약을 변경하시겠습니까?'
              : '${widget.reservations.length}명의 예약자를 선택한 세션으로 이동하시겠습니까?',
      cancelText: '취소',
      confirmText: _isSingleReservation ? '확인' : '이동',
      confirmButtonColor: AppColors.primaryGreen,
    );

    if (confirmed != true) return;

    // 이동 시작 알림 (SessionDetailScreen에 로딩 상태 전달)
    final reservationIds = widget.reservations.map((r) => r.id).toSet();
    if (mounted) {
      widget.onMovingStarted?.call(reservationIds);
      setState(() {
        _isMoving = true;
        _loadingReservationIds = reservationIds;
      });
    }

    // 백그라운드에서 이동 중이면 바텀시트를 닫지 않고 계속 진행
    if (_isMovingInBackground) {
      _performMove();
      return;
    }

    // 바텀시트는 열어두고 로딩 상태 표시
    try {
      await _performMove();
    } finally {
      // 완료되면 자동으로 바텀시트 닫기
      if (mounted && !_isMovingInBackground) {
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> _performMove() async {
    final ctx = navigatorKey.currentContext;
    if (ctx == null && !mounted) return;

    // Null check
    if (_selectedTargetSession == null || _selectedTargetDate == null) {
      if (mounted) {
        setState(() {
          _isMoving = false;
          _loadingReservationIds.clear();
        });
      }
      return;
    }

    try {
      // Null check (비동기 작업 중 상태 변경 가능)
      final targetSession = _selectedTargetSession;
      final targetDate = _selectedTargetDate;
      if (targetSession == null || targetDate == null) {
        if (mounted) {
          setState(() {
            _isMoving = false;
            _loadingReservationIds.clear();
          });
        }
        return;
      }

      // reservations가 비어있거나 placeId가 null인 경우 체크
      if (widget.reservations.isEmpty) {
        if (mounted) {
          setState(() {
            _isMoving = false;
            _loadingReservationIds.clear();
          });
        }
        final errorCtx = navigatorKey.currentContext;
        if (errorCtx != null && errorCtx.mounted) {
          SnackbarUtil.showError(errorCtx, '예약 정보를 찾을 수 없습니다.');
        }
        return;
      }

      final placeId = widget.reservations.first.placeId;
      if (placeId.isEmpty) {
        if (mounted) {
          setState(() {
            _isMoving = false;
            _loadingReservationIds.clear();
          });
        }
        final errorCtx = navigatorKey.currentContext;
        if (errorCtx != null && errorCtx.mounted) {
          SnackbarUtil.showError(errorCtx, '플레이스 정보를 찾을 수 없습니다.');
        }
        return;
      }

      // 개별/일괄 모두 batchMoveReservations 사용 (관리자 권한으로 정원 초과 이동 가능)
      final result = await _firestoreService.batchMoveReservations(
        reservationIds: widget.reservations.map((r) => r.id).toList(),
        placeId: placeId,
        newDayOfWeek: targetSession.dayOfWeek,
        newStartTime: targetSession.startTime,
        newReservedDate: targetDate,
      );

      final movedCount = result['movedCount'] as int? ?? 0;
      final results = result['results'] as List<dynamic>? ?? [];
      final failedCount =
          results.where((r) => (r as Map)['success'] != true).length;

      // 각 예약 완료 알림
      if (mounted) {
        for (final r in results) {
          final resultMap = r as Map;
          if (resultMap['success'] == true) {
            final reservationId = resultMap['reservationId'] as String?;
            if (reservationId != null) {
              widget.onMovingCompleted?.call(reservationId);
            }
          }
        }

        setState(() {
          _isMoving = false;
          _loadingReservationIds.clear();
        });

        widget.onAllMovingCompleted?.call();
      }

      // 결과 표시 (바텀시트가 닫혀있어도 스낵바는 표시)
      if (ctx != null && ctx.mounted) {
        if (failedCount == 0) {
          SnackbarUtil.showSuccess(
            ctx,
            _isSingleReservation
                ? '예약을 변경했습니다.'
                : '$movedCount명의 예약자가 이동되었습니다.',
          );
        } else {
          SnackbarUtil.showInfo(ctx, '$movedCount명 이동 완료, $failedCount명 이동 실패');
        }
      }

      if (mounted) {
        widget.onMoved?.call();
      }
    } catch (e) {
      // 에러 발생 시 모든 예약 ID의 로딩 상태 해제
      if (mounted) {
        final allReservationIds = widget.reservations.map((r) => r.id).toSet();
        for (final reservationId in allReservationIds) {
          widget.onMovingCompleted?.call(reservationId);
        }
        widget.onAllMovingCompleted?.call();

        setState(() {
          _isMoving = false;
          _loadingReservationIds.clear();
        });
      }

      // 에러 알림
      final errorCtx = navigatorKey.currentContext;
      if (errorCtx != null && errorCtx.mounted) {
        // 에러 메시지에서 "세션을 찾을 수 없습니다"를 더 명확하게 표시
        final errorMessage = e.toString();
        String userMessage;
        if (errorMessage.contains('세션을 찾을 수 없습니다') ||
            errorMessage.contains('not-found')) {
          userMessage = '선택한 세션을 찾을 수 없습니다. 다른 세션을 선택해주세요.';
        } else {
          userMessage =
              _isSingleReservation
                  ? '예약 변경 중 오류가 발생했습니다'
                  : '일괄 이동 중 오류가 발생했습니다';
        }
        debugPrint(e.toString());
        SnackbarUtil.showError(errorCtx, userMessage);
      }
    }
  }
}
