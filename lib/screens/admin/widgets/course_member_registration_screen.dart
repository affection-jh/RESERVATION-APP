import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import '../../../models/course.dart' as reservation_models;
import '../../../models/course_enrollment.dart';
import '../../../models/pending_member.dart';
import '../../../models/user.dart';
import '../../../providers/course_provider.dart';
import '../../../providers/member_provider.dart';
import '../../../providers/place_provider.dart';
import '../../../services/firestore_service.dart';
import '../../../services/member_service.dart';
import '../../../utils/snackbar_util.dart';
import '../../../utils/member_utils.dart';
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
  String? _memberLoadRequestedPlaceId;

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
      _loadMembersIfNeeded();
    });
  }

  /// 현재 플레이스의 멤버를 로드 (필요한 경우에만)
  Future<void> _loadMembersIfNeeded() async {
    if (!mounted) return;
    final memberProvider = Provider.of<MemberProvider>(context, listen: false);
    final placeId = widget.placeId;

    // 멤버가 이미 로드되어 있지 않은 경우에만 로드
    if (memberProvider.members.isEmpty) {
      try {
        if (kDebugMode) {
          debugPrint(
            '[CourseMemberRegistrationScreen] loadMembersIfNeeded placeId=$placeId (members empty -> load)',
          );
        }
        await memberProvider.loadMembers(placeId);
      } catch (e) {
        // 에러 발생 시에도 계속 진행
        debugPrint('멤버 로드 실패: $e');
      }
    } else {
      if (kDebugMode) {
        debugPrint(
          '[CourseMemberRegistrationScreen] loadMembersIfNeeded placeId=$placeId (already loaded count=${memberProvider.members.length})',
        );
      }
    }
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

  Future<bool> _isPhoneDuplicateInFirebase(String phoneNumber) async {
    final normalizedPhone = _normalizePhone(phoneNumber);
    if (normalizedPhone.length != 11) return false;

    try {
      final memberProvider = Provider.of<MemberProvider>(
        context,
        listen: false,
      );
      final firestoreService = FirestoreService();
      final placeId = widget.placeId;

      // 1. 현재 플레이스의 멤버 목록에서 확인
      for (final member in memberProvider.members) {
        if (_normalizePhone(member.phoneNumber) == normalizedPhone) {
          return true;
        }
      }

      // 2. pendingMembers에서 확인
      final pendingId = '${placeId}_$normalizedPhone';
      final pendingRef = firestoreService.firestore
          .collection('pendingMembers')
          .doc(pendingId);
      final pendingDoc = await pendingRef.get();

      if (pendingDoc.exists) {
        final data = pendingDoc.data();
        final status = data?['status'] as String?;
        // status가 null이거나 'approved'인 경우 중복으로 간주
        if (status == null || status == 'approved') {
          return true;
        }
      }

      return false;
    } catch (e) {
      debugPrint('❌ [전화번호 중복 체크 오류] $e');
      return false;
    }
  }

  Future<void> _checkPhoneInFirebase(String phoneNumber) async {
    if (_isCheckingPhone) return;

    setState(() {
      _isCheckingPhone = true;
      _phoneErrorText = null;
      _isExistingMember = false;
    });

    final isDuplicate = await _isPhoneDuplicateInFirebase(phoneNumber);

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
      // 탭 변경 시 선택된 멤버 초기화
      _selectedMemberName = null;
      _selectedMemberPhone = null;
      _selectedMemberUserId = null;
    });
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
      // 동기 체크: memberProvider.members에서 즉시 확인
      bool isExistingMemberSync = false;
      for (final member in memberProvider.members) {
        if (_normalizePhone(member.phoneNumber) == normalizedPhone) {
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

      final isDuplicate = await _isPhoneDuplicateInFirebase(trimmedPhone);

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

    try {
      // ⚠️ 중요: 기존 멤버에서 추가하는 경우와 신규 입력하는 경우 구분
      final isExistingMemberAdd = _selectedMemberUserId != null;

      if (isExistingMemberAdd) {
        // 기존 멤버에 코스 추가 (중앙 로직 사용)
        final placeProvider = Provider.of<PlaceProvider>(
          context,
          listen: false,
        );
        final placeId = placeProvider.currentPlace?.id ?? widget.placeId;
        final courseProvider = Provider.of<CourseProvider>(
          context,
          listen: false,
        );

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
          courses: courseProvider.courses,
        );

        if (!success) {
          throw Exception('코스 등록에 실패했습니다.');
        }

        // MemberProvider 새로고침
        await memberProvider.loadMembers(placeId);

        if (mounted) {
          SnackbarUtil.showSuccess(context, '추가되었습니다.');
          Navigator.of(context).pop();
        }
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

        // 저장 성공 후 화면 닫기
        if (mounted) {
          Navigator.of(context).pop();
        }
      }
    } catch (e) {
      if (mounted) {
        // 에러 메시지를 클라이언트 친화적으로 변환
        String errorMessage = '코스 등록 중 오류가 발생했습니다.';
        final errorStr = e.toString();
        if (errorStr.contains('이미 등록되어 있습니다') || errorStr.contains('이미 등록된')) {
          errorMessage = '이미 등록되어 있습니다.';
        } else if (errorStr.contains('코스 등록에 실패')) {
          errorMessage = '코스 등록에 실패했습니다.';
        } else {
          errorMessage = '코스 등록 중 오류가 발생했습니다.';
        }
        SnackbarUtil.showError(context, errorMessage);
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
                            final digitsOnly = value.replaceAll(
                              RegExp(r'[^\d]'),
                              '',
                            );
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

                            // 전화번호 입력 시 실시간 중복 체크
                            final normalizedPhone = _normalizePhone(result);
                            if (normalizedPhone.length == 11) {
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
                        valueColor: AlwaysStoppedAnimation<Color>(
                          AppColors.primaryGreen,
                        ),
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
                  onTabChanged: (index) {
                    setState(() {
                      _mode = index == 0
                          ? CourseMemberRegistrationMode.inputNew
                          : CourseMemberRegistrationMode.selectExisting;
                      // 탭 변경 시 선택된 멤버 초기화
                      _selectedMemberName = null;
                      _selectedMemberPhone = null;
                      _selectedMemberUserId = null;
                      _currentConfig = null;
                    });
                    _initializeCurrentConfig();
                  },
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
                          // hot reload 이후에도 멤버 로드가 보장되도록 build 시점에서도 트리거
                          if (memberProvider.members.isEmpty &&
                              !memberProvider.isLoading &&
                              _memberLoadRequestedPlaceId != widget.placeId) {
                            _memberLoadRequestedPlaceId = widget.placeId;
                            if (kDebugMode) {
                              debugPrint(
                                '[CourseMemberRegistrationScreen] trigger loadMembers in build placeId=${widget.placeId}',
                              );
                            }
                            Future.microtask(() async {
                              try {
                                await Provider.of<MemberProvider>(
                                  context,
                                  listen: false,
                                ).loadMembers(widget.placeId);
                              } catch (e) {
                                debugPrint('멤버 로드 실패(build): $e');
                              }
                            });
                          }

                          final q = _searchCtrl.text.trim();
                          if (kDebugMode) {
                            final key =
                                'q=$q|members=${memberProvider.members.length}|loading=${memberProvider.isLoading}|mode=$_mode';
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

                          // pendingMembers도 "전체 멤버"로 포함 (AdminMemberScreen과 동일한 방식)
                          final now = TimezoneUtils.getSeoulDateTime();
                          final pendingAsUsers = memberProvider.pendingMembers
                              .map((PendingMember pm) {
                                // ⚠️ courseIds 제거: courseEnrollments에서 유도
                                final courseIds = pm.derivedCourseIds;
                                final enrollments = courseIds.map((courseId) {
                                  return CourseEnrollment(
                                    id: 'pending_${pm.id}_$courseId',
                                    userId: 'pending_${pm.id}',
                                    courseId: courseId.toString(),
                                    placeId: pm.placeId,
                                    enrolledAt: pm.createdAt,
                                    validFrom: now.subtract(
                                      const Duration(days: 1),
                                    ),
                                    validUntil: now.add(
                                      const Duration(days: 3650),
                                    ),
                                    totalReservations: 1,
                                    remainingReservations: 1,
                                  );
                                }).toList();

                                return User(
                                  userId: 'pending_${pm.id}',
                                  name: (pm.name ?? '이름 없음').trim().isEmpty
                                      ? '이름 없음'
                                      : (pm.name ?? '이름 없음').trim(),
                                  phoneNumber: pm.phoneNumber,
                                  placeIds: [pm.placeId],
                                  enrollments: enrollments,
                                  reservations: const [],
                                  notificationsEnabled: false,
                                  createdAt: pm.createdAt,
                                  updatedAt: null,
                                );
                              })
                              .toList();

                          final allMembers = <User>[
                            ...memberProvider.members,
                            ...pendingAsUsers,
                          ];

                          final users = allMembers.where((u) {
                            if (u.isEnrolledInCourse(widget.courseId))
                              return false;
                            return matches(u.name, u.phoneNumber);
                          }).toList();

                          if (kDebugMode) {
                            debugPrint(
                              '[CourseMemberRegistrationScreen] filter result q="$q" totalMembers=${allMembers.length} (users=${memberProvider.members.length}, pending=${memberProvider.pendingMembers.length}) result=${users.length}',
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
                          if (users.isEmpty) {
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
                              ...users.map(
                                (u) => _buildExistingRow(
                                  name: u.name,
                                  phone: u.phoneNumber,
                                  statusLabel:
                                      MemberUtils.isPendingMember(u.userId)
                                      ? '대기'
                                      : null,
                                  onTap: () {
                                    setState(() {
                                      _selectedMemberName = u.name;
                                      _selectedMemberPhone = u.phoneNumber;
                                      _selectedMemberUserId =
                                          u.userId; // ⚠️ 중요: userId 저장
                                    });
                                    // 설정 초기화
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

        // 하단 추가 버튼 (멤버가 선택되었을 때만 표시)
        if (hasSelectedMember)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            decoration: const BoxDecoration(color: AppColors.backgroundWhite),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: canAdd
                    ? () => _addAndSaveMember(
                        name: _selectedMemberName!,
                        phoneNumber: _selectedMemberPhone!,
                      )
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
                          valueColor: AlwaysStoppedAnimation<Color>(
                            AppColors.primaryGreen,
                          ),
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
                  disabledBackgroundColor: AppColors.textPrimary.withOpacity(
                    0.1,
                  ),
                ),
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
    String? statusLabel,
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
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
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
