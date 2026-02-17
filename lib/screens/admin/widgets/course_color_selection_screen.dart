import 'package:flutter/material.dart';
import '../../../theme/app_colors.dart';
import '../../../models/course.dart' as reservation_models;
import 'course_basic_info_screen.dart';
import '../../../widgets/course_color_picker_bottom_sheet.dart';
import '../../../widgets/valid_period_input_widget.dart';
import '../../../widgets/reservations_input_widget.dart';
import '../../../utils/timezone_utils.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

abstract class _Layout {
  _Layout._();
  static const double horizontalPadding = 16.0;
  static const double verticalPadding = 16.0;
  static const double borderRadius = 20.0;
  static const double chipBorderRadius = 54.0;
  static const int animationDuration = 200;
}

const _dayNames = ['', '월', '화', '수', '목', '금', '토', '일'];

// ---------------------------------------------------------------------------
// Data
// ---------------------------------------------------------------------------

/// 코스 색상 및 요일 선택 화면 (2단계)에서 넘기는 데이터
class CourseColorSelectionData {
  const CourseColorSelectionData({
    required this.basicInfo,
    required this.selectedColor,
    required this.selectedDays,
    this.defaultTotalReservations = 0,
    this.useUniformSettings = false,
    this.uniformTotalReservations,
    this.uniformPeriodType,
    this.uniformPeriodValue,
  });

  final CourseBasicInfoData basicInfo;
  final int selectedColor;
  final Set<int> selectedDays;
  final int defaultTotalReservations;
  final bool useUniformSettings;
  final int? uniformTotalReservations;
  final reservation_models.PeriodType? uniformPeriodType;
  final int? uniformPeriodValue;
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

/// 코스 색상 및 요일 선택 화면 (2단계)
class CourseColorSelectionScreen extends StatefulWidget {
  const CourseColorSelectionScreen({
    super.key,
    required this.basicInfo,
    this.existingCourse,
    this.savedColorSelection,
    required this.onNext,
  });

  final CourseBasicInfoData basicInfo;
  final reservation_models.Course? existingCourse;
  final CourseColorSelectionData? savedColorSelection;
  final void Function(CourseColorSelectionData) onNext;

  @override
  State<CourseColorSelectionScreen> createState() =>
      _CourseColorSelectionScreenState();
}

class _CourseColorSelectionScreenState extends State<CourseColorSelectionScreen> {
  int? _selectedColor;
  final Set<int> _selectedDays = {};
  bool _useUniformSettings = false;
  int _uniformTotalReservations = 0;
  reservation_models.PeriodType _uniformPeriodType =
      reservation_models.PeriodType.weeks;
  int _uniformPeriodValue = 1;

  late final TextEditingController _totalReservationsController;
  late final TextEditingController _uniformTotalReservationsController;
  late final TextEditingController _uniformPeriodController;

  @override
  void initState() {
    super.initState();
    _totalReservationsController = TextEditingController();
    _uniformTotalReservationsController = TextEditingController();
    _uniformPeriodController = TextEditingController();
    _applyInitialState();
  }

  void _applyInitialState() {
    final saved = widget.savedColorSelection;
    final existing = widget.existingCourse;

    if (saved != null) {
      _selectedColor = saved.selectedColor;
      _selectedDays
        ..clear()
        ..addAll(saved.selectedDays);
      _totalReservationsController.text = saved.defaultTotalReservations.toString();
      _useUniformSettings = saved.useUniformSettings;
      _uniformTotalReservations =
          saved.uniformTotalReservations ?? saved.defaultTotalReservations;
      _uniformPeriodType =
          saved.uniformPeriodType ?? reservation_models.PeriodType.weeks;
      _uniformPeriodValue = saved.uniformPeriodValue ?? 1;
    } else if (existing != null) {
      _selectedColor = existing.color;
      _selectedDays
        ..clear()
        ..addAll(existing.sessions.map((s) => s.dayOfWeek));
      _totalReservationsController.text =
          existing.defaultTotalReservations.toString();
      _useUniformSettings = existing.defaultPeriodType != null;
      _uniformTotalReservations = existing.defaultTotalReservations;
      _uniformPeriodType =
          existing.defaultPeriodType ?? reservation_models.PeriodType.weeks;
      _uniformPeriodValue = existing.defaultPeriodValue ?? 1;
    } else {
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

  bool get _isFormValid {
    final total = int.tryParse(_totalReservationsController.text);
    if (_selectedColor == null ||
        _selectedDays.isEmpty ||
        total == null ||
        total < 0) {
      return false;
    }
    if (!_useUniformSettings) {
      return true;
    }
    final uniformTotalText =
        _uniformTotalReservationsController.text.trim();
    final uniformTotal = int.tryParse(uniformTotalText);
    final uniformValid = uniformTotalText.isNotEmpty &&
        uniformTotal != null &&
        uniformTotal > 0;
    final periodValid = _uniformPeriodValue > 0;
    return uniformValid && periodValid;
  }

  void _submit() {
    if (!_isFormValid || _selectedColor == null) return;
    final totalReservations =
        int.tryParse(_totalReservationsController.text) ?? 0;
    widget.onNext(CourseColorSelectionData(
      basicInfo: widget.basicInfo,
      selectedColor: _selectedColor!,
      selectedDays: Set.from(_selectedDays),
      defaultTotalReservations: totalReservations,
      useUniformSettings: _useUniformSettings,
      uniformTotalReservations:
          _useUniformSettings ? _uniformTotalReservations : null,
      uniformPeriodType: _useUniformSettings ? _uniformPeriodType : null,
      uniformPeriodValue: _useUniformSettings ? _uniformPeriodValue : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isValid = _isFormValid;
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeader(),
                    const SizedBox(height: 20),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: _Layout.horizontalPadding,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildTitle(),
                          const SizedBox(height: 40),
                          _buildColorSelectionTile(context),
                          const SizedBox(height: 22),
                          _buildDaySelectionSection(),
                          const SizedBox(height: 22),
                          _buildUniformSettingsField(),
                        ],
                      ),
                    ),
                    const SizedBox(height: 60),
                  ],
                ),
              ),
            ),
            _buildNextButton(isValid),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
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
    );
  }

  Widget _buildTitle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Text(
        '${widget.basicInfo.name} 세부 설정하기',
        style: const TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.bold,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }

  Widget _buildColorSelectionTile(BuildContext context) {
    final hasColor = _selectedColor != null;
    final color = _selectedColor ?? AppColors.brandColorSeriesInt.first;
    return GestureDetector(
      onTap: () {
        showCourseColorPickerBottomSheet(
          context,
          color,
          (selectedColor) {
            if (context.mounted) {
              setState(() => _selectedColor = selectedColor);
            }
          },
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: _Layout.horizontalPadding,
          vertical: 12,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_Layout.borderRadius),
          border: Border.all(
            color: AppColors.borderLight,
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: hasColor
                    ? Color(_selectedColor!)
                    : AppColors.backgroundLight,
                borderRadius: BorderRadius.circular(_Layout.borderRadius),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                hasColor ? '색상 선택됨' : '코스 대표 색상 선택하기',
                style: TextStyle(
                  fontSize: 16,
                  color: hasColor
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                ),
              ),
            ),
            const Icon(
              Icons.chevron_right,
              color: AppColors.textSecondary,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDaySelectionSection() {
    return Container(
      padding: const EdgeInsets.all(_Layout.verticalPadding),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_Layout.borderRadius),
        border: Border.all(color: AppColors.borderLight, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '정기 요일 선택',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 10,
            children: List.generate(7, (i) => _buildDayChip(i + 1)),
          ),
        ],
      ),
    );
  }

  Widget _buildDayChip(int day) {
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
        duration: const Duration(milliseconds: _Layout.animationDuration),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: _Layout.animationDuration),
          curve: Curves.easeInOut,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.primaryGreen
                : AppColors.backgroundLight,
            borderRadius: BorderRadius.circular(_Layout.chipBorderRadius),
            border: Border.all(
              color: isSelected
                  ? AppColors.primaryGreen
                  : AppColors.borderLight,
              width: 1,
            ),
          ),
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: _Layout.animationDuration),
            style: TextStyle(
              color: isSelected ? Colors.white : AppColors.textSecondary,
              fontSize: 16,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
            ),
            child: Text(_dayNames[day]),
          ),
        ),
      ),
    );
  }

  Widget _buildUniformSettingsField() {
    final labelColor = AppColors.textPrimary.withValues(alpha: 0.8);
    return Container(
      padding: const EdgeInsets.all(_Layout.verticalPadding),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_Layout.borderRadius),
        border: Border.all(color: AppColors.borderLight, width: 1),
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
                    Text(
                      '기본 정보 설정',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: labelColor,
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
                onChanged: (value) =>
                    setState(() => _useUniformSettings = value),
                activeColor: _selectedColor != null
                    ? Color(_selectedColor!)
                    : AppColors.primaryGreen,
              ),
            ],
          ),
          if (_useUniformSettings) ...[
            const SizedBox(height: 24),
            _buildUniformTotalReservationsInput(),
            const SizedBox(height: 20),
            _buildUniformPeriodInput(),
          ],
        ],
      ),
    );
  }

  Widget _buildUniformTotalReservationsInput() {
    return ReservationsInputWidget(
      controller: _uniformTotalReservationsController,
      currentValue: _uniformTotalReservations,
      defaultValue: 0,
      enabled: true,
      minValue: 0,
      maxValue: 999,
      hideLabel: false,
      onChanged: (value) =>
          setState(() => _uniformTotalReservations = value),
    );
  }

  Widget _buildUniformPeriodInput() {
    final now = TimezoneUtils.getSeoulDateTime();
    final duration = switch (_uniformPeriodType) {
      reservation_models.PeriodType.weeks =>
        Duration(days: _uniformPeriodValue * 7),
      reservation_models.PeriodType.days =>
        Duration(days: _uniformPeriodValue),
      reservation_models.PeriodType.months =>
        Duration(days: _uniformPeriodValue * 30),
    };
    return ValidPeriodInputWidget(
      validFrom: now,
      validUntil: now.add(duration),
      periodType: _uniformPeriodType,
      periodValue: _uniformPeriodValue,
      mode: ValidPeriodMode.period,
      enabled: true,
      minPeriodValue: 0,
      maxPeriodValue: 999,
      hideLabel: false,
      hideCalendarToggle: true,
      onModeChanged: (_) {},
      onValidFromChanged: null,
      onValidUntilChanged: (_) {},
      onPeriodTypeChanged: (type) {
        setState(() {
          _uniformPeriodType = type;
          _uniformPeriodValue = type == reservation_models.PeriodType.days
              ? 7
              : 1;
          _uniformPeriodController.text = _uniformPeriodValue.toString();
        });
      },
      onPeriodValueChanged: (value) {
        setState(() => _uniformPeriodValue = value);
      },
    );
  }

  Widget _buildNextButton(bool isValid) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: isValid ? _submit : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: isValid ? AppColors.primaryGreen : AppColors.borderLight,
            disabledBackgroundColor: AppColors.borderLight,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(_Layout.borderRadius),
            ),
            elevation: 0,
          ),
          child: Text(
            '다음',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: isValid ? Colors.white : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
