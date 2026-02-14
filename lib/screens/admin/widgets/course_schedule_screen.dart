import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../theme/app_colors.dart';
import '../../../models/course.dart' as reservation_models;
import '../utils/admin_utils.dart';
import 'course_color_selection_screen.dart';
import 'drag_calendar_editor.dart';
import 'session_edit_bottom_sheet.dart';
import '../../../models/session_draft.dart';
import '../../../utils/snackbar_util.dart';

/// 코스 시간표 설정 화면 (3단계)
class CourseScheduleScreen extends StatefulWidget {
  final CourseColorSelectionData colorSelectionData;
  final reservation_models.Course? existingCourse;
  final Map<int, List<SessionDraft>>? savedDaySessions; // 저장된 세션 데이터
  final int? savedDefaultCapacity; // 저장된 수용인원
  final Function(Map<int, List<SessionDraft>>, int)?
  onSessionsChanged; // 세션 변경 콜백
  final Function(reservation_models.Course) onComplete;

  const CourseScheduleScreen({
    super.key,
    required this.colorSelectionData,
    this.existingCourse,
    this.savedDaySessions,
    this.savedDefaultCapacity,
    this.onSessionsChanged,
    required this.onComplete,
  });

  @override
  State<CourseScheduleScreen> createState() => _CourseScheduleScreenState();
}

class _CourseScheduleScreenState extends State<CourseScheduleScreen> {
  static const double _minHourSlotHeight = 80.0;

  // 2단계 데이터
  late Map<int, List<SessionDraft>> _daySessions; // {dayOfWeek: [sessions]}
  late int _defaultCapacity; // 일괄 수용인원 (처음은 -1, 이후 사용자 입력값 기억)

  // 드래그 상태 추적 (롱프레스 중 스크롤 방지용)
  bool _isAnyDragging = false;
  bool _didInitialJump = false;
  ScrollController? _calendarScrollController;

  // 각 요일의 DragCalendarEditor에 접근하기 위한 GlobalKey
  final Map<int, GlobalKey> _calendarEditorKeys = {};
  final GlobalKey _dragAreaKey = GlobalKey();

  // 일괄등록 미리보기용 임시 세션 (바텀시트가 열려있을 때만 사용)
  String? _previewStartTime;
  String? _previewEndTime;
  int? _previewDayOfWeek;
  bool _isBulkPreview = false;

  @override
  void initState() {
    super.initState();
    _calendarScrollController = ScrollController();

    // 저장된 세션 데이터가 있으면 사용, 없으면 초기화
    if (widget.savedDaySessions != null) {
      _daySessions = Map.from(widget.savedDaySessions!);
      _defaultCapacity = widget.savedDefaultCapacity ?? -1;
    } else {
      _daySessions = {};
      _defaultCapacity = -1;

      // 기존 코스가 있으면 세션 데이터 로드
      if (widget.existingCourse != null) {
        for (final session in widget.existingCourse!.sessions) {
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
      }
    }
  }

  @override
  void dispose() {
    _calendarScrollController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      body: SafeArea(
        child: Column(
          children: [
            // 헤더
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
              color: AppColors.backgroundWhite,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back_ios, size: 24),
                        onPressed: () => Navigator.of(context).pop(),
                        color: AppColors.textPrimary,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '정기 시간표 설정',
                              style: TextStyle(
                                fontSize: 17,
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              '길게 눌러서 등록할 시간에 드래그하기',
                              style: TextStyle(
                                fontSize: 14,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
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
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              // 각 요일 헤더
                              ...(widget.colorSelectionData.selectedDays
                                      .toList()
                                    ..sort())
                                  .map((day) {
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
                                  })
                                  .toList(),
                            ],
                          ),
                        ),
                        // 모든 요일의 캘린더를 동시에 표시
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              return _buildAllDaysCalendar(
                                constraints.maxHeight,
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
            // 하단 버튼
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.backgroundWhite,
                border: Border(
                  top: BorderSide(color: AppColors.borderLight, width: 0.5),
                ),
              ),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isFormValid() ? () => _complete() : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryGreen,
                    disabledBackgroundColor: AppColors.borderLight,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    elevation: 0,
                  ),
                  child: const Text(
                    '다음',
                    style: TextStyle(
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
    );
  }

  // 모든 요일의 캘린더를 동시에 표시
  Widget _buildAllDaysCalendar(double viewportHeight) {
    final selectedDaysList =
        widget.colorSelectionData.selectedDays.toList()..sort();
    if (selectedDaysList.isEmpty) {
      return const Center(child: Text('요일을 선택해주세요.'));
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
          // 9시 위치로 점프 (9 * hourSlotHeight)
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
              // 각 요일의 캘린더 (세로 스크롤은 바깥 SingleChildScrollView 하나만 사용 → 롱프레스 드래그 인식 보장)
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children:
                      selectedDaysList.map((day) {
                        return SizedBox(
                          width:
                              (MediaQuery.of(context).size.width - 35) /
                              selectedDaysList.length,
                          child: _buildDayScheduleEditor(
                            day,
                            hourSlotHeight: hourSlotHeight,
                            totalHeight: totalHeight,
                            scrollController: _calendarScrollController!,
                            dragAreaKey: _dragAreaKey,
                            onDragStateChanged: (isDragging) {
                              debugPrint(
                                '[CourseScheduleScreen] onDragStateChanged($isDragging)',
                              );
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

  Widget _buildDayScheduleEditor(
    int dayOfWeek, {
    required double hourSlotHeight,
    required double totalHeight,
    required ScrollController scrollController,
    required GlobalKey dragAreaKey,
    required Function(bool) onDragStateChanged,
  }) {
    final sessions = _daySessions[dayOfWeek] ?? [];

    // 미리보기 세션 목록
    List<SessionDraft>? previewSessions;
    if (_previewStartTime != null &&
        _previewEndTime != null &&
        _previewDayOfWeek != null) {
      if (_isBulkPreview &&
          widget.colorSelectionData.selectedDays.contains(dayOfWeek)) {
        // 일괄등록 미리보기: 모든 선택된 요일에 표시
        previewSessions = [
          SessionDraft(
            startTime: _previewStartTime!,
            endTime: _previewEndTime!,
            capacity: _defaultCapacity == -1 ? 0 : _defaultCapacity,
          ),
        ];
      } else if (!_isBulkPreview && dayOfWeek == _previewDayOfWeek) {
        // 단일 요일 미리보기: 현재 요일만 표시
        previewSessions = [
          SessionDraft(
            startTime: _previewStartTime!,
            endTime: _previewEndTime!,
            capacity: _defaultCapacity == -1 ? 0 : _defaultCapacity,
          ),
        ];
      }
    }

    // GlobalKey가 없으면 생성
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
        previewSessions: previewSessions,
        defaultCapacity: _defaultCapacity,
        courseColor: Color(widget.colorSelectionData.selectedColor),
        hourSlotHeight: hourSlotHeight,
        totalHeight: totalHeight,
        scrollController: scrollController,
        dragAreaKey: dragAreaKey,
        isEditMode: true, // 드래그 영역(Listener) 렌더링 → 길게 눌러서 세션 추가
        onSessionsChanged: (newSessions) {
          setState(() {
            _daySessions[dayOfWeek] = newSessions;
            // 세션 변경 시 콜백 호출
            widget.onSessionsChanged?.call(_daySessions, _defaultCapacity);
          });
        },
        onDragStateChanged: onDragStateChanged,
        onScrollBlockRequested: (block) {
          debugPrint(
            '[CourseScheduleScreen] onScrollBlockRequested($block) → _isAnyDragging=$block',
          );
          setState(() {
            _isAnyDragging = block;
          });
        },
        onDragEnd: (startTime, endTime, day) {
          // 미리보기 초기화
          setState(() {
            _previewStartTime = null;
            _previewEndTime = null;
            _previewDayOfWeek = null;
            _isBulkPreview = false;
          });
          _showSessionEditBottomSheet(startTime, endTime, day);
        },
        onEditSession: (session) {
          _showSessionEditBottomSheet(
            session.startTime,
            session.endTime,
            dayOfWeek,
            existingSession: session,
          );
        },
      ),
    );
  }

  void _clearSelectionForDay(int dayOfWeek) {
    final key = _calendarEditorKeys[dayOfWeek];
    if (key?.currentState != null) {
      (key!.currentState as dynamic).clearSelection();
    }
  }

  void _showSessionEditBottomSheet(
    String startTime,
    String endTime,
    int dayOfWeek, {
    SessionDraft? existingSession,
  }) {
    final isEditMode = existingSession != null;
    final existingSessionsForDay = _daySessions[dayOfWeek] ?? [];

    // 미리보기 초기화
    setState(() {
      _previewStartTime = startTime;
      _previewEndTime = endTime;
      _previewDayOfWeek = dayOfWeek;
      _isBulkPreview = false;
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
              courseName: widget.colorSelectionData.basicInfo.name,
              dayOfWeek: dayOfWeek,
              selectedDays: widget.colorSelectionData.selectedDays,
              courseColor: Color(widget.colorSelectionData.selectedColor),
              canBulkCancel: false,
              existingSessions: existingSessionsForDay,
              allDaySessions: _daySessions, // 모든 요일의 세션 정보 전달 (일괄 적용 가능 여부 확인용)
              isEditMode: isEditMode,
              onBulkRegistrationChanged: (isBulkRegistration) {
                setState(() {
                  _isBulkPreview = isBulkRegistration;
                  _previewStartTime = startTime;
                  _previewEndTime = endTime;
                  _previewDayOfWeek = dayOfWeek;
                });
              },
              onCancel: () {
                // 미리보기 초기화
                setState(() {
                  _previewStartTime = null;
                  _previewEndTime = null;
                  _previewDayOfWeek = null;
                  _isBulkPreview = false;
                });
                // 선택 영역 초기화
                _clearSelectionForDay(dayOfWeek);
              },
              onRegister: (newStartTime, newEndTime, capacity, bulkDays) {
                setState(() {
                  // 미리보기 초기화
                  _previewStartTime = null;
                  _previewEndTime = null;
                  _previewDayOfWeek = null;
                  _isBulkPreview = false;

                  // 수용인원 기억
                  _defaultCapacity = capacity;

                  // 일괄 적용 처리 (등록/수정 모두)
                  if (bulkDays != null && bulkDays.isNotEmpty) {
                    if (isEditMode) {
                      // 수정 모드: 모든 요일에 동일하게 적용
                      for (final bulkDay in bulkDays) {
                        if (!_daySessions.containsKey(bulkDay)) {
                          _daySessions[bulkDay] = [];
                        }
                        final sessions = _daySessions[bulkDay] ?? [];

                        // 기존 세션 찾기 (동일 시간대)
                        final existingIndex = sessions.indexWhere((session) {
                          return session.startTime == startTime &&
                              session.endTime == endTime;
                        });

                        if (existingIndex != -1) {
                          // 기존 세션 수정 (겹침 방지)
                          final temp = List<SessionDraft>.from(sessions);
                          temp[existingIndex] = SessionDraft(
                            startTime: newStartTime,
                            endTime: newEndTime,
                            capacity: capacity,
                          );
                          final hasOverlap = _hasAnyOverlapInDay(temp);
                          if (!hasOverlap) {
                            sessions[existingIndex] = temp[existingIndex];
                          }
                        } else {
                          // 새 세션 추가 (겹침 체크)
                          if (!_hasOverlap(bulkDay, newStartTime, newEndTime)) {
                            sessions.add(
                              SessionDraft(
                                startTime: newStartTime,
                                endTime: newEndTime,
                                capacity: capacity,
                              ),
                            );
                          }
                        }
                        _daySessions[bulkDay] = sessions;
                      }
                    } else {
                      // 등록 모드: 겹치지 않는 요일에만 추가
                      for (final bulkDay in bulkDays) {
                        if (!_daySessions.containsKey(bulkDay)) {
                          _daySessions[bulkDay] = [];
                        }
                        // 겹침 체크
                        if (!_hasOverlap(bulkDay, newStartTime, newEndTime)) {
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
                    widget.onSessionsChanged?.call(
                      _daySessions,
                      _defaultCapacity,
                    );
                    return;
                  }

                  if (isEditMode) {
                    // 기존 세션 수정 (단일 요일)
                    final sessions = _daySessions[dayOfWeek] ?? [];
                    final index = sessions.indexOf(existingSession);
                    if (index != -1) {
                      final temp = List<SessionDraft>.from(sessions);
                      temp[index] = SessionDraft(
                        startTime: newStartTime,
                        endTime: newEndTime,
                        capacity: capacity,
                      );
                      if (!_hasAnyOverlapInDay(temp)) {
                        sessions[index] = temp[index];
                        _daySessions[dayOfWeek] = sessions;
                      }
                    }
                  } else {
                    // 새 세션 추가 (단일 요일)
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
                  // 세션 변경 시 콜백 호출 (단일 요일)
                  widget.onSessionsChanged?.call(
                    _daySessions,
                    _defaultCapacity,
                  );
                });
                // 선택 영역 초기화
                _clearSelectionForDay(dayOfWeek);
              },
              onDelete:
                  isEditMode
                      ? (bulkDays) {
                        setState(() {
                          // 미리보기 초기화
                          _previewStartTime = null;
                          _previewEndTime = null;
                          _previewDayOfWeek = null;
                          _isBulkPreview = false;
                          // 단일 삭제만 지원 (일괄 삭제 제거)
                          final sessions = _daySessions[dayOfWeek] ?? [];
                          sessions.remove(existingSession);
                          _daySessions[dayOfWeek] = sessions;
                        });
                        widget.onSessionsChanged?.call(
                          _daySessions,
                          _defaultCapacity,
                        );
                        // 선택 영역 초기화
                        _clearSelectionForDay(dayOfWeek);
                      }
                      : null,
            ),
          ),
    ).then((_) {
      // 바텀시트가 닫힐 때 (dismissed) 미리보기 및 선택 영역 초기화
      setState(() {
        _previewStartTime = null;
        _previewEndTime = null;
        _previewDayOfWeek = null;
        _isBulkPreview = false;
      });
      _clearSelectionForDay(dayOfWeek);
    });
  }

  // 겹침 체크
  bool _hasOverlap(int dayOfWeek, String startTime, String endTime) {
    final sessions = _daySessions[dayOfWeek] ?? [];
    final newStart = _parseTimeToMinutes(startTime);
    final newEnd = _parseTimeToMinutes(endTime);

    for (final session in sessions) {
      final sessionStart = _parseTimeToMinutes(session.startTime);
      final sessionEnd = _parseTimeToMinutes(session.endTime);

      // 겹침 체크: 새 세션이 기존 세션과 겹치는지
      if (newStart < sessionEnd && newEnd > sessionStart) {
        return true;
      }
    }
    return false;
  }

  bool _hasAnyOverlapInDay(List<SessionDraft> sessions) {
    for (int i = 0; i < sessions.length; i++) {
      final aStart = _parseTimeToMinutes(sessions[i].startTime);
      final aEnd = _parseTimeToMinutes(sessions[i].endTime);
      for (int j = i + 1; j < sessions.length; j++) {
        final bStart = _parseTimeToMinutes(sessions[j].startTime);
        final bEnd = _parseTimeToMinutes(sessions[j].endTime);
        if (aStart < bEnd && aEnd > bStart) return true;
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

  bool _isFormValid() {
    // 선택된 모든 요일에 적어도 하나씩 세션이 등록되어 있는지 확인
    final selectedDaysList = widget.colorSelectionData.selectedDays.toList();
    if (selectedDaysList.isEmpty) {
      return false;
    }

    for (final day in selectedDaysList) {
      final sessions = _daySessions[day] ?? [];
      if (sessions.isEmpty) {
        return false;
      }
    }

    return true;
  }

  void _complete() {
    final name = widget.colorSelectionData.basicInfo.name.trim();
    if (name.isEmpty) {
      SnackbarUtil.showInfo(context, '코스명을 입력해주세요.');
      return;
    }

    if (!_isFormValid()) {
      SnackbarUtil.showInfo(context, '모든 선택된 요일에 최소 하나의 세션을 추가해주세요.');
      return;
    }

    // 세션 생성
    final courseSessions = <reservation_models.CourseSession>[];
    for (final entry in _daySessions.entries) {
      for (final draft in entry.value) {
        courseSessions.add(
          reservation_models.CourseSession(
            dayOfWeek: entry.key,
            startTime: draft.startTime,
            endTime: draft.endTime,
            capacity: draft.capacity,
          ),
        );
      }
    }

    final course = reservation_models.Course(
      id: widget.existingCourse?.id ?? newId('course'),
      name: name,
      description: widget.colorSelectionData.basicInfo.description,
      color: widget.colorSelectionData.selectedColor,
      sessions: courseSessions,
      imageUrl: widget.colorSelectionData.basicInfo.imageUrl,
      defaultTotalReservations:
          widget.colorSelectionData.defaultTotalReservations,
      useUniformSettings: widget.colorSelectionData.useUniformSettings,
      uniformTotalReservations:
          widget.colorSelectionData.uniformTotalReservations,
      uniformPeriodType: widget.colorSelectionData.uniformPeriodType,
      uniformPeriodValue: widget.colorSelectionData.uniformPeriodValue,
    );

    // 코스를 바로 저장하지 않고 정책 설정 화면으로 이동
    widget.onComplete(course);
  }
}
