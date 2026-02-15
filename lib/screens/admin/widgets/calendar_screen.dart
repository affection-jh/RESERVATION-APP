import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../models/course.dart';
import '../../../models/reservation.dart';
import '../../../models/session_reservation.dart';
import '../../../models/course_enrollment.dart';
import '../../../models/course_override.dart';
import '../../../policies/course_policy.dart';
import '../../../policies/reservation_policy_engine.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/course_provider.dart';
import '../../../utils/timezone_utils.dart';
import '../../../providers/enrollment_provider.dart';
import '../../../providers/place_provider.dart';
import '../../../providers/reservation_provider.dart';
import '../../../services/firestore_service.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/reservation_bottom_sheet.dart';
import '../../../widgets/reservation_complete_bottom_sheet.dart';
import '../../../widgets/user_reservation_manage_bottom_sheet.dart';
import '../../../utils/snackbar_util.dart';
import '../../../utils/week_range_calculator.dart';
import '../../../widgets/week_tab_bar.dart';
import '../../../widgets/common_dialog.dart';
import 'package:flutter/scheduler.dart';

class CalendarScreen extends StatefulWidget {
  final Course course;
  final Map<String, dynamic>? highlightSession;

  const CalendarScreen({super.key, required this.course, this.highlightSession});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  /// 정기일정(요일/세션) 변경 시 Provider에서 최신 코스 반영
  late Course _effectiveCourse;

  Course get course => _effectiveCourse;

  // 주간 이동을 위한 상태
  int _weekOffset = 0; // 0: 현재 주(이번주), 1: 다음주, 2: 다다음주

  final FirestoreService _firestoreService = FirestoreService();
  CoursePolicy? _coursePolicy;
  StreamSubscription<List<SessionReservation>>? _sessionReservationSub;
  final Map<String, SessionReservation> _sessionReservationsByKey = {};
  StreamSubscription<List<CourseOverride>>? _courseOverridesSub;
  final Map<String, List<CourseOverride>> _courseOverridesByDate = {};
  StreamSubscription<Map<String, int>>? _capacityOverridesSub;
  Map<String, int> _capacityOverridesByKey = {}; // "sessionId_date" -> capacity
  bool _sessionReservationsLoaded = false;
  bool _courseOverridesLoaded = false;
  StreamSubscription<ReservationOperationEvent>? _reservationOpSub;
  String? _lastShownCompleteReservationId;
  StreamSubscription<Set<String>>? _bookingWeekOpensSub;
  Set<String> _openedWeekStartDates = {}; // 미리 열린 주차의 weekStartDate 집합

  // 구독 파라미터 추적 (중복 구독 방지)
  String? _lastSubscribedCourseId;
  String? _lastSubscribedPlaceId;
  int? _lastSubscribedWeekOffset;
  DateTime? _lastSubscribedStartDate;
  DateTime? _lastSubscribedEndDate;
  String? _lastSubscribedOverridesWeekStartDate;

  // 정책 기반 주차 범위
  List<int> _availableWeekOffsets = [0, 1, 2]; // 기본값

  // 에러 상태 관리
  String? _errorMessage;
  String? _errorType;
  bool _isLoading = false;
  // 주차 전환 후 로딩이 끝나도 레이아웃이 잡힐 때까지 그리드 숨김 (요동 방지)
  bool _showGridAfterLoad = true;

  // UI 상수 정의
  static const double _minHourSlotHeight = 120.0; // 세션이 있는 구간의 최소 한 시간당 높이 (px)
  static const double _minHourSlotHeightCompressed =
      36.0; // 뷰포트에 맞출 때 슬롯 하한 (긴 세션 시 간격 축소)
  static const double _optimalPxPerMinute = 50; // 세션 블록이 잘 보이기 위한 분당 픽셀 수
  static const double _minGapHourSlotHeight = 22.0; // 공백 구간 축소 하한 (px/h)
  static const int _edgePaddingMinutes = 30; // 00시, 23시 경계에 추가할 여백(분)
  static const double _timeColumnWidth = 35.0; // 시간대 컬럼 너비 (px)
  static const double _lineOffset = 1.0; // 가로선을 아래로 이동하는 오프셋 (px)
  static const double _sessionPadding = 2.0; // 세션 블록 좌우 패딩 (px)
  static const double _dateColumnSpacing = 0.0; // 날짜 컬럼 간 간격 (px)
  static const double _timeTextPaddingRight = 8.0; // 시간 텍스트 오른쪽 패딩 (px)
  static const double _gridRightPadding = 16.0; // 그리드 오른쪽 패딩 (px)

  static const int _basePaddingMinutes = 120; // 세션 위/아래 기본 여백(2시간)

  final ScrollController _scrollController = ScrollController();
  bool _didInitialJump = false;

  static int _floorToHour(int minutes) => (minutes ~/ 60) * 60;
  static int _ceilToHour(int minutes) =>
      ((minutes + 59) ~/ 60) * 60; // 올림(1~59분 포함)

  DateTime? _lastPolicyLoadTime;
  static const _policyReloadInterval = Duration(seconds: 2);

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
          final thisMonday = _startOfWeekMonday(now);
          final targetMonday = _startOfWeekMonday(target);
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
      _subscribeWeekSessionReservations();
      _subscribeReservationOperationEvents();
      _subscribeBookingWeekOpens();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // CourseProvider에 최신 정기일정이 있으면 반영 (요일/세션 변경 시)
    final fromProvider = Provider.of<CourseProvider>(
      context,
      listen: false,
    ).getCourse(widget.course.id);
    if (fromProvider != null && fromProvider != _effectiveCourse) {
      setState(() => _effectiveCourse = fromProvider);
    }
    // 화면이 다시 포커스될 때 정책을 다시 로드
    // (예: 정책 편집 화면에서 돌아왔을 때)
    // 중복 호출 방지를 위해 최근 로드 시간 확인
    final now = TimezoneUtils.getSeoulDateTime();
    if (_lastPolicyLoadTime == null ||
        now.difference(_lastPolicyLoadTime!) > _policyReloadInterval) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _lastPolicyLoadTime = TimezoneUtils.getSeoulDateTime();
        _loadCoursePolicy();
      });
    }
  }

  @override
  void dispose() {
    debugPrint('[CalendarScreen] dispose: 화면 종료, 구독 취소 시작');
    if (_sessionReservationSub != null) {
      debugPrint('[CalendarScreen] dispose: 기존 구독 취소 중...');
      _sessionReservationSub?.cancel();
      _sessionReservationSub = null;
      debugPrint('[CalendarScreen] dispose: 구독 취소 완료');
    } else {
      debugPrint('[CalendarScreen] dispose: 취소할 구독이 없음');
    }
    _courseOverridesSub?.cancel();
    _courseOverridesSub = null;
    _capacityOverridesSub?.cancel();
    _capacityOverridesSub = null;
    _bookingWeekOpensSub?.cancel();
    _bookingWeekOpensSub = null;
    _reservationOpSub?.cancel();
    _scrollController.dispose();
    // 구독 파라미터 초기화
    _lastSubscribedCourseId = null;
    _lastSubscribedPlaceId = null;
    _lastSubscribedWeekOffset = null;
    _lastSubscribedStartDate = null;
    _lastSubscribedEndDate = null;
    _lastSubscribedOverridesWeekStartDate = null;
    debugPrint('[CalendarScreen] dispose: 모든 리소스 해제 완료');
    super.dispose();
  }

  void _recomputeLoading() {
    final nextLoading = !(_sessionReservationsLoaded && _courseOverridesLoaded);
    if (!mounted) return;
    if (_isLoading != nextLoading) {
      setState(() {
        _isLoading = nextLoading;
      });
      // 로딩이 끝난 뒤 잠시 뒤에 그리드 표시 (레이아웃 안정화 후 세션 박스 요동 방지)
      if (!nextLoading) {
        Future.delayed(const Duration(milliseconds: 350), () {
          if (!mounted) return;
          setState(() {
            _showGridAfterLoad = true;
          });
        });
      }
    }
  }

  List<CourseSession> _effectiveSessionsForDate(DateTime date) {
    final dateStr = _formatDate(date);
    final overrides =
        _courseOverridesByDate[dateStr] ?? const <CourseOverride>[];
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
      (a, b) => _parseTimeToMinutes(
        a.startTime,
      ).compareTo(_parseTimeToMinutes(b.startTime)),
    );
    return all;
  }

  bool _hasAddedOverrideSessionsForDate(DateTime date) {
    final dateStr = _formatDate(date);
    final overrides = _courseOverridesByDate[dateStr];
    if (overrides == null || overrides.isEmpty) return false;
    return overrides.any(
      (o) => o.isCancelled != true && o.startTime != null && o.endTime != null,
    );
  }

  List<CourseSession> _effectiveSessionsForDates(List<DateTime> dates) {
    final out = <CourseSession>[];
    for (final d in dates) {
      out.addAll(_effectiveSessionsForDate(d));
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

  /// 미리 열린 주차 구독
  void _subscribeBookingWeekOpens() {
    _bookingWeekOpensSub?.cancel();

    final placeId =
        Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id;
    if (placeId == null) return;

    try {
      _bookingWeekOpensSub = _firestoreService
          .streamBookingWeekOpens(placeId: placeId, courseId: course.id)
          .listen(
            (openedWeekStartDates) {
              if (!mounted) return;
              setState(() {
                _openedWeekStartDates = openedWeekStartDates;
              });
              // 정책이 로드되어 있으면 주차 범위 업데이트
              if (_coursePolicy != null) {
                _updateAvailableWeekOffsets(_coursePolicy!);
              }
            },
            onError: (e) {
              debugPrint('[CalendarScreen] bookingWeekOpens stream error: $e');
            },
          );
    } catch (e) {
      debugPrint('[CalendarScreen] bookingWeekOpens subscribe error: $e');
    }
  }

  /// 정책 기반 주차 범위 계산 (미리 열린 주차 포함)
  /// 이번 주(0)는 항상 탭에 포함.
  void _updateAvailableWeekOffsets(CoursePolicy policy) {
    // 정책 기반 기본 주차 범위
    final baseOffsets = WeekRangeCalculator.getAvailableWeekOffsets(policy);
    final now = TimezoneUtils.getSeoulDateTime();
    final thisWeekMonday = _startOfWeekMonday(now);

    // 미리 열린 주차의 weekOffset 계산
    final openedOffsets = <int>{};
    for (final weekStartDateStr in _openedWeekStartDates) {
      try {
        final parts = weekStartDateStr.split('-');
        final weekStartDate = DateTime(
          int.parse(parts[0]),
          int.parse(parts[1]),
          int.parse(parts[2]),
        );
        final diffDays = weekStartDate.difference(thisWeekMonday).inDays;
        final weekOffset = (diffDays / 7).round();
        if (weekOffset >= 0) {
          openedOffsets.add(weekOffset);
        }
      } catch (_) {
        // 날짜 파싱 실패 시 스킵
      }
    }

    // highlightSession의 주차도 포함 (새 수업 일정 알림 등)
    final highlightOffsets = <int>{};
    final hl = widget.highlightSession;
    if (hl != null) {
      final dateStr = hl['date'] as String?;
      if (dateStr != null && dateStr.isNotEmpty) {
        try {
          final target = DateTime.parse(dateStr);
          final diffDays =
              _startOfWeekMonday(target).difference(thisWeekMonday).inDays;
          final weekOffset = (diffDays / 7).round();
          if (weekOffset >= 0) highlightOffsets.add(weekOffset);
        } catch (_) {}
      }
    }

    // 정책 기반 주차 + 미리 열린 주차 + highlight 주차 합치기
    var sortedOffsets = <int>[
      0,
      ...baseOffsets,
      ...openedOffsets,
      ...highlightOffsets
    ].toSet().toList()
      ..sort();

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
      _subscribeWeekSessionReservations();
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

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  DateTime _startOfWeekMonday(DateTime date) {
    final dateOnly = DateTime(date.year, date.month, date.day);
    return dateOnly.subtract(
      Duration(days: dateOnly.weekday - DateTime.monday),
    );
  }

  Future<void> _loadCoursePolicy() async {
    final placeId =
        Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id;
    if (placeId == null) return;
    try {
      final policy = await _firestoreService.getCoursePolicy(
        courseId: course.id,
        placeId: placeId,
      );
      if (!mounted) return;
      setState(() {
        _coursePolicy = policy;
        // 정책 기반 주차 범위 계산 (미리 열린 주차 포함)
        _updateAvailableWeekOffsets(policy);
        // 선택된 주차가 범위를 벗어나면 조정
        if (_availableWeekOffsets.isNotEmpty &&
            _weekOffset >= _availableWeekOffsets.length) {
          _weekOffset = _availableWeekOffsets.length - 1;
        }
      });
    } catch (_) {
      if (!mounted) return;
      final defaultPolicy = CoursePolicy.defaultFor(
        courseId: course.id,
        placeId: placeId,
      );
      setState(() {
        _coursePolicy = defaultPolicy;
        // 정책 기반 주차 범위 계산 (미리 열린 주차 포함)
        _updateAvailableWeekOffsets(defaultPolicy);
        if (_availableWeekOffsets.isNotEmpty &&
            _weekOffset >= _availableWeekOffsets.length) {
          _weekOffset = _availableWeekOffsets.length - 1;
        }
      });
    }
  }

  void _subscribeWeekSessionReservations() {
    debugPrint('[CalendarScreen] _subscribeWeekSessionReservations: 구독 시작');

    final placeId =
        Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id;

    final now = TimezoneUtils.getSeoulDateTime();
    // 정책 기반 주차 범위 내에서만 선택 가능
    final weekOffset = _weekOffset.clamp(
      0,
      _availableWeekOffsets.isNotEmpty ? _availableWeekOffsets.last : 2,
    );
    final weekStart = _startOfWeekMonday(
      now,
    ).add(Duration(days: 7 * weekOffset));
    final startDate = DateTime(weekStart.year, weekStart.month, weekStart.day);
    final endDate = startDate.add(const Duration(days: 6));
    final weekStartDateString = TimezoneUtils.formatDateToSeoul(weekStart);

    // 구독 파라미터가 변경되지 않았으면 재구독하지 않음
    if (_sessionReservationSub != null &&
        _lastSubscribedCourseId == course.id &&
        _lastSubscribedPlaceId == placeId &&
        _lastSubscribedWeekOffset == weekOffset &&
        _lastSubscribedStartDate != null &&
        _lastSubscribedEndDate != null &&
        _lastSubscribedStartDate!.year == startDate.year &&
        _lastSubscribedStartDate!.month == startDate.month &&
        _lastSubscribedStartDate!.day == startDate.day &&
        _lastSubscribedEndDate!.year == endDate.year &&
        _lastSubscribedEndDate!.month == endDate.month &&
        _lastSubscribedEndDate!.day == endDate.day &&
        _courseOverridesSub != null &&
        _lastSubscribedOverridesWeekStartDate == weekStartDateString) {
      debugPrint(
        '[CalendarScreen] _subscribeWeekSessionReservations: 동일한 파라미터로 이미 구독 중, 재구독 스킵',
      );
      return;
    }

    // 기존 구독이 있으면 취소
    if (_sessionReservationSub != null) {
      debugPrint(
        '[CalendarScreen] _subscribeWeekSessionReservations: 기존 구독 취소 중...',
      );
      _sessionReservationSub?.cancel();
      _sessionReservationSub = null;
      debugPrint(
        '[CalendarScreen] _subscribeWeekSessionReservations: 기존 구독 취소 완료',
      );
    }
    _courseOverridesSub?.cancel();
    _courseOverridesSub = null;

    _sessionReservationsByKey.clear();
    _courseOverridesByDate.clear();

    // 구독 파라미터 저장
    _lastSubscribedCourseId = course.id;
    _lastSubscribedPlaceId = placeId;
    _lastSubscribedWeekOffset = weekOffset;
    _lastSubscribedStartDate = startDate;
    _lastSubscribedEndDate = endDate;
    _lastSubscribedOverridesWeekStartDate = weekStartDateString;

    debugPrint('[CalendarScreen] _subscribeWeekSessionReservations: 쿼리 파라미터');
    debugPrint('  - courseId: ${course.id}');
    debugPrint('  - placeId: $placeId');
    debugPrint('  - weekOffset: $weekOffset');
    debugPrint('  - startDate: $startDate');
    debugPrint('  - endDate: $endDate');
    debugPrint('  - overrides.weekStartDate: $weekStartDateString');

    _loadCoursePolicy();

    // 초기 로딩 상태 설정
    setState(() {
      _isLoading = true;
      _sessionReservationsLoaded = false;
      _courseOverridesLoaded = false;
      _errorMessage = null;
      _errorType = null;
    });

    // 비정기 일정 구독 (실시간)
    try {
      if (placeId != null) {
        _courseOverridesSub = _firestoreService
            .streamCourseOverrides(
              placeId: placeId,
              courseId: course.id,
              weekStartDate: weekStartDateString,
            )
            .listen(
              (items) {
                final nextByDate = <String, List<CourseOverride>>{};
                for (final o in items) {
                  nextByDate
                      .putIfAbsent(o.date, () => <CourseOverride>[])
                      .add(o);
                }
                if (!mounted) return;
                setState(() {
                  _courseOverridesByDate
                    ..clear()
                    ..addAll(nextByDate);
                  _courseOverridesLoaded = true;
                });
                _recomputeLoading();
              },
              onError: (e) {
                debugPrint(
                  '[CalendarScreen] ⚠️ courseOverrides stream error: $e',
                );
                if (!mounted) return;
                setState(() {
                  _courseOverridesByDate.clear();
                  _courseOverridesLoaded = true; // 로딩 무한 방지
                });
                _recomputeLoading();
              },
            );
      } else {
        // placeId가 없으면 overrides는 비움 처리
        _courseOverridesLoaded = true;
        _recomputeLoading();
      }
    } catch (e) {
      debugPrint('[CalendarScreen] ❌ courseOverrides subscribe error: $e');
      _courseOverridesLoaded = true;
      _recomputeLoading();
    }

    // dateCapacityOverrides 구독
    _capacityOverridesSub?.cancel();
    if (placeId == null || placeId.isEmpty) return;
    _capacityOverridesSub = _firestoreService
        .watchDateCapacityOverrides(
          placeId: placeId,
          courseId: course.id,
          startDate: startDate,
          endDate: endDate,
        )
        .listen(
          (overrides) {
            if (!mounted) return;
            setState(() {
              // ✅ 스트림이 source of truth (다른 화면에서의 변경도 즉시 반영)
              _capacityOverridesByKey = {
                ..._capacityOverridesByKey,
                ...overrides,
              };
              // 기존 SessionReservation들의 capacity 업데이트
              for (final key in _sessionReservationsByKey.keys) {
                final overrideCapacity = _capacityOverridesByKey[key];
                if (overrideCapacity != null) {
                  final sr = _sessionReservationsByKey[key];
                  if (sr != null) {
                    _sessionReservationsByKey[key] = sr.copyWith(
                      capacity: overrideCapacity,
                    );
                  }
                }
              }
            });
          },
          onError: (e) {
            debugPrint(
              '[CalendarScreen] dateCapacityOverrides stream error: $e',
            );
            // 에러는 조용히 로그만 남김 (인덱스는 이미 정의되어 있으므로)
          },
        );

    try {
      debugPrint(
        '[CalendarScreen] _subscribeWeekSessionReservations: Firestore 구독 시작...',
      );
      _sessionReservationSub = _firestoreService
          .watchCourseSessionReservations(
            courseId: course.id,
            placeId: placeId,
            startDate: startDate,
            endDate: endDate,
          )
          .handleError((error) {
            // Stream 에러 처리
            debugPrint('[CalendarScreen] ⚠️ Stream handleError: 에러 발생');
            debugPrint('[CalendarScreen] 에러 내용: $error');
            debugPrint('[CalendarScreen] 에러 타입: ${error.runtimeType}');
            if (!mounted) {
              debugPrint('[CalendarScreen] handleError: 위젯이 마운트되지 않음, 처리 중단');
              return;
            }
            setState(() {
              _sessionReservationsByKey.clear();
              _isLoading = false;
              _errorMessage = _getErrorMessage(error);
              _errorType = _getErrorType(error);
            });
            debugPrint(
              '[CalendarScreen] handleError: 에러 UI 표시 완료 - $_errorMessage',
            );
          })
          .listen(
            (list) {
              debugPrint('[CalendarScreen] ✅ 구독 데이터 수신: ${list.length}개 항목');
              final next = <String, SessionReservation>{};
              for (final sr in list) {
                final key = '${sr.sessionId}_${sr.date}';
                // dateCapacityOverrides가 있으면 capacity를 오버라이드
                final overrideCapacity = _capacityOverridesByKey[key];
                final updatedSr =
                    overrideCapacity != null
                        ? sr.copyWith(capacity: overrideCapacity)
                        : sr;
                next[key] = updatedSr;
                debugPrint(
                  '[CalendarScreen]   - $key: reservedCount=${updatedSr.reservedCount}/${updatedSr.capacity}, id=${updatedSr.id}',
                );
              }
              if (!mounted) {
                debugPrint('[CalendarScreen] listen: 위젯이 마운트되지 않음, 업데이트 중단');
                return;
              }
              setState(() {
                _sessionReservationsByKey
                  ..clear()
                  ..addAll(next);
                _errorMessage = null;
                _errorType = null;
                _sessionReservationsLoaded = true;
              });
              _recomputeLoading();
              debugPrint(
                '[CalendarScreen] ✅ 구독 데이터 업데이트 완료: 총 ${_sessionReservationsByKey.length}개 항목',
              );
            },
            onError: (error) {
              // 추가 에러 처리 (이중 안전장치)
              debugPrint('[CalendarScreen] ⚠️ listen onError: 구독 오류 발생');
              debugPrint('[CalendarScreen] 에러 내용: $error');
              debugPrint('[CalendarScreen] 에러 타입: ${error.runtimeType}');
              if (!mounted) {
                debugPrint('[CalendarScreen] onError: 위젯이 마운트되지 않음, 처리 중단');
                return;
              }
              setState(() {
                _sessionReservationsByKey.clear();
                _sessionReservationsLoaded = true; // 로딩 무한 방지
                _errorMessage = _getErrorMessage(error);
                _errorType = _getErrorType(error);
              });
              _recomputeLoading();
              debugPrint(
                '[CalendarScreen] onError: 에러 UI 표시 완료 - $_errorMessage',
              );
            },
            cancelOnError: false, // 에러 발생해도 구독 유지
            onDone: () {
              debugPrint('[CalendarScreen] 🔚 구독 종료: Stream이 완료됨');
            },
          );
      debugPrint('[CalendarScreen] ✅ 구독 설정 완료: StreamSubscription 생성됨');
    } catch (e) {
      // 초기 구독 시도 중 에러 (동기 에러)
      debugPrint('[CalendarScreen] ❌ 구독 초기화 중 동기 에러 발생: $e');
      debugPrint('[CalendarScreen] 에러 타입: ${e.runtimeType}');
      if (!mounted) {
        debugPrint('[CalendarScreen] catch: 위젯이 마운트되지 않음, 처리 중단');
        return;
      }
      setState(() {
        _sessionReservationsLoaded = true; // 로딩 무한 방지
        _errorMessage = _getErrorMessage(e);
        _errorType = _getErrorType(e);
      });
      _recomputeLoading();
      debugPrint('[CalendarScreen] catch: 에러 UI 표시 완료 - $_errorMessage');
    }
  }

  String _getErrorType(dynamic error) {
    if (error is FirebaseException) {
      return error.code;
    }
    final errorString = error.toString().toLowerCase();
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
    // ReservationProvider를 listen하여 예약 변경사항 자동 반영
    Provider.of<ReservationProvider>(context);

    // 해당 코스의 세션이 있는 요일들만 가져오기 (정기)
    final availableDays = course.availableDays;

    // 현재 주의 날짜들 계산 (주간 오프셋 적용, 이번주~다다음주만 / 월요일 기준)
    final now = TimezoneUtils.getSeoulDateTime();
    // 정책 기반 주차 범위 내에서만 선택 가능
    final weekOffset = _weekOffset.clamp(
      0,
      _availableWeekOffsets.isNotEmpty ? _availableWeekOffsets.last : 2,
    );
    final weekStart = _startOfWeekMonday(
      now,
    ).add(Duration(days: weekOffset * 7));
    final weekDates = List.generate(
      7,
      (index) => weekStart.add(Duration(days: index)),
    );

    // 세션이 있는 날짜만 필터링 (정기 요일 + 비정기 추가 세션이 있는 날짜)
    final sessionDates =
        weekDates.where((date) {
          return availableDays.contains(date.weekday) ||
              _hasAddedOverrideSessionsForDate(date);
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
                      _isLoading = true;
                      _showGridAfterLoad = false;
                      _sessionReservationsLoaded = false;
                      _courseOverridesLoaded = false;
                    });
                    _subscribeWeekSessionReservations();
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
                              _isLoading = true;
                              _showGridAfterLoad = false;
                              _sessionReservationsLoaded = false;
                              _courseOverridesLoaded = false;
                            });
                            _subscribeWeekSessionReservations();
                          }
                        } else if (details.primaryVelocity! < 0) {
                          // 왼쪽으로 스와이프 (다음주로)
                          if (currentIndex < _availableWeekOffsets.length - 1) {
                            setState(() {
                              _weekOffset =
                                  _availableWeekOffsets[currentIndex + 1];
                              _didInitialJump = false;
                              _isLoading = true;
                              _showGridAfterLoad = false;
                              _sessionReservationsLoaded = false;
                              _courseOverridesLoaded = false;
                            });
                            _subscribeWeekSessionReservations();
                          }
                        }
                      },
                      child: Column(
                        children: [
                          // 요일 헤더
                          _buildDayHeaders(sessionDates),

                          // 주차 변경 시 로딩 중·레이아웃 대기 중에는 스피너만, 그 후 세션 그리드 페이드 인
                          Expanded(
                            child:
                                (_isLoading || !_showGridAfterLoad)
                                    ? Center(
                                      child: CircularProgressIndicator(
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                              AppColors.primaryGreen,
                                            ),
                                      ),
                                    )
                                    : TweenAnimationBuilder<double>(
                                      key: ValueKey('grid_$_weekOffset'),
                                      tween: Tween(begin: 0, end: 1),
                                      duration: const Duration(
                                        milliseconds: 320,
                                      ),
                                      curve: Curves.easeOut,
                                      builder: (context, value, child) {
                                        return Opacity(
                                          opacity: value,
                                          child: child,
                                        );
                                      },
                                      child: LayoutBuilder(
                                        builder: (context, constraints) {
                                          return _buildCalendarGrid(
                                            sessionDates,
                                            viewportHeight:
                                                constraints.maxHeight,
                                          );
                                        },
                                      ),
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
    required double viewportHeight,
  }) {
    // 해당 컬럼(날짜들)에서 실제로 표시될 세션(정기+비정기) 기준으로 범위 계산
    final sessions = _effectiveSessionsForDates(dates);

    if (sessions.isEmpty) {
      return _SmartRange(
        rangeStartMinutes: 9 * 60,
        rangeEndMinutes: 18 * 60,
        startHour: 9,
        endHour: 18,
        slotCount: 9,
        hourSlotHeight: _minHourSlotHeight,
      );
    }

    final starts = sessions.map((s) => _parseTimeToMinutes(s.startTime));
    final ends = sessions.map((s) => _parseTimeToMinutes(s.endTime));
    final minStart = starts.reduce((a, b) => a < b ? a : b);
    final maxEnd = ends.reduce((a, b) => a > b ? a : b);

    // 세션 지속 시간을 기반으로 동적 최적 높이 계산
    double maxSessionDuration = 0;
    for (final session in sessions) {
      final start = _parseTimeToMinutes(session.startTime);
      final end = _parseTimeToMinutes(session.endTime);
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

    // 세션 블록이 잘 보이기 위한 최적 높이 (짧은 세션일 때 사용)
    final optimalHourSlotHeight =
        maxSessionDuration > 0
            ? (maxSessionDuration * _optimalPxPerMinute / 60.0).clamp(
              _minHourSlotHeight,
              double.infinity,
            )
            : _minHourSlotHeight;

    // 긴 세션이 있을 때: 뷰포트에 맞추기 위해 눈금 간격을 동적으로 줄임
    final maxByViewport = viewportHeight / slotCount;
    final hourSlotHeight = (optimalHourSlotHeight > maxByViewport
            ? maxByViewport
            : optimalHourSlotHeight)
        .clamp(_minHourSlotHeightCompressed, double.infinity);

    double totalHeightAtDefault = slotCount * hourSlotHeight;

    if (totalHeightAtDefault < viewportHeight) {
      final extraSlotsNeeded =
          ((viewportHeight - totalHeightAtDefault) / hourSlotHeight).ceil();
      var addBefore = extraSlotsNeeded ~/ 2;
      var addAfter = extraSlotsNeeded - addBefore;

      // 경계(0~24h) 안에서 확장
      final startHour = rangeStart ~/ 60;
      final endHour = rangeEnd ~/ 60;

      final maxBefore = startHour;
      final maxAfter = 24 - endHour;

      addBefore = addBefore.clamp(0, maxBefore);
      addAfter = addAfter.clamp(0, maxAfter);

      rangeStart -= addBefore * 60;
      rangeEnd += addAfter * 60;
      slotCount = (rangeEnd - rangeStart) ~/ 60;
      totalHeightAtDefault = slotCount * hourSlotHeight;
    }

    // 범위 확장 후에도 뷰포트를 넘지 않도록 눈금 간격 한 번 더 조정
    double finalHourSlotHeight = hourSlotHeight;
    if (slotCount > 0 && slotCount * hourSlotHeight > viewportHeight) {
      finalHourSlotHeight = (viewportHeight / slotCount).clamp(
        _minHourSlotHeightCompressed,
        hourSlotHeight,
      );
    }

    final startHour = rangeStart ~/ 60;
    final endHour = rangeEnd ~/ 60;
    return _SmartRange(
      rangeStartMinutes: rangeStart,
      rangeEndMinutes: rangeEnd,
      startHour: startHour,
      endHour: endHour,
      slotCount: slotCount,
      hourSlotHeight: finalHourSlotHeight,
    );
  }

  _SlotLayout _buildSlotLayout({
    required List<DateTime> dates,
    required _SmartRange smart,
    required double viewportHeight,
  }) {
    final timeSlots = _generateTimeSlots(
      startHour: smart.startHour,
      endHour: smart.endHour,
    );

    final rangeStartMinutes = smart.rangeStartMinutes;
    final rangeEndMinutes = smart.rangeEndMinutes;

    // 표시되는 날짜들에 해당하는 세션(정기+비정기)을 모아 "활성 시간대"를 계산
    final sessions = _effectiveSessionsForDates(dates);

    // 시간 슬롯(시간 단위)별로 active 여부 계산 (어느 요일이든 해당 시간대에 세션이 있으면 active)
    final active = List<bool>.filled(timeSlots.length, false);
    int? minSessionStart;
    for (final s in sessions) {
      final start = _parseTimeToMinutes(s.startTime);
      final end = _parseTimeToMinutes(s.endTime);
      if (end <= start) continue;
      minSessionStart =
          minSessionStart == null
              ? start
              : (start < minSessionStart ? start : minSessionStart);

      for (int i = 0; i < timeSlots.length; i++) {
        final slotStart = rangeStartMinutes + (i * 60);
        final slotEnd = slotStart + 60;
        final overlaps = start < slotEnd && end > slotStart;
        if (overlaps) active[i] = true;
      }
    }

    // 공백 압축은 "첫 active ~ 마지막 active" 사이의 inactive 구간만 적용
    final firstActive = active.indexWhere((v) => v);
    final lastActive = active.lastIndexWhere((v) => v);

    // 기본 슬롯 높이(세션/외부 여백)
    final baseSlotHeight = smart.hourSlotHeight;
    final slotHeights = List<double>.filled(timeSlots.length, baseSlotHeight);

    if (firstActive != -1 && lastActive != -1 && lastActive > firstActive) {
      final gapIndices = <int>[];
      for (int i = firstActive; i <= lastActive; i++) {
        if (!active[i]) gapIndices.add(i);
      }

      if (gapIndices.isNotEmpty) {
        // 현재 높이(압축 전)
        final currentTotal = slotHeights.fold<double>(0.0, (s, h) => s + h);
        if (currentTotal > viewportHeight) {
          // gap만 줄여서 viewportHeight에 최대한 맞춤
          final nonGapCount = timeSlots.length - gapIndices.length;
          final nonGapHeight = nonGapCount * baseSlotHeight;
          final remaining = viewportHeight - nonGapHeight;
          if (remaining.isFinite && remaining > 0) {
            final gapHeight = (remaining / gapIndices.length).clamp(
              _minGapHourSlotHeight,
              baseSlotHeight,
            );
            for (final idx in gapIndices) {
              slotHeights[idx] = gapHeight;
            }
          } else {
            // 남는 공간이 없으면 gap을 최소로
            for (final idx in gapIndices) {
              slotHeights[idx] = _minGapHourSlotHeight;
            }
          }
        }
      }
    }

    // prefix sum (slotTops)
    final slotTops = List<double>.filled(timeSlots.length + 1, 0.0);
    for (int i = 0; i < timeSlots.length; i++) {
      slotTops[i + 1] = slotTops[i] + slotHeights[i];
    }

    // 초기 점프 위치: highlightSession 있으면 해당 세션, 없으면 첫 세션 - 2시간
    int jumpMinute = rangeStartMinutes;
    final hl = widget.highlightSession;
    if (hl != null) {
      final startTime = hl['startTime'] as String?;
      if (startTime != null && startTime.isNotEmpty) {
        try {
          final m = _parseTimeToMinutes(startTime);
          jumpMinute =
              (m - _basePaddingMinutes).clamp(rangeStartMinutes, rangeEndMinutes);
        } catch (_) {}
      }
    }
    if (jumpMinute == rangeStartMinutes && minSessionStart != null) {
      jumpMinute = (minSessionStart - _basePaddingMinutes)
          .clamp(rangeStartMinutes, rangeEndMinutes);
    }
    final initialJumpMinute = jumpMinute;

    return _SlotLayout(
      timeSlots: timeSlots,
      slotHeights: slotHeights,
      slotTops: slotTops,
      rangeStartMinutes: rangeStartMinutes,
      initialJumpMinute: initialJumpMinute,
      isActive: active,
    );
  }

  // 캘린더 그리드 (세션이 있는 구간만, 동적 스케일)
  Widget _buildCalendarGrid(
    List<DateTime> dates, {
    required double viewportHeight,
  }) {
    final smart = _computeSmartRange(
      dates: dates,
      viewportHeight: viewportHeight,
    );
    final layout = _buildSlotLayout(
      dates: dates,
      smart: smart,
      viewportHeight: viewportHeight,
    );

    // 진입 즉시 "세션 구간"을 최상단으로 보이게
    if (!_didInitialJump) {
      _didInitialJump = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          final targetMinute = layout.initialJumpMinute;
          final targetY = layout.yForMinute(targetMinute);
          _scrollController.jumpTo(
            targetY.clamp(0.0, _scrollController.position.maxScrollExtent),
          );
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
                        final hour = time.split(':')[0]; // "17:00" -> "17"
                        final isActiveSlot = layout.isActive[idx];
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
                              fontSize: isActiveSlot ? 16 : 13,
                              fontWeight:
                                  isActiveSlot
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                              color:
                                  isActiveSlot
                                      ? AppColors.textSecondary
                                      : AppColors.textSecondary.withOpacity(
                                        0.4,
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
                      timeSlots: layout.timeSlots,
                      rangeStartMinutes: smart.rangeStartMinutes,
                      slotTops: layout.slotTops,
                      slotHeights: layout.slotHeights,
                      yForMinute: layout.yForMinute,
                      isActive: layout.isActive,
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
    required List<String> timeSlots,
    required int rangeStartMinutes,
    required List<double> slotTops,
    required List<double> slotHeights,
    required double Function(int minute) yForMinute,
    required List<bool> isActive,
  }) {
    final daySessions = _effectiveSessionsForDate(date);

    // 세션이 시작하는 시간대만 찾기 (연속 세션은 하나의 위젯으로 그리기 위해)
    final sessionStartSlots = <String, CourseSession>{};

    for (final session in daySessions) {
      final sessionStartMinutes = _parseTimeToMinutes(session.startTime);
      final sessionStartHour = sessionStartMinutes ~/ 60;
      final startTimeSlot = '${sessionStartHour.toString().padLeft(2, '0')}:00';

      // 세션이 시작하는 시간대 찾기
      if (timeSlots.contains(startTimeSlot)) {
        // 이미 다른 세션이 있으면 시작 시간이 더 빠른 세션 우선
        if (!sessionStartSlots.containsKey(startTimeSlot) ||
            _parseTimeToMinutes(sessionStartSlots[startTimeSlot]!.startTime) >
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

            return Positioned(
              top: slotTops[index] + _lineOffset,
              left: 0,
              right: 0,
              child: Container(
                height: 0.5,
                color:
                    isActiveSlot
                        ? AppColors.borderLight
                        : AppColors.borderLight.withOpacity(0.2),
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

  // 시간 문자열을 분 단위로 변환
  int _parseTimeToMinutes(String time) {
    final parts = time.split(':');
    final hour = int.parse(parts[0]);
    final minute = int.parse(parts[1]);
    return hour * 60 + minute;
  }

  Reservation? _getUserReservationForSession({
    required List<Reservation> reservations,
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
    final sessionStartMinutes = _parseTimeToMinutes(session.startTime);
    final sessionEndMinutes = _parseTimeToMinutes(session.endTime);

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
    final enrollmentCanReserve = enrollment?.canReserve ?? false;

    final policy =
        _coursePolicy ??
        CoursePolicy.defaultFor(courseId: course.id, placeId: placeId ?? '');

    final dateString = _formatDate(date);
    final generatedSessionId = SessionReservation.generateSessionId(
      course.id,
      session.dayOfWeek,
      session.startTime,
    );
    final lookupKey = '${generatedSessionId}_$dateString';
    final sr = _sessionReservationsByKey[lookupKey];
    final dateCapacityOverride = _capacityOverridesByKey[lookupKey];
    final totalSeats =
        dateCapacityOverride ??
        sr?.capacity ??
        session.getCapacityForDate(date);
    final reservedCount = sr?.reservedCount ?? 0;
    final remainingSeats = (totalSeats - reservedCount).clamp(0, 1 << 30);

    // 디버깅: 세션 블록 렌더링 시 현재 상태 로그
    debugPrint(
      '[CalendarScreen] 세션 블록: $lookupKey -> reservedCount: $reservedCount/$totalSeats, remaining: $remainingSeats',
    );

    final eligibility = ReservationPolicyEngine.evaluateReservation(
      now: TimezoneUtils.getSeoulDateTime(),
      policy: policy,
      sessionDate: date,
      startTime: session.startTime,
      capacity: totalSeats,
      reservedCount: reservedCount,
      enrollmentCanReserve: enrollmentCanReserve,
    );

    // ✅ 관리자가 미리 예약 열기를 한 경우 잠금 해제
    bool isBookingWeekOpened = false;
    if (eligibility.reason == ReservationLockReason.notOpenedYet) {
      final weekStart = _startOfWeekMonday(date);
      final weekStartDateString =
          '${weekStart.year}-${weekStart.month.toString().padLeft(2, '0')}-${weekStart.day.toString().padLeft(2, '0')}';
      isBookingWeekOpened = _openedWeekStartDates.contains(weekStartDateString);
    }

    // 미리 열린 주차인 경우 잠금 해제
    final effectiveCanReserve =
        eligibility.canReserve ||
        (isBookingWeekOpened &&
            eligibility.reason == ReservationLockReason.notOpenedYet);

    final isLocked = !effectiveCanReserve || !isEnrolled || userId == null;
    final isMyReserved = hasUserReservation;
    final canReserve = !isLocked && !isMyReserved;

    // ✅ 이미 예약된 세션은 "연하게(비활성 느낌)" 보이되,
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
    final operationType =
        processingKey != null
            ? reservationProvider.getOperationTypeByKey(processingKey)
            : null;

    // 배경색: 이미 예약된 경우 옅은 코스 컬러 우선, 그 다음 잠김 상태는 회색
    final baseBlockColor =
        isMyReserved
            ? course
                .colorValue // 이미 예약된 경우 코스 컬러 사용 (회색보다 우선)
            : (isLocked
                ? AppColors
                    .reservedGrey // 잠긴 경우 회색
                : course.colorValue); // 예약 가능한 경우 코스 컬러
    final blockColor =
        isProcessing
            ? (isMyReserved
                ? baseBlockColor.withOpacity(0.3)
                : baseBlockColor.withOpacity(0.45))
            : (isMyReserved ? baseBlockColor.withOpacity(0.4) : baseBlockColor);

    // 비활성화된 회색 위에는 textPrimary, 그 외에는 흰색
    final isInactive = isMyReserved || isLocked;
    final textColor = isInactive ? AppColors.textPrimary : Colors.white;
    final iconColor = isInactive ? AppColors.textPrimary : Colors.white;
    // 예약중/취소중/변경중 UI는 iconColor 대신 고정 흰색으로 표시 (깜빡임 방지)
    const Color processingUiColor = Colors.white;

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
            try {
              // ✅ 성공 바텀시트는 ReservationProvider operationEvents에서 처리
              await ReservationBottomSheet.show(
                context: context,
                activityName: course.name,
                date: '${session.dayName}요일 ${date.day}일',
                startTime: session.startTime,
                endTime: session.endTime,
                availableSeats: remainingSeats,
                totalSeats: totalSeats,
                remainingReservations: enrollment.remainingReservations,
                course: course,
                onConfirm: () async {
                  return await Provider.of<ReservationProvider>(
                    context,
                    listen: false,
                  ).createReservation(
                    Reservation(
                      id: '',
                      userId: uid,
                      courseId: course.id,
                      placeId: pid,
                      dayOfWeek: session.dayOfWeek,
                      startTime: session.startTime,
                      reservedAt: TimezoneUtils.getSeoulDateTime(),
                      // ✅ 선택한 캘린더 날짜로 예약 생성해야 셀(in-flight key)과도 일치함
                      reservedDate: date,
                    ),
                  );
                },
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
          switch (eligibility.reason) {
            case ReservationLockReason.pastDate:
              SnackbarUtil.showInfo(context, '지나간 세션은 예약할 수 없습니다.');
              return;
            case ReservationLockReason.closedBeforeStart:
              SnackbarUtil.showInfo(
                context,
                '세션 시작 ${policy.closeBeforeMinutes}분 전까지만 예약 가능합니다.',
              );
              return;
            case ReservationLockReason.full:
              SnackbarUtil.showInfo(context, '예약 가능한 자리가 없습니다.');
              return;
            case ReservationLockReason.noCreditsOrExpired:
              SnackbarUtil.showInfo(context, '예약 가능한 횟수가 없습니다.');
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
            left: 12,
            top: sessionHeightPx >= 50 ? 8 : 6,
            right: 8,
            bottom: sessionHeightPx >= 50 ? 4 : 2,
          ),
          decoration: BoxDecoration(
            color: blockColor,
            borderRadius: BorderRadius.circular(8),
            boxShadow:
                isMyReserved
                    ? const []
                    : [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
          ),
          child: Stack(
            children: [
              // 로딩 중이 아닐 때만 텍스트 표시
              if (!isProcessing)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 코스 이름 (항상 표시, 높이에 따라 폰트 크기 조정)
                    Text(
                      course.name,
                      style: TextStyle(
                        color: textColor,
                        fontSize:
                            sessionHeightPx >= 60
                                ? 20
                                : (sessionHeightPx >= 40 ? 18 : 16),
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),

                    // 시간 (높이가 충분할 때만 표시)
                    if (sessionHeightPx >= 70) ...[
                      SizedBox(height: sessionHeightPx >= 80 ? 3 : 2),
                      Text(
                        '${session.startTime} - ${session.endTime}',
                        style: TextStyle(
                          color: iconColor,
                          fontSize: sessionHeightPx >= 90 ? 17 : 15,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],

                    // 예약 현황 (높이가 충분할 때만 표시)
                    if (sessionHeightPx >= 90) ...[
                      SizedBox(height: sessionHeightPx >= 100 ? 3 : 2),
                      Text(
                        '$reservedCount / $totalSeats',
                        style: TextStyle(
                          color: iconColor,
                          fontSize: sessionHeightPx >= 110 ? 18 : 16,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                              processingUiColor,
                            ),
                          ),
                        ),
                        if (operationType != null) ...[
                          SizedBox(height: sessionHeightPx >= 50 ? 8 : 6),
                          Text(
                            operationType == ReservationOperationType.create
                                ? '예약중'
                                : operationType ==
                                    ReservationOperationType.cancel
                                ? '취소중'
                                : '변경중',
                            style: TextStyle(
                              color: processingUiColor,
                              fontSize: sessionHeightPx >= 50 ? 18 : 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              if (!hasUserReservation && isLocked && !isBookingWeekOpened)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Icon(
                    Icons.lock_rounded,
                    size: sessionHeightPx >= 60 ? 18 : 14,
                    color: iconColor,
                  ),
                ),
              if (!hasUserReservation &&
                  isLocked &&
                  !isBookingWeekOpened &&
                  eligibility.reason == ReservationLockReason.notOpenedYet &&
                  eligibility.openAt != null &&
                  sessionHeightPx >= 70)
                Positioned(
                  bottom: 2,
                  right: 4,
                  child: Text(
                    '오픈 ${eligibility.openAt!.month}/${eligibility.openAt!.day} ${eligibility.openAt!.hour.toString().padLeft(2, '0')}:${eligibility.openAt!.minute.toString().padLeft(2, '0')}',
                    style: TextStyle(
                      color: iconColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // 시간대 목록 생성 (startHour ~ endHour-1, 1시간 단위)
  List<String> _generateTimeSlots({
    required int startHour,
    required int endHour,
  }) {
    final slots = <String>[];
    for (int hour = startHour; hour < endHour; hour++) {
      slots.add('${hour.toString().padLeft(2, '0')}:00');
    }
    return slots;
  }

  // 에러 UI 위젯 (애플 스타일)
  Widget _buildErrorWidget() {
    // 디버그: 에러 상태 확인
    debugPrint('[CalendarScreen] _buildErrorWidget 호출');
    debugPrint('[CalendarScreen] _errorMessage: $_errorMessage');
    debugPrint('[CalendarScreen] _errorType: $_errorType');

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
                          _subscribeWeekSessionReservations();
                        },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.textPrimary,
                  foregroundColor: Colors.white,
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

class _SlotLayout {
  final List<String> timeSlots;
  final List<double> slotHeights; // 각 시간 슬롯의 높이
  final List<double> slotTops; // prefix sum (0 포함, 마지막이 totalHeight)
  final int rangeStartMinutes;
  final int initialJumpMinute;
  final List<bool> isActive; // 각 시간 슬롯이 활성(세션이 있는) 구간인지

  const _SlotLayout({
    required this.timeSlots,
    required this.slotHeights,
    required this.slotTops,
    required this.rangeStartMinutes,
    required this.initialJumpMinute,
    required this.isActive,
  });

  double yForMinute(int minute) {
    final m = minute.clamp(
      rangeStartMinutes,
      rangeStartMinutes + (timeSlots.length * 60),
    );
    final offsetMinutes = m - rangeStartMinutes;
    final slotIndex = (offsetMinutes ~/ 60).clamp(0, timeSlots.length - 1);
    final within = offsetMinutes - (slotIndex * 60);
    final ppm = slotHeights[slotIndex] / 60.0;
    return slotTops[slotIndex] + (within * ppm);
  }
}
