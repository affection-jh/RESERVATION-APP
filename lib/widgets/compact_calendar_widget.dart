import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:reservation/utils/snackbar_util.dart';
import '../models/course.dart';
import '../models/reservation.dart';
import '../models/session_reservation.dart';
import '../models/course_enrollment.dart';
import '../models/course_override.dart';
import '../policies/course_policy.dart';
import '../policies/reservation_policy_engine.dart';
import '../services/firestore_service.dart';
import '../utils/timezone_utils.dart';
import '../theme/app_colors.dart';
import '../utils/storage_service.dart';
import '../providers/place_provider.dart';
import '../providers/reservation_provider.dart';
import '../providers/course_provider.dart';
import 'package:provider/provider.dart';
import 'session_manage_bottom_sheet.dart';
import '../widgets/common_dialog.dart';

/// CompactCalendarWidget 사용 목적(모드)
///
/// - adminNavigate: 관리자 홈 등에서 "조회/이동" 목적. 잠김/만석/과거여도 **탭은 가능**해야 함.
/// - adminSelectNewSlot: 관리자 예약 변경에서 "새 슬롯 선택" 목적. **과거/만석은 선택 불가**.
/// - userWeeklyReservationsView: 마이페이지 "내 예약(이번주) 보기" 목적(기본적으로 보기+탭 가능).
/// - courseDetailView: 코스 상세 화면용. 내부 스크롤 불가, 남은자리 표시 숨김.
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
  final List<Reservation>? userReservations; // 사용자의 예약 리스트 (일정보기 모드용)
  final Map<String, dynamic>? highlightReservation; // 강조할 예약 정보
  final Color? backgroundColor; // 배경색 (기본값: AppColors.backgroundWhite)
  final bool adminSelectionMode; // 관리자 선택 모드(잠긴 세션도 선택 가능)
  final Map<String, CourseEnrollment>? enrollmentsByCourseId; // 유저 등록 정보(코스별)
  final CompactCalendarUsage? usage; // 신규: 사용 목적(모드) - 명시적으로 상태/탭 규칙 분리

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
  StreamSubscription<List<SessionReservation>>? _sessionReservationSub;
  final Map<String, SessionReservation> _sessionReservationsByKey = {};
  StreamSubscription<Set<String>>? _bookingWeekOpensSub;
  Set<String> _openedWeekStartDates = {}; // 미리 열린 주차의 weekStartDate 집합
  StreamSubscription<Map<String, int>>? _capacityOverridesSub;
  Map<String, int> _capacityOverridesByKey = {}; // "sessionId_date" -> capacity

  // 비정기 일정 캐시 (날짜별)
  final Map<String, List<CourseOverride>> _overridesByDate = {};
  // 현재 주차 추적 (주차 변경 감지용)
  String? _currentWeekStartDate;
  // 동일한 (placeId|courseId|weekStartDate)로 중복 재구독/재로딩을 막기 위한 키
  String? _weekSubscriptionKey;
  // 현재 구독 중인 코스 ID (코스 변경 감지용)
  String? _subscribedCourseId;
  // 취소 중인 세션 추적 (로딩 스피너 표시용)
  final Set<String> _cancellingSessions = {}; // "date|dayOfWeek|startTime" 형식
  // postFrameCallback 중복 등록 방지
  bool _pendingOverrideUpdate = false;
  // 마지막으로 확인한 override 데이터 해시 (실제 변경 감지용)
  int? _lastOverridesHash;
  // 코스 변경 중 로딩 상태
  bool _isLoadingCourse = false;
  // 주차 변경 중 로딩 상태 (admin_home_screen 모드용)
  bool _isLoadingWeek = false;
  // 마지막 선택 코스 복원 상태 (place 로드 타이밍 이슈 방지)
  bool _didRestoreLastSelectedCourse = false;
  bool _isRestoringLastSelectedCourse = false;

  // UI 상수 정의 (compact calendar용으로 조정)
  static const double _minHourSlotHeight = 60.0; // 세션이 있는 구간의 최소 한 시간당 높이 (px)
  static const double _minGapHourSlotHeight = 18.0; // 공백 구간 축소 하한 (px/h)
  static const int _mergeGapMinHours = 3; // 이 시간(시간) 이상 연속 공백은 하나로 합쳐(건너뛰기) 표시
  static const double _mergedGapSlotHeight = 22.0; // 합쳐진 긴 공백 슬롯의 기본 높이(px)
  static const double _minActiveSlotHeight =
      36.0; // 화면이 너무 작을 때도 active 슬롯이 너무 얇아지지 않도록
  static const int _mergedGapInnerTickCount =
      2; // 합쳐진 긴 공백 슬롯 내부에 그릴 미세 눈금선 개수(최대)
  static const int _edgePaddingMinutes = 30; // 00시, 23시 경계에 추가할 여백(분)
  static const double _timeColumnWidth = 35.0; // 시간대 컬럼 너비 (px)
  static const double _lineOffset = 1.0; // 가로선을 아래로 이동하는 오프셋 (px)
  static const double _sessionPadding = 2.0; // 세션 블록 좌우 패딩 (px)
  static const double _dateColumnSpacing = 0.0; // 날짜 컬럼 간 간격 (px)
  static const double _timeTextPaddingRight = 8.0; // 시간 텍스트 오른쪽 패딩 (px)
  static const int _basePaddingMinutes = 120; // 세션 위/아래 기본 여백(2시간)

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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('지나간 일정은 취소할 수 없습니다.')));
      }
      return;
    }

    final dateString = TimezoneUtils.formatDateToSeoul(date);
    final dateKey = _formatDate(date);

    // ✅ 추가된 비정기(override) 세션인지 확인: 이런 세션은 '취소 override 생성'이 아니라
    // override 문서 자체를 delete 해야 리스타트 후에도 안 남음.
    CourseOverride? addedOverride;
    final overridesForDate =
        _overridesByDate[dateKey] ?? const <CourseOverride>[];
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

    // 현재 수용인원 가져오기
    final courseId = course.id;
    final sessionId = SessionReservation.generateSessionId(
      courseId,
      session.dayOfWeek,
      session.startTime,
    );
    final sr = _sessionReservationsByKey['${sessionId}_$dateKey'];
    final overrideCap = _capacityOverridesByKey['${sessionId}_$dateKey'];
    final currentCapacity =
        overrideCap ?? sr?.capacity ?? session.getCapacityForDate(date);
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
          SnackbarUtil.showError(context, '플레이스를 찾을 수 없습니다.');
          return;
        }
        await _firestoreService.setCapacityOverride(
          placeId: placeId,
          sessionId: sessionId,
          date: dateKey,
          capacity: newCapacity,
        );
        // UI 즉시 업데이트
        if (mounted) {
          final key = '${sessionId}_$dateKey';
          setState(() {
            // _capacityOverridesByKey 업데이트
            _capacityOverridesByKey = {
              ..._capacityOverridesByKey,
              key: newCapacity,
            };
            // _sessionReservationsByKey도 함께 업데이트
            final existingSr = _sessionReservationsByKey[key];
            if (existingSr != null) {
              _sessionReservationsByKey[key] = existingSr.copyWith(
                capacity: newCapacity,
                lastUpdated: TimezoneUtils.getSeoulDateTime(),
              );
            }
          });
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
      message:
          addedOverride != null
              ? '이 세션을 삭제하시겠습니까?\n\n삭제된 세션의 모든 예약이 취소됩니다.'
              : '이 세션을 취소하시겠습니까?\n\n취소된 세션의 모든 예약이 취소됩니다.',
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

      final weekStart = DateTime(
        date.year,
        date.month,
        date.day,
      ).subtract(Duration(days: date.weekday - DateTime.monday));
      final weekStartDate = TimezoneUtils.formatDateToSeoul(weekStart);

      final shouldSendNotification = result['sendNotification'] ?? true;

      final Map<String, dynamic> upsertResult =
          addedOverride != null
              ? await _firestoreService.upsertCourseOverride(
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
              : await _firestoreService.upsertCourseOverride(
                placeId: placeId,
                courseId: course.id,
                date: dateString,
                dayOfWeek: session.dayOfWeek,
                startTime: session.startTime,
                weekStartDate: weekStartDate,
                isCancelled: true,
                action: 'create',
                sendNotification: shouldSendNotification,
              );

      if (mounted) {
        setState(() {
          _cancellingSessions.remove(cancellingKey);

          // ✅ UI 즉시 반영 (스트림/Provider 반영 지연 방지)
          final list = List<CourseOverride>.from(
            _overridesByDate[dateKey] ?? const <CourseOverride>[],
          );

          if (addedOverride != null) {
            // 추가 override 세션 삭제 → override 문서 제거
            list.removeWhere((o) => o.id == addedOverride!.id);
            _overridesByDate[dateKey] = list;
          } else {
            // 정기 세션 취소 → cancel override 추가
            final overrideId =
                (upsertResult['overrideId'] as String?)?.trim() ?? '';
            final effectiveOverrideId =
                overrideId.isNotEmpty
                    ? overrideId
                    : '${course.id}_${dateKey}_${session.startTime}_cancel';

            list.removeWhere(
              (o) =>
                  o.courseId == course.id &&
                  o.date == dateKey &&
                  o.dayOfWeek == session.dayOfWeek &&
                  o.startTime == session.startTime &&
                  o.isCancelled == true,
            );

            list.add(
              CourseOverride(
                id: effectiveOverrideId,
                courseId: course.id,
                placeId: placeId,
                date: dateKey,
                dayOfWeek: session.dayOfWeek,
                startTime: session.startTime,
                isCancelled: true,
                weekStartDate: weekStartDate,
                createdAt: DateTime.now(),
                updatedAt: DateTime.now(),
              ),
            );
            _overridesByDate[dateKey] = list;
          }
        });
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('오류가 발생했습니다: $e')));
      }
    }
  }

  @override
  void initState() {
    super.initState();
    // 저장된 마지막 선택 코스 복원
    _restoreLastSelectedCourse();

    // 강조 애니메이션용 컨트롤러
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
    if (placeId == null) return;

    final now = TimezoneUtils.getSeoulDateTime();
    final weekStart = _startOfWeekMonday(
      now,
    ).add(Duration(days: 7 * widget.weekOffset));
    final weekStartDate = TimezoneUtils.formatDateToSeoul(weekStart);

    final nextKey = '$placeId|${course.id}|$weekStartDate';
    if (_weekSubscriptionKey == nextKey) return;

    // 코스가 변경되었는지 확인
    final courseChanged =
        _subscribedCourseId != null && _subscribedCourseId != course.id;
    if (courseChanged) {
      // 코스 변경 시 이전 코스의 모든 캐시 초기화
      _overridesByDate.clear();
      _sessionReservationsByKey.clear();
      _lastOverridesHash = null;
      _currentWeekStartDate = null;
      _pendingOverrideUpdate = false;
    }

    _weekSubscriptionKey = nextKey;
    _subscribedCourseId = course.id;

    if (resetViewport) {
      _didInitialJump = false;
      _currentWeekStartDate = weekStartDate;
    }

    _subscribeWeekSessionReservations();
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
    final weekStart = _startOfWeekMonday(
      now,
    ).add(Duration(days: 7 * widget.weekOffset));
    final weekStartDate = TimezoneUtils.formatDateToSeoul(weekStart);

    // CourseProvider에서 비정기 일정 구독
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    courseProvider.subscribeToOverrides(placeId, [weekStartDate]);

    // 주차가 변경되었는지 확인
    final weekChanged = _currentWeekStartDate != weekStartDate;
    if (weekChanged) {
      _currentWeekStartDate = weekStartDate;
      _didInitialJump = false; // 주차 변경 시 뷰포트 리셋
    }

    try {
      // 초기 로드 (이후에는 CourseProvider 스트림으로 자동 업데이트)
      await _loadOverridesForWeek(placeId, weekStartDate, course.id);
    } finally {
      // admin_home_screen 모드에서 로딩 종료 (성공/실패 관계없이)
      if (!widget.hideCourseSelector && _isLoadingWeek) {
        if (mounted) {
          setState(() {
            _isLoadingWeek = false;
          });
        }
      }
    }
  }

  /// bookingWeekOpens 구독 (미리 열린 주차 확인)
  void _subscribeBookingWeekOpens() {
    _bookingWeekOpensSub?.cancel();

    final course = _selectedCourse;
    if (course == null) return;
    if (widget.weeklyViewMode) return;

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
            },
            onError: (e) {
              debugPrint(
                '[CompactCalendarWidget] bookingWeekOpens stream error: $e',
              );
              if (!mounted) return;
              setState(() {
                _openedWeekStartDates.clear();
              });
            },
          );
    } catch (e) {
      debugPrint(
        '[CompactCalendarWidget] bookingWeekOpens subscribe error: $e',
      );
    }
  }

  /// 특정 주의 비정기 일정 로드 (초기 로드용)
  Future<void> _loadOverridesForWeek(
    String placeId,
    String weekStartDate,
    String courseId,
  ) async {
    try {
      final overrides = await _firestoreService.getCourseOverrides(
        placeId: placeId,
        courseId: courseId,
        weekStartDate: weekStartDate,
      );

      if (!mounted) return;

      // 새 데이터를 임시 변수에 저장 (UI 업데이트는 한 번에)
      final newOverridesByDate = <String, List<CourseOverride>>{};
      for (final override in overrides) {
        if (!newOverridesByDate.containsKey(override.date)) {
          newOverridesByDate[override.date] = [];
        }
        newOverridesByDate[override.date]!.add(override);
      }

      // 데이터가 실제로 변경되었는지 확인
      final hasChanges =
          newOverridesByDate.length != _overridesByDate.length ||
          newOverridesByDate.entries.any((entry) {
            final existing = _overridesByDate[entry.key] ?? [];
            if (existing.length != entry.value.length) return true;
            for (final override in entry.value) {
              if (!existing.any((e) => e.id == override.id)) return true;
            }
            return false;
          });

      if (hasChanges && mounted) {
        setState(() {
          // 날짜별로 그룹화 (한 번에 업데이트하여 UI 흔들림 방지)
          _overridesByDate.clear();
          _overridesByDate.addAll(newOverridesByDate);
          _currentWeekStartDate = weekStartDate;
        });
      }
    } catch (e) {
      debugPrint('[CompactCalendarWidget] Error loading overrides: $e');
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
    final course = _selectedCourse;
    final placeId =
        Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id;
    if (course == null || placeId == null) return;

    try {
      final policy = await _firestoreService.getCoursePolicy(
        courseId: course.id,
        placeId: placeId,
      );
      if (!mounted) return;
      setState(() {
        _coursePolicy = policy;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _coursePolicy = CoursePolicy.defaultFor(
          courseId: course.id,
          placeId: placeId,
        );
      });
    }
  }

  void _subscribeWeekSessionReservations() {
    _sessionReservationSub?.cancel();

    final course = _selectedCourse;
    if (course == null) return;
    if (widget.weeklyViewMode) return;

    final placeId =
        Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id;

    final now = TimezoneUtils.getSeoulDateTime();
    final weekStart = _startOfWeekMonday(
      now,
    ).add(Duration(days: 7 * widget.weekOffset));
    final startDate = DateTime(weekStart.year, weekStart.month, weekStart.day);
    final endDate = startDate.add(const Duration(days: 6));

    _loadCoursePolicy();

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
              // ✅ 스트림이 source of truth.
              // 다른 화면(SessionDetailScreen 등)에서 변경된 capacity가
              // 여기로 돌아왔을 때 즉시 반영되도록 스트림 값을 우선한다.
              // (이 위젯 내에서의 즉시 반영은 onCapacityChanged에서 setState로 이미 처리)
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
            // 인덱스 미배포 등으로 스트림이 죽으면
            // 다른 화면(SessionDetailScreen)에서의 변경이 여기로 동기화되지 않는다.
            debugPrint(
              '[CompactCalendarWidget] dateCapacityOverrides stream error: $e',
            );
            // 에러는 조용히 로그만 남김 (인덱스는 이미 정의되어 있으므로)
          },
        );

    _sessionReservationSub = _firestoreService
        .watchCourseSessionReservations(
          courseId: course.id,
          placeId: placeId,
          startDate: startDate,
          endDate: endDate,
        )
        .listen(
          (list) {
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
            }
            if (!mounted) return;
            setState(() {
              _sessionReservationsByKey
                ..clear()
                ..addAll(next);
            });
          },
          onError: (_) {
            // 권한 문제 등으로 스트림이 실패해도 앱이 크래시 나지 않도록 방어
            // (여기서 즉시 clear하면 UI가 "없다→있다"로 튀는 경우가 있어, 일단 유지)
          },
        );
  }

  @override
  void didUpdateWidget(CompactCalendarWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 주 변경 시(이번주/다음주/다다음주) 예약 현황/정책 재구독
    if (widget.weekOffset != oldWidget.weekOffset) {
      // admin_home_screen 모드에서만 로딩 표시
      if (!widget.hideCourseSelector) {
        setState(() {
          _isLoadingWeek = true;
        });
      }
      _ensureWeekSubscriptions(resetViewport: true);
    }
    // highlightReservation이 새로 추가되었을 때 애니메이션 시작
    if (widget.highlightReservation != null) {
      // null에서 값으로 변경되었거나, 값이 변경되었을 때 애니메이션 시작
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
      // highlightReservation이 null로 변경되었을 때 애니메이션 정지
      _shakeController?.stop();
    }
    // 코스 목록이 변경되었을 때 처리
    if (widget.courses != oldWidget.courses) {
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
  void _updateOverridesFromProvider() {
    if (widget.weeklyViewMode || _selectedCourse == null) return;

    final now = TimezoneUtils.getSeoulDateTime();
    final currentWeekStart = _startOfWeekMonday(
      now,
    ).add(Duration(days: 7 * widget.weekOffset));
    final weekStartDate = TimezoneUtils.formatDateToSeoul(currentWeekStart);

    // 현재 주차가 아니면 업데이트하지 않음 (주 변경 시에는 didUpdateWidget에서 처리)
    if (_currentWeekStartDate != null &&
        _currentWeekStartDate != weekStartDate) {
      return;
    }

    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final weekOverrides =
        courseProvider
            .getOverridesForWeek(weekStartDate)
            .where((o) => o.courseId == _selectedCourse!.id)
            .toList();

    // _overridesByDate 업데이트 (날짜별로 그룹화)
    final newOverridesByDate = <String, List<CourseOverride>>{};
    for (final override in weekOverrides) {
      if (!newOverridesByDate.containsKey(override.date)) {
        newOverridesByDate[override.date] = [];
      }
      newOverridesByDate[override.date]!.add(override);
    }

    // 데이터가 변경되었는지 확인 (더 엄격한 체크: 해시 기반)
    final currentHash = Object.hashAll(
      newOverridesByDate.entries.map(
        (e) => Object.hashAll(
          e.value.map((o) => Object.hash(o.id, o.date, o.isCancelled)),
        ),
      ),
    );

    // 해시가 같으면 실제 변경 없음 → setState 호출 안 함
    if (_lastOverridesHash == currentHash) {
      return;
    }
    _lastOverridesHash = currentHash;

    // 실제 변경사항이 있으면 업데이트 (즉시 setState, postFrameCallback 제거)
    if (mounted) {
      setState(() {
        _overridesByDate.clear();
        _overridesByDate.addAll(newOverridesByDate);
      });
    }
  }

  @override
  void dispose() {
    _sessionReservationSub?.cancel();
    _capacityOverridesSub?.cancel();
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

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin을 위해 필요
    // ReservationProvider를 listen하여 예약 변경사항 자동 반영
    Provider.of<ReservationProvider>(context);
    // CourseProvider를 listen하여 비정기 일정 변경사항 자동 반영
    // 주의: build 메서드에서는 직접 setState를 호출하지 않고, postFrameCallback으로 지연
    Provider.of<CourseProvider>(context);
    // 비정기 일정 업데이트 (중복 등록 방지 + 실제 변경 감지)
    if (!widget.weeklyViewMode &&
        _selectedCourse != null &&
        !_pendingOverrideUpdate) {
      _pendingOverrideUpdate = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _pendingOverrideUpdate = false;
        if (mounted) {
          _updateOverridesFromProvider();
        }
      });
    }
    // 일정보기 모드인 경우
    if (widget.weeklyViewMode) {
      if (widget.userReservations == null || widget.userReservations!.isEmpty) {
        // 예약이 없을 때는 높이를 100px로 제한
        return SizedBox(height: widget.height, child: _buildEmptyState());
      }

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
              final dateString = _formatDate(date);
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
            // 요일 헤더: 예약이 없는 주차면 헤더를 숨기고 빈 상태만 보여줌
            if (datesToRender.isNotEmpty) _buildDayHeaders(datesToRender),
            // 캘린더 그리드 / 빈 상태
            Expanded(
              child:
                  datesToRender.isEmpty
                      ? _buildEmptyState()
                      : LayoutBuilder(
                        builder: (context, constraints) {
                          return _buildCalendarGrid(
                            datesToRender,
                            viewportHeight: constraints.maxHeight,
                          );
                        },
                      ),
            ),
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

    // 토일(6, 7)에 세션이 없으면 필터링
    final hasSaturdaySession = selectedCourseSessions.any(
      (s) => s.dayOfWeek == 6,
    );
    final hasSundaySession = selectedCourseSessions.any(
      (s) => s.dayOfWeek == 7,
    );

    final weekDates =
        allWeekDates.where((date) {
          // 토요일이고 세션이 없으면 제외
          if (date.weekday == 6 && !hasSaturdaySession) return false;
          // 일요일이고 세션이 없으면 제외
          if (date.weekday == 7 && !hasSundaySession) return false;
          return true;
        }).toList();

    return SizedBox(
      height: widget.height,
      child: Column(
        children: [
          // 코스 선택 드롭다운
          if (!widget.hideCourseSelector) _buildCourseSelector(),
          // 로딩 중이면 스피너 표시 (코스 변경 또는 주차 변경)
          if (_isLoadingCourse || _isLoadingWeek)
            Expanded(
              child: Center(
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(
                    AppColors.primaryGreen,
                  ),
                ),
              ),
            )
          else ...[
            // 요일 헤더
            _buildDayHeaders(weekDates),
            // 캘린더 그리드
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return _buildCalendarGrid(
                    weekDates,
                    viewportHeight: constraints.maxHeight,
                  );
                },
              ),
            ),
          ],
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
                // 코스 변경 시 즉시 캐시 초기화 (UI 깜빡임 방지)
                if (_selectedCourse?.id != newCourse.id) {
                  _overridesByDate.clear();
                  _sessionReservationsByKey.clear();
                  _lastOverridesHash = null;
                  _subscribedCourseId = null;
                  _weekSubscriptionKey = null;
                  _pendingOverrideUpdate = false;
                }

                setState(() {
                  _selectedCourse = newCourse;
                  _isDropdownOpen = false;
                  _didInitialJump = false; // 코스 변경 시 초기 점프 리셋
                  _isLoadingCourse = true; // 로딩 시작
                });

                // 콜백 호출
                widget.onCourseSelected?.call(newCourse);

                // 데이터 로드 (약간의 지연을 주어 UI가 먼저 업데이트되도록)
                await Future.delayed(const Duration(milliseconds: 50));
                _subscribeWeekSessionReservations();
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

  // 요일 헤더
  Widget _buildDayHeaders(List<DateTime> dates) {
    const dayNames = ['', '월', '화', '수', '목', '금', '토', '일'];

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: widget.backgroundColor ?? AppColors.backgroundWhite,
        border: Border(
          bottom: BorderSide(color: AppColors.borderLight, width: 1),
        ),
      ),
      child: Row(
        children: [
          // 시간대 컬럼 (빈 공간)
          SizedBox(width: _timeColumnWidth, child: Container()),
          // 각 날짜 헤더
          ...dates.map((date) {
            return Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      dayNames[date.weekday],
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
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
      color: widget.backgroundColor ?? AppColors.backgroundWhite,
      child: SingleChildScrollView(
        controller: _scrollController,
        physics:
            (_usage == CompactCalendarUsage.courseDetailView ||
                    _usage == CompactCalendarUsage.adminNavigate)
                ? const NeverScrollableScrollPhysics()
                : null, // courseDetailView 및 adminNavigate 모드에서는 스크롤 비활성화
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 시간대 컬럼
            Container(
              width: _timeColumnWidth,
              color: widget.backgroundColor ?? AppColors.backgroundWhite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children:
                    layout.slots.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final slot = entry.value;
                      final label = slot.label; // "11" or "…"
                      final isActiveSlot = slot.isActive;
                      return Container(
                        height: layout.slotHeights[idx],
                        alignment: Alignment.topRight,
                        padding: EdgeInsets.only(
                          right: _timeTextPaddingRight,
                          top: 0,
                        ),
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize:
                                label == '…' ? 14 : (isActiveSlot ? 16 : 13),
                            fontWeight:
                                isActiveSlot
                                    ? FontWeight.w600
                                    : FontWeight.w400,
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
                    slots: layout.slots,
                    rangeStartMinutes: smart.rangeStartMinutes,
                    slotTops: layout.slotTops,
                    slotHeights: layout.slotHeights,
                    yForMinute: layout.yForMinute,
                    slotIndexForMinute: layout.slotIndexForMinute,
                  ),
                ),
              );
            }).toList(),
          ],
        ),
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
          hourSlotHeight: _minHourSlotHeight,
        );
      }

      // 예약된 세션들의 시간 범위 계산
      // - 정기 세션이 없으면 override(비정기) 확인
      // - 그래도 없으면 예약 정보로 fallback(기본 2시간)
      final weekStart = _startOfWeekMonday(dates.first);
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
            final dateString = _formatDate(dateOnly);

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
              final startMinutes = _parseTimeToMinutes(startTime);
              final endMinutes = startMinutes + 120; // 기본 2시간
              endTime =
                  '${(endMinutes ~/ 60).toString().padLeft(2, '0')}:${(endMinutes % 60).toString().padLeft(2, '0')}';
            }
          }

          final startMins = _parseTimeToMinutes(startTime);
          final endMins = _parseTimeToMinutes(endTime);
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
          hourSlotHeight: _minHourSlotHeight,
        );
      }

      final minStart = reservationTimes.reduce((a, b) => a < b ? a : b);
      final maxEnd = reservationTimes.reduce((a, b) => a > b ? a : b);

      final optimalHourSlotHeight =
          maxSessionDuration >= 180
              ? 45.0
              : maxSessionDuration >= 120
              ? 50.0
              : _minHourSlotHeight;

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
        hourSlotHeight: _minHourSlotHeight,
      );
    }

    // 해당 컬럼(날짜들)에서 보이는 요일들의 세션만 대상으로 범위 계산
    final weekdays = dates.map((d) => d.weekday).toSet();
    final regularSessions = _selectedCourse!.sessions.where(
      (s) => weekdays.contains(s.dayOfWeek),
    );

    // 비정기 일정도 포함 (뷰포트 범위 계산에 필요)
    final weekStart = _startOfWeekMonday(dates.first);
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
        hourSlotHeight: _minHourSlotHeight,
      );
    }

    final starts = allSessions.map((s) => _parseTimeToMinutes(s.startTime));
    final ends = allSessions.map((s) => _parseTimeToMinutes(s.endTime));
    final minStart = starts.reduce((a, b) => a < b ? a : b);
    final maxEnd = ends.reduce((a, b) => a > b ? a : b);

    // 세션 지속 시간을 기반으로 동적 최적 높이 계산
    double maxSessionDuration = 0;
    for (final session in allSessions) {
      final start = _parseTimeToMinutes(session.startTime);
      final end = _parseTimeToMinutes(session.endTime);
      if (end > start) {
        final duration = end - start;
        if (duration > maxSessionDuration) {
          maxSessionDuration = duration.toDouble();
        }
      }
    }

    // 세션 블록이 잘 보이기 위한 최적 높이 계산
    // 세션이 길면 시간 간격을 줄여서 전체가 보이도록, 짧으면 시간 간격을 늘려서 한눈에 보이도록
    final optimalHourSlotHeight =
        maxSessionDuration >= 180
            ? 45.0 // 3시간 이상 세션: 시간 간격을 줄여서 전체가 보이도록
            : maxSessionDuration >= 120
            ? 50.0 // 2-3시간 세션: 중간 높이
            : _minHourSlotHeight; // 2시간 미만: 기본 높이 (60px)로 한눈에 보이도록

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

      final weekStart = _startOfWeekMonday(dates.first);
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
            final dateString = _formatDate(dateOnly);

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
              final startMinutes = _parseTimeToMinutes(startTime);
              final endMinutes = startMinutes + 120; // 기본 2시간
              endTime =
                  '${(endMinutes ~/ 60).toString().padLeft(2, '0')}:${(endMinutes % 60).toString().padLeft(2, '0')}';
            }
          }

          activeRanges.add([
            _parseTimeToMinutes(startTime),
            _parseTimeToMinutes(endTime),
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

      // 긴 공백 합치기
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

      // 슬롯 높이 설정
      final baseSlotHeight = smart.hourSlotHeight;
      final slotHeights = List<double>.filled(slots.length, baseSlotHeight);
      for (int idx = 0; idx < slots.length; idx++) {
        final s = slots[idx];
        if (s.isActive) {
          slotHeights[idx] = baseSlotHeight;
        } else if (s.isMergedGap) {
          slotHeights[idx] = _mergedGapSlotHeight;
        } else {
          slotHeights[idx] = _minGapHourSlotHeight;
        }
      }

      // viewportHeight에 맞춰 동적 조절 (기존 로직과 동일)
      double currentTotal = slotHeights.fold<double>(0.0, (s, h) => s + h);

      if (currentTotal > viewportHeight) {
        for (int idx = 0; idx < slots.length; idx++) {
          if (currentTotal <= viewportHeight) break;
          if (slots[idx].isMergedGap && slotHeights[idx] > 12.0) {
            final reducible = slotHeights[idx] - 12.0;
            final need = currentTotal - viewportHeight;
            final reduce = reducible < need ? reducible : need;
            slotHeights[idx] -= reduce;
            currentTotal -= reduce;
          }
        }

        for (int idx = 0; idx < slots.length; idx++) {
          if (currentTotal <= viewportHeight) break;
          if (!slots[idx].isActive && !slots[idx].isMergedGap) {
            if (slotHeights[idx] > _minGapHourSlotHeight) {
              final reducible = slotHeights[idx] - _minGapHourSlotHeight;
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
            totalReducible += (slotHeights[idx] - _minActiveSlotHeight).clamp(
              0.0,
              double.infinity,
            );
          }

          if (activeIndices.isNotEmpty && totalReducible > 0) {
            final need = currentTotal - viewportHeight;
            final ratio = (need / totalReducible).clamp(0.0, 1.0);
            double reduced = 0.0;
            for (final idx in activeIndices) {
              final reducible = (slotHeights[idx] - _minActiveSlotHeight).clamp(
                0.0,
                double.infinity,
              );
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

    // 비정기 일정 추가 (CourseProvider의 실시간 업데이트 사용)
    final weekStart = _startOfWeekMonday(dates.first);
    final weekStartDate = TimezoneUtils.formatDateToSeoul(weekStart);
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    // _overridesByDate를 우선 사용 (더 최신 데이터), 없으면 CourseProvider 사용
    final weekOverrides = <CourseOverride>[];
    for (final date in dates) {
      final dateString = _formatDate(date);
      final dayOverrides = _overridesByDate[dateString] ?? [];
      weekOverrides.addAll(
        dayOverrides.where(
          (o) => o.courseId == _selectedCourse?.id && !o.isCancelled,
        ),
      );
    }
    // _overridesByDate에 없는 경우에만 CourseProvider 사용 (fallback)
    if (weekOverrides.isEmpty) {
      weekOverrides.addAll(
        courseProvider
            .getOverridesForWeek(weekStartDate)
            .where((o) => o.courseId == _selectedCourse?.id && !o.isCancelled),
      );
    }

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
      final start = _parseTimeToMinutes(s.startTime);
      final end = _parseTimeToMinutes(s.endTime);
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

    // 3) 기본 슬롯 높이 설정
    final baseSlotHeight = smart.hourSlotHeight;
    final slotHeights = List<double>.filled(slots.length, baseSlotHeight);
    for (int idx = 0; idx < slots.length; idx++) {
      final s = slots[idx];
      if (s.isActive) {
        slotHeights[idx] = baseSlotHeight;
      } else if (s.isMergedGap) {
        slotHeights[idx] = _mergedGapSlotHeight;
      } else {
        slotHeights[idx] = _minGapHourSlotHeight;
      }
    }

    // 4) viewportHeight에 맞춰 동적 조절
    double currentTotal = slotHeights.fold<double>(0.0, (s, h) => s + h);

    // (a) 너무 크면: gap 먼저 더 줄이고, 그래도 크면 active도 최소까지만 줄임
    if (currentTotal > viewportHeight) {
      // merged gap: 더 압축 가능(최소 12px)
      for (int idx = 0; idx < slots.length; idx++) {
        if (currentTotal <= viewportHeight) break;
        if (slots[idx].isMergedGap && slotHeights[idx] > 12.0) {
          final reducible = slotHeights[idx] - 12.0;
          final need = currentTotal - viewportHeight;
          final reduce = reducible < need ? reducible : need;
          slotHeights[idx] -= reduce;
          currentTotal -= reduce;
        }
      }

      // 일반 gap: _minGapHourSlotHeight까지는 이미 설정되어 있지만, 혹시라도 늘어났다면 다시 줄이기
      for (int idx = 0; idx < slots.length; idx++) {
        if (currentTotal <= viewportHeight) break;
        if (!slots[idx].isActive && !slots[idx].isMergedGap) {
          if (slotHeights[idx] > _minGapHourSlotHeight) {
            final reducible = slotHeights[idx] - _minGapHourSlotHeight;
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
          totalReducible += (slotHeights[idx] - _minActiveSlotHeight).clamp(
            0.0,
            double.infinity,
          );
        }

        if (activeIndices.isNotEmpty && totalReducible > 0) {
          final need = currentTotal - viewportHeight;
          final ratio = (need / totalReducible).clamp(0.0, 1.0);
          double reduced = 0.0;
          for (final idx in activeIndices) {
            final reducible = (slotHeights[idx] - _minActiveSlotHeight).clamp(
              0.0,
              double.infinity,
            );
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
          final dateString = _formatDate(date);
          // listen: true로 변경하여 비정기 세션이 로드되면 위젯이 리빌드되도록 함
          final courseProvider = Provider.of<CourseProvider>(context);
          final weekStart = _startOfWeekMonday(date);
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
              final startMinutes = _parseTimeToMinutes(reservation.startTime);
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

        final sessionStartMinutes = _parseTimeToMinutes(session.startTime);
        if (sessionStartMinutes < rangeStartMinutes) continue;
        if (sessionStartMinutes >=
            (slots.isNotEmpty ? slots.last.endMinute : rangeStartMinutes))
          continue;

        final idx = slotIndexForMinute(sessionStartMinutes);
        if (idx < 0 || idx >= slots.length) continue;
        if (!sessionStartSlots.containsKey(idx) ||
            _parseTimeToMinutes(sessionStartSlots[idx]!.session.startTime) >
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

    // 비정기 일정 확인
    final dateString = _formatDate(date);
    final dayOverrides = _overridesByDate[dateString] ?? [];

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
      final sessionStartMinutes = _parseTimeToMinutes(session.startTime);
      // 표시 범위 밖이면 스킵
      if (sessionStartMinutes < rangeStartMinutes) continue;
      if (sessionStartMinutes >=
          (slots.isNotEmpty ? slots.last.endMinute : rangeStartMinutes))
        continue;

      final idx = slotIndexForMinute(sessionStartMinutes);
      if (idx < 0 || idx >= slots.length) continue;
      if (!sessionStartSlots.containsKey(idx) ||
          _parseTimeToMinutes(sessionStartSlots[idx]!.startTime) >
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
    final sessionStartMinutes = _parseTimeToMinutes(session.startTime);
    final sessionEndMinutes = _parseTimeToMinutes(session.endTime);

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

    // 강조할 예약인지 확인
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

    // 방문 완료된 경우 회색, 아니면 코스 색상
    final baseColor =
        isVisited ? AppColors.reservedGrey : info.course.colorValue;

    final textColor = isVisited ? AppColors.reservedTextGrey : Colors.white;
    final iconColor =
        isVisited ? AppColors.reservedIconGrey : Colors.white.withOpacity(0.9);

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
    final operationType =
        processingKey != null
            ? reservationProvider.getOperationTypeByKey(processingKey)
            : null;

    // 처리 중일 때 배경색 조정
    final blockColor = isProcessing ? baseColor.withOpacity(0.45) : baseColor;

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
                    // 위아래로 천천히 흔들리는 애니메이션 (sin 파형 사용)
                    // 2초 동안 여러 번 왔다갔다 (약 3-4번)
                    final shakeOffset =
                        math.sin(_shakeAnimation!.value * math.pi * 6) *
                        6.0 *
                        (1.0 - _shakeAnimation!.value * 0.3);

                    return Transform.translate(
                      offset: Offset(0, shakeOffset),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: sessionHeightPx >= 50 ? 2 : 1,
                        ),
                        decoration: BoxDecoration(
                          color: blockColor,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: blockColor.withOpacity(0.4),
                              blurRadius: 12,
                              spreadRadius: 2,
                              offset: const Offset(0, 4),
                            ),
                            BoxShadow(
                              color: Colors.black.withOpacity(0.2),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: child,
                      ),
                    );
                  },
                  child: Stack(
                    children: [
                      // 로딩 중이 아닐 때만 텍스트 표시
                      if (!isProcessing)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 코스 이름
                            Text(
                              info.course.name,
                              style: TextStyle(
                                color: textColor,
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
                                  color: iconColor,
                                  fontSize: sessionHeightPx >= 90 ? 16 : 14,
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
                                      iconColor,
                                    ),
                                  ),
                                ),
                                if (operationType != null) ...[
                                  SizedBox(
                                    height: sessionHeightPx >= 50 ? 8 : 6,
                                  ),
                                  Text(
                                    operationType ==
                                            ReservationOperationType.create
                                        ? '예약중'
                                        : operationType ==
                                            ReservationOperationType.cancel
                                        ? '취소중'
                                        : '변경중',
                                    style: TextStyle(
                                      color: iconColor,
                                      fontSize: sessionHeightPx >= 50 ? 18 : 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                )
                : Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: sessionHeightPx >= 50 ? 2 : 1,
                  ),
                  decoration: BoxDecoration(
                    color: blockColor,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
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
                                  color: textColor,
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
                                    color: iconColor,
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
                                        iconColor,
                                      ),
                                    ),
                                  ),
                                  if (operationType != null &&
                                      sessionHeightPx >= 28) ...[
                                    SizedBox(
                                      height: sessionHeightPx >= 50 ? 8 : 6,
                                    ),
                                    Text(
                                      operationType ==
                                              ReservationOperationType.create
                                          ? '예약중'
                                          : operationType ==
                                              ReservationOperationType.cancel
                                          ? '취소중'
                                          : '변경중',
                                      style: TextStyle(
                                        color: iconColor,
                                        fontSize:
                                            sessionHeightPx >= 50 ? 18 : 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
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
    final sessionStartMinutes = _parseTimeToMinutes(session.startTime);
    final sessionEndMinutes = _parseTimeToMinutes(session.endTime);

    // 비선형(공백 압축) 포함한 위치/높이
    final topPosition = yForMinute(sessionStartMinutes) + _lineOffset;
    final sessionHeightPx = (yForMinute(sessionEndMinutes) -
            yForMinute(sessionStartMinutes))
        .clamp(0.0, double.infinity);

    // 예약/잠금 정보 (sessionReservations + 중앙 정책 엔진 기반)
    final courseId = _selectedCourse!.id;
    final dateString = _formatDate(date);
    final sessionId = SessionReservation.generateSessionId(
      courseId,
      session.dayOfWeek,
      session.startTime,
    );
    final sr = _sessionReservationsByKey['${sessionId}_$dateString'];

    // 비정기 일정인지 확인 (추가된 세션인지)
    final dayOverrides = _overridesByDate[dateString] ?? [];
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

    // dateCapacityOverrides는 "특정 날짜"에 대한 가장 강한 오버라이드이므로
    // 정기/비정기(override) 세션 모두에서 최우선으로 적용한다.
    final dateCapacityOverride =
        _capacityOverridesByKey['${sessionId}_$dateString'];
    final totalSeats =
        dateCapacityOverride ??
        overrideCapacity ??
        sr?.capacity ??
        session.getCapacityForDate(date);
    final reservedCount = sr?.reservedCount ?? 0;
    final remainingSeats = math.max(0, totalSeats - reservedCount);

    final placeId =
        Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id ??
        '';
    final policy =
        _coursePolicy ??
        CoursePolicy.defaultFor(courseId: courseId, placeId: placeId);
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
      final weekStart = _startOfWeekMonday(date);
      final weekStartDateString = _formatDate(weekStart);
      isBookingWeekOpened = _openedWeekStartDates.contains(weekStartDateString);
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

    // "선택 가능(관리자 변경 선택)" 여부:
    // - allowAdminForceMoveWithinCourse ON: 오픈/마감/오픈전은 무시하고(서버도 허용), 과거만 차단 (꽉 찬 것은 선택 가능)
    // - OFF: 일반 예약 정책(오픈/마감 포함)을 그대로 적용 (서버에서도 강제)
    final forceMoveAllowed = policy.allowAdminForceMoveWithinCourse;
    final selectableForAdminMove =
        forceMoveAllowed
            ? (!isCurrentReservation && !isPastDate) // 꽉 찬 것도 선택 가능
            : (!isCurrentReservation && eligibility.canReserve);

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

    final baseColor =
        visuallyDisabled ? AppColors.reservedGrey : _selectedCourse!.colorValue;

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
    // adminSelectNewSlot 모드: 모든 타겟 세션(현재 예약이 아닌 모든 세션)을 연한 색으로 표시
    // 선택된 세션은 진하게 표시
    // 지나간 세션(visuallyDisabled)은 항상 진하게 표시 (회색이 확실히 보이도록)
    // 일반 모드에서는 기본적으로 진하게 표시
    final opacity = switch (_usage) {
      CompactCalendarUsage.adminSelectNewSlot =>
        visuallyDisabled
            ? 1.0 // 지나간 세션은 항상 진하게 (회색이 확실히 보이도록)
            : (isCurrentReservation
                ? 1.0
                : (isSelected ? 1.0 : 0.4)), // 현재 예약 또는 선택된 세션은 진하게, 나머지는 연하게
      _ =>
        (isEditMode && !isCurrentReservation && !isFull && !isLocked)
            ? (isSelected ? 1.0 : 0.4)
            : 1.0,
    };

    final blockColor = baseColor.withOpacity(opacity);
    // 텍스트 색상은 visuallyDisabled 또는 현재 예약 여부를 기준으로 결정
    final textColor =
        (isCurrentReservation || visuallyDisabled)
            ? AppColors.reservedTextGrey
            : Colors.white.withOpacity(opacity);
    final iconColor =
        (isCurrentReservation || visuallyDisabled)
            ? AppColors.reservedIconGrey
            : Colors.white.withOpacity(0.9 * opacity);

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

    // adminSelectNewSlot 모드에서는 직접 계산한 isPastSession도 체크
    final bool canTapWithPastCheck = switch (_usage) {
      CompactCalendarUsage.adminSelectNewSlot =>
        canTap && !isPastSession, // isPastDate와 isPastSession 둘 다 체크
      _ => canTap,
    };

    return Positioned(
      top: topPosition,
      left: _sessionPadding,
      right: _sessionPadding,
      height: sessionHeightPx,
      child: GestureDetector(
        onTap:
            canTapWithPastCheck
                ? () {
                  // 선택 상태는 "관리자 변경 선택"에서만 유지 (조회/이동 모드에서는 불필요한 내부 상태를 만들지 않음)
                  if (_usage == CompactCalendarUsage.adminSelectNewSlot) {
                    setState(() {
                      // 같은 세션을 다시 클릭하면 선택 해제
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
                  widget.onSessionTap!(_selectedCourse!, session, date);
                }
                : null,
        onLongPress:
            _usage == CompactCalendarUsage.adminNavigate && !isPastSession
                ? () {
                  // 지나간 일정은 롱프레스로도 취소 불가 (이미 위에서 계산한 isPastSession 사용)
                  if (isPastSession) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('지나간 일정은 취소할 수 없습니다.')),
                    );
                    return;
                  }
                  _showCancelSessionDialog(_selectedCourse!, session, date);
                }
                : null,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: 4,
            vertical: sessionHeightPx >= 50 ? 2 : 1,
          ),
          decoration: BoxDecoration(
            color: blockColor,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Stack(
            children: [
              // sessionHeightPx가 매우 작은 경우가 있어 Column이 overflow를 유발할 수 있음.
              // -> 높이가 충분할 때만 텍스트 레이어를 렌더링 (필요 시 scaleDown)
              if (sessionHeightPx >= 14)
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 홈 화면이 아닐 때: 코스 이름 표시
                      if (widget.hideCourseSelector)
                        Text(
                          _selectedCourse!.name,
                          style: TextStyle(
                            color: textColor,
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
                              iconColor,
                              BlendMode.srcIn,
                            ),
                          )
                        else
                          Text(
                            '$reservedCount / $totalSeats',
                            style: TextStyle(
                              color: textColor,
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
                      // 시간 (높이가 충분할 때만 표시, 줄바꿈)
                      if (sessionHeightPx >= 70) ...[
                        SizedBox(height: sessionHeightPx >= 80 ? 4 : 3),
                        Text(
                          '${session.startTime}\n- ${session.endTime}',
                          style: TextStyle(
                            color: iconColor,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            height: 1.2,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      // 남은 자리 (홈 화면이 아닐 때만, 높이가 충분할 때만 표시, courseDetailView 모드에서는 숨김)
                      if (widget.hideCourseSelector &&
                          sessionHeightPx >= 90 &&
                          _usage != CompactCalendarUsage.courseDetailView) ...[
                        SizedBox(height: sessionHeightPx >= 100 ? 3 : 2),
                        Text(
                          '$remainingSeats / $totalSeats',
                          style: TextStyle(
                            color: iconColor,
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
              // 1. 탭 불가능하고 && 현재 예약이 아니고 && 잠겨있고 && 주차가 열리지 않았거나
              // 2. adminSelectNewSlot 모드에서 지나간 세션인 경우
              if ((!canTapWithPastCheck &&
                      !isCurrentReservation &&
                      isLocked &&
                      !isBookingWeekOpened) ||
                  (_usage == CompactCalendarUsage.adminSelectNewSlot &&
                      isPastSession))
                Positioned(
                  top: 0,
                  right: 0,
                  child: Icon(
                    Icons.lock_rounded,
                    size: sessionHeightPx >= 60 ? 18 : 14,
                    color: iconColor,
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
                      color: iconColor,
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
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white,
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
    );
  }

  // 시간 문자열을 분 단위로 변환
  int _parseTimeToMinutes(String time) {
    final parts = time.split(':');
    final hour = int.parse(parts[0]);
    final minute = int.parse(parts[1]);
    return hour * 60 + minute;
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
  final Reservation reservation;
  final DateTime date;

  const _ReservationSessionInfo({
    required this.course,
    required this.session,
    required this.reservation,
    required this.date,
  });
}
