import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../models/course.dart';
import '../../../models/session_reservation.dart';
import '../../../models/session_reservation_summary.dart';
import '../../../models/course_enrollment.dart';
import '../../../models/course_override.dart';
import '../../../models/course_policy.dart';
import '../../../utils/reservation_policy_engine.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/course_provider.dart';
import '../../../utils/timezone_utils.dart';
import '../../../utils/calendar_utils.dart';
import '../../../providers/enrollment_provider.dart';
import '../../../providers/place_provider.dart';
import '../../../providers/reservation_provider.dart';
import '../../../providers/reservation_summary_provider.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/session_block_style.dart';
import '../../../widgets/reservation_bottom_sheet.dart';
import '../../../widgets/reservation_complete_bottom_sheet.dart';
import '../../../widgets/user_reservation_manage_bottom_sheet.dart';
import '../../../utils/snackbar_util.dart';
import '../../../utils/week_range_calculator.dart';
import '../../../utils/session_slot_builder.dart';
import '../../../widgets/week_tab_bar.dart';
import '../../../widgets/common_dialog.dart';

class CalendarScreen extends StatefulWidget {
  final Course course;
  final Map<String, dynamic>? highlightSession;

  const CalendarScreen({
    super.key,
    required this.course,
    this.highlightSession,
  });

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  /// 정기일정(요일/세션) 변경 시 Provider에서 최신 코스 반영
  late Course _effectiveCourse;

  Course get course => _effectiveCourse;

  // 주간 이동을 위한 상태
  int _weekOffset = 0; // 0: 현재 주(이번주), 1: 다음주, 2: 다다음주

  CoursePolicy? _coursePolicy;
  StreamSubscription<ReservationOperationEvent>? _reservationOpSub;
  String? _lastShownCompleteReservationId;

  // 정책 기반 주차 범위
  List<int> _availableWeekOffsets = [0, 1, 2]; // 기본값

  // 에러 상태 관리
  String? _errorMessage;
  String? _errorType;
  bool _isLoading = false; // 재시도 버튼 비활성화용

  // UI 상수 정의
  static const double _minHourSlotHeight =
      80.0; // 세로 눈금 최소 간격 (스크롤 허용, 적당한 가독성)
  static const double _optimalPxPerMinute = 50; // 세션 블록이 잘 보이기 위한 분당 픽셀 수
  static const int _edgePaddingMinutes = 30; // 00시, 23시 경계에 추가할 여백(분)
  static const int _mergeGapMinHours = 3; // 이 시간 이상 연속 공백은 하나로 합쳐(건너뛰기) 표시
  static const double _mergedGapSlotHeight = 28.0; // 병합 공백 최소 높이(px)
  static const double _mergedGapPxPerHour = 16.0; // 병합 공백: 시간당 px (시간 길이 시각화)
  static const double _minGapHourSlotHeight = 18.0; // 공백 구간 축소 하한 (px/h)
  static const double _timeColumnWidth = 35.0; // 시간대 컬럼 너비 (px)
  static const double _lineOffset = 1.0; // 가로선을 아래로 이동하는 오프셋 (px)
  static const double _sessionPadding = 1.0; // 세션 블록 좌우 패딩 (px)
  static const double _dateColumnSpacing = 0.0; // 날짜 컬럼 간 간격 (px)
  static const double _timeTextPaddingRight = 6.0; // 시간 텍스트 오른쪽 패딩 (px)
  static const double _gridRightPadding = 8.0; // 그리드 오른쪽 패딩 (px)

  static const int _basePaddingMinutes = 120; // 세션 위/아래 기본 여백(2시간)

  final ScrollController _scrollController = ScrollController();
  bool _didInitialJump = false;

  /// ReservationSummaryProvider 참조 — dispose 시 구독 해제용
  ReservationSummaryProvider? _summaryProvider;

  /// 첫 build 후 한 번만 _updateProviderContext 예약 (initState postFrameCallback 보완)

  static int _floorToHour(int minutes) => (minutes ~/ 60) * 60;
  static int _ceilToHour(int minutes) =>
      ((minutes + 59) ~/ 60) * 60; // 올림(1~59분 포함)

  @override
  void initState() {
    super.initState();
    _effectiveCourse = widget.course;
    final hl = widget.highlightSession;
    if (hl != null) {
      final dateStr = hl['date'] as String?;
      if (dateStr != null && dateStr.isNotEmpty) {
        try {
          final target = DateTime.parse(dateStr);
          final now = TimezoneUtils.getSeoulDateTime();
          final thisMonday = CalendarUtils.startOfWeekMonday(now);
          final targetMonday = CalendarUtils.startOfWeekMonday(target);
          final diffDays = targetMonday.difference(thisMonday).inDays;
          final weekOffset = (diffDays / 7).round();
          if (weekOffset >= 0) {
            _weekOffset = weekOffset;
          }
        } catch (_) {}
      }
    }
    debugPrint('[CalendarScreen] initState: 화면 초기화 시작');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      debugPrint('[CalendarScreen] postFrameCallback: 구독 시작 준비');
      _ensureUserDataLoaded();
      _updateProviderContext();
      _subscribeReservationOperationEvents();
    });
  }

  @override
  void didUpdateWidget(CalendarScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.course.id != widget.course.id) {
      _effectiveCourse = widget.course;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateProviderContext();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // CourseProvider 기준으로 코스·정책 동기화 (정책 편집 복귀 시 자물쇠/주차 탭 즉시 반영)
    final fromProvider = Provider.of<CourseProvider>(
      context,
      listen: false,
    ).getCourse(widget.course.id);
    if (fromProvider == null) return;
    final policy = fromProvider.policy;
    final needUpdate =
        fromProvider != _effectiveCourse || _coursePolicy != policy;
    if (needUpdate) {
      setState(() {
        _effectiveCourse = fromProvider;
        _coursePolicy = policy;
        _updateAvailableWeekOffsets(policy);
        if (_availableWeekOffsets.isNotEmpty &&
            _weekOffset >= _availableWeekOffsets.length) {
          _weekOffset = _availableWeekOffsets.length - 1;
        }
      });
    }
  }

  @override
  void dispose() {
    _reservationOpSub?.cancel();
    // ReservationSummaryProvider 구독 해제 (sessionReservations, courseOverrides 스트림 cancel)
    _summaryProvider?.clear();
    _summaryProvider = null;
    _scrollController.dispose();
    super.dispose();
  }

  void _recomputeLoadingFromProvider(bool providerLoading) {
    if (!mounted) return;
    if (_isLoading != providerLoading) {
      setState(() {
        _isLoading = providerLoading;
      });
    }
  }

  List<CourseSession> _effectiveSessionsForDate(
    DateTime date,
    Map<String, List<CourseOverride>> overridesByDate,
  ) {
    final dateStr = CalendarUtils.formatDateYMD(date);
    final overrides = overridesByDate[dateStr] ?? const <CourseOverride>[];
    final regular = course.getSessionsByDay(date.weekday);

    // 취소: startTime이 있으면 해당 세션만, 없으면 해당 요일 전체(정기 세션 전체) 취소로 처리
    final cancelled = overrides.where((o) => o.isCancelled == true).toList();
    final cancelAllForDay = cancelled.any((o) {
      final st = o.startTime;
      return st == null || st.isEmpty;
    });
    final cancelledStartTimes =
        cancelled.map((o) => o.startTime).whereType<String>().toSet();

    final filteredRegular =
        cancelAllForDay
            ? <CourseSession>[]
            : regular
                .where((s) => !cancelledStartTimes.contains(s.startTime))
                .toList();

    // 추가/변경: startTime/endTime이 있는 override는 세션으로 간주
    // 동일 startTime이 있으면 정기 세션을 대체(override 우선)
    final addedOrModified =
        overrides
            .where(
              (o) =>
                  o.isCancelled != true &&
                  o.startTime != null &&
                  o.endTime != null,
            )
            .map(
              (o) => CourseSession(
                dayOfWeek: o.dayOfWeek,
                startTime: o.startTime!,
                endTime: o.endTime!,
                capacity: o.capacity ?? 0,
              ),
            )
            .toList();

    final overrideStartTimes = addedOrModified.map((s) => s.startTime).toSet();
    final base =
        filteredRegular
            .where((s) => !overrideStartTimes.contains(s.startTime))
            .toList();
    final all = <CourseSession>[...base, ...addedOrModified]..sort(
      (a, b) => CalendarUtils.parseTimeToMinutes(
        a.startTime,
      ).compareTo(CalendarUtils.parseTimeToMinutes(b.startTime)),
    );
    return all;
  }

  bool _hasAddedOverrideSessionsForDate(
    DateTime date,
    Map<String, List<CourseOverride>> overridesByDate,
  ) {
    final dateStr = CalendarUtils.formatDateYMD(date);
    final overrides = overridesByDate[dateStr];
    if (overrides == null || overrides.isEmpty) return false;
    return overrides.any(
      (o) => o.isCancelled != true && o.startTime != null && o.endTime != null,
    );
  }

  List<CourseSession> _effectiveSessionsForDates(
    List<DateTime> dates,
    Map<String, List<CourseOverride>> overridesByDate,
  ) {
    final out = <CourseSession>[];
    for (final d in dates) {
      out.addAll(_effectiveSessionsForDate(d, overridesByDate));
    }
    return out;
  }

  void _subscribeReservationOperationEvents() {
    _reservationOpSub?.cancel();
    final rp = Provider.of<ReservationProvider>(context, listen: false);
    _reservationOpSub = rp.operationEvents.listen((event) async {
      // create 성공 시: 바텀시트가 닫혀 있어도(또는 닫혔더라도) 성공 바텀시트 표시
      if (event.type == ReservationOperationType.create &&
          event.success == true &&
          event.reservation != null) {
        final created = event.reservation!;
        if (_lastShownCompleteReservationId == created.id) return;
        _lastShownCompleteReservationId = created.id;

        if (!mounted) return;
        ReservationCompleteBottomSheet.show(
          context: context,
          onViewReservations: () {
            Navigator.of(context).pushNamedAndRemoveUntil(
              '/main',
              (route) => false,
              arguments: {
                'initialIndex': 2, // 마이페이지 탭
                'highlightReservation': {
                  'reservationId': created.id,
                  'courseId': created.courseId,
                  'dayOfWeek': created.dayOfWeek,
                  'startTime': created.startTime,
                  'reservedDate': created.reservedDate,
                  'shouldShowBottomSheet': true, // 명시적 클릭이므로 바텀시트 표시
                },
              },
            );
          },
          onClose: () {
            if (!mounted) return;
            setState(() {});
          },
        );
        return;
      }

      // cancel 성공/실패: MainScreen에서 단일 구독으로 스낵바 + 데이터 갱신 처리

      // move 성공 시: 바텀시트가 닫혀 있어도 결과 피드백 + 상태 갱신
      if (event.type == ReservationOperationType.move &&
          event.success == true &&
          event.reservation != null) {
        if (!mounted) return;
        final r = event.reservation!;
        try {
          // 이동 후 목록/세션 정보가 즉시 반영되도록 재구독(이미 구독 중이면 내부에서 noop)
          await Provider.of<ReservationProvider>(
            context,
            listen: false,
          ).loadUserReservations(userId: r.userId, placeId: r.placeId);
        } catch (_) {}
        SnackbarUtil.showSuccess(context, '예약을 변경했습니다.');
        if (!mounted) return;
        setState(() {});
      }

      // move 실패 시: 바텀시트가 닫혀 있어도 즉시 피드백 (유저친화 문구만 스낵바, 상세는 디버그)
      if (event.type == ReservationOperationType.move &&
          event.success == false) {
        if (!mounted) return;
        debugPrint('[CalendarScreen] 예약 변경 실패: ${event.error}');
        SnackbarUtil.showInfo(context, '예약 변경에 실패했습니다.');
        if (!mounted) return;
        setState(() {});
      }
    });
  }

  /// 정책 기반 주차 범위 계산. 이번 주(0)는 항상 탭에 포함.
  void _updateAvailableWeekOffsets(CoursePolicy policy) {
    final baseOffsets = WeekRangeCalculator.getAvailableWeekOffsets(policy);
    final now = TimezoneUtils.getSeoulDateTime();
    final thisWeekMonday = CalendarUtils.startOfWeekMonday(now);

    // highlightSession의 주차도 포함 (새 수업 일정 알림 등)
    final highlightOffsets = <int>{};
    final hl = widget.highlightSession;
    if (hl != null) {
      final dateStr = hl['date'] as String?;
      if (dateStr != null && dateStr.isNotEmpty) {
        try {
          final target = DateTime.parse(dateStr);
          final diffDays =
              CalendarUtils.startOfWeekMonday(
                target,
              ).difference(thisWeekMonday).inDays;
          final weekOffset = (diffDays / 7).round();
          if (weekOffset >= 0) highlightOffsets.add(weekOffset);
        } catch (_) {}
      }
    }

    var sortedOffsets =
        <int>{0, ...baseOffsets, ...highlightOffsets}.toList()..sort();

    // 빈 리스트 방지 (clamp(0, -1) 예외 방지)
    if (sortedOffsets.isEmpty) {
      sortedOffsets = [0];
    }

    var didChangeWeek = false;
    setState(() {
      _availableWeekOffsets = sortedOffsets;
      // 선택된 주가 범위를 벗어나면 마지막 탭으로
      if (_availableWeekOffsets.isNotEmpty &&
          _weekOffset > _availableWeekOffsets.last) {
        _weekOffset = _availableWeekOffsets.last;
        didChangeWeek = true;
      }
    });
    if (didChangeWeek && mounted) {
      _updateProviderContext();
    }
  }

  void _ensureUserDataLoaded() {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final placeId =
        Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id;
    final userId = authProvider.currentUser?.userId;
    if (userId == null) return;

    if (placeId != null) {
      Provider.of<ReservationProvider>(
        context,
        listen: false,
      ).loadUserReservations(userId: userId, placeId: placeId);
    }

    if (placeId != null) {
      Provider.of<EnrollmentProvider>(
        context,
        listen: false,
      ).loadUserEnrollments(userId: userId, placeId: placeId);
    }
  }

  String _formatCloseBefore(int minutes) {
    if (minutes >= 60) {
      final h = minutes ~/ 60;
      final m = minutes % 60;
      if (m == 0) return '${h}시간';
      return '${h}시간 ${m}분';
    }
    return '${minutes}분';
  }

  void _updateProviderContext() {
    if (!mounted) return;
    final placeId =
        Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id;

    final now = TimezoneUtils.getSeoulDateTime();
    final maxOffset =
        _availableWeekOffsets.isNotEmpty ? _availableWeekOffsets.last : 2;
    // 전체 주차 범위 (이번주 월 ~ 마지막주 일) 한 번에 구독 → 처음 열 때부터 모든 주차/세션 채움
    final firstWeekStart = CalendarUtils.weekStartFrom(now, 0);
    final lastWeekStart = CalendarUtils.weekStartFrom(now, maxOffset);
    final startDate = DateTime(
      firstWeekStart.year,
      firstWeekStart.month,
      firstWeekStart.day,
    );
    final endDate = lastWeekStart.add(const Duration(days: 6));
    final firstWeekStartDateString = CalendarUtils.formatDateYMD(
      firstWeekStart,
    );

    final summaryProvider = Provider.of<ReservationSummaryProvider>(
      context,
      listen: false,
    );
    _summaryProvider = summaryProvider;
    summaryProvider.setContext(
      placeId: placeId,
      courseId: course.id,
      startDate: startDate,
      endDate: endDate,
      weekStartDate: firstWeekStartDateString,
    );

    // CourseProvider 단일 구독 → 모든 주차 overrides + slots 전달
    if (placeId != null && placeId.isNotEmpty) {
      final courseProvider = Provider.of<CourseProvider>(
        context,
        listen: false,
      );
      final weekStartDates =
          _availableWeekOffsets
              .map(
                (o) => CalendarUtils.formatDateYMD(
                  CalendarUtils.weekStartFrom(now, o),
                ),
              )
              .toList();
      courseProvider.subscribeToOverrides(placeId, weekStartDates);

      for (final wo in _availableWeekOffsets) {
        final weekStart = CalendarUtils.weekStartFrom(now, wo);
        final ws = DateTime(weekStart.year, weekStart.month, weekStart.day);
        final weekStartDateString = CalendarUtils.formatDateYMD(weekStart);
        final overridesForCourse =
            courseProvider
                .getOverridesForWeek(weekStartDateString)
                .where((o) => o.courseId == course.id)
                .toList();
        summaryProvider.updateOverridesForWeek(
          weekStartDateString,
          overridesForCourse,
        );
        final byDate = <String, List<CourseOverride>>{};
        for (final o in overridesForCourse) {
          byDate.putIfAbsent(o.date, () => <CourseOverride>[]).add(o);
        }
        final slotList = SessionSlotBuilder.buildSlotsForWeek(
          placeId: placeId,
          course: course,
          startDate: ws,
          overridesByDate: byDate,
          getCapacityOverride: summaryProvider.getCapacityOverride,
        );
        summaryProvider.updateSessionSlots(weekStartDateString, slotList);
      }
    }
  }

  String _getErrorType(dynamic error) {
    if (error is FirebaseException) {
      return error.code;
    }
    final errorString = error.toString().toLowerCase();
    if (errorString.contains('permission-denied') ||
        errorString.contains('permission_denied')) {
      return 'permission-denied';
    }
    if (errorString.contains('network') || errorString.contains('connection')) {
      return 'network';
    }
    if (errorString.contains('timeout')) {
      return 'timeout';
    }
    return 'unknown';
  }

  String _getErrorMessage(dynamic error) {
    if (error is FirebaseException) {
      switch (error.code) {
        case 'failed-precondition':
          return '일시적인 설정 문제로 데이터를 불러올 수 없어요.\n잠시 후 다시 시도해주세요.\n\n문제가 계속되면 관리자에게 문의해주세요.';
        case 'permission-denied':
          return '접근 권한이 없어요.\n관리자에게 문의해주세요.';
        case 'unavailable':
          return '연결 상태가 불안정해요.\n인터넷 연결을 확인해주세요.';
        case 'deadline-exceeded':
          return '요청이 지연되고 있어요.\n잠시 후 다시 시도해주세요.';
        case 'resource-exhausted':
          return '잠시 이용이 몰리고 있어요.\n잠시 후 다시 시도해주세요.';
        case 'internal':
          return '일시적인 오류가 발생했어요.\n잠시 후 다시 시도해주세요.';
        default:
          return '데이터를 불러올 수 없어요.\n잠시 후 다시 시도해주세요.';
      }
    }
    final errorString = error.toString().toLowerCase();
    if (errorString.contains('network') || errorString.contains('connection')) {
      return '인터넷 연결을 확인해주세요.\n잠시 후 다시 시도해주세요.';
    }
    if (errorString.contains('timeout')) {
      return '요청이 지연되고 있어요.\n잠시 후 다시 시도해주세요.';
    }
    return '예상치 못한 오류가 발생했습니다.\n잠시 후 다시 시도해주세요.';
  }

  @override
  Widget build(BuildContext context) {
    // 예약 목록(내 예약 여부)·처리 중 상태용 (세션 박스 N/M은 ReservationSummaryProvider만 사용)
    Provider.of<ReservationProvider>(context);
    context.watch<CourseProvider>(); // 주차 오픈·비정기 일정 갱신 시 리빌드
    context
        .watch<
          EnrollmentProvider
        >(); // enrollment 로드 후 잠금 해제(noCreditsOrExpired → 예약 가능) 리빌드

    // 세션 박스·그리드 UI는 ReservationSummaryProvider 단일 구독 (setContext·overrides 갱신은 initState postFrameCallback·주차 변경 시 _updateProviderContext()에서만 호출)
    final srProvider = context.watch<ReservationSummaryProvider>();

    // context 설정 + overrides/slots 반영. 에러 UI일 때는 호출하지 않음 → 무한 리빌드 방지
    if (_errorMessage == null && _errorType == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateProviderContext();
      });
    }

    final overridesByDate = srProvider.overridesByDate;
    final providerLoading = srProvider.isLoading;
    final providerError = srProvider.error;

    _recomputeLoadingFromProvider(providerLoading);
    if (_errorMessage !=
        (providerError != null ? _getErrorMessage(providerError) : null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _errorMessage =
                providerError != null ? _getErrorMessage(providerError) : null;
            _errorType =
                providerError != null ? _getErrorType(providerError) : null;
          });
        }
      });
    }

    // 해당 코스의 세션이 있는 요일들만 가져오기 (정기)
    final availableDays = course.availableDays;

    // 현재 주의 날짜들 계산 (주간 오프셋 적용, 이번주~다다음주만 / 월요일 기준)
    final now = TimezoneUtils.getSeoulDateTime();
    // 정책 기반 주차 범위 내에서만 선택 가능
    final weekOffset = _weekOffset.clamp(
      0,
      _availableWeekOffsets.isNotEmpty ? _availableWeekOffsets.last : 2,
    );
    final weekStart = CalendarUtils.weekStartFrom(now, weekOffset);
    final weekDates = List.generate(
      7,
      (index) => weekStart.add(Duration(days: index)),
    );

    // 월~금은 항상 표시, 토·일은 세션이 있을 때만 동적 추가
    final sessionDates =
        weekDates.where((date) {
          final w = date.weekday;
          if (w >= DateTime.monday && w <= DateTime.friday) {
            return true; // 월화수목금 항상
          }
          // 토(6), 일(7): 정기 또는 비정기 세션이 있는 경우만
          return availableDays.contains(w) ||
              _hasAddedOverrideSessionsForDate(date, overridesByDate);
        }).toList();

    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
        backgroundColor: AppColors.backgroundWhite,
        centerTitle: false,
        elevation: 0,
        title: Row(
          children: [
            GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Icon(Icons.arrow_back_ios, color: AppColors.textPrimary),
            ),
            Expanded(
              child: WeekTabBar(
                selectedIndex:
                    _availableWeekOffsets.isEmpty
                        ? 0
                        : _availableWeekOffsets
                            .indexOf(_weekOffset)
                            .clamp(0, _availableWeekOffsets.length - 1),
                onTabChanged: (index) {
                  if (index < _availableWeekOffsets.length) {
                    setState(() {
                      _weekOffset = _availableWeekOffsets[index];
                      _didInitialJump = false;
                    });
                    // 주차 전환 시 재구독 안 함 (전체 범위 이미 로드됨)
                  }
                },
                availableWeekOffsets: _availableWeekOffsets,
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          const SizedBox(height: 6),
          Expanded(
            child:
                (_errorMessage != null || _errorType != null)
                    ? _buildErrorWidget()
                    : GestureDetector(
                      onHorizontalDragEnd: (details) {
                        // 스와이프 방향에 따라 주간 이동
                        final currentIndex = _availableWeekOffsets.indexOf(
                          _weekOffset,
                        );
                        if (details.primaryVelocity! > 0) {
                          // 오른쪽으로 스와이프 (저번주로)
                          if (currentIndex > 0) {
                            setState(() {
                              _weekOffset =
                                  _availableWeekOffsets[currentIndex - 1];
                              _didInitialJump = false;
                            });
                            // 주차 전환 시 재구독 안 함 (전체 범위 이미 로드됨)
                          }
                        } else if (details.primaryVelocity! < 0) {
                          // 왼쪽으로 스와이프 (다음주로)
                          if (currentIndex < _availableWeekOffsets.length - 1) {
                            setState(() {
                              _weekOffset =
                                  _availableWeekOffsets[currentIndex + 1];
                              _didInitialJump = false;
                            });
                            // 주차 전환 시 재구독 안 함 (전체 범위 이미 로드됨)
                          }
                        }
                      },
                      child: Column(
                        children: [
                          // 요일 헤더
                          _buildDayHeaders(sessionDates),

                          // ReservationSummaryProvider 스트림 기반 → 주차 변경 시 그리드 페이드인
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                return AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 200),
                                  switchInCurve: Curves.easeIn,
                                  child: KeyedSubtree(
                                    key: ValueKey('grid_$_weekOffset'),
                                    child: _buildCalendarGrid(
                                      sessionDates,
                                      overridesByDate: overridesByDate,
                                      viewportHeight: constraints.maxHeight,
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
    );
  }

  // 요일 헤더
  Widget _buildDayHeaders(List<DateTime> dates) {
    const dayNames = ['', '월', '화', '수', '목', '금', '토', '일'];

    return Container(
      color: AppColors.backgroundWhite,
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Row(
        children: [
          // 시간대 컬럼 (빈 공간)
          SizedBox(width: _timeColumnWidth, child: Container()),
          // 각 날짜 헤더 (중앙 정렬)
          ...dates.map((date) {
            return Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      dayNames[date.weekday],
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w400,
                        color: AppColors.textSecondary,
                      ),
                    ),

                    Text(
                      '${date.month}/${date.day}',
                      style: TextStyle(
                        letterSpacing: 2,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary.withOpacity(0.9),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
          // 시간대 컬럼 (빈 공간)
          SizedBox(width: _gridRightPadding, child: Container()),
          // 시간대 컬럼 (빈 공간)
        ],
      ),
    );
  }

  _SmartRange _computeSmartRange({
    required List<DateTime> dates,
    required Map<String, List<CourseOverride>> overridesByDate,
    double? viewportHeight,
  }) {
    // 해당 컬럼(날짜들)에서 실제로 표시될 세션(정기+비정기) 기준으로 범위 계산
    final sessions = _effectiveSessionsForDates(dates, overridesByDate);

    if (sessions.isEmpty) {
      final slotCount = 9;
      final h =
          viewportHeight != null
              ? ((viewportHeight + _scrollBuffer(viewportHeight)) / slotCount)
                  .clamp(_minHourSlotHeight, double.infinity)
              : _minHourSlotHeight;
      return _SmartRange(
        rangeStartMinutes: 9 * 60,
        rangeEndMinutes: 18 * 60,
        startHour: 9,
        endHour: 18,
        slotCount: slotCount,
        hourSlotHeight: h,
      );
    }

    final starts = sessions.map(
      (s) => CalendarUtils.parseTimeToMinutes(s.startTime),
    );
    final ends = sessions.map(
      (s) => CalendarUtils.parseTimeToMinutes(s.endTime),
    );
    final minStart = starts.reduce((a, b) => a < b ? a : b);
    final maxEnd = ends.reduce((a, b) => a > b ? a : b);

    // 세션 지속 시간을 기반으로 동적 최적 높이 계산
    double maxSessionDuration = 0;
    for (final session in sessions) {
      final start = CalendarUtils.parseTimeToMinutes(session.startTime);
      final end = CalendarUtils.parseTimeToMinutes(session.endTime);
      if (end > start) {
        final duration = end - start;
        if (duration > maxSessionDuration) {
          maxSessionDuration = duration.toDouble();
        }
      }
    }

    // 2시간 여백 + 시간 단위 정렬 + 경계 여백 (먼저 범위 계산)
    var rangeStart = _floorToHour(
      (minStart - _basePaddingMinutes).clamp(0, 24 * 60),
    );
    var rangeEnd = _ceilToHour(
      (maxEnd + _basePaddingMinutes).clamp(0, 24 * 60),
    );

    // 00시 경계에 여백 추가
    if (rangeStart == 0) {
      rangeStart = 0;
    } else if (rangeStart < _edgePaddingMinutes) {
      rangeStart = 0;
    }

    // 23시 경계에 여백 추가
    if (rangeEnd >= 24 * 60 - _edgePaddingMinutes) {
      rangeEnd = 24 * 60;
    }

    if (rangeEnd <= rangeStart) {
      rangeEnd = (rangeStart + 60).clamp(0, 24 * 60);
    }

    int slotCount = (rangeEnd - rangeStart) ~/ 60;

    // 뷰포트 고려 + 약간의 위아래 스크롤 여유
    final double hourSlotHeight;
    if (viewportHeight != null && slotCount > 0) {
      final buffer = _scrollBuffer(viewportHeight);
      final targetHeight = viewportHeight + buffer;
      hourSlotHeight = (targetHeight / slotCount).clamp(
        _minHourSlotHeight,
        double.infinity,
      );
    } else {
      hourSlotHeight =
          maxSessionDuration > 0
              ? (maxSessionDuration * _optimalPxPerMinute / 60.0).clamp(
                _minHourSlotHeight,
                double.infinity,
              )
              : _minHourSlotHeight;
    }

    final startHour = rangeStart ~/ 60;
    final endHour = rangeEnd ~/ 60;
    return _SmartRange(
      rangeStartMinutes: rangeStart,
      rangeEndMinutes: rangeEnd,
      startHour: startHour,
      endHour: endHour,
      slotCount: slotCount,
      hourSlotHeight: hourSlotHeight,
    );
  }

  _SlotLayout _buildSlotLayout({
    required List<DateTime> dates,
    required Map<String, List<CourseOverride>> overridesByDate,
    required _SmartRange smart,
    double? viewportHeight,
  }) {
    final rangeStartMinutes = smart.rangeStartMinutes;
    final rangeEndMinutes = smart.rangeEndMinutes;
    final hourSlotCount = ((rangeEndMinutes - rangeStartMinutes) / 60).round();

    // 표시되는 날짜들에 해당하는 세션(정기+비정기)을 모아 "활성 시간대"를 계산
    final sessions = _effectiveSessionsForDates(dates, overridesByDate);

    // 1) 60분 슬롯별 active 여부 계산
    final activePerHour = List<bool>.filled(hourSlotCount, false);
    int? minSessionStart;
    for (final s in sessions) {
      final start = CalendarUtils.parseTimeToMinutes(s.startTime);
      final end = CalendarUtils.parseTimeToMinutes(s.endTime);
      if (end <= start) continue;
      minSessionStart =
          minSessionStart == null
              ? start
              : (start < minSessionStart ? start : minSessionStart);
      for (int i = 0; i < hourSlotCount; i++) {
        final slotStart = rangeStartMinutes + (i * 60);
        final slotEnd = slotStart + 60;
        if (start < slotEnd && end > slotStart) activePerHour[i] = true;
      }
    }

    // 2) raw 슬롯 생성
    final rawSlots = <_CalendarTimeSlot>[];
    for (int i = 0; i < hourSlotCount; i++) {
      final startMinute = rangeStartMinutes + (i * 60);
      final endMinute = startMinute + 60;
      final hour = (startMinute ~/ 60) % 24;
      rawSlots.add(
        _CalendarTimeSlot(
          startMinute: startMinute,
          endMinute: endMinute,
          label: '${hour.toString().padLeft(2, '0')}:00',
          isActive: activePerHour[i],
          isMergedGap: false,
        ),
      );
    }

    // 3) 긴 공백(연속 inactive >= 3시간)을 하나로 합치기
    final slots = <_CalendarTimeSlot>[];
    int i = 0;
    while (i < rawSlots.length) {
      final slot = rawSlots[i];
      if (slot.isActive) {
        slots.add(slot);
        i++;
        continue;
      }
      int j = i;
      while (j < rawSlots.length && !rawSlots[j].isActive) j++;
      final gapHours = j - i;
      if (gapHours >= _mergeGapMinHours) {
        slots.add(
          _CalendarTimeSlot(
            startMinute: rawSlots[i].startMinute,
            endMinute: rawSlots[j - 1].endMinute,
            label: '…',
            isActive: false,
            isMergedGap: true,
          ),
        );
      } else {
        for (int k = i; k < j; k++) slots.add(rawSlots[k]);
      }
      i = j;
    }

    // 4) 슬롯별 높이 할당 (병합 공백은 시간 길이에 비례해 시각화)
    final baseSlotHeight = smart.hourSlotHeight;
    final slotHeights = List<double>.filled(slots.length, baseSlotHeight);
    for (int idx = 0; idx < slots.length; idx++) {
      final s = slots[idx];
      if (s.isActive) {
        slotHeights[idx] = baseSlotHeight;
      } else if (s.isMergedGap) {
        final gapHours = ((s.endMinute - s.startMinute) / 60).round().clamp(
          1,
          24,
        );
        slotHeights[idx] = (_mergedGapPxPerHour * gapHours).clamp(
          _mergedGapSlotHeight,
          baseSlotHeight * gapHours * 0.6,
        );
      } else {
        slotHeights[idx] = _minGapHourSlotHeight;
      }
    }

    // 5) viewport에 맞춰 조절 — 화면 전체 높이를 채우고 약간의 스크롤 유지
    if (viewportHeight != null && viewportHeight > 0) {
      final buffer = _scrollBuffer(viewportHeight);
      final targetHeight = viewportHeight + buffer;
      double currentTotal = slotHeights.fold<double>(0.0, (a, b) => a + b);
      if (currentTotal > targetHeight) {
        // 콘텐츠가 더 크면 축소
        for (
          int idx = 0;
          idx < slots.length && currentTotal > targetHeight;
          idx++
        ) {
          if (slots[idx].isMergedGap &&
              slotHeights[idx] > _mergedGapSlotHeight) {
            final reduce = (currentTotal - targetHeight).clamp(
              0.0,
              slotHeights[idx] - _mergedGapSlotHeight,
            );
            slotHeights[idx] -= reduce;
            currentTotal -= reduce;
          }
        }
        for (
          int idx = 0;
          idx < slots.length && currentTotal > targetHeight;
          idx++
        ) {
          if (!slots[idx].isActive &&
              !slots[idx].isMergedGap &&
              slotHeights[idx] > _minGapHourSlotHeight) {
            final reduce = (currentTotal - targetHeight).clamp(
              0.0,
              slotHeights[idx] - _minGapHourSlotHeight,
            );
            slotHeights[idx] -= reduce;
            currentTotal -= reduce;
          }
        }
      } else if (currentTotal < targetHeight && currentTotal > 0) {
        // 콘텐츠가 더 작으면 확장. 세션 없는 부분(공백/병합)에 여분을 더 분배
        final extra = targetHeight - currentTotal;
        final gapTotal = slots
            .asMap()
            .entries
            .where((e) => !e.value.isActive)
            .fold<double>(0.0, (sum, e) => sum + slotHeights[e.key]);
        if (gapTotal > 0) {
          final gapScale = 1.0 + (extra / gapTotal);
          for (int idx = 0; idx < slots.length; idx++) {
            if (!slots[idx].isActive) {
              slotHeights[idx] *= gapScale;
            }
          }
        } else {
          final scale = targetHeight / currentTotal;
          for (int idx = 0; idx < slotHeights.length; idx++) {
            slotHeights[idx] *= scale;
          }
        }
      }
    }

    // prefix sum (slotTops)
    final slotTops = List<double>.filled(slots.length + 1, 0.0);
    for (int idx = 0; idx < slots.length; idx++) {
      slotTops[idx + 1] = slotTops[idx] + slotHeights[idx];
    }

    final timeSlots = slots.map((s) => s.label).toList();
    final active = slots.map((s) => s.isActive).toList();

    // 초기 점프 위치: highlightSession 있으면 해당 세션, 없으면 첫 세션 - 2시간
    int jumpMinute = rangeStartMinutes;
    final hl = widget.highlightSession;
    if (hl != null) {
      final startTime = hl['startTime'] as String?;
      if (startTime != null && startTime.isNotEmpty) {
        try {
          final m = CalendarUtils.parseTimeToMinutes(startTime);
          jumpMinute = (m - _basePaddingMinutes).clamp(
            rangeStartMinutes,
            rangeEndMinutes,
          );
        } catch (_) {}
      }
    }
    if (jumpMinute == rangeStartMinutes && minSessionStart != null) {
      jumpMinute = (minSessionStart - _basePaddingMinutes).clamp(
        rangeStartMinutes,
        rangeEndMinutes,
      );
    }
    final initialJumpMinute = jumpMinute;

    return _SlotLayout(
      slots: slots,
      timeSlots: timeSlots,
      slotHeights: slotHeights,
      slotTops: slotTops,
      rangeStartMinutes: rangeStartMinutes,
      initialJumpMinute: initialJumpMinute,
      isActive: active,
      isMergedGap: slots.map((s) => s.isMergedGap).toList(),
    );
  }

  /// 뷰포트 대비 콘텐츠 높이 여유. 시간축은 화면 전체에 보이되, 항상 조금의 스크롤 유지
  static double _scrollBuffer(double viewportHeight) =>
      (_minHourSlotHeight * 1.5).clamp(60.0, 100.0);

  // 캘린더 그리드 (뷰포트 고려 + 약간의 위아래 스크롤 여유)
  Widget _buildCalendarGrid(
    List<DateTime> dates, {
    required Map<String, List<CourseOverride>> overridesByDate,
    double? viewportHeight,
  }) {
    final smart = _computeSmartRange(
      dates: dates,
      overridesByDate: overridesByDate,
      viewportHeight: viewportHeight,
    );
    final layout = _buildSlotLayout(
      dates: dates,
      overridesByDate: overridesByDate,
      smart: smart,
      viewportHeight: viewportHeight,
    );

    // 진입 즉시 "세션 구간"을 최상단으로 보이게
    if (!_didInitialJump) {
      _didInitialJump = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // 여러 스크롤 뷰에 연결된 경우 사용 금지 (AnimatedSwitcher 전환 중 등)
        if (_scrollController.hasClients &&
            _scrollController.positions.length == 1) {
          final targetMinute = layout.initialJumpMinute;
          final targetY = layout.yForMinute(targetMinute);
          final pos = _scrollController.position;
          _scrollController.jumpTo(targetY.clamp(0.0, pos.maxScrollExtent));
        }
      });
    }

    return Container(
      color: AppColors.backgroundWhite,
      child: SingleChildScrollView(
        controller: _scrollController,
        child: Padding(
          padding: const EdgeInsets.only(right: _gridRightPadding),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 시간대 컬럼
              SizedBox(
                width: _timeColumnWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children:
                      layout.timeSlots.asMap().entries.map((entry) {
                        final idx = entry.key;
                        final time = entry.value;
                        final hour =
                            time.contains(':')
                                ? time.split(':')[0]
                                : time; // "17:00" -> "17", "…" -> "…"
                        final isActiveSlot = layout.isActive[idx];
                        final isMergedGap = layout.isMergedGap[idx];
                        return Container(
                          height: layout.slotHeights[idx],
                          alignment: Alignment.topRight,
                          padding: EdgeInsets.only(
                            right: _timeTextPaddingRight,
                            top: 0,
                          ),
                          child: Text(
                            hour,
                            style: TextStyle(
                              fontSize:
                                  isMergedGap ? 14 : (isActiveSlot ? 16 : 13),
                              fontWeight:
                                  isActiveSlot
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                              color:
                                  isActiveSlot
                                      ? AppColors.textSecondary
                                      : AppColors.textSecondary.withOpacity(
                                        isMergedGap ? 0.5 : 0.4,
                                      ),
                              height: 1.0,
                            ),
                          ),
                        );
                      }).toList(),
                ),
              ),
              // 각 날짜 컬럼
              ...dates.asMap().entries.map((entry) {
                final index = entry.key;
                final date = entry.value;
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: index > 0 ? _dateColumnSpacing : 0,
                    ),
                    child: _buildDayColumn(
                      date,
                      overridesByDate: overridesByDate,
                      timeSlots: layout.timeSlots,
                      rangeStartMinutes: smart.rangeStartMinutes,
                      slotTops: layout.slotTops,
                      slotHeights: layout.slotHeights,
                      yForMinute: layout.yForMinute,
                      isActive: layout.isActive,
                      isMergedGap: layout.isMergedGap,
                    ),
                  ),
                );
              }).toList(),
            ],
          ),
        ),
      ),
    );
  }

  // 날짜별 컬럼
  Widget _buildDayColumn(
    DateTime date, {
    required Map<String, List<CourseOverride>> overridesByDate,
    required List<String> timeSlots,
    required int rangeStartMinutes,
    required List<double> slotTops,
    required List<double> slotHeights,
    required double Function(int minute) yForMinute,
    required List<bool> isActive,
    required List<bool> isMergedGap,
  }) {
    final daySessions = _effectiveSessionsForDate(date, overridesByDate);

    // 세션이 시작하는 시간대만 찾기 (연속 세션은 하나의 위젯으로 그리기 위해)
    final sessionStartSlots = <String, CourseSession>{};

    for (final session in daySessions) {
      final sessionStartMinutes = CalendarUtils.parseTimeToMinutes(
        session.startTime,
      );
      final sessionStartHour = sessionStartMinutes ~/ 60;
      final startTimeSlot = '${sessionStartHour.toString().padLeft(2, '0')}:00';

      // 세션이 시작하는 시간대 찾기
      if (timeSlots.contains(startTimeSlot)) {
        // 이미 다른 세션이 있으면 시작 시간이 더 빠른 세션 우선
        if (!sessionStartSlots.containsKey(startTimeSlot) ||
            CalendarUtils.parseTimeToMinutes(
                  sessionStartSlots[startTimeSlot]!.startTime,
                ) >
                sessionStartMinutes) {
          sessionStartSlots[startTimeSlot] = session;
        }
      }
    }

    // 전체 컬럼 높이 계산 (모든 시간대의 높이 합)
    final totalHeight = slotTops.isNotEmpty ? slotTops.last : 0.0;

    return Container(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: AppColors.borderLight, width: 0.5),
        ),
      ),
      height: totalHeight,
      clipBehavior: Clip.none,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 시간대 구분선 (약간 아래로 이동)
          // 공백 구간은 더 연하게 표시
          ...timeSlots.asMap().entries.map((entry) {
            final index = entry.key;
            final isActiveSlot = isActive[index];
            final isMerged = isMergedGap[index];

            return Positioned(
              top: slotTops[index] + _lineOffset,
              left: 0,
              right: 0,
              child: Container(
                height: 0.5,
                color:
                    isActiveSlot
                        ? AppColors.borderLight
                        : AppColors.borderLight.withOpacity(
                          isMerged ? 0.12 : 0.2,
                        ),
              ),
            );
          }).toList(),
          // 세션 블록들 (각 세션을 하나의 연속된 위젯으로 그림)
          ...sessionStartSlots.entries.map((entry) {
            final timeSlot = entry.key;
            final session = entry.value;
            return _buildSessionBlock(
              session,
              date,
              startTimeSlot: timeSlot,
              rangeStartMinutes: rangeStartMinutes,
              yForMinute: yForMinute,
            );
          }).toList(),
        ],
      ),
    );
  }

  SessionReservation? _getUserReservationForSession({
    required List<SessionReservation> reservations,
    required CourseSession session,
    required DateTime date,
  }) {
    try {
      return reservations.firstWhere(
        (r) =>
            r.courseId == course.id &&
            r.dayOfWeek == session.dayOfWeek &&
            r.startTime == session.startTime &&
            r.reservedDate.year == date.year &&
            r.reservedDate.month == date.month &&
            r.reservedDate.day == date.day,
      );
    } catch (_) {
      return null;
    }
  }

  // 세션 블록 (하나의 연속된 위젯으로 그림)
  Widget _buildSessionBlock(
    CourseSession session,
    DateTime date, {
    required String startTimeSlot,
    required int rangeStartMinutes,
    required double Function(int minute) yForMinute,
  }) {
    // 세션의 실제 시작/끝 시간 (분 단위)
    final sessionStartMinutes = CalendarUtils.parseTimeToMinutes(
      session.startTime,
    );
    final sessionEndMinutes = CalendarUtils.parseTimeToMinutes(session.endTime);

    // 비선형(공백 압축) 포함한 위치/높이
    final topPosition = yForMinute(sessionStartMinutes) + _lineOffset;
    final sessionHeightPx = (yForMinute(sessionEndMinutes) -
            yForMinute(sessionStartMinutes))
        .clamp(0.0, double.infinity);

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final placeId =
        Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id;
    final userId = authProvider.currentUser?.userId;

    final reservationProvider = Provider.of<ReservationProvider>(
      context,
      listen: false,
    );
    final userReservation = _getUserReservationForSession(
      reservations: reservationProvider.reservations,
      session: session,
      date: date,
    );
    final hasUserReservation = userReservation != null;

    final enrollmentProvider = Provider.of<EnrollmentProvider>(
      context,
      listen: false,
    );
    final CourseEnrollment? enrollment =
        enrollmentProvider.enrollmentsByCourseId[course.id];
    final isEnrolled = enrollment != null;
    final enrollmentCanReserve =
        enrollment?.canReserveForSessionDate(date) ?? false;

    // 디버그: noCreditsOrExpired 원인 (코스 불일치 vs 만료/0회)
    if (kDebugMode && userId != null && !enrollmentCanReserve) {
      if (enrollment == null) {
        debugPrint(
          '[CalendarScreen] enrollment null for courseId=${course.id}; '
          'enrolledCourseIds=${enrollmentProvider.enrollmentsByCourseId.keys.join(', ')}',
        );
      } else {
        final todaySeoul = TimezoneUtils.getSeoulToday();
        final vf = enrollment.validFrom;
        final vu = enrollment.validUntil;
        final vfSeoul = TimezoneUtils.getSeoulDateOnly(vf);
        final vuSeoul = TimezoneUtils.getSeoulDateOnly(vu);
        debugPrint(
          '[CalendarScreen] courseId=${course.id} canReserve=false '
          'isValid=${enrollment.isValid} remaining=${enrollment.remainingReservations} '
          'todaySeoul=$todaySeoul '
          'validFrom=$vf (utc=${vf.toUtc()}) seoulDateOnly=$vfSeoul '
          'validUntil=$vu (utc=${vu.toUtc()}) seoulDateOnly=$vuSeoul',
        );
      }
    }

    final policy = _coursePolicy ?? CoursePolicy.defaultValue;

    // 예약 현황(N/M, 정원)은 ReservationSummaryProvider 단일 소스 (compact_calendar와 동일 방식)
    final srProvider = Provider.of<ReservationSummaryProvider>(
      context,
      listen: false,
    );
    final sessionId = SessionReservationSummary.generateSessionId(
      course.id,
      session.dayOfWeek,
      session.startTime,
    );
    final dateString = CalendarUtils.formatDateYMD(date);
    final sr = srProvider.getSessionReservationSummary(sessionId, dateString);
    final totalSeats = srProvider.getTotalCapacity(
      sessionId,
      dateString,
      fallback: session.capacity,
    );
    final reservedCount = sr?.reservedCount ?? 0;
    final reservedCountDisplay = srProvider.getReservedCountDisplayString(
      sessionId,
      dateString,
    );
    final remainingSeats = (totalSeats - reservedCount).clamp(0, 1 << 30);

    final eligibility = ReservationPolicyEngine.evaluateReservation(
      now: TimezoneUtils.getSeoulDateTime(),
      policy: policy,
      sessionDate: date,
      startTime: session.startTime,
      capacity: totalSeats,
      reservedCount: reservedCount,
      enrollmentCanReserve: enrollmentCanReserve,
    );

    final effectiveCanReserve = eligibility.canReserve;
    final isLocked = !effectiveCanReserve || !isEnrolled || userId == null;
    final isMyReserved = hasUserReservation;
    final canReserve = !isLocked && !isMyReserved;

    // 이미 예약된 세션은 "연하게(비활성 느낌)" 보이되,
    // 잠김(정책/권한/만석 등)과는 구분해서 표시한다.
    final String? pidForKey = placeId;
    final processingKey =
        pidForKey == null
            ? null
            : reservationProvider.operationKeyFromParts(
              placeId: pidForKey,
              courseId: course.id,
              dayOfWeek: session.dayOfWeek,
              startTime: session.startTime,
              date: date,
            );
    final isProcessing =
        processingKey != null &&
        reservationProvider.isOperationInFlightByKey(processingKey);

    final blockType =
        isProcessing
            ? SessionBlockType.processing
            : isMyReserved
            ? SessionBlockType.reserved
            : isLocked
            ? SessionBlockType.locked
            : SessionBlockType.available;
    final blockStyle = SessionBlockStyle.fromType(
      blockType,
      courseColor: course.colorValue,
    );

    // 예약 불가(잠긴) 세션은 박스 숨김 — 단, 본인 예약은 취소를 위해 표시
    if (isLocked && !hasUserReservation) {
      return Positioned(
        top: topPosition,
        left: _sessionPadding,
        right: _sessionPadding,
        height: sessionHeightPx,
        child: const SizedBox.shrink(),
      );
    }

    return Positioned(
      top: topPosition,
      left: _sessionPadding,
      right: _sessionPadding,
      height: sessionHeightPx,
      child: GestureDetector(
        onTap: () async {
          if (isProcessing) {
            SnackbarUtil.showInfo(context, '처리 중입니다. 잠시만 기다려주세요.');
            return;
          }

          // ✅ Apple App Store 가이드라인 5.1.1 준수: 세션 클릭 시 로그인 체크
          // 세션 브라우징은 로그인 없이 가능하지만, 예약/취소 등 계정 기반 기능은 로그인 필요
          final String? pid = placeId;
          final String? uid = userId;
          final bool isLoggedIn = pid != null && uid != null;

          if (!isLoggedIn) {
            // 로그인 안 된 경우 로그인 다이얼로그 표시
            final confirmed = await CommonDialog.show(
              context: context,
              title: '로그인이 필요합니다',
              message: '예약 하려면 로그인이 필요합니다.\n로그인하시겠습니까?',
              cancelText: '취소',
              confirmText: '로그인하기',
            );

            if (confirmed == true) {
              // 로그인 화면으로 이동
              Navigator.of(context).pushNamed('/phone-number');
            }
            return;
          }

          if (hasUserReservation) {
            // 사용자가 예약한 경우 예약 취소 바텀시트 표시
            UserReservationManageBottomSheet.show(
              context: context,
              course: course,
              session: session,
              date: date,
              reservation: userReservation,
              onReservationCancelled: () {
                if (!mounted) return;
                setState(() {});
              },
            );
            return;
          }

          if (canReserve) {
            final reservation = SessionReservation(
              id: '',
              userId: uid,
              courseId: course.id,
              placeId: pid,
              dayOfWeek: session.dayOfWeek,
              startTime: session.startTime,
              reservedAt: TimezoneUtils.getSeoulDateTime(),
              reservedDate: date,
            );
            final rp = Provider.of<ReservationProvider>(context, listen: false);
            final isAdminForPlace =
                placeId != null &&
                authProvider.hasAdminAccessToPlace(placeId);

            try {
              await SessionReservationBottomSheet.show(
                context: context,
                activityName: course.name,
                date: '${session.dayName}요일 ${date.day}일',
                startTime: session.startTime,
                endTime: session.endTime,
                availableSeats: remainingSeats,
                totalSeats: totalSeats,
                remainingSessionReservations: enrollment.remainingReservations,
                course: course,
                onConfirm: () async => rp.createReservation(reservation),
                canForceAdd: isAdminForPlace,
                onForceConfirm:
                    isAdminForPlace
                        ? () async =>
                            rp.createReservation(reservation, force: true)
                        : null,
              );

              if (!mounted) return;
              setState(() {});
            } catch (e) {
              if (!mounted) return;
              // 예약 실패 시 에러 메시지는 ReservationBottomSheet에서 처리됨
              setState(() {});
            }
            return;
          }

          if (!isEnrolled) {
            SnackbarUtil.showInfo(context, '등록된 코스가 아닙니다.');
            return;
          }
          if (eligibility.reason == ReservationLockReason.notOpenedYet &&
              eligibility.openAt != null) {
            final t = eligibility.openAt!;
            SnackbarUtil.showInfo(
              context,
              '아직 예약 오픈 전입니다. (오픈 ${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')})',
            );
            return;
          }
          debugPrint('eligibility.reason: ${eligibility.reason}');
          // 지난 세션(날짜/시작시간 경과)은 항상 해당 메시지 우선 표시
          final today = TimezoneUtils.getSeoulToday();
          final sessionDateOnly = TimezoneUtils.getSeoulDateOnly(date);
          if (sessionDateOnly.isBefore(today)) {
            SnackbarUtil.showInfo(context, '지나간 세션은 예약할 수 없습니다.');
            return;
          }
          final sessionStart = TimezoneUtils.combineDateAndTimeSeoul(
            date,
            session.startTime,
          );
          if (!TimezoneUtils.getSeoulDateTime().isBefore(sessionStart)) {
            SnackbarUtil.showInfo(
              context,
              '세션 시작 ${_formatCloseBefore(policy.reserveCloseBeforeMinutes)} 전까지만 예약 가능합니다.',
            );
            return;
          }

          switch (eligibility.reason) {
            case ReservationLockReason.pastDate:
              SnackbarUtil.showInfo(context, '지나간 세션은 예약할 수 없습니다.');
              return;
            case ReservationLockReason.closedBeforeStart:
              SnackbarUtil.showInfo(
                context,
                '세션 시작 ${_formatCloseBefore(policy.reserveCloseBeforeMinutes)} 전까지만 예약 가능합니다.',
              );
              return;
            case ReservationLockReason.full:
              SnackbarUtil.showInfo(context, '예약 가능한 자리가 없습니다.');
              return;
            case ReservationLockReason.noCreditsOrExpired:
              if (kDebugMode) {
                final nowSeoul = TimezoneUtils.getSeoulDateTime();
                final todaySeoul = TimezoneUtils.getSeoulToday();
                final vf = enrollment.validFrom;
                final vu = enrollment.validUntil;
                debugPrint(
                  '[CalendarScreen] noCreditsOrExpired: nowSeoul=$nowSeoul todaySeoul=$todaySeoul '
                  'remaining=${enrollment.remainingReservations} '
                  'validFrom=$vf (seoulDateOnly=${TimezoneUtils.getSeoulDateOnly(vf)}) '
                  'validUntil=$vu (seoulDateOnly=${TimezoneUtils.getSeoulDateOnly(vu)}) '
                  'isValid=${enrollment.isValid} canReserve=${enrollment.canReserve}',
                );
              }
              if (enrollment.remainingReservations <= 0) {
                SnackbarUtil.showInfo(context, '예약 가능한 횟수가 없습니다.');
              } else if (!enrollment.isSessionDateWithinValidity(date)) {
                final sessionDateOnly = TimezoneUtils.getSeoulDateOnly(date);
                final vf = TimezoneUtils.getSeoulDateOnly(enrollment.validFrom);
                final vu = TimezoneUtils.getSeoulDateOnly(
                  enrollment.validUntil,
                );
                if (sessionDateOnly.isBefore(vf)) {
                  SnackbarUtil.showInfo(
                    context,
                    '수강 시작 전 날짜는 예약할 수 없습니다.',
                  );
                } else if (sessionDateOnly.isAfter(vu)) {
                  SnackbarUtil.showInfo(
                    context,
                    '수강 기간이 만료된 날짜는 예약할 수 없습니다.',
                  );
                } else {
                  SnackbarUtil.showInfo(context, '현재 예약할 수 없습니다.');
                }
              }
              return;
            case ReservationLockReason.notOpenedYet:
              SnackbarUtil.showInfo(context, '아직 예약 오픈 전입니다.');
              return;
            case ReservationLockReason.none:
              return;
          }
        },
        child: Container(
          padding: EdgeInsets.only(
            left: 6,
            top: sessionHeightPx >= 50 ? 6 : 4,
            right: 4,
            bottom: sessionHeightPx >= 50 ? 3 : 2,
          ),
          decoration: blockStyle.toBoxDecoration(),
          child: Stack(
            children: [
              // 로딩 중이 아닐 때만 텍스트 표시
              if (!isProcessing)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 코스 이름 (항상 표시, 간격 축소로 전체 표시)
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        course.name,
                        style: TextStyle(
                          color: blockStyle.textColor,
                          fontSize:
                              sessionHeightPx >= 60
                                  ? 20
                                  : (sessionHeightPx >= 40 ? 18 : 16),
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                      ),
                    ),

                    // 시간 (높이가 충분할 때만 표시, scaleDown으로 ellipsis 대신 축소)
                    if (sessionHeightPx >= 70) ...[
                      SizedBox(height: sessionHeightPx >= 80 ? 2 : 1),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '${session.startTime} - ${session.endTime}',
                          style: TextStyle(
                            color: blockStyle.iconColor,
                            fontSize: sessionHeightPx >= 90 ? 17 : 15,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                        ),
                      ),
                    ],

                    // 예약 현황 N/M (높이가 충분할 때 항상 표시, 정원 꽉 찼어도 유지)
                    if (sessionHeightPx >= 90) ...[
                      SizedBox(height: sessionHeightPx >= 100 ? 2 : 1),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '$reservedCountDisplay / $totalSeats',
                          style: TextStyle(
                            color: blockStyle.iconColor,
                            fontSize: sessionHeightPx >= 110 ? 18 : 16,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ],
                ),
              // 로딩 중일 때 중앙에 로딩 인디케이터와 텍스트 표시
              if (isProcessing)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: sessionHeightPx >= 50 ? 32 : 24,
                          height: sessionHeightPx >= 50 ? 32 : 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 3.0,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              blockStyle.iconColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (!hasUserReservation && isLocked)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Icon(
                    Icons.lock_rounded,
                    size: sessionHeightPx >= 60 ? 18 : 14,
                    color: blockStyle.iconColor,
                  ),
                ),
              if (!hasUserReservation &&
                  isLocked &&
                  eligibility.reason == ReservationLockReason.notOpenedYet &&
                  eligibility.openAt != null &&
                  sessionHeightPx >= 70)
                Positioned(
                  bottom: 2,
                  right: 4,
                  child: Text(
                    '오픈 ${eligibility.openAt!.month}/${eligibility.openAt!.day} ${eligibility.openAt!.hour.toString().padLeft(2, '0')}:${eligibility.openAt!.minute.toString().padLeft(2, '0')}',
                    style: TextStyle(
                      color: blockStyle.iconColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // 에러 UI 위젯 (애플 스타일)
  Widget _buildErrorWidget() {
    final isNetworkError =
        _errorType == 'network' ||
        _errorType == 'unavailable' ||
        _errorType == 'timeout';

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 아이콘
            Container(
              width: 80,
              height: 80,

              child: Icon(
                isNetworkError
                    ? Icons.wifi_off_rounded
                    : Icons.error_outline_rounded,
                size: 40,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 24),
            // 에러 메시지
            Text(
              _errorMessage ?? '오류가 발생했습니다',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w500,
                color: AppColors.textPrimary.withOpacity(0.8),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 62),
            // 재시도 버튼
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed:
                    _isLoading
                        ? null
                        : () async {
                          setState(() {
                            _errorMessage = null;
                            _errorType = null;
                            _isLoading = true;
                          });
                          // 1초 대기 후 재시도
                          await Future.delayed(const Duration(seconds: 1));
                          if (!mounted) return;
                          _updateProviderContext();
                        },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.textPrimary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppColors.borderLight,
                  disabledForegroundColor: AppColors.textSecondary,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  elevation: 0,
                ),
                child:
                    _isLoading
                        ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              AppColors.primaryGreen,
                            ),
                          ),
                        )
                        : const Text(
                          '다시 시도',
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
    );
  }
}

class _SmartRange {
  final int rangeStartMinutes;
  final int rangeEndMinutes;
  final int startHour;
  final int endHour;
  final int slotCount;
  final double hourSlotHeight;

  _SmartRange({
    required this.rangeStartMinutes,
    required this.rangeEndMinutes,
    required this.startHour,
    required this.endHour,
    required this.slotCount,
    required this.hourSlotHeight,
  });
}

class _CalendarTimeSlot {
  final int startMinute;
  final int endMinute;
  final String label;
  final bool isActive;
  final bool isMergedGap;

  const _CalendarTimeSlot({
    required this.startMinute,
    required this.endMinute,
    required this.label,
    required this.isActive,
    required this.isMergedGap,
  });
}

class _SlotLayout {
  final List<_CalendarTimeSlot> slots;
  final List<String> timeSlots;
  final List<double> slotHeights;
  final List<double> slotTops;
  final int rangeStartMinutes;
  final int initialJumpMinute;
  final List<bool> isActive;
  final List<bool> isMergedGap;

  const _SlotLayout({
    required this.slots,
    required this.timeSlots,
    required this.slotHeights,
    required this.slotTops,
    required this.rangeStartMinutes,
    required this.initialJumpMinute,
    required this.isActive,
    required this.isMergedGap,
  });

  double yForMinute(int minute) {
    final m = minute.clamp(
      rangeStartMinutes,
      slots.isNotEmpty ? slots.last.endMinute : rangeStartMinutes,
    );
    for (int idx = 0; idx < slots.length; idx++) {
      final slot = slots[idx];
      if (m >= slot.startMinute && m < slot.endMinute) {
        final span = slot.endMinute - slot.startMinute;
        if (span <= 0) return slotTops[idx];
        final frac = (m - slot.startMinute) / span;
        return slotTops[idx] + frac * slotHeights[idx];
      }
    }
    if (slots.isNotEmpty) {
      final last = slots.last;
      if (m >= last.endMinute) return slotTops.last;
    }
    return 0.0;
  }
}
