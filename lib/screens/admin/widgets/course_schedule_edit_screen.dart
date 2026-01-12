import 'package:flutter/material.dart';
import 'dart:async';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:provider/provider.dart';
import '../../../models/course.dart';
import '../../../models/reservation.dart';
import '../../../models/session_draft.dart';
import '../../../models/session_reservation.dart';
import '../../../providers/course_provider.dart';
import '../../../providers/place_provider.dart';
import '../../../services/firestore_service.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/snackbar_util.dart';
import '../../../utils/timezone_utils.dart';
import '../../../widgets/common_dialog.dart';
import 'drag_calendar_editor.dart';
import 'session_edit_bottom_sheet.dart';
import 'session_detail_screen.dart';
import 'course_policy_edit_screen.dart';

/// 코스 일정 편집 화면
///
/// CourseScheduleScreen과 유사한 레이아웃으로
/// DragCalendarEditor를 Row로 묶어서 표시
class CourseScheduleEditScreen extends StatefulWidget {
  final Course course;

  const CourseScheduleEditScreen({super.key, required this.course});

  @override
  State<CourseScheduleEditScreen> createState() =>
      _CourseScheduleEditScreenState();
}

class _CourseScheduleEditScreenState extends State<CourseScheduleEditScreen> {
  static const double _minHourSlotHeight = 80.0;

  // 요일별 세션 데이터
  Map<int, List<SessionDraft>> _daySessions = {};
  int _defaultCapacity = 30;

  final FirestoreService _firestoreService = FirestoreService();
  StreamSubscription<Set<String>>? _reservedSessionIdsSub;
  Set<String> _reservedSessionIds = <String>{};
  Map<int, List<SessionDraft>> _initialDaySessionsSnapshot = {};
  bool _shownIndexErrorOnce = false;

  // 드래그 상태 추적
  bool _isAnyDragging = false;
  bool _isSaving = false; // 저장 중 상태
  bool _didInitialJump = false;
  ScrollController? _calendarScrollController;

  // 각 요일의 DragCalendarEditor에 접근하기 위한 GlobalKey
  final Map<int, GlobalKey> _calendarEditorKeys = {};

  void _clearSelectionForDay(int dayOfWeek) {
    final key = _calendarEditorKeys[dayOfWeek];
    if (key?.currentState != null) {
      (key!.currentState as dynamic).clearSelection();
    }
  }

  @override
  void initState() {
    super.initState();
    _calendarScrollController = ScrollController();
    _loadSessions();
    _subscribeReservedSessionIds();
  }

  @override
  void dispose() {
    _reservedSessionIdsSub?.cancel();
    _calendarScrollController?.dispose();
    super.dispose();
  }

  void _subscribeReservedSessionIds() {
    _reservedSessionIdsSub?.cancel();
    _reservedSessionIdsSub = _firestoreService
        .watchReservedSessionIdsForCourse(widget.course.id)
        .listen(
          (ids) {
            if (!mounted) return;
            setState(() {
              _reservedSessionIds = ids;
            });
          },
          onError: (e, _) {
            // Firestore 인덱스 누락 등으로 스트림이 실패해도 화면이 죽지 않도록 방어
            debugPrint(
              '[CourseScheduleEditScreen] watchReservedSessionIdsForCourse error: $e',
            );
            if (!mounted) return;
            setState(() {
              _reservedSessionIds = <String>{};
            });
            if (_shownIndexErrorOnce) return;
            _shownIndexErrorOnce = true;
            SnackbarUtil.showError(
              context,
              '예약 세션 조회를 위해 Firestore 인덱스가 필요합니다. (콘솔에서 indexes 생성 후 다시 시도)',
            );
          },
        );
  }

  // CourseSession을 SessionDraft로 변환
  void _loadSessions() {
    final course = widget.course;
    _daySessions = {};

    for (final session in course.sessions) {
      if (!_daySessions.containsKey(session.dayOfWeek)) {
        _daySessions[session.dayOfWeek] = [];
      }
      _daySessions[session.dayOfWeek]!.add(
        SessionDraft(
          startTime: session.startTime,
          endTime: session.endTime,
          capacity: session.capacity,
        ),
      );
    }

    // 기본 수용인원 설정
    if (course.sessions.isNotEmpty) {
      _defaultCapacity = course.sessions.first.capacity;
    }

    // 초기 상태 스냅샷 저장 (요일 삭제 확인 등에서 사용)
    _initialDaySessionsSnapshot = {
      for (final entry in _daySessions.entries)
        entry.key: entry.value
            .map(
              (s) => SessionDraft(
                startTime: s.startTime,
                endTime: s.endTime,
                capacity: s.capacity,
              ),
            )
            .toList(),
    };
  }

  DateTime _dateForDayOfWeekInCurrentWeek(int dayOfWeek) {
    final now = TimezoneUtils.getSeoulDateTime();
    final daysFromMonday = now.weekday - 1;
    final thisWeekMonday = now.subtract(Duration(days: daysFromMonday));
    return DateTime(
      thisWeekMonday.year,
      thisWeekMonday.month,
      thisWeekMonday.day,
    ).add(Duration(days: dayOfWeek - 1));
  }

  // 특정 요일에 "예약이 존재하는 세션 템플릿"이 하나라도 있는지 확인 (주차 무관)
  bool _hasReservationsForDay(int dayOfWeek) {
    for (final s in _daySessions[dayOfWeek] ?? []) {
      final sessionId = SessionReservation.generateSessionId(
        widget.course.id,
        dayOfWeek,
        s.startTime,
      );
      if (_reservedSessionIds.contains(sessionId)) return true;
    }
    return false;
  }

  // 특정 세션 템플릿(요일+시작시간)에 예약이 있는지 확인 (주차 무관)
  bool _hasReservationsForSession(int dayOfWeek, String startTime) {
    final sessionId = SessionReservation.generateSessionId(
      widget.course.id,
      dayOfWeek,
      startTime,
    );
    return _reservedSessionIds.contains(sessionId);
  }

  Future<bool> _onWillPop() async {
    if (!_hasChanges()) {
      return true; // 변경사항 없으면 바로 나가기
    }

    // 변경사항이 있으면 확인 다이얼로그
    final confirmed = await CommonDialog.show(
      context: context,
      title: '변경사항이 있습니다',
      message: '저장하지 않고 나가시면]\n변경된 내용이 사라집니다.',
      secondaryMessage: '정말 나가시겠습니까?',
      cancelText: '취소',
      confirmText: '나가기',
      confirmButtonColor: Colors.red,
    );

    return confirmed == true;
  }

  @override
  Widget build(BuildContext context) {
    final selectedDays = _daySessions.keys.toList()..sort();

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.backgroundWhite,
        appBar: AppBar(
          scrolledUnderElevation: 0,
          backgroundColor: AppColors.backgroundWhite,
          elevation: 0,
          leading: IconButton(
            icon: Icon(
              Icons.arrow_back_ios_rounded,
              color: AppColors.textPrimary,
            ),
            onPressed: () async {
              final shouldPop = await _onWillPop();
              if (shouldPop && mounted) {
                Navigator.of(context).pop();
              }
            },
          ),
          actions: [
            // 예약 정책 변경 버튼 (OutlinedButton) - 저장 중일 때 숨김
            if (!_isSaving)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: OutlinedButton(
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => CoursePolicyEditScreen(
                          courseId: widget.course.id,
                          requireSave: false,
                        ),
                      ),
                    );
                  },
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    side: BorderSide(
                      color: AppColors.textPrimary.withOpacity(0.2),
                      width: 1,
                    ),
                  ),
                  child: Text(
                    '예약 정책',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ),
            // 요일 편집 버튼 (OutlinedButton) - 저장 중일 때 숨김
            if (!_isSaving)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: OutlinedButton(
                  onPressed: _showAddDayDialog,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    side: BorderSide(
                      color: AppColors.textPrimary.withOpacity(0.2),
                      width: 1,
                    ),
                  ),
                  child: Text(
                    '요일 편집',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ),
            // 저장 버튼 (FilledButton, 변경사항 있을 때만 활성화)
            Padding(
              padding: const EdgeInsets.only(right: 20),
              child: FilledButton(
                onPressed: (_hasChanges() && !_isSaving) ? _saveSessions : null,
                style: FilledButton.styleFrom(
                  backgroundColor: _isSaving
                      ? AppColors.borderLight
                      : AppColors.primaryGreen,
                  disabledBackgroundColor: AppColors.borderLight,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 8,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                child: _isSaving
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                AppColors.primaryGreen,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '저장 중...',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      )
                    : Text(
                        '저장',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
              ),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          bottom: false,
          child: Column(
            children: [
              SizedBox(height: 12),

              // 메인 콘텐츠
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        children: [
                          // 요일 헤더
                          Container(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            color: AppColors.backgroundWhite,
                            child: Row(
                              children: [
                                // 시간 컬럼 헤더
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
                                          color: AppColors.textPrimary,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                // 각 요일 헤더
                                if (selectedDays.isEmpty)
                                  Expanded(
                                    child: Center(
                                      child: Text(
                                        '요일을 추가해주세요',
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: AppColors.textSecondary,
                                        ),
                                      ),
                                    ),
                                  )
                                else
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

                                    return Expanded(
                                      child: Center(
                                        child: Text(
                                          dayNames[day],
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                            color: AppColors.textPrimary,
                                          ),
                                        ),
                                      ),
                                    );
                                  }).toList(),
                              ],
                            ),
                          ),
                          // 모든 요일의 캘린더를 동시에 표시
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                return _buildAllDaysCalendar(
                                  constraints.maxHeight,
                                  selectedDays,
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 모든 요일의 캘린더를 동시에 표시
  Widget _buildAllDaysCalendar(double viewportHeight, List<int> selectedDays) {
    if (selectedDays.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.calendar_today_outlined,
              size: 48,
              color: AppColors.textSecondary.withOpacity(0.3),
            ),
            const SizedBox(height: 16),
            Text(
              '요일을 추가해주세요',
              style: TextStyle(fontSize: 16, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => _showAddDayDialog(),
              icon: Icon(Icons.add, color: Colors.white),
              label: Text('요일 추가'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryGreen,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // 전체 시간대 계산 (00:00 ~ 24:00)
    final hours = List.generate(24, (i) => i);
    final hourSlotHeight = (viewportHeight / 24).clamp(
      _minHourSlotHeight,
      double.infinity,
    );
    final totalHeight = hours.length * hourSlotHeight;

    // 초기 진입 시 9시로 스크롤
    if (!_didInitialJump && _calendarScrollController != null) {
      _didInitialJump = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_calendarScrollController!.hasClients) {
          final targetY = 9 * hourSlotHeight;
          _calendarScrollController!.jumpTo(
            targetY.clamp(
              0.0,
              _calendarScrollController!.position.maxScrollExtent,
            ),
          );
        }
      });
    }

    return Container(
      color: AppColors.backgroundWhite,
      child: SingleChildScrollView(
        controller: _calendarScrollController,
        physics: _isAnyDragging
            ? const NeverScrollableScrollPhysics()
            : const AlwaysScrollableScrollPhysics(),
        child: SizedBox(
          height: totalHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 시간 컬럼 (고정, 공통)
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
                  children: hours.map((hour) {
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
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: selectedDays.map((day) {
                      return SizedBox(
                        width:
                            (MediaQuery.of(context).size.width - 35) /
                            selectedDays.length.clamp(1, 7),
                        child: _buildDayScheduleEditor(
                          day,
                          hourSlotHeight: hourSlotHeight,
                          totalHeight: totalHeight,
                          scrollController: _calendarScrollController!,
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
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDayScheduleEditor(
    int dayOfWeek, {
    required double hourSlotHeight,
    required double totalHeight,
    required ScrollController scrollController,
    required Function(bool) onDragStateChanged,
  }) {
    final sessions = _daySessions[dayOfWeek] ?? [];

    // GlobalKey 초기화
    if (!_calendarEditorKeys.containsKey(dayOfWeek)) {
      _calendarEditorKeys[dayOfWeek] = GlobalKey();
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: AppColors.borderLight, width: 0.5),
        ),
      ),
      child: DragCalendarEditor(
        key: _calendarEditorKeys[dayOfWeek],
        dayOfWeek: dayOfWeek,
        sessions: sessions,
        defaultCapacity: _defaultCapacity,
        courseColor: Color(widget.course.color),
        hourSlotHeight: hourSlotHeight,
        totalHeight: totalHeight,
        scrollController: scrollController,
        isEditMode: true, // 템플릿 편집은 주차/과거 여부와 무관하게 허용
        onSessionsChanged: (newSessions) {
          setState(() {
            _daySessions[dayOfWeek] = newSessions;
          });
        },
        onDragStateChanged: onDragStateChanged,
        onDragEnd: (startTime, endTime, day) {
          _showSessionEditBottomSheet(startTime, endTime, day);
        },
        onEditSession: (session) {
          () async {
            // 예약이 있으면: 시간변경/삭제 금지 -> 예약 관리(세션 상세)로 이동
            if (_hasReservationsForSession(dayOfWeek, session.startTime)) {
              final placeId = Provider.of<PlaceProvider>(
                context,
                listen: false,
              ).currentPlace?.id;
              if (placeId == null) return;

              final sessionId = SessionReservation.generateSessionId(
                widget.course.id,
                dayOfWeek,
                session.startTime,
              );

              // 실제 예약이 존재하는 날짜로 이동(없으면 현재 주 날짜로 fallback)
              DateTime? reservedDate;
              try {
                reservedDate = await _firestoreService
                    .findFirstReservedDateForSession(sessionId);
              } catch (e) {
                debugPrint(
                  '[CourseScheduleEditScreen] findFirstReservedDateForSession failed: $e',
                );
                reservedDate = null;
              }
              final date =
                  reservedDate ?? _dateForDayOfWeekInCurrentWeek(dayOfWeek);

              final courseSession =
                  widget.course.findSession(dayOfWeek, session.startTime) ??
                  CourseSession(
                    dayOfWeek: dayOfWeek,
                    startTime: session.startTime,
                    endTime: session.endTime,
                    capacity: session.capacity,
                  );

              if (!mounted) return;
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SessionDetailScreen(
                    course: widget.course,
                    session: courseSession,
                    date: date,
                    placeId: placeId,
                  ),
                ),
              );
              return;
            }

            // 예약이 없으면: 바로 수정 바텀시트
            _showSessionEditBottomSheet(
              session.startTime,
              session.endTime,
              dayOfWeek,
              existingSession: session,
            );
          }();
        },
      ),
    );
  }

  // 세션 편집 바텀시트 표시
  void _showSessionEditBottomSheet(
    String startTime,
    String endTime,
    int dayOfWeek, {
    SessionDraft? existingSession,
  }) {
    final isEditMode = existingSession != null;
    final capacity = existingSession?.capacity ?? _defaultCapacity;
    final selectedDays = {..._daySessions.keys, dayOfWeek};

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.7),
      isDismissible: true,
      enableDrag: true,
      useSafeArea: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SessionEditBottomSheet(
          initialStartTime: startTime,
          initialEndTime: endTime,
          initialCapacity: capacity,
          courseName: widget.course.name,
          dayOfWeek: dayOfWeek,
          selectedDays: selectedDays,
          courseColor: Color(widget.course.color),
          existingSessions: _daySessions[dayOfWeek] ?? [],
          allDaySessions: _daySessions, // 모든 요일의 세션 정보 전달
          isEditMode: isEditMode,
          onCancel: () {
            _clearSelectionForDay(dayOfWeek);
          },
          onRegister: (newStartTime, newEndTime, newCapacity, bulkDays) {
            // 시간 유효성 검증
            final startMinutes = _parseTimeToMinutes(newStartTime);
            final endMinutes = _parseTimeToMinutes(newEndTime);
            if (startMinutes >= endMinutes) {
              SnackbarUtil.showError(context, '시작 시간은 종료 시간보다 빨라야 합니다.');
              return;
            }

            // 정원 유효성 검증
            if (newCapacity <= 0) {
              SnackbarUtil.showError(context, '정원은 1명 이상이어야 합니다.');
              return;
            }

            if (newCapacity > 999) {
              SnackbarUtil.showError(context, '정원은 999명 이하여야 합니다.');
              return;
            }

            setState(() {
              _defaultCapacity = newCapacity;

              // 일괄 적용 (등록/수정 모두)
              if (bulkDays != null && bulkDays.isNotEmpty) {
                const dayNames = ['', '월', '화', '수', '목', '금', '토', '일'];
                if (isEditMode) {
                  // 수정 모드: 모든 요일에 동일하게 적용
                  for (final bulkDay in bulkDays) {
                    _daySessions.putIfAbsent(bulkDay, () => <SessionDraft>[]);
                    final sessions = _daySessions[bulkDay] ?? [];

                    // 기존 세션 찾기 (원본 시간대 기준)
                    final existingIndex = sessions.indexWhere(
                      (s) => s.startTime == startTime && s.endTime == endTime,
                    );

                    if (existingIndex != -1) {
                      final temp = List<SessionDraft>.from(sessions);
                      temp[existingIndex] = SessionDraft(
                        startTime: newStartTime,
                        endTime: newEndTime,
                        capacity: newCapacity,
                      );
                      // 자기 자신을 제외하고 겹침 체크
                      final overlapInfo = _findOverlapInDay(
                        temp,
                        excludeIndex: existingIndex,
                      );
                      if (overlapInfo == null) {
                        sessions[existingIndex] = temp[existingIndex];
                      } else {
                        SnackbarUtil.showError(
                          context,
                          '${dayNames[bulkDay]}요일: ${overlapInfo['overlapStart']}~${overlapInfo['overlapEnd']} 세션과 시간이 겹칩니다.',
                        );
                      }
                    } else {
                      // 없으면 새로 추가 (겹침 체크)
                      final overlapInfo = _findOverlap(
                        bulkDay,
                        newStartTime,
                        newEndTime,
                      );
                      if (overlapInfo == null) {
                        sessions.add(
                          SessionDraft(
                            startTime: newStartTime,
                            endTime: newEndTime,
                            capacity: newCapacity,
                          ),
                        );
                      } else {
                        SnackbarUtil.showError(
                          context,
                          '${dayNames[bulkDay]}요일: ${overlapInfo['overlapStart']}~${overlapInfo['overlapEnd']} 세션과 시간이 겹칩니다.',
                        );
                      }
                    }
                    _daySessions[bulkDay] = sessions;
                  }
                } else {
                  // 등록 모드: 겹치지 않는 요일에만 추가
                  for (final bulkDay in bulkDays) {
                    _daySessions.putIfAbsent(bulkDay, () => <SessionDraft>[]);
                    final overlapInfo = _findOverlap(
                      bulkDay,
                      newStartTime,
                      newEndTime,
                    );
                    if (overlapInfo == null) {
                      _daySessions[bulkDay]!.add(
                        SessionDraft(
                          startTime: newStartTime,
                          endTime: newEndTime,
                          capacity: newCapacity,
                        ),
                      );
                    } else {
                      SnackbarUtil.showError(
                        context,
                        '${dayNames[bulkDay]}요일: ${overlapInfo['overlapStart']}~${overlapInfo['overlapEnd']} 세션과 시간이 겹칩니다.',
                      );
                    }
                  }
                }
                return;
              }

              if (isEditMode) {
                // 기존 세션 수정 (단일 요일)
                final sessions = _daySessions[dayOfWeek] ?? [];
                final index = sessions.indexWhere(
                  (s) => s.startTime == startTime && s.endTime == endTime,
                );
                if (index != -1) {
                  final temp = List<SessionDraft>.from(sessions);
                  temp[index] = SessionDraft(
                    startTime: newStartTime,
                    endTime: newEndTime,
                    capacity: newCapacity,
                  );
                  // 자기 자신을 제외하고 겹침 체크
                  final overlapInfo = _findOverlapInDay(
                    temp,
                    excludeIndex: index,
                  );
                  if (overlapInfo == null) {
                    sessions[index] = temp[index];
                    _daySessions[dayOfWeek] = sessions;
                  } else {
                    SnackbarUtil.showError(
                      context,
                      '${overlapInfo['overlapStart']}~${overlapInfo['overlapEnd']} 세션과 시간이 겹칩니다.',
                    );
                  }
                }
              } else {
                // 새 세션 추가 (단일 요일)
                _daySessions.putIfAbsent(dayOfWeek, () => <SessionDraft>[]);
                final overlapInfo = _findOverlap(
                  dayOfWeek,
                  newStartTime,
                  newEndTime,
                );
                if (overlapInfo == null) {
                  _daySessions[dayOfWeek]!.add(
                    SessionDraft(
                      startTime: newStartTime,
                      endTime: newEndTime,
                      capacity: newCapacity,
                    ),
                  );
                } else {
                  SnackbarUtil.showError(
                    context,
                    '${overlapInfo['overlapStart']}~${overlapInfo['overlapEnd']} 세션과 시간이 겹칩니다.',
                  );
                }
              }
            });

            _clearSelectionForDay(dayOfWeek);
          },
          onDelete: isEditMode
              ? (bulkDays) async {
                  // 예약이 있는 세션인지 확인
                  if (_hasReservationsForSession(
                    dayOfWeek,
                    existingSession.startTime,
                  )) {
                    await _showBulkMoveOption(dayOfWeek, existingSession);
                    _clearSelectionForDay(dayOfWeek);
                    return;
                  }

                  // 예약이 없으면 바로 삭제(템플릿에서 제거)
                  setState(() {
                    final sessions = _daySessions[dayOfWeek] ?? [];
                    sessions.remove(existingSession);
                    _daySessions[dayOfWeek] = sessions;
                  });
                  _clearSelectionForDay(dayOfWeek);
                }
              : null,
        ),
      ),
    ).then((_) {
      // 바텀시트가 닫힐 때(dismiss 포함) 선택 영역 초기화
      _clearSelectionForDay(dayOfWeek);
    });
  }

  // 일괄 취소 옵션 표시 (요일 편집에서는 취소만 지원)
  Future<void> _showBulkMoveOption(int dayOfWeek, SessionDraft session) async {
    // 예약 목록 조회 (최근 4주간)
    final now = TimezoneUtils.getSeoulDateTime();
    final startDate = DateTime(now.year, now.month, now.day);
    final endDate = startDate.add(const Duration(days: 28));

    List<Reservation> allReservations = [];
    try {
      // 모든 날짜의 예약을 조회 (날짜별로 조회)
      for (
        var date = startDate;
        date.isBefore(endDate) || date.isAtSameMomentAs(endDate);
        date = date.add(const Duration(days: 1))
      ) {
        if (date.weekday == dayOfWeek) {
          try {
            final placeProvider = Provider.of<PlaceProvider>(
              context,
              listen: false,
            );
            final placeId = placeProvider.currentPlace?.id ?? '';
            if (placeId.isEmpty) {
              throw Exception('플레이스 정보를 찾을 수 없습니다.');
            }
            final reservations = await _firestoreService
                .watchSessionReservations(
                  placeId: placeId,
                  courseId: widget.course.id,
                  dayOfWeek: dayOfWeek,
                  startTime: session.startTime,
                  date: date,
                )
                .first;
            allReservations.addAll(reservations);
          } catch (_) {
            // 개별 날짜 조회 실패는 무시하고 계속
          }
        }
      }
    } catch (e) {
      SnackbarUtil.showError(context, '예약 목록을 불러오는 중 오류가 발생했습니다.');
      return;
    }

    if (allReservations.isEmpty) {
      // 예약이 없다고 판단되면 바로 삭제
      // 하지만 _reservedSessionIds에 있으면 실제로 예약이 있을 수 있으므로 재확인
      final sessionId = SessionReservation.generateSessionId(
        widget.course.id,
        dayOfWeek,
        session.startTime,
      );
      if (_reservedSessionIds.contains(sessionId)) {
        // 스트림 데이터와 실제 조회 결과가 다를 수 있으므로 경고만 표시
        SnackbarUtil.showError(
          context,
          '예약 정보를 확인하는 중 오류가 발생했습니다. 잠시 후 다시 시도해주세요.',
        );
        return;
      }
      await _deleteSession(dayOfWeek, session);
      return;
    }

    // 일괄 취소 확인 다이얼로그
    const dayNames = ['', '월', '화', '수', '목', '금', '토', '일'];
    final confirmed = await CommonDialog.show(
      context: context,
      title: '예약이 있는 세션',
      message:
          '${dayNames[dayOfWeek]}요일 ${session.startTime}~${session.endTime} 세션에\n'
          '${allReservations.length}명의 예약이 있습니다.\n\n'
          '세션을 삭제하려면 모든 예약을 취소해야 합니다.',
      cancelText: '취소',
      confirmText: '일괄 취소 (${allReservations.length}명)',
      confirmButtonColor: Colors.red,
    );

    if (confirmed != true) {
      return;
    }

    // 일괄 취소 실행
    try {
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final placeId = placeProvider.currentPlace?.id ?? '';
      if (placeId.isEmpty) {
        SnackbarUtil.showError(context, '플레이스 정보를 찾을 수 없습니다.');
        return;
      }

      final result = await _firestoreService.batchCancelReservations(
        reservationIds: allReservations.map((r) => r.id).toList(),
        placeId: placeId,
      );

      final cancelledCount = result['cancelledCount'] as int? ?? 0;
      final results = result['results'] as List<dynamic>? ?? [];
      final failedCount = results
          .where((r) => (r as Map)['success'] != true)
          .length;

      if (!mounted) return;

      if (failedCount == 0) {
        SnackbarUtil.showSuccess(context, '$cancelledCount명의 예약이 취소되었습니다.');
        // 취소 완료 후 세션 삭제
        await _deleteSession(dayOfWeek, session);
      } else {
        SnackbarUtil.showError(
          context,
          '$cancelledCount명 취소 완료, $failedCount명 취소 실패',
        );
        // 일부라도 성공했으면 세션 삭제
        if (cancelledCount > 0) {
          await _deleteSession(dayOfWeek, session);
        }
      }
    } catch (e) {
      if (!mounted) return;
      SnackbarUtil.showError(context, '일괄 취소 중 오류가 발생했습니다: $e');
    }
  }

  // 세션 삭제
  Future<void> _deleteSession(int dayOfWeek, SessionDraft session) async {
    const dayNames = ['', '월', '화', '수', '목', '금', '토', '일'];

    // 삭제 확인 다이얼로그
    final confirmed = await CommonDialog.show(
      context: context,
      title: '세션 삭제',
      message:
          '${dayNames[dayOfWeek]}요일 ${session.startTime}~${session.endTime} 세션을 삭제하시겠습니까?',
      confirmText: '삭제',
      cancelText: '취소',
      confirmButtonColor: Colors.red,
    );

    if (confirmed != true) {
      return;
    }

    // 개별 세션만 삭제 (요일은 유지)
    final sessions = _daySessions[dayOfWeek] ?? [];
    sessions.remove(session);

    // 세션 리스트 업데이트 (요일은 유지)
    _daySessions[dayOfWeek] = sessions;

    setState(() {});
  }

  // 겹침 체크 (겹치는 세션 정보 반환)
  Map<String, String>? _findOverlapInDay(
    List<SessionDraft> sessions, {
    int? excludeIndex,
  }) {
    for (int i = 0; i < sessions.length; i++) {
      if (excludeIndex != null && i == excludeIndex) continue;
      final aStart = _parseTimeToMinutes(sessions[i].startTime);
      final aEnd = _parseTimeToMinutes(sessions[i].endTime);
      for (int j = i + 1; j < sessions.length; j++) {
        if (excludeIndex != null && j == excludeIndex) continue;
        final bStart = _parseTimeToMinutes(sessions[j].startTime);
        final bEnd = _parseTimeToMinutes(sessions[j].endTime);
        if (aStart < bEnd && aEnd > bStart) {
          // 겹치는 세션 정보 반환
          return {
            'overlapStart': sessions[j].startTime,
            'overlapEnd': sessions[j].endTime,
          };
        }
      }
    }
    return null;
  }

  // 겹침 체크 (겹치는 세션 정보 반환)
  Map<String, String>? _findOverlap(
    int dayOfWeek,
    String startTime,
    String endTime,
  ) {
    final sessions = _daySessions[dayOfWeek] ?? [];
    final newStart = _parseTimeToMinutes(startTime);
    final newEnd = _parseTimeToMinutes(endTime);

    for (final session in sessions) {
      final sessionStart = _parseTimeToMinutes(session.startTime);
      final sessionEnd = _parseTimeToMinutes(session.endTime);

      if (newStart < sessionEnd && newEnd > sessionStart) {
        return {
          'overlapStart': session.startTime,
          'overlapEnd': session.endTime,
        };
      }
    }
    return null;
  }

  // 시간을 분으로 변환
  int _parseTimeToMinutes(String time) {
    final parts = time.split(':');
    final hour = int.parse(parts[0]);
    final minute = int.parse(parts[1]);
    return hour * 60 + minute;
  }

  // 세션 저장
  void _saveSessions() async {
    // 저장 중이면 중복 실행 방지
    if (_isSaving) return;

    // 빈 세션 리스트 검증
    final totalSessions = _daySessions.values.fold<int>(
      0,
      (sum, sessions) => sum + sessions.length,
    );
    if (totalSessions == 0) {
      final confirmed = await CommonDialog.show(
        context: context,
        title: '세션이 없습니다',
        message: '모든 세션이 삭제되었습니다.\n정말 저장하시겠습니까?',
        confirmText: '저장',
        cancelText: '취소',
        confirmButtonColor: Colors.red,
      );
      if (confirmed != true) {
        return;
      }
    }

    // 삭제된 요일 중 코스가 있는 요일 확인
    final originalDays = _initialDaySessionsSnapshot.keys.toSet();
    final currentDays = _daySessions.keys.toSet();
    final removedDays = originalDays.difference(currentDays);

    // 삭제된 요일 중에 세션이 있었던 요일이 있는지 확인
    final removedDaysWithSessions = removedDays.where((day) {
      final originalSessions = _initialDaySessionsSnapshot[day] ?? [];
      return originalSessions.isNotEmpty;
    }).toList();

    // 코스가 있는 날을 지웠다면 확인 다이얼로그
    if (removedDaysWithSessions.isNotEmpty) {
      const dayNames = ['', '월', '화', '수', '목', '금', '토', '일'];
      final removedDayNames = removedDaysWithSessions
          .map((day) => dayNames[day])
          .join(', ');

      final confirmed = await CommonDialog.show(
        context: context,
        title: '요일 삭제 확인',
        message: '${removedDayNames}요일의 모든 세션이 삭제됩니다.\n계속하시겠습니까?',
        confirmText: '삭제',
        cancelText: '취소',
        confirmButtonColor: Colors.red,
      );

      if (confirmed != true) {
        return;
      }
    }

    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final currentPlace = placeProvider.currentPlace;

    if (currentPlace == null) {
      SnackbarUtil.showError(context, '플레이스를 찾을 수 없습니다.');
      return;
    }

    // SessionDraft를 CourseSession으로 변환
    final courseSessions = <CourseSession>[];
    for (final entry in _daySessions.entries) {
      final dayOfWeek = entry.key;
      for (final draft in entry.value) {
        // 시간 유효성 검증
        final startMinutes = _parseTimeToMinutes(draft.startTime);
        final endMinutes = _parseTimeToMinutes(draft.endTime);
        if (startMinutes >= endMinutes) {
          SnackbarUtil.showError(
            context,
            '${draft.startTime}~${draft.endTime} 세션의 시간이 유효하지 않습니다.',
          );
          return;
        }
        if (draft.capacity <= 0) {
          SnackbarUtil.showError(
            context,
            '${draft.startTime}~${draft.endTime} 세션의 정원이 유효하지 않습니다.',
          );
          return;
        }

        courseSessions.add(
          CourseSession(
            dayOfWeek: dayOfWeek,
            startTime: draft.startTime,
            endTime: draft.endTime,
            capacity: draft.capacity,
          ),
        );
      }
    }

    // 코스 업데이트 (기존 코스의 모든 필드 유지, sessions만 업데이트)
    final updatedCourse = Course(
      id: widget.course.id,
      name: widget.course.name,
      description: widget.course.description,
      color: widget.course.color,
      imageUrl: widget.course.imageUrl,
      sessions: courseSessions,
      defaultTotalReservations: widget.course.defaultTotalReservations,
      useUniformSettings: widget.course.useUniformSettings,
      uniformTotalReservations: widget.course.uniformTotalReservations,
      uniformPeriodType: widget.course.uniformPeriodType,
      uniformPeriodValue: widget.course.uniformPeriodValue,
    );

    setState(() {
      _isSaving = true;
    });

    try {
      // ✅ 서버 중앙 검증 적용: 예약이 있는 세션 삭제/변경은 서버에서 차단
      await _firestoreService.updateCourseSchedule(
        placeId: currentPlace.id,
        courseId: updatedCourse.id,
        sessions: updatedCourse.sessions,
      );

      // 최신 코스 목록 새로고침
      await courseProvider.loadCourses(currentPlace.id);

      if (mounted) {
        SnackbarUtil.showSuccess(context, '일정이 저장되었습니다.');
        Navigator.of(context).pop(true); // 저장 성공을 알리기 위해 true 반환
      }
    } on FirebaseFunctionsException catch (e) {
      final details = e.details;
      final detailsMap = details is Map
          ? Map<String, dynamic>.from(details)
          : null;
      final requiresBulkMove = detailsMap?['requiresBulkMove'] == true;
      if (requiresBulkMove) {
        final dayOfWeek = (detailsMap?['dayOfWeek'] as num?)?.toInt();
        final startTime = detailsMap?['startTime'] as String?;

        // 예약이 있어서 삭제/변경할 수 없는 경우, 바로 일괄 취소 다이얼로그 표시
        if (dayOfWeek != null && startTime != null) {
          // 삭제/변경 대상 세션을 찾아 일괄 취소 플로우로 유도
          SessionDraft? target;
          final initial = _initialDaySessionsSnapshot[dayOfWeek] ?? const [];
          for (final s in initial) {
            if (s.startTime == startTime) {
              target = s;
              break;
            }
          }
          target ??= (_daySessions[dayOfWeek] ?? const [])
              .where((s) => s.startTime == startTime)
              .cast<SessionDraft?>()
              .firstWhere((s) => s != null, orElse: () => null);

          if (target != null) {
            await _showBulkMoveOption(dayOfWeek, target);
          } else {
            SnackbarUtil.showError(context, '대상 세션을 찾을 수 없습니다.');
          }
        } else {
          SnackbarUtil.showError(context, '예약이 있어서 삭제할 수 없습니다. 먼저 예약을 취소해주세요.');
        }
      } else {
        if (mounted) {
          SnackbarUtil.showError(context, e.message ?? '일정 저장에 실패했습니다.');
        }
      }
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showError(context, '일정 저장에 실패했습니다: ${e.toString()}');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  // 요일 편집 바텀시트
  void _showAddDayDialog() {
    const dayNames = ['', '월', '화', '수', '목', '금', '토', '일'];
    final allDays = List.generate(7, (i) => i + 1);

    // 원본 상태 저장 (취소 시 복원용)
    // 원본 세션 데이터 저장 (취소 시 복원용)
    final originalDaySessionsCopy = <int, List<SessionDraft>>{};
    for (final entry in _daySessions.entries) {
      originalDaySessionsCopy[entry.key] = List<SessionDraft>.from(entry.value);
    }
    // 원본 요일 목록 저장 (취소 시 복원용)
    final originalSelectedDays = Set<int>.from(_daySessions.keys);
    // 임시 선택 상태 (바텀시트에서만 사용)
    final tempSelectedDays = Set<int>.from(_daySessions.keys);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          // 변경사항 확인 함수
          bool hasDayChanges(Set<int> current, Set<int> original) {
            if (current.length != original.length) return true;
            return !current.every((day) => original.contains(day));
          }

          return Container(
            decoration: BoxDecoration(
              color: AppColors.backgroundWhite,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
            ),
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 헤더
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: AppColors.borderLight,
                          width: 0.5,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Text(
                          '요일 편집',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const Spacer(),
                        // 취소 버튼
                        TextButton(
                          onPressed: () {
                            // 원본 상태로 복원 (요일과 세션 데이터 모두)
                            setState(() {
                              _daySessions.clear();
                              // 원본 요일 목록으로 복원
                              for (final day in originalSelectedDays) {
                                if (originalDaySessionsCopy.containsKey(day)) {
                                  _daySessions[day] = List<SessionDraft>.from(
                                    originalDaySessionsCopy[day]!,
                                  );
                                } else {
                                  _daySessions[day] = [];
                                }
                              }
                            });
                            Navigator.pop(context);
                          },
                          child: Text(
                            '취소',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // 확인 버튼 (변경사항이 있을 때만 활성화)
                        FilledButton(
                          onPressed:
                              hasDayChanges(
                                tempSelectedDays,
                                originalSelectedDays,
                              )
                              ? () {
                                  // 변경사항 유지하고 닫기
                                  Navigator.pop(context);
                                }
                              : null,
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.primaryGreen,
                            disabledBackgroundColor: AppColors.borderLight,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            elevation: 0,
                          ),
                          child: Text(
                            '확인',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color:
                                  hasDayChanges(
                                    tempSelectedDays,
                                    originalSelectedDays,
                                  )
                                  ? Colors.white
                                  : AppColors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 요일 리스트 (원형 셀)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      alignment: WrapAlignment.start,
                      children: allDays.map((day) {
                        final isSelected = tempSelectedDays.contains(day);
                        final hasReservations = _hasReservationsForDay(day);
                        final isDisabled = hasReservations && !isSelected;

                        return GestureDetector(
                          onTap: isDisabled
                              ? null
                              : () {
                                  setModalState(() {
                                    if (isSelected) {
                                      tempSelectedDays.remove(day);
                                    } else {
                                      tempSelectedDays.add(day);
                                    }
                                  });

                                  // 미리보기로 캘린더 업데이트
                                  setState(() {
                                    // 선택 해제된 요일 제거 (미리보기)
                                    if (!tempSelectedDays.contains(day) &&
                                        _daySessions.containsKey(day)) {
                                      _daySessions.remove(day);
                                    }
                                    // 새로 선택된 요일 추가 (원본 데이터 복원 또는 빈 리스트)
                                    if (tempSelectedDays.contains(day) &&
                                        !_daySessions.containsKey(day)) {
                                      // 원본 데이터가 있으면 복원, 없으면 빈 리스트
                                      if (originalDaySessionsCopy.containsKey(
                                        day,
                                      )) {
                                        _daySessions[day] =
                                            List<SessionDraft>.from(
                                              originalDaySessionsCopy[day]!,
                                            );
                                      } else {
                                        _daySessions[day] = [];
                                      }
                                    }
                                  });
                                  // 변경사항 확인을 위해 setModalState 호출 (확인 버튼 상태 업데이트)
                                  setModalState(() {});
                                },
                          child: Container(
                            width: 60,
                            height: 60,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isSelected
                                  ? AppColors.primaryGreen
                                  : AppColors.backgroundLight,
                              border: Border.all(
                                color: isSelected
                                    ? AppColors.primaryGreen
                                    : (isDisabled
                                          ? AppColors.borderLight.withOpacity(
                                              0.5,
                                            )
                                          : AppColors.borderLight),
                                width: isSelected ? 2 : 1,
                              ),
                            ),
                            child: Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    dayNames[day],
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: isSelected
                                          ? Colors.white
                                          : (isDisabled
                                                ? AppColors.textSecondary
                                                      .withOpacity(0.5)
                                                : AppColors.textPrimary),
                                    ),
                                  ),
                                  if (isDisabled)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Icon(
                                        Icons.lock,
                                        size: 12,
                                        color: AppColors.textSecondary
                                            .withOpacity(0.5),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // Set 비교 헬퍼 함수
  bool _setsEqual<T>(Set<T> set1, Set<T> set2) {
    if (set1.length != set2.length) return false;
    return set1.every((item) => set2.contains(item));
  }

  // 변경사항이 있는지 확인
  bool _hasChanges() {
    // 요일이 추가/삭제되었는지 확인
    final originalDays = _initialDaySessionsSnapshot.keys.toSet();
    final currentDays = _daySessions.keys.toSet();
    final daysChanged = !_setsEqual(originalDays, currentDays);

    // 요일이 추가/삭제된 경우, 모든 현재 요일에 세션이 있는지 확인
    if (daysChanged) {
      // 현재 선택된 모든 요일에 세션이 있는지 확인
      for (final day in currentDays) {
        final sessions = _daySessions[day] ?? [];
        if (sessions.isEmpty) {
          // 하나라도 세션이 없으면 저장 불가
          return false;
        }
      }
      // 모든 요일에 세션이 있으면 저장 가능
      return true;
    }

    // 요일이 변경되지 않은 경우, 각 요일의 세션 데이터가 변경되었는지 확인
    for (final day in currentDays) {
      final originalSessions = _initialDaySessionsSnapshot[day] ?? [];
      final currentSessions = _daySessions[day] ?? [];

      // 세션 개수가 다르면 변경됨
      if (originalSessions.length != currentSessions.length) {
        return true;
      }

      // 각 세션의 내용이 변경되었는지 확인
      for (int i = 0; i < originalSessions.length; i++) {
        final original = originalSessions[i];
        final current = currentSessions[i];

        if (original.startTime != current.startTime ||
            original.endTime != current.endTime ||
            original.capacity != current.capacity) {
          return true;
        }
      }
    }

    return false;
  }
}
