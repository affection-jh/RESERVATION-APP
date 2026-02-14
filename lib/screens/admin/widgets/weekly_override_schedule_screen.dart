import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../theme/app_colors.dart';
import '../../../models/course.dart' as reservation_models;
import '../../../models/session_draft.dart';
import '../../../models/course_override.dart';
import '../../../policies/course_policy.dart';
import '../../../providers/course_provider.dart';
import '../../../providers/place_provider.dart';
import '../../../services/firestore_service.dart';
import '../../../utils/snackbar_util.dart';
import '../../../utils/timezone_utils.dart';
import '../../../utils/week_range_calculator.dart';
import '../../../widgets/week_tab_bar.dart';
import 'drag_calendar_editor.dart';
import 'session_edit_bottom_sheet.dart';

/// 비정기 일정 편집 화면
///
/// 특정 주에만 적용되는 비정기 일정을 관리합니다.
/// - 정기 일정 취소
/// - 새로운 비정기 일정 추가
class WeeklyOverrideScheduleScreen extends StatefulWidget {
  final int weekOffset; // 0: 이번주, 1: 다음주, ...
  final String? weekStartDate; // "YYYY-MM-DD" 형식, null이면 weekOffset으로 계산
  final String? selectedCourseId; // 선택된 코스 ID

  const WeeklyOverrideScheduleScreen({
    super.key,
    required this.weekOffset,
    this.weekStartDate,
    this.selectedCourseId,
  });

  @override
  State<WeeklyOverrideScheduleScreen> createState() =>
      _WeeklyOverrideScheduleScreenState();
}

class _WeeklyOverrideScheduleScreenState
    extends State<WeeklyOverrideScheduleScreen> {
  static const double _minHourSlotHeight = 80.0;

  final FirestoreService _firestoreService = FirestoreService();
  bool _isSaving = false;
  bool _isLoadingData = false; // 데이터 로딩 상태

  // 현재 주차 (위젯 파라미터에서 초기화, 이후 내부 상태로 관리)
  late int _currentWeekOffset;

  // 주의 시작 날짜 (월요일)
  late DateTime _weekStart;
  late String _weekStartDateString; // "YYYY-MM-DD"
  late List<DateTime> _weekDates; // 주의 7일

  // 정기 일정 (모든 코스)
  Map<String, List<reservation_models.CourseSession>> _regularSessions = {};

  // 편집 중인 세션 데이터
  Map<int, List<SessionDraft>> _daySessions = {}; // {dayOfWeek: [sessions]}
  Map<int, Set<String>> _cancelledSessions = {}; // {dayOfWeek: {startTime}}

  // 드래그 상태 추적
  bool _isAnyDragging = false;
  bool _didInitialJump = false;
  ScrollController? _calendarScrollController;

  // 각 요일의 DragCalendarEditor에 접근하기 위한 GlobalKey
  final Map<int, GlobalKey> _calendarEditorKeys = {};
  // 드래그 영역(캘린더 그리드) 기준 좌표용 - 상하단 자동스크롤
  final GlobalKey _dragAreaKey = GlobalKey();

  // 일괄등록 미리보기용 임시 세션
  String? _previewStartTime;
  String? _previewEndTime;
  int? _previewDayOfWeek;
  int _defaultCapacity = -1;

  // 초기 상태 저장 (변경사항 추적용)
  Map<int, List<SessionDraft>> _initialDaySessions = {};
  Map<int, Set<String>> _initialCancelledSessions = {};

  // 정책 기반 주차 범위 (기본값: 0~2주, 정책 + 2주까지 확장)
  List<int> _availableWeekOffsets = [0, 1, 2]; // 기본값

  // 정책 정보 (주차 오픈 여부 확인용)
  CoursePolicy? _coursePolicy;

  // 미리 열린 주차 여부 (bookingWeekOpens에서 확인)
  bool _isBookingWeekOpened = false;

  /// 저장 성공 후 pop 또는 사용자 뒤로가기 시 한 번만 pop 되도록 방지
  bool _isLeaving = false;

  void _popOnce(dynamic result) {
    if (_isLeaving || !mounted) return;
    _isLeaving = true;
    Navigator.of(context).pop(result);
  }

  @override
  void initState() {
    super.initState();
    _currentWeekOffset = widget.weekOffset;
    _calendarScrollController = ScrollController();
    _calculateWeekDates();
    // build가 완료된 후에 데이터 로드 (setState during build 에러 방지)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _loadData();
      }
    });
  }

  @override
  void dispose() {
    _calendarScrollController?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(WeeklyOverrideScheduleScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 위젯이 업데이트될 때 (과목 변경, 주 변경 등)
    if (oldWidget.selectedCourseId != widget.selectedCourseId ||
        oldWidget.weekOffset != widget.weekOffset ||
        oldWidget.weekStartDate != widget.weekStartDate) {
      // weekOffset이 변경되면 내부 상태도 업데이트
      if (oldWidget.weekOffset != widget.weekOffset) {
        _currentWeekOffset = widget.weekOffset;
      }
      // 주 날짜 재계산
      _calculateWeekDates();
      // 데이터 다시 로드 (로딩 중에도 이전 UI 유지)
      _loadData();
    }
  }

  void _calculateWeekDates() {
    final now = TimezoneUtils.getSeoulDateTime();
    final thisWeekMonday = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: now.weekday - DateTime.monday));

    if (widget.weekStartDate != null) {
      final parts = widget.weekStartDate!.split('-');
      _weekStart = DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );
    } else {
      _weekStart = thisWeekMonday.add(Duration(days: _currentWeekOffset * 7));
    }

    _weekStartDateString = TimezoneUtils.formatDateToSeoul(_weekStart);
    _weekDates = List.generate(7, (i) => _weekStart.add(Duration(days: i)));
  }

  DateTime _dateForDayOfWeek(int dayOfWeek) {
    return _weekDates.firstWhere(
      (d) => d.weekday == dayOfWeek,
      orElse:
          () =>
              _weekDates.isNotEmpty
                  ? _weekDates.first
                  : TimezoneUtils.getSeoulDateTime(),
    );
  }

  Future<void> _loadData() async {
    final placeId =
        Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id;
    if (placeId == null) {
      return;
    }

    // 로딩 시작
    if (mounted) {
      setState(() {
        _isLoadingData = true;
      });
    }

    try {
      // 선택된 코스의 정기 일정만 로드
      final courseProvider = Provider.of<CourseProvider>(
        context,
        listen: false,
      );
      await courseProvider.loadCourses(placeId);

      // 새 데이터를 임시 변수에 저장 (UI 업데이트는 한 번에)
      final newRegularSessions =
          <String, List<reservation_models.CourseSession>>{};

      // 선택된 코스만 필터링
      final targetCourses =
          widget.selectedCourseId != null
              ? courseProvider.courses
                  .where((c) => c.id == widget.selectedCourseId)
                  .toList()
              : courseProvider.courses;

      for (final course in targetCourses) {
        newRegularSessions[course.id] = course.sessions;
      }

      // 정책에서 허용하는 주차 + 2주까지만 선택 가능하도록 설정
      List<int> newAvailableWeekOffsets = [0, 1, 2]; // 기본값
      CoursePolicy? loadedPolicy;
      bool isOpenedByAdmin = false;
      final selectedCourseId = widget.selectedCourseId;
      if (selectedCourseId != null) {
        // 1) 정책 로드 (실패해도 null로 두지 말고 기본 정책으로 폴백)
        try {
          loadedPolicy = await _firestoreService.getCoursePolicy(
            courseId: selectedCourseId,
            placeId: placeId,
          );
        } catch (_) {
          loadedPolicy = CoursePolicy.defaultFor(
            courseId: selectedCourseId,
            placeId: placeId,
          );
        }

        // 2) 주차 탭 범위 = 정책 기반 + 2주(관리자 편집 여유)
        final policyOffsets = WeekRangeCalculator.getAvailableWeekOffsets(
          loadedPolicy,
        );
        if (policyOffsets.isNotEmpty) {
          final maxPolicyWeek = policyOffsets.reduce((a, b) => a > b ? a : b);
          final maxWeek = maxPolicyWeek + 2;
          newAvailableWeekOffsets = List.generate(maxWeek + 1, (i) => i);
        }

        // 3) "미리 예약 열기" 여부(bookingWeekOpens) 확인
        try {
          isOpenedByAdmin = await _firestoreService.isBookingWeekOpened(
            placeId: placeId,
            courseId: selectedCourseId,
            weekStartDate: _weekStartDateString,
          );
        } catch (_) {
          isOpenedByAdmin = false;
        }
      }

      // 비정기 일정 로드 (선택된 코스만)
      final overrides = await _firestoreService.getCourseOverrides(
        placeId: placeId,
        courseId: widget.selectedCourseId, // 선택된 코스만
        weekStartDate: _weekStartDateString,
      );

      // 새 데이터를 임시 변수에 저장
      final newOverrides = <String, List<CourseOverride>>{};
      final newCancelledSessions = <int, Set<String>>{};
      final newDaySessions = <int, List<SessionDraft>>{};

      for (final override in overrides) {
        if (!newOverrides.containsKey(override.courseId)) {
          newOverrides[override.courseId] = [];
        }
        newOverrides[override.courseId]!.add(override);

        if (override.isCancelled) {
          // 정기 일정 취소
          if (!newCancelledSessions.containsKey(override.dayOfWeek)) {
            newCancelledSessions[override.dayOfWeek] = {};
          }
          newCancelledSessions[override.dayOfWeek]!.add(
            override.startTime ?? '',
          );
        } else {
          // 새 세션 추가
          if (!newDaySessions.containsKey(override.dayOfWeek)) {
            newDaySessions[override.dayOfWeek] = [];
          }
          newDaySessions[override.dayOfWeek]!.add(
            SessionDraft(
              startTime: override.startTime!,
              endTime: override.endTime!,
              capacity: override.capacity ?? 0,
            ),
          );
        }
      }

      // 지나간 일정 필터링 (오늘 이전 날짜의 일정 제외)
      final now = TimezoneUtils.getSeoulDateTime();
      final today = DateTime(now.year, now.month, now.day);

      // 정기 일정도 표시용으로 추가 (취소되지 않은 것만, 지나간 일정 제외)
      for (final entry in newRegularSessions.entries) {
        for (final session in entry.value) {
          final dayOfWeek = session.dayOfWeek;
          final isCancelled =
              newCancelledSessions[dayOfWeek]?.contains(session.startTime) ??
              false;

          // 해당 요일의 날짜 확인
          final sessionDate = _weekDates.firstWhere(
            (d) => d.weekday == dayOfWeek,
            orElse: () => _weekDates.first,
          );
          final sessionDateTime = DateTime(
            sessionDate.year,
            sessionDate.month,
            sessionDate.day,
          );

          // 지나간 일정이면 제외
          if (sessionDateTime.isBefore(today)) {
            // 지나간 일정은 취소 목록에서도 제거
            if (newCancelledSessions.containsKey(dayOfWeek)) {
              newCancelledSessions[dayOfWeek]?.remove(session.startTime);
              if (newCancelledSessions[dayOfWeek]!.isEmpty) {
                newCancelledSessions.remove(dayOfWeek);
              }
            }
            continue;
          }

          if (!isCancelled) {
            // 정기 일정이 취소되지 않았으면 표시용으로 추가
            // (편집 불가, 회색으로 표시)
          }
        }
      }

      // 비정기 일정에서도 지나간 일정 제외
      for (final entry in newOverrides.entries.toList()) {
        final courseId = entry.key;
        final overrides = entry.value;
        final filteredOverrides = <CourseOverride>[];

        for (final override in overrides) {
          final overrideDate = _weekDates.firstWhere(
            (d) => d.weekday == override.dayOfWeek,
            orElse: () => _weekDates.first,
          );
          final overrideDateTime = DateTime(
            overrideDate.year,
            overrideDate.month,
            overrideDate.day,
          );

          // 지나간 일정이 아니면 유지
          if (!overrideDateTime.isBefore(today)) {
            filteredOverrides.add(override);
          }
        }

        if (filteredOverrides.isEmpty) {
          newOverrides.remove(courseId);
        } else {
          newOverrides[courseId] = filteredOverrides;
        }
      }

      // 추가된 세션에서도 지나간 일정 제외
      for (final entry in newDaySessions.entries.toList()) {
        final dayOfWeek = entry.key;

        final sessionDate = _weekDates.firstWhere(
          (d) => d.weekday == dayOfWeek,
          orElse: () => _weekDates.first,
        );
        final sessionDateTime = DateTime(
          sessionDate.year,
          sessionDate.month,
          sessionDate.day,
        );

        // 지나간 일정이면 제거
        if (sessionDateTime.isBefore(today)) {
          newDaySessions.remove(dayOfWeek);
        }
      }

      // 모든 데이터를 한 번에 업데이트 (UI 흔들림 방지)
      if (mounted) {
        setState(() {
          _regularSessions = newRegularSessions;
          _cancelledSessions = newCancelledSessions;
          _daySessions = newDaySessions;
          // 주차 범위 업데이트 (정책과 상관없이 0~9주까지 확장)
          _availableWeekOffsets = newAvailableWeekOffsets;
          // 정책 저장
          _coursePolicy = loadedPolicy;
          _isBookingWeekOpened = isOpenedByAdmin;
          // 초기 상태 저장 (변경사항 추적용)
          _initialDaySessions = Map.fromEntries(
            _daySessions.entries.map(
              (e) => MapEntry(
                e.key,
                e.value
                    .map(
                      (s) => SessionDraft(
                        startTime: s.startTime,
                        endTime: s.endTime,
                        capacity: s.capacity,
                      ),
                    )
                    .toList(),
              ),
            ),
          );
          _initialCancelledSessions = Map.fromEntries(
            _cancelledSessions.entries.map(
              (e) => MapEntry(e.key, Set.from(e.value)),
            ),
          );
          _isLoadingData = false; // 로딩 완료
          _didInitialJump = false; // 주차별 데이터 로드 후 스크롤을 첫 세션으로 맞추기 위해 리셋
        });
      }
    } catch (e) {
      debugPrint('[WeeklyOverrideScheduleScreen] 로드 실패: $e');
      if (mounted) {
        setState(() {
          _isLoadingData = false; // 에러 발생 시에도 로딩 상태 해제
        });
      }
    }
  }

  // 변경사항이 있는지 확인 (더 엄격한 비교)
  bool _hasChanges() {
    // 취소된 세션 변경 확인
    final cancelledKeys = _cancelledSessions.keys.toSet();
    final initialCancelledKeys = _initialCancelledSessions.keys.toSet();

    if (cancelledKeys.length != initialCancelledKeys.length) {
      return true;
    }

    for (final dayOfWeek in cancelledKeys) {
      final current = _cancelledSessions[dayOfWeek] ?? {};
      final initial = _initialCancelledSessions[dayOfWeek] ?? {};

      if (current.length != initial.length) {
        return true;
      }

      // 모든 항목이 정확히 일치하는지 확인
      if (!current.every((v) => initial.contains(v)) ||
          !initial.every((v) => current.contains(v))) {
        return true;
      }
    }

    // 추가된 세션 변경 확인
    final daySessionKeys = _daySessions.keys.toSet();
    final initialDaySessionKeys = _initialDaySessions.keys.toSet();

    if (daySessionKeys.length != initialDaySessionKeys.length) {
      return true;
    }

    for (final dayOfWeek in daySessionKeys) {
      final current = _daySessions[dayOfWeek] ?? [];
      final initial = _initialDaySessions[dayOfWeek] ?? [];

      if (current.length != initial.length) {
        return true;
      }

      // 세션 내용을 정확히 비교 (순서 무관)
      final currentMap = {
        for (final s in current) '${s.startTime}_${s.endTime}_${s.capacity}': s,
      };
      final initialMap = {
        for (final s in initial) '${s.startTime}_${s.endTime}_${s.capacity}': s,
      };

      if (currentMap.length != initialMap.length) {
        return true;
      }

      for (final key in currentMap.keys) {
        if (!initialMap.containsKey(key)) {
          return true;
        }
      }
    }

    return false;
  }

  /// 현재 주차가 정책상 오픈되었는지 확인
  /// (미리 열린 주차인 경우 true 반환)
  bool _isWeekOpenedByPolicy() {
    // 1) 먼저 미리 열린 주차인지 확인 (관리자가 "미리 예약 열기"를 한 경우)
    if (_isBookingWeekOpened) {
      return true;
    }

    if (_coursePolicy == null || widget.selectedCourseId == null) {
      // 정책이 없으면 기본적으로 오픈된 것으로 간주
      return true;
    }

    final now = TimezoneUtils.getSeoulDateTime();

    // 정책 타입에 따라 다른 로직 적용
    switch (_coursePolicy!.openStrategy.type) {
      case BookingOpenStrategyType.rollingWindow:
        // rollingWindow: "오늘부터 N일 뒤까지 오픈"
        // 주차 단위 오픈 판단은 "해당 주의 마지막 날짜(일요일)가 오픈 범위 안에 들어오는가"로 통일
        return _isWeekOpenedByRollingWindowPolicy();

      case BookingOpenStrategyType.weeklyRelease:
        // weeklyRelease: 주차 시작 날짜(월요일) 기준으로 오픈 시간 계산
        // 정책: "매주 월요일 09:00에 1주 뒤까지"라면
        // 다음 주가 오픈되는 시간은 이번 주 월요일 09:00
        final openAt = _computeOpenAtForWeeklyRelease(_weekStart);
        if (openAt == null) {
          return true; // 오픈 시간을 계산할 수 없으면 오픈된 것으로 간주
        }
        return now.isAfter(openAt) || now.isAtSameMomentAs(openAt);
    }
  }

  /// rollingWindow 정책: 주차 단위 오픈 여부 판단
  bool _isWeekOpenedByRollingWindowPolicy() {
    if (_coursePolicy == null) return true;
    final days = _coursePolicy!.openStrategy.rollingWindow?.windowDays ?? 21;
    final today = TimezoneUtils.getSeoulToday();
    final openUntil = today.add(Duration(days: (days - 1).clamp(0, 3650)));
    final weekEnd = TimezoneUtils.getSeoulDateOnly(
      _weekStart.add(const Duration(days: 6)),
    );
    // 주 마지막 날짜가 오픈 범위 내면 "해당 주는 오픈"으로 간주
    return !weekEnd.isAfter(openUntil);
  }

  /// weeklyRelease 정책: 주차 시작 날짜(월요일) 기준으로 오픈 시간 계산
  DateTime? _computeOpenAtForWeeklyRelease(DateTime weekStartDate) {
    if (_coursePolicy == null) return null;

    final s = _coursePolicy!.openStrategy.weeklyRelease;
    if (s == null) return null;

    final dateOnly = TimezoneUtils.getSeoulDateOnly(weekStartDate);

    // weekStartDate는 이미 월요일이므로 그대로 사용
    // weeksAhead 의미(정책 UI와 일치):
    // - weeksAhead=1: 이번주만 오픈 (해당 주의 releaseDay/releaseTime에 오픈)
    // - weeksAhead=2: 이번주+다음주 오픈 (다음 주는 이번주의 releaseDay/releaseTime에 오픈)
    final backWeeks = (s.weeksAhead - 1).clamp(0, 520);
    final openWeekStart = dateOnly.subtract(Duration(days: 7 * backWeeks));
    final parts = s.releaseTime.split(':');
    final h = int.tryParse(parts[0]) ?? 10;
    final m = int.tryParse(parts[1]) ?? 0;

    // 오픈 주차의 releaseDayOfWeek 요일에 releaseTime 시간에 오픈
    return TimezoneUtils.combineDateAndTimeSeoul(
      openWeekStart.add(Duration(days: (s.releaseDayOfWeek - 1))),
      '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}',
    );
  }

  @override
  Widget build(BuildContext context) {
    // 기본적으로 월~금(1~5) 표시, 지나간 요일 제외
    final now = TimezoneUtils.getSeoulDateTime();
    final today = DateTime(now.year, now.month, now.day);

    // 이번 주: 남은 요일만 표시 (토·일 포함). 다른 주: 월~금 + 세션 있는 요일.
    List<int> selectedDays;
    if (_currentWeekOffset == 0) {
      // 이번 주는 1~7 중 오늘 포함 이후 요일만 (토요일 밤이면 토·일만 표시)
      selectedDays =
          [1, 2, 3, 4, 5, 6, 7].where((day) {
            final date = _dateForDayOfWeek(day);
            final dateOnly = DateTime(date.year, date.month, date.day);
            return !dateOnly.isBefore(today);
          }).toList();
    } else {
      final defaultDays = <int>{1, 2, 3, 4, 5};
      for (final sessions in _regularSessions.values) {
        for (final session in sessions) {
          if (session.dayOfWeek >= 1 && session.dayOfWeek <= 7) {
            defaultDays.add(session.dayOfWeek);
          }
        }
      }
      for (final day in _daySessions.keys) {
        if (day >= 1 && day <= 7) {
          defaultDays.add(day);
        }
      }
      selectedDays = defaultDays.toList()..sort();
    }

    // 선택된 코스 정보 가져오기 (UI 표시용)
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final displayCourse =
        widget.selectedCourseId != null
            ? courseProvider.courses
                .where((c) => c.id == widget.selectedCourseId)
                .firstOrNull
            : null;

    return PopScope(
      canPop: !_isLeaving && !_isSaving,
      child: Scaffold(
        backgroundColor: AppColors.backgroundWhite,
        appBar: AppBar(
          backgroundColor: AppColors.backgroundWhite,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios, size: 24),
            onPressed: () => _popOnce(null),
            color: AppColors.textPrimary,
          ),
          title: Column(
            children: [
              Text(
                '비정기 일정 설정',
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '길게 눌러 드래그하기',
                style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              // 헤더
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 20,
                ),
                color: AppColors.backgroundWhite,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 연속 주차 표시 (이번주, 다음주, 다다음주)
                              _buildWeekTabs(),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // 메인 콘텐츠 (주차 변경 시에도 바깥 표는 유지, 안쪽만 로딩)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 요일 헤더 (항상 표시)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      color: AppColors.backgroundWhite,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 35,
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.only(left: 2),
                                child: Text(
                                  '시간',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          ...selectedDays.map((day) {
                            const dayNames = [
                              '',
                              '월',
                              '화',
                              '수',
                              '목',
                              '금',
                              '토',
                              '일',
                            ];
                            final date = _dateForDayOfWeek(day);
                            final dateStr = '${date.month}/${date.day}';
                            return Expanded(
                              child: Center(
                                child: Column(
                                  children: [
                                    Text(
                                      dayNames[day],
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.textPrimary,
                                      ),
                                    ),
                                    Text(
                                      dateStr,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ],
                      ),
                    ),
                    // 캘린더 영역: 로딩 중이면 스피너만, 로딩 완료 후 그리드 페이드 인
                    Expanded(
                      child:
                          _isLoadingData
                              ? Center(
                                child: CircularProgressIndicator(
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.transparent,
                                  ),
                                ),
                              )
                              : TweenAnimationBuilder<double>(
                                key: ValueKey('grid_$_currentWeekOffset'),
                                tween: Tween(begin: 0, end: 1),
                                duration: const Duration(milliseconds: 320),
                                curve: Curves.easeOut,
                                builder: (context, value, child) {
                                  return Opacity(opacity: value, child: child);
                                },
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    return _buildAllDaysCalendar(
                                      constraints.maxHeight,
                                      selectedDays,
                                    );
                                  },
                                ),
                              ),
                    ),
                  ],
                ),
              ),
              // 하단 버튼
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: AppColors.backgroundWhite,
                  border: Border(
                    top: BorderSide(color: AppColors.borderLight, width: 0.5),
                  ),
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed:
                        _isSaving
                            ? null
                            : (_isWeekOpenedByPolicy()
                                ? (_hasChanges() ? _saveOverrides : null)
                                : _saveOverrides), // ✅ 변경사항 없어도 "미리 예약 열기"는 가능
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryGreen,
                      disabledBackgroundColor: AppColors.borderLight,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      elevation: 0,
                    ),
                    child:
                        _isSaving
                            ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white,
                                ),
                              ),
                            )
                            : Text(
                              _isWeekOpenedByPolicy() ? '저장' : '미리 예약 열기',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAllDaysCalendar(double viewportHeight, List<int> selectedDays) {
    // 기본적으로 월~금 시간표 표시 (selectedDays가 비어있어도 시간표는 표시)

    // 전체 시간대 계산 (00:00 ~ 24:00)
    final hours = List.generate(24, (i) => i);
    final hourSlotHeight = (viewportHeight / 24).clamp(
      _minHourSlotHeight,
      double.infinity,
    );
    final totalHeight = hours.length * hourSlotHeight;

    // 주차별 진입/전환 시 스크롤을 해당 주의 첫 세션 시작 위치로 이동
    if (!_didInitialJump && _calendarScrollController != null) {
      _didInitialJump = true;
      final slotHeight = hourSlotHeight; // 콜백에서 사용할 값 캡처
      WidgetsBinding.instance.addPostFrameCallback((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted ||
              _calendarScrollController == null ||
              !_calendarScrollController!.hasClients)
            return;
          // 현재 주의 정기+비정기 세션에서 첫 시작 시간 계산
          final allStartTimes = <int>[];
          for (final entry in _regularSessions.entries) {
            for (final session in entry.value) {
              final dayOfWeek = session.dayOfWeek;
              final isCancelled =
                  _cancelledSessions[dayOfWeek]?.contains(session.startTime) ??
                  false;
              if (!isCancelled) {
                allStartTimes.add(_parseTimeToMinutes(session.startTime));
              }
            }
          }
          for (final entry in _daySessions.entries) {
            for (final session in entry.value) {
              allStartTimes.add(_parseTimeToMinutes(session.startTime));
            }
          }
          double targetY;
          if (allStartTimes.isEmpty) {
            targetY = 10 * slotHeight;
          } else {
            final firstStartMinutes = allStartTimes.reduce(
              (a, b) => a < b ? a : b,
            );
            final firstStartHour = firstStartMinutes ~/ 60;
            targetY =
                (firstStartHour * slotHeight) +
                ((firstStartMinutes % 60) / 60.0 * slotHeight) -
                (0.5 * slotHeight);
            targetY = targetY.clamp(0.0, double.infinity);
          }
          final maxExtent = _calendarScrollController!.position.maxScrollExtent;
          _calendarScrollController!.jumpTo(targetY.clamp(0.0, maxExtent));
        });
      });
    }

    return Container(
      key: _dragAreaKey,
      color: AppColors.backgroundWhite,
      child: SingleChildScrollView(
        controller: _calendarScrollController,
        physics:
            _isAnyDragging
                ? const NeverScrollableScrollPhysics()
                : const AlwaysScrollableScrollPhysics(),
        child: SizedBox(
          height: totalHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 시간 컬럼
              Container(
                width: 35,
                decoration: BoxDecoration(
                  color: AppColors.backgroundWhite,
                  border: Border(
                    right: BorderSide(color: AppColors.borderLight, width: 0.5),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children:
                      hours.map((hour) {
                        return Container(
                          height: hourSlotHeight,
                          alignment: Alignment.topRight,
                          padding: const EdgeInsets.only(right: 8, top: 0),
                          child: Text(
                            hour.toString().padLeft(2, '0'),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w400,
                              color: AppColors.textSecondary,
                              height: 1.0,
                            ),
                          ),
                        );
                      }).toList(),
                ),
              ),
              // 각 요일의 캘린더
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children:
                      selectedDays.map((day) {
                        return SizedBox(
                          width:
                              (MediaQuery.of(context).size.width - 35) /
                              selectedDays.length,
                          child: _buildDayScheduleEditor(
                            day,
                            hourSlotHeight: hourSlotHeight,
                            totalHeight: totalHeight,
                            scrollController: _calendarScrollController!,
                            dragAreaKey: _dragAreaKey,
                            onDragStateChanged: (isDragging) {
                              setState(() {
                                _isAnyDragging = isDragging;
                              });
                            },
                          ),
                        );
                      }).toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWeekTabs() {
    // 현재 weekOffset이 availableWeekOffsets에서 몇 번째 인덱스인지 찾기
    final selectedIndex = _availableWeekOffsets.indexOf(_currentWeekOffset);
    final currentIndex = selectedIndex >= 0 ? selectedIndex : 0;

    return WeekTabBar(
      selectedIndex: currentIndex,
      availableWeekOffsets: _availableWeekOffsets,
      showDot: true,
      onTabChanged: (index) {
        if (index < _availableWeekOffsets.length) {
          final newWeekOffset = _availableWeekOffsets[index];
          if (newWeekOffset != _currentWeekOffset) {
            // 주차 변경 (compact_calendar_widget.dart와 동일한 방식)
            // 1. 주차 변경 및 뷰포트 리셋
            setState(() {
              _currentWeekOffset = newWeekOffset;
              _didInitialJump = false; // 뷰포트 리셋
            });

            // 2. 주 날짜 재계산
            _calculateWeekDates();

            // 3. 데이터 로드 (이전 데이터는 유지하여 UI 흔들림 방지)
            // _loadData()에서 새 데이터를 임시 변수에 저장하고 한 번에 업데이트
            _loadData();
          }
        }
      },
    );
  }

  Widget _buildDayScheduleEditor(
    int dayOfWeek, {
    required double hourSlotHeight,
    required double totalHeight,
    required ScrollController scrollController,
    required GlobalKey dragAreaKey,
    required Function(bool) onDragStateChanged,
  }) {
    // 정기 일정 (취소되지 않은 것)
    final regularSessionsForDay = <SessionDraft>[];
    for (final entry in _regularSessions.entries) {
      for (final session in entry.value) {
        if (session.dayOfWeek == dayOfWeek) {
          final isCancelled =
              _cancelledSessions[dayOfWeek]?.contains(session.startTime) ??
              false;
          if (!isCancelled) {
            regularSessionsForDay.add(
              SessionDraft(
                startTime: session.startTime,
                endTime: session.endTime,
                capacity: session.capacity,
              ),
            );
          }
        }
      }
    }

    // 비정기 일정 (추가된 것)
    final overrideSessions = _daySessions[dayOfWeek] ?? [];

    // 미리보기 세션
    List<SessionDraft>? previewSessions;
    if (_previewStartTime != null &&
        _previewEndTime != null &&
        _previewDayOfWeek != null &&
        _previewDayOfWeek == dayOfWeek) {
      previewSessions = [
        SessionDraft(
          startTime: _previewStartTime!,
          endTime: _previewEndTime!,
          capacity: _defaultCapacity == -1 ? 0 : _defaultCapacity,
        ),
      ];
    }

    // GlobalKey가 없으면 생성
    if (!_calendarEditorKeys.containsKey(dayOfWeek)) {
      _calendarEditorKeys[dayOfWeek] = GlobalKey();
    }

    // 선택된 코스 색상 사용
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    Color courseColor = AppColors.primaryGreen;
    if (widget.selectedCourseId != null) {
      final selectedCourse =
          courseProvider.courses
              .where((c) => c.id == widget.selectedCourseId)
              .firstOrNull;
      if (selectedCourse != null) {
        courseColor = Color(selectedCourse.color);
      }
    } else if (courseProvider.courses.isNotEmpty) {
      courseColor = Color(courseProvider.courses.first.color);
    }

    // 모든 세션을 하나의 리스트로 합침 (정기 + 비정기)
    final allSessionsForDay = <SessionDraft>[];

    // 정기 일정 먼저 추가 (회색으로 표시)
    for (final regularSession in regularSessionsForDay) {
      allSessionsForDay.add(regularSession);
    }

    // 비정기 일정 추가 (코스 색상으로 표시)
    allSessionsForDay.addAll(overrideSessions);

    return Container(
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: AppColors.borderLight, width: 0.5),
        ),
      ),
      child: DragCalendarEditor(
        key: _calendarEditorKeys[dayOfWeek],
        dayOfWeek: dayOfWeek,
        sessions: allSessionsForDay,
        // 정기 세션이 있는 시간대에는 비정기 세션 추가 드래그를 막아야 함
        blockedSessions: regularSessionsForDay,
        previewSessions: previewSessions,
        defaultCapacity: _defaultCapacity,
        courseColor: courseColor,
        hourSlotHeight: hourSlotHeight,
        totalHeight: totalHeight,
        scrollController: scrollController,
        dragAreaKey: dragAreaKey,
        onSessionsChanged: (newSessions) {
          // 비정기 일정만 업데이트 (정기 일정 제외)
          // 주의: 이 콜백은 드래그로 세션을 추가/수정할 때만 호출되어야 함
          // 세션 클릭 시에는 호출되지 않아야 함
          final overrideOnly =
              newSessions.where((s) {
                return !regularSessionsForDay.any(
                  (r) => r.startTime == s.startTime && r.endTime == s.endTime,
                );
              }).toList();

          // 실제로 변경사항이 있는지 확인
          final currentSessions = _daySessions[dayOfWeek] ?? [];
          final hasActualChange =
              overrideOnly.length != currentSessions.length ||
              overrideOnly.any((s) {
                return !currentSessions.any(
                  (c) =>
                      c.startTime == s.startTime &&
                      c.endTime == s.endTime &&
                      c.capacity == s.capacity,
                );
              });

          if (hasActualChange) {
            setState(() {
              _daySessions[dayOfWeek] = overrideOnly;
            });
          }
        },
        onDragStateChanged: onDragStateChanged,
        onDragEnd: (startTime, endTime, day) {
          setState(() {
            _previewStartTime = null;
            _previewEndTime = null;
            _previewDayOfWeek = null;
          });
          _showSessionEditBottomSheet(startTime, endTime, day);
        },
        onEditSession: (session) {
          // 정기 일정인지 확인
          final isRegular = regularSessionsForDay.any(
            (r) =>
                r.startTime == session.startTime &&
                r.endTime == session.endTime,
          );

          if (isRegular) {
            // 정기 일정 탭 시 취소/복원
            _toggleCancelRegularSession(dayOfWeek, session.startTime);
          } else {
            // 비정기 일정 탭 시 편집 바텀시트
            _showSessionEditBottomSheet(
              session.startTime,
              session.endTime,
              dayOfWeek,
              existingSession: session,
            );
          }
        },
        isEditMode: true,
        // 세션별로 정기/비정기 구분을 위해 정기 세션 정보 전달
        regularSessions: regularSessionsForDay,
      ),
    );
  }

  void _showSessionEditBottomSheet(
    String startTime,
    String endTime,
    int dayOfWeek, {
    SessionDraft? existingSession,
  }) {
    final isEditMode = existingSession != null;
    final existingSessionsForDay = _daySessions[dayOfWeek] ?? [];

    setState(() {
      _previewStartTime = startTime;
      _previewEndTime = endTime;
      _previewDayOfWeek = dayOfWeek;
    });

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.7),
      isDismissible: true,
      enableDrag: true,
      useSafeArea: true,
      builder:
          (context) => Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
            child: SessionEditBottomSheet(
              initialStartTime: startTime,
              initialEndTime: endTime,
              initialCapacity:
                  existingSession?.capacity ??
                  (_defaultCapacity == -1 ? 0 : _defaultCapacity),
              courseName: '비정기 세션',
              dayOfWeek: dayOfWeek,
              selectedDays: {dayOfWeek},
              courseColor: AppColors.primaryGreen,
              canBulkCancel: false,
              existingSessions: existingSessionsForDay,
              allDaySessions: _daySessions,
              isEditMode: isEditMode,
              onBulkRegistrationChanged: (_) {
                // 비정기 일정에서는 일괄 등록 미지원
              },
              onCancel: () {
                setState(() {
                  _previewStartTime = null;
                  _previewEndTime = null;
                  _previewDayOfWeek = null;
                });
                _clearSelectionForDay(dayOfWeek);
              },
              onRegister: (newStartTime, newEndTime, capacity, bulkDays) {
                setState(() {
                  _previewStartTime = null;
                  _previewEndTime = null;
                  _previewDayOfWeek = null;
                  _defaultCapacity = capacity;

                  if (bulkDays != null && bulkDays.isNotEmpty) {
                    for (final bulkDay in bulkDays) {
                      if (!_daySessions.containsKey(bulkDay)) {
                        _daySessions[bulkDay] = [];
                      }
                      if (!_hasOverlap(bulkDay, newStartTime, newEndTime)) {
                        if (isEditMode) {
                          final index = _daySessions[bulkDay]!.indexWhere(
                            (s) =>
                                s.startTime == startTime &&
                                s.endTime == endTime,
                          );
                          if (index != -1) {
                            _daySessions[bulkDay]![index] = SessionDraft(
                              startTime: newStartTime,
                              endTime: newEndTime,
                              capacity: capacity,
                            );
                          }
                        } else {
                          _daySessions[bulkDay]!.add(
                            SessionDraft(
                              startTime: newStartTime,
                              endTime: newEndTime,
                              capacity: capacity,
                            ),
                          );
                        }
                      }
                    }
                  } else {
                    if (isEditMode) {
                      final index = _daySessions[dayOfWeek]!.indexOf(
                        existingSession,
                      );
                      if (index != -1) {
                        _daySessions[dayOfWeek]![index] = SessionDraft(
                          startTime: newStartTime,
                          endTime: newEndTime,
                          capacity: capacity,
                        );
                      }
                    } else {
                      if (!_daySessions.containsKey(dayOfWeek)) {
                        _daySessions[dayOfWeek] = [];
                      }
                      if (!_hasOverlap(dayOfWeek, newStartTime, newEndTime)) {
                        _daySessions[dayOfWeek]!.add(
                          SessionDraft(
                            startTime: newStartTime,
                            endTime: newEndTime,
                            capacity: capacity,
                          ),
                        );
                      }
                    }
                  }
                });
                _clearSelectionForDay(dayOfWeek);
              },
              onDelete:
                  isEditMode
                      ? (bulkDays) {
                        setState(() {
                          _previewStartTime = null;
                          _previewEndTime = null;
                          _previewDayOfWeek = null;
                          _daySessions[dayOfWeek]?.remove(existingSession);
                        });
                        _clearSelectionForDay(dayOfWeek);
                      }
                      : null,
            ),
          ),
    ).then((_) {
      setState(() {
        _previewStartTime = null;
        _previewEndTime = null;
        _previewDayOfWeek = null;
      });
      // 바텀시트가 닫힌 후 드래그 상태 초기화
      _clearSelectionForDay(dayOfWeek);
    });
  }

  void _clearSelectionForDay(int dayOfWeek) {
    final key = _calendarEditorKeys[dayOfWeek];
    if (key?.currentState != null) {
      (key!.currentState as dynamic).clearSelection();
    }
  }

  bool _hasOverlap(int dayOfWeek, String startTime, String endTime) {
    final sessions = _daySessions[dayOfWeek] ?? [];
    final newStart = _parseTimeToMinutes(startTime);
    final newEnd = _parseTimeToMinutes(endTime);

    for (final session in sessions) {
      final sessionStart = _parseTimeToMinutes(session.startTime);
      final sessionEnd = _parseTimeToMinutes(session.endTime);

      if (newStart < sessionEnd && newEnd > sessionStart) {
        return true;
      }
    }
    return false;
  }

  int _parseTimeToMinutes(String time) {
    final parts = time.split(':');
    final hour = int.parse(parts[0]);
    final minute = int.parse(parts[1]);
    return hour * 60 + minute;
  }

  // 취소 시 알림 전송 여부 저장 (dayOfWeek_startTime -> bool)
  final Map<String, bool> _cancelNotificationFlags = {};

  Future<void> _toggleCancelRegularSession(
    int dayOfWeek,
    String startTime,
  ) async {
    if (!_cancelledSessions.containsKey(dayOfWeek)) {
      _cancelledSessions[dayOfWeek] = {};
    }

    if (_cancelledSessions[dayOfWeek]!.contains(startTime)) {
      // 복원
      setState(() {
        _cancelledSessions[dayOfWeek]!.remove(startTime);
        _cancelNotificationFlags.remove('${dayOfWeek}_$startTime');
      });
      SnackbarUtil.showSuccess(context, '정기 일정이 복원되었습니다.');
    } else {
      // 취소 - 바텀시트로 알림 전송 여부 선택
      final key = '${dayOfWeek}_$startTime';
      bool sendNotification = true; // 기본값: 알림 전송

      // 세션 정보 찾기
      final courseProvider = Provider.of<CourseProvider>(
        context,
        listen: false,
      );
      final displayCourse =
          widget.selectedCourseId != null
              ? courseProvider.courses
                  .where((c) => c.id == widget.selectedCourseId)
                  .firstOrNull
              : null;

      final sessionDate = _weekDates.firstWhere(
        (d) => d.weekday == dayOfWeek,
        orElse: () => _weekDates.first,
      );
      final dateString = TimezoneUtils.formatDateToSeoul(sessionDate);

      final result = await showModalBottomSheet<Map<String, bool>>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withOpacity(0.7),
        isDismissible: true,
        enableDrag: true,
        useSafeArea: true,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              return Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: AppColors.backgroundWhite,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 헤더
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '정기 일정 취소',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              if (displayCourse != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                  '${displayCourse.name} - $dateString $startTime',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(context).pop(null),
                          color: AppColors.textSecondary,
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    const SizedBox(height: 24),
                    // 취소 버튼
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed:
                            () => Navigator.of(context).pop({
                              'confirmed': true,
                              'sendNotification': sendNotification,
                            }),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          foregroundColor: Colors.red,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                            side: const BorderSide(
                              color: Colors.red,
                              width: 1.5,
                            ),
                          ),
                          elevation: 0,
                        ),
                        child: const Text(
                          '세션 취소하기',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: MediaQuery.of(context).padding.bottom + 4),
                  ],
                ),
              );
            },
          );
        },
      );

      if (result != null && result['confirmed'] == true && mounted) {
        final shouldSendNotification = result['sendNotification'] ?? true;
        setState(() {
          _cancelledSessions[dayOfWeek]!.add(startTime);
          _cancelNotificationFlags[key] = shouldSendNotification;
        });
        SnackbarUtil.showSuccess(context, '정기 일정이 취소되었습니다.');
      }
    }
  }

  Future<void> _saveOverrides() async {
    if (_isSaving) return;

    final placeId =
        Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id;
    if (placeId == null) {
      SnackbarUtil.showInfo(context, '플레이스를 찾을 수 없습니다.');
      return;
    }

    setState(() => _isSaving = true);

    try {
      // 선택된 코스 ID 확인
      final courseId =
          widget.selectedCourseId ?? _regularSessions.keys.firstOrNull;
      if (courseId == null) {
        SnackbarUtil.showInfo(context, '코스를 선택해주세요');
        setState(() => _isSaving = false);
        return;
      }

      final isPreOpen = !_isWeekOpenedByPolicy();
      final hasChanges = _hasChanges();

      // ✅ 변경사항이 없어도 정책상 아직 안 열렸다면 "미리 예약 열기"만 수행
      if (isPreOpen && !hasChanges) {
        try {
          await _firestoreService.setBookingWeekOpened(
            placeId: placeId,
            courseId: courseId,
            weekStartDate: _weekStartDateString,
          );
        } catch (e) {
          debugPrint('[WeeklyOverrideScheduleScreen] 미리 예약 열기 실패: $e');
          if (mounted) {
            SnackbarUtil.showInfo(context, '미리 예약 열기에 실패했습니다.');
          }
          return;
        }

        if (mounted) {
          SnackbarUtil.showSuccess(context, '예약이 미리 열렸습니다.');
          _popOnce(true);
        }
        return;
      }

      // 기존 override 중 취소되지 않은 것만 삭제 (취소된 세션은 유지)
      final existingOverrides = await _firestoreService.getCourseOverrides(
        placeId: placeId,
        courseId: courseId,
        weekStartDate: _weekStartDateString,
      );

      // 취소할 세션들의 키 생성 (dayOfWeek_startTime)
      final cancelledKeys = <String>{};
      for (final entry in _cancelledSessions.entries) {
        final dayOfWeek = entry.key;
        for (final startTime in entry.value) {
          cancelledKeys.add('${dayOfWeek}_$startTime');
        }
      }

      // 삭제 작업들을 병렬로 실행 (UI 블로킹 방지)
      // 취소된 세션은 제외하고 삭제
      final deleteFutures = <Future>[];
      for (final override in existingOverrides) {
        // 취소된 세션이면 삭제하지 않음 (나중에 업데이트할 것)
        final overrideKey = '${override.dayOfWeek}_${override.startTime ?? ''}';
        if (cancelledKeys.contains(overrideKey)) {
          continue;
        }

        deleteFutures.add(
          _firestoreService.upsertCourseOverride(
            placeId: placeId,
            courseId: courseId,
            date: override.date,
            dayOfWeek: override.dayOfWeek,
            weekStartDate: _weekStartDateString,
            action: 'delete',
            overrideId: override.id,
            sendNotification: false,
          ),
        );
      }

      // 삭제 작업 완료 대기 (병렬 처리)
      if (deleteFutures.isNotEmpty) {
        await Future.wait(deleteFutures);
        // UI 업데이트를 위해 이벤트 루프에 제어권 반환
        await Future.delayed(const Duration(milliseconds: 10));
      }

      // 추가된 세션들 (Functions로 처리 - 알림 포함) - 병렬 처리
      final createFutures = <Future>[];
      for (final entry in _daySessions.entries) {
        final dayOfWeek = entry.key;
        final sessions = entry.value;
        final date = TimezoneUtils.formatDateToSeoul(
          _dateForDayOfWeek(dayOfWeek),
        );

        for (final session in sessions) {
          createFutures.add(
            _firestoreService.upsertCourseOverride(
              placeId: placeId,
              courseId: courseId,
              date: date,
              dayOfWeek: dayOfWeek,
              startTime: session.startTime,
              endTime: session.endTime,
              capacity: session.capacity,
              weekStartDate: _weekStartDateString,
              isCancelled: false,
              action: 'create',
              sendNotification: true, // 알림 전송
            ),
          );
        }
      }

      // 추가 작업 완료 대기 (병렬 처리)
      if (createFutures.isNotEmpty) {
        await Future.wait(createFutures);
        // UI 업데이트를 위해 이벤트 루프에 제어권 반환
        await Future.delayed(const Duration(milliseconds: 10));
      }

      // 취소된 정기 세션들 (Functions로 처리 - 기존 예약자 처리 + 알림) - 병렬 처리
      final cancelFutures = <Future>[];
      for (final entry in _cancelledSessions.entries) {
        final dayOfWeek = entry.key;
        final startTimes = entry.value;
        final date = TimezoneUtils.formatDateToSeoul(
          _dateForDayOfWeek(dayOfWeek),
        );

        for (final startTime in startTimes) {
          final key = '${dayOfWeek}_$startTime';
          final sendNotification =
              _cancelNotificationFlags[key] ?? true; // 기본값: 알림 전송

          // 기존 override가 있는지 확인 (이미 취소된 세션이면 업데이트)
          final existingOverride = existingOverrides.firstWhere(
            (o) =>
                o.dayOfWeek == dayOfWeek &&
                o.startTime == startTime &&
                o.date == date,
            orElse:
                () => CourseOverride(
                  id: '',
                  courseId: courseId,
                  placeId: placeId,
                  date: date,
                  dayOfWeek: dayOfWeek,
                  startTime: startTime,
                  weekStartDate: _weekStartDateString,
                  createdAt: DateTime.now(),
                ),
          );

          cancelFutures.add(
            _firestoreService.upsertCourseOverride(
              placeId: placeId,
              courseId: courseId,
              date: date,
              dayOfWeek: dayOfWeek,
              startTime: startTime,
              weekStartDate: _weekStartDateString,
              isCancelled: true,
              action: existingOverride.id.isNotEmpty ? 'update' : 'create',
              overrideId:
                  existingOverride.id.isNotEmpty ? existingOverride.id : null,
              sendNotification: sendNotification,
            ),
          );
        }
      }

      // 취소 작업 완료 대기 (병렬 처리)
      if (cancelFutures.isNotEmpty) {
        await Future.wait(cancelFutures);
      }

      // 정책상 오픈되지 않은 주차인 경우 "미리 예약 열기" 처리
      if (isPreOpen) {
        try {
          await _firestoreService.setBookingWeekOpened(
            placeId: placeId,
            courseId: courseId,
            weekStartDate: _weekStartDateString,
          );
        } catch (e) {
          debugPrint('[WeeklyOverrideScheduleScreen] 미리 예약 열기 실패: $e');
          // 미리 열기 실패해도 저장은 성공한 것으로 처리
        }
      }

      if (mounted) {
        SnackbarUtil.showSuccess(context, '저장되었습니다.');

        // 저장 성공 후 화면을 닫고 부모 화면에서 데이터를 다시 로드하도록 함 (한 번만 pop)
        _popOnce(true);
      }
    } catch (e) {
      if (mounted) {
        debugPrint('저장 중 오류: $e');
        SnackbarUtil.showInfo(context, '저장 중 오류가 발생했습니다');
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }
}
