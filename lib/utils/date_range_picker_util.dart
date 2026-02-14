import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import 'timezone_utils.dart';

/// 유효기간 선택 달력 유틸리티
class DateRangePickerUtil {
  DateRangePickerUtil._();

  /// 유효기간 선택 다이얼로그 표시 (Flutter 기본 달력 사용)
  ///
  /// [initialStartDate] 초기 시작일 (기본값: 현재 날짜)
  /// [initialEndDate] 초기 종료일 (기본값: 현재 날짜 + 365일)
  /// [minDate] 선택 가능한 최소 날짜 (기본값: 2020-01-01)
  /// [maxDate] 선택 가능한 최대 날짜 (기본값: 2100-12-31)
  ///
  /// Returns: 선택된 날짜 범위 (startDate, endDate) 또는 null
  static Future<DateTimeRange?> showDefaultDateRangePicker({
    required BuildContext context,
    DateTime? initialStartDate,
    DateTime? initialEndDate,
    DateTime? minDate,
    DateTime? maxDate,
  }) async {
    final now = TimezoneUtils.getSeoulDateTime();
    final startDate = initialStartDate ?? now;
    final endDate = initialEndDate ?? now.add(const Duration(days: 365));
    final firstDate = minDate ?? DateTime(2020, 1, 1);
    final lastDate = maxDate ?? DateTime(2100, 12, 31);

    // Flutter의 기본 showDateRangePicker 사용
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: DateTimeRange(start: startDate, end: endDate),
      firstDate: firstDate,
      lastDate: lastDate,
      locale: const Locale('ko', 'KR'),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.light(
              primary: AppColors.primaryGreen,
              onPrimary: Colors.white,
              surface: AppColors.backgroundWhite,
              onSurface: AppColors.textPrimary,
            ),
            dialogBackgroundColor: AppColors.backgroundWhite,
          ),
          child: child!,
        );
      },
    );

    return picked;
  }

  /// 커스텀 유효기간 선택 다이얼로그 (더 나은 UI)
  ///
  /// 달력에서 시작일과 종료일을 선택할 수 있는 커스텀 다이얼로그
  static Future<DateTimeRange?> showCustomDateRangePicker({
    required BuildContext context,
    DateTime? initialStartDate,
    DateTime? initialEndDate,
    DateTime? minDate,
    DateTime? maxDate,
  }) async {
    final now = TimezoneUtils.getSeoulDateTime();
    final startDate = initialStartDate ?? now;
    final endDate = initialEndDate ?? now.add(const Duration(days: 365));
    final firstDate = minDate ?? DateTime(2020, 1, 1);
    final lastDate = maxDate ?? DateTime(2100, 12, 31);

    return await showDialog<DateTimeRange>(
      context: context,
      builder: (context) => _CustomDateRangePickerDialog(
        initialStartDate: startDate,
        initialEndDate: endDate,
        firstDate: firstDate,
        lastDate: lastDate,
      ),
    );
  }

  /// 단일 날짜 선택 바텀시트
  ///
  /// [initialDate] 초기 날짜 (기본값: 현재 날짜)
  /// [firstDate] 선택 가능한 최소 날짜 (기본값: 2020-01-01)
  /// [lastDate] 선택 가능한 최대 날짜 (기본값: 2100-12-31)
  /// [title] 바텀시트 제목 (기본값: "날짜 선택")
  ///
  /// Returns: 선택된 날짜 또는 null
  static Future<DateTime?> showSingleDatePicker({
    required BuildContext context,
    DateTime? initialDate,
    DateTime? firstDate,
    DateTime? lastDate,
    String? title,
  }) async {
    final now = TimezoneUtils.getSeoulDateTime();
    final date = initialDate ?? now;
    final first = firstDate ?? DateTime(2020, 1, 1);
    final last = lastDate ?? DateTime(2100, 12, 31);

    return await showModalBottomSheet<DateTime>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      builder: (context) => _SingleDatePickerBottomSheet(
        initialDate: date,
        firstDate: first,
        lastDate: last,
        title: title ?? '날짜 선택',
      ),
    );
  }
}

/// 단일 날짜 선택 바텀시트
class _SingleDatePickerBottomSheet extends StatefulWidget {
  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;
  final String title;

  const _SingleDatePickerBottomSheet({
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
    required this.title,
  });

  @override
  State<_SingleDatePickerBottomSheet> createState() =>
      _SingleDatePickerBottomSheetState();
}

class _SingleDatePickerBottomSheetState
    extends State<_SingleDatePickerBottomSheet> {
  DateTime? _selectedDate;
  late DateTime _currentMonth;

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.initialDate;
    _currentMonth = DateTime(widget.initialDate.year, widget.initialDate.month);
  }

  void _previousMonth() {
    setState(() {
      _currentMonth = DateTime(_currentMonth.year, _currentMonth.month - 1);
    });
  }

  void _nextMonth() {
    setState(() {
      _currentMonth = DateTime(_currentMonth.year, _currentMonth.month + 1);
    });
  }

  bool _isSelectedDate(DateTime date) {
    if (_selectedDate == null) return false;
    return date.year == _selectedDate!.year &&
        date.month == _selectedDate!.month &&
        date.day == _selectedDate!.day;
  }

  bool _isDateDisabled(DateTime date) {
    return date.isBefore(widget.firstDate) || date.isAfter(widget.lastDate);
  }

  Widget _buildCalendar() {
    final now = TimezoneUtils.getSeoulDateTime();
    final firstDayOfMonth = DateTime(
      _currentMonth.year,
      _currentMonth.month,
      1,
    );
    final lastDayOfMonth = DateTime(
      _currentMonth.year,
      _currentMonth.month + 1,
      0,
    );

    final daysInMonth = lastDayOfMonth.day;
    final firstWeekday = firstDayOfMonth.weekday;

    final prevMonthLastDay = DateTime(
      _currentMonth.year,
      _currentMonth.month,
      0,
    ).day;

    return Column(
      children: [
        // 월 네비게이션
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: Icon(Icons.chevron_left, color: AppColors.textPrimary),
                onPressed: _previousMonth,
              ),
              Text(
                '${_currentMonth.year}년 ${_currentMonth.month}월',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              IconButton(
                icon: Icon(Icons.chevron_right, color: AppColors.textPrimary),
                onPressed: _nextMonth,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // 요일 헤더
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: ['월', '화', '수', '목', '금', '토', '일'].asMap().entries.map((
              entry,
            ) {
              final isWeekend = entry.key >= 5;
              return Expanded(
                child: Center(
                  child: Text(
                    entry.value,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isWeekend
                          ? Colors.red.withOpacity(0.7)
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 8),
        // 달력 그리드
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            children: List.generate(6, (weekIndex) {
              return Row(
                children: List.generate(7, (dayIndex) {
                  final dayNumber = weekIndex * 7 + dayIndex - firstWeekday + 2;
                  late DateTime date;
                  bool isPrevMonth = false;
                  bool isNextMonth = false;

                  if (dayNumber < 1) {
                    final prevDay = prevMonthLastDay + dayNumber;
                    date = DateTime(
                      _currentMonth.year,
                      _currentMonth.month - 1,
                      prevDay,
                    );
                    isPrevMonth = true;
                  } else if (dayNumber > daysInMonth) {
                    final nextDay = dayNumber - daysInMonth;
                    date = DateTime(
                      _currentMonth.year,
                      _currentMonth.month + 1,
                      nextDay,
                    );
                    isNextMonth = true;
                  } else {
                    date = DateTime(
                      _currentMonth.year,
                      _currentMonth.month,
                      dayNumber,
                    );
                  }

                  final isSelected = _isSelectedDate(date);
                  final isToday =
                      date.year == now.year &&
                      date.month == now.month &&
                      date.day == now.day;
                  final isDisabled = _isDateDisabled(date);

                  return Expanded(
                    child: GestureDetector(
                      onTap: isDisabled
                          ? null
                          : () {
                              setState(() {
                                _selectedDate = date;
                              });
                            },
                      child: Container(
                        margin: const EdgeInsets.all(2),
                        height: 50,
                        decoration: BoxDecoration(
                          color: isSelected
                              ? AppColors.primaryGreen
                              : isToday
                              ? Colors.transparent
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(16),
                          border: isToday && !isSelected
                              ? Border.all(
                                  color: AppColors.primaryGreen,
                                  width: 1,
                                )
                              : null,
                        ),
                        child: Center(
                          child: Text(
                            '${date.day}',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: isSelected || isToday
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                              color: isDisabled
                                  ? AppColors.textSecondary.withOpacity(0.3)
                                  : isSelected
                                  ? Colors.white
                                  : isPrevMonth || isNextMonth
                                  ? AppColors.textSecondary.withOpacity(0.5)
                                  : AppColors.textPrimary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              );
            }),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(30),
          topRight: Radius.circular(30),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 16),
          // 달력
          Flexible(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _buildCalendar(),
              ),
            ),
          ),
          // 버튼
          Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      side: BorderSide(
                        color: AppColors.textSecondary.withValues(alpha: 0.5),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      '취소',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _selectedDate != null
                        ? () {
                            Navigator.of(context).pop(_selectedDate);
                          }
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryGreen,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      elevation: 0,
                    ),
                    child: Text(
                      widget.title,
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
          ),
        ],
      ),
    );
  }
}

/// 커스텀 날짜 범위 선택 다이얼로그
class _CustomDateRangePickerDialog extends StatefulWidget {
  final DateTime initialStartDate;
  final DateTime initialEndDate;
  final DateTime firstDate;
  final DateTime lastDate;

  const _CustomDateRangePickerDialog({
    required this.initialStartDate,
    required this.initialEndDate,
    required this.firstDate,
    required this.lastDate,
  });

  @override
  State<_CustomDateRangePickerDialog> createState() =>
      _CustomDateRangePickerDialogState();
}

class _CustomDateRangePickerDialogState
    extends State<_CustomDateRangePickerDialog> {
  DateTime? _tempStartDate;
  DateTime? _tempEndDate;
  bool _isSelectingStart = true;
  late DateTime _currentMonth;

  @override
  void initState() {
    super.initState();
    _tempStartDate = widget.initialStartDate;
    _tempEndDate = widget.initialEndDate;
    _currentMonth = DateTime(
      widget.initialStartDate.year,
      widget.initialStartDate.month,
    );
  }

  void _onDateSelected(DateTime date) {
    if (_isSelectingStart) {
      setState(() {
        _tempStartDate = date;
        _isSelectingStart = false;
        // 종료일이 시작일보다 이전이면 종료일을 시작일로 설정
        if (_tempEndDate != null && _tempEndDate!.isBefore(date)) {
          _tempEndDate = date;
        }
      });
    } else {
      if (date.isBefore(_tempStartDate!)) {
        // 종료일이 시작일보다 이전이면 시작일을 다시 선택
        setState(() {
          _tempStartDate = date;
          _isSelectingStart = false;
        });
      } else {
        setState(() {
          _tempEndDate = date;
          _isSelectingStart = true;
        });
      }
    }
  }

  bool _isDateInRange(DateTime date) {
    if (_tempStartDate == null || _tempEndDate == null) return false;
    return date.isAfter(_tempStartDate!.subtract(const Duration(days: 1))) &&
        date.isBefore(_tempEndDate!.add(const Duration(days: 1)));
  }

  bool _isStartDate(DateTime date) {
    if (_tempStartDate == null) return false;
    return date.year == _tempStartDate!.year &&
        date.month == _tempStartDate!.month &&
        date.day == _tempStartDate!.day;
  }

  bool _isEndDate(DateTime date) {
    if (_tempEndDate == null) return false;
    return date.year == _tempEndDate!.year &&
        date.month == _tempEndDate!.month &&
        date.day == _tempEndDate!.day;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        constraints: BoxConstraints(
          maxWidth: 400,
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 헤더
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '유효기간 선택',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: _isSelectingStart
                                    ? AppColors.primaryGreen.withOpacity(0.2)
                                    : AppColors.backgroundLight,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: _isSelectingStart
                                      ? AppColors.primaryGreen
                                      : AppColors.borderLight,
                                  width: _isSelectingStart ? 2 : 1,
                                ),
                              ),
                              child: Text(
                                '시작일: ${TimezoneUtils.formatDateToSeoul(_tempStartDate ?? widget.initialStartDate)}',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: _isSelectingStart
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                  color: _isSelectingStart
                                      ? AppColors.primaryGreen
                                      : AppColors.textSecondary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: !_isSelectingStart
                                    ? AppColors.primaryGreen.withOpacity(0.2)
                                    : AppColors.backgroundLight,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: !_isSelectingStart
                                      ? AppColors.primaryGreen
                                      : AppColors.borderLight,
                                  width: !_isSelectingStart ? 2 : 1,
                                ),
                              ),
                              child: Text(
                                '종료일: ${TimezoneUtils.formatDateToSeoul(_tempEndDate ?? widget.initialEndDate)}',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: !_isSelectingStart
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                  color: !_isSelectingStart
                                      ? AppColors.primaryGreen
                                      : AppColors.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: AppColors.textSecondary),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            // 달력
            Flexible(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _buildCalendar(),
                ),
              ),
            ),
            // 버튼
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        side: BorderSide(
                          color: AppColors.textSecondary.withValues(alpha: 0.5),
                          width: 1,
                        ),
                      ),
                      child: Text(
                        '취소',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed:
                          (_tempStartDate != null && _tempEndDate != null)
                          ? () {
                              Navigator.of(context).pop(
                                DateTimeRange(
                                  start: _tempStartDate!,
                                  end: _tempEndDate!,
                                ),
                              );
                            }
                          : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primaryGreen,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        elevation: 0,
                      ),
                      child: Text(
                        '확인',
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
            ),
          ],
        ),
      ),
    );
  }

  void _previousMonth() {
    setState(() {
      _currentMonth = DateTime(_currentMonth.year, _currentMonth.month - 1);
    });
  }

  void _nextMonth() {
    setState(() {
      _currentMonth = DateTime(_currentMonth.year, _currentMonth.month + 1);
    });
  }

  Widget _buildCalendar() {
    final now = TimezoneUtils.getSeoulDateTime();
    final firstDayOfMonth = DateTime(
      _currentMonth.year,
      _currentMonth.month,
      1,
    );
    final lastDayOfMonth = DateTime(
      _currentMonth.year,
      _currentMonth.month + 1,
      0,
    );

    // 달력 그리드 생성
    final daysInMonth = lastDayOfMonth.day;
    final firstWeekday = firstDayOfMonth.weekday; // 1=월요일, 7=일요일

    // 이전 달의 마지막 날들
    final prevMonthLastDay = DateTime(
      _currentMonth.year,
      _currentMonth.month,
      0,
    ).day;

    return Column(
      children: [
        // 월 네비게이션
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: Icon(Icons.chevron_left, color: AppColors.textPrimary),
                onPressed: _previousMonth,
              ),
              Text(
                '${_currentMonth.year}년 ${_currentMonth.month}월',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              IconButton(
                icon: Icon(Icons.chevron_right, color: AppColors.textPrimary),
                onPressed: _nextMonth,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // 요일 헤더
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: ['월', '화', '수', '목', '금', '토', '일'].asMap().entries.map((
              entry,
            ) {
              final isWeekend = entry.key >= 5; // 토, 일
              return Expanded(
                child: Center(
                  child: Text(
                    entry.value,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isWeekend
                          ? Colors.red.withOpacity(0.7)
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 8),
        // 달력 그리드
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            children: List.generate(6, (weekIndex) {
              return Row(
                children: List.generate(7, (dayIndex) {
                  final dayNumber = weekIndex * 7 + dayIndex - firstWeekday + 2;
                  late DateTime date;
                  bool isPrevMonth = false;
                  bool isNextMonth = false;

                  if (dayNumber < 1) {
                    // 이전 달
                    final prevDay = prevMonthLastDay + dayNumber;
                    date = DateTime(
                      _currentMonth.year,
                      _currentMonth.month - 1,
                      prevDay,
                    );
                    isPrevMonth = true;
                  } else if (dayNumber > daysInMonth) {
                    // 다음 달
                    final nextDay = dayNumber - daysInMonth;
                    date = DateTime(
                      _currentMonth.year,
                      _currentMonth.month + 1,
                      nextDay,
                    );
                    isNextMonth = true;
                  } else {
                    // 현재 달
                    date = DateTime(
                      _currentMonth.year,
                      _currentMonth.month,
                      dayNumber,
                    );
                  }

                  final isInRange = _isDateInRange(date);
                  final isStart = _isStartDate(date);
                  final isEnd = _isEndDate(date);
                  final isToday =
                      date.year == now.year &&
                      date.month == now.month &&
                      date.day == now.day;
                  final isSelectable =
                      date.isAfter(
                        widget.firstDate.subtract(const Duration(days: 1)),
                      ) &&
                      date.isBefore(
                        widget.lastDate.add(const Duration(days: 1)),
                      );

                  return Expanded(
                    child: GestureDetector(
                      onTap: isSelectable ? () => _onDateSelected(date) : null,
                      child: Container(
                        margin: const EdgeInsets.all(2),
                        height: 40,
                        decoration: BoxDecoration(
                          color: isStart || isEnd
                              ? AppColors.primaryGreen
                              : isInRange
                              ? AppColors.primaryGreen.withOpacity(0.2)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          border: isToday
                              ? Border.all(
                                  color: AppColors.primaryGreen,
                                  width: 2,
                                )
                              : null,
                        ),
                        child: Center(
                          child: Text(
                            '${date.day}',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: isStart || isEnd
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isStart || isEnd
                                  ? Colors.white
                                  : (isPrevMonth || isNextMonth)
                                  ? AppColors.textSecondary.withOpacity(0.3)
                                  : AppColors.textPrimary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              );
            }),
          ),
        ),
      ],
    );
  }
}
