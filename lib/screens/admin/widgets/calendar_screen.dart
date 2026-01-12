import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../models/course.dart';
import '../../../models/reservation.dart';
import '../../../models/session_reservation.dart';
import '../../../models/course_enrollment.dart';
import '../../../policies/course_policy.dart';
import '../../../policies/reservation_policy_engine.dart';
import '../../../providers/auth_provider.dart';
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
import 'package:flutter/scheduler.dart';

class CalendarScreen extends StatefulWidget {
  final Course course;

  const CalendarScreen({super.key, required this.course});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  Course get course => widget.course;

  // 주간 이동을 위한 상태
  int _weekOffset = 0; // 0: 현재 주(이번주), 1: 다음주, 2: 다다음주

  final FirestoreService _firestoreService = FirestoreService();
  CoursePolicy? _coursePolicy;
  StreamSubscription<List<SessionReservation>>? _sessionReservationSub;
  final Map<String, SessionReservation> _sessionReservationsByKey = {};
  StreamSubscription<ReservationOperationEvent>? _reservationOpSub;
  String? _lastShownCompleteReservationId;

  // 구독 파라미터 추적 (중복 구독 방지)
  String? _lastSubscribedCourseId;
  String? _lastSubscribedPlaceId;
  int? _lastSubscribedWeekOffset;
  DateTime? _lastSubscribedStartDate;
  DateTime? _lastSubscribedEndDate;

  // 정책 기반 주차 범위
  List<int> _availableWeekOffsets = [0, 1, 2]; // 기본값

  // 에러 상태 관리
  String? _errorMessage;
  String? _errorType;
  bool _isLoading = false;

  // UI 상수 정의
  static const double _minHourSlotHeight = 120.0; // 세션이 있는 구간의 최소 한 시간당 높이 (px)
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
    debugPrint('[CalendarScreen] initState: 화면 초기화 시작');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      debugPrint('[CalendarScreen] postFrameCallback: 구독 시작 준비');
      _ensureUserDataLoaded();
      _subscribeWeekSessionReservations();
      _subscribeReservationOperationEvents();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
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
    _reservationOpSub?.cancel();
    _scrollController.dispose();
    // 구독 파라미터 초기화
    _lastSubscribedCourseId = null;
    _lastSubscribedPlaceId = null;
    _lastSubscribedWeekOffset = null;
    _lastSubscribedStartDate = null;
    _lastSubscribedEndDate = null;
    debugPrint('[CalendarScreen] dispose: 모든 리소스 해제 완료');
    super.dispose();
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

      // cancel 성공 시: 달력에서도 바로 피드백 + 상태 갱신
      if (event.type == ReservationOperationType.cancel &&
          event.success == true &&
          event.reservation != null) {
        if (!mounted) return;
        final r = event.reservation!;
        try {
          // 취소 후 크레딧/예약이 바로 반영되도록 강제 재구독 (닫혀있어도 백그라운드에서 정상 동작)
          await Provider.of<EnrollmentProvider>(
            context,
            listen: false,
          ).loadUserEnrollments(userId: r.userId, placeId: r.placeId);
          await Provider.of<ReservationProvider>(
            context,
            listen: false,
          ).loadUserReservations(userId: r.userId, placeId: r.placeId);
        } catch (_) {}
        SnackbarUtil.showSuccess(context, '예약이 취소되었습니다.');
        if (!mounted) return;
        setState(() {});
      }

      // cancel 실패 시: 바텀시트가 닫혀 있어도 즉시 피드백
      if (event.type == ReservationOperationType.cancel &&
          event.success == false) {
        if (!mounted) return;
        final msg = event.error?.toString();
        SnackbarUtil.showError(
          context,
          (msg == null || msg.isEmpty) ? '예약 취소에 실패했습니다.' : '예약 취소 실패: $msg',
        );
        if (!mounted) return;
        setState(() {});
      }

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
        SnackbarUtil.showSuccess(context, '예약이 변경되었습니다.');
        if (!mounted) return;
        setState(() {});
      }

      // move 실패 시: 바텀시트가 닫혀 있어도 즉시 피드백
      if (event.type == ReservationOperationType.move &&
          event.success == false) {
        if (!mounted) return;
        final msg = event.error?.toString();
        SnackbarUtil.showError(
          context,
          (msg == null || msg.isEmpty) ? '예약 변경에 실패했습니다.' : '예약 변경 실패: $msg',
        );
        if (!mounted) return;
        setState(() {});
      }
    });
  }

  void _ensureUserDataLoaded() {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final placeId = Provider.of<PlaceProvider>(
      context,
      listen: false,
    ).currentPlace?.id;
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
    final placeId = Provider.of<PlaceProvider>(
      context,
      listen: false,
    ).currentPlace?.id;
    if (placeId == null) return;
    try {
      final policy = await _firestoreService.getCoursePolicy(
        courseId: course.id,
        placeId: placeId,
      );
      if (!mounted) return;
      setState(() {
        _coursePolicy = policy;
        // 정책 기반 주차 범위 계산
        _availableWeekOffsets = WeekRangeCalculator.getAvailableWeekOffsets(
          policy,
        );
        // 선택된 주차가 범위를 벗어나면 조정
        if (_weekOffset >= _availableWeekOffsets.length) {
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
        _availableWeekOffsets = WeekRangeCalculator.getAvailableWeekOffsets(
          defaultPolicy,
        );
        if (_weekOffset >= _availableWeekOffsets.length) {
          _weekOffset = _availableWeekOffsets.length - 1;
        }
      });
    }
  }

  void _subscribeWeekSessionReservations() {
    debugPrint('[CalendarScreen] _subscribeWeekSessionReservations: 구독 시작');

    final placeId = Provider.of<PlaceProvider>(
      context,
      listen: false,
    ).currentPlace?.id;

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
        _lastSubscribedEndDate!.day == endDate.day) {
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

    _sessionReservationsByKey.clear();

    // 구독 파라미터 저장
    _lastSubscribedCourseId = course.id;
    _lastSubscribedPlaceId = placeId;
    _lastSubscribedWeekOffset = weekOffset;
    _lastSubscribedStartDate = startDate;
    _lastSubscribedEndDate = endDate;

    debugPrint('[CalendarScreen] _subscribeWeekSessionReservations: 쿼리 파라미터');
    debugPrint('  - courseId: ${course.id}');
    debugPrint('  - placeId: $placeId');
    debugPrint('  - weekOffset: $weekOffset');
    debugPrint('  - startDate: $startDate');
    debugPrint('  - endDate: $endDate');

    _loadCoursePolicy();

    // 초기 로딩 상태 설정
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _errorType = null;
    });

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
                next[key] = sr;
                debugPrint(
                  '[CalendarScreen]   - $key: reservedCount=${sr.reservedCount}/${sr.capacity}, id=${sr.id}',
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
                _isLoading = false;
              });
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
                _isLoading = false;
                _errorMessage = _getErrorMessage(error);
                _errorType = _getErrorType(error);
              });
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
        _isLoading = false;
        _errorMessage = _getErrorMessage(e);
        _errorType = _getErrorType(e);
      });
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

    // 해당 코스의 세션이 있는 요일들만 가져오기
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

    // 세션이 있는 날짜만 필터링
    final sessionDates = weekDates.where((date) {
      return availableDays.contains(date.weekday);
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
                selectedIndex: _availableWeekOffsets
                    .indexOf(_weekOffset)
                    .clamp(0, _availableWeekOffsets.length - 1),
                onTabChanged: (index) {
                  if (index < _availableWeekOffsets.length) {
                    setState(() {
                      _weekOffset = _availableWeekOffsets[index];
                      _didInitialJump = false;
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
            child: (_errorMessage != null || _errorType != null)
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
                          _subscribeWeekSessionReservations();
                        }
                      } else if (details.primaryVelocity! < 0) {
                        // 왼쪽으로 스와이프 (다음주로)
                        if (currentIndex < _availableWeekOffsets.length - 1) {
                          setState(() {
                            _weekOffset =
                                _availableWeekOffsets[currentIndex + 1];
                            _didInitialJump = false;
                          });
                          _subscribeWeekSessionReservations();
                        }
                      }
                    },
                    child: Column(
                      children: [
                        // 요일 헤더
                        _buildDayHeaders(sessionDates),

                        // 캘린더 그리드
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              return _buildCalendarGrid(
                                sessionDates,
                                viewportHeight: constraints.maxHeight,
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
                        fontSize: 16,
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
    // 해당 컬럼(날짜들)에서 보이는 요일들의 세션만 대상으로 범위 계산
    final weekdays = dates.map((d) => d.weekday).toSet();
    final sessions = course.sessions.where(
      (s) => weekdays.contains(s.dayOfWeek),
    );

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

    // 세션 블록이 잘 보이기 위한 최적 높이 계산
    // 분당 _optimalPxPerMinute 픽셀을 기준으로, 최소 _minHourSlotHeight 보장
    // 예: 1시간 세션 = 60분 * 10.5px/분 = 630px → 630px/h → 10.5px/h
    // 예: 2시간 세션 = 120분 * 10.5px/분 = 1260px → 1260px/h → 21px/h
    // 계산: maxSessionDuration(분) * _optimalPxPerMinute(px/분) / 60(분/h) = px/h
    final optimalHourSlotHeight = maxSessionDuration > 0
        ? (maxSessionDuration * _optimalPxPerMinute / 60.0).clamp(
            _minHourSlotHeight,
            double.infinity,
          )
        : _minHourSlotHeight;

    // 디버그: 계산된 높이 확인
    debugPrint(
      '세션 지속 시간: $maxSessionDuration분, 계산된 높이: ${maxSessionDuration * _optimalPxPerMinute / 60.0}px/h, 최종 높이: $optimalHourSlotHeight px/h',
    );

    // 2시간 여백 + 시간 단위 정렬 + 경계 여백
    var rangeStart = _floorToHour(
      (minStart - _basePaddingMinutes).clamp(0, 24 * 60),
    );
    var rangeEnd = _ceilToHour(
      (maxEnd + _basePaddingMinutes).clamp(0, 24 * 60),
    );

    // 00시 경계에 여백 추가
    if (rangeStart == 0) {
      rangeStart = 0; // 00시는 그대로 유지하되, 시각적으로 여백이 보이도록
    } else if (rangeStart < _edgePaddingMinutes) {
      rangeStart = 0; // 00시 근처면 00시부터 시작
    }

    // 23시 경계에 여백 추가
    if (rangeEnd >= 24 * 60 - _edgePaddingMinutes) {
      rangeEnd = 24 * 60; // 23시 근처면 24시까지 확장
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
    final timeSlots = _generateTimeSlots(
      startHour: smart.startHour,
      endHour: smart.endHour,
    );

    final rangeStartMinutes = smart.rangeStartMinutes;
    final rangeEndMinutes = smart.rangeEndMinutes;

    // 표시되는 요일들에 해당하는 세션들을 모아 "활성 시간대"를 계산
    final weekdays = dates.map((d) => d.weekday).toSet();
    final sessions = course.sessions.where(
      (s) => weekdays.contains(s.dayOfWeek),
    );

    // 시간 슬롯(시간 단위)별로 active 여부 계산 (어느 요일이든 해당 시간대에 세션이 있으면 active)
    final active = List<bool>.filled(timeSlots.length, false);
    int? minSessionStart;
    for (final s in sessions) {
      final start = _parseTimeToMinutes(s.startTime);
      final end = _parseTimeToMinutes(s.endTime);
      if (end <= start) continue;
      minSessionStart = minSessionStart == null
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

    // 초기 점프 위치: 첫 세션 시작 - 2시간 (없으면 rangeStart)
    final initialJumpMinute = minSessionStart == null
        ? rangeStartMinutes
        : (minSessionStart - _basePaddingMinutes).clamp(
            rangeStartMinutes,
            rangeEndMinutes,
          );

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
                  children: layout.timeSlots.asMap().entries.map((entry) {
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
                          fontWeight: isActiveSlot
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: isActiveSlot
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
    final daySessions = course.getSessionsByDay(date.weekday);

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
                color: isActiveSlot
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
    final sessionHeightPx =
        (yForMinute(sessionEndMinutes) - yForMinute(sessionStartMinutes)).clamp(
          0.0,
          double.infinity,
        );

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final placeId = Provider.of<PlaceProvider>(
      context,
      listen: false,
    ).currentPlace?.id;
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
    final totalSeats = sr?.capacity ?? session.getCapacityForDate(date);
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

    final isLocked = !eligibility.canReserve || !isEnrolled || userId == null;
    final isMyReserved = hasUserReservation;
    final canReserve = !isLocked && !isMyReserved;

    // ✅ 이미 예약된 세션은 "연하게(비활성 느낌)" 보이되,
    // 잠김(정책/권한/만석 등)과는 구분해서 표시한다.
    final String? pidForKey = placeId;
    final processingKey = pidForKey == null
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
    final operationType = processingKey != null
        ? reservationProvider.getOperationTypeByKey(processingKey)
        : null;

    // 배경색: 이미 예약된 경우 옅은 코스 컬러 우선, 그 다음 잠김 상태는 회색
    final baseBlockColor = isMyReserved
        ? course
              .colorValue // 이미 예약된 경우 코스 컬러 사용 (회색보다 우선)
        : (isLocked
              ? AppColors
                    .reservedGrey // 잠긴 경우 회색
              : course.colorValue); // 예약 가능한 경우 코스 컬러
    final blockColor = isProcessing
        ? (isMyReserved
              ? baseBlockColor.withOpacity(0.35)
              : baseBlockColor.withOpacity(0.45))
        : (isMyReserved ? baseBlockColor.withOpacity(0.55) : baseBlockColor);

    // 배경색 밝기에 따라 텍스트 색상 자동 결정
    // opacity가 적용된 색상의 실제 밝기를 계산하기 위해
    // 배경이 흰색이라고 가정하고 블렌딩된 색상의 밝기 계산
    final backgroundColor = AppColors.backgroundWhite;
    final blendedColor = Color.alphaBlend(blockColor, backgroundColor);
    final luminance = blendedColor.computeLuminance();

    // 예약 완료 또는 잠김 상태는 회색 텍스트 유지
    final textColor = (isMyReserved || isLocked)
        ? AppColors.reservedTextGrey
        : (luminance > 0.5 ? AppColors.textPrimary : Colors.white);
    final iconColor = (isMyReserved || isLocked)
        ? AppColors.reservedTextGrey
        : (luminance > 0.5
              ? AppColors.textPrimary.withOpacity(0.9)
              : Colors.white.withOpacity(0.9));

    return Positioned(
      top: topPosition,
      left: _sessionPadding,
      right: _sessionPadding,
      height: sessionHeightPx,
      child: GestureDetector(
        onTap: () async {
          if (isProcessing) {
            SnackbarUtil.showError(context, '처리 중입니다. 잠시만 기다려주세요.');
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
                setState(() {});
              },
            );
            return;
          }

          if (canReserve) {
            final String? pid = placeId;
            final String? uid = userId;
            if (pid == null || uid == null) {
              SnackbarUtil.showError(context, '로그인이 필요합니다.');
              return;
            }

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
            SnackbarUtil.showError(context, '등록된 코스가 아닙니다.');
            return;
          }
          if (eligibility.reason == ReservationLockReason.notOpenedYet &&
              eligibility.openAt != null) {
            final t = eligibility.openAt!;
            SnackbarUtil.showError(
              context,
              '아직 예약 오픈 전입니다. (오픈 ${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')})',
            );
            return;
          }
          debugPrint('eligibility.reason: ${eligibility.reason}');
          switch (eligibility.reason) {
            case ReservationLockReason.pastDate:
              SnackbarUtil.showError(context, '과거 날짜는 예약할 수 없습니다.');
              return;
            case ReservationLockReason.closedBeforeStart:
              SnackbarUtil.showError(
                context,
                '세션 시작 ${policy.closeBeforeMinutes}분 전까지만 예약 가능합니다.',
              );
              return;
            case ReservationLockReason.full:
              SnackbarUtil.showError(context, '예약 가능한 인원이 없습니다.');
              return;
            case ReservationLockReason.noCreditsOrExpired:
              SnackbarUtil.showError(context, '예약 가능한 횟수가 없습니다.');
              return;
            case ReservationLockReason.notOpenedYet:
              SnackbarUtil.showError(context, '아직 예약 오픈 전입니다.');
              return;
            case ReservationLockReason.none:
              return;
          }
        },
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: 8,
            vertical: sessionHeightPx >= 50 ? 4 : 2,
          ),
          decoration: BoxDecoration(
            color: blockColor,
            borderRadius: BorderRadius.circular(8),
            boxShadow: isMyReserved
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
                        fontSize: sessionHeightPx >= 60
                            ? 16
                            : (sessionHeightPx >= 40 ? 14 : 12),
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
                          fontSize: sessionHeightPx >= 90 ? 13 : 11,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],

                    // 남은 자리 (높이가 충분할 때만 표시)
                    if (sessionHeightPx >= 90) ...[
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
                          SizedBox(height: sessionHeightPx >= 50 ? 8 : 6),
                          Text(
                            operationType == ReservationOperationType.create
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
              if (!hasUserReservation && isLocked)
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
                onPressed: _isLoading
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
                child: _isLoading
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
