import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/snackbar_util.dart';
import '../../../utils/text_field_decoration_util.dart';
import '../../../models/session_draft.dart';

/// 커스텀 체크박스 위젯
class CustomCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool?>? onChanged;
  final Color activeColor;
  final double size;

  const CustomCheckbox({
    super.key,
    required this.value,
    this.onChanged,
    required this.activeColor,
    this.size = 24.0,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onChanged != null ? () => onChanged!(!value) : null,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: value ? activeColor : AppColors.borderLight,
            width: value ? 2 : 1.5,
          ),
          color: value ? activeColor : Colors.transparent,
        ),
        child:
            value
                ? Icon(Icons.check, size: size * 0.6, color: Colors.white)
                : null,
      ),
    );
  }
}

/// 세션 편집 바텀시트
class SessionEditBottomSheet extends StatefulWidget {
  final String initialStartTime;
  final String initialEndTime;
  final int initialCapacity;
  final String courseName;
  final int dayOfWeek;
  final Set<int> selectedDays; // 선택된 요일들 (일괄등록용)
  final bool canBulkCancel; // 편집 모드에서 일괄취소 UI 노출 여부(동일 시간대가 모든 선택 요일에 존재)
  final Color courseColor; // 코스 색상
  final List<SessionDraft>? existingSessions; // 현재 요일의 기존 세션들 (충돌 체크용)
  final Map<int, List<SessionDraft>>?
  allDaySessions; // 모든 요일의 세션 정보 (일괄 적용 가능 여부 확인용)
  final Function(
    String startTime,
    String endTime,
    int capacity,
    List<int>? bulkDays,
  )
  onRegister;
  final VoidCallback onCancel;
  final void Function(List<int>? bulkDays)? onDelete; // 삭제 콜백 (편집 모드일 때만)
  final void Function(bool isBulkRegistration)?
  onBulkRegistrationChanged; // 일괄등록 변경 콜백
  final bool isEditMode; // 편집 모드인지 여부

  const SessionEditBottomSheet({
    super.key,
    required this.initialStartTime,
    required this.initialEndTime,
    required this.initialCapacity,
    required this.courseName,
    required this.dayOfWeek,
    required this.selectedDays,
    required this.courseColor,
    this.canBulkCancel = false,
    this.existingSessions,
    this.allDaySessions,
    required this.onRegister,
    required this.onCancel,
    this.onDelete,
    this.onBulkRegistrationChanged,
    this.isEditMode = false,
  });

  @override
  State<SessionEditBottomSheet> createState() => _SessionEditBottomSheetState();
}

class _SessionEditBottomSheetState extends State<SessionEditBottomSheet> {
  late TextEditingController _capacityController;
  late FocusNode _capacityFocusNode;
  late FixedExtentScrollController _startHourController;
  late FixedExtentScrollController _startMinuteController;
  late FixedExtentScrollController _endHourController;
  late FixedExtentScrollController _endMinuteController;

  int _startHour = 0;
  int _startMinute = 0;
  int _endHour = 0;
  int _endMinute = 0;
  bool _isStartTimeExpanded = false;
  bool _isEndTimeExpanded = false;
  bool _isBulkRegistration = false; // 일괄등록 여부

  // 초기 값 저장 (변경 감지용)
  late int _initialStartHour;
  late int _initialStartMinute;
  late int _initialEndHour;
  late int _initialEndMinute;
  late int _initialCapacity;
  late bool _initialBulkRegistration; // 초기 일괄등록 상태

  @override
  void initState() {
    super.initState();
    final startParts = widget.initialStartTime.split(':');
    final endParts = widget.initialEndTime.split(':');

    _startHour = int.tryParse(startParts[0]) ?? 0;
    _startMinute = int.tryParse(startParts[1]) ?? 0;
    _endHour = int.tryParse(endParts[0]) ?? 0;
    _endMinute = int.tryParse(endParts[1]) ?? 0;

    // 초기 값 저장
    _initialStartHour = _startHour;
    _initialStartMinute = _startMinute;
    _initialEndHour = _endHour;
    _initialEndMinute = _endMinute;
    _initialCapacity = widget.initialCapacity;
    _initialBulkRegistration = _isBulkRegistration;

    _startHourController = FixedExtentScrollController(initialItem: _startHour);
    _startMinuteController = FixedExtentScrollController(
      initialItem: _startMinute,
    );
    _endHourController = FixedExtentScrollController(initialItem: _endHour);
    _endMinuteController = FixedExtentScrollController(initialItem: _endMinute);

    _capacityController = TextEditingController(
      text:
          (widget.initialCapacity == -1 || widget.initialCapacity == 0)
              ? ''
              : widget.initialCapacity.toString(),
    );
    _capacityController.addListener(() {
      setState(() {
        // 수용인원 변경 시 완료 버튼 활성화 상태 업데이트
      });
    });
    _capacityFocusNode = FocusNode();
    _capacityFocusNode.addListener(() {
      setState(() {
        // 키보드 상태 변경 시 UI 업데이트
      });
    });

    // 수용인원이 0이거나 비어있으면 자동 포커스
    if (widget.initialCapacity == -1 || widget.initialCapacity == 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _capacityFocusNode.requestFocus();
      });
    }
  }

  // 시간을 분으로 변환
  int _parseTimeToMinutes(int hour, int minute) {
    return hour * 60 + minute;
  }

  // 시간 충돌 체크
  bool _hasTimeConflict(
    int startHour,
    int startMinute,
    int endHour,
    int endMinute,
  ) {
    if (widget.existingSessions == null || widget.existingSessions!.isEmpty) {
      return false;
    }

    final newStart = _parseTimeToMinutes(startHour, startMinute);
    final newEnd = _parseTimeToMinutes(endHour, endMinute);

    // 편집 모드인 경우, 현재 편집 중인 세션은 제외하고 체크
    final sessionsToCheck =
        widget.isEditMode
            ? widget.existingSessions!
                .where(
                  (s) =>
                      s.startTime != widget.initialStartTime ||
                      s.endTime != widget.initialEndTime,
                )
                .toList()
            : widget.existingSessions!;

    for (final session in sessionsToCheck) {
      final sessionStartParts = session.startTime.split(':');
      final sessionEndParts = session.endTime.split(':');
      final sessionStart = _parseTimeToMinutes(
        int.tryParse(sessionStartParts[0]) ?? 0,
        int.tryParse(sessionStartParts[1]) ?? 0,
      );
      final sessionEnd = _parseTimeToMinutes(
        int.tryParse(sessionEndParts[0]) ?? 0,
        int.tryParse(sessionEndParts[1]) ?? 0,
      );

      // 겹침 체크: 새 세션이 기존 세션과 겹치는지
      if (newStart < sessionEnd && newEnd > sessionStart) {
        return true;
      }
    }
    return false;
  }

  // 특정 시간이 충돌하는지 체크 (시작 시간 또는 종료 시간 단독 체크)
  bool _isTimeInConflict(int hour, int minute, {required bool isStartTime}) {
    if (widget.existingSessions == null || widget.existingSessions!.isEmpty) {
      return false;
    }

    final checkTime = _parseTimeToMinutes(hour, minute);

    // 편집 모드인 경우, 현재 편집 중인 세션은 제외하고 체크
    final sessionsToCheck =
        widget.isEditMode
            ? widget.existingSessions!
                .where(
                  (s) =>
                      s.startTime != widget.initialStartTime ||
                      s.endTime != widget.initialEndTime,
                )
                .toList()
            : widget.existingSessions!;

    for (final session in sessionsToCheck) {
      final sessionStartParts = session.startTime.split(':');
      final sessionEndParts = session.endTime.split(':');
      final sessionStart = _parseTimeToMinutes(
        int.tryParse(sessionStartParts[0]) ?? 0,
        int.tryParse(sessionStartParts[1]) ?? 0,
      );
      final sessionEnd = _parseTimeToMinutes(
        int.tryParse(sessionEndParts[0]) ?? 0,
        int.tryParse(sessionEndParts[1]) ?? 0,
      );

      // 시작 시간이 기존 세션 범위 내에 있거나, 종료 시간이 기존 세션 범위 내에 있으면 충돌
      if (isStartTime) {
        if (checkTime >= sessionStart && checkTime < sessionEnd) {
          return true;
        }
      } else {
        if (checkTime > sessionStart && checkTime <= sessionEnd) {
          return true;
        }
      }
    }
    return false;
  }

  // 일괄 적용 버튼 표시 여부 확인
  bool _shouldShowBulkUi() {
    // 선택된 요일이 2개 이상이어야 함
    if (widget.selectedDays.length <= 1) {
      return false;
    }

    // 편집 모드가 아닌 경우 (드래그로 새로 추가하는 경우)
    if (!widget.isEditMode && widget.allDaySessions != null) {
      // 현재 요일을 제외한 다른 선택된 요일들 확인
      final otherSelectedDays =
          widget.selectedDays.where((day) => day != widget.dayOfWeek).toList();

      // 다른 요일들 중 하나라도 해당 시간대에 세션이 있으면 일괄 적용 숨김
      for (final day in otherSelectedDays) {
        final daySessions = widget.allDaySessions![day] ?? [];
        // 해당 시간대와 겹치는 세션이 있는지 확인
        final hasOverlappingSession = daySessions.any((session) {
          final sessionStart = _parseTimeToMinutes(
            int.tryParse(session.startTime.split(':')[0]) ?? 0,
            int.tryParse(session.startTime.split(':')[1]) ?? 0,
          );
          final sessionEnd = _parseTimeToMinutes(
            int.tryParse(session.endTime.split(':')[0]) ?? 0,
            int.tryParse(session.endTime.split(':')[1]) ?? 0,
          );
          final newStart = _parseTimeToMinutes(_startHour, _startMinute);
          final newEnd = _parseTimeToMinutes(_endHour, _endMinute);

          // 시간이 겹치는지 확인
          return newStart < sessionEnd && newEnd > sessionStart;
        });

        if (hasOverlappingSession) {
          return false; // 하나라도 있으면 일괄 적용 숨김
        }
      }

      // 다른 요일들에 해당 시간대 세션이 없으면 일괄 적용 가능
      return true;
    }

    // 편집 모드이거나 allDaySessions가 없는 경우는 기존 로직 유지
    return widget.selectedDays.length > 1;
  }

  // 변경 사항이 있는지 확인 및 유효성 검사
  bool _hasChanges() {
    final capacityText = _capacityController.text.trim();
    final capacity = int.tryParse(capacityText);

    // 수용인원이 유효하지 않으면 비활성화
    if (capacity == null || capacity <= 0) return false;

    // 시간 유효성 검사: 종료 시간이 시작 시간보다 늦어야 함
    final startTotalMinutes = _startHour * 60 + _startMinute;
    final endTotalMinutes = _endHour * 60 + _endMinute;
    if (endTotalMinutes <= startTotalMinutes) return false;

    if (!widget.isEditMode) {
      // 새로 추가하는 경우: 수용인원만 입력되면 활성화
      return capacityText.isNotEmpty;
    }

    // 편집 모드: 초기값과 다르면 활성화
    return _startHour != _initialStartHour ||
        _startMinute != _initialStartMinute ||
        _endHour != _initialEndHour ||
        _endMinute != _initialEndMinute ||
        capacity != _initialCapacity ||
        _isBulkRegistration !=
            _initialBulkRegistration; // 일괄등록 체크박스 변경도 변경사항으로 인식
  }

  void _handleDelete() {
    if (widget.onDelete != null) {
      // 일괄 삭제 제거, 단일 삭제만 지원
      widget.onDelete!(null);
      // 바텀시트 닫기
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _startHourController.dispose();
    _startMinuteController.dispose();
    _endHourController.dispose();
    _endMinuteController.dispose();
    _capacityController.dispose();
    _capacityFocusNode.dispose();
    super.dispose();
  }

  String _formatTime(int hour, int minute) {
    final h = hour.toString().padLeft(2, '0');
    final m = minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  void _handleRegister() {
    final capacityText = _capacityController.text.trim();

    // 유효성 검사
    if (capacityText.isEmpty) {
      SnackbarUtil.showError(context, '수용인원을 입력해주세요.');
      return;
    }

    final capacity = int.tryParse(capacityText);

    if (capacity == null) {
      SnackbarUtil.showError(context, '올바른 값을 입력해주세요.');
      return;
    }

    if (capacity <= 0) {
      SnackbarUtil.showError(context, '수용인원은 1명 이상이어야 합니다.');
      return;
    }

    final startTime = _formatTime(_startHour, _startMinute);
    final endTime = _formatTime(_endHour, _endMinute);

    // 종료 시간이 시작 시간보다 이전이면 안됨
    final startTotalMinutes = _startHour * 60 + _startMinute;
    final endTotalMinutes = _endHour * 60 + _endMinute;

    if (endTotalMinutes <= startTotalMinutes) {
      SnackbarUtil.showError(context, '종료 시간은 시작 시간보다 늦어야 합니다.');
      return;
    }

    // 일괄 적용 처리 (등록/수정 모두)
    List<int>? bulkDays;
    if (_isBulkRegistration) {
      // 현재 선택된 요일들에 일괄 적용 (현재 드래그한 요일 포함)
      bulkDays = widget.selectedDays.toList();
    }

    widget.onRegister(startTime, endTime, capacity, bulkDays);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final maxHeight = screenHeight * 0.9; // 화면 높이의 90%로 제한

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 헤더
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),

                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 8),
                              Text(
                                widget.courseName,
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.textPrimary,
                                ),
                              ),

                              // 고정 높이로 UI 흔들림 방지
                              SizedBox(
                                height: 24,
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 200),
                                  child: Text(
                                    _getDayDisplayText(),
                                    key: ValueKey(_isBulkRegistration),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                      color: AppColors.textSecondary,
                                      height: 1.2,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Builder(
                                builder: (context) {
                                  // 일괄 적용 버튼 표시 여부 확인
                                  if (!_shouldShowBulkUi())
                                    return const SizedBox();

                                  return Row(
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.only(top: 3),
                                        child: Text(
                                          '일괄 적용',
                                          style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w500,
                                            color: AppColors.textPrimary,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      CustomCheckbox(
                                        value: _isBulkRegistration,
                                        onChanged: (value) {
                                          setState(() {
                                            _isBulkRegistration =
                                                value ?? false;
                                          });
                                          // 일괄등록 변경 시 실시간 미리보기 업데이트
                                          widget.onBulkRegistrationChanged
                                              ?.call(_isBulkRegistration);
                                        },
                                        activeColor: widget.courseColor,
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 24),
                          onPressed: () {
                            widget.onCancel();
                            Navigator.of(context).pop();
                          },
                          color: AppColors.textSecondary,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // 수용인원 (가장 위에 배치)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '수용인원',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    TextField(
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                      controller: _capacityController,
                      focusNode: _capacityFocusNode,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: TextFieldDecorationUtil.defaultDecoration(
                        hintText: '수용인원을 입력하세요',
                        hasFocus: _capacityFocusNode.hasFocus,
                        borderRadius: 12,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 16,
                        ),
                      ).copyWith(
                        suffixIcon:
                            _capacityFocusNode.hasFocus
                                ? Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: TextButton(
                                    onPressed: () {
                                      _capacityFocusNode.unfocus();
                                    },
                                    child: Text(
                                      '완료',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.primaryGreen,
                                      ),
                                    ),
                                  ),
                                )
                                : Icon(
                                  Icons.edit,
                                  size: 18,
                                  color: AppColors.textSecondary.withOpacity(
                                    0.5,
                                  ),
                                ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              // 시작 시간
              _buildExpandableTimePicker(
                label: '시작 시간',
                isExpanded: _isStartTimeExpanded,
                onTap: () {
                  setState(() {
                    _isStartTimeExpanded = !_isStartTimeExpanded;
                    if (_isEndTimeExpanded && _isStartTimeExpanded) {
                      _isEndTimeExpanded = false;
                    }
                  });
                },
                hour: _startHour,
                minute: _startMinute,
                hourController: _startHourController,
                minuteController: _startMinuteController,
                isStartTime: true,
                onHourChanged: (index) {
                  // 충돌 체크
                  if (_isTimeInConflict(
                    index,
                    _startMinute,
                    isStartTime: true,
                  )) {
                    // 충돌하는 시간이면 이전 유효한 시간으로 되돌림
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _startHourController.animateToItem(
                        _startHour,
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                      );
                    });
                    return;
                  }
                  setState(() {
                    _startHour = index;
                  });
                  // 종료 시간과의 충돌도 체크
                  if (_hasTimeConflict(
                    index,
                    _startMinute,
                    _endHour,
                    _endMinute,
                  )) {
                    SnackbarUtil.showError(context, '이미 해당 시간에 세션이 있습니다.');
                  }
                },
                onMinuteChanged: (index) {
                  // 충돌 체크
                  if (_isTimeInConflict(_startHour, index, isStartTime: true)) {
                    // 충돌하는 시간이면 이전 유효한 시간으로 되돌림
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _startMinuteController.animateToItem(
                        _startMinute,
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                      );
                    });
                    return;
                  }
                  setState(() {
                    _startMinute = index;
                  });
                  // 종료 시간과의 충돌도 체크
                  if (_hasTimeConflict(
                    _startHour,
                    index,
                    _endHour,
                    _endMinute,
                  )) {
                    SnackbarUtil.showError(context, '이미 해당 시간에 세션이 있습니다.');
                  }
                },
              ),
              const SizedBox(height: 8),
              // 종료 시간
              _buildExpandableTimePicker(
                label: '종료 시간',
                isExpanded: _isEndTimeExpanded,
                onTap: () {
                  setState(() {
                    _isEndTimeExpanded = !_isEndTimeExpanded;
                    if (_isStartTimeExpanded && _isEndTimeExpanded) {
                      _isStartTimeExpanded = false;
                    }
                  });
                },
                hour: _endHour,
                minute: _endMinute,
                hourController: _endHourController,
                minuteController: _endMinuteController,
                isStartTime: false,
                onHourChanged: (index) {
                  // 충돌 체크
                  if (_isTimeInConflict(
                    index,
                    _endMinute,
                    isStartTime: false,
                  )) {
                    // 충돌하는 시간이면 이전 유효한 시간으로 되돌림
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _endHourController.animateToItem(
                        _endHour,
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                      );
                    });
                    return;
                  }
                  setState(() {
                    _endHour = index;
                  });
                  // 시작 시간과의 충돌도 체크
                  if (_hasTimeConflict(
                    _startHour,
                    _startMinute,
                    index,
                    _endMinute,
                  )) {
                    SnackbarUtil.showError(context, '이미 해당 시간에 세션이 있습니다.');
                  }
                },
                onMinuteChanged: (index) {
                  // 충돌 체크
                  if (_isTimeInConflict(_endHour, index, isStartTime: false)) {
                    // 충돌하는 시간이면 이전 유효한 시간으로 되돌림
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _endMinuteController.animateToItem(
                        _endMinute,
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                      );
                    });
                    return;
                  }
                  setState(() {
                    _endMinute = index;
                  });
                  // 시작 시간과의 충돌도 체크
                  if (_hasTimeConflict(
                    _startHour,
                    _startMinute,
                    _endHour,
                    index,
                  )) {
                    SnackbarUtil.showError(context, '이미 해당 시간에 세션이 있습니다.');
                  }
                },
              ),
              const SizedBox(height: 24),
              // 버튼
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed:
                            widget.isEditMode
                                ? _handleDelete
                                : () {
                                  widget.onCancel();
                                  Navigator.of(context).pop();
                                },
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          side: BorderSide(
                            color:
                                widget.isEditMode
                                    ? Colors.red
                                    : AppColors.borderLight,
                            width: 1,
                          ),
                        ),
                        child: Text(
                          widget.isEditMode ? '삭제' : '취소',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color:
                                widget.isEditMode
                                    ? Colors.red
                                    : AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        onPressed: _hasChanges() ? _handleRegister : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primaryGreen,
                          disabledBackgroundColor: AppColors.borderLight,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          elevation: 0,
                        ),
                        child: Text(
                          widget.isEditMode ? '수정 완료' : '등록',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  String _getDayName(int dayOfWeek) {
    const dayNames = ['', '월요일', '화요일', '수요일', '목요일', '금요일', '토요일', '일요일'];
    return dayNames[dayOfWeek];
  }

  /// 요일 표시 텍스트 생성 (일괄등록 체크 시 여러 요일 표시)
  String _getDayDisplayText() {
    // 일괄등록이 체크되어 있고 선택된 요일이 여러 개일 때
    if (_isBulkRegistration && widget.selectedDays.length > 1) {
      final sortedDays = widget.selectedDays.toList()..sort();

      // 매일인 경우
      if (sortedDays.length == 7) {
        return '매일';
      }

      // 3개 이하인 경우: "월요일, 화요일, 수요일" 형식
      if (sortedDays.length <= 3) {
        return sortedDays.map((day) => _getDayName(day)).join(', ');
      }

      // 3개 초과인 경우: "월요일, 화요일 외 2개" 형식
      final firstTwoDays = sortedDays
          .take(2)
          .map((day) => _getDayName(day))
          .join(', ');
      final remainingCount = sortedDays.length - 2;
      return '$firstTwoDays 외 $remainingCount개';
    }

    // 기본: 단일 요일 표시
    return _getDayName(widget.dayOfWeek);
  }

  Widget _buildExpandableTimePicker({
    required String label,
    required bool isExpanded,
    required VoidCallback onTap,
    required int hour,
    required int minute,
    required FixedExtentScrollController hourController,
    required FixedExtentScrollController minuteController,
    required Function(int) onHourChanged,
    required Function(int) onMinuteChanged,
    required bool isStartTime,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderLight, width: 1),
      ),
      child: Column(
        children: [
          // 헤더 (항상 보임)
          InkWell(
            onTap: onTap,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: Row(
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: isExpanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      color: AppColors.textSecondary.withOpacity(0.8),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Picker (펼쳐질 때만 보임)
          ClipRRect(
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(12),
            ),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              height: isExpanded ? 200 : 0,
              child:
                  isExpanded
                      ? Row(
                        children: [
                          Expanded(
                            child: CupertinoPicker(
                              scrollController: hourController,
                              itemExtent: 40,
                              diameterRatio: 0.8,
                              useMagnifier: false,
                              onSelectedItemChanged: onHourChanged,
                              children: List.generate(24, (index) {
                                final isConflict = _isTimeInConflict(
                                  index,
                                  minute,
                                  isStartTime: isStartTime,
                                );
                                return Center(
                                  child: Text(
                                    index.toString().padLeft(2, '0'),
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w500,
                                      color:
                                          isConflict
                                              ? AppColors.borderLight
                                              : AppColors.textPrimary,
                                    ),
                                  ),
                                );
                              }),
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              ':',
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                          Expanded(
                            child: CupertinoPicker(
                              scrollController: minuteController,
                              itemExtent: 40,
                              diameterRatio: 0.8,
                              useMagnifier: false,
                              onSelectedItemChanged: onMinuteChanged,
                              children: List.generate(60, (index) {
                                final isConflict = _isTimeInConflict(
                                  hour,
                                  index,
                                  isStartTime: isStartTime,
                                );
                                return Center(
                                  child: Text(
                                    index.toString().padLeft(2, '0'),
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w500,
                                      color:
                                          isConflict
                                              ? AppColors.borderLight
                                              : AppColors.textPrimary,
                                    ),
                                  ),
                                );
                              }),
                            ),
                          ),
                        ],
                      )
                      : const SizedBox.shrink(),
            ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}
