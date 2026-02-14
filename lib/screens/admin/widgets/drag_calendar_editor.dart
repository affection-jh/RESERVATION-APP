import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:reservation/utils/timezone_utils.dart';
import '../../../theme/app_colors.dart';
import '../../../models/session_draft.dart';

/// 드래그 가능한 캘린더 에디터
class DragCalendarEditor extends StatefulWidget {
  final int dayOfWeek;
  final List<SessionDraft> sessions;
  // 드래그로 생성/수정이 막혀야 하는 세션들 (예: 정기 세션)
  final List<SessionDraft> blockedSessions;
  final List<SessionDraft>? previewSessions; // 미리보기 세션 (투명도 적용)
  final int defaultCapacity;
  final Color courseColor;
  final double? hourSlotHeight;
  final double? totalHeight;
  final ScrollController? scrollController;
  final Function(List<SessionDraft>) onSessionsChanged;
  final Function(bool)? onDragStateChanged;
  /// 빈 영역 터치 시 스크롤 막기 요청( true ), 손 떼면 해제( false ). 롱프레스 인식 전에 스크롤이 제스처를 가져가는 것 방지.
  final Function(bool)? onScrollBlockRequested;
  final Function(String startTime, String endTime, int dayOfWeek)? onDragEnd;
  final VoidCallback? onClearSelection;
  final Function(SessionDraft session)? onEditSession; // 기존 세션 편집 콜백
  final bool isEditMode; // 수정 모드 (기존 세션 수정 가능)
  final bool isRegularSession; // 정기일정 여부 (텍스트 표시용)
  final List<SessionDraft>? regularSessions; // 정기 세션 목록 (세션별 색상/동작 구분용)

  const DragCalendarEditor({
    super.key,
    required this.dayOfWeek,
    required this.sessions,
    this.blockedSessions = const <SessionDraft>[],
    this.previewSessions,
    required this.defaultCapacity,
    required this.courseColor,
    this.hourSlotHeight,
    this.totalHeight,
    this.scrollController,
    required this.onSessionsChanged,
    this.onDragStateChanged,
    this.onScrollBlockRequested,
    this.onDragEnd,
    this.onClearSelection,
    this.onEditSession,
    this.isEditMode = false,
    this.isRegularSession = false,
    this.regularSessions,
  });

  @override
  State<DragCalendarEditor> createState() => _DragCalendarEditorState();
}

class _DragCalendarEditorState extends State<DragCalendarEditor> {
  static const double _minHourSlotHeight = 60.0;
  static const double _sessionPadding = 2.0;

  bool _isDragging = false;
  int? _dragStartSlot;
  int? _dragEndSlot;
  bool _isBottomSheetOpen = false;
  Timer? _longPressTimer;
  Offset? _longPressStartPosition;

  ScrollController? _scrollController;
  bool _didInitialJump = false;

  @override
  void initState() {
    super.initState();
    _scrollController = widget.scrollController ?? ScrollController();
  }

  @override
  void dispose() {
    if (widget.scrollController == null) {
      _scrollController?.dispose();
    }
    _longPressTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final today = TimezoneUtils.getSeoulToday();
    final weekStart = today.subtract(Duration(days: today.weekday % 7));
    final targetDate = weekStart.add(Duration(days: widget.dayOfWeek - 1));
    final dates = [targetDate];

    if (widget.hourSlotHeight != null && widget.totalHeight != null) {
      final hourSlotHeight = widget.hourSlotHeight!;
      final totalHeight = widget.totalHeight!;
      final hours = List.generate(24, (i) => i);
      final timeSlots =
          hours.map((h) => '${h.toString().padLeft(2, '0')}:00').toList();
      final slotHeights = List<double>.filled(24, hourSlotHeight);
      final slotTops = List<double>.generate(25, (i) => i * hourSlotHeight);
      final active = List<bool>.filled(24, true);

      return SizedBox(
        height: totalHeight,
        child: _buildDayColumn(
          targetDate,
          timeSlots: timeSlots,
          rangeStartMinutes: 0,
          slotTops: slotTops,
          slotHeights: slotHeights,
          yForMinute: (minute) => (minute / 60.0) * hourSlotHeight,
          isActive: active,
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final smart = _computeSmartRange(
          dates: dates,
          viewportHeight: constraints.maxHeight,
        );
        final layout = _buildSlotLayout(
          dates: dates,
          smart: smart,
          viewportHeight: constraints.maxHeight,
        );

        if (!_didInitialJump && _scrollController != null) {
          _didInitialJump = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollController!.hasClients) {
              final targetMinute = layout.initialJumpMinute;
              final targetY = layout.yForMinute(targetMinute);
              _scrollController!.jumpTo(
                targetY.clamp(0.0, _scrollController!.position.maxScrollExtent),
              );
            }
          });
        }

        return SingleChildScrollView(
          controller: _scrollController,
          child: _buildDayColumn(
            targetDate,
            timeSlots: layout.timeSlots,
            rangeStartMinutes: smart.rangeStartMinutes,
            slotTops: layout.slotTops,
            slotHeights: layout.slotHeights,
            yForMinute: layout.yForMinute,
            isActive: layout.isActive,
          ),
        );
      },
    );
  }

  _SmartRange _computeSmartRange({
    required List<DateTime> dates,
    required double viewportHeight,
  }) {
    final rangeStart = 0;
    final rangeEnd = 24 * 60;
    final slotCount = 24;

    final hourSlotHeight = (viewportHeight / slotCount).clamp(
      _minHourSlotHeight,
      double.infinity,
    );

    return _SmartRange(
      rangeStartMinutes: rangeStart,
      rangeEndMinutes: rangeEnd,
      startHour: 0,
      endHour: 24,
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
    final active = List<bool>.filled(timeSlots.length, true);
    final baseSlotHeight = smart.hourSlotHeight;
    final slotHeights = List<double>.filled(timeSlots.length, baseSlotHeight);

    final slotTops = List<double>.filled(timeSlots.length + 1, 0.0);
    for (int i = 0; i < timeSlots.length; i++) {
      slotTops[i + 1] = slotTops[i] + slotHeights[i];
    }

    final initialJumpMinute = 9 * 60;

    return _SlotLayout(
      timeSlots: timeSlots,
      slotHeights: slotHeights,
      slotTops: slotTops,
      rangeStartMinutes: rangeStartMinutes,
      initialJumpMinute: initialJumpMinute,
      isActive: active,
    );
  }

  Widget _buildDayColumn(
    DateTime date, {
    required List<String> timeSlots,
    required int rangeStartMinutes,
    required List<double> slotTops,
    required List<double> slotHeights,
    required double Function(int minute) yForMinute,
    required List<bool> isActive,
  }) {
    final totalHeight = slotTops.isNotEmpty ? slotTops.last : 0.0;

    // IMPORTANT:
    // - 배경 Container(테두리/그리드)이 hitTest를 먹어버리면 아래 레이어(예: 비정기 DragCalendarEditor)로
    //   포인터가 전달되지 않아 "정기 일정 있는 날은 드래그가 안 됨" 문제가 생김.
    // - 따라서 배경은 IgnorePointer로 감싸서 hitTest에서 제외하고, 세션 블록(클릭)은 그대로 유지.
    return SizedBox(
      height: totalHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              ignoring: true,
              child: Container(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: AppColors.borderLight, width: 0.5),
        ),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ...timeSlots.asMap().entries.map((entry) {
            final index = entry.key;
            final isActiveSlot = isActive[index];
            return Positioned(
              top: slotTops[index] + 1.0,
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
                  ],
                ),
              ),
            ),
          ),
          // 드래그 영역을 먼저 배치 (세션 블록 아래)
          if (widget.isEditMode)
          _buildDraggableArea(
            date,
            rangeStartMinutes: rangeStartMinutes,
            yForMinute: yForMinute,
            totalHeight: totalHeight,
          ),
          ...widget.sessions.map((session) {
            return _buildSessionBlock(
              session,
              date,
              rangeStartMinutes: rangeStartMinutes,
              yForMinute: yForMinute,
              isPreview: false,
            );
          }).toList(),
          // 미리보기 세션 (투명도 적용)
          if (widget.previewSessions != null)
            ...widget.previewSessions!.map((session) {
              return _buildSessionBlock(
                session,
                date,
                rangeStartMinutes: rangeStartMinutes,
                yForMinute: yForMinute,
                isPreview: true,
              );
            }).toList(),
          if ((_isDragging || _isBottomSheetOpen) &&
              _dragStartSlot != null &&
              _dragEndSlot != null)
            _buildDragSelection(
              rangeStartMinutes: rangeStartMinutes,
              yForMinute: yForMinute,
            ),
        ],
      ),
    );
  }

  Widget _buildSessionBlock(
    SessionDraft session,
    DateTime date, {
    required int rangeStartMinutes,
    required double Function(int minute) yForMinute,
    bool isPreview = false,
  }) {
    final sessionStartMinutes = _parseTimeToMinutes(session.startTime);
    final sessionEndMinutes = _parseTimeToMinutes(session.endTime);
    final topPosition = yForMinute(sessionStartMinutes) + 1.0;
    final sessionHeightPx = (yForMinute(sessionEndMinutes) -
            yForMinute(sessionStartMinutes))
        .clamp(0.0, double.infinity);

    // 정기 세션인지 확인
    final isRegular =
        widget.regularSessions != null &&
        widget.regularSessions!.any(
          (r) =>
              r.startTime == session.startTime && r.endTime == session.endTime,
        );

    // 정기 세션이면 회색, 비정기 세션이면 코스 색상
    final sessionColor = isRegular ? Colors.grey[400]! : widget.courseColor;

    // 세션 위젯 내용
    Widget sessionContent = Container(
      padding: EdgeInsets.symmetric(
        horizontal: 8,
        vertical: sessionHeightPx >= 50 ? 4 : 2,
      ),
      decoration: BoxDecoration(
        color: isPreview ? sessionColor.withOpacity(0.3) : sessionColor,
        borderRadius: BorderRadius.circular(8),
        boxShadow:
            isPreview
                ? []
                : [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
      ),
      child: Builder(
        builder: (context) {
          // 배경색 밝기에 따라 텍스트 색상 동적 결정
          // opacity가 적용된 색상의 실제 밝기를 계산하기 위해
          // 배경이 흰색이라고 가정하고 블렌딩된 색상의 밝기 계산
          final backgroundColor = AppColors.backgroundWhite;
          final actualBlockColor =
              isPreview ? sessionColor.withOpacity(0.3) : sessionColor;
          final blendedColor = Color.alphaBlend(
            actualBlockColor,
            backgroundColor,
          );
          final luminance = blendedColor.computeLuminance();

          // 밝기에 따라 텍스트 색상 결정 (밝으면 검정, 어두우면 흰색)
          final textColor =
              luminance > 0.5 ? AppColors.textPrimary : Colors.white;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isRegular) ...[
                Text(
                  '정기일정',
                  style: TextStyle(
                    color: textColor,
                    fontSize: sessionHeightPx >= 60 ? 13 : 11,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (sessionHeightPx >= 50) const SizedBox(height: 2),
              ],
              Text(
                '${session.startTime} - ${session.endTime}',
                style: TextStyle(
                  color: textColor,
                  fontSize: sessionHeightPx >= 60 ? 15 : 13,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (sessionHeightPx >= 70) ...[
                const SizedBox(height: 4),
                Text(
                  '${session.capacity}명',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: textColor.withOpacity(0.9),
                    fontSize: sessionHeightPx >= 90 ? 17 : 14,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );

    // 일반 모드 (기존 로직)
    // 정기 일정의 경우 세션 블록만 포인터 이벤트를 받고, 나머지 영역은 통과
    return Positioned(
      top: topPosition,
      left: _sessionPadding,
      right: _sessionPadding,
      height: sessionHeightPx,
      child: GestureDetector(
        // 세션 블록이 드래그 영역 위에 있으므로, 항상 opaque로 설정하여 클릭 이벤트를 받음
        behavior: HitTestBehavior.opaque,
        onTap: isPreview ? null : () => widget.onEditSession?.call(session),
        child: sessionContent,
      ),
    );
  }

  Widget _buildDraggableArea(
    DateTime date, {
    required int rangeStartMinutes,
    required double Function(int minute) yForMinute,
    required double totalHeight,
  }) {
    return Positioned.fill(
      child: Listener(
        // 세션 블록의 클릭을 통과시키기 위해 translucent 사용
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) {
          final y = event.localPosition.dy;
          final isOnSession = _isPointerOnSession(
            y,
            rangeStartMinutes,
            yForMinute,
          );
          debugPrint(
            '[DragCalendarEditor] onPointerDown day=${widget.dayOfWeek} dy=$y isOnSession=$isOnSession',
          );

          if (!isOnSession) {
            debugPrint(
              '[DragCalendarEditor] 빈 영역 터치 → 500ms 타이머만 시작 (스크롤은 롱프레스 인식 후에만 막음)',
            );
            _longPressStartPosition = event.localPosition;
            _longPressTimer?.cancel();
            _longPressTimer = Timer(const Duration(milliseconds: 500), () {
              if (_longPressStartPosition != null) {
                debugPrint('[DragCalendarEditor] 롱프레스 500ms 완료 → 드래그 시작');
                final slot = _getSlotFromPosition(
                  _longPressStartPosition!.dy,
                  rangeStartMinutes,
                  yForMinute,
                );
                setState(() {
                  _isDragging = true;
                  _dragStartSlot = slot;
                  _dragEndSlot = slot;
                });
                widget.onDragStateChanged?.call(true);
              }
            });
          }
        },
        onPointerMove: (event) {
          if (_isDragging && _longPressStartPosition != null) {
            debugPrint(
              '[DragCalendarEditor] onPointerMove (드래그 중) dy=${event.localPosition.dy}',
            );
            final slot = _getSlotFromPosition(
              event.localPosition.dy,
              rangeStartMinutes,
              yForMinute,
            );
            // 드래그 중에도 겹침 체크
            final startSlot = _dragStartSlot! < slot ? _dragStartSlot! : slot;
            final endSlot = _dragStartSlot! > slot ? _dragStartSlot! : slot;
            if (endSlot - startSlot >= 1) {
              final startMinutes = rangeStartMinutes + (startSlot * 30);
              final endMinutes = rangeStartMinutes + ((endSlot + 1) * 30);
              final startTime = _minutesToTime(startMinutes);
              final endTime = _minutesToTime(endMinutes);

              // 겹침이 있으면 드래그 중단
              if (_hasOverlap(startTime, endTime)) {
                setState(() {
                  _isDragging = false;
                  _dragStartSlot = null;
                  _dragEndSlot = null;
                });
                widget.onDragStateChanged?.call(false);
                _longPressTimer?.cancel();
                _longPressStartPosition = null;
                return;
              }
            }
            setState(() {
              _dragEndSlot = slot;
            });
          } else if (!_isDragging) {
            debugPrint(
              '[DragCalendarEditor] onPointerMove (드래그 아님) → 타이머 취소',
            );
            _longPressTimer?.cancel();
            _longPressStartPosition = null;
          }
        },
        onPointerUp: (event) {
          debugPrint(
            '[DragCalendarEditor] onPointerUp _isDragging=$_isDragging',
          );
          _longPressTimer?.cancel();
          if (_isDragging) {
            _endDrag(rangeStartMinutes, yForMinute);
          }
          _longPressStartPosition = null;
          widget.onScrollBlockRequested?.call(false);
        },
        onPointerCancel: (event) {
          debugPrint('[DragCalendarEditor] onPointerCancel');
          _longPressTimer?.cancel();
          setState(() {
            _isDragging = false;
            _dragStartSlot = null;
            _dragEndSlot = null;
          });
          widget.onDragStateChanged?.call(false);
          _longPressStartPosition = null;
          widget.onScrollBlockRequested?.call(false);
        },
        child: Container(color: Colors.transparent),
      ),
    );
  }

  Widget _buildDragSelection({
    required int rangeStartMinutes,
    required double Function(int minute) yForMinute,
  }) {
    if (_dragStartSlot == null || _dragEndSlot == null) {
      return const SizedBox.shrink();
    }

    final startSlot =
        _dragStartSlot! < _dragEndSlot! ? _dragStartSlot! : _dragEndSlot!;
    final endSlot =
        _dragStartSlot! > _dragEndSlot! ? _dragStartSlot! : _dragEndSlot!;

    final startMinutes = rangeStartMinutes + (startSlot * 30);
    final endMinutes = rangeStartMinutes + ((endSlot + 1) * 30);

    final top = yForMinute(startMinutes) + 1.0;
    final height = (yForMinute(endMinutes) - yForMinute(startMinutes)).clamp(
      0.0,
      double.infinity,
    );

    return Positioned(
      top: top,
      left: _sessionPadding,
      right: _sessionPadding,
      height: height,
      child: Container(
        decoration: BoxDecoration(
          color: widget.courseColor.withOpacity(0.2),
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }

  void _endDrag(int rangeStartMinutes, double Function(int minute) yForMinute) {
    if (!_isDragging || _dragStartSlot == null || _dragEndSlot == null) {
      setState(() {
        _isDragging = false;
        _dragStartSlot = null;
        _dragEndSlot = null;
      });
      widget.onDragStateChanged?.call(false);
      return;
    }

    final startSlot =
        _dragStartSlot! < _dragEndSlot! ? _dragStartSlot! : _dragEndSlot!;
    final endSlot =
        _dragStartSlot! > _dragEndSlot! ? _dragStartSlot! : _dragEndSlot!;

    if (endSlot - startSlot < 1) {
      setState(() {
        _isDragging = false;
        _dragStartSlot = null;
        _dragEndSlot = null;
      });
      widget.onDragStateChanged?.call(false);
      return;
    }

    final startMinutes = rangeStartMinutes + (startSlot * 30);
    final endMinutes = rangeStartMinutes + ((endSlot + 1) * 30);

    final startTime = _minutesToTime(startMinutes);
    final endTime = _minutesToTime(endMinutes);

    // 겹침 체크
    if (_hasOverlap(startTime, endTime)) {
      setState(() {
        _isDragging = false;
        _dragStartSlot = null;
        _dragEndSlot = null;
      });
      widget.onDragStateChanged?.call(false);
      // 겹침 경고 표시 (선택사항)
      return;
    }

    setState(() {
      _isDragging = false;
      _isBottomSheetOpen = true;
      // _dragStartSlot과 _dragEndSlot은 유지
    });
    widget.onDragStateChanged?.call(false);

    // 바텀시트 열기
    widget.onDragEnd?.call(startTime, endTime, widget.dayOfWeek);
  }

  // 겹침 체크
  bool _hasOverlap(String startTime, String endTime) {
    final newStart = _parseTimeToMinutes(startTime);
    final newEnd = _parseTimeToMinutes(endTime);

    for (final session in <SessionDraft>[
      ...widget.sessions,
      ...widget.blockedSessions,
    ]) {
      final sessionStart = _parseTimeToMinutes(session.startTime);
      final sessionEnd = _parseTimeToMinutes(session.endTime);

      // 겹침 체크: 새 세션이 기존 세션과 겹치는지
      if (newStart < sessionEnd && newEnd > sessionStart) {
        return true;
      }
    }
    return false;
  }

  void clearSelection() {
    setState(() {
      _isDragging = false;
      _isBottomSheetOpen = false;
      _dragStartSlot = null;
      _dragEndSlot = null;
      _longPressStartPosition = null;
    });
    _longPressTimer?.cancel();
    widget.onDragStateChanged?.call(false);
  }

  // 포인터가 세션 블록 위에 있는지 확인
  bool _isPointerOnSession(
    double y,
    int rangeStartMinutes,
    double Function(int minute) yForMinute,
  ) {
    for (final session in widget.sessions) {
      final sessionStartMinutes = _parseTimeToMinutes(session.startTime);
      final sessionEndMinutes = _parseTimeToMinutes(session.endTime);
      final topPosition = yForMinute(sessionStartMinutes) + 1.0;
      final bottomPosition = yForMinute(sessionEndMinutes);

      if (y >= topPosition && y <= bottomPosition) {
        return true;
      }
    }
    return false;
  }

  int _getSlotFromPosition(
    double y,
    int rangeStartMinutes,
    double Function(int minute) yForMinute,
  ) {
    int bestSlot = 0;
    double minDiff = double.infinity;

    for (int slot = 0; slot < 48; slot++) {
      final minutes = rangeStartMinutes + (slot * 30);
      final slotY = yForMinute(minutes);
      final diff = (y - slotY).abs();
      if (diff < minDiff) {
        minDiff = diff;
        bestSlot = slot;
      }
    }

    return bestSlot;
  }

  int _parseTimeToMinutes(String time) {
    final parts = time.split(':');
    final hour = int.parse(parts[0]);
    final minute = int.parse(parts[1]);
    return hour * 60 + minute;
  }

  String _minutesToTime(int minutes) {
    final hour = (minutes ~/ 60) % 24;
    final minute = minutes % 60;
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

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
  final List<double> slotHeights;
  final List<double> slotTops;
  final int rangeStartMinutes;
  final int initialJumpMinute;
  final List<bool> isActive;

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
