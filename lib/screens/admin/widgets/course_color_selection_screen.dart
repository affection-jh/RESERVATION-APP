import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../theme/app_colors.dart';
import '../../../models/course.dart' as reservation_models;
import 'course_basic_info_screen.dart';
import '../../../widgets/course_color_picker_bottom_sheet.dart';
import '../../../widgets/valid_period_input_widget.dart';
import '../../../widgets/reservations_input_widget.dart';
import '../../../utils/timezone_utils.dart';

/// 코스 색상 및 요일 선택 화면 (2단계)
class CourseColorSelectionScreen extends StatefulWidget {
  final CourseBasicInfoData basicInfo;
  final reservation_models.Course? existingCourse;
  final CourseColorSelectionData? savedColorSelection;
  final Function(CourseColorSelectionData) onNext;

  const CourseColorSelectionScreen({
    super.key,
    required this.basicInfo,
    this.existingCourse,
    this.savedColorSelection,
    required this.onNext,
  });

  @override
  State<CourseColorSelectionScreen> createState() =>
      _CourseColorSelectionScreenState();
}

class CourseColorSelectionData {
  final CourseBasicInfoData basicInfo;
  final int selectedColor;
  final Set<int> selectedDays;
  final int defaultTotalReservations; // 등록당 기본 수업 횟수
  final bool useUniformSettings; // 일괄 적용 모드 여부
  final int? uniformTotalReservations; // 일괄 적용 수업 횟수
  final reservation_models.PeriodType? uniformPeriodType; // 일괄 적용 유효기간 단위
  final int? uniformPeriodValue; // 일괄 적용 유효기간 값

  CourseColorSelectionData({
    required this.basicInfo,
    required this.selectedColor,
    required this.selectedDays,
    this.defaultTotalReservations = 0, // 기본값: 0회
    this.useUniformSettings = false,
    this.uniformTotalReservations,
    this.uniformPeriodType,
    this.uniformPeriodValue,
  });
}

class _CourseColorSelectionScreenState
    extends State<CourseColorSelectionScreen> {
  int? _selectedColor; // 선택된 색상 (필수)
  final Set<int> _selectedDays = {}; // 1=월, 2=화, ..., 7=일
  final TextEditingController _totalReservationsController =
      TextEditingController();

  // 일괄 적용 모드 관련
  bool _useUniformSettings = false;
  int _uniformTotalReservations = 0;
  reservation_models.PeriodType _uniformPeriodType =
      reservation_models.PeriodType.weeks;
  int _uniformPeriodValue = 1;
  final TextEditingController _uniformTotalReservationsController =
      TextEditingController();
  final TextEditingController _uniformPeriodController =
      TextEditingController();

  @override
  void initState() {
    super.initState();
    // 저장된 데이터가 있으면 우선 사용 (뒤로 갔다 온 경우)
    if (widget.savedColorSelection != null) {
      _selectedColor = widget.savedColorSelection!.selectedColor;
      _selectedDays.clear();
      _selectedDays.addAll(widget.savedColorSelection!.selectedDays);
      _totalReservationsController.text =
          widget.savedColorSelection!.defaultTotalReservations.toString();
      _useUniformSettings = widget.savedColorSelection!.useUniformSettings;
      _uniformTotalReservations =
          widget.savedColorSelection!.uniformTotalReservations ??
          widget.savedColorSelection!.defaultTotalReservations;
      _uniformPeriodType =
          widget.savedColorSelection!.uniformPeriodType ??
          reservation_models.PeriodType.weeks;
      _uniformPeriodValue = widget.savedColorSelection!.uniformPeriodValue ?? 1;
    } else if (widget.existingCourse != null) {
      // 기존 코스 편집인 경우
      _selectedColor = widget.existingCourse!.color;
      _selectedDays.clear();
      for (final session in widget.existingCourse!.sessions) {
        _selectedDays.add(session.dayOfWeek);
      }
      _totalReservationsController.text =
          widget.existingCourse!.defaultTotalReservations.toString();
      _useUniformSettings = widget.existingCourse!.useUniformSettings;
      _uniformTotalReservations =
          widget.existingCourse!.uniformTotalReservations ??
          widget.existingCourse!.defaultTotalReservations;
      _uniformPeriodType =
          widget.existingCourse!.uniformPeriodType ??
          reservation_models.PeriodType.weeks;
      _uniformPeriodValue = widget.existingCourse!.uniformPeriodValue ?? 1;
    } else {
      // 기본값: 0회
      _totalReservationsController.text = '0';
      _uniformTotalReservations = 0;
    }
    _uniformTotalReservationsController.text =
        _uniformTotalReservations.toString();
    _uniformPeriodController.text = _uniformPeriodValue.toString();
  }

  @override
  void dispose() {
    _totalReservationsController.dispose();
    _uniformTotalReservationsController.dispose();
    _uniformPeriodController.dispose();
    super.dispose();
  }

  bool _isFormValid() {
    final totalReservations = int.tryParse(_totalReservationsController.text);
    final baseValid =
        _selectedColor != null &&
        _selectedDays.isNotEmpty &&
        totalReservations != null &&
        totalReservations >= 0;

    // 일괄 적용 모드가 켜져 있을 때 추가 검증
    if (_useUniformSettings) {
      final uniformTotalText = _uniformTotalReservationsController.text.trim();
      final uniformTotal = int.tryParse(uniformTotalText);

      // 일괄 적용 수업 횟수 검증: 비어있지 않고, 유효한 숫자이며, 0보다 커야 함
      final isUniformTotalValid =
          uniformTotalText.isNotEmpty &&
          uniformTotal != null &&
          uniformTotal > 0;

      // 일괄 적용 유효기간 검증: 0보다 커야 함
      final isPeriodValid = _uniformPeriodValue > 0;

      return baseValid && isUniformTotalValid && isPeriodValid;
    }

    return baseValid;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      body: SafeArea(
        child: Column(
          children: [
            // 메인 콘텐츠
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 헤더
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 16,
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(
                              Icons.arrow_back_ios,
                              size: 24,
                              color: AppColors.primaryGreen,
                            ),
                            onPressed: () => Navigator.of(context).pop(),
                            color: AppColors.textPrimary,
                          ),
                          const Spacer(),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 5),
                            child: Text(
                              '${widget.basicInfo.name} 세부 설정하기',
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                          const SizedBox(height: 40),

                          // 코스 색상 선택
                          GestureDetector(
                            onTap: () {
                              showCourseColorPickerBottomSheet(
                                context,
                                _selectedColor ??
                                    AppColors.brandColorSeriesInt.first,
                                (selectedColor) {
                                  setState(() {
                                    _selectedColor = selectedColor;
                                  });
                                },
                              );
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: AppColors.borderLight,
                                  width: 1,
                                ),
                              ),
                              child: Row(
                                children: [
                                  _selectedColor != null
                                      ? Container(
                                        width: 38,
                                        height: 38,
                                        decoration: BoxDecoration(
                                          color:
                                              _selectedColor != null
                                                  ? Color(_selectedColor!)
                                                  : null,
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                        ),
                                      )
                                      : Container(
                                        width: 38,
                                        height: 38,
                                        decoration: BoxDecoration(
                                          color: AppColors.backgroundLight,
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                        ),
                                      ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      _selectedColor != null
                                          ? '색상 선택됨'
                                          : '코스 대표 색상 선택하기',
                                      style: TextStyle(
                                        fontSize: 16,
                                        color:
                                            _selectedColor != null
                                                ? AppColors.textPrimary
                                                : AppColors.textSecondary,
                                      ),
                                    ),
                                  ),
                                  Icon(
                                    Icons.chevron_right,
                                    color: AppColors.textSecondary,
                                    size: 20,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 22),
                          // 코스 요일 선택
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: AppColors.borderLight,
                                width: 1,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '정기 요일 선택',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textPrimary.withOpacity(
                                      0.8,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 10,
                                  children: [
                                    for (int day = 1; day <= 7; day++)
                                      _buildDayChip(day),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 22),

                          // 일괄 적용 모드
                          _buildUniformSettingsField(),
                        ],
                      ),
                    ),
                    const SizedBox(height: 60),
                  ],
                ),
              ),
            ),
            // 하단 버튼
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed:
                      _isFormValid()
                          ? () {
                            final totalReservations =
                                int.tryParse(
                                  _totalReservationsController.text,
                                ) ??
                                0;
                            widget.onNext(
                              CourseColorSelectionData(
                                basicInfo: widget.basicInfo,
                                selectedColor: _selectedColor!,
                                selectedDays: Set.from(_selectedDays),
                                defaultTotalReservations: totalReservations,
                                useUniformSettings: _useUniformSettings,
                                uniformTotalReservations:
                                    _useUniformSettings
                                        ? _uniformTotalReservations
                                        : null,
                                uniformPeriodType:
                                    _useUniformSettings
                                        ? _uniformPeriodType
                                        : null,
                                uniformPeriodValue:
                                    _useUniformSettings
                                        ? _uniformPeriodValue
                                        : null,
                              ),
                            );
                          }
                          : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        _isFormValid()
                            ? AppColors.primaryGreen
                            : AppColors.borderLight,
                    disabledBackgroundColor: AppColors.borderLight,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    elevation: 0,
                  ),
                  child: Text(
                    '다음',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color:
                          _isFormValid()
                              ? Colors.white
                              : AppColors.textSecondary,
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

  Widget _buildDayChip(int day) {
    const dayNames = ['', '월', '화', '수', '목', '금', '토', '일'];
    final isSelected = _selectedDays.contains(day);

    return GestureDetector(
      onTap: () {
        FocusScope.of(context).unfocus();
        setState(() {
          if (isSelected) {
            _selectedDays.remove(day);
          } else {
            _selectedDays.add(day);
          }
        });
      },
      child: AnimatedScale(
        scale: isSelected ? 1.0 : 0.98,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          decoration: BoxDecoration(
            color:
                isSelected ? AppColors.primaryGreen : AppColors.backgroundLight,
            borderRadius: BorderRadius.circular(54),
            border: Border.all(
              color:
                  isSelected ? AppColors.primaryGreen : AppColors.borderLight,
              width: 1,
            ),
          ),
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 200),
            style: TextStyle(
              color: isSelected ? Colors.white : AppColors.textSecondary,
              fontSize: 16,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
            ),
            child: Text(dayNames[day]),
          ),
        ),
      ),
    );
  }

  /// 일괄 적용 모드 필드
  Widget _buildUniformSettingsField() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.borderLight, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 토글 스위치
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '기본 정보 설정',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary.withOpacity(0.8),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '코스 기본값을 설정합니다\n멤버 등록시 개별적으로 변경 가능합니다',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _useUniformSettings,
                onChanged: (value) {
                  setState(() {
                    _useUniformSettings = value;
                  });
                },
                activeColor:
                    _selectedColor != null
                        ? Color(_selectedColor!)
                        : AppColors.primaryGreen,
              ),
            ],
          ),

          // 일괄 적용 설정 UI (토글이 켜져 있을 때만 표시)
          if (_useUniformSettings) ...[
            const SizedBox(height: 24),
            // 일괄 적용 수업 횟수
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ReservationsInputWidget(
                  controller: _uniformTotalReservationsController,
                  currentValue: _uniformTotalReservations,
                  defaultValue: 0,
                  enabled: true,
                  minValue: 0,
                  maxValue: 999,
                  hideLabel: false,
                  onChanged: (value) {
                    setState(() {
                      _uniformTotalReservations = value;
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 20),
            // 일괄 적용 유효기간
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ValidPeriodInputWidget(
                  // 일괄 적용 유효기간은 "등록/재등록 시점(now) 기준으로 계산"되는 상대 기간만 설정한다.
                  // 코스 생성 시점의 절대 날짜를 저장/적용하면 나중에 유효기간이 꼬일 수 있으므로 캘린더 모드는 지원하지 않음.
                  validFrom: TimezoneUtils.getSeoulDateTime(),
                  validUntil: TimezoneUtils.getSeoulDateTime().add(
                    switch (_uniformPeriodType) {
                      reservation_models.PeriodType.weeks => Duration(
                        days: _uniformPeriodValue * 7,
                      ),
                      reservation_models.PeriodType.days => Duration(
                        days: _uniformPeriodValue,
                      ),
                      reservation_models.PeriodType.months => Duration(
                        days: _uniformPeriodValue * 30,
                      ),
                    },
                  ),
                  periodType: _uniformPeriodType,
                  periodValue: _uniformPeriodValue,
                  mode: ValidPeriodMode.period,
                  enabled: true,
                  minPeriodValue: 0,
                  maxPeriodValue: 999,
                  hideLabel: false,
                  hideCalendarToggle: true, // 일괄 적용 모드에서는 캘린더(절대 날짜) 모드 미지원
                  onModeChanged: (_) {
                    // 캘린더 토글이 숨겨져 있어 호출되지 않지만, 타입상 required라 no-op 처리
                  },
                  onValidFromChanged: null, // calendar 모드 미지원
                  onValidUntilChanged: (_) {
                    // calendar 모드 미지원: 종료일 직접 지정 불가
                  },
                  onPeriodTypeChanged: (type) {
                    setState(() {
                      _uniformPeriodType = type;
                      // 타입 변경 시 기본값 설정
                      if (type == reservation_models.PeriodType.days) {
                        _uniformPeriodValue = 7;
                      } else {
                        _uniformPeriodValue = 1;
                      }
                      _uniformPeriodController.text =
                          _uniformPeriodValue.toString();
                    });
                  },
                  onPeriodValueChanged: (value) {
                    setState(() {
                      _uniformPeriodValue = value;
                    });
                  },
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
