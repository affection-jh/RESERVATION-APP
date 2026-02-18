import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:reservation/utils/snackbar_util.dart';
import '../models/course.dart';
import '../models/session_reservation.dart';
import '../models/session_reservation_summary.dart';
import '../models/course_enrollment.dart';
import '../models/course_override.dart';
import '../models/course_policy.dart';
import '../utils/reservation_policy_engine.dart';
import '../services/firestore_service.dart';
import '../utils/timezone_utils.dart';
import '../utils/calendar_utils.dart';
import '../utils/firestore_utils.dart';
import '../theme/app_colors.dart';
import '../utils/local_storage_util.dart';
import 'session_block_style.dart';
import '../providers/place_provider.dart';
import '../providers/reservation_provider.dart';
import '../providers/reservation_summary_provider.dart';
import '../providers/course_provider.dart';
import '../utils/session_slot_builder.dart';
import 'package:provider/provider.dart';
import 'session_manage_bottom_sheet.dart';
import '../widgets/common_dialog.dart';

/// CompactCalendarWidget 사용 목적(모드)
///
/// - adminNavigate: 관리자 홈 등에서 "조회/이동" 목적. 잠김/만석/과거여도 **탭은 가능**해야 함.
/// - adminSelectNewSlot: 관리자 예약 변경에서 "새 슬롯 선택" 목적. **과거/만석은 선택 불가**.
/// - userWeeklyReservationsView: 마이페이지 "내 예약(이번주) 보기" 목적(기본적으로 보기+탭 가능).
/// - courseDetailView: 코스 상세 화면용. 눈금/세션박스 압축으로 스크롤 없이 맞춤, 남은자리 표시 숨김.
enum CompactCalendarUsage {
  adminNavigate,
  adminSelectNewSlot,
  userWeeklyReservationsView,
  courseDetailView,
}

/// 홈 화면용 간소화된 캘린더 위젯
class CompactCalendarWidget extends StatefulWidget {
  final List<Course> courses;
  final int weekOffset; // 0: 이번주, 1: 다음주, 2: 다다음주
  final double height;
  final Function(Course course, CourseSession session, DateTime date)?
  onSessionTap;
  final VoidCallback? onAddCourseTap; // 코스 등록하기 버튼 콜백
  final Function(Course? course)? onCourseSelected; // 코스 선택 콜백
  final bool hideCourseSelector; // 코스 드롭다운 숨기기
  final int? currentReservationDayOfWeek; // 현재 예약된 세션의 요일
  final String? currentReservationStartTime; // 현재 예약된 세션의 시작 시간
  final DateTime? currentReservationDate; // 현재 예약된 날짜
  final int? selectedSessionDayOfWeek; // 선택된 타겟 세션의 요일 (외부에서 전달)
  final String? selectedSessionStartTime; // 선택된 타겟 세션의 시작 시간 (외부에서 전달)
  final DateTime? selectedSessionDate; // 선택된 타겟 세션의 날짜 (외부에서 전달)

  // 일정보기 모드 (마이페이지용)
  final bool weeklyViewMode; // 일정보기 모드 활성화
  final List<SessionReservation>? userReservations; // 사용자의 예약 리스트 (일정보기 모드용)
  final Map<String, dynamic>? highlightReservation; // 강조할 예약 정보
  final Color? backgroundColor; // 배경색 (기본값: AppColors.backgroundWhite)
  final bool adminSelectionMode; // 관리자 선택 모드(잠긴 세션도 선택 가능)
  final Map<String, CourseEnrollment>? enrollmentsByCourseId; // 유저 등록 정보(코스별)
  final CompactCalendarUsage? usage; // 신규: 사용 목적(모드) - 명시적으로 상태/탭 규칙 분리
  /// 확대되지 않았을 때 좌우 스와이프로 주차 변경 시 호출 (주차가 여러 개인 화면에서 사용)
  final VoidCallback? onSwipeToPrevWeek;
  final VoidCallback? onSwipeToNextWeek;

  /// 열린 주차 전체 범위. 전달 시 Provider가 전체 구독해 두고 주차 전환 시 재구독 안 함.
  final List<int>? availableWeekOffsets;

  const CompactCalendarWidget({
    super.key,
    required this.courses,
    this.weekOffset = 0,
    this.height = 300,
    this.onSessionTap,
    this.onAddCourseTap,
    this.onCourseSelected,
    this.hideCourseSelector = false,
    this.currentReservationDayOfWeek,
    this.currentReservationStartTime,
    this.currentReservationDate,
    this.selectedSessionDayOfWeek,
    this.selectedSessionStartTime,
    this.selectedSessionDate,
    this.weeklyViewMode = false,
    this.userReservations,
    this.highlightReservation,
    this.backgroundColor,
    this.adminSelectionMode = false,
    this.enrollmentsByCourseId,
    this.usage,
    this.onSwipeToPrevWeek,
    this.onSwipeToNextWeek,
    this.availableWeekOffsets,
  });

  @override
  State<CompactCalendarWidget> createState() => _CompactCalendarWidgetState();
}

class _CompactCalendarWidgetState extends State<CompactCalendarWidget>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  Course? _selectedCourse;
  CourseSession? _selectedSession; // 선택된 세션
  DateTime? _selectedDate; // 선택된 날짜
  AnimationController? _shakeController;
  Animation<double>? _shakeAnimation;

  final FirestoreService _firestoreService = FirestoreService();
  CoursePolicy? _coursePolicy;

  // 현재 주차 추적 (주차 변경 감지용)
  String? _currentWeekStartDate;
  // 동일한 (placeId|courseId|weekStartDate)로 중복 재구독/재로딩을 막기 위한 키
  String? _weekSubscriptionKey;
  // 현재 구독 중인 코스 ID (코스 변경 감지용)
  String? _subscribedCourseId;
  // 취소 중인 세션 추적 (로딩 스피너 표시용)
  final Set<String> _cancellingSessions = {}; // "date|dayOfWeek|startTime" 형식
  // 코스 변경 중 로딩 상태
  bool _isLoadingCourse = false;
  // 주차 변경 중 로딩 상태 (admin_home_screen 모드용)
  bool _isLoadingWeek = false;
  // 주차 전환 후 레이아웃 안정화 후 그리드 페이드인 (calendar_screen과 동일)
  bool _showGridAfterLoad = true;
  // 마지막 선택 코스 복원 상태 (place 로드 타이밍 이슈 방지)
  bool _didRestoreLastSelectedCourse = false;
  bool _isRestoringLastSelectedCourse = false;

  // 그리드 가로 축 스케일 (핀치 줌): 세로는 고정, 가로만 확대/축소
  double _gridScale = 1.0;
  double _scaleStart = 1.0;
  double _pendingGridScale = 1.0;
  // 핀치 제스처 중에는 드래그(스크롤) 막기
  bool _isPinching = false;
  // 멀티터치 시 스크롤보다 핀치 우선: 화면에 닿은 포인터 수
  final Set<int> _activePointers = {};
  // 확대 안 됐을 때 좌우 스와이프로 주차 변경 감지용 (단일 손가락만)
  int _pointerCountAtScaleStart = 0;
  // UI 상수 정의 (compact calendar용) - 스크롤 최소화를 위해 압축 허용
  static const double _minHourSlotHeight = 38.0; // 세션이 있는 구간 최소 한 시간당 높이 (px)
  static const double _minGapHourSlotHeight = 12.0; // 공백 구간 축소 하한 (px/h)
  static const int _mergeGapMinHours = 3; // 이 시간(시간) 이상 연속 공백은 하나로 합쳐(건너뛰기) 표시
  static const double _mergedGapSlotHeight = 20.0; // 병합 공백 최소 높이(px)
  static const double _mergedGapPxPerHour = 14.0; // 병합 공백: 시간당 px
  static const double _minActiveSlotHeight =
      28.0; // 압축 시 active 슬롯 하한 (스크롤 최소화용)
  // courseDetailView(코스 상세): 스크롤 없이 맞추기 위해 압축 한도 더 낮춤
  double get _effectiveMinGapHourSlotHeight =>
      _usage == CompactCalendarUsage.courseDetailView
          ? 6.0
          : _minGapHourSlotHeight;
  double get _effectiveMergedGapSlotHeight =>
      _usage == CompactCalendarUsage.courseDetailView
          ? 12.0
          : _mergedGapSlotHeight;
  double get _effectiveMinActiveSlotHeight =>
      _usage == CompactCalendarUsage.courseDetailView
          ? 20.0
          : _minActiveSlotHeight;
  double get _effectiveMergedGapPxPerHour =>
      _usage == CompactCalendarUsage.courseDetailView
          ? 10.0
          : _mergedGapPxPerHour;
  double get _effectiveMinHourSlotHeight =>
      _usage == CompactCalendarUsage.courseDetailView
          ? 28.0
          : _minHourSlotHeight;
  static const int _mergedGapInnerTickCount =
      2; // 합쳐진 긴 공백 슬롯 내부에 그릴 미세 눈금선 개수(최대)
  static const int _edgePaddingMinutes = 30; // 00시, 23시 경계에 추가할 여백(분)
  static const double _timeColumnWidth = 35.0; // 시간대 컬럼 너비 (px)
  // 패딩(8*2)+테두리(1)+텍스트2줄(~38) → 52로는 부족해 11px overflow 발생. 64로 여유 확보.
  static const double _kDayHeaderHeight = 64.0; // 요일 헤더 높이 (scale 내부 레이아웃용)
  static const double _lineOffset = 1.0; // 가로선을 아래로 이동하는 오프셋 (px)
  static const double _sessionPadding = 2.0; // 세션 블록 좌우 패딩 (px)
  static const double _dateColumnSpacing = 0.0; // 날짜 컬럼 간 간격 (px)
  static const double _timeTextPaddingRight = 8.0; // 시간 텍스트 오른쪽 패딩 (px)
  static const int _basePaddingMinutes = 120; // 세션 위/아래 기본 여백(2시간)
  // 레이아웃 높이에서 줄일 하단 여백 (0이면 눈금 여백 없이 전체 높이 사용)
  static const double _minBottomPadding = 0.0;

  final ScrollController _scrollController = ScrollController();
  bool _didInitialJump = false;
  bool _isDropdownOpen = false;

  static int _floorToHour(int minutes) => (minutes ~/ 60) * 60;
  static int _ceilToHour(int minutes) =>
      ((minutes + 59) ~/ 60) * 60; // 올림(1~59분 포함)

  /// 관리자 홈 모드에서 길게 눌러서 세션 관리 (취소, 수용인원 변경)
  Future<void> _showCancelSessionDialog(
    Course course,
    CourseSession session,
    DateTime date,
  ) async {
    // 지나간 일정은 취소 불가 (날짜 + 시간까지 고려)
    final now = TimezoneUtils.getSeoulDateTime();
    final sessionStartTime = session.startTime.split(':');
    final sessionHour = int.parse(sessionStartTime[0]);
    final sessionMinute = int.parse(sessionStartTime[1]);
    final sessionDateTime = DateTime(
      date.year,
      date.month,
      date.day,
      sessionHour,
      sessionMinute,
    );

    if (sessionDateTime.isBefore(now)) {
      if (mounted) {
        SnackbarUtil.showInfo(context, '지나간 일정은 취소할 수 없습니다.');
      }
      return;
    }

    final dateString = TimezoneUtils.formatDateToSeoul(date);
    final dateKey = CalendarUtils.formatDateYMD(date);
    final weekStartForDate = DateTime(
      date.year,
      date.month,
      date.day,
    ).subtract(Duration(days: date.weekday - DateTime.monday));
    final weekStartDateForDate = TimezoneUtils.formatDateToSeoul(
      weekStartForDate,
    );

    // 추가된 비정기(override) 세션인지 확인 → CourseProvider 결과만 사용
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final overridesForDate =
        courseProvider
            .getOverridesForWeek(weekStartDateForDate)
            .where((o) => o.date == dateKey)
            .toList();
    CourseOverride? addedOverride;
    try {
      addedOverride = overridesForDate.firstWhere(
        (o) =>
            o.isCancelled != true &&
            o.courseId == course.id &&
            o.date == dateKey &&
            o.dayOfWeek == session.dayOfWeek &&
            o.startTime == session.startTime &&
            (o.endTime == null || o.endTime == session.endTime),
      );
    } catch (_) {
      addedOverride = null;
    }

    // 현재 수용인원·예약 수는 중앙 ReservationSummaryProvider에서만 사용
    final courseId = course.id;
    final sessionId = SessionReservationSummary.generateSessionId(
      courseId,
      session.dayOfWeek,
      session.startTime,
    );
    final srProvider = Provider.of<ReservationSummaryProvider>(
      context,
      listen: false,
    );
    final sr = srProvider.getSessionReservationSummary(sessionId, dateKey);
    final currentCapacity = srProvider.getTotalCapacity(
      sessionId,
      dateKey,
      fallback: session.capacity,
    );
    final reservedCount = sr?.reservedCount ?? 0;

    final result = await showSessionManageBottomSheet(
      context: context,
      course: course,
      dateString: dateString,
      startTime: session.startTime,
      endTime: session.endTime,
      currentCapacity: currentCapacity,
      reservedCount: reservedCount,
      onCapacityChanged: (newCapacity) async {
        final placeId =
            Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id;
        if (placeId == null || placeId.isEmpty) {
          SnackbarUtil.showInfo(context, '플레이스를 찾을 수 없습니다.');
          return;
        }
        if (!await FirestoreUtils.canReachFirestoreForSave(
          probeCollection: 'places',
          probeDocId: placeId,
        )) {
          if (mounted) {
            SnackbarUtil.showInfo(context, '네트워크 연결을 확인해주세요. ');
          }
          return;
        }
        await _firestoreService.setCapacityOverride(
          placeId: placeId,
          sessionId: sessionId,
          date: dateKey,
          capacity: newCapacity,
        );
        // 중앙 프로바이더만 갱신 (UI는 watch로 자동 리빌드)
        if (mounted) {
          Provider.of<ReservationSummaryProvider>(
            context,
            listen: false,
          ).updateCapacityLocally(sessionId, dateKey, newCapacity);
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
      message: '이 세션을 취소하시겠습니까?\n세션의 모든 예약이 취소됩니다.',
      cancelText: '취소',
      confirmText: '확인',
      confirmButtonColor: Colors.red,
    );

    if (confirmed != true || !mounted) return;

    // 취소 중인 세션 키 생성
    final cancellingKey =
        '$dateString|${session.dayOfWeek}|${session.startTime}';

    // 확인 다이얼로그가 닫힌 직후 즉시 로딩 스피너 표시
    if (mounted) {
      setState(() {
        _cancellingSessions.add(cancellingKey);
      });
    }

    try {
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final placeId = placeProvider.currentPlace?.id;
      if (placeId == null) {
        setState(() {
          _cancellingSessions.remove(cancellingKey);
        });
        return;
      }
      if (!await FirestoreUtils.canReachFirestoreForSave(
        probeCollection: 'places',
        probeDocId: placeId,
      )) {
        if (mounted) {
          setState(() => _cancellingSessions.remove(cancellingKey));
          SnackbarUtil.showInfo(context, '네트워크 연결을 확인해주세요. ');
        }
        return;
      }

      final weekStart = DateTime(
        date.year,
        date.month,
        date.day,
      ).subtract(Duration(days: date.weekday - DateTime.monday));
      final weekStartDate = TimezoneUtils.formatDateToSeoul(weekStart);

      final shouldSendNotification = result['sendNotification'] ?? true;

      final Map<String, dynamic> upsertResult =
          await (addedOverride != null
              ? _firestoreService.upsertCourseOverride(
                placeId: placeId,
                courseId: course.id,
                date: dateString,
                dayOfWeek: session.dayOfWeek,
                startTime: session.startTime,
                endTime: session.endTime,
                weekStartDate: weekStartDate,
                action: 'delete',
                overrideId: addedOverride.id,
                sendNotification: shouldSendNotification,
              )
              : _firestoreService.upsertCourseOverride(
                placeId: placeId,
                courseId: course.id,
                date: dateString,
                dayOfWeek: session.dayOfWeek,
                startTime: session.startTime,
                weekStartDate: weekStartDate,
                isCancelled: true,
                action: 'create',
                sendNotification: shouldSendNotification,
              ));

      if (mounted) {
        setState(() => _cancellingSessions.remove(cancellingKey));
        // override 상태는 CourseProvider에서만 관리 (UI 즉시 반영)
        if (addedOverride != null) {
          courseProvider.removeOverrideOptimistically(
            weekStartDate,
            addedOverride.id,
          );
        } else {
          final overrideId =
              (upsertResult['overrideId'] as String?)?.trim() ?? '';
          final effectiveOverrideId =
              overrideId.isNotEmpty
                  ? overrideId
                  : CourseOverride.overrideDocIdForCancel(
                    course.id,
                    dateKey,
                    session.startTime,
                  );
          courseProvider.addOverrideOptimistically(
            weekStartDate,
            CourseOverride.cancelSession(
              id: effectiveOverrideId,
              courseId: course.id,
              placeId: placeId,
              date: dateKey,
              dayOfWeek: session.dayOfWeek,
              startTime: session.startTime,
              weekStartDate: weekStartDate,
            ),
          );
        }
        SnackbarUtil.showSuccess(
          context,
          addedOverride != null ? '세션이 삭제되었습니다.' : '세션이 취소되었습니다.',
        );
      }
    } catch (e) {
      debugPrint('[CompactCalendarWidget] Error canceling session: $e');
      if (mounted) {
        setState(() {
          _cancellingSessions.remove(cancellingKey);
        });
        SnackbarUtil.showInfo(context, '오류가 발생했습니다.');
      }
    }
  }

  @override
  void initState() {
    super.initState();
    // 저장된 마지막 선택 코스 복원
    _restoreLastSelectedCourse();

    // 강조 시 흔들기 애니메이션용 컨트롤러 (글로우는 사용하지 않음)
    if (widget.highlightReservation != null) {
      _shakeController = AnimationController(
        duration: const Duration(milliseconds: 2000),
        vsync: this,
      );
      _shakeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _shakeController!, curve: Curves.easeInOut),
      );
      _shakeController!.forward();
    }
  }

  /// 저장된 마지막 선택 코스 복원
  Future<void> _restoreLastSelectedCourse() async {
    if (widget.courses.isEmpty) return;
    if (_isRestoringLastSelectedCourse) return;

    try {
      _isRestoringLastSelectedCourse = true;
      // PlaceProvider에서 현재 플레이스 가져오기
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final currentPlace = placeProvider.currentPlace;
      if (currentPlace == null) {
        // 플레이스가 아직 로드되지 않았으면 일단 첫 코스를 보여주되,
        // placeId가 생기면 didChangeDependencies에서 한 번 더 복원 시도
        if (mounted) {
          setState(() {
            _selectedCourse = widget.courses.first;
          });
          // 콜백 호출
          widget.onCourseSelected?.call(widget.courses.first);
        }
        return;
      }

      // 저장된 마지막 선택 코스 ID 가져오기
      final storageService = StorageService();
      final scope =
          (_usage == CompactCalendarUsage.adminNavigate ||
                  _usage == CompactCalendarUsage.adminSelectNewSlot)
              ? StorageService.scopeAdmin
              : StorageService.scopeMember;
      final lastCourseId = await storageService.getLastSelectedCourseId(
        currentPlace.id,
        scope: scope,
      );

      if (lastCourseId != null) {
        // 저장된 코스가 현재 코스 목록에 있는지 확인
        final savedCourse = widget.courses.firstWhere(
          (course) => course.id == lastCourseId,
          orElse: () => widget.courses.first,
        );

        if (mounted) {
          setState(() {
            _selectedCourse = savedCourse;
          });
          // 콜백 호출
          widget.onCourseSelected?.call(savedCourse);
        }
      } else {
        // 저장된 코스가 없으면 첫 번째 코스 선택
        if (mounted) {
          setState(() {
            _selectedCourse = widget.courses.first;
          });
          // 콜백 호출
          widget.onCourseSelected?.call(widget.courses.first);
        }
      }
      _didRestoreLastSelectedCourse = true;
    } catch (e) {
      // 에러 발생 시 첫 번째 코스 선택
      if (mounted) {
        setState(() {
          _selectedCourse = widget.courses.first;
        });
        // 콜백 호출
        widget.onCourseSelected?.call(widget.courses.first);
      }
      _didRestoreLastSelectedCourse = true;
    } finally {
      _isRestoringLastSelectedCourse = false;
    }

    // 선택 코스가 확정된 뒤, 해당 주차의 예약 현황/정책을 구독
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ensureWeekSubscriptions(resetViewport: true);
    });
  }

  void _ensureWeekSubscriptions({bool resetViewport = false}) {
    final course = _selectedCourse;
    if (course == null) return;
    if (widget.weeklyViewMode) return;

    final placeId =
        Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id;
    if (placeId == null || placeId.isEmpty) return;

    final now = TimezoneUtils.getSeoulDateTime();
    final offsets = widget.availableWeekOffsets ?? [widget.weekOffset];
    final maxOffset =
        offsets.isNotEmpty ? offsets.reduce((a, b) => a > b ? a : b) : 0;
    // 전체 범위 구독: placeId|courseId만 키로 → 주차 전환 시 재구독 안 함
    final firstWeekStart = CalendarUtils.weekStartFrom(now, 0);
    final lastWeekStart = CalendarUtils.weekStartFrom(now, maxOffset);
    final startDate = DateTime(
      firstWeekStart.year,
      firstWeekStart.month,
      firstWeekStart.day,
    );
    final endDate = lastWeekStart.add(const Duration(days: 6));
    final firstWeekStartDateStr = CalendarUtils.formatDateYMD(firstWeekStart);

    final nextKey = '$placeId|${course.id}';
    if (_weekSubscriptionKey == nextKey) {
      if (resetViewport) {
        _didInitialJump = false;
        _currentWeekStartDate = CalendarUtils.formatDateYMD(
          CalendarUtils.weekStartFrom(now, widget.weekOffset),
        );
      }
      return;
    }

    final courseChanged =
        _subscribedCourseId != null && _subscribedCourseId != course.id;
    if (courseChanged) {
      _currentWeekStartDate = null;
    }

    _weekSubscriptionKey = nextKey;
    _subscribedCourseId = course.id;

    if (resetViewport) {
      _didInitialJump = false;
      _currentWeekStartDate = CalendarUtils.formatDateYMD(
        CalendarUtils.weekStartFrom(now, widget.weekOffset),
      );
    }

    _loadCoursePolicy();

    Provider.of<ReservationSummaryProvider>(context, listen: false).setContext(
      placeId: placeId,
      courseId: course.id,
      startDate: startDate,
      endDate: endDate,
      weekStartDate: firstWeekStartDateStr,
    );

    _subscribeWeekOverrides();
    _subscribeBookingWeekOpens();
  }

  /// 비정기 일정 구독
  Future<void> _subscribeWeekOverrides() async {
    final course = _selectedCourse;
    if (course == null) {
      // admin_home_screen 모드에서 로딩 종료
      if (!widget.hideCourseSelector && _isLoadingWeek) {
        if (mounted) {
          setState(() {
            _isLoadingWeek = false;
          });
        }
      }
      return;
    }
    if (widget.weeklyViewMode) {
      // admin_home_screen 모드에서 로딩 종료
      if (!widget.hideCourseSelector && _isLoadingWeek) {
        if (mounted) {
          setState(() {
            _isLoadingWeek = false;
          });
        }
      }
      return;
    }

    final placeId =
        Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id;
    if (placeId == null) {
      // admin_home_screen 모드에서 로딩 종료
      if (!widget.hideCourseSelector && _isLoadingWeek) {
        if (mounted) {
          setState(() {
            _isLoadingWeek = false;
          });
        }
      }
      return;
    }

    final now = TimezoneUtils.getSeoulDateTime();
    final offsets = widget.availableWeekOffsets ?? [widget.weekOffset];
    final weekStartDates =
        offsets
            .map(
              (o) => CalendarUtils.formatDateYMD(
                CalendarUtils.weekStartFrom(now, o),
              ),
            )
            .toList();
    if (weekStartDates.isEmpty) {
      weekStartDates.add(
        CalendarUtils.formatDateYMD(
          CalendarUtils.weekStartFrom(now, widget.weekOffset),
        ),
      );
    }

    // CourseProvider에서 비정기 일정 구독 (전체 주차 한 번에)
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    courseProvider.subscribeToOverrides(placeId, weekStartDates);

    final currentWeekStartDate = CalendarUtils.formatDateYMD(
      CalendarUtils.weekStartFrom(now, widget.weekOffset),
    );
    final weekChanged = _currentWeekStartDate != currentWeekStartDate;
    if (weekChanged) {
      _currentWeekStartDate = currentWeekStartDate;
      _didInitialJump = false; // 주차 변경 시 뷰포트 리셋
    }

    try {
      // 초기 로드 (이후에는 CourseProvider 스트림으로 자동 업데이트)
      await _loadOverridesForWeek(placeId, currentWeekStartDate, course.id);
    } finally {
      // admin_home_screen 모드에서 로딩 종료 (성공/실패 관계없이)
      if (!widget.hideCourseSelector && _isLoadingWeek) {
        if (mounted) {
          setState(() {
            _isLoadingWeek = false;
          });
        }
      }
      // Provider 기반이므로 지연 페이드인 없이 즉시 표시
    }
  }

  /// bookingWeekOpens 구독 (CourseProvider에서 단일 구독 공유)
  void _subscribeBookingWeekOpens() {
    final course = _selectedCourse;
    if (course == null) return;
    if (widget.weeklyViewMode) return;

    final placeId =
        Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id;
    if (placeId == null) return;

    Provider.of<CourseProvider>(
      context,
      listen: false,
    ).subscribeToBookingWeekOpens(placeId, course.id);
  }

  /// 특정 주 비정기 일정은 CourseProvider 스트림으로만 사용 (초기 로드 시 주차만 표시)
  Future<void> _loadOverridesForWeek(
    String placeId,
    String weekStartDate,
    String courseId,
  ) async {
    if (!mounted) return;
    setState(() => _currentWeekStartDate = weekStartDate);
  }

  /// CourseProvider에서 해당 날짜의 override만 반환 (override는 Provider에서만 관리)
  List<CourseOverride> _getOverridesForDate(
    BuildContext context,
    DateTime date,
  ) {
    final dateKey = CalendarUtils.formatDateYMD(date);
    final weekStartDate = TimezoneUtils.formatDateToSeoul(
      CalendarUtils.startOfWeekMonday(date),
    );
    return Provider.of<CourseProvider>(context, listen: false)
        .getOverridesForWeek(weekStartDate)
        .where((o) => o.date == dateKey)
        .toList();
  }

  Future<void> _loadCoursePolicy() async {
    final course = _selectedCourse;
    if (course == null) return;
    setState(() {
      _coursePolicy = course.policy;
    });
  }

  @override
  void didUpdateWidget(CompactCalendarWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 주 변경 시(이번주/다음주/다다음주) 예약 현황/정책 재구독
    // Provider 기반이므로 로딩/페이드 없이 바로 전환
    if (widget.weekOffset != oldWidget.weekOffset) {
      setState(() {
        _didInitialJump = false;
      });
      // setContext → notifyListeners()가 빌드 중에 호출되지 않도록 다음 프레임으로 연기
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _ensureWeekSubscriptions(resetViewport: true);
      });
    }
    // highlightReservation이 새로 추가/변경되었을 때 흔들기 애니메이션 시작
    if (widget.highlightReservation != null) {
      final oldHighlight = oldWidget.highlightReservation;
      final newHighlight = widget.highlightReservation;
      final shouldStartAnimation =
          oldHighlight == null ||
          oldHighlight['reservationId'] != newHighlight!['reservationId'] ||
          oldHighlight['courseId'] != newHighlight['courseId'] ||
          oldHighlight['dayOfWeek'] != newHighlight['dayOfWeek'] ||
          oldHighlight['startTime'] != newHighlight['startTime'] ||
          (oldHighlight['reservedDate'] as DateTime).year !=
              (newHighlight['reservedDate'] as DateTime).year ||
          (oldHighlight['reservedDate'] as DateTime).month !=
              (newHighlight['reservedDate'] as DateTime).month ||
          (oldHighlight['reservedDate'] as DateTime).day !=
              (newHighlight['reservedDate'] as DateTime).day;
      if (shouldStartAnimation) {
        _shakeController?.dispose();
        _shakeController = AnimationController(
          duration: const Duration(milliseconds: 2000),
          vsync: this,
        );
        _shakeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
          CurvedAnimation(parent: _shakeController!, curve: Curves.easeInOut),
        );
        _shakeController!.forward();
      }
    } else if (oldWidget.highlightReservation != null) {
      _shakeController?.stop();
    }
    // 코스 목록이 변경되었을 때 처리
    if (widget.courses != oldWidget.courses) {
      // 같은 id의 코스가 새 인스턴스로 바뀐 경우(예: 예약 정책 수정 후) 선택 코스·정책 갱신
      if (_selectedCourse != null && widget.courses.isNotEmpty) {
        final match =
            widget.courses
                .where((c) => c.id == _selectedCourse!.id)
                .firstOrNull;
        if (match != null && match != _selectedCourse) {
          setState(() {
            _selectedCourse = match;
            _coursePolicy = match.policy;
          });
        }
      }
      // 코스가 비어있다가 채워졌거나(place 로드 타이밍), 아직 복원 못 했으면 1회 복원 시도
      if (!_didRestoreLastSelectedCourse && widget.courses.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _restoreLastSelectedCourse();
        });
      }
      // 새 코스가 추가되었는지 확인 (목록 길이가 증가)
      final newCourseAdded = widget.courses.length > oldWidget.courses.length;

      if (newCourseAdded) {
        // 새 코스가 추가되었으면 마지막 코스(새로 추가된 코스) 선택
        if (widget.courses.isNotEmpty) {
          setState(() {
            _selectedCourse = widget.courses.last;
            _didInitialJump = false; // 초기 점프 리셋
          });
          // 콜백 호출
          widget.onCourseSelected?.call(widget.courses.last);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _ensureWeekSubscriptions(resetViewport: true);
          });
        }
      } else {
        // 선택된 코스가 여전히 목록에 있는지 확인
        if (_selectedCourse != null) {
          final stillExists = widget.courses.any(
            (course) => course.id == _selectedCourse!.id,
          );
          if (!stillExists) {
            // 선택된 코스가 없어졌으면 첫 번째 코스 선택
            if (widget.courses.isNotEmpty) {
              setState(() {
                _selectedCourse = widget.courses.first;
                _didInitialJump = false; // 초기 점프 리셋
              });
              // 콜백 호출
              widget.onCourseSelected?.call(widget.courses.first);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                _ensureWeekSubscriptions(resetViewport: true);
              });
            } else {
              setState(() {
                _selectedCourse = null;
              });
              // 콜백 호출
              widget.onCourseSelected?.call(null);
            }
          } else {
            // 선택된 코스가 여전히 있으면, 최신 정보로 업데이트 (이름, 색상, 이미지, 세션 등 모든 변경사항 반영)
            final updatedCourse = widget.courses.firstWhere(
              (course) => course.id == _selectedCourse!.id,
            );
            // 코스 정보가 변경되었는지 확인 (이름, 색상, 이미지, 세션 등)
            final hasChanges =
                updatedCourse.name != _selectedCourse!.name ||
                updatedCourse.color != _selectedCourse!.color ||
                updatedCourse.imageUrl != _selectedCourse!.imageUrl ||
                updatedCourse.description != _selectedCourse!.description ||
                updatedCourse.sessions.length !=
                    _selectedCourse!.sessions.length ||
                updatedCourse.sessions.any(
                  (s) =>
                      !_selectedCourse!.sessions.any(
                        (os) =>
                            os.dayOfWeek == s.dayOfWeek &&
                            os.startTime == s.startTime &&
                            os.endTime == s.endTime &&
                            os.capacity == s.capacity,
                      ),
                );
            if (hasChanges) {
              setState(() {
                _selectedCourse = updatedCourse;
                _didInitialJump = false; // 초기 점프 리셋
              });
              // 콜백 호출 (업데이트된 코스 정보)
              widget.onCourseSelected?.call(updatedCourse);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                _ensureWeekSubscriptions(resetViewport: true);
              });
            }
          }
        } else if (widget.courses.isNotEmpty) {
          // 선택된 코스가 없었는데 코스가 추가되었으면 첫 번째 코스 선택
          setState(() {
            _selectedCourse = widget.courses.first;
            _didInitialJump = false; // 초기 점프 리셋
          });
          // 콜백 호출
          widget.onCourseSelected?.call(widget.courses.first);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _ensureWeekSubscriptions(resetViewport: true);
          });
        }
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // initState 때 placeId가 없어서 복원 못 한 케이스를 보정:
    // placeId가 생기는 순간 1회 복원 시도
    if (_didRestoreLastSelectedCourse) return;
    if (_isRestoringLastSelectedCourse) return;
    if (widget.courses.isEmpty) return;
    final placeId =
        Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id;
    if (placeId == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _restoreLastSelectedCourse();
    });
  }

  /// CourseProvider의 비정기 일정 변경사항을 감지하여 업데이트
  @override
  void dispose() {
    _scrollController.dispose();
    _shakeController?.dispose();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true; // 상태 유지 활성화

  CompactCalendarUsage get _usage {
    // 기존 플래그 기반 기본값을 유지하되, 호출부에서 usage를 명시하는 것을 권장
    if (widget.usage != null) return widget.usage!;
    if (widget.weeklyViewMode)
      return CompactCalendarUsage.userWeeklyReservationsView;
    if (widget.adminSelectionMode)
      return CompactCalendarUsage.adminSelectNewSlot;
    return CompactCalendarUsage.adminNavigate;
  }

  /// 관리자 홈 / 마이페이지 / 예약 이동 선택에서 그리드 핀치 줌·축소 활성화
  bool get _enableGridZoom =>
      _usage == CompactCalendarUsage.adminNavigate ||
      _usage == CompactCalendarUsage.userWeeklyReservationsView ||
      _usage == CompactCalendarUsage.adminSelectNewSlot;

  /// 내부 스크롤 막기: 확대 안 했을 때(_gridScale<=1), 핀치 중, 또는 손가락 2개 이상(핀치 우선)
  bool get _blockInternalScroll =>
      _enableGridZoom &&
      (_gridScale <= 1.0 || _isPinching || _activePointers.length >= 2);

  /// 확대 시(_gridScale>1): 세로 스크롤 허용.
  /// courseDetailView: 눈금/세션박스 압축으로 자연스럽게 맞춤. 그래도 넘치면 스크롤 허용.
  ScrollPhysics get _verticalScrollPhysics => const ClampingScrollPhysics();

  /// 확대되지 않았을 때 스케일 제스처 종료 시 좌우 스와이프면 주차 변경 콜백 호출
  void _handleScaleEnd(ScaleEndDetails details) {
    setState(() => _isPinching = false);
    if (_gridScale <= 1.0 && _pointerCountAtScaleStart <= 1) {
      final vx = details.velocity.pixelsPerSecond.dx;
      if (vx > 200 && widget.onSwipeToPrevWeek != null) {
        widget.onSwipeToPrevWeek!();
      } else if (vx < -200 && widget.onSwipeToNextWeek != null) {
        widget.onSwipeToNextWeek!();
      }
    }
  }

  /// 확대 비활성 모드(핀치 없음)에서 좌우 스와이프로 주차 변경
  void _handleHorizontalDragEnd(DragEndDetails details) {
    if (details.primaryVelocity == null) return;
    if (details.primaryVelocity! > 300 && widget.onSwipeToPrevWeek != null) {
      widget.onSwipeToPrevWeek!();
    } else if (details.primaryVelocity! < -300 &&
        widget.onSwipeToNextWeek != null) {
      widget.onSwipeToNextWeek!();
    }
  }

  /// 핀치 스케일 즉시 반영 (한 프레임 지연 시 레이아웃 흔들림 방지). 호출은 제스처 콜백에서만 하므로 build 중 호출 아님.
  void _applyGridScaleUpdate(double newScale) {
    final clamped = newScale.clamp(1.0, 1.8);
    if ((_gridScale - clamped).abs() < 0.001) return; // 변화 없으면 리빌드 생략
    _pendingGridScale = clamped;
    if (!mounted) return;
    setState(() {
      _gridScale = _pendingGridScale;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin을 위해 필요
    Provider.of<ReservationProvider>(context);
    // N/M 표시는 ReservationSummaryProvider 구독(setContext)에만 의존. watch로 변경 시 리빌드.
    context.watch<ReservationSummaryProvider>();
    // CourseProvider watch: 비정기 일정(override) 스트림 변경·저장 중 상태 변경 시 리빌드
    final courseProvider = context.watch<CourseProvider>();

    // ReservationSummaryProvider에 슬롯/오버라이드 전달 (N/M용). build 중 notifyListeners 금지 → 프레임 후 실행
    if (!widget.weeklyViewMode && _selectedCourse != null) {
      final placeId =
          Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id;
      if (placeId != null && placeId.isNotEmpty) {
        final now = TimezoneUtils.getSeoulDateTime();
        final offsets = widget.availableWeekOffsets ?? [widget.weekOffset];
        final weekStarts =
            offsets.map((o) => CalendarUtils.weekStartFrom(now, o)).toList();
        if (weekStarts.isEmpty) {
          weekStarts.add(CalendarUtils.weekStartFrom(now, widget.weekOffset));
        }
        final weekStartDates =
            weekStarts.map((d) => CalendarUtils.formatDateYMD(d)).toList();
        courseProvider.subscribeToOverrides(placeId, weekStartDates);
        final selectedCourseId = _selectedCourse!.id;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          final cp = context.read<CourseProvider>();
          final rsp = context.read<ReservationSummaryProvider>();
          final placeIdRead = context.read<PlaceProvider>().currentPlace?.id;
          if (placeIdRead != null && _selectedCourse != null) {
            for (var i = 0; i < weekStarts.length; i++) {
              final ws = weekStarts[i];
              final weekStartDate = weekStartDates[i];
              final startDate = DateTime(ws.year, ws.month, ws.day);
              final overridesForCourse =
                  cp
                      .getOverridesForWeek(weekStartDate)
                      .where((o) => o.courseId == selectedCourseId)
                      .toList();
              rsp.updateOverridesForWeek(weekStartDate, overridesForCourse);
              final byDate = <String, List<CourseOverride>>{};
              for (final o in overridesForCourse) {
                byDate.putIfAbsent(o.date, () => <CourseOverride>[]).add(o);
              }
              final slots = SessionSlotBuilder.buildSlotsForWeek(
                placeId: placeIdRead,
                course: _selectedCourse!,
                startDate: startDate,
                overridesByDate: byDate,
                getCapacityOverride: rsp.getCapacityOverride,
              );
              rsp.updateSessionSlots(weekStartDate, slots);
            }
          }
        });
      }
    }
    // 일정보기 모드인 경우
    if (widget.weeklyViewMode) {
      // 현재 주의 날짜들 계산 (이번주만)
      final today = TimezoneUtils.getSeoulDateTime();
      final daysFromMonday = today.weekday - 1;
      final thisWeekMonday = today.subtract(Duration(days: daysFromMonday));
      final weekStart = thisWeekMonday.add(
        Duration(days: 7 * widget.weekOffset),
      ); // weekOffset 반영 (0:이번주, 1:다음주...)

      // 월~일 모든 요일 생성
      final allWeekDates = List.generate(7, (index) {
        return weekStart.add(Duration(days: index));
      });

      // 예약이 없을 때: 이번주 월~금 5일 + 눈금만 표시 (빈 캘린더)
      // admin_home과 동일: 스크롤 정책·확대 구조(header+grid 하나의 Transform.scale)
      if (widget.userReservations == null || widget.userReservations!.isEmpty) {
        final weekdaysOnly = allWeekDates.take(5).toList(); // 월~금
        return SizedBox(
          height: widget.height,
          child: Column(
            children: [
              Expanded(child: _buildWeeklyViewModeContent(weekdaysOnly)),
            ],
          ),
        );
      }

      // 예약이 있는 날짜만 필터링 (취소된 비정기 세션의 예약은 제외)
      final courseProvider = Provider.of<CourseProvider>(context);
      final weekStartDate = TimezoneUtils.formatDateToSeoul(weekStart);
      final overrides = courseProvider.getOverridesForWeek(weekStartDate);

      final weekDates =
          allWeekDates.where((date) {
            return widget.userReservations!.any((reservation) {
              final resDate = DateTime(
                reservation.reservedDate.year,
                reservation.reservedDate.month,
                reservation.reservedDate.day,
              );
              final targetDate = DateTime(date.year, date.month, date.day);
              if (resDate != targetDate) return false;

              // 비정기 세션이 취소되었는지 확인
              final dateString = CalendarUtils.formatDateYMD(date);
              final cancelledOverride = overrides.firstWhere(
                (o) =>
                    o.courseId == reservation.courseId &&
                    o.date == dateString &&
                    o.dayOfWeek == reservation.dayOfWeek &&
                    o.startTime == reservation.startTime &&
                    o.isCancelled == true,
                orElse:
                    () => CourseOverride(
                      id: '',
                      courseId: '',
                      placeId: '',
                      date: '',
                      sessionId: '',
                      type: CourseOverrideType.cancel,
                      dayOfWeek: 0,
                      weekStartDate: '',
                      createdAt: DateTime.now(),
                    ),
              );

              // 취소된 비정기 세션이면 예약 표시하지 않음
              if (cancelledOverride.id.isNotEmpty) return false;

              return true;
            });
          }).toList();

      // 마이페이지(weeklyViewMode)에서는 부모가 준 height(예: 500)를 유지해야 UX가 안정적임.
      // 주차에 예약이 없어도 height를 축소하지 않고, 내부에서 빈 상태를 보여준다.
      final datesToRender = weekDates;

      return SizedBox(
        height: widget.height,
        child: Column(
          children: [
            if (datesToRender.isEmpty)
              Expanded(child: _buildEmptyState())
            else
              Expanded(child: _buildWeeklyViewModeContent(datesToRender)),
          ],
        ),
      );
    }

    // 기존 모드 (일정보기 모드가 아닌 경우)
    // 선택된 코스가 없으면 빈 상태
    if (_selectedCourse == null || widget.courses.isEmpty) {
      return _buildEmptyState();
    }

    // 선택된 코스의 세션만 사용
    final selectedCourseSessions = _selectedCourse!.sessions;

    if (selectedCourseSessions.isEmpty) {
      return _buildEmptyState();
    }

    // 현재 주의 날짜들 계산
    final today = TimezoneUtils.getSeoulDateTime();
    // 이번 주 월요일 찾기
    final daysFromMonday = today.weekday - 1; // 월요일이 0이 되도록
    final thisWeekMonday = today.subtract(Duration(days: daysFromMonday));
    final weekStart = thisWeekMonday.add(Duration(days: widget.weekOffset * 7));

    // 월~일 모든 요일 생성
    final allWeekDates = List.generate(7, (index) {
      return weekStart.add(Duration(days: index));
    });

    // 토일(6, 7)에 세션이 없으면 필터링 (정기 + 비정기 모두 확인)
    final hasSaturdaySession = selectedCourseSessions.any(
      (s) => s.dayOfWeek == 6,
    );
    final hasSundaySession = selectedCourseSessions.any(
      (s) => s.dayOfWeek == 7,
    );

    // 비정기 일정으로 토/일이 추가된 경우 해당 요일도 표시
    bool hasSaturdayOverride = false;
    bool hasSundayOverride = false;
    for (final date in allWeekDates) {
      final dayOverrides = _getOverridesForDate(context, date);
      for (final o in dayOverrides) {
        if (o.courseId != _selectedCourse!.id || o.isCancelled == true)
          continue;
        if (o.dayOfWeek == 6) hasSaturdayOverride = true;
        if (o.dayOfWeek == 7) hasSundayOverride = true;
      }
    }

    final weekDates =
        allWeekDates.where((date) {
          // 토요일: 정기 또는 비정기 세션이 있으면 표시
          if (date.weekday == 6 && !hasSaturdaySession && !hasSaturdayOverride)
            return false;
          // 일요일: 정기 또는 비정기 세션이 있으면 표시
          if (date.weekday == 7 && !hasSundaySession && !hasSundayOverride)
            return false;
          return true;
        }).toList();

    return SizedBox(
      height: widget.height,
      child: Column(
        children: [
          if (!widget.hideCourseSelector) _buildCourseSelector(),
          // 요일 헤더 + 그리드를 같은 가로 스크롤(contentWidth) 안에 넣어 헤더도 스케일/스크롤 동기화
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final viewportWidth = constraints.maxWidth;
                final viewportHeight = constraints.maxHeight;
                final layoutViewportHeight = (viewportHeight -
                        _minBottomPadding)
                    .clamp(1.0, double.infinity);
                // 그리드 영역 = 전체 - 헤더 (header + contentHeight == viewportHeight 정확히 맞추기)
                final gridAreaHeight = (layoutViewportHeight -
                        _kDayHeaderHeight)
                    .clamp(1.0, double.infinity);
                final smart = _computeSmartRange(
                  dates: weekDates,
                  viewportHeight: gridAreaHeight,
                );
                final layout = _buildSlotLayout(
                  dates: weekDates,
                  smart: smart,
                  viewportHeight: gridAreaHeight,
                );
                final isLoading =
                    _isLoadingCourse || _isLoadingWeek || !_showGridAfterLoad;

                if (!isLoading && !_didInitialJump) {
                  _didInitialJump = true;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    // 단일 스크롤뷰에만 연결된 경우에만 jumpTo (다중 연결 시 assertion 방지)
                    if (_scrollController.hasClients &&
                        _scrollController.positions.length == 1) {
                      final targetMinute = layout.initialJumpMinute;
                      final targetY = layout.yForMinute(targetMinute);
                      _scrollController.jumpTo(
                        targetY.clamp(
                          0.0,
                          _scrollController.position.maxScrollExtent,
                        ),
                      );
                    }
                  });
                }

                // double 오차 방지: 강제로 header + contentHeight == viewportHeight 맞춤
                final contentHeight = gridAreaHeight;
                // 실제 그리드 전체 폭 (timeColumn + dayColumns). Transform.scale은 레이아웃 크기를 안 바꿈.
                final contentWidth = viewportWidth;
                final scrollContentWidth =
                    _enableGridZoom ? contentWidth * _gridScale : contentWidth;
                final scrollContentHeight =
                    _enableGridZoom
                        ? contentHeight * _gridScale
                        : contentHeight;

                // Transform.scale: child 레이아웃 크기는 그대로, 실제 그려지는 폭만 scale배. 따라서
                // 스크롤 영역/외부 SizedBox는 반드시 contentWidth*scale, contentHeight*scale 사용.
                final List<Widget> columnChildren;
                if (_enableGridZoom) {
                  // 헤더 고정 + 그리드만 세로 스크롤 (둘 다 scale 적용)
                  columnChildren = [
                    Expanded(
                      child: Container(
                        color:
                            widget.backgroundColor ?? AppColors.backgroundWhite,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 요일 헤더: 고정 (scrollContentWidth로 감싸 확대 시 잘림 방지)
                            SizedBox(
                              width: scrollContentWidth,
                              height: _kDayHeaderHeight * _gridScale,
                              child: Align(
                                alignment: Alignment.topLeft,
                                child: Transform.scale(
                                  scale: _gridScale,
                                  alignment: Alignment.topLeft,
                                  child: SizedBox(
                                    width: contentWidth,
                                    height: _kDayHeaderHeight,
                                    child: _buildDayHeaders(
                                      weekDates,
                                      contentWidth: contentWidth,
                                      timeColumnWidth: _timeColumnWidth,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            // 그리드만 세로 스크롤
                            Expanded(
                              child: SingleChildScrollView(
                                controller: _scrollController,
                                physics: _verticalScrollPhysics,
                                child: SizedBox(
                                  width: scrollContentWidth,
                                  height: contentHeight * _gridScale,
                                  child: Align(
                                    alignment: Alignment.topLeft,
                                    child: Transform.scale(
                                      scale: _gridScale,
                                      alignment: Alignment.topLeft,
                                      child: SizedBox(
                                        width: contentWidth,
                                        height: contentHeight,
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            _buildTimeColumn(layout),
                                            if (isLoading)
                                              Expanded(
                                                child: Center(
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.all(
                                                          24,
                                                        ),
                                                    child: CircularProgressIndicator(
                                                      valueColor:
                                                          AlwaysStoppedAnimation<
                                                            Color
                                                          >(
                                                            AppColors
                                                                .primaryGreen,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                              )
                                            else
                                              ...weekDates.asMap().entries.map((
                                                entry,
                                              ) {
                                                final index = entry.key;
                                                final date = entry.value;
                                                return Expanded(
                                                  child: TweenAnimationBuilder<
                                                    double
                                                  >(
                                                    key: ValueKey(
                                                      'daycol_${widget.weekOffset}_$index',
                                                    ),
                                                    tween: Tween(
                                                      begin: 1,
                                                      end: 1,
                                                    ),
                                                    duration: Duration.zero,
                                                    builder: (
                                                      context,
                                                      value,
                                                      child,
                                                    ) {
                                                      return Opacity(
                                                        opacity: value,
                                                        child: child,
                                                      );
                                                    },
                                                    child: Padding(
                                                      padding: EdgeInsets.only(
                                                        left:
                                                            index > 0
                                                                ? _dateColumnSpacing
                                                                : 0,
                                                      ),
                                                      child: _buildDayColumn(
                                                        date,
                                                        slots: layout.slots,
                                                        rangeStartMinutes:
                                                            smart
                                                                .rangeStartMinutes,
                                                        slotTops:
                                                            layout.slotTops,
                                                        slotHeights:
                                                            layout.slotHeights,
                                                        yForMinute:
                                                            layout.yForMinute,
                                                        slotIndexForMinute:
                                                            layout
                                                                .slotIndexForMinute,
                                                      ),
                                                    ),
                                                  ),
                                                );
                                              }),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ];
                } else {
                  columnChildren = [
                    _buildDayHeaders(
                      weekDates,
                      contentWidth: scrollContentWidth,
                      timeColumnWidth: null,
                    ),
                    Expanded(
                      child: Container(
                        color:
                            widget.backgroundColor ?? AppColors.backgroundWhite,
                        child: SingleChildScrollView(
                          controller: _scrollController,
                          physics: _verticalScrollPhysics,
                          child: SizedBox(
                            width: scrollContentWidth,
                            height: scrollContentHeight,
                            child: SizedBox(
                              height: contentHeight,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _buildTimeColumn(layout),
                                  if (isLoading)
                                    Expanded(
                                      child: Center(
                                        child: Padding(
                                          padding: const EdgeInsets.all(24),
                                          child: CircularProgressIndicator(
                                            valueColor:
                                                AlwaysStoppedAnimation<Color>(
                                                  AppColors.primaryGreen,
                                                ),
                                          ),
                                        ),
                                      ),
                                    )
                                  else
                                    ...weekDates.asMap().entries.map((entry) {
                                      final index = entry.key;
                                      final date = entry.value;
                                      return Expanded(
                                        child: TweenAnimationBuilder<double>(
                                          key: ValueKey(
                                            'daycol_${widget.weekOffset}_$index',
                                          ),
                                          tween: Tween(begin: 1, end: 1),
                                          duration: Duration.zero,
                                          builder: (context, value, child) {
                                            return Opacity(
                                              opacity: value,
                                              child: child,
                                            );
                                          },
                                          child: Padding(
                                            padding: EdgeInsets.only(
                                              left:
                                                  index > 0
                                                      ? _dateColumnSpacing
                                                      : 0,
                                            ),
                                            child: _buildDayColumn(
                                              date,
                                              slots: layout.slots,
                                              rangeStartMinutes:
                                                  smart.rangeStartMinutes,
                                              slotTops: layout.slotTops,
                                              slotHeights: layout.slotHeights,
                                              yForMinute: layout.yForMinute,
                                              slotIndexForMinute:
                                                  layout.slotIndexForMinute,
                                            ),
                                          ),
                                        ),
                                      );
                                    }),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ];
                }
                final Widget scrollContent = SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics:
                      _blockInternalScroll
                          ? const NeverScrollableScrollPhysics()
                          : const ClampingScrollPhysics(),
                  child: SizedBox(
                    width: scrollContentWidth,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: columnChildren,
                    ),
                  ),
                );
                final gridWithFade = AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  switchInCurve: Curves.easeIn,
                  child: KeyedSubtree(
                    key: ValueKey(widget.weekOffset),
                    child: scrollContent,
                  ),
                );
                if (_enableGridZoom) {
                  return Listener(
                    onPointerDown: (e) {
                      setState(() => _activePointers.add(e.pointer));
                    },
                    onPointerUp: (e) {
                      setState(() => _activePointers.remove(e.pointer));
                    },
                    onPointerCancel: (e) {
                      setState(() => _activePointers.remove(e.pointer));
                    },
                    child: GestureDetector(
                      // deferToChild: 확대 시 단일 손가락 가로 드래그가 ScrollView에 전달되어 스크롤 가능
                      behavior: HitTestBehavior.deferToChild,
                      onScaleStart: (details) {
                        _pointerCountAtScaleStart = _activePointers.length;
                        _scaleStart = _gridScale;
                        setState(() => _isPinching = true);
                      },
                      onScaleUpdate:
                          (d) => _applyGridScaleUpdate(_scaleStart * d.scale),
                      onScaleEnd: (details) => _handleScaleEnd(details),
                      child: gridWithFade,
                    ),
                  );
                }
                if (widget.onSwipeToPrevWeek != null ||
                    widget.onSwipeToNextWeek != null) {
                  return GestureDetector(
                    onHorizontalDragEnd: _handleHorizontalDragEnd,
                    behavior: HitTestBehavior.opaque,
                    child: gridWithFade,
                  );
                }
                return gridWithFade;
              },
            ),
          ),
        ],
      ),
    );
  }

  // 코스 선택 드롭다운
  Widget _buildCourseSelector() {
    if (widget.courses.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      decoration: BoxDecoration(
        color: widget.backgroundColor ?? AppColors.backgroundWhite,
        border: Border(
          bottom: BorderSide(
            color: AppColors.borderLight.withOpacity(0.3),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          // 드롭다운
          Expanded(
            child: PopupMenuButton<Course>(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              elevation: 8,
              color: AppColors.backgroundWhite,
              offset: const Offset(0, 0),
              constraints: const BoxConstraints(minWidth: 200, maxWidth: 400),
              itemBuilder: (context) {
                return widget.courses.map((course) {
                  final isSelected = course.id == _selectedCourse?.id;
                  return PopupMenuItem<Course>(
                    value: course,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          // 색상 인디케이터
                          Container(
                            width: 4,
                            height: 16,
                            decoration: BoxDecoration(
                              color: Color(course.color),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 12),
                          // 코스 이름
                          Expanded(
                            child: Text(
                              course.name,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight:
                                    isSelected
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                color:
                                    isSelected
                                        ? AppColors.textPrimary
                                        : AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList();
              },
              onOpened: () {
                setState(() {
                  _isDropdownOpen = true;
                });
              },
              onCanceled: () {
                setState(() {
                  _isDropdownOpen = false;
                });
              },
              onSelected: (Course newCourse) async {
                // 이전과 같은 코스면 로딩/재구독 스킵 (드롭다운만 닫기)
                if (_selectedCourse?.id == newCourse.id) {
                  if (mounted) {
                    setState(() => _isDropdownOpen = false);
                  }
                  return;
                }

                // 코스 변경 시 즉시 기존 구독 키 초기화 → 새 구독으로 전환
                _subscribedCourseId = null;
                _weekSubscriptionKey = null;

                setState(() {
                  _selectedCourse = newCourse;
                  _isDropdownOpen = false;
                  _didInitialJump = false; // 코스 변경 시 초기 점프 리셋
                  _isLoadingCourse = true; // 로딩 시작
                });

                widget.onCourseSelected?.call(newCourse);

                // 즉시 ReservationSummaryProvider 구독 전환 (지연 시 이전 코스 N/새 코스 M 혼합 표시 버그 방지)
                _ensureWeekSubscriptions(resetViewport: true);
                await _subscribeWeekOverrides();

                // 추가 지연으로 UI 안정화
                await Future.delayed(const Duration(milliseconds: 100));

                if (mounted) {
                  setState(() {
                    _isLoadingCourse = false; // 로딩 완료
                  });
                }

                // 마지막 선택 코스 저장
                try {
                  final placeProvider = Provider.of<PlaceProvider>(
                    context,
                    listen: false,
                  );
                  final currentPlace = placeProvider.currentPlace;
                  if (currentPlace != null) {
                    final storageService = StorageService();
                    final scope =
                        (_usage == CompactCalendarUsage.adminNavigate ||
                                _usage ==
                                    CompactCalendarUsage.adminSelectNewSlot)
                            ? StorageService.scopeAdmin
                            : StorageService.scopeMember;
                    await storageService.saveLastSelectedCourseId(
                      currentPlace.id,
                      newCourse.id,
                      scope: scope,
                    );
                  }
                } catch (e) {
                  // 저장 실패해도 계속 진행
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _selectedCourse?.name ?? '코스 선택',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    Icon(
                      _isDropdownOpen
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      color: AppColors.textSecondary,
                      size: 24,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 빈 상태 UI
  Widget _buildEmptyState() {
    final message = widget.weeklyViewMode ? '예약이 없어요' : '아직 코스가 없어요';

    // "예약이 없어요" 등 기타 빈 상태
    return Container(
      height: widget.height,
      color: widget.backgroundColor ?? AppColors.backgroundWhite,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            message,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: AppColors.textSecondary.withOpacity(0.7),
            ),
          ),
        ),
      ),
    );
  }

  /// weeklyViewMode용 캘린더 콘텐츠. admin_home과 동일한 스크롤 정책·확대 구조 사용.
  Widget _buildWeeklyViewModeContent(List<DateTime> dates) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = constraints.maxWidth;
        final viewportHeight = constraints.maxHeight;
        final layoutViewportHeight = (viewportHeight - _minBottomPadding).clamp(
          1.0,
          double.infinity,
        );
        // 그리드 영역 = 전체 - 헤더 (header + contentHeight == viewportHeight 정확히 맞추기)
        final gridAreaHeight = (layoutViewportHeight - _kDayHeaderHeight).clamp(
          1.0,
          double.infinity,
        );
        final smart = _computeSmartRange(
          dates: dates,
          viewportHeight: gridAreaHeight,
        );
        final layout = _buildSlotLayout(
          dates: dates,
          smart: smart,
          viewportHeight: gridAreaHeight,
        );
        final isLoading =
            _isLoadingCourse || _isLoadingWeek || !_showGridAfterLoad;

        if (!isLoading && !_didInitialJump) {
          _didInitialJump = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (_scrollController.hasClients &&
                _scrollController.positions.length == 1) {
              final targetMinute = layout.initialJumpMinute;
              final targetY = layout.yForMinute(targetMinute);
              _scrollController.jumpTo(
                targetY.clamp(0.0, _scrollController.position.maxScrollExtent),
              );
            }
          });
        }

        // double 오차 방지: 강제로 header + contentHeight == viewportHeight 맞춤
        final contentHeight = gridAreaHeight;
        final contentWidth = viewportWidth;
        final scrollContentWidth =
            _enableGridZoom ? contentWidth * _gridScale : contentWidth;
        final scrollContentHeight =
            _enableGridZoom ? contentHeight * _gridScale : contentHeight;

        final List<Widget> columnChildren;
        if (_enableGridZoom) {
          columnChildren = [
            Expanded(
              child: Container(
                color: widget.backgroundColor ?? AppColors.backgroundWhite,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: scrollContentWidth,
                      height: _kDayHeaderHeight * _gridScale,
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Transform.scale(
                          scale: _gridScale,
                          alignment: Alignment.topLeft,
                          child: SizedBox(
                            width: contentWidth,
                            height: _kDayHeaderHeight,
                            child: _buildDayHeaders(
                              dates,
                              contentWidth: contentWidth,
                              timeColumnWidth: _timeColumnWidth,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        physics: _verticalScrollPhysics,
                        child: SizedBox(
                          width: scrollContentWidth,
                          height: contentHeight * _gridScale,
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: Transform.scale(
                              scale: _gridScale,
                              alignment: Alignment.topLeft,
                              child: SizedBox(
                                width: contentWidth,
                                height: contentHeight,
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _buildTimeColumn(layout),
                                    if (isLoading)
                                      Expanded(
                                        child: Center(
                                          child: Padding(
                                            padding: const EdgeInsets.all(24),
                                            child: CircularProgressIndicator(
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                    AppColors.primaryGreen,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      )
                                    else
                                      ...dates.asMap().entries.map((entry) {
                                        final index = entry.key;
                                        final date = entry.value;
                                        return Expanded(
                                          child: TweenAnimationBuilder<double>(
                                            key: ValueKey(
                                              'daycol_${widget.weekOffset}_$index',
                                            ),
                                            tween: Tween(begin: 1, end: 1),
                                            duration: Duration.zero,
                                            builder: (context, value, child) {
                                              return Opacity(
                                                opacity: value,
                                                child: child,
                                              );
                                            },
                                            child: Padding(
                                              padding: EdgeInsets.only(
                                                left:
                                                    index > 0
                                                        ? _dateColumnSpacing
                                                        : 0,
                                              ),
                                              child: _buildDayColumn(
                                                date,
                                                slots: layout.slots,
                                                rangeStartMinutes:
                                                    smart.rangeStartMinutes,
                                                slotTops: layout.slotTops,
                                                slotHeights: layout.slotHeights,
                                                yForMinute: layout.yForMinute,
                                                slotIndexForMinute:
                                                    layout.slotIndexForMinute,
                                              ),
                                            ),
                                          ),
                                        );
                                      }),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ];
        } else {
          columnChildren = [
            _buildDayHeaders(
              dates,
              contentWidth: scrollContentWidth,
              timeColumnWidth: null,
            ),
            Expanded(
              child: Container(
                color: widget.backgroundColor ?? AppColors.backgroundWhite,
                child: SingleChildScrollView(
                  controller: _scrollController,
                  physics: _verticalScrollPhysics,
                  child: SizedBox(
                    width: scrollContentWidth,
                    height: scrollContentHeight,
                    child: SizedBox(
                      height: contentHeight,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildTimeColumn(layout),
                          if (isLoading)
                            Expanded(
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: CircularProgressIndicator(
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      AppColors.primaryGreen,
                                    ),
                                  ),
                                ),
                              ),
                            )
                          else
                            ...dates.asMap().entries.map((entry) {
                              final index = entry.key;
                              final date = entry.value;
                              return Expanded(
                                child: TweenAnimationBuilder<double>(
                                  key: ValueKey(
                                    'daycol_${widget.weekOffset}_$index',
                                  ),
                                  tween: Tween(begin: 1, end: 1),
                                  duration: Duration.zero,
                                  builder: (context, value, child) {
                                    return Opacity(
                                      opacity: value,
                                      child: child,
                                    );
                                  },
                                  child: Padding(
                                    padding: EdgeInsets.only(
                                      left: index > 0 ? _dateColumnSpacing : 0,
                                    ),
                                    child: _buildDayColumn(
                                      date,
                                      slots: layout.slots,
                                      rangeStartMinutes:
                                          smart.rangeStartMinutes,
                                      slotTops: layout.slotTops,
                                      slotHeights: layout.slotHeights,
                                      yForMinute: layout.yForMinute,
                                      slotIndexForMinute:
                                          layout.slotIndexForMinute,
                                    ),
                                  ),
                                ),
                              );
                            }),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ];
        }

        final scrollContent = SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics:
              _blockInternalScroll
                  ? const NeverScrollableScrollPhysics()
                  : const ClampingScrollPhysics(),
          child: SizedBox(
            width: scrollContentWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: columnChildren,
            ),
          ),
        );

        if (_enableGridZoom) {
          return Listener(
            onPointerDown: (e) {
              setState(() => _activePointers.add(e.pointer));
            },
            onPointerUp: (e) {
              setState(() => _activePointers.remove(e.pointer));
            },
            onPointerCancel: (e) {
              setState(() => _activePointers.remove(e.pointer));
            },
            child: GestureDetector(
              behavior: HitTestBehavior.deferToChild,
              onScaleStart: (details) {
                _pointerCountAtScaleStart = _activePointers.length;
                _scaleStart = _gridScale;
                setState(() => _isPinching = true);
              },
              onScaleUpdate:
                  (d) => _applyGridScaleUpdate(_scaleStart * d.scale),
              onScaleEnd: (details) => _handleScaleEnd(details),
              child: scrollContent,
            ),
          );
        }
        return scrollContent;
      },
    );
  }

  // 요일 헤더. [contentWidth]가 주어지면 그 너비로 늘어나서 그리드와 같은 가로 스케일/스크롤에 맞춤.
  // [timeColumnWidth] 확대 시 그리드 시간열과 정렬: 그리드는 Transform.scale로 확대되므로 시간열=35*scale, 헤더도 동일 비율 적용.
  Widget _buildDayHeaders(
    List<DateTime> dates, {
    double? contentWidth,
    double? timeColumnWidth,
  }) {
    const dayNames = ['', '월', '화', '수', '목', '금', '토', '일'];
    final effectiveTimeWidth = timeColumnWidth ?? _timeColumnWidth;

    Widget row = Row(
      children: [
        SizedBox(width: effectiveTimeWidth, child: Container()),
        ...dates.map((date) {
          return Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    dayNames[date.weekday],
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w400,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  Text(
                    '${date.month}/${date.day}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      letterSpacing: 1.5,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary.withOpacity(0.9),
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ],
    );
    if (contentWidth != null && contentWidth.isFinite) {
      row = SizedBox(width: contentWidth, child: row);
    }
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: widget.backgroundColor ?? AppColors.backgroundWhite,
        border: Border(
          bottom: BorderSide(color: AppColors.borderLight, width: 1),
        ),
      ),
      child: row,
    );
  }

  Widget _buildTimeColumn(_SlotLayout layout) {
    return Container(
      width: _timeColumnWidth,
      color: widget.backgroundColor ?? AppColors.backgroundWhite,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children:
            layout.slots.asMap().entries.map((entry) {
              final idx = entry.key;
              final slot = entry.value;
              final label = slot.label;
              final isActiveSlot = slot.isActive;
              return Container(
                height: layout.slotHeights[idx],
                alignment: Alignment.topRight,
                padding: EdgeInsets.only(right: _timeTextPaddingRight, top: 0),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: label == '…' ? 14 : (isActiveSlot ? 16 : 13),
                    fontWeight:
                        isActiveSlot ? FontWeight.w600 : FontWeight.w400,
                    color:
                        isActiveSlot
                            ? AppColors.textSecondary
                            : AppColors.textSecondary.withOpacity(0.4),
                    height: 1.0,
                  ),
                ),
              );
            }).toList(),
      ),
    );
  }

  _SmartRange _computeSmartRange({
    required List<DateTime> dates,
    required double viewportHeight,
  }) {
    // 일정보기 모드인 경우
    if (widget.weeklyViewMode) {
      if (widget.userReservations == null || widget.userReservations!.isEmpty) {
        return _SmartRange(
          rangeStartMinutes: 9 * 60,
          rangeEndMinutes: 18 * 60,
          startHour: 9,
          endHour: 18,
          slotCount: 9,
          hourSlotHeight: _effectiveMinHourSlotHeight,
        );
      }

      // 예약된 세션들의 시간 범위 계산
      // - 정기 세션이 없으면 override(비정기) 확인
      // - 그래도 없으면 예약 정보로 fallback(기본 2시간)
      final weekStart = CalendarUtils.startOfWeekMonday(dates.first);
      final weekStartDate = TimezoneUtils.formatDateToSeoul(weekStart);
      final courseProvider = Provider.of<CourseProvider>(
        context,
        listen: false,
      );
      final overrides = courseProvider.getOverridesForWeek(weekStartDate);

      final reservationTimes = <int>[];
      double maxSessionDuration = 0;
      for (final reservation in widget.userReservations!) {
        // 해당 날짜의 예약인지 확인
        final isInWeek = dates.any((date) {
          final resDate = DateTime(
            reservation.reservedDate.year,
            reservation.reservedDate.month,
            reservation.reservedDate.day,
          );
          final targetDate = DateTime(date.year, date.month, date.day);
          return resDate == targetDate;
        });

        if (isInWeek && widget.courses.isNotEmpty) {
          // 예약된 세션 찾기
          final course = widget.courses.firstWhere(
            (c) => c.id == reservation.courseId,
            orElse: () => widget.courses.first,
          );
          final regularSession = course.findSession(
            reservation.dayOfWeek,
            reservation.startTime,
          );

          late final String startTime;
          late final String endTime;

          if (regularSession != null) {
            startTime = regularSession.startTime;
            endTime = regularSession.endTime;
          } else {
            final dateOnly = DateTime(
              reservation.reservedDate.year,
              reservation.reservedDate.month,
              reservation.reservedDate.day,
            );
            final dateString = CalendarUtils.formatDateYMD(dateOnly);

            final override = overrides.cast<CourseOverride?>().firstWhere(
              (o) =>
                  o != null &&
                  o.courseId == reservation.courseId &&
                  o.date == dateString &&
                  o.dayOfWeek == reservation.dayOfWeek &&
                  o.startTime == reservation.startTime,
              orElse: () => null,
            );

            // 취소된 override면 제외
            if (override != null && override.isCancelled == true) {
              continue;
            }

            if (override != null &&
                override.startTime != null &&
                override.endTime != null) {
              startTime = override.startTime!;
              endTime = override.endTime!;
            } else {
              startTime = reservation.startTime;
              final startMinutes = CalendarUtils.parseTimeToMinutes(startTime);
              final endMinutes = startMinutes + 120; // 기본 2시간
              endTime =
                  '${(endMinutes ~/ 60).toString().padLeft(2, '0')}:${(endMinutes % 60).toString().padLeft(2, '0')}';
            }
          }

          final startMins = CalendarUtils.parseTimeToMinutes(startTime);
          final endMins = CalendarUtils.parseTimeToMinutes(endTime);
          reservationTimes.add(startMins);
          reservationTimes.add(endMins);
          if (endMins > startMins) {
            final duration = (endMins - startMins).toDouble();
            if (duration > maxSessionDuration) {
              maxSessionDuration = duration;
            }
          }
        }
      }

      if (reservationTimes.isEmpty) {
        return _SmartRange(
          rangeStartMinutes: 9 * 60,
          rangeEndMinutes: 18 * 60,
          startHour: 9,
          endHour: 18,
          slotCount: 9,
          hourSlotHeight: _effectiveMinHourSlotHeight,
        );
      }

      final minStart = reservationTimes.reduce((a, b) => a < b ? a : b);
      final maxEnd = reservationTimes.reduce((a, b) => a > b ? a : b);

      final optimalHourSlotHeight =
          maxSessionDuration >= 180
              ? 38.0
              : maxSessionDuration >= 120
              ? 40.0
              : _effectiveMinHourSlotHeight;

      var rangeStart = _floorToHour(
        (minStart - _basePaddingMinutes).clamp(0, 24 * 60),
      );
      var rangeEnd = _ceilToHour(
        (maxEnd + _basePaddingMinutes).clamp(0, 24 * 60),
      );

      if (rangeStart < _edgePaddingMinutes) {
        rangeStart = 0;
      }

      if (rangeEnd >= 24 * 60 - _edgePaddingMinutes) {
        rangeEnd = 24 * 60;
      }

      if (rangeEnd <= rangeStart) {
        rangeEnd = (rangeStart + 60).clamp(0, 24 * 60);
      }

      int slotCount = (rangeEnd - rangeStart) ~/ 60;
      final hourSlotHeight = optimalHourSlotHeight;
      double totalHeightAtDefault = slotCount * hourSlotHeight;

      if (totalHeightAtDefault < viewportHeight) {
        final extraSlotsNeeded =
            ((viewportHeight - totalHeightAtDefault) / hourSlotHeight).ceil();
        var addBefore = extraSlotsNeeded ~/ 2;
        var addAfter = extraSlotsNeeded - addBefore;

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

    // 기존 모드
    if (_selectedCourse == null) {
      return _SmartRange(
        rangeStartMinutes: 9 * 60,
        rangeEndMinutes: 18 * 60,
        startHour: 9,
        endHour: 18,
        slotCount: 9,
        hourSlotHeight: _effectiveMinHourSlotHeight,
      );
    }

    // 해당 컬럼(날짜들)에서 보이는 요일들의 세션만 대상으로 범위 계산
    final weekdays = dates.map((d) => d.weekday).toSet();
    final regularSessions = _selectedCourse!.sessions.where(
      (s) => weekdays.contains(s.dayOfWeek),
    );

    // 비정기 일정도 포함 (뷰포트 범위 계산에 필요)
    final weekStart = CalendarUtils.startOfWeekMonday(dates.first);
    final weekStartDate = TimezoneUtils.formatDateToSeoul(weekStart);
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final weekOverrides =
        courseProvider
            .getOverridesForWeek(weekStartDate)
            .where((o) => o.courseId == _selectedCourse!.id && !o.isCancelled)
            .toList();

    // 비정기 일정을 CourseSession으로 변환
    final overrideSessions =
        weekOverrides
            .where(
              (o) =>
                  weekdays.contains(o.dayOfWeek) &&
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

    // 정기 일정 + 비정기 일정 병합
    final allSessions = [...regularSessions, ...overrideSessions];

    if (allSessions.isEmpty) {
      return _SmartRange(
        rangeStartMinutes: 9 * 60,
        rangeEndMinutes: 18 * 60,
        startHour: 9,
        endHour: 18,
        slotCount: 9,
        hourSlotHeight: _effectiveMinHourSlotHeight,
      );
    }

    final starts = allSessions.map(
      (s) => CalendarUtils.parseTimeToMinutes(s.startTime),
    );
    final ends = allSessions.map(
      (s) => CalendarUtils.parseTimeToMinutes(s.endTime),
    );
    final minStart = starts.reduce((a, b) => a < b ? a : b);
    final maxEnd = ends.reduce((a, b) => a > b ? a : b);

    // 세션 지속 시간을 기반으로 동적 최적 높이 계산
    double maxSessionDuration = 0;
    for (final session in allSessions) {
      final start = CalendarUtils.parseTimeToMinutes(session.startTime);
      final end = CalendarUtils.parseTimeToMinutes(session.endTime);
      if (end > start) {
        final duration = end - start;
        if (duration > maxSessionDuration) {
          maxSessionDuration = duration.toDouble();
        }
      }
    }

    // 세션 블록이 잘 보이기 위한 최적 높이 (스크롤 최소화로 컴팩트하게)
    final optimalHourSlotHeight =
        maxSessionDuration >= 180
            ? (_usage == CompactCalendarUsage.courseDetailView
                ? 28.0
                : 38.0) // 3시간 이상
            : maxSessionDuration >= 120
            ? (_usage == CompactCalendarUsage.courseDetailView
                ? 30.0
                : 40.0) // 2-3시간
            : _effectiveMinHourSlotHeight; // 2시간 미만

    // 2시간 여백 + 시간 단위 정렬 + 경계 여백
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

    // 동적 최적 높이로 계산
    int slotCount = (rangeEnd - rangeStart) ~/ 60;
    final hourSlotHeight = optimalHourSlotHeight;
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
    required _SmartRange smart,
    required double viewportHeight,
  }) {
    final rangeStartMinutes = smart.rangeStartMinutes;
    final rangeEndMinutes = smart.rangeEndMinutes;

    // 일정보기 모드인 경우
    if (widget.weeklyViewMode) {
      // 예약된 세션들을 활성 시간대로 계산
      // - 정기 세션이 없으면 override(비정기) 확인
      // - 그래도 없으면 예약 정보로 fallback(기본 2시간)
      final weekdays = dates.map((d) => d.weekday).toSet();
      final activeRanges = <List<int>>[]; // [startMinute, endMinute]

      final weekStart = CalendarUtils.startOfWeekMonday(dates.first);
      final weekStartDate = TimezoneUtils.formatDateToSeoul(weekStart);
      final courseProvider = Provider.of<CourseProvider>(
        context,
        listen: false,
      );
      final overrides = courseProvider.getOverridesForWeek(weekStartDate);

      for (final reservation in widget.userReservations ?? []) {
        final isInWeek = dates.any((date) {
          final resDate = DateTime(
            reservation.reservedDate.year,
            reservation.reservedDate.month,
            reservation.reservedDate.day,
          );
          final targetDate = DateTime(date.year, date.month, date.day);
          return resDate == targetDate;
        });

        if (isInWeek &&
            weekdays.contains(reservation.dayOfWeek) &&
            widget.courses.isNotEmpty) {
          final course = widget.courses.firstWhere(
            (c) => c.id == reservation.courseId,
            orElse: () => widget.courses.first,
          );
          final regularSession = course.findSession(
            reservation.dayOfWeek,
            reservation.startTime,
          );

          late final String startTime;
          late final String endTime;

          if (regularSession != null) {
            startTime = regularSession.startTime;
            endTime = regularSession.endTime;
          } else {
            final dateOnly = DateTime(
              reservation.reservedDate.year,
              reservation.reservedDate.month,
              reservation.reservedDate.day,
            );
            final dateString = CalendarUtils.formatDateYMD(dateOnly);

            final override = overrides.cast<CourseOverride?>().firstWhere(
              (o) =>
                  o != null &&
                  o.courseId == reservation.courseId &&
                  o.date == dateString &&
                  o.dayOfWeek == reservation.dayOfWeek &&
                  o.startTime == reservation.startTime,
              orElse: () => null,
            );

            // 취소된 override면 제외
            if (override != null && override.isCancelled == true) {
              continue;
            }

            if (override != null &&
                override.startTime != null &&
                override.endTime != null) {
              startTime = override.startTime!;
              endTime = override.endTime!;
            } else {
              startTime = reservation.startTime;
              final startMinutes = CalendarUtils.parseTimeToMinutes(startTime);
              final endMinutes = startMinutes + 120; // 기본 2시간
              endTime =
                  '${(endMinutes ~/ 60).toString().padLeft(2, '0')}:${(endMinutes % 60).toString().padLeft(2, '0')}';
            }
          }

          activeRanges.add([
            CalendarUtils.parseTimeToMinutes(startTime),
            CalendarUtils.parseTimeToMinutes(endTime),
          ]);
        }
      }

      // 시간 슬롯별 active 여부 계산
      final hourSlotCount =
          ((rangeEndMinutes - rangeStartMinutes) / 60).round();
      final activePerHour = List<bool>.filled(hourSlotCount, false);
      int? minSessionStart;

      for (final range in activeRanges) {
        final start = range[0];
        final end = range[1];
        if (end <= start) continue;
        minSessionStart =
            minSessionStart == null
                ? start
                : (start < minSessionStart ? start : minSessionStart);

        for (int i = 0; i < hourSlotCount; i++) {
          final slotStart = rangeStartMinutes + (i * 60);
          final slotEnd = slotStart + 60;
          final overlaps = start < slotEnd && end > slotStart;
          if (overlaps) activePerHour[i] = true;
        }
      }

      // 슬롯 생성
      final rawSlots = <_TimeSlot>[];
      for (int i = 0; i < hourSlotCount; i++) {
        final startMinute = rangeStartMinutes + (i * 60);
        final endMinute = startMinute + 60;
        final hourLabel = (startMinute ~/ 60).toString().padLeft(2, '0');
        rawSlots.add(
          _TimeSlot(
            startMinute: startMinute,
            endMinute: endMinute,
            label: hourLabel,
            isActive: activePerHour[i],
            isMergedGap: false,
          ),
        );
      }

      // 긴 공백 합치기 (예약 없을 때는 합치지 않아서 시간 눈금이 보이도록 함)
      final slots = <_TimeSlot>[];
      final bool noReservations =
          widget.weeklyViewMode &&
          (widget.userReservations == null || widget.userReservations!.isEmpty);
      if (noReservations) {
        slots.addAll(rawSlots);
      } else {
        int i = 0;
        while (i < rawSlots.length) {
          final slot = rawSlots[i];
          if (slot.isActive) {
            slots.add(slot);
            i++;
            continue;
          }

          int j = i;
          while (j < rawSlots.length && !rawSlots[j].isActive) {
            j++;
          }
          final gapHours = j - i;
          if (gapHours >= _mergeGapMinHours) {
            slots.add(
              _TimeSlot(
                startMinute: rawSlots[i].startMinute,
                endMinute: rawSlots[j - 1].endMinute,
                label: '…',
                isActive: false,
                isMergedGap: true,
              ),
            );
          } else {
            for (int k = i; k < j; k++) {
              slots.add(rawSlots[k]);
            }
          }
          i = j;
        }
      }

      // 슬롯 높이 설정
      final baseSlotHeight = smart.hourSlotHeight;
      List<double> slotHeights = List<double>.filled(
        slots.length,
        baseSlotHeight,
      );
      if (noReservations && slots.isNotEmpty) {
        // 예약 없을 때: 눈금만 균등 높이로
        final equalHeight = viewportHeight / slots.length;
        slotHeights = List<double>.filled(slots.length, equalHeight);
      } else {
        for (int idx = 0; idx < slots.length; idx++) {
          final s = slots[idx];
          if (s.isActive) {
            slotHeights[idx] = baseSlotHeight;
          } else if (s.isMergedGap) {
            final gapHours = ((s.endMinute - s.startMinute) / 60).round().clamp(
              1,
              24,
            );
            slotHeights[idx] = (_effectiveMergedGapPxPerHour * gapHours).clamp(
              _effectiveMergedGapSlotHeight,
              baseSlotHeight * gapHours * 0.6,
            );
          } else {
            slotHeights[idx] = _effectiveMinGapHourSlotHeight;
          }
        }
      }

      // viewportHeight에 맞춰 동적 조절 (기존 로직과 동일)
      double currentTotal = slotHeights.fold<double>(0.0, (s, h) => s + h);

      if (currentTotal > viewportHeight) {
        for (int idx = 0; idx < slots.length; idx++) {
          if (currentTotal <= viewportHeight) break;
          if (slots[idx].isMergedGap &&
              slotHeights[idx] > _effectiveMergedGapSlotHeight) {
            final reducible = slotHeights[idx] - _effectiveMergedGapSlotHeight;
            final need = currentTotal - viewportHeight;
            final reduce = reducible < need ? reducible : need;
            slotHeights[idx] -= reduce;
            currentTotal -= reduce;
          }
        }

        for (int idx = 0; idx < slots.length; idx++) {
          if (currentTotal <= viewportHeight) break;
          if (!slots[idx].isActive && !slots[idx].isMergedGap) {
            if (slotHeights[idx] > _effectiveMinGapHourSlotHeight) {
              final reducible =
                  slotHeights[idx] - _effectiveMinGapHourSlotHeight;
              final need = currentTotal - viewportHeight;
              final reduce = reducible < need ? reducible : need;
              slotHeights[idx] -= reduce;
              currentTotal -= reduce;
            }
          }
        }

        if (currentTotal > viewportHeight) {
          final activeIndices = <int>[];
          double totalReducible = 0.0;
          for (int idx = 0; idx < slots.length; idx++) {
            if (!slots[idx].isActive) continue;
            activeIndices.add(idx);
            totalReducible += (slotHeights[idx] - _effectiveMinActiveSlotHeight)
                .clamp(0.0, double.infinity);
          }

          if (activeIndices.isNotEmpty && totalReducible > 0) {
            final need = currentTotal - viewportHeight;
            final ratio = (need / totalReducible).clamp(0.0, 1.0);
            double reduced = 0.0;
            for (final idx in activeIndices) {
              final reducible = (slotHeights[idx] -
                      _effectiveMinActiveSlotHeight)
                  .clamp(0.0, double.infinity);
              final reduce = reducible * ratio;
              slotHeights[idx] -= reduce;
              reduced += reduce;
            }
            currentTotal -= reduced;
          }
        }
      }

      if (currentTotal < viewportHeight) {
        final firstActiveIdx = slots.indexWhere((s) => s.isActive);
        final lastActiveIdx = slots.lastIndexWhere((s) => s.isActive);

        if (firstActiveIdx != -1 && lastActiveIdx != -1) {
          final extra = viewportHeight - currentTotal;
          final weights = List<double>.filled(slots.length, 0.0);
          for (int idx = 0; idx < slots.length; idx++) {
            final s = slots[idx];
            final isEdgeGap = idx < firstActiveIdx || idx > lastActiveIdx;
            final isMiddleNormalGap =
                !s.isActive && !s.isMergedGap && !isEdgeGap;

            if (isMiddleNormalGap) {
              weights[idx] = 0.0;
            } else if (s.isActive) {
              weights[idx] = 1.0;
            } else if (s.isMergedGap) {
              weights[idx] = 0.7;
            } else if (isEdgeGap) {
              weights[idx] = 0.5;
            }
          }

          final totalWeight = weights.fold<double>(0.0, (s, w) => s + w);
          if (totalWeight > 0 && extra > 0) {
            final unit = extra / totalWeight;
            for (int idx = 0; idx < slots.length; idx++) {
              if (weights[idx] <= 0) continue;
              slotHeights[idx] += unit * weights[idx];
            }
          }
        }
        currentTotal = slotHeights.fold<double>(0.0, (s, h) => s + h);
      }

      // 5) double 오차 방지: slotHeights 합이 정확히 viewportHeight가 되도록 스케일
      currentTotal = slotHeights.fold<double>(0.0, (s, h) => s + h);
      if (currentTotal > 0 && (currentTotal - viewportHeight).abs() > 0.001) {
        final scale = viewportHeight / currentTotal;
        for (int idx = 0; idx < slots.length; idx++) {
          slotHeights[idx] *= scale;
        }
      }
      // 6) 마지막 강제 맞춤: double 오차로 1px 밀림 방지
      currentTotal = slotHeights.fold<double>(0.0, (s, h) => s + h);
      final diff = viewportHeight - currentTotal;
      if (diff != 0 && slots.isNotEmpty) {
        final lastIdx = slots.length - 1;
        slotHeights[lastIdx] = (slotHeights[lastIdx] + diff).clamp(
          0.0,
          double.infinity,
        );
      }

      final slotTops = List<double>.filled(slots.length + 1, 0.0);
      for (int idx = 0; idx < slots.length; idx++) {
        slotTops[idx + 1] = slotTops[idx] + slotHeights[idx];
      }

      final initialJumpMinute =
          minSessionStart == null
              ? rangeStartMinutes
              : (minSessionStart - _basePaddingMinutes).clamp(
                rangeStartMinutes,
                rangeEndMinutes,
              );

      return _SlotLayout(
        slots: slots,
        slotHeights: slotHeights,
        slotTops: slotTops,
        rangeStartMinutes: rangeStartMinutes,
        rangeEndMinutes: rangeEndMinutes,
        initialJumpMinute: initialJumpMinute,
      );
    }

    // 기존 모드
    // 표시되는 요일들에 해당하는 세션들을 모아 "활성 시간대"를 계산
    final weekdays = dates.map((d) => d.weekday).toSet();

    // 정기 일정
    final regularSessions =
        _selectedCourse?.sessions.where(
          (s) => weekdays.contains(s.dayOfWeek),
        ) ??
        <CourseSession>[];

    // 비정기 일정: CourseProvider 결과만 사용
    final weekStart = CalendarUtils.startOfWeekMonday(dates.first);
    final weekStartDate = TimezoneUtils.formatDateToSeoul(weekStart);
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final weekOverrides =
        courseProvider
            .getOverridesForWeek(weekStartDate)
            .where((o) => o.courseId == _selectedCourse?.id && !o.isCancelled)
            .toList();

    // 추가된 비정기 일정을 CourseSession으로 변환
    final overrideSessions =
        weekOverrides
            .where(
              (o) =>
                  weekdays.contains(o.dayOfWeek) &&
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

    // 정기 일정 + 비정기 일정 병합
    final sessions = [...regularSessions, ...overrideSessions];

    // 시간 슬롯(시간 단위, 60분)별로 active 여부 계산 (이후 긴 공백은 merge하여 건너뛰기 슬롯으로 변환)
    final hourSlotCount = ((rangeEndMinutes - rangeStartMinutes) / 60).round();
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
        final overlaps = start < slotEnd && end > slotStart;
        if (overlaps) activePerHour[i] = true;
      }
    }

    // 1) 60분 슬롯을 만들고
    final rawSlots = <_TimeSlot>[];
    for (int i = 0; i < hourSlotCount; i++) {
      final startMinute = rangeStartMinutes + (i * 60);
      final endMinute = startMinute + 60;
      final hourLabel = (startMinute ~/ 60).toString().padLeft(2, '0');
      rawSlots.add(
        _TimeSlot(
          startMinute: startMinute,
          endMinute: endMinute,
          label: hourLabel,
          isActive: activePerHour[i],
          isMergedGap: false,
        ),
      );
    }

    // 2) 긴 공백(연속 inactive)을 하나의 슬롯으로 합쳐서 눈금을 건너뛰게 만들기
    final slots = <_TimeSlot>[];
    int i = 0;
    while (i < rawSlots.length) {
      final slot = rawSlots[i];
      if (slot.isActive) {
        slots.add(slot);
        i++;
        continue;
      }

      int j = i;
      while (j < rawSlots.length && !rawSlots[j].isActive) {
        j++;
      }
      final gapHours = j - i;
      if (gapHours >= _mergeGapMinHours) {
        slots.add(
          _TimeSlot(
            startMinute: rawSlots[i].startMinute,
            endMinute: rawSlots[j - 1].endMinute,
            label: '…',
            isActive: false,
            isMergedGap: true,
          ),
        );
      } else {
        for (int k = i; k < j; k++) {
          slots.add(rawSlots[k]);
        }
      }
      i = j;
    }

    // 3) 기본 슬롯 높이 설정 (병합 공백은 시간 길이에 비례)
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
        slotHeights[idx] = (_effectiveMergedGapPxPerHour * gapHours).clamp(
          _effectiveMergedGapSlotHeight,
          baseSlotHeight * gapHours * 0.6,
        );
      } else {
        slotHeights[idx] = _effectiveMinGapHourSlotHeight;
      }
    }

    // 4) viewportHeight에 맞춰 동적 조절
    double currentTotal = slotHeights.fold<double>(0.0, (s, h) => s + h);

    // (a) 너무 크면: gap 먼저 더 줄이고, 그래도 크면 active도 최소까지만 줄임
    if (currentTotal > viewportHeight) {
      // merged gap: 더 압축 가능(최소 _effectiveMergedGapSlotHeight)
      for (int idx = 0; idx < slots.length; idx++) {
        if (currentTotal <= viewportHeight) break;
        if (slots[idx].isMergedGap &&
            slotHeights[idx] > _effectiveMergedGapSlotHeight) {
          final reducible = slotHeights[idx] - _effectiveMergedGapSlotHeight;
          final need = currentTotal - viewportHeight;
          final reduce = reducible < need ? reducible : need;
          slotHeights[idx] -= reduce;
          currentTotal -= reduce;
        }
      }

      // 일반 gap: _effectiveMinGapHourSlotHeight까지는 이미 설정되어 있지만, 혹시라도 늘어났다면 다시 줄이기
      for (int idx = 0; idx < slots.length; idx++) {
        if (currentTotal <= viewportHeight) break;
        if (!slots[idx].isActive && !slots[idx].isMergedGap) {
          if (slotHeights[idx] > _effectiveMinGapHourSlotHeight) {
            final reducible = slotHeights[idx] - _effectiveMinGapHourSlotHeight;
            final need = currentTotal - viewportHeight;
            final reduce = reducible < need ? reducible : need;
            slotHeights[idx] -= reduce;
            currentTotal -= reduce;
          }
        }
      }

      // active도 줄여야 하는 상황이면: 균등하게 줄이되 최소 높이 보장
      if (currentTotal > viewportHeight) {
        final activeIndices = <int>[];
        double totalReducible = 0.0;
        for (int idx = 0; idx < slots.length; idx++) {
          if (!slots[idx].isActive) continue;
          activeIndices.add(idx);
          totalReducible += (slotHeights[idx] - _effectiveMinActiveSlotHeight)
              .clamp(0.0, double.infinity);
        }

        if (activeIndices.isNotEmpty && totalReducible > 0) {
          final need = currentTotal - viewportHeight;
          final ratio = (need / totalReducible).clamp(0.0, 1.0);
          double reduced = 0.0;
          for (final idx in activeIndices) {
            final reducible = (slotHeights[idx] - _effectiveMinActiveSlotHeight)
                .clamp(0.0, double.infinity);
            final reduce = reducible * ratio;
            slotHeights[idx] -= reduce;
            reduced += reduce;
          }
          currentTotal -= reduced;
        }
      }
    }

    // (b) 너무 작으면: 앞/뒤 여백(inactive)만 확장해서 채움 (중간 공백(merged/non-merged)은 확장 X)
    if (currentTotal < viewportHeight) {
      final firstActiveIdx = slots.indexWhere((s) => s.isActive);
      final lastActiveIdx = slots.lastIndexWhere((s) => s.isActive);

      if (firstActiveIdx != -1 && lastActiveIdx != -1) {
        // “카드 높이(예: 400)”를 항상 꽉 채우기 위해, 확장 가능한 구간에 가중치로 여분 높이를 분배
        // - active: 한눈에 보이도록 어느 정도는 늘려도 됨
        // - merged gap(…): “건너뛰기”를 유지하되, 너무 납작하지 않게(미세 눈금도 보이게) 적당히 늘림
        // - 앞/뒤 여백: 늘림 가능
        // - 중간 일반 공백(코스 사이): 늘리지 않음 (요청사항)
        final extra = viewportHeight - currentTotal;
        final weights = List<double>.filled(slots.length, 0.0);
        for (int idx = 0; idx < slots.length; idx++) {
          final s = slots[idx];
          final isEdgeGap = idx < firstActiveIdx || idx > lastActiveIdx;
          final isMiddleNormalGap = !s.isActive && !s.isMergedGap && !isEdgeGap;

          if (isMiddleNormalGap) {
            weights[idx] = 0.0;
          } else if (s.isActive) {
            weights[idx] = 1.0;
          } else if (s.isMergedGap) {
            weights[idx] = 0.7;
          } else if (isEdgeGap) {
            weights[idx] = 0.5;
          }
        }

        final totalWeight = weights.fold<double>(0.0, (s, w) => s + w);
        if (totalWeight > 0 && extra > 0) {
          final unit = extra / totalWeight;
          for (int idx = 0; idx < slots.length; idx++) {
            if (weights[idx] <= 0) continue;
            slotHeights[idx] += unit * weights[idx];
          }
        }
      }
      currentTotal = slotHeights.fold<double>(0.0, (s, h) => s + h);
    }

    // 5) double 오차 방지: slotHeights 합이 정확히 viewportHeight가 되도록 스케일
    currentTotal = slotHeights.fold<double>(0.0, (s, h) => s + h);
    if (currentTotal > 0 && (currentTotal - viewportHeight).abs() > 0.001) {
      final scale = viewportHeight / currentTotal;
      for (int idx = 0; idx < slots.length; idx++) {
        slotHeights[idx] *= scale;
      }
    }
    // 6) 마지막 강제 맞춤: double 오차로 1px 밀림 방지
    currentTotal = slotHeights.fold<double>(0.0, (s, h) => s + h);
    final diff = viewportHeight - currentTotal;
    if (diff != 0 && slots.isNotEmpty) {
      final lastIdx = slots.length - 1;
      slotHeights[lastIdx] = (slotHeights[lastIdx] + diff).clamp(
        0.0,
        double.infinity,
      );
    }

    // prefix sum (slotTops)
    final slotTops = List<double>.filled(slots.length + 1, 0.0);
    for (int idx = 0; idx < slots.length; idx++) {
      slotTops[idx + 1] = slotTops[idx] + slotHeights[idx];
    }

    // 초기 점프 위치: 첫 세션 시작 - 2시간 (없으면 rangeStart)
    final initialJumpMinute =
        minSessionStart == null
            ? rangeStartMinutes
            : (minSessionStart - _basePaddingMinutes).clamp(
              rangeStartMinutes,
              rangeEndMinutes,
            );

    return _SlotLayout(
      slots: slots,
      slotHeights: slotHeights,
      slotTops: slotTops,
      rangeStartMinutes: rangeStartMinutes,
      rangeEndMinutes: rangeEndMinutes,
      initialJumpMinute: initialJumpMinute,
    );
  }

  // 날짜별 컬럼
  Widget _buildDayColumn(
    DateTime date, {
    required List<_TimeSlot> slots,
    required int rangeStartMinutes,
    required List<double> slotTops,
    required List<double> slotHeights,
    required double Function(int minute) yForMinute,
    required int Function(int minute) slotIndexForMinute,
  }) {
    // 일정보기 모드인 경우
    if (widget.weeklyViewMode) {
      if (widget.userReservations == null || widget.userReservations!.isEmpty) {
        // 예약 없을 때: 눈금만 (가로 시간선만 표시)
        final totalHeight = slotTops.isNotEmpty ? slotTops.last : 0.0;
        return Container(
          decoration: BoxDecoration(
            color: widget.backgroundColor ?? AppColors.backgroundWhite,
            border: Border(
              left: BorderSide(color: AppColors.borderLight, width: 0.5),
            ),
          ),
          height: totalHeight,
          clipBehavior: Clip.none,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              ...slots.asMap().entries.map((entry) {
                final index = entry.key;
                return Positioned(
                  top: slotTops[index] + _lineOffset,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 0.5,
                    color: AppColors.borderLight.withOpacity(0.2),
                  ),
                );
              }).toList(),
            ],
          ),
        );
      }

      // 해당 날짜의 예약된 세션들 찾기
      final dateReservations =
          widget.userReservations!.where((reservation) {
            final resDate = DateTime(
              reservation.reservedDate.year,
              reservation.reservedDate.month,
              reservation.reservedDate.day,
            );
            final targetDate = DateTime(date.year, date.month, date.day);
            return resDate == targetDate;
          }).toList();

      if (dateReservations.isEmpty) {
        final totalHeight = slotTops.isNotEmpty ? slotTops.last : 0.0;
        return Container(
          height: totalHeight,
          decoration: BoxDecoration(
            color: AppColors.backgroundWhite,
            border: Border(
              left: BorderSide(color: AppColors.borderLight, width: 0.5),
            ),
          ),
        );
      }

      // 세션이 시작하는 슬롯만 찾기
      final sessionStartSlots = <int, _ReservationSessionInfo>{};

      for (final reservation in dateReservations) {
        if (widget.courses.isEmpty) continue;
        final course = widget.courses.firstWhere(
          (c) => c.id == reservation.courseId,
          orElse: () => widget.courses.first,
        );

        // 정기 세션 찾기
        CourseSession? session = course.findSession(
          reservation.dayOfWeek,
          reservation.startTime,
        );

        // 정기 세션이 없으면 비정기 세션 확인
        if (session == null) {
          final dateString = CalendarUtils.formatDateYMD(date);
          // listen: true로 변경하여 비정기 세션이 로드되면 위젯이 리빌드되도록 함
          final courseProvider = Provider.of<CourseProvider>(context);
          final weekStart = CalendarUtils.startOfWeekMonday(date);
          final weekStartDate = TimezoneUtils.formatDateToSeoul(weekStart);
          final overrides = courseProvider.getOverridesForWeek(weekStartDate);

          // 비정기 세션 찾기 (예약과 일치하는 override)
          CourseOverride? foundOverride;
          CourseOverride? cancelledOverride;

          try {
            // 취소된 비정기 세션 확인
            cancelledOverride = overrides.firstWhere(
              (o) =>
                  o.courseId == reservation.courseId &&
                  o.date == dateString &&
                  o.dayOfWeek == reservation.dayOfWeek &&
                  o.startTime == reservation.startTime &&
                  o.isCancelled == true,
            );
          } catch (_) {
            // 취소된 override를 찾지 못함
            cancelledOverride = null;
          }

          // 취소된 비정기 세션이면 예약 표시하지 않음
          if (cancelledOverride != null) {
            session = null;
          } else {
            try {
              foundOverride = overrides.firstWhere(
                (o) =>
                    o.courseId == reservation.courseId &&
                    o.date == dateString &&
                    o.dayOfWeek == reservation.dayOfWeek &&
                    o.startTime == reservation.startTime &&
                    !o.isCancelled &&
                    o.startTime != null &&
                    o.endTime != null,
              );
            } catch (_) {
              // override를 찾지 못함
              foundOverride = null;
            }

            if (foundOverride != null &&
                foundOverride.startTime != null &&
                foundOverride.endTime != null) {
              // 실제 override를 찾았으면 세션 생성
              session = CourseSession(
                dayOfWeek: foundOverride.dayOfWeek,
                startTime: foundOverride.startTime!,
                endTime: foundOverride.endTime!,
                capacity: foundOverride.capacity ?? 0,
              );
            } else {
              // override를 찾지 못했지만 예약 정보가 있으면 fallback으로 세션 생성
              // (비정기 세션이 아직 로드되지 않았을 수 있으므로 예약 정보로 표시)
              final startMinutes = CalendarUtils.parseTimeToMinutes(
                reservation.startTime,
              );
              final endMinutes = startMinutes + 120; // 기본 2시간
              final endTime =
                  '${(endMinutes ~/ 60).toString().padLeft(2, '0')}:${(endMinutes % 60).toString().padLeft(2, '0')}';
              session = CourseSession(
                dayOfWeek: reservation.dayOfWeek,
                startTime: reservation.startTime,
                endTime: endTime,
                capacity: 0,
              );
            }
          }
        }

        // session이 null이면 건너뛰기 (정기/비정기 세션 모두 찾지 못함)
        // ignore: unnecessary_null_comparison
        if (session == null) continue;

        final sessionStartMinutes = CalendarUtils.parseTimeToMinutes(
          session.startTime,
        );
        if (sessionStartMinutes < rangeStartMinutes) continue;
        if (sessionStartMinutes >=
            (slots.isNotEmpty ? slots.last.endMinute : rangeStartMinutes))
          continue;

        final idx = slotIndexForMinute(sessionStartMinutes);
        if (idx < 0 || idx >= slots.length) continue;
        if (!sessionStartSlots.containsKey(idx) ||
            CalendarUtils.parseTimeToMinutes(
                  sessionStartSlots[idx]!.session.startTime,
                ) >
                sessionStartMinutes) {
          sessionStartSlots[idx] = _ReservationSessionInfo(
            course: course,
            session: session,
            reservation: reservation,
            date: date,
          );
        }
      }

      final totalHeight = slotTops.isNotEmpty ? slotTops.last : 0.0;

      return Container(
        decoration: BoxDecoration(
          color: widget.backgroundColor ?? AppColors.backgroundWhite,
          border: Border(
            left: BorderSide(color: AppColors.borderLight, width: 0.5),
          ),
        ),
        height: totalHeight,
        clipBehavior: Clip.none,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // 시간대 구분선
            ...slots.asMap().entries.map((entry) {
              final index = entry.key;
              final isActiveSlot = slots[index].isActive;
              final isMergedGap = slots[index].isMergedGap;
              return Positioned(
                top: slotTops[index] + _lineOffset,
                left: 0,
                right: 0,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      height: 0.5,
                      color:
                          isActiveSlot
                              ? AppColors.borderLight
                              : AppColors.borderLight.withOpacity(0.2),
                    ),
                    if (isMergedGap)
                      ..._buildMergedGapInnerTicks(
                        slotHeight: slotHeights[index],
                      ),
                  ],
                ),
              );
            }).toList(),
            // 세션 블록들
            ...sessionStartSlots.entries.map((entry) {
              final slotIdx = entry.key;
              final info = entry.value;
              return _buildReservationSessionBlock(
                info,
                startTimeSlot: slots[slotIdx].label,
                rangeStartMinutes: rangeStartMinutes,
                yForMinute: yForMinute,
              );
            }).toList(),
          ],
        ),
      );
    }

    // 기존 모드
    if (_selectedCourse == null) {
      final totalHeight = slotTops.isNotEmpty ? slotTops.last : 0.0;
      return Container(
        height: totalHeight,
        decoration: BoxDecoration(
          color: widget.backgroundColor ?? AppColors.backgroundWhite,
          border: Border(
            left: BorderSide(color: AppColors.borderLight, width: 0.5),
          ),
        ),
      );
    }

    // 정기 일정 가져오기
    final regularSessions = _selectedCourse!.getSessionsByDay(date.weekday);

    // 비정기 일정 확인 (CourseProvider에서만 조회)
    final dayOverrides = _getOverridesForDate(context, date);

    // 취소된 정기 일정 필터링
    final cancelledStartTimes =
        dayOverrides
            .where((o) => o.isCancelled && o.dayOfWeek == date.weekday)
            .map((o) => o.startTime ?? '')
            .toSet();

    final activeRegularSessions =
        regularSessions
            .where((s) => !cancelledStartTimes.contains(s.startTime))
            .toList();

    // 추가된 비정기 일정을 CourseSession으로 변환
    final addedOverrideSessions =
        dayOverrides
            .where(
              (o) =>
                  !o.isCancelled &&
                  o.dayOfWeek == date.weekday &&
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

    // 정기 일정 + 추가된 비정기 일정 병합
    final daySessions = [...activeRegularSessions, ...addedOverrideSessions];

    // 세션이 시작하는 슬롯만 찾기 (긴 공백 merge/skip과 관계없이 slotIndex 기준으로 버킷)
    final sessionStartSlots = <int, CourseSession>{};

    for (final session in daySessions) {
      final sessionStartMinutes = CalendarUtils.parseTimeToMinutes(
        session.startTime,
      );
      // 표시 범위 밖이면 스킵
      if (sessionStartMinutes < rangeStartMinutes) continue;
      if (sessionStartMinutes >=
          (slots.isNotEmpty ? slots.last.endMinute : rangeStartMinutes))
        continue;

      final idx = slotIndexForMinute(sessionStartMinutes);
      if (idx < 0 || idx >= slots.length) continue;
      if (!sessionStartSlots.containsKey(idx) ||
          CalendarUtils.parseTimeToMinutes(sessionStartSlots[idx]!.startTime) >
              sessionStartMinutes) {
        sessionStartSlots[idx] = session;
      }
    }

    // 전체 컬럼 높이 계산
    final totalHeight = slotTops.isNotEmpty ? slotTops.last : 0.0;

    return Container(
      decoration: BoxDecoration(
        color: widget.backgroundColor ?? AppColors.backgroundWhite,
        border: Border(
          left: BorderSide(color: AppColors.borderLight, width: 0.5),
        ),
      ),
      height: totalHeight,
      clipBehavior: Clip.none,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 시간대 구분선
          ...slots.asMap().entries.map((entry) {
            final index = entry.key;
            final isActiveSlot = slots[index].isActive;
            final isMergedGap = slots[index].isMergedGap;
            return Positioned(
              top: slotTops[index] + _lineOffset,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    height: 0.5,
                    color:
                        isActiveSlot
                            ? AppColors.borderLight
                            : AppColors.borderLight.withOpacity(0.2),
                  ),
                  if (isMergedGap)
                    ..._buildMergedGapInnerTicks(
                      slotHeight: slotHeights[index],
                    ),
                ],
              ),
            );
          }).toList(),
          // 세션 블록들
          ...sessionStartSlots.entries.map((entry) {
            final slotIdx = entry.key;
            final session = entry.value;
            return _buildSessionBlock(
              session,
              date,
              startTimeSlot: slots[slotIdx].label,
              rangeStartMinutes: rangeStartMinutes,
              yForMinute: yForMinute,
            );
          }).toList(),
        ],
      ),
    );
  }

  // 예약 세션 블록 (일정보기 모드용)
  Widget _buildReservationSessionBlock(
    _ReservationSessionInfo info, {
    required String startTimeSlot,
    required int rangeStartMinutes,
    required double Function(int minute) yForMinute,
  }) {
    final session = info.session;
    final date = info.date;

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

    // 방문 완료 여부 확인 (세션 종료 시간이 지났는지)
    final now = TimezoneUtils.getSeoulDateTime();
    final sessionEndDateTime = DateTime(
      date.year,
      date.month,
      date.day,
      int.parse(session.endTime.split(':')[0]),
      int.parse(session.endTime.split(':')[1]),
    );
    final isVisited = now.isAfter(sessionEndDateTime);

    // 강조할 예약인지 (흔들기 애니메이션 대상, 글로우는 사용하지 않음)
    final shouldHighlight =
        widget.highlightReservation != null &&
        info.course.id == widget.highlightReservation!['courseId'] &&
        session.dayOfWeek == widget.highlightReservation!['dayOfWeek'] &&
        session.startTime == widget.highlightReservation!['startTime'] &&
        date.year ==
            (widget.highlightReservation!['reservedDate'] as DateTime).year &&
        date.month ==
            (widget.highlightReservation!['reservedDate'] as DateTime).month &&
        date.day ==
            (widget.highlightReservation!['reservedDate'] as DateTime).day;

    // 예약 처리 중인지 확인 (ReservationProvider 사용)
    final placeId =
        Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id ??
        '';
    final reservationProvider = Provider.of<ReservationProvider>(
      context,
      listen: false,
    );
    final processingKey =
        placeId.isEmpty
            ? null
            : reservationProvider.operationKeyFromParts(
              placeId: placeId,
              courseId: info.course.id,
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
            : isVisited
            ? SessionBlockType.locked
            : SessionBlockType.reserved;
    final blockStyle = SessionBlockStyle.fromType(
      blockType,
      courseColor: info.course.colorValue,
    );

    return Positioned(
      top: topPosition,
      left: _sessionPadding,
      right: _sessionPadding,
      height: sessionHeightPx,
      child: GestureDetector(
        onTap:
            widget.onSessionTap != null
                ? () {
                  widget.onSessionTap!(info.course, session, date);
                }
                : null,
        child:
            shouldHighlight && _shakeAnimation != null
                ? AnimatedBuilder(
                  animation: _shakeAnimation!,
                  builder: (context, child) {
                    final shakeOffset =
                        math.sin(_shakeAnimation!.value * math.pi * 6) *
                        6.0 *
                        (1.0 - _shakeAnimation!.value * 0.3);
                    return Transform.translate(
                      offset: Offset(0, shakeOffset),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: sessionHeightPx >= 50 ? 8 : 6,
                        ),
                        decoration: blockStyle.toBoxDecoration(),
                        child: child,
                      ),
                    );
                  },
                  child: Stack(
                    children: [
                      if (!isProcessing && sessionHeightPx >= 14)
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                info.course.name,
                                style: TextStyle(
                                  color: blockStyle.textColor,
                                  fontSize:
                                      sessionHeightPx >= 60
                                          ? 22
                                          : (sessionHeightPx >= 40 ? 18 : 16),
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (sessionHeightPx >= 70) ...[
                                SizedBox(height: sessionHeightPx >= 80 ? 4 : 3),
                                Text(
                                  '${session.startTime} - ${session.endTime}',
                                  style: TextStyle(
                                    color: blockStyle.iconColor,
                                    fontSize: sessionHeightPx >= 90 ? 16 : 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
                          ),
                        ),
                      if (isProcessing && sessionHeightPx >= 18)
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
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
                        ),
                    ],
                  ),
                )
                : Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: sessionHeightPx >= 50 ? 8 : 6,
                  ),
                  decoration: blockStyle.toBoxDecoration(),
                  child: Stack(
                    children: [
                      // sessionHeightPx가 아주 작아지는 케이스가 있어, 내부 Column 렌더링 시
                      // RenderFlex overflow(BOTTOM OVERFLOWED...)가 발생할 수 있음.
                      // -> 높이가 충분할 때만 텍스트/로딩 UI 렌더링
                      if (!isProcessing && sessionHeightPx >= 14)
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // 코스 이름
                              Text(
                                info.course.name,
                                style: TextStyle(
                                  color: blockStyle.textColor,
                                  fontSize:
                                      sessionHeightPx >= 60
                                          ? 22
                                          : (sessionHeightPx >= 40 ? 18 : 16),
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              // 시간 (높이가 충분할 때만 표시)
                              if (sessionHeightPx >= 70) ...[
                                SizedBox(height: sessionHeightPx >= 80 ? 4 : 3),
                                Text(
                                  '${session.startTime} - ${session.endTime}',
                                  style: TextStyle(
                                    color: blockStyle.iconColor,
                                    fontSize: sessionHeightPx >= 90 ? 16 : 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
                          ),
                        ),
                      // 로딩 중일 때: 높이가 충분할 때만 표시 (작으면 숨김)
                      if (isProcessing && sessionHeightPx >= 18)
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
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
                        ),
                    ],
                  ),
                ),
      ),
    );
  }

  // 세션 블록 (하나의 연속된 위젯으로 그림)
  Widget _buildSessionBlock(
    CourseSession session,
    DateTime date, {
    required String startTimeSlot,
    required int rangeStartMinutes,
    required double Function(int minute) yForMinute,
  }) {
    if (_selectedCourse == null) return const SizedBox.shrink();

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

    // 예약/잠금 정보 (중앙 ReservationSummaryProvider + 정책 엔진)
    // listen: true → 사용자 예약 시 N/M 실시간 반영
    final courseId = _selectedCourse!.id;
    final dateString = CalendarUtils.formatDateYMD(date);
    final sessionId = SessionReservationSummary.generateSessionId(
      courseId,
      session.dayOfWeek,
      session.startTime,
    );
    final srProvider = context.watch<ReservationSummaryProvider>();
    final sr = srProvider.getSessionReservationSummary(sessionId, dateString);

    // 비정기 일정인지 확인 (CourseProvider에서만 조회)
    final dayOverrides = _getOverridesForDate(context, date);
    final isOverrideSession = dayOverrides.any(
      (o) =>
          !o.isCancelled &&
          o.dayOfWeek == session.dayOfWeek &&
          o.startTime == session.startTime &&
          o.endTime == session.endTime,
    );

    // 비정기 일정이면 override의 capacity 사용, 아니면 정기 일정의 capacity 사용
    final overrideCapacity =
        isOverrideSession
            ? dayOverrides
                .firstWhere(
                  (o) =>
                      !o.isCancelled &&
                      o.dayOfWeek == session.dayOfWeek &&
                      o.startTime == session.startTime &&
                      o.endTime == session.endTime,
                )
                .capacity
            : null;

    // 수용인원: 프로바이더(날짜별) > 비정기 세션 정원 > 정기 세션 capacity
    final totalSeats = srProvider.getTotalCapacity(
      sessionId,
      dateString,
      fallback: overrideCapacity ?? session.capacity,
    );
    final reservedCount = sr?.reservedCount ?? 0;
    final reservedCountDisplay = srProvider.getReservedCountDisplayString(
      sessionId,
      dateString,
    );
    final remainingSeats = math.max(0, totalSeats - reservedCount);

    final policy = _coursePolicy ?? CoursePolicy.defaultValue;
    final enrollmentCanReserve =
        widget.adminSelectionMode
            ? true
            : (widget.enrollmentsByCourseId != null
                ? (widget.enrollmentsByCourseId![courseId]?.canReserve ?? false)
                : true);

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
      final weekStart = CalendarUtils.startOfWeekMonday(date);
      final weekStartDateString = CalendarUtils.formatDateYMD(weekStart);
      final placeId =
          Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id;
      isBookingWeekOpened =
          placeId != null &&
          Provider.of<CourseProvider>(context, listen: false)
              .getBookingWeekOpens(placeId, courseId)
              .contains(weekStartDateString);
    }

    // 미리 열린 주차인 경우 잠금 해제
    final effectiveCanReserve =
        eligibility.canReserve ||
        (isBookingWeekOpened &&
            eligibility.reason == ReservationLockReason.notOpenedYet);

    final isLocked = !effectiveCanReserve;
    final isFull = eligibility.reason == ReservationLockReason.full;
    final isPastDate = eligibility.reason == ReservationLockReason.pastDate;

    // 현재 예약된 세션인지 확인
    final isCurrentReservation =
        widget.currentReservationDayOfWeek != null &&
        widget.currentReservationStartTime != null &&
        widget.currentReservationDate != null &&
        session.dayOfWeek == widget.currentReservationDayOfWeek &&
        session.startTime == widget.currentReservationStartTime &&
        date.year == widget.currentReservationDate!.year &&
        date.month == widget.currentReservationDate!.month &&
        date.day == widget.currentReservationDate!.day;

    // "선택 가능(관리자 변경 선택)" 여부: 관리자는 항상 오픈/마감 무시, 과거만 차단 (꽉 찬 것도 선택 가능)
    final selectableForAdminMove = !isCurrentReservation && !isPastDate;

    // 지나간 일정인지 확인 (롱프레스/탭 취소 제외용) - 세션 시작 시간까지 고려
    final nowForPastCheck = TimezoneUtils.getSeoulDateTime();
    final sessionStartTime = session.startTime.split(':');
    final sessionHour = int.parse(sessionStartTime[0]);
    final sessionMinute = int.parse(sessionStartTime[1]);
    final sessionDateTime = DateTime(
      date.year,
      date.month,
      date.day,
      sessionHour,
      sessionMinute,
    );
    final isPastSession = sessionDateTime.isBefore(nowForPastCheck);

    // 보기/선택 목적별로 "비활성 표시" 기준을 분리
    // adminSelectNewSlot: 지나간 세션만 회색 처리, 꽉 찬 세션은 선택 가능
    // adminNavigate: 지나간 세션만 회색 처리 (수용인원 꽉 찬 것은 제외)
    // isPastDate 또는 isPastSession이 true이면 무조건 회색 처리 (지나간 세션은 확실히 회색으로)
    final bool visuallyDisabled = switch (_usage) {
      CompactCalendarUsage.adminSelectNewSlot =>
        isPastDate ||
            isPastSession ||
            (!selectableForAdminMove &&
                !isFull), // 지나간 것은 무조건 회색, 선택 불가능한 것도 회색 (단, 꽉 찬 것은 제외)
      CompactCalendarUsage.adminNavigate =>
        (isPastDate || isPastSession), // 지나간 세션만 회색 처리
      CompactCalendarUsage.userWeeklyReservationsView => (isFull || isLocked),
      CompactCalendarUsage.courseDetailView => (isFull || isLocked),
    };

    // 편집 모드인지 확인 (현재 예약 정보가 전달되었으면 편집 모드)
    final isEditMode =
        widget.currentReservationDayOfWeek != null ||
        widget.currentReservationStartTime != null ||
        widget.currentReservationDate != null;

    // 선택된 세션인지 확인 (외부에서 전달된 선택 정보 우선)
    final isSelectedFromExternal =
        widget.selectedSessionDayOfWeek != null &&
        widget.selectedSessionStartTime != null &&
        widget.selectedSessionDate != null &&
        widget.selectedSessionDayOfWeek == session.dayOfWeek &&
        widget.selectedSessionStartTime == session.startTime &&
        widget.selectedSessionDate!.year == date.year &&
        widget.selectedSessionDate!.month == date.month &&
        widget.selectedSessionDate!.day == date.day;

    final isSelectedFromInternal =
        _selectedSession != null &&
        _selectedDate != null &&
        _selectedSession!.dayOfWeek == session.dayOfWeek &&
        _selectedSession!.startTime == session.startTime &&
        _selectedDate!.year == date.year &&
        _selectedDate!.month == date.month &&
        _selectedDate!.day == date.day;

    final isSelected = isSelectedFromExternal || isSelectedFromInternal;

    // 편집 모드일 때만 선택 가능한 세션에 opacity 적용
    // adminSelectNewSlot 모드: 이동 가능/불가 모두 회색으로 통일, 자물쇠 아이콘으로만 구분 → opacity 1.0
    // 일반 모드에서는 기본적으로 진하게 표시
    final opacity = switch (_usage) {
      CompactCalendarUsage.adminSelectNewSlot => 1.0,
      _ =>
        (isEditMode && !isCurrentReservation && !isFull && !isLocked)
            ? (isSelected ? 1.0 : 0.4)
            : 1.0,
    };

    // 탭 가능 여부는 "정책(예약 가능)"이 아니라 "화면 목적(사용처)"이 결정
    final bool canTap = switch (_usage) {
      // 관리자 홈 등: 기록/조회 목적이므로 잠김/과거/만석이어도 탭은 가능
      CompactCalendarUsage.adminNavigate => widget.onSessionTap != null,
      // 관리자 예약 변경: 지나간 세션만 선택 불가, 꽉 찬 세션은 선택 가능 (다이얼로그로 확인)
      CompactCalendarUsage.adminSelectNewSlot =>
        widget.onSessionTap != null && (!isCurrentReservation && !isPastDate),
      // 유저 주간(마이페이지) 모드는 이 블록 경로를 사용하지 않음(weeklyViewMode 경로)
      CompactCalendarUsage.userWeeklyReservationsView =>
        widget.onSessionTap != null,
      // 코스 상세 화면: 탭 가능
      CompactCalendarUsage.courseDetailView => widget.onSessionTap != null,
    };

    // 취소 중인 세션인지 확인
    final dateStringForCancel = TimezoneUtils.formatDateToSeoul(date);
    final cancellingKey =
        '$dateStringForCancel|${session.dayOfWeek}|${session.startTime}';
    final isCancelling = _cancellingSessions.contains(cancellingKey);

    // 비정기 일정 저장 중인 세션인지 확인 (compact_calendar에서 해당 박스에 로딩 스피너)
    final weekStartDate = TimezoneUtils.formatDateToSeoul(
      CalendarUtils.startOfWeekMonday(date),
    );
    final isSavingOverride = context.read<CourseProvider>().isSavingOverride(
      weekStartDate,
      dateStringForCancel,
      session.dayOfWeek,
      session.startTime,
    );

    final blockType =
        (isCancelling || isSavingOverride)
            ? SessionBlockType.processing
            : isCurrentReservation
            ? SessionBlockType.reserved
            : visuallyDisabled
            ? SessionBlockType.locked
            : SessionBlockType.available;
    // adminNavigate(관리자 홈): 예약 여부와 관계없이 코스 색상으로 통일
    final effectiveBlockType =
        (_usage == CompactCalendarUsage.adminNavigate &&
                blockType == SessionBlockType.available)
            ? SessionBlockType.reserved
            : blockType;
    // adminSelectNewSlot 모드에서는 직접 계산한 isPastSession도 체크
    final bool canTapWithPastCheck = switch (_usage) {
      CompactCalendarUsage.adminSelectNewSlot =>
        canTap && !isPastSession, // isPastDate와 isPastSession 둘 다 체크
      _ => canTap,
    };

    var blockStyle = SessionBlockStyle.fromType(
      effectiveBlockType,
      courseColor: _selectedCourse!.colorValue,
    );
    // adminSelectNewSlot: 이동 불가=회색+자물쇠, 이동 가능=연한 courseColor (선택 시 진하게)
    if (_usage == CompactCalendarUsage.adminSelectNewSlot) {
      final color = _selectedCourse!.colorValue;
      final movableBg = isSelected ? color : color.withOpacity(0.3);
      blockStyle =
          canTapWithPastCheck
              ? SessionBlockStyle(
                backgroundColor: movableBg,
                textColor: SessionBlockStyle.textColorForBackground(movableBg),
                iconColor: SessionBlockStyle.textColorForBackground(movableBg),
                borderRadius: 12,
                showShadow: isSelected,
              )
              : SessionBlockStyle.fromType(
                SessionBlockType.locked,
                courseColor: color,
              );
    }

    return Positioned(
      top: topPosition,
      left: _sessionPadding,
      right: _sessionPadding,
      height: sessionHeightPx,
      child: GestureDetector(
        onTap:
            canTapWithPastCheck
                ? () async {
                  // adminSelectNewSlot: 콜백을 먼저 호출하고, 취소 시(false) 내부 선택 유지(이전 opacity 복원)
                  if (_usage == CompactCalendarUsage.adminSelectNewSlot) {
                    final result = widget.onSessionTap!(
                      _selectedCourse!,
                      session,
                      date,
                    );
                    final accepted =
                        result is Future<bool> ? await result : true;
                    if (!mounted) return;
                    if (accepted) {
                      setState(() {
                        if (_selectedSession != null &&
                            _selectedDate != null &&
                            _selectedSession!.dayOfWeek == session.dayOfWeek &&
                            _selectedSession!.startTime == session.startTime &&
                            _selectedDate!.year == date.year &&
                            _selectedDate!.month == date.month &&
                            _selectedDate!.day == date.day) {
                          _selectedSession = null;
                          _selectedDate = null;
                        } else {
                          _selectedSession = session;
                          _selectedDate = date;
                        }
                      });
                    }
                  } else {
                    widget.onSessionTap!(_selectedCourse!, session, date);
                  }
                }
                : null,
        onLongPress:
            _usage == CompactCalendarUsage.adminNavigate && !isPastSession
                ? () {
                  // 지나간 일정은 롱프레스로도 취소 불가 (이미 위에서 계산한 isPastSession 사용)
                  if (isPastSession) {
                    SnackbarUtil.showInfo(context, '지나간 일정은 취소할 수 없습니다.');
                    return;
                  }
                  _showCancelSessionDialog(_selectedCourse!, session, date);
                }
                : null,
        child:
            (opacity < 1.0
                ? Opacity(
                  opacity: opacity,
                  child: _sessionBlockContainer(
                    session,
                    date,
                    sessionHeightPx,
                    blockStyle,
                    eligibility,
                    isBookingWeekOpened,
                    canTapWithPastCheck,
                    isCurrentReservation,
                    isLocked,
                    (isCancelling || isSavingOverride),
                    totalSeats,
                    reservedCount,
                    remainingSeats,
                    isPastSession,
                    canTap,
                    adminSelectNewSlotLockFilled:
                        _usage == CompactCalendarUsage.adminSelectNewSlot
                            ? !canTapWithPastCheck
                            : null,
                    isAdminSelectNewSlot:
                        _usage == CompactCalendarUsage.adminSelectNewSlot,
                    reservedCountDisplay: reservedCountDisplay,
                  ),
                )
                : _sessionBlockContainer(
                  session,
                  date,
                  sessionHeightPx,
                  blockStyle,
                  eligibility,
                  isBookingWeekOpened,
                  canTapWithPastCheck,
                  isCurrentReservation,
                  isLocked,
                  isCancelling,
                  totalSeats,
                  reservedCount,
                  remainingSeats,
                  isPastSession,
                  canTap,
                  adminSelectNewSlotLockFilled:
                      _usage == CompactCalendarUsage.adminSelectNewSlot
                          ? !canTapWithPastCheck
                          : null,
                  isAdminSelectNewSlot:
                      _usage == CompactCalendarUsage.adminSelectNewSlot,
                  reservedCountDisplay: reservedCountDisplay,
                )),
      ),
    );
  }

  Widget _sessionBlockContainer(
    CourseSession session,
    DateTime date,
    double sessionHeightPx,
    SessionBlockStyle blockStyle,
    ReservationEligibility eligibility,
    bool isBookingWeekOpened,
    bool canTapWithPastCheck,
    bool isCurrentReservation,
    bool isLocked,
    bool isCancelling,
    int totalSeats,
    int reservedCount,
    int remainingSeats,
    bool isPastSession,
    bool canTap, {
    bool? adminSelectNewSlotLockFilled,
    bool isAdminSelectNewSlot = false,
    String? reservedCountDisplay,
  }) {
    final nDisplay = reservedCountDisplay ?? '$reservedCount';
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 4,
        vertical: sessionHeightPx >= 50 ? 2 : 1,
      ),
      decoration: blockStyle.toBoxDecoration(),
      child: Stack(
        children: [
          // sessionHeightPx가 매우 작은 경우가 있어 Column이 overflow를 유발할 수 있음.
          if (sessionHeightPx >= 14)
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // adminSelectNewSlot: n/m만 표시
                  if (isAdminSelectNewSlot)
                    Text(
                      '$nDisplay / $totalSeats',
                      style: TextStyle(
                        color: blockStyle.textColor,
                        fontSize:
                            sessionHeightPx >= 60
                                ? 18
                                : (sessionHeightPx >= 40 ? 20 : 18),
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  else ...[
                    if (widget.hideCourseSelector)
                      Text(
                        _selectedCourse!.name,
                        style: TextStyle(
                          color: blockStyle.textColor,
                          fontSize:
                              sessionHeightPx >= 60
                                  ? 18
                                  : (sessionHeightPx >= 40 ? 14 : 12),
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    // 홈 화면일 때: 현재신청/정원을 크게 표시 (예약이 아직 안 열린 경우 lock 아이콘 표시)
                    if (!widget.hideCourseSelector) ...[
                      if (eligibility.reason ==
                              ReservationLockReason.notOpenedYet &&
                          !isBookingWeekOpened)
                        SvgPicture.asset(
                          'assets/icons/lock.svg',
                          width:
                              sessionHeightPx >= 60
                                  ? 24
                                  : (sessionHeightPx >= 40 ? 20 : 16),
                          height:
                              sessionHeightPx >= 60
                                  ? 24
                                  : (sessionHeightPx >= 40 ? 20 : 16),
                          colorFilter: ColorFilter.mode(
                            blockStyle.iconColor,
                            BlendMode.srcIn,
                          ),
                        )
                      else
                        Text(
                          '$nDisplay / $totalSeats',
                          style: TextStyle(
                            color: blockStyle.textColor,
                            fontSize:
                                sessionHeightPx >= 60
                                    ? 18
                                    : (sessionHeightPx >= 40 ? 20 : 18),
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ],
                  // 시간 (높이가 충분할 때만 표시, 줄바꿈) - adminSelectNewSlot에서는 숨김
                  if (sessionHeightPx >= 70 && !isAdminSelectNewSlot) ...[
                    SizedBox(height: sessionHeightPx >= 80 ? 4 : 3),
                    Text(
                      '${session.startTime}\n- ${session.endTime}',
                      style: TextStyle(
                        color: blockStyle.iconColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        height: 1.2,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  // 남은 자리 (홈 화면이 아닐 때만, 높이가 충분할 때만 표시, courseDetailView/adminSelectNewSlot에서는 숨김)
                  if (widget.hideCourseSelector &&
                      sessionHeightPx >= 90 &&
                      _usage != CompactCalendarUsage.courseDetailView &&
                      !isAdminSelectNewSlot) ...[
                    SizedBox(height: sessionHeightPx >= 100 ? 3 : 2),
                    Text(
                      '$remainingSeats / $totalSeats',
                      style: TextStyle(
                        color: blockStyle.iconColor,
                        fontSize: sessionHeightPx >= 110 ? 14 : 12,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          // 자물쇠 아이콘 표시 조건:
          // adminSelectNewSlot: 이동 불가일 때만 채운 자물쇠 표시 (이동 가능은 아이콘 없음)
          // 그 외: 탭 불가 && 현재 예약 아님 && 잠김 && 주차 미오픈
          if (adminSelectNewSlotLockFilled == true)
            Positioned(
              top: 0,
              right: 0,
              child: Icon(
                Icons.lock_rounded,
                size: sessionHeightPx >= 60 ? 18 : 14,
                color: blockStyle.iconColor,
              ),
            )
          else if (adminSelectNewSlotLockFilled == null &&
              !canTapWithPastCheck &&
              !isCurrentReservation &&
              isLocked &&
              !isBookingWeekOpened)
            Positioned(
              top: 0,
              right: 0,
              child: Icon(
                Icons.lock_rounded,
                size: sessionHeightPx >= 60 ? 18 : 14,
                color: blockStyle.iconColor,
              ),
            ),
          if (!canTap &&
              !isCurrentReservation &&
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
                  color: blockStyle.iconColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          // 취소 중인 세션에 로딩 스피너 표시
          if (isCancelling)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: SizedBox(
                    width: sessionHeightPx >= 60 ? 24 : 20,
                    height: sessionHeightPx >= 60 ? 24 : 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // 합쳐진 긴 공백(… 슬롯) 내부에 미세 눈금선을 그려 “간격이 있다”는 느낌을 주기
  // (slotTop 위치에서 바로 그리면 겹치므로, 내부에서는 위에서부터 일정 비율만큼 내려서 표시)
  List<Widget> _buildMergedGapInnerTicks({required double slotHeight}) {
    final count = _mergedGapInnerTickCount.clamp(0, 6);
    if (count == 0) return const <Widget>[];
    if (slotHeight < 24) return const <Widget>[]; // 너무 작으면 생략

    // Column 안에서 “스페이서 + 라인”만으로 간단히 구성 (위치 = 비율)
    final children = <Widget>[];
    double lastY = 0.0;
    for (int i = 1; i <= count; i++) {
      final frac = i / (count + 1);
      final y = (slotHeight * frac).clamp(0.0, slotHeight);
      final gap = (y - lastY).clamp(0.0, double.infinity);
      if (gap > 0) children.add(SizedBox(height: gap));
      children.add(
        Container(height: 0.5, color: AppColors.borderLight.withOpacity(0.12)),
      );
      lastY = y;
    }
    return children;
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
  final List<_TimeSlot> slots;
  final List<double> slotHeights; // 각 시간 슬롯의 높이
  final List<double> slotTops; // prefix sum (0 포함, 마지막이 totalHeight)
  final int rangeStartMinutes;
  final int rangeEndMinutes;
  final int initialJumpMinute;

  const _SlotLayout({
    required this.slots,
    required this.slotHeights,
    required this.slotTops,
    required this.rangeStartMinutes,
    required this.rangeEndMinutes,
    required this.initialJumpMinute,
  });

  int slotIndexForMinute(int minute) {
    if (slots.isEmpty) return -1;
    final m = minute.clamp(rangeStartMinutes, rangeEndMinutes);
    for (int i = 0; i < slots.length; i++) {
      final s = slots[i];
      if (m >= s.startMinute && m < s.endMinute) return i;
    }
    // rangeEndMinutes는 마지막 end와 같을 수 있으므로 끝이면 마지막 슬롯로
    return slots.length - 1;
  }

  double yForMinute(int minute) {
    if (slots.isEmpty) return 0.0;
    final m = minute.clamp(rangeStartMinutes, rangeEndMinutes);
    final idx = slotIndexForMinute(m);
    if (idx < 0 || idx >= slots.length) return 0.0;
    final s = slots[idx];
    final duration = (s.endMinute - s.startMinute).clamp(1, 24 * 60);
    final within = (m - s.startMinute).clamp(0, duration);
    final ppm = slotHeights[idx] / duration;
    return slotTops[idx] + (within * ppm);
  }
}

class _TimeSlot {
  final int startMinute;
  final int endMinute;
  final String label; // 시간 레이블 또는 '…'(긴 공백)
  final bool isActive;
  final bool isMergedGap;

  const _TimeSlot({
    required this.startMinute,
    required this.endMinute,
    required this.label,
    required this.isActive,
    required this.isMergedGap,
  });
}

// 예약 세션 정보 (일정보기 모드용)
class _ReservationSessionInfo {
  final Course course;
  final CourseSession session;
  final SessionReservation reservation;
  final DateTime date;

  const _ReservationSessionInfo({
    required this.course,
    required this.session,
    required this.reservation,
    required this.date,
  });
}
