import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:reservation/utils/calendar_utils.dart';
import 'package:reservation/utils/timezone_utils.dart';
import '../../../theme/app_colors.dart';
import '../../../models/session_draft.dart';
import '../../../widgets/session_block_style.dart';

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

  /// 드래그 영역(캘린더 그리드) RenderBox용 키 - 상하단 자동스크롤을 전역 화면이 아닌 이 영역 기준으로 함
  final GlobalKey? dragAreaKey;
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
    this.dragAreaKey,
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

  /// 롱프레스 인식 전: 이 거리(px) 이상 움직이면 롱프레스 취소(스크롤로 간주). 실기기 미세 떨림은 무시.
  static const double _longPressMoveThreshold = 14.0;

  /// 롱프레스/드래그 시 터치 위치가 의도보다 아래로 쳐지므로, slot 계산 시 dy를 이만큼 위로 보정
  static const double _longPressDyUpwardOffset = 12.0;

  /// 드래그 중 화면 끝 근처에서 자동 스크롤 (손 가만히 대도 안정적)
  // enter/exit 히스테리시스: 임계값 근처에서 파르르 떨림 방지
  static const double _autoScrollEnterZone = 60.0;
  static const double _autoScrollExitZone = 90.0;
  static const double _autoScrollStep = 8.0; // 8px / 16ms ≈ 500px/s
  static const Duration _autoScrollInterval = Duration(milliseconds: 16);

  bool _isDragging = false;
  int? _dragStartSlot;
  int? _dragEndSlot;
  bool _isBottomSheetOpen = false;
  Timer? _longPressTimer;
  Offset? _longPressStartPosition;
  Timer? _autoScrollTimer;
  int _autoScrollDirection = 0; // -1: up, 0: none, 1: down
  double? _lastFingerViewportY; // 손 가만히 둬도 사용 (매 틱마다 동일 값으로 슬롯 갱신)

  ScrollController? _scrollController;
  bool _didInitialJump = false;
  int _dragRangeStartMinutes = 0;
  double Function(int minute)? _dragYForMinute;

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
    _autoScrollTimer?.cancel();
    super.dispose();
  }

  /// 포인터 위치를 "드래그 영역(캘린더 그리드)" 기준 viewportY로 저장
  /// - 전역 화면 기준이 아니라 dragAreaKey 기준
  void _updateFingerViewportY(
    double fingerContentY,
    Offset pointerGlobalPosition,
  ) {
    final controller = _scrollController;
    if (controller == null || !controller.hasClients) return;

    // 1) dragAreaKey가 있으면 그 RenderBox 기준
    final dragCtx = widget.dragAreaKey?.currentContext;
    final dragBox = dragCtx?.findRenderObject() as RenderBox?;
    if (dragBox != null && dragBox.hasSize) {
      final local = dragBox.globalToLocal(pointerGlobalPosition);
      _lastFingerViewportY = local.dy.clamp(0.0, dragBox.size.height);
      return;
    }

    // 2) fallback: contentY - scrollOffset
    final vh = controller.position.viewportDimension;
    final so = controller.offset;
    _lastFingerViewportY = (fingerContentY - so).clamp(0.0, vh);
  }

  void _startAutoScrollLoopIfNeeded() {
    if (_autoScrollTimer != null) return;
    final controller = _scrollController;
    if (controller == null) return;
    _autoScrollTimer = Timer.periodic(_autoScrollInterval, (_) {
      if (!mounted || !_isDragging || !controller.hasClients) return;
      _autoScrollTick(controller);
    });
  }

  int _computeAutoScrollDirection(double y, double h, int current) {
    final yClamped = y.clamp(0.0, h);
    // 반대 엣지로 들어가면 즉시 전환
    if (yClamped < _autoScrollEnterZone) return -1;
    if (yClamped > h - _autoScrollEnterZone) return 1;

    // 엣지에서 벗어날 때는 exitZone까지는 유지(히스테리시스)
    if (current == -1 && yClamped > _autoScrollExitZone) return 0;
    if (current == 1 && yClamped < h - _autoScrollExitZone) return 0;
    return current;
  }

  void _autoScrollTick(ScrollController controller) {
    final y = _lastFingerViewportY;
    if (y == null) return;

    // 드래그 영역 높이(가능하면 dragAreaKey 기준), 없으면 viewportDimension
    double h = controller.position.viewportDimension;
    final dragCtx = widget.dragAreaKey?.currentContext;
    final dragBox = dragCtx?.findRenderObject() as RenderBox?;
    if (dragBox != null && dragBox.hasSize) h = dragBox.size.height;

    final yClamped = y.clamp(0.0, h);

    // 방향은 "손가락 위치"를 단일 소스로 사용 (틱에서도 동일 로직으로 안정화)
    final dir = _computeAutoScrollDirection(yClamped, h, _autoScrollDirection);
    _autoScrollDirection = dir;
    if (dir == 0) return;

    // 슬롯: 손가락 위치 그대로 따라감 (일반모드와 동일 - contentY = offset + viewportY)
    if (_dragYForMinute != null && _dragStartSlot != null) {
      final contentY = controller.offset + yClamped;
      final dyAdjusted = (contentY - _longPressDyUpwardOffset).clamp(
        0.0,
        double.infinity,
      );
      final slot = _getSlotFromPosition(
        dyAdjusted,
        _dragRangeStartMinutes,
        _dragYForMinute!,
      );
      final startSlot = _dragStartSlot! < slot ? _dragStartSlot! : slot;
      final endSlot = _dragStartSlot! > slot ? _dragStartSlot! : slot;
      if (endSlot - startSlot >= 1) {
        final startMinutes = _dragRangeStartMinutes + (startSlot * 30);
        final endMinutes = _dragRangeStartMinutes + ((endSlot + 1) * 30);
        if (!_hasOverlap(
          CalendarUtils.minutesToTimeString(startMinutes),
          CalendarUtils.minutesToTimeString(endMinutes),
        )) {
          setState(() => _dragEndSlot = slot);
        }
      }
    }

    final step = _autoScrollStep * dir;
    var target = controller.offset + step;
    target = target.clamp(
      controller.position.minScrollExtent,
      controller.position.maxScrollExtent,
    );
    controller.jumpTo(target);
  }

  void _cancelAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _autoScrollDirection = 0;
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
    final sessionStartMinutes = CalendarUtils.parseTimeToMinutes(session.startTime);
    final sessionEndMinutes = CalendarUtils.parseTimeToMinutes(session.endTime);
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

    final blockType = isPreview
        ? SessionBlockType.preview
        : isRegular
            ? SessionBlockType.regularSchedule
            : SessionBlockType.overrideSchedule;
    final blockStyle = SessionBlockStyle.fromType(
      blockType,
      courseColor: widget.courseColor,
    );

    // 세션 위젯 내용
    Widget sessionContent = Container(
      padding: EdgeInsets.symmetric(
        horizontal: 8,
        vertical: sessionHeightPx >= 50 ? 4 : 2,
      ),
      decoration: blockStyle.toBoxDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isRegular) ...[
            Text(
              '정기일정',
              style: TextStyle(
                color: blockStyle.textColor,
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
              color: blockStyle.textColor,
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
                color: blockStyle.iconColor,
                fontSize: sessionHeightPx >= 90 ? 17 : 14,
              ),
            ),
          ],
        ],
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
        // 드래그 중에는 이벤트를 확실히 잡아 cancel/up 오판을 줄인다.
        behavior:
            _isDragging ? HitTestBehavior.opaque : HitTestBehavior.translucent,
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
            _longPressStartPosition = event.localPosition;
            _longPressTimer?.cancel();
            _longPressTimer = Timer(const Duration(milliseconds: 500), () {
              if (_longPressStartPosition != null) {
                debugPrint('[DragCalendarEditor] 롱프레스 500ms 완료 → 드래그 시작');
                _dragRangeStartMinutes = rangeStartMinutes;
                _dragYForMinute = yForMinute;
                // 롱프레스가 인식된 뒤에만 스크롤 막기 (그 전에는 스크롤 가능하도록)
                widget.onScrollBlockRequested?.call(true);
                final dy = (_longPressStartPosition!.dy -
                        _longPressDyUpwardOffset)
                    .clamp(0.0, double.infinity);
                final slot = _getSlotFromPosition(
                  dy,
                  rangeStartMinutes,
                  yForMinute,
                );
                setState(() {
                  _isDragging = true;
                  _dragStartSlot = slot;
                  _dragEndSlot = slot;
                });
                widget.onDragStateChanged?.call(true);
                // 자동 스크롤 루프는 드래그 시작 시부터 유지 (틱에서 방향 결정)
                _startAutoScrollLoopIfNeeded();
              }
            });
          }
        },
        onPointerMove: (event) {
          if (_isDragging && _longPressStartPosition != null) {
            debugPrint(
              '[DragCalendarEditor] onPointerMove (드래그 중) dy=${event.localPosition.dy}',
            );
            // 드래그 영역(캘린더 그리드) 기준으로 마지막 손가락 위치만 갱신
            _updateFingerViewportY(event.localPosition.dy, event.position);
            // 방향 전환은 move에서 즉시 반영
            final sc = _scrollController;
            if (sc != null && sc.hasClients) {
              double h = sc.position.viewportDimension;
              final dragCtx = widget.dragAreaKey?.currentContext;
              final dragBox = dragCtx?.findRenderObject() as RenderBox?;
              if (dragBox != null && dragBox.hasSize) h = dragBox.size.height;
              final yV = _lastFingerViewportY;
              if (yV != null) {
                _autoScrollDirection = _computeAutoScrollDirection(
                  yV,
                  h,
                  _autoScrollDirection,
                );
              }
            }
            // 1️⃣ 슬롯 계산 기준 통일: 항상 offset + viewportY (timer와 동일)
            final controller = _scrollController;
            final yV = _lastFingerViewportY;
            int? slot;
            if (controller != null && controller.hasClients && yV != null) {
              final contentY = controller.offset + yV;
              final dyAdjusted = (contentY - _longPressDyUpwardOffset).clamp(
                0.0,
                double.infinity,
              );
              slot = _getSlotFromPosition(
                dyAdjusted,
                rangeStartMinutes,
                yForMinute,
              );
            }
            if (slot != null) {
              // 드래그 중에도 겹침 체크
              final startSlot = _dragStartSlot! < slot ? _dragStartSlot! : slot;
              final endSlot = _dragStartSlot! > slot ? _dragStartSlot! : slot;
              if (endSlot - startSlot >= 1) {
                final startMinutes = rangeStartMinutes + (startSlot * 30);
                final endMinutes = rangeStartMinutes + ((endSlot + 1) * 30);
                final startTime = CalendarUtils.minutesToTimeString(startMinutes);
                final endTime = CalendarUtils.minutesToTimeString(endMinutes);

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
              // 2️⃣ 자동스크롤 중에는 timer만 슬롯 갱신. 일반 모드(_autoScrollDirection==0)일 때만 move가 갱신
              if (_autoScrollDirection == 0) {
                if (_dragEndSlot != slot) {
                  setState(() {
                    _dragEndSlot = slot;
                  });
                }
              }
            }
          } else if (!_isDragging && _longPressStartPosition != null) {
            final dx = event.localPosition.dx - _longPressStartPosition!.dx;
            final dy = event.localPosition.dy - _longPressStartPosition!.dy;
            final distanceSquared = dx * dx + dy * dy;
            final thresholdSquared =
                _longPressMoveThreshold * _longPressMoveThreshold;
            if (distanceSquared > thresholdSquared) {
              _longPressTimer?.cancel();
              _longPressStartPosition = null;
              // 스크롤로 간주했으므로 막았던 스크롤 해제 → 그냥 드래그(스크롤) 시 리스트가 움직이도록
              widget.onScrollBlockRequested?.call(false);
            }
          }
        },
        onPointerUp: (event) {
          debugPrint(
            '[DragCalendarEditor] onPointerUp _isDragging=$_isDragging',
          );
          _longPressTimer?.cancel();
          _cancelAutoScroll();
          if (_isDragging) {
            _endDrag(rangeStartMinutes, yForMinute);
          }
          _longPressStartPosition = null;
          _lastFingerViewportY = null;
          widget.onScrollBlockRequested?.call(false);
        },
        onPointerCancel: (event) {
          debugPrint('[DragCalendarEditor] onPointerCancel');
          _longPressTimer?.cancel();
          _cancelAutoScroll();
          setState(() {
            _isDragging = false;
            _dragStartSlot = null;
            _dragEndSlot = null;
          });
          widget.onDragStateChanged?.call(false);
          _longPressStartPosition = null;
          _lastFingerViewportY = null;
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

    final startTime = CalendarUtils.minutesToTimeString(startMinutes);
    final endTime = CalendarUtils.minutesToTimeString(endMinutes);

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
    final newStart = CalendarUtils.parseTimeToMinutes(startTime);
    final newEnd = CalendarUtils.parseTimeToMinutes(endTime);

    for (final session in <SessionDraft>[
      ...widget.sessions,
      ...widget.blockedSessions,
    ]) {
      final sessionStart = CalendarUtils.parseTimeToMinutes(session.startTime);
      final sessionEnd = CalendarUtils.parseTimeToMinutes(session.endTime);

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
      final sessionStartMinutes = CalendarUtils.parseTimeToMinutes(session.startTime);
      final sessionEndMinutes = CalendarUtils.parseTimeToMinutes(session.endTime);
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
