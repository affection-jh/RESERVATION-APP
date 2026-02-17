import 'package:flutter/material.dart';
import '../../../models/course.dart';
import '../../../models/session_reservation.dart';
import '../../../models/member_view.dart';
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
  /// date가 속한 주의 weekOffset (0=이번주, 1=다음주, ...)
  static int weekOffsetFromDate(DateTime date) {
    final now = TimezoneUtils.getSeoulToday();
    final thisWeekMonday = now.subtract(
      Duration(days: now.weekday - DateTime.monday),
    );
    final sessionWeekMonday = date.subtract(
      Duration(days: date.weekday - DateTime.monday),
    );
    final weekDiff =
        (sessionWeekMonday.difference(thisWeekMonday).inDays / 7).round();
    return weekDiff.clamp(0, 9);
  }
  final Course course;
  final CourseSession sourceSession;
  final DateTime sourceDate;
  final List<SessionReservation> reservations;
  final MemberView? member; // 개별 예약 시 예약자 정보
  final VoidCallback? onMoved;
  final VoidCallback? onCancelled; // 취소 콜백
  final Function(Set<String>)? onMovingStarted; // 이동 시작 시 예약 ID 목록 전달
  final Function(String)? onMovingCompleted; // 개별 예약 이동 완료 시
  final Function()? onAllMovingCompleted; // 모든 이동 완료 시
  /// 스낵바를 붙일 context (화면 쪽 context 권장, null이면 navigatorKey.currentContext 사용)
  final BuildContext? snackbarContext;
  /// 진입 시 선택할 주차 오프셋 (sourceDate가 속한 주. null이면 0=이번주)
  final int? initialWeekOffset;

  const BulkMoveReservationsBottomSheet({
    super.key,
    required this.course,
    required this.sourceSession,
    required this.sourceDate,
    required this.reservations,
    this.member,
    this.onMoved,
    this.onCancelled,
    this.onMovingStarted,
    this.onMovingCompleted,
    this.onAllMovingCompleted,
    this.snackbarContext,
    this.initialWeekOffset,
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

  late int _weekOffset;
  late List<int> _availableWeekOffsets;
  final TextEditingController _customWeekController = TextEditingController();
  bool _isUsingCustomWeek = false; // 커스텀 주차 사용 여부
  bool _isCustomWeekExpanded = false; // 커스텀 주차 입력 영역 펼침 여부

  // 예약자별 로딩 상태 및 사용자 정보
  Map<String, User> _userCache = {};
  Set<String> _loadingReservationIds = {}; // 이동 중인 예약 ID들
  bool _isMovingInBackground = false; // 백그라운드에서 이동 중인지
  bool get _isSingleReservation => widget.reservations.length == 1;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialWeekOffset ?? 0;
    _weekOffset = initial.clamp(0, 9);
    final maxOffset = _weekOffset > 2 ? _weekOffset : 2;
    _availableWeekOffsets = List.generate(maxOffset + 1, (i) => i);
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
    final maxHeight = MediaQuery.sizeOf(context).height * 0.88;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
      ),
      padding: EdgeInsets.only(
        left: 0,
        right: 0,
        top: 32,
        bottom: 32 + MediaQuery.of(context).padding.bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 12),

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
                height: 500,
                decoration: BoxDecoration(color: AppColors.backgroundWhite),
                child: Stack(
                  children: [
                    ClipRRect(
                      child: CompactCalendarWidget(
                        courses: [widget.course],
                        usage: CompactCalendarUsage.adminSelectNewSlot,
                        weekOffset: _weekOffset,
                        availableWeekOffsets: _availableWeekOffsets,
                        height: 500,
                        onSwipeToPrevWeek:
                            _availableWeekOffsets.length > 1
                                ? () {
                                  final i = _availableWeekOffsets
                                      .indexOf(_weekOffset)
                                      .clamp(
                                        0,
                                        _availableWeekOffsets.length - 1,
                                      );
                                  if (i > 0) {
                                    setState(() {
                                      _weekOffset =
                                          _availableWeekOffsets[i - 1];
                                      _selectedTargetSession = null;
                                      _selectedTargetDate = null;
                                    });
                                  }
                                }
                                : null,
                        onSwipeToNextWeek:
                            _availableWeekOffsets.length > 1
                                ? () {
                                  final i = _availableWeekOffsets
                                      .indexOf(_weekOffset)
                                      .clamp(
                                        0,
                                        _availableWeekOffsets.length - 1,
                                      );
                                  if (i < _availableWeekOffsets.length - 1) {
                                    setState(() {
                                      _weekOffset =
                                          _availableWeekOffsets[i + 1];
                                      _selectedTargetSession = null;
                                      _selectedTargetDate = null;
                                    });
                                  }
                                }
                                : null,
                        onSessionTap: (course, session, date) async {
                          // 정확히 같은 세션(요일+시간+날짜)으로는 이동 불가
                          if (session.dayOfWeek ==
                                  widget.sourceSession.dayOfWeek &&
                              session.startTime ==
                                  widget.sourceSession.startTime &&
                              date.year == widget.sourceDate.year &&
                              date.month == widget.sourceDate.month &&
                              date.day == widget.sourceDate.day) {
                            return false;
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
                            SnackbarUtil.showInfo(
                              widget.snackbarContext ?? context,
                              '지나간 세션으로는 이동할 수 없습니다.',
                            );
                            return false;
                          }

                          // 관리자 이동: 정원 마감 여부와 관계없이 선택 허용 (다이얼로그 없음)
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
                          return true;
                        },
                        hideCourseSelector: true,
                        adminSelectionMode: true,
                        currentReservationDayOfWeek:
                            widget.sourceSession.dayOfWeek,
                        currentReservationStartTime:
                            widget.sourceSession.startTime,
                        currentReservationDate: widget.sourceDate,
                        selectedSessionDayOfWeek:
                            _selectedTargetSession?.dayOfWeek,
                        selectedSessionStartTime:
                            _selectedTargetSession?.startTime,
                        selectedSessionDate: _selectedTargetDate,
                      ),
                    ),
                  ],
                ),
              ),

              AnimatedSize(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                child:
                    _selectedTargetSession != null &&
                            _selectedTargetDate != null
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
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
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
                ),
              ],
            ],
          ),
        ),
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
        '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';

    // 주차 정보 계산
    final now = TimezoneUtils.getSeoulToday();
    final daysFromMonday = now.weekday - 1;
    final thisWeekMonday = now.subtract(Duration(days: daysFromMonday));
    final sessionWeekMonday = date.subtract(Duration(days: date.weekday - 1));
    final weekDiff =
        (sessionWeekMonday.difference(thisWeekMonday).inDays / 7).round();
    final weekLabel = WeekRangeCalculator.getWeekLabel(weekDiff);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(color: AppColors.backgroundWhite),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 24),
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
              ),
            ],
          ),
          if (!isSource) ...[
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.only(left: 24),
              child: Text(
                weekLabel,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondary,
                ),
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
      SnackbarUtil.showInfo(
        widget.snackbarContext ?? context,
        '같은 세션으로는 이동할 수 없습니다.',
      );
      return;
    }

    // 취소 확인 다이얼로그 (바텀시트 닫기 전에 표시)
    final confirmed = await CommonDialog.show(
      context: context,
      title: _isSingleReservation ? '예약 변경' : '일괄 이동',
      message:
          _isSingleReservation
              ? '예약을 변경하시겠습니까?'
              : '${widget.reservations.length}명의 예약자를\n선택한 세션으로 이동하시겠습니까?',
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
    // 스낵바는 바텀시트가 아닌 화면 context에 붙임 (닫힌 뒤에도 안정적)
    final ctx = widget.snackbarContext ?? navigatorKey.currentContext;
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

    // 이동이 서버에서 성공한 뒤 UI/콜백에서 예외가 나도 실패 스낵바를 띄우지 않도록 구분
    bool moveSucceeded = false;

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
        final errorCtx = widget.snackbarContext ?? navigatorKey.currentContext;
        if (errorCtx != null && errorCtx.mounted) {
          SnackbarUtil.showInfo(errorCtx, '예약 정보를 찾을 수 없습니다.');
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
        final errorCtx = widget.snackbarContext ?? navigatorKey.currentContext;
        if (errorCtx != null && errorCtx.mounted) {
          SnackbarUtil.showInfo(errorCtx, '플레이스 정보를 찾을 수 없습니다.');
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

      // 서버에서 정상 응답을 받은 시점에 성공으로 간주 (이후 UI 예외는 실패 스낵바 미표시)
      moveSucceeded = true;

      final movedCount =
          result['movedCount'] is int
              ? result['movedCount'] as int
              : (int.tryParse(result['movedCount']?.toString() ?? '') ?? 0);
      final resultsRaw = result['results'];
      final results =
          resultsRaw is List ? List<dynamic>.from(resultsRaw) : <dynamic>[];
      final failedResults =
          results.where((r) => r is Map && (r['success'] != true)).toList();
      final failedCount = failedResults.length;
      final firstError =
          failedResults.isNotEmpty && failedResults.first is Map
              ? (failedResults.first as Map)['error'] as String? ?? ''
              : '';
      if (failedCount > 0) {
        for (final r in failedResults) {
          if (r is Map) {
            debugPrint(
              '[BulkMove] 실패: reservationId=${r['reservationId']} error=${r['error']}',
            );
          }
        }
      }

      // 이후 UI/콜백에서 null 등 예외가 나도 이동 성공은 유지 (방어 코드)
      try {
        // 이동 성공 스낵바를 먼저 표시 (바텀시트 닫힌 뒤에는 context 무효화될 수 있음)
        final snackbarCtx =
            ctx?.mounted == true
                ? ctx
                : (widget.snackbarContext ?? navigatorKey.currentContext);
        if (snackbarCtx != null && snackbarCtx.mounted) {
          if (failedCount == 0) {
            SnackbarUtil.showSuccess(
              snackbarCtx,
              _isSingleReservation
                  ? '예약을 변경했습니다.'
                  : '$movedCount명의 예약자가 이동되었습니다.',
            );
          } else {
            final message =
                firstError.isNotEmpty
                    ? '$movedCount명 성공 $failedCount명 실패.\n$firstError'
                    : '$movedCount명 성공, $failedCount명 실패';
            SnackbarUtil.showInfo(snackbarCtx, message);
          }
        }

        if (mounted) {
          for (final r in results) {
            if (r is! Map) continue;
            if (r['success'] == true) {
              final reservationId = r['reservationId'] as String?;
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

        if (mounted) {
          widget.onMoved?.call();
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _isMoving = false;
            _loadingReservationIds.clear();
          });
        }
        debugPrint('[BulkMove] 예약 이동은 성공했으나 이후 처리 중 오류: $e');
      }
    } catch (e) {
      // 에러 발생 시 로딩 상태 해제
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

      // 실제 이동이 실패했을 때만 실패 스낵바 표시 (이동 성공 후 UI/콜백 예외는 제외)
      if (moveSucceeded) {
        debugPrint('[BulkMove] 예약 이동은 성공했으나 이후 처리 중 오류: $e');
        return;
      }

      final errorCtx = widget.snackbarContext ?? navigatorKey.currentContext;
      if (errorCtx != null && errorCtx.mounted) {
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
        SnackbarUtil.showInfo(errorCtx, userMessage);
      }
    }
  }
}
