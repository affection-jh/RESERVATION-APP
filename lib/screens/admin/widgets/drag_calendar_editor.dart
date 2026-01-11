import 'dart:async';
import 'package:flutter/material.dart';
import 'package:reservation/utils/timezone_utils.dart';
import '../../../theme/app_colors.dart';
import '../../../models/session_draft.dart';
import '../../../widgets/course_color_picker_bottom_sheet.dart';

/// 드래그 가능한 캘린더 에디터
class DragCalendarEditor extends StatefulWidget {
  final int dayOfWeek;
  final List<SessionDraft> sessions;
  final List<SessionDraft>? previewSessions; // 미리보기 세션 (투명도 적용)
  final int defaultCapacity;
  final Color courseColor;
  final double? hourSlotHeight;
  final double? totalHeight;
  final ScrollController? scrollController;
  final Function(List<SessionDraft>) onSessionsChanged;
  final Function(bool)? onDragStateChanged;
  final Function(String startTime, String endTime, int dayOfWeek)? onDragEnd;
  final VoidCallback? onClearSelection;
  final Function(SessionDraft session)? onEditSession; // 기존 세션 편집 콜백
  final bool isEditMode; // 수정 모드 (기존 세션 수정 가능)

  const DragCalendarEditor({
    super.key,
    required this.dayOfWeek,
    required this.sessions,
    this.previewSessions,
    required this.defaultCapacity,
    required this.courseColor,
    this.hourSlotHeight,
    this.totalHeight,
    this.scrollController,
    required this.onSessionsChanged,
    this.onDragStateChanged,
    this.onDragEnd,
    this.onClearSelection,
    this.onEditSession,
    this.isEditMode = false,
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
      final timeSlots = hours
          .map((h) => '${h.toString().padLeft(2, '0')}:00')
          .toList();
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
          ...timeSlots.asMap().entries.map((entry) {
            final index = entry.key;
            final isActiveSlot = isActive[index];
            return Positioned(
              top: slotTops[index] + 1.0,
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
    final sessionHeightPx =
        (yForMinute(sessionEndMinutes) - yForMinute(sessionStartMinutes)).clamp(
          0.0,
          double.infinity,
        );

    // 세션 위젯 내용
    Widget sessionContent = Container(
      padding: EdgeInsets.symmetric(
        horizontal: 8,
        vertical: sessionHeightPx >= 50 ? 4 : 2,
      ),
      decoration: BoxDecoration(
        color: isPreview
            ? widget.courseColor.withOpacity(0.3)
            : widget.courseColor,
        borderRadius: BorderRadius.circular(8),
        boxShadow: isPreview
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
          // 색상 팔레트에서 정의된 onColor 사용 (원본 색상 기준)
          final textColor = CourseColorPickerBottomSheet.getOnColorForColor(
            widget.courseColor.value,
          );

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
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
    return Positioned(
      top: topPosition,
      left: _sessionPadding,
      right: _sessionPadding,
      height: sessionHeightPx,
      child: GestureDetector(
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
        onPointerDown: (event) {
          _longPressStartPosition = event.localPosition;
          _longPressTimer?.cancel();
          _longPressTimer = Timer(const Duration(milliseconds: 500), () {
            if (_longPressStartPosition != null) {
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
        },
        onPointerMove: (event) {
          if (_isDragging && _longPressStartPosition != null) {
            final slot = _getSlotFromPosition(
              event.localPosition.dy,
              rangeStartMinutes,
              yForMinute,
            );
            setState(() {
              _dragEndSlot = slot;
            });
          } else if (!_isDragging) {
            _longPressTimer?.cancel();
            _longPressStartPosition = null;
          }
        },
        onPointerUp: (event) {
          _longPressTimer?.cancel();
          if (_isDragging) {
            _endDrag(rangeStartMinutes, yForMinute);
          }
          _longPressStartPosition = null;
        },
        onPointerCancel: (event) {
          _longPressTimer?.cancel();
          setState(() {
            _isDragging = false;
            _dragStartSlot = null;
            _dragEndSlot = null;
          });
          widget.onDragStateChanged?.call(false);
          _longPressStartPosition = null;
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

    final startSlot = _dragStartSlot! < _dragEndSlot!
        ? _dragStartSlot!
        : _dragEndSlot!;
    final endSlot = _dragStartSlot! > _dragEndSlot!
        ? _dragStartSlot!
        : _dragEndSlot!;

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

    final startSlot = _dragStartSlot! < _dragEndSlot!
        ? _dragStartSlot!
        : _dragEndSlot!;
    final endSlot = _dragStartSlot! > _dragEndSlot!
        ? _dragStartSlot!
        : _dragEndSlot!;

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

    for (final session in widget.sessions) {
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
      _isBottomSheetOpen = false;
      _dragStartSlot = null;
      _dragEndSlot = null;
    });
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
