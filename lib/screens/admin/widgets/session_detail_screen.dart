import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:provider/provider.dart';
import '../../../models/course.dart';
import '../../../models/member_view.dart';
import '../../../models/place_member.dart';
import '../../../models/session_reservation.dart';
import '../../../models/session_reservation_summary.dart';
import '../../../models/course_override.dart';
import '../../../models/course_enrollment.dart';
import '../../../theme/app_colors.dart';
import '../../../services/firestore_service.dart';
import '../../../widgets/common_dialog.dart';
import '../../../providers/reservation_provider.dart';
import '../../../providers/member_provider.dart';
import 'bulk_move_reservations_bottom_sheet.dart';
import 'member_selection_side_panel.dart';
import '../../../services/reservation_service.dart';
import '../../../utils/snackbar_util.dart';
import '../../../utils/navigator_key.dart';
import '../../../utils/timezone_utils.dart';
import '../../../utils/format_utils.dart';
import '../../../utils/firestore_utils.dart';
import '../../../widgets/session_manage_bottom_sheet.dart';
import '../../../providers/course_provider.dart';
import '../../../providers/reservation_summary_provider.dart';
import 'enrollment_detail_screen.dart';
import 'dart:async';

/// 세션 상세보기 화면
class SessionDetailScreen extends StatefulWidget {
  final Course course;
  final CourseSession session;
  final DateTime date;
  final String placeId;

  const SessionDetailScreen({
    super.key,
    required this.course,
    required this.session,
    required this.date,
    required this.placeId,
  });

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  Set<String> _loadingUserIds = {}; // 개별 멤버 로딩 상태 추적
  Set<String> _movingReservationIds = {}; // 이동 중인 예약 ID들
  Set<String> _cancellingReservationIds = {}; // 취소 중인 예약 ID들 (로컬 상태)
  Map<String, bool> _copiedPhones = {}; // 전화번호 복사 상태 관리
  List<SessionReservation> _dateReservations = [];
  StreamSubscription<List<SessionReservation>>? _reservationsSub;
  StreamSubscription<ReservationOperationEvent>?
  _operationEventsSub; // 예약 작업 이벤트 구독
  Set<String> _selectedReservationIds = {}; // 일괄 액션용 선택 예약 ID
  bool _isBulkCancelling = false; // 일괄 취소 진행 중
  /// 비정기/정기 세션 삭제·취소 진행 중 — 이때 뒤로가기 막아 이중 pop 방지
  bool _isDeletingSession = false;
  bool _leaveRequested = false;

  @override
  void initState() {
    super.initState();
    // setPlaceId는 notifyListeners()를 호출하므로 빌드 중 호출 시 setState during build 오류 발생.
    // 첫 프레임 이후에 실행하도록 지연.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Provider.of<MemberProvider>(
        context,
        listen: false,
      ).setPlaceId(widget.placeId);
    });
    _listenReservations();
    _listenReservationOperationEvents();
  }

  @override
  void dispose() {
    _reservationsSub?.cancel();
    _operationEventsSub?.cancel();
    super.dispose();
  }

  /// 예약 작업 이벤트 구독 (취소/이동 등)
  void _listenReservationOperationEvents() {
    final reservationProvider = Provider.of<ReservationProvider>(
      context,
      listen: false,
    );
    _operationEventsSub?.cancel();
    _operationEventsSub = reservationProvider.operationEvents.listen((event) {
      if (!mounted) return;

      // 취소 작업 이벤트 처리
      if (event.type == ReservationOperationType.cancel &&
          event.reservation != null) {
        final reservationId = event.reservation!.id;
        if (event.success) {
          // 취소 성공: 로딩 상태 제거
          setState(() {
            _cancellingReservationIds.remove(reservationId);
          });
        } else {
          // 취소 실패: 로딩 상태 제거
          setState(() {
            _cancellingReservationIds.remove(reservationId);
          });
        }
      }
    });
  }

  void _listenReservations() {
    _reservationsSub?.cancel();
    _reservationsSub = _firestoreService
        .watchSessionReservations(
          placeId: widget.placeId,
          courseId: widget.course.id,
          dayOfWeek: widget.session.dayOfWeek,
          startTime: widget.session.startTime,
          date: widget.date,
        )
        .listen((reservations) {
          if (!mounted) return;
          final sorted = List<SessionReservation>.from(reservations)
            ..sort((a, b) => a.reservedAt.compareTo(b.reservedAt));
          setState(() {
            _dateReservations = sorted;
          });
          final userIds =
              sorted.map((r) => r.userId).where((id) => id.isNotEmpty).toList();
          if (userIds.isNotEmpty) {
            Provider.of<MemberProvider>(
              context,
              listen: false,
            ).ensureMembersForUserIds(userIds);
          }
        });
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  void _refreshReservations() {
    // watchSessionReservations가 최신 상태를 반영하므로 별도 처리 불필요
  }

  @override
  Widget build(BuildContext context) {
    final dateKey = _formatDate(widget.date);
    final sessionId = SessionReservationSummary.generateSessionId(
      widget.course.id,
      widget.session.dayOfWeek,
      widget.session.startTime,
    );
    context.watch<MemberProvider>(); // 멤버 로드 시 리빌드 → 이름/전화번호 즉시 반영
    final srProvider = context.watch<ReservationSummaryProvider>();
    final sr = srProvider.getSessionReservationSummary(sessionId, dateKey);
    final totalCapacity = srProvider.getTotalCapacity(
      sessionId,
      dateKey,
      fallback: widget.session.capacity,
    );
    final dateReservations = _dateReservations;
    final reservedCount = sr?.reservedCount ?? _dateReservations.length;
    final isPastSession = _isPastSession();

    return PopScope(
      canPop: !_isDeletingSession,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;
        if (_isDeletingSession) await _handleBackDuringDelete();
      },
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: AppColors.backgroundWhite,
        appBar: _buildAppBar(),
        body: Stack(
          children: [
            SafeArea(
              child: Column(
                children: [
                  // 날짜/요일/시간 칩 섹션
                  _buildChipSection(),

                  // 예약 상세 정보 (게이지)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 0,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: _buildInfoItem(
                                label: '수용 인원',
                                value: '$totalCapacity명',
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _buildInfoItem(
                                label: '예약 현황',
                                value: '$reservedCount명 / $totalCapacity명',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // 예약자 명단
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      color: AppColors.backgroundWhite,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 16),
                          Expanded(
                            child:
                                dateReservations.isEmpty
                                    ? Center(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Text(
                                            '예약자가 없어요',
                                            style: TextStyle(
                                              fontSize: 16,
                                              color: AppColors.textSecondary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                    : ListView.builder(
                                      padding: EdgeInsets.only(
                                        left: 18,
                                        right: 18,
                                        bottom:
                                            (_selectedReservationIds
                                                        .isNotEmpty &&
                                                    !isPastSession &&
                                                    !_isBulkCancelling &&
                                                    _movingReservationIds
                                                        .isEmpty &&
                                                    _loadingUserIds.isEmpty)
                                                ? 90
                                                : 0,
                                      ),
                                      itemCount: dateReservations.length,

                                      itemBuilder: (context, index) {
                                        final reservation =
                                            dateReservations[index];
                                        return Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 4,
                                          ),
                                          child: _buildReservistItem(
                                            index: index + 1,
                                            reservation: reservation,
                                            isPastSession: isPastSession,
                                            isSelected: _selectedReservationIds
                                                .contains(reservation.id),
                                            onCheckboxTap:
                                                () =>
                                                    _toggleReservationSelection(
                                                      reservation.id,
                                                    ),
                                          ),
                                        );
                                      },
                                    ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_selectedReservationIds.isNotEmpty &&
                !isPastSession &&
                !_isBulkCancelling &&
                _movingReservationIds.isEmpty &&
                _loadingUserIds.isEmpty)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildBulkActionBar(),
              ),
          ],
        ),
      ),
    );
  }

  bool _isPastSession() {
    final now = TimezoneUtils.getSeoulDateTime();
    final sessionStartTime = widget.session.startTime.split(':');
    final sessionHour = int.parse(sessionStartTime[0]);
    final sessionMinute =
        (sessionStartTime.length > 1) ? int.parse(sessionStartTime[1]) : 0;
    final sessionDateTime = DateTime(
      widget.date.year,
      widget.date.month,
      widget.date.day,
      sessionHour,
      sessionMinute,
    );
    return sessionDateTime.isBefore(now);
  }

  void _toggleReservationSelection(String reservationId) {
    setState(() {
      if (_selectedReservationIds.contains(reservationId)) {
        _selectedReservationIds.remove(reservationId);
      } else {
        _selectedReservationIds.add(reservationId);
      }
    });
  }

  Widget _buildBulkActionBar() {
    final count = _selectedReservationIds.length;
    return Container(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 12,
        bottom: MediaQuery.of(context).padding.bottom - 10,
      ),
      decoration: BoxDecoration(color: AppColors.backgroundWhite),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              flex: 2,
              child: OutlinedButton(
                onPressed: _isBulkCancelling ? null : () => _handleBulkCancel(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  backgroundColor: Colors.transparent,
                  side: BorderSide(
                    color: Colors.red.withOpacity(0.8),
                    width: 1.5,
                  ),
                  padding: const EdgeInsets.symmetric(
                    vertical: 14,
                    horizontal: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child:
                    _isBulkCancelling
                        ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : Text(
                          ' 예약 취소 ($count) ',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              child: ElevatedButton(
                onPressed: _isBulkCancelling ? null : () => _handleBulkMove(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.textPrimary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppColors.borderLight,
                  disabledForegroundColor: AppColors.textSecondary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(
                  '예약 변경 ($count)',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleBulkCancel() async {
    if (_selectedReservationIds.isEmpty) return;
    final ids = _selectedReservationIds.toList();
    final confirmed = await CommonDialog.show(
      context: context,
      title: '일괄 예약 취소',
      message: '선택한 ${ids.length}명의 예약을 취소하시겠습니까?',
      cancelText: '취소',
      confirmText: '확인',
      confirmButtonColor: Colors.red,
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _isBulkCancelling = true;
      _cancellingReservationIds.addAll(ids);
    });

    try {
      final result = await _firestoreService.batchCancelReservations(
        reservationIds: ids,
        placeId: widget.placeId,
        asAdminAction: true,
      );
      ReservationService.throwIfBatchCancelFailed(result);
      if (mounted) {
        setState(() {
          _selectedReservationIds.clear();
        });
        final sessionId = SessionReservationSummary.generateSessionId(
          widget.course.id,
          widget.session.dayOfWeek,
          widget.session.startTime,
        );
        final dateKey = _formatDate(widget.date);
        Provider.of<ReservationSummaryProvider>(
          context,
          listen: false,
        ).applyOptimisticReservedCountChange(sessionId, dateKey, -ids.length);
        SnackbarUtil.showSuccess(context, '${ids.length}명의 예약이 취소되었습니다.');
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        SnackbarUtil.showInfoFromError(context, e, fallback: '예약 취소에 실패했습니다.');
      }
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showInfo(context, '예약 취소 중 오류가 발생했습니다.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isBulkCancelling = false;
          for (final id in ids) {
            _cancellingReservationIds.remove(id);
          }
        });
      }
    }
  }

  void _handleBulkMove() {
    if (_selectedReservationIds.isEmpty) return;
    final selected =
        _dateReservations
            .where((r) => _selectedReservationIds.contains(r.id))
            .toList();
    if (selected.isEmpty) return;

    final initialWeekOffset =
        BulkMoveReservationsBottomSheet.weekOffsetFromDate(widget.date);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.7),
      isDismissible: true,
      enableDrag: true,
      useSafeArea: true,
      builder:
          (sheetContext) => BulkMoveReservationsBottomSheet(
            course: widget.course,
            sourceSession: widget.session,
            sourceDate: widget.date,
            reservations: selected,
            initialWeekOffset: initialWeekOffset,
            snackbarContext: context,
            onMoved: () {
              if (mounted) {
                setState(() => _selectedReservationIds.clear());
              }
              // bulk 시트는 자체적으로 닫으므로 여기서 pop 호출 금지
            },
            onMovingStarted: _handleMovingStarted,
            onMovingCompleted: _handleMovingCompleted,
            onAllMovingCompleted: _handleAllMovingCompleted,
          ),
    ).whenComplete(() {
      if (mounted) {
        setState(() => _selectedReservationIds.clear());
      }
    });
  }

  PreferredSizeWidget _buildAppBar() {
    final dateKey = _formatDate(widget.date);
    final sessionId = SessionReservationSummary.generateSessionId(
      widget.course.id,
      widget.session.dayOfWeek,
      widget.session.startTime,
    );
    final srProvider = Provider.of<ReservationSummaryProvider>(
      context,
      listen: false,
    );
    final sr = srProvider.getSessionReservationSummary(sessionId, dateKey);
    final totalCapacity = srProvider.getTotalCapacity(
      sessionId,
      dateKey,
      fallback: widget.session.capacity,
    );
    final reservedCount = sr?.reservedCount ?? _dateReservations.length;

    // 지나간 일정인지 확인 (세션 시작 시간까지 고려)
    final now = TimezoneUtils.getSeoulDateTime();
    final sessionStartTime = widget.session.startTime.split(':');
    final sessionHour = int.parse(sessionStartTime[0]);
    final sessionMinute = int.parse(sessionStartTime[1]);
    final sessionDateTime = DateTime(
      widget.date.year,
      widget.date.month,
      widget.date.day,
      sessionHour,
      sessionMinute,
    );
    final isPastSession = sessionDateTime.isBefore(now);

    return AppBar(
      scrolledUnderElevation: 0,
      backgroundColor: AppColors.backgroundWhite,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios, color: AppColors.primaryGreen),
        onPressed: () async {
          if (_isDeletingSession) {
            await _handleBackDuringDelete();
          } else {
            Navigator.of(context).pop();
          }
        },
      ),
      title: Text(
        widget.course.name,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: AppColors.textPrimary,
        ),
      ),
      actions: [
        // 예약자 추가 버튼 (지나간 일정이 아닐 때만 표시)
        if (!isPastSession)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: OutlinedButton(
              onPressed: () {
                // 남은 횟수 등이 MemberProvider.enrollments와 맞도록 미리 context 설정
                final memberProvider = Provider.of<MemberProvider>(
                  context,
                  listen: false,
                );
                memberProvider.setPlaceId(widget.placeId);
                memberProvider.setSelectedCourseId(widget.course.id);
                memberProvider.setShowPending(true);
                MemberSelectionSidePanel.showForReservation(
                  context: context,
                  placeId: widget.placeId,
                  course: widget.course,
                  totalCapacity: totalCapacity,
                  reservedCount: reservedCount,
                  existingReservationUserIds:
                      _dateReservations.map((r) => r.userId).toList(),
                  onMembersSelected: (members) async {
                    await _addReservationsForUsers(members);
                  },
                );
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textPrimary,
                side: BorderSide(
                  color: AppColors.textSecondary.withOpacity(0.3),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                '예약 추가',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ),

        if (!isPastSession)
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: OutlinedButton(
              onPressed: () => _showSessionManageBottomSheet(),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textPrimary,
                side: BorderSide(
                  color: AppColors.textSecondary.withOpacity(0.3),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                '편집',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildChipSection() {
    final dateText = '${widget.date.month}월 ${widget.date.day}일';
    final dayName = widget.session.dayName;
    final timeRange = '${widget.session.startTime} - ${widget.session.endTime}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildWhiteChip('$dateText $dayName요일'),
          const SizedBox(width: 8),
          _buildWhiteChip(timeRange),
        ],
      ),
    );
  }

  Widget _buildWhiteChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.backgroundLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildInfoItem({required String label, required String value}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      decoration: BoxDecoration(
        color: AppColors.backgroundLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 15, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppColors.primaryGreen,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReservistItem({
    required int index,
    required SessionReservation reservation,
    required bool isPastSession,
    required bool isSelected,
    required VoidCallback onCheckboxTap,
  }) {
    final memberProvider = Provider.of<MemberProvider>(context, listen: false);
    final memberView = memberProvider.getMemberView(reservation.userId);
    final enrollment =
        (reservation.enrollmentId.isNotEmpty
            ? memberProvider.getEnrollmentById(reservation.enrollmentId)
            : null) ??
        memberProvider.getEnrollmentForUserAndCourse(
          reservation.userId,
          widget.course.id,
        );
    final isMemberLoading =
        memberView == null &&
        memberProvider.isMemberLoadInFlight(reservation.userId);
    final userName =
        (memberView != null && memberView.adminDisplayName.trim().isNotEmpty)
            ? memberView.adminDisplayName.trim()
            : (enrollment != null &&
                enrollment.adminDisplayName.trim().isNotEmpty)
            ? enrollment.adminDisplayName.trim()
            : isMemberLoading
            ? '불러오는 중...'
            : '예약자 $index';
    final phoneNumber = memberView?.phoneNumber.trim() ?? '';
    final isLoading = _loadingUserIds.contains(reservation.userId);
    final isMoving = _movingReservationIds.contains(reservation.id);

    // 예약 취소 중인지 확인 (로컬 상태 사용)
    final isCancelling = _cancellingReservationIds.contains(reservation.id);

    return InkWell(
      onTap: () => _openEnrollmentDetailFor(reservation),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.backgroundLight,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.only(
          left: 20,
          right: 12,
          top: 18,
          bottom: 18,
        ),
        child: Row(
          children: [
            // 예약자 정보
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          userName,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color:
                                (isLoading ||
                                        isMoving ||
                                        isCancelling ||
                                        isMemberLoading)
                                    ? AppColors.textSecondary
                                    : AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),

                  if (phoneNumber.isNotEmpty)
                    Row(
                      children: [
                        Text(
                          FormatUtils.formatPhoneNumber(phoneNumber),
                          style: TextStyle(
                            fontSize: 16,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (!isLoading && !isCancelling)
                          GestureDetector(
                            onTap: () {
                              Clipboard.setData(
                                ClipboardData(text: phoneNumber),
                              );
                              setState(() {
                                _copiedPhones[reservation.id] = true;
                              });
                              SnackbarUtil.showSuccess(
                                context,
                                '클립보드에 복사되었습니다',
                              );
                              Future.delayed(const Duration(seconds: 2), () {
                                if (mounted) {
                                  setState(() {
                                    _copiedPhones[reservation.id] = false;
                                  });
                                }
                              });
                            },
                            child: Icon(
                              _copiedPhones[reservation.id] == true
                                  ? Icons.check
                                  : Icons.copy_all,
                              size: 18,
                              color:
                                  _copiedPhones[reservation.id] == true
                                      ? AppColors.primaryGreen
                                      : AppColors.textSecondary,
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
            if (isLoading || isMoving || isCancelling)
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    AppColors.primaryGreen,
                  ),
                ),
              )
            else if (!isPastSession &&
                !_isBulkCancelling &&
                _movingReservationIds.isEmpty &&
                _loadingUserIds.isEmpty)
              GestureDetector(
                onTap: () => onCheckboxTap(),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Center(
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color:
                                isSelected
                                    ? AppColors.primaryGreen
                                    : AppColors.textSecondary.withOpacity(0.6),
                            width: 2,
                          ),
                          color:
                              isSelected
                                  ? AppColors.primaryGreen
                                  : Colors.transparent,
                        ),
                        child:
                            isSelected
                                ? Icon(
                                  Icons.check,
                                  size: 16,
                                  color: Colors.white,
                                )
                                : null,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 멤버 카드 탭 시 해당 멤버의 이 코스 등록(enrollment) 상세 화면으로 이동
  Future<void> _openEnrollmentDetailFor(SessionReservation reservation) async {
    final memberProvider = Provider.of<MemberProvider>(context, listen: false);
    await memberProvider.ensureMembersForUserIds([reservation.userId]);
    if (!mounted) return;

    CourseEnrollment? enrollment;
    if (reservation.enrollmentId.isNotEmpty) {
      enrollment = await memberProvider.ensureEnrollmentById(
        reservation.enrollmentId,
      );
    }
    enrollment ??= memberProvider.getEnrollmentForUserAndCourse(
      reservation.userId,
      widget.course.id,
    );
    if (enrollment == null) {
      SnackbarUtil.showInfo(context, '이 코스에 등록되지 않은 멤버입니다.');
      return;
    }

    final memberView = memberProvider.getMemberView(reservation.userId);
    final targetMember = (memberView ??
            MemberView(
              userId: reservation.userId,
              adminDisplayName:
                  enrollment.adminDisplayName.trim().isNotEmpty
                      ? enrollment.adminDisplayName.trim()
                      : '이름 없음',
              phoneNumber: '',
              role: PlaceMemberRole.member,
            ))
        .copyWith(enrollment: enrollment);

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (context) => EnrollmentDetailScreen(
              member: targetMember,
              enrollment: enrollment!,
              course: widget.course,
            ),
      ),
    );
  }

  void _handleMovingStarted(Set<String> reservationIds) {
    if (!mounted) return;
    setState(() {
      _movingReservationIds.addAll(reservationIds);
    });
  }

  void _handleMovingCompleted(String reservationId) {
    if (!mounted) return;
    setState(() {
      _movingReservationIds.remove(reservationId);
    });
  }

  void _handleAllMovingCompleted() {
    if (!mounted) return;
    setState(() {
      _movingReservationIds.clear();
    });
    _refreshReservations();
  }

  List<MemberView> _uniqueMembersByUserId(List<MemberView> members) {
    final seen = <String>{};
    final out = <MemberView>[];
    for (final m in members) {
      if (m.userId.isEmpty || seen.contains(m.userId)) continue;
      seen.add(m.userId);
      out.add(m);
    }
    return out;
  }

  Future<void> _addReservationsForUsers(List<MemberView> members) async {
    if (members.isEmpty) return;

    final uniqueMembers = _uniqueMembersByUserId(members);
    final existingUserIds = _dateReservations.map((r) => r.userId).toSet();
    final toAdd =
        uniqueMembers
            .where((m) => !existingUserIds.contains(m.userId))
            .toList();
    final skipped = uniqueMembers.length - toAdd.length;
    if (skipped > 0 && mounted) {
      SnackbarUtil.showInfo(context, '이미 이 세션에 예약된 멤버 $skipped명은 제외했습니다.');
    }
    if (toAdd.isEmpty) return;

    final tempReservationIds = <String>[];
    setState(() {
      for (final member in toAdd) {
        _loadingUserIds.add(member.userId);
        final temp = SessionReservation(
          id: 'temp_${member.userId}_${DateTime.now().millisecondsSinceEpoch}',
          userId: member.userId,
          courseId: widget.course.id,
          placeId: widget.placeId,
          dayOfWeek: widget.session.dayOfWeek,
          startTime: widget.session.startTime,
          reservedAt: DateTime.now(),
          reservedDate: widget.date,
        );
        tempReservationIds.add(temp.id);
        _dateReservations = [..._dateReservations, temp]
          ..sort((a, b) => a.reservedAt.compareTo(b.reservedAt));
      }
    });

    Map<String, dynamic> batchResult;
    try {
      batchResult = await _firestoreService.batchCreateReservations(
        placeId: widget.placeId,
        courseId: widget.course.id,
        dayOfWeek: widget.session.dayOfWeek,
        startTime: widget.session.startTime,
        reservedDate: widget.date,
        entries:
            toAdd
                .map(
                  (m) => <String, dynamic>{
                    'userId': m.userId,
                    // 코스 미등록자만 1회성(더미). pending이라도 이 코스 등록돼 있으면 일회성 아님 → 서버에서 pending 문서 횟수 -1
                    'createOneTimeEnrollment':
                        !m.enrolledCourseIds.contains(widget.course.id),
                  },
                )
                .toList(),
        force: true, // 관리자 추가 시 제한사유 조사 없이 강제 추가
      );
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        SnackbarUtil.showInfoFromError(context, e, fallback: '예약 추가에 실패했습니다.');
      }
      _clearBatchLoading(
        toAdd.map((m) => m.userId).toList(),
        tempReservationIds,
      );
      return;
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showInfo(context, '예약 추가 중 오류가 발생했습니다: $e');
      }
      _clearBatchLoading(
        toAdd.map((m) => m.userId).toList(),
        tempReservationIds,
      );
      return;
    }

    final resultsList = batchResult['results'] as List<dynamic>? ?? [];
    int success = 0;
    int oneTimeCount = 0;
    String? firstError;
    for (final r in resultsList) {
      final map = Map<String, dynamic>.from(r as Map);
      if (map['success'] == true) {
        success++;
        if (map['isOneTime'] == true) oneTimeCount++;
      } else {
        firstError ??= map['error']?.toString();
      }
    }
    final failed = resultsList.length - success;
    if (mounted) {
      _clearBatchLoading(
        toAdd.map((m) => m.userId).toList(),
        tempReservationIds,
      );
      if (success > 0) {
        if (oneTimeCount > 0) {
          SnackbarUtil.showSuccess(
            context,
            '일회성 추가 성공: $oneTimeCount명${success > oneTimeCount ? ' (총 $success명 추가됨)' : ''}${failed > 0 ? ' (실패 $failed명)' : ''}',
          );
        } else {
          SnackbarUtil.showSuccess(
            context,
            '$success명 예약이 추가되었습니다.${failed > 0 ? ' (실패 $failed명)' : ''}',
          );
        }
      } else {
        SnackbarUtil.showInfo(
          context,
          firstError ?? '예약이 추가되지 않았습니다. (코스 미등록자는 일회성으로만 추가 가능)',
        );
      }
    }
  }

  void _clearBatchLoading(
    List<String> userIds,
    List<String> tempReservationIds,
  ) {
    if (!mounted) return;
    setState(() {
      for (final userId in userIds) {
        _loadingUserIds.remove(userId);
      }
      _dateReservations.removeWhere((r) => tempReservationIds.contains(r.id));
    });
  }

  Future<void> _handleBackDuringDelete() async {
    if (!_isDeletingSession) return;
    final leave = await CommonDialog.showSavingLeaveConfirm(
      context: context,
      title: '삭제 중입니다',
      onLeave: () => _leaveRequested = true,
    );
    if (leave && mounted) {
      setState(() => _isDeletingSession = false);
      Navigator.of(context).pop();
    }
  }

  /// 세션 관리 바텀시트 표시 (수용인원 변경, 세션 취소)
  Future<void> _showSessionManageBottomSheet() async {
    final dateString = TimezoneUtils.formatDateToSeoul(widget.date);
    final dateKey = _formatDate(widget.date);

    // ✅ 추가된 비정기(override) 세션인지 확인
    final weekStart = DateTime(
      widget.date.year,
      widget.date.month,
      widget.date.day,
    ).subtract(Duration(days: widget.date.weekday - DateTime.monday));
    final weekStartDate = TimezoneUtils.formatDateToSeoul(weekStart);
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final overridesForCourse =
        courseProvider
            .getOverridesForWeek(weekStartDate)
            .where((o) => o.courseId == widget.course.id)
            .toList();
    final overridesForDate =
        overridesForCourse.where((o) => o.date == dateKey).toList();

    CourseOverride? addedOverride;
    try {
      addedOverride = overridesForDate.firstWhere(
        (o) =>
            o.isCancelled != true &&
            o.courseId == widget.course.id &&
            o.date == dateKey &&
            o.dayOfWeek == widget.session.dayOfWeek &&
            o.startTime == widget.session.startTime &&
            (o.endTime == null || o.endTime == widget.session.endTime),
      );
    } catch (_) {
      addedOverride = null;
    }

    // 수용인원·예약 수는 중앙 ReservationSummaryProvider에서만 사용
    final sessionId = SessionReservationSummary.generateSessionId(
      widget.course.id,
      widget.session.dayOfWeek,
      widget.session.startTime,
    );
    final srProvider = Provider.of<ReservationSummaryProvider>(
      context,
      listen: false,
    );
    final sr = srProvider.getSessionReservationSummary(sessionId, dateKey);
    final currentCapacity = srProvider.getTotalCapacity(
      sessionId,
      dateKey,
      fallback: widget.session.capacity,
    );
    final reservedCount = sr?.reservedCount ?? _dateReservations.length;

    final result = await showSessionManageBottomSheet(
      context: context,
      course: widget.course,
      dateString: dateString,
      startTime: widget.session.startTime,
      endTime: widget.session.endTime,
      currentCapacity: currentCapacity,
      reservedCount: reservedCount,
      onCapacityChanged: (newCapacity) async {
        if (!await FirestoreUtils.canReachFirestoreForSave(
          probeCollection: 'places',
          probeDocId: widget.placeId,
        )) {
          if (mounted) {
            SnackbarUtil.showInfo(context, '네트워크 연결을 확인해주세요. ');
          }
          return;
        }
        await _firestoreService.setCapacityOverride(
          placeId: widget.placeId,
          sessionId: sessionId,
          date: dateKey,
          capacity: newCapacity,
        );
        if (mounted) {
          srProvider.updateCapacityLocally(sessionId, dateKey, newCapacity);
          setState(() {});
          SnackbarUtil.showSuccess(context, '수용인원이 변경되었습니다.');
        }
      },
      onCancelSession: () {
        // 세션 취소는 바텀시트가 닫힌 후 result를 확인해서 처리
      },
    );

    if (result == null || result['action'] != 'cancel' || !mounted) return;

    // 세션 취소 확인 다이얼로그
    final confirmed = await CommonDialog.show(
      context: context,
      title: addedOverride != null ? '세션 삭제' : '세션 취소',
      message: '이 세션을 취소하시겠습니까?\n이 세션의 모든 예약이 취소됩니다.',
      cancelText: '취소',
      confirmText: '확인',
      confirmButtonColor: Colors.red,
    );

    if (confirmed != true || !mounted) return;

    // pop 후에도 스낵바가 유지되도록 글로벌 context 사용 (로딩 → 성공 전환이 정상 동작)
    final snackbarContext = navigatorKey.currentContext ?? context;

    if (mounted) {
      setState(() => _isDeletingSession = true);
      SnackbarUtil.showLoading(snackbarContext, '삭제 중');
    }

    try {
      if (_leaveRequested) return;
      if (!await FirestoreUtils.canReachFirestoreForSave(
        probeCollection: 'places',
        probeDocId: widget.placeId,
      )) {
        if (mounted) {
          setState(() => _isDeletingSession = false);
          SnackbarUtil.showInfo(context, '네트워크 연결을 확인해주세요. ');
        }
        return;
      }
      // 세션 취소 처리
      // 알림은 항상 true로 설정 (UI에서 제거됨)
      const bool shouldSendNotification = true;

      // 세션 취소 처리 (await로 완료까지 대기, 삭제 시 리버트 가드 적용)
      await (addedOverride != null
          ? _firestoreService.upsertCourseOverride(
            placeId: widget.placeId,
            courseId: widget.course.id,
            date: dateString,
            dayOfWeek: widget.session.dayOfWeek,
            startTime: widget.session.startTime,
            endTime: widget.session.endTime,
            weekStartDate: weekStartDate,
            action: 'delete',
            overrideId: addedOverride.id,
            sendNotification: shouldSendNotification,
          )
          : _firestoreService.upsertCourseOverride(
            placeId: widget.placeId,
            courseId: widget.course.id,
            date: dateString,
            dayOfWeek: widget.session.dayOfWeek,
            startTime: widget.session.startTime,
            weekStartDate: weekStartDate,
            isCancelled: true,
            action: 'create',
            sendNotification: shouldSendNotification,
          ));
      // 나갔어도 로딩 스낵바를 닫고 결과 표시
      final resultCtx = mounted ? context : navigatorKey.currentContext;
      if (resultCtx != null) {
        final message = addedOverride != null ? '세션이 삭제되었습니다.' : '세션이 취소되었습니다.';
        SnackbarUtil.showSuccess(resultCtx, message);
      }
      if (_leaveRequested) return;
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      debugPrint('[SessionDetailScreen] 세션 취소 실패: $e');
      final errCtx = mounted ? context : navigatorKey.currentContext;
      if (errCtx != null) {
        SnackbarUtil.showInfoFromError(errCtx, e, fallback: '세션 취소에 실패했습니다.');
      }
      if (_leaveRequested) return;
      if (mounted) {
        setState(() => _isDeletingSession = false);
      }
    } finally {
      SnackbarUtil.dismissLoading();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        SnackbarUtil.dismissLoading();
      });
      if (mounted) setState(() => _isDeletingSession = false);
    }
  }
}
