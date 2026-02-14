import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:provider/provider.dart';
import 'package:reservation/services/user_service.dart';
import '../../../models/course.dart';
import '../../../models/reservation.dart';
import '../../../models/user.dart';
import '../../../models/pending_member.dart';
import '../../../models/course_enrollment.dart';
import '../../../models/notification.dart';
import '../../../models/session_reservation.dart';
import '../../../models/course_override.dart';
import '../../../theme/app_colors.dart';
import '../../../services/firestore_service.dart';
import '../../../services/enrollment_service.dart';
import '../../../services/member_service.dart';
import '../../../widgets/common_dialog.dart';
import '../../../providers/reservation_provider.dart';
import '../../../providers/member_provider.dart';
import 'reservation_manage_bottom_sheet.dart';
import 'member_selection_side_panel.dart';
import '../../../utils/snackbar_util.dart';
import '../../../utils/timezone_utils.dart';
import '../../../utils/format_utils.dart';
import '../../../widgets/session_manage_bottom_sheet.dart';
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
  final EnrollmentService _enrollmentService = EnrollmentService();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  Map<String, User> _userCache = {};
  Set<String> _loadingUserIds = {}; // 개별 멤버 로딩 상태 추적
  Set<String> _movingReservationIds = {}; // 이동 중인 예약 ID들
  Set<String> _cancellingReservationIds = {}; // 취소 중인 예약 ID들 (로컬 상태)
  Map<String, bool> _copiedPhones = {}; // 전화번호 복사 상태 관리
  List<Reservation> _dateReservations = [];
  StreamSubscription<List<Reservation>>? _reservationsSub;
  StreamSubscription<ReservationOperationEvent>?
  _operationEventsSub; // 예약 작업 이벤트 구독
  bool _adminForceAddApproved = false; // 강제 추가를 한 번 승인하면 같은 화면에서는 재확인 최소화
  Map<String, SessionReservation> _sessionReservationsByKey = {}; // 세션 예약 정보 캐시
  Map<String, List<CourseOverride>> _overridesByDate = {}; // 비정기 일정 캐시
  int? _capacityOverride; // dateCapacityOverrides로 설정된 수용인원(있으면 우선)
  @override
  void initState() {
    super.initState();
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
        .listen((reservations) async {
          if (!mounted) return;
          setState(() {
            _dateReservations =
                reservations
                  ..sort((a, b) => a.reservedAt.compareTo(b.reservedAt));
          });
          await _loadUserDataFor(_dateReservations);
          await _loadSessionReservationData();
        });
  }

  /// 세션 예약 정보 및 비정기 일정 로드
  Future<void> _loadSessionReservationData() async {
    final dateKey = _formatDate(widget.date);
    final sessionId = SessionReservation.generateSessionId(
      widget.course.id,
      widget.session.dayOfWeek,
      widget.session.startTime,
    );

    try {
      // dateCapacityOverrides 확인 (예약이 0명인 경우 sessionReservations 문서가 없을 수 있음)
      final capOverride = await _firestoreService.getCapacityOverride(
        widget.placeId,
        sessionId,
        dateKey,
      );
      final overrideCap = capOverride?.capacity;
      if (mounted) {
        setState(() {
          _capacityOverride = overrideCap;
        });
      }

      // 세션 예약 정보 로드
      final sessionReservations =
          await _firestoreService
              .watchCourseSessionReservations(
                courseId: widget.course.id,
                placeId: widget.placeId,
                startDate: widget.date,
                endDate: widget.date,
              )
              .first;

      final baseSr = sessionReservations.firstWhere(
        (sr) => sr.sessionId == sessionId && sr.date == dateKey,
        orElse:
            () => SessionReservation(
              id: '',
              sessionId: sessionId,
              courseId: widget.course.id,
              placeId: widget.placeId,
              dayOfWeek: widget.session.dayOfWeek,
              startTime: widget.session.startTime,
              date: dateKey,
              capacity:
                  overrideCap ?? widget.session.getCapacityForDate(widget.date),
              reservedCount: _dateReservations.length,
              lastUpdated: TimezoneUtils.getSeoulDateTime(),
            ),
      );
      final sr =
          overrideCap != null ? baseSr.copyWith(capacity: overrideCap) : baseSr;

      if (mounted) {
        setState(() {
          _sessionReservationsByKey['${sessionId}_$dateKey'] = sr;
        });
      }

      // 비정기 일정 로드
      final weekStart = DateTime(
        widget.date.year,
        widget.date.month,
        widget.date.day,
      ).subtract(Duration(days: widget.date.weekday - DateTime.monday));
      final weekStartDate = TimezoneUtils.formatDateToSeoul(weekStart);

      final overrides = await _firestoreService.getCourseOverrides(
        placeId: widget.placeId,
        courseId: widget.course.id,
        weekStartDate: weekStartDate,
      );

      if (mounted) {
        setState(() {
          _overridesByDate[dateKey] =
              overrides.where((o) => o.date == dateKey).toList();
        });
      }
    } catch (e) {
      debugPrint('[SessionDetailScreen] Error loading session data: $e');
    }
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  Future<void> _loadUserDataFor(List<Reservation> reservations) async {
    // ✅ 성능/안정성:
    // - 기존은 예약 수만큼 개별 setState + 개별 getUser 호출
    // - pending_ 예약은 users 문서가 없을 수 있으므로 pendingMembers에서 폴백 조회
    final missingUserIds =
        reservations
            .map((r) => r.userId)
            .where((id) => id.isNotEmpty && !_userCache.containsKey(id))
            .toSet()
            .toList();

    if (missingUserIds.isEmpty) return;

    final realUserIds = <String>[];
    final pendingDocIds = <String>[];
    for (final id in missingUserIds) {
      if (id.startsWith('pending_') && id.length > 'pending_'.length) {
        pendingDocIds.add(id.substring('pending_'.length));
      } else {
        realUserIds.add(id);
      }
    }

    final fetched = <String, User>{};

    // 1) 일반 유저는 배치 조회 (내부적으로 실패 시 개별 조회 폴백)
    if (realUserIds.isNotEmpty) {
      try {
        final users = await UserService().getUsersByIds(realUserIds);
        for (final u in users) {
          fetched[u.userId] = u;
        }
      } catch (_) {
        // ignore
      }
    }

    // 2) pending 유저는 pendingMembers 문서에서 이름/전화번호 로드
    if (pendingDocIds.isNotEmpty) {
      try {
        final firestore = _firestoreService.firestore;
        final docs = await Future.wait(
          pendingDocIds.map(
            (docId) => firestore.collection('pendingMembers').doc(docId).get(),
          ),
        );

        for (final doc in docs) {
          if (!doc.exists || doc.data() == null) continue;
          final data = Map<String, dynamic>.from(doc.data()!);
          data['id'] ??= doc.id;

          final pending = PendingMember.fromJson(data);
          final name =
              (pending.name ?? '').trim().isNotEmpty
                  ? pending.name!.trim()
                  : '대기 멤버';

          final pseudoUser = User(
            userId: 'pending_${pending.id}',
            name: name,
            phoneNumber: pending.phoneNumber,
            createdAt: pending.createdAt,
          );

          // 캐시 key는 reservation.userId와 동일해야 UI에서 매칭된다.
          fetched[pseudoUser.userId] = pseudoUser;
        }
      } catch (_) {
        // ignore
      }
    }

    if (!mounted || fetched.isEmpty) return;
    setState(() {
      _userCache.addAll(fetched);
    });
  }

  void _refreshReservations() {
    // watchSessionReservations가 최신 상태를 반영하므로 별도 처리 불필요
  }

  @override
  Widget build(BuildContext context) {
    final totalCapacity =
        _capacityOverride ?? widget.session.getCapacityForDate(widget.date);
    final dateReservations = _dateReservations;
    final reservedCount = _dateReservations.length;
    final progress = totalCapacity > 0 ? reservedCount / totalCapacity : 0.0;

    return Scaffold(
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

                const SizedBox(height: 16),

                // 예약 상세 정보 (게이지)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
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
                          Expanded(
                            child: _buildInfoItem(
                              label: '예약 현황',
                              value: '$reservedCount명 / $totalCapacity명',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 13),
                      // 진행 바
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 8,
                          backgroundColor: AppColors.borderLight,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Color(widget.course.color),
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
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
                                          '아직 예약자가 없어요',
                                          style: TextStyle(
                                            fontSize: 16,
                                            color: AppColors.textSecondary,
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                  : ListView.builder(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
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
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final totalCapacity =
        _capacityOverride ?? widget.session.getCapacityForDate(widget.date);
    final reservedCount = _dateReservations.length;

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
        onPressed: () => Navigator.of(context).pop(),
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
          IconButton(
            icon: Icon(
              Icons.add_circle,
              color: AppColors.primaryGreen,
              size: 32,
            ),
            onPressed:
                () => MemberSelectionSidePanel.show(
                  context: context,
                  course: widget.course,
                  totalCapacity: totalCapacity,
                  reservedCount: reservedCount,
                  existingReservationUserIds:
                      _dateReservations.map((r) => r.userId).toList(),
                  onMembersSelected: (users) {
                    // 여러 명 선택 시에도 네트워크 호출/다이얼로그가 겹치지 않게 순차 처리
                    () async {
                      await _addReservationsForUsers(users);
                    }();
                  },
                ),
            tooltip: '예약자 추가',
          ),

        if (!isPastSession)
          IconButton(
            icon: Icon(
              Icons.more_vert,
              color: AppColors.primaryGreen,
              size: 28,
            ),
            onPressed: () => _showSessionManageBottomSheet(),
            tooltip: '세션 설정',
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
    return Column(
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
    );
  }

  Widget _buildReservistItem({
    required int index,
    required Reservation reservation,
  }) {
    final user = _userCache[reservation.userId];
    // 관리자 지정 이름(placeMemberships.displayName) 우선, 없으면 user.name
    final memberProvider = Provider.of<MemberProvider>(context, listen: false);
    final adminDisplayName =
        memberProvider.membershipDisplayNamesByUserId[reservation.userId];
    final userName =
        (adminDisplayName != null && adminDisplayName.trim().isNotEmpty)
            ? adminDisplayName.trim()
            : (user?.name ?? '예약자 $index');
    final phoneNumber = user?.phoneNumber ?? '010-0000-0000';
    final isLoading = _loadingUserIds.contains(reservation.userId);
    final isMoving = _movingReservationIds.contains(reservation.id);

    // 예약 취소 중인지 확인 (로컬 상태 사용)
    final isCancelling = _cancellingReservationIds.contains(reservation.id);

    return InkWell(
      onTap:
          (isLoading || isMoving || isCancelling)
              ? null
              : () =>
                  _showReservationManageBottomSheet(context, reservation, user),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.backgroundLight,
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 18),
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
                                (isLoading || isMoving || isCancelling)
                                    ? AppColors.textSecondary
                                    : AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
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
                            // 클립보드에 복사
                            Clipboard.setData(ClipboardData(text: phoneNumber));
                            setState(() {
                              _copiedPhones[reservation.id] = true;
                            });
                            // 스낵바 표시
                            SnackbarUtil.showSuccess(context, '클립보드에 복사되었습니다');
                            // 2초 후 다시 복사 아이콘으로 변경
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
            else
              Icon(
                Icons.chevron_right,
                color: AppColors.primaryGreen,
                size: 30,
              ),
          ],
        ),
      ),
    );
  }

  void _showReservationManageBottomSheet(
    BuildContext context,
    Reservation reservation,
    User? user,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.7),
      isDismissible: true,
      enableDrag: true,
      useSafeArea: true,
      builder:
          (context) => ReservationManageBottomSheet(
            course: widget.course,
            sourceSession: widget.session,
            sourceDate: widget.date,
            reservation: reservation,
            user: user,
            onCancelled: () {
              if (!mounted) return;
              // 취소 시작 시 로딩 상태 추가 (operationEvents로 완료 감지)
              setState(() {
                _cancellingReservationIds.add(reservation.id);
              });
              _refreshReservations();
              // 바텀시트는 이미 _handleCancel에서 닫히므로 여기서는 닫지 않음
            },
            onMoved: () {
              if (!mounted) return;
              _refreshReservations();
              Navigator.of(context).pop();
            },
            onMovingStarted: _handleMovingStarted,
            onMovingCompleted: _handleMovingCompleted,
            onAllMovingCompleted: _handleAllMovingCompleted,
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

  Future<Map<String, dynamic>> _addReservationForUser(
    User user, {
    bool force = false,
    bool isOneTimeEnrollment = false,
  }) async {
    try {
      final newReservation = Reservation(
        id: '',
        userId: user.userId,
        courseId: widget.course.id,
        placeId: widget.placeId,
        dayOfWeek: widget.session.dayOfWeek,
        startTime: widget.session.startTime,
        reservedAt: DateTime.now(),
        reservedDate: widget.date,
      );

      await _firestoreService.createReservation(newReservation, force: force);

      // 1회석 enrollment로 추가된 경우 알림 전송
      if (isOneTimeEnrollment) {
        final dateString = TimezoneUtils.formatDateToSeoul(widget.date);
        final notification = AppNotification(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          userId: user.userId,
          placeId: widget.placeId,
          type: NotificationType.reservation,
          title: '일회성 예약 추가 완료',
          body:
              '${widget.course.name} - $dateString ${widget.session.startTime}',
          createdAt: TimezoneUtils.getSeoulDateTime(),
          data: {
            'courseId': widget.course.id,
            'courseName': widget.course.name,
            'date': dateString,
            'startTime': widget.session.startTime,
            'isOneTime': true,
          },
        );

        await _firestoreService.createNotification(notification);
      }

      return {'success': true, 'isOneTime': isOneTimeEnrollment};
    } on FirebaseFunctionsException catch (e) {
      final details = e.details;
      final detailsMap =
          details is Map ? Map<String, dynamic>.from(details) : null;
      final requiresForce = detailsMap?['requiresForce'] == true;
      final isPendingUser = user.userId.startsWith('pending_');

      // 디버깅: 에러 상세 정보 로그
      debugPrint('[SessionDetailScreen] 예약 추가 실패:');
      debugPrint('  - code: ${e.code}');
      debugPrint('  - message: ${e.message}');
      debugPrint('  - details: $detailsMap');
      debugPrint('  - user: ${user.userId}, course: ${widget.course.id}');
      debugPrint(
        '  - enrollment: ${user.getRemainingReservations(widget.course.id)} 남은 횟수',
      );

      // 등록되지 않은 코스인 경우:
      // - 일반 유저: 1회석 enrollment 자동 생성 (enrollments 컬렉션)
      // - pending 유저: pendingMembers.courseEnrollments에 1회석을 추가/업데이트
      if (e.code == 'failed-precondition' &&
          (e.message?.contains('등록된 코스가 아닙니다') == true)) {
        try {
          final now = TimezoneUtils.getSeoulDateTime();
          final validUntil = now.add(const Duration(days: 365));
          if (isPendingUser) {
            // pending 멤버는 enrollments를 만들지 않는다. pendingMembers에 1회석을 기록한다.
            final ok = await MemberService().updatePendingCourseEnrollmentConfig(
              placeId: widget.placeId,
              phoneNumber: user.phoneNumber,
              courseId: widget.course.id,
              totalReservations: 1,
              validFrom: now,
              validUntil: validUntil,
              // remainingReservations는 서버에서 totalReservations fallback + 차감 로직으로 처리
            );
            if (!ok) {
              throw Exception('pending 멤버 코스 등록(1회석) 업데이트 실패');
            }
          } else {
            // 1회석 enrollment 생성
            final oneTimeEnrollment = CourseEnrollment(
              id: '${user.userId}_${widget.placeId}_${widget.course.id}',
              userId: user.userId,
              courseId: widget.course.id,
              placeId: widget.placeId,
              enrolledAt: now,
              totalEnrollmentCount: 1,
              validFrom: now,
              validUntil: validUntil,
              totalReservations: 1,
              remainingReservations: 1,
              reenrollmentHistory: [
                ReenrollmentRecord(
                  enrollmentNumber: 1,
                  totalReservations: 1,
                  enrolledAt: now,
                  validFrom: now,
                  validUntil: validUntil,
                ),
              ],
            );

            await _enrollmentService.createEnrollment(oneTimeEnrollment);
          }

          // enrollment 생성 후 다시 예약 시도 (1회석 플래그 전달)
          return await _addReservationForUser(
            user,
            force: force,
            isOneTimeEnrollment: true,
          );
        } catch (enrollmentError) {
          if (mounted) {
            SnackbarUtil.showInfo(
              context,
              isPendingUser
                  ? 'pending 멤버 1회석 등록 업데이트에 실패했습니다: $enrollmentError'
                  : '1회석 등록 생성에 실패했습니다: $enrollmentError',
            );
          }
          return {'success': false, 'isOneTime': false};
        }
      }

      if (requiresForce) {
        // 한 번 승인했으면 같은 화면에서는 재확인 최소화
        if (_adminForceAddApproved && !force) {
          return await _addReservationForUser(user, force: true);
        }

        final reason = (detailsMap?['reason'] as String?) ?? '';
        final openAt = (detailsMap?['openAt'] as String?) ?? '';
        final capacity = detailsMap?['capacity'];
        final reservedCount = detailsMap?['reservedCount'];
        final closeBeforeMinutes = detailsMap?['closeBeforeMinutes'];

        String message = e.message ?? '정책상 예약이 제한됩니다.';
        if (reason == 'full') {
          message =
              '정원 마감 상태입니다.\n관리자 권한으로 추가하시겠습니까?\n\n현재: $reservedCount / $capacity';
        } else if (reason == 'notOpenedYet') {
          message =
              '아직 예약 오픈 전입니다. 관리자 권한으로 강제 추가하시겠습니까?'
              '${openAt.isNotEmpty ? '\n\n오픈 예정: $openAt' : ''}';
        } else if (reason == 'closedBeforeStart') {
          message =
              '세션 시작 임박으로 예약이 마감되었습니다. 관리자 권한으로 강제 추가하시겠습니까?\n\n마감 기준: 시작 ${closeBeforeMinutes ?? 60}분 전';
        }

        final confirmed = await CommonDialog.show(
          context: context,
          title: '관리자 강제 추가',
          message: message,
          cancelText: '취소',
          confirmText: '추가',
          confirmButtonColor: Colors.red,
        );

        if (confirmed == true) {
          _adminForceAddApproved = true;
          return await _addReservationForUser(user, force: true);
        }
        return {'success': false, 'isOneTime': false};
      }

      if (mounted) {
        final reason = (detailsMap?['reason'] as String?) ?? '';

        // "세션을 찾을 수 없습니다" 에러는 비정기 일정일 수 있으므로 더 명확한 메시지 표시
        if (e.message?.contains('세션을 찾을 수 없습니다') == true) {
          SnackbarUtil.showInfo(
            context,
            '비정기 일정은 예약 추가가 제한될 수 있습니다. 정기 일정을 사용해주세요.',
          );
        } else if (reason == 'noCreditsOrExpired' ||
            e.message?.contains('남은 예약 횟수가 없거나 유효 기간이 만료') == true ||
            e.message?.contains('예약 가능한 횟수가 없거나 유효 기간이 만료') == true) {
          // 유효기간/횟수 관련 에러는 더 자세한 정보 표시
          SnackbarUtil.showInfo(
            context,
            '남은 예약 횟수가 없거나 유효 기간이 만료된 회원입니다.\n\n'
            '회원의 등록 정보를 확인해주세요.',
          );
        } else {
          SnackbarUtil.showInfo(context, e.message ?? '예약 추가에 실패했습니다.');
        }
      }
      return {'success': false, 'isOneTime': false};
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showInfo(context, '예약 추가 중 오류가 발생했습니다: $e');
      }
      return {'success': false, 'isOneTime': false};
    }
  }

  Future<void> _addReservationsForUsers(List<User> users) async {
    if (users.isEmpty) return;

    // 이미 이 세션에 예약된 사용자는 제외 (클라이언트 중복 방지, 데이터 지연 시에도 안전)
    final existingUserIds = _dateReservations.map((r) => r.userId).toSet();
    final toAdd =
        users.where((u) => !existingUserIds.contains(u.userId)).toList();
    final skipped = users.length - toAdd.length;
    if (skipped > 0 && mounted) {
      SnackbarUtil.showInfo(context, '이미 이 세션에 예약된 멤버 $skipped명은 제외했습니다.');
    }
    if (toAdd.isEmpty) return;

    int success = 0;
    int oneTimeCount = 0;
    final List<Reservation> tempReservations = [];

    // 1. 로컬에서 즉시 리스트에 추가 (임시 예약 생성)
    for (final user in toAdd) {
      if (!mounted) break;

      // 사용자 정보 캐시에 추가
      if (!_userCache.containsKey(user.userId)) {
        _userCache[user.userId] = user;
      }

      // 임시 예약 생성 (id는 userId로 임시 식별)
      final tempReservation = Reservation(
        id: 'temp_${user.userId}_${DateTime.now().millisecondsSinceEpoch}',
        userId: user.userId,
        courseId: widget.course.id,
        placeId: widget.placeId,
        dayOfWeek: widget.session.dayOfWeek,
        startTime: widget.session.startTime,
        reservedAt: DateTime.now(),
        reservedDate: widget.date,
      );

      tempReservations.add(tempReservation);

      // 로컬 리스트에 즉시 추가
      setState(() {
        _loadingUserIds.add(user.userId);
        _dateReservations = [..._dateReservations, tempReservation]
          ..sort((a, b) => a.reservedAt.compareTo(b.reservedAt));
      });
    }

    // 2. 백그라운드에서 서버 요청 처리
    for (int i = 0; i < toAdd.length; i++) {
      final user = toAdd[i];
      final tempReservation = tempReservations[i];

      if (!mounted) break;

      try {
        final result = await _addReservationForUser(user);

        if (result['success'] == true) {
          success++;
          if (result['isOneTime'] == true) {
            oneTimeCount++;
          }

          // 성공 시 로딩 상태 제거 (실제 예약은 stream에서 업데이트됨)
          if (mounted) {
            setState(() {
              _loadingUserIds.remove(user.userId);
              // 임시 예약 제거 (실제 예약이 stream에서 추가됨)
              _dateReservations.removeWhere((r) => r.id == tempReservation.id);
            });
          }
        } else {
          // 실패 시 임시 예약 제거 및 로딩 상태 제거
          if (mounted) {
            setState(() {
              _loadingUserIds.remove(user.userId);
              _dateReservations.removeWhere((r) => r.id == tempReservation.id);
            });
          }
        }
      } catch (e) {
        // 에러 발생 시 임시 예약 제거 및 로딩 상태 제거
        if (mounted) {
          setState(() {
            _loadingUserIds.remove(user.userId);
            _dateReservations.removeWhere((r) => r.id == tempReservation.id);
          });
        }
      }
    }

    if (!mounted) return;

    // 3. 결과 스낵바 표시
    if (success > 0) {
      if (oneTimeCount > 0) {
        // 일회성 추가 성공 스낵바
        SnackbarUtil.showSuccess(
          context,
          '일회성 추가 성공: $oneTimeCount명${success > oneTimeCount ? ' (총 $success명 추가됨)' : ''}',
        );
      } else {
        SnackbarUtil.showSuccess(context, '$success명 예약이 추가되었습니다.');
      }
    }
  }

  /// 세션 관리 바텀시트 표시 (수용인원 변경, 세션 취소)
  Future<void> _showSessionManageBottomSheet() async {
    final dateString = TimezoneUtils.formatDateToSeoul(widget.date);
    final dateKey = _formatDate(widget.date);

    // ✅ 추가된 비정기(override) 세션인지 확인
    CourseOverride? addedOverride;
    final overridesForDate =
        _overridesByDate[dateKey] ?? const <CourseOverride>[];
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

    // 현재 수용인원 가져오기
    final sessionId = SessionReservation.generateSessionId(
      widget.course.id,
      widget.session.dayOfWeek,
      widget.session.startTime,
    );
    final sr = _sessionReservationsByKey['${sessionId}_$dateKey'];
    // _capacityOverride가 있으면 우선 사용 (dateCapacityOverrides)
    final currentCapacity =
        _capacityOverride ??
        sr?.capacity ??
        widget.session.getCapacityForDate(widget.date);
    final reservedCount = _dateReservations.length;

    final result = await showSessionManageBottomSheet(
      context: context,
      course: widget.course,
      dateString: dateString,
      startTime: widget.session.startTime,
      endTime: widget.session.endTime,
      currentCapacity: currentCapacity,
      reservedCount: reservedCount,
      onCapacityChanged: (newCapacity) async {
        await _firestoreService.setCapacityOverride(
          placeId: widget.placeId,
          sessionId: sessionId,
          date: dateKey,
          capacity: newCapacity,
        );
        // UI 즉시 업데이트
        if (mounted) {
          setState(() {
            // _capacityOverride 업데이트
            _capacityOverride = newCapacity;
          });
          final key = '${sessionId}_$dateKey';
          final existingSr = _sessionReservationsByKey[key];
          if (existingSr != null) {
            setState(() {
              _sessionReservationsByKey[key] = existingSr.copyWith(
                capacity: newCapacity,
                lastUpdated: TimezoneUtils.getSeoulDateTime(),
              );
            });
          }
          SnackbarUtil.showSuccess(context, '수용인원이 변경되었습니다.');
          // 세션 데이터 다시 로드 (백그라운드)
          _loadSessionReservationData();
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

    // 로딩 스낵바 표시
    if (mounted) {
      SnackbarUtil.showLoading(context, '세션 취소 중...');
    }

    try {
      // 세션 취소 처리
      final weekStart = DateTime(
        widget.date.year,
        widget.date.month,
        widget.date.day,
      ).subtract(Duration(days: widget.date.weekday - DateTime.monday));
      final weekStartDate = TimezoneUtils.formatDateToSeoul(weekStart);

      // 알림은 항상 true로 설정 (UI에서 제거됨)
      const bool shouldSendNotification = true;

      // 세션 취소 처리 (await로 완료까지 대기)
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

      // 성공 시 화면 닫기
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      debugPrint('[SessionDetailScreen] 세션 취소 실패: $e');
      if (mounted) {
        SnackbarUtil.showInfo(context, '세션 취소에 실패했습니다.');
      }
    }
  }
}
