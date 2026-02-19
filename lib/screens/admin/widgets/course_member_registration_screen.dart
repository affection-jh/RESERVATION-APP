import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import '../../../models/course.dart' as models;
import '../../../providers/course_provider.dart';
import '../../../providers/member_provider.dart';
import '../../../providers/place_provider.dart';
import '../../../services/member_service.dart';
import '../../../utils/snackbar_util.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/text_field_decoration_util.dart';
import '../../../utils/timezone_utils.dart';
import '../../../widgets/common_dialog.dart';
import '../../../widgets/reservations_input_widget.dart';
import '../../../widgets/valid_period_input_widget.dart';
import '../../../widgets/defualt_tapbar.dart';

typedef PeriodType = models.PeriodType;

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
  final String placeId;

  const CourseMemberRegistrationScreen({
    super.key,
    required this.onSave,
    required this.courseId,
    required this.placeId,
  });

  @override
  State<CourseMemberRegistrationScreen> createState() =>
      _CourseMemberRegistrationScreenState();
}

class _CourseMemberRegistrationScreenState
    extends State<CourseMemberRegistrationScreen> {
  CourseMemberRegistrationMode _mode = CourseMemberRegistrationMode.inputNew;
  String _lastMemberSearchLogKey = '';

  // 신규 입력 컨트롤러
  late TextEditingController _nameCtrl;
  late TextEditingController _phoneCtrl;
  final FocusNode _nameFocusNode = FocusNode();
  final FocusNode _phoneFocusNode = FocusNode();

  // 기존 멤버 검색
  final TextEditingController _searchCtrl = TextEditingController();

  // 선택된 멤버 (기존 멤버에서 추가 모드)
  String? _selectedMemberName;
  String? _selectedMemberPhone;
  String? _selectedMemberUserId; // ⚠️ 중요: pending 멤버 구분용

  // 현재 추가할 멤버의 설정
  CourseEnrollmentConfig? _currentConfig;
  ValidPeriodMode _currentValidPeriodMode = ValidPeriodMode.period;
  late TextEditingController _currentTotalReservationsCtrl;

  bool _isSaving = false;
  bool _leaveRequested = false;
  bool _isExistingMember = false; // 기존 멤버 여부 (신규 추가 막기용)
  bool _isCheckingPhone = false;
  String? _phoneErrorText;

  @override
  void initState() {
    super.initState();

    _nameCtrl = TextEditingController();
    _phoneCtrl = TextEditingController(text: '010');
    _currentTotalReservationsCtrl = TextEditingController();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeCurrentConfig();
      _ensureMemberProviderPlaceId();
    });
  }

  void _ensureMemberProviderPlaceId() {
    if (!mounted) return;
    Provider.of<MemberProvider>(
      context,
      listen: false,
    ).setPlaceId(widget.placeId);
  }

  String _placeId() =>
      Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id ??
      widget.placeId;

  models.Course _course() => Provider.of<CourseProvider>(
    context,
    listen: false,
  ).courses.firstWhere((c) => c.id == widget.courseId);

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
    final course = _course();

    final now = TimezoneUtils.getSeoulDateTime();
    final defaultTotal = course.defaultTotalReservations;
    final defaultPeriodType = course.defaultPeriodType ?? PeriodType.weeks;
    final defaultPeriodValue = course.defaultPeriodValue ?? 1;

    final Duration duration;
    switch (defaultPeriodType) {
      case models.PeriodType.weeks:
        duration = Duration(days: defaultPeriodValue * 7);
        break;
      case models.PeriodType.days:
        duration = Duration(days: defaultPeriodValue);
        break;
      case models.PeriodType.months:
        duration = Duration(days: defaultPeriodValue * 30);
        break;
    }

    final totalReservations = defaultTotal;
    final periodType = defaultPeriodType;
    final periodValue = defaultPeriodValue;
    final validUntil = now.add(duration);

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
      _currentTotalReservationsCtrl.text =
          totalReservations == 0 ? '' : totalReservations.toString();
    });
  }

  static String _normalizePhone(String phone) {
    var d = phone.replaceAll(RegExp(r'[^\d]'), '');
    if (d.startsWith('82')) d = '0${d.substring(2)}';
    if (!d.startsWith('0')) d = '0$d';
    return d;
  }

  static String _formatPhoneInput(String digitsOnly) {
    if (digitsOnly.isEmpty) return '010';
    if (digitsOnly.length <= 3) return digitsOnly;
    if (digitsOnly.length <= 7) {
      return '${digitsOnly.substring(0, 3)}-${digitsOnly.substring(3)}';
    }
    if (digitsOnly.length <= 11) {
      return '${digitsOnly.substring(0, 3)}-${digitsOnly.substring(3, 7)}-${digitsOnly.substring(7)}';
    }
    return '${digitsOnly.substring(0, 3)}-${digitsOnly.substring(3, 7)}-${digitsOnly.substring(7, 11)}';
  }

  /// 전화번호 중복 여부 (MemberProvider.allMembers = members + pendingMembers)
  Future<bool> _isPhoneDuplicate(String phoneNumber) async {
    final normalized = _normalizePhone(phoneNumber);
    if (normalized.length != 11) return false;

    final memberProvider = Provider.of<MemberProvider>(context, listen: false);
    return memberProvider.allMembers.any(
      (v) => _normalizePhone(v.phoneNumber) == normalized,
    );
  }

  Future<void> _checkPhoneInFirebase(String phoneNumber) async {
    if (_isCheckingPhone) return;

    setState(() {
      _isCheckingPhone = true;
      _phoneErrorText = null;
      _isExistingMember = false;
    });

    final isDuplicate = await _isPhoneDuplicate(phoneNumber);

    if (!mounted) return;

    if (isDuplicate) {
      setState(() {
        _phoneErrorText = '이미 등록된 멤버입니다. 기존 멤버에서 추가해주세요.';
        _isCheckingPhone = false;
        _isExistingMember = true; // 기존 멤버 플래그 설정
      });
    } else {
      setState(() {
        _phoneErrorText = null;
        _isCheckingPhone = false;
        _isExistingMember = false;
      });
    }
  }

  Widget _buildAddButton({
    required bool enabled,
    required VoidCallback onPressed,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      decoration: const BoxDecoration(color: AppColors.backgroundWhite),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: enabled ? onPressed : null,
          icon: Icon(
            Icons.add,
            color: enabled ? Colors.white : AppColors.textSecondary,
          ),
          label:
              _isSaving
                  ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        AppColors.primaryGreen,
                      ),
                    ),
                  )
                  : const Text(
                    '추가',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
          style: ElevatedButton.styleFrom(
            backgroundColor:
                enabled
                    ? AppColors.primaryGreen
                    : AppColors.textSecondary.withValues(alpha: 0.3),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 18),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            elevation: 0,
            disabledBackgroundColor: AppColors.textPrimary.withValues(
              alpha: 0.1,
            ),
          ),
        ),
      ),
    );
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
      _mode =
          index == 0
              ? CourseMemberRegistrationMode.inputNew
              : CourseMemberRegistrationMode.selectExisting;
      _selectedMemberName = null;
      _selectedMemberPhone = null;
      _selectedMemberUserId = null;
      if (index == 1) {
        _currentConfig = null;
      }
    });
    if (index == 1) {
      Provider.of<MemberProvider>(
        context,
        listen: false,
      ).setPlaceId(widget.placeId);
      _initializeCurrentConfig();
    }
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

    // ⚠️ 중요: 기존 멤버에서 추가하는 경우와 신규 입력하는 경우 구분
    final isExistingMemberAdd = _selectedMemberUserId != null;
    final memberProvider = Provider.of<MemberProvider>(context, listen: false);

    if (!isExistingMemberAdd) {
      // 신규 입력 모드: 중복 체크 필요
      // 동기 체크: memberProvider.allMembers에서 즉시 확인
      bool isExistingMemberSync = false;
      for (final v in memberProvider.allMembers) {
        if (_normalizePhone(v.phoneNumber) == normalizedPhone) {
          isExistingMemberSync = true;
          break;
        }
      }

      if (isExistingMemberSync) {
        setState(() {
          _phoneErrorText = '이미 등록된 멤버입니다. 기존 멤버에서 추가해주세요.';
          _isExistingMember = true; // 기존 멤버 플래그 설정 (신규 추가 완전 차단)
        });
        return;
      }

      // 비동기 체크: pendingMembers도 확인
      setState(() {
        _isCheckingPhone = true;
        _phoneErrorText = null;
        _isExistingMember = false;
      });

      final isDuplicate = await _isPhoneDuplicate(trimmedPhone);

      if (!mounted) return;

      if (isDuplicate) {
        setState(() {
          _phoneErrorText = '이미 등록된 멤버입니다. 기존 멤버에서 추가해주세요.';
          _isCheckingPhone = false;
          _isExistingMember = true; // 기존 멤버 플래그 설정 (신규 추가 완전 차단)
        });
        return;
      }
    }

    setState(() {
      _isSaving = true;
      _isCheckingPhone = false;
      _isExistingMember = false;
    });
    if (_leaveRequested) return;

    try {
      // ⚠️ 중요: 기존 멤버에서 추가하는 경우와 신규 입력하는 경우 구분
      final isExistingMemberAdd = _selectedMemberUserId != null;

      if (isExistingMemberAdd) {
        final placeId = _placeId();

        final courseEnrollments = [
          {
            'courseId': widget.courseId,
            'totalReservations': _currentConfig!.totalReservations,
            'validFrom': _currentConfig!.validFrom.toIso8601String(),
            'validUntil': _currentConfig!.validUntil.toIso8601String(),
          },
        ];

        // ⚠️ 중앙 로직: pending/일반 멤버 자동 분기 처리
        final memberService = MemberService();
        final success = await memberService.enrollMemberToCourseOrUpdatePending(
          userId: _selectedMemberUserId!,
          placeId: placeId,
          phoneNumber: trimmedPhone,
          courseEnrollments: courseEnrollments,
          courses: Provider.of<CourseProvider>(context, listen: false).courses,
          adminDisplayName: _selectedMemberName,
        );
        if (_leaveRequested) return;

        if (!success) {
          throw Exception('코스 등록에 실패했습니다.');
        }

        memberProvider.setPlaceId(placeId);
        if (!context.mounted) return;
        SnackbarUtil.showSuccess(context, '추가되었습니다.');
        final nav = Navigator.of(context);
        nav.pop(); // 1) 다이얼로그가 열려 있으면 먼저 제거
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (nav.canPop()) nav.pop(); // 2) 화면까지 닫기
        });
      } else {
        // 신규 멤버 등록 (기존 로직)
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
        if (_leaveRequested) return;

        memberProvider.setPlaceId(_placeId());
        if (!context.mounted) return;
        final nav = Navigator.of(context);
        nav.pop(); // 1) 다이얼로그가 열려 있으면 먼저 제거
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (nav.canPop()) nav.pop(); // 2) 화면까지 닫기
        });
      }
    } catch (e) {
      if (!context.mounted) return;
      final errorStr = e.toString();
      final errorMessage =
          (errorStr.contains('이미 등록되어 있습니다') || errorStr.contains('이미 등록된'))
              ? '이미 등록되어 있습니다.'
              : errorStr.contains('코스 등록에 실패')
              ? '코스 등록에 실패했습니다.'
              : '코스 등록 중 오류가 발생했습니다.';
      SnackbarUtil.showInfo(context, errorMessage);
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<bool> _onWillPop() async {
    if (_isSaving) return _handleBackDuringSave();

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

  Future<bool> _handleBackDuringSave() async {
    if (!_isSaving) return false;
    final leave = await CommonDialog.showSavingLeaveConfirm(
      context: context,
      onLeave: () => _leaveRequested = true,
    );
    if (leave && mounted) {
      setState(() => _isSaving = false);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
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
    final course = _course();

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
        !_isSaving &&
        !_isExistingMember && // 기존 멤버는 신규 추가 불가 (기존 멤버에서 추가만 가능)
        !_isCheckingPhone && // 전화번호 체크 중이면 추가 불가
        _phoneErrorText == null; // 전화번호 에러가 없어야 함

    return Column(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: () => FocusScope.of(context).unfocus(),
            behavior: HitTestBehavior.translucent,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(height: 10),
                  DefaultTapbar(
                    labels: ['신규 입력', '기존 멤버에서 추가'],
                    selectedIndex: _modeIndex,
                    onTabChanged: _onTabChanged,
                  ),
                  const SizedBox(height: 24),

                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      children: [
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

                        const SizedBox(height: 10),

                        TextField(
                          controller: _phoneCtrl,
                          focusNode: _phoneFocusNode,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(13),
                          ],
                          onChanged: (value) {
                            final digits = value.replaceAll(
                              RegExp(r'[^\d]'),
                              '',
                            );
                            final result = _formatPhoneInput(digits);
                            if (_phoneCtrl.text != result) {
                              _phoneCtrl.value = TextEditingValue(
                                text: result,
                                selection: TextSelection.collapsed(
                                  offset: result.length,
                                ),
                              );
                            }
                            if (_normalizePhone(result).length == 11) {
                              _checkPhoneInFirebase(result);
                            } else {
                              setState(() {
                                _phoneErrorText = null;
                                _isExistingMember = false;
                              });
                            }
                          },
                          style: TextStyle(
                            fontSize: 18,
                            color: AppColors.textPrimary,
                          ),
                          decoration: TextFieldDecorationUtil.defaultDecoration(
                            hintText: '전화번호를 입력하세요',
                            fillColor: AppColors.backgroundLight,
                            hasError: _phoneErrorText != null,
                          ).copyWith(errorText: _phoneErrorText),
                        ),
                        const SizedBox(height: 24),

                        _buildCurrentCourseConfigCard(course),
                        const SizedBox(height: 80),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        _buildAddButton(
          enabled: canAdd,
          onPressed: () => _addAndSaveMember(name: name, phoneNumber: phone),
        ),
      ],
    );
  }

  Widget _buildSelectExistingMode() {
    final course = _course();

    // 멤버가 선택되었고 설정이 유효한지 확인
    final hasSelectedMember =
        _selectedMemberName != null && _selectedMemberPhone != null;
    final reservationsValid = (_currentConfig?.totalReservations ?? 0) > 0;
    final periodValid = (_currentConfig?.periodValue ?? 0) > 0;
    final canAdd =
        hasSelectedMember && reservationsValid && periodValid && !_isSaving;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(height: 10),
                DefaultTapbar(
                  labels: ['신규 입력', '기존 멤버에서 추가'],
                  selectedIndex: _modeIndex,
                  onTabChanged: _onTabChanged,
                ),
                const SizedBox(height: 24),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    children: [
                      TextField(
                        style: TextStyle(
                          fontSize: 18,
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
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
                          if (kDebugMode) {
                            final key =
                                'q=$q|members=${memberProvider.allMembers.length}|loading=${memberProvider.isLoading}|mode=$_mode';
                            if (_lastMemberSearchLogKey != key) {
                              _lastMemberSearchLogKey = key;
                              debugPrint(
                                '[CourseMemberRegistrationScreen] search state $key',
                              );
                            }
                          }

                          bool matches(String name, String phone) {
                            if (q.isEmpty) return true;
                            final nq = q.replaceAll(RegExp(r'\s'), '');
                            return name.contains(q) ||
                                phone.contains(q) ||
                                _normalizePhone(phone).contains(nq) ||
                                name.replaceAll(' ', '').contains(nq);
                          }

                          // 이 코스에 미등록 멤버만 (allMembers = members + pendingMembers)
                          final candidateMembers =
                              memberProvider.allMembers.where((v) {
                                if (v.enrolledCourseIds.contains(
                                  widget.courseId,
                                )) {
                                  return false;
                                }
                                return matches(
                                  v.adminDisplayName,
                                  v.phoneNumber,
                                );
                              }).toList();

                          if (kDebugMode) {
                            debugPrint(
                              '[CourseMemberRegistrationScreen] filter result q="$q" total=${memberProvider.allMembers.length} result=${candidateMembers.length}',
                            );
                          }

                          if (memberProvider.isLoading) {
                            return const Center(
                              child: Padding(
                                padding: EdgeInsets.all(40),
                                child: CircularProgressIndicator(
                                  color: AppColors.primaryGreen,
                                ),
                              ),
                            );
                          }

                          // 멤버가 선택되었으면 설정 UI 표시
                          if (_selectedMemberName != null &&
                              _selectedMemberPhone != null) {
                            return Column(
                              children: [
                                _buildCurrentCourseConfigCard(course),
                                const SizedBox(height: 80),
                              ],
                            );
                          }

                          // 검색어가 없으면 멤버 리스트 숨김
                          if (q.isEmpty) {
                            return const SizedBox.shrink();
                          }

                          // 검색어가 있는데 결과가 없으면
                          if (candidateMembers.isEmpty) {
                            return Center(
                              child: Padding(
                                padding: const EdgeInsets.all(40),
                                child: Text(
                                  '검색 결과가 없어요.',
                                  style: TextStyle(
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ),
                            );
                          }

                          // 검색어가 있고 결과가 있으면 멤버 리스트 표시
                          return Column(
                            children: [
                              ...candidateMembers.map(
                                (v) => _buildExistingRow(
                                  name: v.adminDisplayName,
                                  phone: v.phoneNumber,
                                  statusLabel: v.isPending ? '대기' : null,
                                  onTap: () {
                                    setState(() {
                                      _selectedMemberName = v.adminDisplayName;
                                      _selectedMemberPhone = v.phoneNumber;
                                      _selectedMemberUserId = v.userId;
                                    });
                                    _initializeCurrentConfig();
                                  },
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
              ],
            ),
          ),
        ),

        if (hasSelectedMember)
          _buildAddButton(
            enabled: canAdd,
            onPressed:
                () => _addAndSaveMember(
                  name: _selectedMemberName!,
                  phoneNumber: _selectedMemberPhone!,
                ),
          ),
      ],
    );
  }

  Widget _buildExistingRow({
    required String name,
    required String phone,
    required VoidCallback onTap,
    String? statusLabel,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        decoration: BoxDecoration(
          color: AppColors.backgroundLight,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    phone,
                    style: TextStyle(
                      fontSize: 16,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.add_circle, color: AppColors.primaryGreen, size: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildCurrentCourseConfigCard(models.Course course) {
    if (_currentConfig == null) {
      return const SizedBox.shrink();
    }

    final currentValue = _currentConfig!.totalReservations;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.borderLight.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 선택된 멤버 정보 칩 (카드 상단)
          if (_selectedMemberName != null && _selectedMemberPhone != null)
            Container(
              margin: const EdgeInsets.only(bottom: 18),
              child: Row(
                children: [
                  // 멤버 정보 칩
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.backgroundLight,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              _selectedMemberName!,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '•',
                            style: TextStyle(color: AppColors.textSecondary),
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Text(
                                _selectedMemberPhone!,
                                style: TextStyle(
                                  fontSize: 15,
                                  color: AppColors.textSecondary,
                                  fontWeight: FontWeight.w500,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: Icon(
                      Icons.close,
                      color: AppColors.textSecondary,
                      size: 20,
                    ),
                    onPressed: () {
                      setState(() {
                        _selectedMemberName = null;
                        _selectedMemberPhone = null;
                        _currentConfig = null;
                      });
                      _initializeCurrentConfig();
                    },
                  ),
                ],
              ),
            ),
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
    required models.Course course,
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
