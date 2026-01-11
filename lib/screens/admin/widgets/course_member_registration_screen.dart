import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../models/course.dart' as reservation_models;
import '../../../providers/course_provider.dart';
import '../../../providers/member_provider.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/text_field_decoration_util.dart';
import '../../../utils/timezone_utils.dart';
import '../../../widgets/common_dialog.dart';
import '../../../widgets/reservations_input_widget.dart';
import '../../../widgets/valid_period_input_widget.dart';
import '../../../widgets/defualt_tapbar.dart';

typedef PeriodType = reservation_models.PeriodType;

/// 코스 상세보기 전용 멤버 등록 화면 모드
enum CourseMemberRegistrationMode {
  inputNew, // 신규 입력
  selectExisting, // 기존 멤버 검색/선택
}

/// 코스별 등록 설정 데이터
class CourseEnrollmentConfig {
  final String courseId;
  int totalReservations;
  DateTime validFrom;
  DateTime validUntil;
  PeriodType periodType;
  int periodValue;
  ValidPeriodMode validPeriodMode;

  CourseEnrollmentConfig({
    required this.courseId,
    required this.totalReservations,
    required this.validFrom,
    required this.validUntil,
    this.periodType = PeriodType.weeks,
    this.periodValue = 1,
    this.validPeriodMode = ValidPeriodMode.period,
  });

  CourseEnrollmentConfig copy() {
    return CourseEnrollmentConfig(
      courseId: courseId,
      totalReservations: totalReservations,
      validFrom: validFrom,
      validUntil: validUntil,
      periodType: periodType,
      periodValue: periodValue,
      validPeriodMode: validPeriodMode,
    );
  }
}

/// 코스 상세보기 전용 멤버 등록 화면
///
/// 핵심 UX:
/// - 신규 입력 또는 기존 멤버 검색/선택
/// - 한 번에 한 명씩만 추가 가능 (추가 시 바로 저장)
class CourseMemberRegistrationScreen extends StatefulWidget {
  final Function(List<Map<String, dynamic>>) onSave;
  final String courseId;

  const CourseMemberRegistrationScreen({
    super.key,
    required this.onSave,
    required this.courseId,
  });

  @override
  State<CourseMemberRegistrationScreen> createState() =>
      _CourseMemberRegistrationScreenState();
}

class _CourseMemberRegistrationScreenState
    extends State<CourseMemberRegistrationScreen> {
  CourseMemberRegistrationMode _mode = CourseMemberRegistrationMode.inputNew;

  // 신규 입력 컨트롤러
  late TextEditingController _nameCtrl;
  late TextEditingController _phoneCtrl;
  final FocusNode _nameFocusNode = FocusNode();
  final FocusNode _phoneFocusNode = FocusNode();

  // 기존 멤버 검색
  final TextEditingController _searchCtrl = TextEditingController();

  // 현재 추가할 멤버의 설정
  CourseEnrollmentConfig? _currentConfig;
  ValidPeriodMode _currentValidPeriodMode = ValidPeriodMode.period;
  late TextEditingController _currentTotalReservationsCtrl;

  bool _isSaving = false;

  @override
  void initState() {
    super.initState();

    _nameCtrl = TextEditingController();
    _phoneCtrl = TextEditingController(text: '010');
    _currentTotalReservationsCtrl = TextEditingController();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeCurrentConfig();
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _searchCtrl.dispose();
    _currentTotalReservationsCtrl.dispose();
    _nameFocusNode.dispose();
    _phoneFocusNode.dispose();
    super.dispose();
  }

  void _initializeCurrentConfig() {
    if (!mounted) return;
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final course = courseProvider.courses.firstWhere(
      (c) => c.id == widget.courseId,
      orElse: () => throw Exception('Course not found: ${widget.courseId}'),
    );

    final now = TimezoneUtils.getSeoulDateTime();
    final useUniform = course.useUniformSettings;
    final uniformTotal =
        course.uniformTotalReservations ?? course.defaultTotalReservations;
    final uniformPeriodType = course.uniformPeriodType ?? PeriodType.weeks;
    final uniformPeriodValue = course.uniformPeriodValue ?? 1;

    final Duration duration;
    switch (uniformPeriodType) {
      case reservation_models.PeriodType.weeks:
        duration = Duration(days: uniformPeriodValue * 7);
        break;
      case reservation_models.PeriodType.days:
        duration = Duration(days: uniformPeriodValue);
        break;
      case reservation_models.PeriodType.months:
        duration = Duration(days: uniformPeriodValue * 30);
        break;
    }

    final totalReservations = useUniform ? uniformTotal : 0;
    final periodType = useUniform ? uniformPeriodType : PeriodType.weeks;
    final periodValue = useUniform ? uniformPeriodValue : 1;
    final validUntil = useUniform
        ? now.add(duration)
        : now.add(const Duration(days: 7));

    setState(() {
      _currentConfig = CourseEnrollmentConfig(
        courseId: widget.courseId,
        totalReservations: totalReservations,
        validFrom: now,
        validUntil: validUntil,
        periodType: periodType,
        periodValue: periodValue,
        validPeriodMode: ValidPeriodMode.period,
      );
      _currentValidPeriodMode = ValidPeriodMode.period;
      _currentTotalReservationsCtrl.text = totalReservations == 0
          ? ''
          : totalReservations.toString();
    });
  }

  String _normalizePhone(String phoneNumber) {
    var digits = phoneNumber.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.startsWith('82')) {
      digits = '0${digits.substring(2)}';
    }
    if (!digits.startsWith('0')) {
      digits = '0$digits';
    }
    return digits;
  }

  bool _isConfigValid() {
    return (_currentConfig?.totalReservations ?? 0) > 0 &&
        (_currentConfig?.periodValue ?? 0) > 0;
  }

  int get _modeIndex {
    switch (_mode) {
      case CourseMemberRegistrationMode.inputNew:
        return 0;
      case CourseMemberRegistrationMode.selectExisting:
        return 1;
    }
  }

  void _onTabChanged(int index) {
    setState(() {
      _mode = index == 0
          ? CourseMemberRegistrationMode.inputNew
          : CourseMemberRegistrationMode.selectExisting;
    });
  }

  void _resetNewInput() {
    _nameCtrl.clear();
    _phoneCtrl.text = '010';
    _nameFocusNode.requestFocus();
  }

  Future<void> _addAndSaveMember({
    required String name,
    required String phoneNumber,
  }) async {
    final trimmedName = name.trim();
    final trimmedPhone = phoneNumber.trim();
    final normalizedPhone = _normalizePhone(trimmedPhone);

    if (trimmedName.isEmpty || trimmedPhone.isEmpty) return;
    if (normalizedPhone.length != 11) return;
    if (_currentConfig == null) return;
    if (!_isConfigValid()) return;

    if (_isSaving) return;

    setState(() {
      _isSaving = true;
    });

    try {
      final payload = [
        {
          'name': trimmedName,
          'phoneNumber': trimmedPhone,
          'courseEnrollments': [
            {
              'courseId': widget.courseId,
              'totalReservations': _currentConfig!.totalReservations,
              'validFrom': _currentConfig!.validFrom.toIso8601String(),
              'validUntil': _currentConfig!.validUntil.toIso8601String(),
            },
          ],
        },
      ];

      await widget.onSave(payload);

      if (mounted) {
        // 저장 성공 후 입력 필드 초기화
        _resetNewInput();
        // 설정도 다시 초기화
        _initializeCurrentConfig();
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<bool> _onWillPop() async {
    final hasInput =
        _nameCtrl.text.trim().isNotEmpty ||
        (_phoneCtrl.text.trim().isNotEmpty && _phoneCtrl.text.trim() != '010');

    if (!hasInput) return true;

    final shouldPop = await CommonDialog.show(
      context: context,
      title: '나가시겠습니까?',
      message: '입력한 내용이 저장되지 않습니다.',
      cancelText: '취소',
      confirmText: '나가기',
      confirmButtonColor: AppColors.primaryGreen,
      onCancel: () => Navigator.of(context).pop(false),
      onConfirm: () => Navigator.of(context).pop(true),
    );
    return shouldPop ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (!didPop) {
          final shouldPop = await _onWillPop();
          if (shouldPop && context.mounted) {
            Navigator.of(context).pop();
          }
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.backgroundWhite,
        appBar: AppBar(
          scrolledUnderElevation: 0,
          backgroundColor: AppColors.backgroundWhite,
          elevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_ios, color: AppColors.textPrimary),
            onPressed: () async {
              final shouldPop = await _onWillPop();
              if (shouldPop && context.mounted) {
                Navigator.of(context).pop();
              }
            },
          ),
          centerTitle: false,
        ),
        body: SafeArea(
          child: switch (_mode) {
            CourseMemberRegistrationMode.inputNew => _buildInputNewMode(),
            CourseMemberRegistrationMode.selectExisting =>
              _buildSelectExistingMode(),
          },
        ),
      ),
    );
  }

  Widget _buildInputNewMode() {
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final course = courseProvider.courses.firstWhere(
      (c) => c.id == widget.courseId,
    );

    final name = _nameCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();
    final normalized = _normalizePhone(phone);
    final isPhoneValid = normalized.length == 11;

    final reservationsValid = (_currentConfig?.totalReservations ?? 0) > 0;
    final periodValid = (_currentConfig?.periodValue ?? 0) > 0;

    final canAdd =
        name.isNotEmpty &&
        phone.isNotEmpty &&
        isPhoneValid &&
        reservationsValid &&
        periodValid &&
        !_isSaving;

    return Column(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: () => FocusScope.of(context).unfocus(),
            behavior: HitTestBehavior.translucent,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DefaultTapbar(
                    labels: ['신규 입력', '기존 멤버에서 추가'],
                    selectedIndex: _modeIndex,
                    onTabChanged: _onTabChanged,
                  ),
                  const SizedBox(height: 24),

                  TextField(
                    controller: _nameCtrl,
                    focusNode: _nameFocusNode,
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => _phoneFocusNode.requestFocus(),
                    style: TextStyle(
                      fontSize: 18,
                      color: AppColors.textPrimary,
                    ),
                    decoration: TextFieldDecorationUtil.defaultDecoration(
                      hintText: '이름을 입력하세요',
                      fillColor: AppColors.backgroundLight,
                    ),
                  ),
                  const SizedBox(height: 16),

                  TextField(
                    controller: _phoneCtrl,
                    focusNode: _phoneFocusNode,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(13),
                    ],
                    onChanged: (value) {
                      final digitsOnly = value.replaceAll(RegExp(r'[^\d]'), '');
                      String formatted = digitsOnly.isEmpty
                          ? '010'
                          : digitsOnly;

                      String result = '';
                      if (formatted.length <= 3) {
                        result = formatted;
                      } else if (formatted.length <= 7) {
                        result =
                            '${formatted.substring(0, 3)}-${formatted.substring(3)}';
                      } else if (formatted.length <= 11) {
                        result =
                            '${formatted.substring(0, 3)}-${formatted.substring(3, 7)}-${formatted.substring(7)}';
                      } else {
                        result =
                            '${formatted.substring(0, 3)}-${formatted.substring(3, 7)}-${formatted.substring(7, 11)}';
                      }

                      if (_phoneCtrl.text != result) {
                        _phoneCtrl.value = TextEditingValue(
                          text: result,
                          selection: TextSelection.collapsed(
                            offset: result.length,
                          ),
                        );
                      }
                      setState(() {});
                    },
                    style: TextStyle(
                      fontSize: 18,
                      color: AppColors.textPrimary,
                    ),
                    decoration: TextFieldDecorationUtil.defaultDecoration(
                      hintText: '전화번호를 입력하세요',
                      fillColor: AppColors.backgroundLight,
                    ),
                  ),
                  const SizedBox(height: 24),

                  _buildCurrentCourseConfigCard(course),
                  const SizedBox(height: 80),
                ],
              ),
            ),
          ),
        ),

        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          decoration: const BoxDecoration(color: AppColors.backgroundWhite),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: canAdd
                  ? () => _addAndSaveMember(name: name, phoneNumber: phone)
                  : null,
              icon: Icon(
                Icons.add,
                color: canAdd ? Colors.white : AppColors.textSecondary,
              ),
              label: _isSaving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Text(
                      '추가',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
              style: ElevatedButton.styleFrom(
                backgroundColor: canAdd
                    ? AppColors.primaryGreen
                    : AppColors.textSecondary.withOpacity(0.3),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                elevation: 0,
                disabledBackgroundColor: AppColors.textPrimary.withOpacity(0.1),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSelectExistingMode() {
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final course = courseProvider.courses.firstWhere(
      (c) => c.id == widget.courseId,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DefaultTapbar(
                  labels: ['신규 입력', '기존 멤버에서 추가'],
                  selectedIndex: _modeIndex,
                  onTabChanged: _onTabChanged,
                ),
                const SizedBox(height: 24),

                TextField(
                  controller: _searchCtrl,
                  onChanged: (_) => setState(() {}),
                  decoration: TextFieldDecorationUtil.defaultDecoration(
                    hintText: '이름 또는 전화번호로 검색',
                    prefixIcon: Icon(
                      Icons.search,
                      color: AppColors.textSecondary,
                    ),
                    fillColor: AppColors.backgroundLight,
                  ),
                ),
                const SizedBox(height: 16),

                Consumer<MemberProvider>(
                  builder: (context, memberProvider, _) {
                    final q = _searchCtrl.text.trim();

                    bool matches(String name, String phone) {
                      if (q.isEmpty) return true;
                      final nq = q.replaceAll(RegExp(r'\s'), '');
                      return name.contains(q) ||
                          phone.contains(q) ||
                          _normalizePhone(phone).contains(nq) ||
                          name.replaceAll(' ', '').contains(nq);
                    }

                    final users = memberProvider.members.where((u) {
                      if (u.isEnrolledInCourse(widget.courseId)) return false;
                      return matches(u.name, u.phoneNumber);
                    }).toList();

                    if (memberProvider.isLoading) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(40),
                          child: CircularProgressIndicator(),
                        ),
                      );
                    }

                    if (users.isEmpty) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(40),
                          child: Text(
                            '검색 결과가 없어요.',
                            style: TextStyle(color: AppColors.textSecondary),
                          ),
                        ),
                      );
                    }

                    return Column(
                      children: [
                        _buildCurrentCourseConfigCard(course),
                        const SizedBox(height: 16),
                        ...users.map(
                          (u) => _buildExistingRow(
                            name: u.name,
                            phone: u.phoneNumber,
                            onTap: () => _addAndSaveMember(
                              name: u.name,
                              phoneNumber: u.phoneNumber,
                            ),
                          ),
                        ),
                        const SizedBox(height: 80),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildExistingRow({
    required String name,
    required String phone,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.backgroundLight,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(phone, style: TextStyle(color: AppColors.textSecondary)),
                ],
              ),
            ),
            Icon(Icons.add_circle, color: AppColors.primaryGreen),
          ],
        ),
      ),
    );
  }

  Widget _buildCurrentCourseConfigCard(reservation_models.Course course) {
    if (_currentConfig == null) {
      return const SizedBox.shrink();
    }

    final currentValue = _currentConfig!.totalReservations;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.borderLight.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '예약 가능 횟수',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          ReservationsInputWidget(
            controller: _currentTotalReservationsCtrl,
            currentValue: currentValue,
            defaultValue: course.defaultTotalReservations,
            enabled: true,
            onChanged: (value) {
              setState(() {
                _currentConfig!.totalReservations = value;
              });
            },
          ),
          const SizedBox(height: 18),
          _buildValidPeriodField(
            course: course,
            config: _currentConfig!,
            mode: _currentValidPeriodMode,
            onModeChanged: (m) => setState(() => _currentValidPeriodMode = m),
            onConfigChanged: () => setState(() {}),
          ),
        ],
      ),
    );
  }

  Widget _buildValidPeriodField({
    required reservation_models.Course course,
    required CourseEnrollmentConfig config,
    required ValidPeriodMode mode,
    required ValueChanged<ValidPeriodMode> onModeChanged,
    required VoidCallback onConfigChanged,
  }) {
    final now = TimezoneUtils.getSeoulDateTime();

    void updateValidUntil() {
      final currentValidFrom = config.validFrom;
      Duration duration;
      switch (config.periodType) {
        case PeriodType.weeks:
          duration = Duration(days: config.periodValue * 7);
          break;
        case PeriodType.days:
          duration = Duration(days: config.periodValue);
          break;
        case PeriodType.months:
          duration = Duration(days: config.periodValue * 30);
          break;
      }
      config.validUntil = currentValidFrom.add(duration);
    }

    return ValidPeriodInputWidget(
      validFrom: config.validFrom,
      validUntil: config.validUntil,
      periodType: config.periodType,
      periodValue: config.periodValue,
      mode: mode,
      enabled: true,
      minValidUntil: now,
      maxPeriodValue: 999,
      minPeriodValue: 0,
      onModeChanged: (m) {
        config.validPeriodMode = m;
        onModeChanged(m);
        if (m == ValidPeriodMode.period) {
          config.validFrom = now;
          updateValidUntil();
        }
        onConfigChanged();
      },
      onValidFromChanged: (date) {
        config.validFrom = date;
        if (config.validUntil.isBefore(date)) {
          config.validUntil = date.add(const Duration(days: 30));
        }
        onConfigChanged();
      },
      onValidUntilChanged: (date) {
        config.validUntil = date;
        onConfigChanged();
      },
      onPeriodTypeChanged: (type) {
        config.validPeriodMode = ValidPeriodMode.period;
        onModeChanged(ValidPeriodMode.period);
        config.periodType = type;
        config.periodValue = type == PeriodType.days ? 7 : 1;
        updateValidUntil();
        onConfigChanged();
      },
      onPeriodValueChanged: (value) {
        config.validPeriodMode = ValidPeriodMode.period;
        onModeChanged(ValidPeriodMode.period);
        config.periodValue = value;
        updateValidUntil();
        onConfigChanged();
      },
    );
  }
}
