import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../models/course.dart';
import '../theme/app_colors.dart';
import '../utils/date_range_picker_util.dart';
import '../utils/enrollment_valid_until_util.dart';
import '../utils/timezone_utils.dart';

/// 유효기간 설정 모드
enum ValidPeriodMode {
  period, // 주/달/일 모드
  calendar, // 캘린더 모드
}

/// 유효기간 입력 위젯
///
/// [validFrom] 시작일 (읽기 전용, period 모드에서는 표시 안 함)
/// [validUntil] 종료일
/// [periodType] 주/달/일 타입 (period 모드에서만 사용)
/// [periodValue] 기간 값 (period 모드에서만 사용)
/// [mode] 현재 모드 (period 또는 calendar)
/// [onModeChanged] 모드 변경 콜백
/// [onValidFromChanged] 시작일 변경 콜백 (calendar 모드에서만 호출)
/// [onValidUntilChanged] 종료일 변경 콜백
/// [onPeriodTypeChanged] 기간 타입 변경 콜백 (period 모드에서만 호출)
/// [onPeriodValueChanged] 기간 값 변경 콜백 (period 모드에서만 호출)
/// [enabled] 활성화 여부 (false면 회색 처리)
/// [minValidUntil] 최소 종료일 (오늘 또는 시작일 중 더 늦은 날짜)
/// [maxPeriodValue] 최대 기간 값 (기본값: 999)
/// [minPeriodValue] 최소 기간 값 (기본값: 0, 음수 가능)
/// [hideLabel] 라벨 숨김 여부 (기본값: false)
/// [hideCalendarToggle] 달력 토글 버튼 숨김 여부 (기본값: false)
class ValidPeriodInputWidget extends StatefulWidget {
  final DateTime validFrom;
  final DateTime validUntil;
  final PeriodType periodType;
  final int periodValue;
  final ValidPeriodMode mode;
  final ValueChanged<ValidPeriodMode> onModeChanged;
  final ValueChanged<DateTime>? onValidFromChanged;
  final ValueChanged<DateTime> onValidUntilChanged;
  final ValueChanged<PeriodType> onPeriodTypeChanged;
  final ValueChanged<int> onPeriodValueChanged;
  final bool enabled;
  final DateTime? minValidUntil;
  final int maxPeriodValue;
  final int minPeriodValue;
  final bool hideLabel;
  final bool hideCalendarToggle;

  const ValidPeriodInputWidget({
    super.key,
    required this.validFrom,
    required this.validUntil,
    required this.periodType,
    required this.periodValue,
    required this.mode,
    required this.onModeChanged,
    this.onValidFromChanged,
    required this.onValidUntilChanged,
    required this.onPeriodTypeChanged,
    required this.onPeriodValueChanged,
    this.enabled = true,
    this.minValidUntil,
    this.maxPeriodValue = 999,
    this.minPeriodValue = 0,
    this.hideLabel = false,
    this.hideCalendarToggle = false,
  });

  @override
  State<ValidPeriodInputWidget> createState() => _ValidPeriodInputWidgetState();
}

class _ValidPeriodInputWidgetState extends State<ValidPeriodInputWidget> {
  late TextEditingController _periodController;

  @override
  void initState() {
    super.initState();
    _periodController = TextEditingController(
      text: widget.periodValue.toString(),
    );
  }

  @override
  void didUpdateWidget(ValidPeriodInputWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.periodValue != oldWidget.periodValue) {
      _periodController.text = widget.periodValue.toString();
    }
  }

  @override
  void dispose() {
    _periodController.dispose();
    super.dispose();
  }

  String _formatDate(DateTime date) {
    return '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';
  }

  String _getUnitText() {
    switch (widget.periodType) {
      case PeriodType.weeks:
        return '주';
      case PeriodType.days:
        return '일';
      case PeriodType.months:
        return '개월';
    }
  }

  bool _canDecreasePeriod() {
    return widget.periodValue > widget.minPeriodValue;
  }

  bool _canIncreasePeriod() {
    return widget.periodValue < widget.maxPeriodValue;
  }

  Widget _buildPeriodTab({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: widget.enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: isSelected && widget.enabled
              ? AppColors.brandWhite
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: !widget.enabled
                ? AppColors.textSecondary.withOpacity(0.4)
                : (isSelected
                      ? AppColors.primaryGreen
                      : AppColors.textSecondary),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = TimezoneUtils.getSeoulToday();
    final minDate = widget.minValidUntil ?? now;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!widget.hideLabel || !widget.hideCalendarToggle) ...[
          Row(
            children: [
              if (!widget.hideLabel)
                Text(
                  '유효기간',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: widget.enabled
                        ? AppColors.textSecondary
                        : AppColors.textSecondary.withOpacity(0.4),
                  ),
                ),
              if (!widget.hideLabel && !widget.hideCalendarToggle)
                const Spacer(),
              if (!widget.hideCalendarToggle)
                GestureDetector(
                  onTap: widget.enabled
                      ? () {
                          widget.onModeChanged(
                            widget.mode == ValidPeriodMode.calendar
                                ? ValidPeriodMode.period
                                : ValidPeriodMode.calendar,
                          );
                        }
                      : null,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color:
                          widget.mode == ValidPeriodMode.calendar &&
                              widget.enabled
                          ? AppColors.primaryGreen
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SvgPicture.asset(
                      'assets/icons/calendar-icon.svg',
                      width: 20,
                      height: 20,
                      colorFilter: ColorFilter.mode(
                        !widget.enabled
                            ? AppColors.textSecondary.withOpacity(0.4)
                            : (widget.mode == ValidPeriodMode.calendar
                                  ? AppColors.brandWhite
                                  : AppColors.textSecondary),
                        BlendMode.srcIn,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],

        // 캘린더 모드: 시작일/종료일 지정 버튼
        if (widget.mode == ValidPeriodMode.calendar) ...[
          if (widget.onValidFromChanged != null) ...[
            GestureDetector(
              onTap: widget.enabled
                  ? () async {
                      final picked =
                          await DateRangePickerUtil.showSingleDatePicker(
                            context: context,
                            initialDate: widget.validFrom,
                            firstDate: now,
                            title: '시작일 선택',
                          );

                      if (picked != null) {
                        widget.onValidFromChanged!(
                          EnrollmentValidUntilUtil.toSeoulDateOnly(picked),
                        );
                        // 종료일이 시작일보다 이전이면 종료일도 조정
                        if (widget.validUntil.isBefore(picked)) {
                          widget.onValidUntilChanged(
                            EnrollmentValidUntilUtil.toSeoulDateOnly(
                              picked.add(const Duration(days: 30)),
                            ),
                          );
                        }
                      }
                    }
                  : null,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: 16,
                  horizontal: 16,
                ),
                decoration: BoxDecoration(
                  color: widget.enabled
                      ? AppColors.backgroundLight
                      : AppColors.backgroundLight.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Text(
                      '시작일 지정',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: widget.enabled
                            ? AppColors.textSecondary
                            : AppColors.textSecondary.withOpacity(0.5),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _formatDate(widget.validFrom),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: widget.enabled
                            ? AppColors.textPrimary
                            : AppColors.textSecondary.withOpacity(0.5),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.keyboard_arrow_right_rounded,
                      size: 24,
                      color: widget.enabled
                          ? AppColors.textLight
                          : AppColors.textLight.withOpacity(0.5),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          GestureDetector(
            onTap: widget.enabled
                ? () async {
                    final startDateOnly =
                        EnrollmentValidUntilUtil.toSeoulDateOnly(
                          widget.validFrom,
                        );
                    final picked =
                        await DateRangePickerUtil.showSingleDatePicker(
                          context: context,
                          initialDate: widget.validUntil,
                          firstDate: EnrollmentValidUntilUtil.maxDateOnly(
                            minDate,
                            startDateOnly.add(const Duration(days: 1)),
                          ),
                          lastDate: DateTime(2100, 12, 31),
                          title: '종료일 선택',
                        );

                    if (picked != null) {
                      widget.onValidUntilChanged(
                        EnrollmentValidUntilUtil.toSeoulDateOnly(picked),
                      );
                    }
                  }
                : null,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
              decoration: BoxDecoration(
                color: widget.enabled
                    ? AppColors.backgroundLight
                    : AppColors.backgroundLight.withOpacity(0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Text(
                    '종료일 지정',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: widget.enabled
                          ? AppColors.textSecondary
                          : AppColors.textSecondary.withOpacity(0.5),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _formatDate(widget.validUntil),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: widget.enabled
                          ? AppColors.textPrimary
                          : AppColors.textSecondary.withOpacity(0.5),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.keyboard_arrow_right_rounded,
                    size: 24,
                    color: widget.enabled
                        ? AppColors.textLight
                        : AppColors.textLight.withOpacity(0.5),
                  ),
                ],
              ),
            ),
          ),
        ] else ...[
          // 주/달/일 모드: 탭바 + 값 조절 UI
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: widget.enabled
                  ? AppColors.backgroundLight
                  : AppColors.backgroundLight.withOpacity(0.5),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _buildPeriodTab(
                    label: '주',
                    isSelected: widget.periodType == PeriodType.weeks,
                    onTap: () {
                      widget.onPeriodTypeChanged(PeriodType.weeks);
                      widget.onPeriodValueChanged(1);
                    },
                  ),
                ),
                Expanded(
                  child: _buildPeriodTab(
                    label: '달',
                    isSelected: widget.periodType == PeriodType.months,
                    onTap: () {
                      widget.onPeriodTypeChanged(PeriodType.months);
                      widget.onPeriodValueChanged(1);
                    },
                  ),
                ),
                Expanded(
                  child: _buildPeriodTab(
                    label: '일',
                    isSelected: widget.periodType == PeriodType.days,
                    onTap: () {
                      widget.onPeriodTypeChanged(PeriodType.days);
                      widget.onPeriodValueChanged(1);
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // 값 조절 UI
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: widget.enabled
                  ? AppColors.backgroundLight
                  : AppColors.backgroundLight.withOpacity(0.5),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // - 버튼
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: widget.enabled && _canDecreasePeriod()
                        ? () {
                            final newValue = widget.periodValue - 1;
                            widget.onPeriodValueChanged(newValue);
                          }
                        : null,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        Icons.remove_rounded,
                        size: 20,
                        color: widget.enabled && _canDecreasePeriod()
                            ? AppColors.primaryGreen
                            : AppColors.textLight.withOpacity(0.3),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                // 값 표시
                SizedBox(
                  width: 60,
                  child: TextField(
                    controller: _periodController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textAlign: TextAlign.center,
                    enabled: widget.enabled,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: !widget.enabled
                          ? AppColors.textSecondary.withOpacity(0.4)
                          : (widget.periodValue == 0
                                ? AppColors.textSecondary.withOpacity(0.4)
                                : AppColors.textPrimary),
                    ),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: '0',
                      hintStyle: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary.withOpacity(0.4),
                      ),
                      contentPadding: EdgeInsets.zero,
                      isDense: true,
                      suffixText: _getUnitText(),
                      suffixStyle: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: widget.enabled
                            ? AppColors.textSecondary
                            : AppColors.textSecondary.withOpacity(0.4),
                      ),
                    ),
                    onChanged: (value) {
                      if (value.isEmpty) {
                        widget.onPeriodValueChanged(0);
                      } else {
                        final intValue = int.tryParse(value);
                        if (intValue != null &&
                            intValue >= widget.minPeriodValue &&
                            intValue <= widget.maxPeriodValue) {
                          widget.onPeriodValueChanged(intValue);
                        }
                      }
                    },
                    onSubmitted: (value) {
                      if (value.isEmpty) {
                        widget.onPeriodValueChanged(0);
                        _periodController.text = '0';
                      } else {
                        final intValue = int.tryParse(value);
                        if (intValue == null ||
                            intValue < widget.minPeriodValue) {
                          widget.onPeriodValueChanged(widget.minPeriodValue);
                          _periodController.text = widget.minPeriodValue
                              .toString();
                        } else if (intValue > widget.maxPeriodValue) {
                          widget.onPeriodValueChanged(widget.maxPeriodValue);
                          _periodController.text = widget.maxPeriodValue
                              .toString();
                        } else {
                          widget.onPeriodValueChanged(intValue);
                        }
                      }
                    },
                  ),
                ),
                const SizedBox(width: 16),
                // + 버튼
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: widget.enabled && _canIncreasePeriod()
                        ? () {
                            final newValue = widget.periodValue + 1;
                            widget.onPeriodValueChanged(newValue);
                          }
                        : null,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        Icons.add_rounded,
                        size: 20,
                        color: widget.enabled && _canIncreasePeriod()
                            ? AppColors.primaryGreen
                            : AppColors.textLight.withOpacity(0.3),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // 종료일 표시
          Text(
            '종료일: ${_formatDate(widget.validUntil)}',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: widget.enabled
                  ? AppColors.textSecondary
                  : AppColors.textSecondary.withOpacity(0.4),
            ),
          ),
        ],
      ],
    );
  }
}
