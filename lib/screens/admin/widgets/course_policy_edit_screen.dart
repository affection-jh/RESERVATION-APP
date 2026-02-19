import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../models/course.dart' as reservation_models;
import '../../../models/course_policy.dart';
import '../../../providers/course_provider.dart';
import '../../../providers/place_provider.dart';
import '../../../services/firestore_service.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/navigator_key.dart';
import '../../../utils/snackbar_util.dart';
import '../../../widgets/common_dialog.dart';

/// 코스 예약 정책 설정 화면
class CoursePolicyEditScreen extends StatefulWidget {
  final String courseId;
  final bool requireSave;
  final VoidCallback? onPolicySaved;
  final reservation_models.Course? courseToRegister; // 코스 등록 플로우에서 전달

  const CoursePolicyEditScreen({
    super.key,
    required this.courseId,
    this.requireSave = false,
    this.onPolicySaved,
    this.courseToRegister,
  });

  @override
  State<CoursePolicyEditScreen> createState() => _CoursePolicyEditScreenState();
}

class _CoursePolicyEditScreenState extends State<CoursePolicyEditScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  bool _isLoading = true;
  bool _isSaving = false;
  bool _leaveRequested = false;
  bool _hasReservations = false;

  CoursePolicy? _original;
  BookingOpenStrategyType _type = BookingOpenStrategyType.weeklyRelease;

  // 공통
  int _closeBeforeMinutes = 60;
  final TextEditingController _closeBeforeHoursController =
      TextEditingController();

  // rolling window
  int _windowDays = 21;
  final TextEditingController _windowDaysController = TextEditingController();

  // weekly release
  int _releaseDayOfWeek = 1;
  TimeOfDay _releaseTime = const TimeOfDay(hour: 9, minute: 0);
  int _weeksAhead = 1;

  @override
  void initState() {
    super.initState();
    _windowDaysController.text = _windowDays.toString();
    _closeBeforeHoursController.text =
        (_closeBeforeMinutes / 60).round().toString();
    _load();
  }

  @override
  void dispose() {
    _windowDaysController.dispose();
    _closeBeforeHoursController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final placeId =
        Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id;
    if (placeId == null) {
      setState(() => _isLoading = false);
      return;
    }

    try {
      final policy = await _firestoreService.getCoursePolicy(
        courseId: widget.courseId,
        placeId: placeId,
      );
      _original = policy;

      _type = policy.openStrategy.type;
      _closeBeforeMinutes = policy.closeBeforeMinutes;
      _closeBeforeHoursController.text =
          (_closeBeforeMinutes / 60).round().toString();

      _windowDays = policy.openStrategy.rollingWindow?.windowDays ?? 21;
      _windowDaysController.text = _windowDays.toString();

      final weekly = policy.openStrategy.weeklyRelease;
      _releaseDayOfWeek = weekly?.releaseDayOfWeek ?? 1;
      final parts = (weekly?.releaseTime ?? '10:00').split(':');
      _releaseTime = TimeOfDay(
        hour: int.tryParse(parts[0]) ?? 10,
        minute: int.tryParse(parts[1]) ?? 0,
      );
      _weeksAhead = weekly?.weeksAhead ?? 1;
    } catch (e) {
      _original = null;
      _type = BookingOpenStrategyType.rollingWindow;
      _closeBeforeMinutes = 60;
      _closeBeforeHoursController.text = '1';
      _windowDays = 21;
      _windowDaysController.text = '21';
      _releaseDayOfWeek = 1;
      _releaseTime = const TimeOfDay(hour: 10, minute: 0);
      _weeksAhead = 1;
    }

    try {
      final hasReservations = await _firestoreService
          .hasAnySessionReservationsForCourse(widget.courseId);
      _hasReservations = hasReservations;
    } catch (_) {
      _hasReservations = false;
    }

    if (mounted) setState(() => _isLoading = false);
  }

  bool get _hasChanges {
    final original = _original;
    if (original == null) return true;
    if (_type != original.openStrategy.type) return true;
    if (_closeBeforeMinutes != original.closeBeforeMinutes) return true;

    if (_type == BookingOpenStrategyType.rollingWindow) {
      return _windowDays !=
          (original.openStrategy.rollingWindow?.windowDays ?? 21);
    }

    final w = original.openStrategy.weeklyRelease;
    final oldTime = w?.releaseTime ?? '10:00';
    final normalizedNewTime = _toHHmm(_releaseTime);
    return _releaseDayOfWeek != (w?.releaseDayOfWeek ?? 1) ||
        normalizedNewTime != oldTime ||
        _weeksAhead != (w?.weeksAhead ?? 1);
  }

  String _toHHmm(TimeOfDay t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  // 입력값 유효성 검증
  bool _isValidInput() {
    // 기간 기준 일수 체크
    if (_type == BookingOpenStrategyType.rollingWindow) {
      final windowDaysValue = int.tryParse(_windowDaysController.text);
      if (windowDaysValue == null || windowDaysValue < 1) {
        return false;
      }
    }

    // 세션 시작 전 시간 체크
    final closeBeforeHoursValue = int.tryParse(
      _closeBeforeHoursController.text,
    );
    if (closeBeforeHoursValue == null || closeBeforeHoursValue < 0) {
      return false;
    }

    return true;
  }

  Future<void> _pickReleaseTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _releaseTime,
    );
    if (picked == null) return;
    setState(() {
      _releaseTime = picked;
    });
  }

  Future<void> _handleBackDuringSave() async {
    if (!_isSaving) return;
    final leave = await CommonDialog.showSavingLeaveConfirm(
      context: context,
      onLeave: () => _leaveRequested = true,
    );
    if (leave && mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<bool> _savePolicy({
    required bool popAfterSave,
    bool isInternalCall = false,
  }) async {
    if (!isInternalCall && _isSaving) return false;
    final placeId =
        Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id;
    if (placeId == null) return false;

    // 유효값 체크 및 값 업데이트
    final windowDaysValue = int.tryParse(_windowDaysController.text);
    if (_type == BookingOpenStrategyType.rollingWindow) {
      if (windowDaysValue == null || windowDaysValue < 1) {
        SnackbarUtil.showInfo(context, '기간 기준 일수는 1일 이상 입력해주세요.');
        return false;
      }
      _windowDays = windowDaysValue;
    }

    final closeBeforeHoursValue = int.tryParse(
      _closeBeforeHoursController.text,
    );
    if (closeBeforeHoursValue == null || closeBeforeHoursValue < 0) {
      SnackbarUtil.showInfo(context, '세션 시작 전 시간은 0시간 이상 입력해주세요.');
      return false;
    }
    _closeBeforeMinutes = closeBeforeHoursValue * 60;

    setState(() => _isSaving = true);
    try {
      if (_leaveRequested) return false;
      final openStrategy =
          _type == BookingOpenStrategyType.rollingWindow
              ? BookingOpenStrategy.rollingWindow(
                RollingWindowOpenStrategy(windowDays: _windowDays),
              )
              : BookingOpenStrategy.weeklyRelease(
                WeeklyReleaseOpenStrategy(
                  releaseDayOfWeek: _releaseDayOfWeek,
                  releaseTime: _toHHmm(_releaseTime),
                  weeksAhead: _weeksAhead,
                ),
              );

      final policy = CoursePolicy(
        closeBeforeMinutes: _closeBeforeMinutes,
        openStrategy: openStrategy,
        updatedAt: DateTime.now(),
      );

      await _firestoreService.upsertCoursePolicy(
        placeId: placeId,
        courseId: widget.courseId,
        policy: policy,
      );
      if (_leaveRequested || !mounted) return false;

      final courseProvider = Provider.of<CourseProvider>(
        context,
        listen: false,
      );
      await courseProvider.reloadCoursePolicy(widget.courseId, placeId);

      // 코스 등록 플로우(requireSave=true)에서는 스낵바를 띄우지 않음 (조용히 진행)
      if (!widget.requireSave) {
        SnackbarUtil.showSuccess(context, '예약 정책이 저장되었습니다.');
      }

      // 정책 저장 후 콜백 호출
      widget.onPolicySaved?.call();

      if (_leaveRequested) return false;
      if (popAfterSave) {
        final nav = Navigator.of(context);
        nav.pop(); // 1) 다이얼로그가 열려 있으면 먼저 제거
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (nav.canPop()) nav.pop(); // 2) 화면까지 닫기
        });
      }
      return true;
    } catch (e) {
      if (_leaveRequested) return false;
      if (mounted) {
        debugPrint('저장 중 오류가 발생했습니다: $e');
        SnackbarUtil.showInfoFromError(
          context,
          e,
          fallback: '저장 중 오류가 발생했습니다.',
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _saveAndRegisterCourse() async {
    if (_isSaving) return;
    final course = widget.courseToRegister;
    if (course == null) {
      Navigator.of(context).pop();
      return;
    }

    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final currentPlace = placeProvider.currentPlace;
    if (currentPlace == null) {
      SnackbarUtil.showInfo(context, '플레이스를 찾을 수 없습니다.');
      return;
    }

    setState(() => _isSaving = true);
    try {
      if (_leaveRequested) return;
      // 동일 장소에 같은 이름 코스가 있으면 중복 등록 방지 (1회 조회로 검사)
      final existingCourses = await _firestoreService.getCoursesByPlace(
        currentPlace.id,
      );
      if (!mounted) return;
      final hasDuplicate = existingCourses.any(
        (c) => c.name.trim().toLowerCase() == course.name.trim().toLowerCase(),
      );
      if (hasDuplicate) {
        if (mounted) setState(() => _isSaving = false);
        SnackbarUtil.showInfo(context, '같은 이름의 코스가 이미 있습니다. 코스 이름을 변경해 주세요.');
        return;
      }

      if (_leaveRequested) return;
      // 1) 코스 등록: 먼저 코스를 생성해야 정책(upsertCoursePolicy) 저장이 가능함
      await courseProvider.saveCourse(placeId: currentPlace.id, course: course);
      if (_leaveRequested || !mounted) return;

      // 2) 정책 저장 (isInternalCall: true로 _isSaving 체크 스킵)
      final ok = await _savePolicy(popAfterSave: false, isInternalCall: true);
      if (!ok || !mounted) return;

      // 코스 등록(requireSave) 시: 코스 추가 플로우 4개 화면만 제거 (정책→일정→세부→기본정보), 관리자 화면 유지
      if (!widget.requireSave) {
        SnackbarUtil.showSuccess(context, '코스가 등록되었습니다.');
      } else {
        final nav = Navigator.of(context);
        for (int i = 0; i < 4 && nav.canPop(); i++) {
          nav.pop();
        }
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          await Future.delayed(const Duration(milliseconds: 400));
          final ctx = navigatorKey.currentContext;
          if (ctx == null || !ctx.mounted) return;
          SnackbarUtil.showSuccess(ctx, '코스가 추가되었습니다.');
        });
      }
    } catch (e) {
      if (_leaveRequested) return;
      if (mounted) {
        SnackbarUtil.showInfoFromError(context, e, fallback: '코스 저장에 실패했습니다.');
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 로딩 중일 때는 빌드 방지
    if (_isLoading) {
      return Scaffold(
        backgroundColor: AppColors.backgroundLight,
        appBar: AppBar(
          backgroundColor: AppColors.backgroundLight,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: const Text(
            '예약 정책 설정',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // 코스 색상 가져오기
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final course =
        courseProvider.getCourse(widget.courseId) ?? widget.courseToRegister;
    final courseColor =
        course != null ? Color(course.color) : AppColors.primaryGreen;

    return PopScope(
      canPop: !_isSaving,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;
        if (_isSaving)
          await _handleBackDuringSave();
        else if (mounted)
          Navigator.of(context).pop();
      },
      child: Scaffold(
        backgroundColor: AppColors.backgroundLight,
        appBar: AppBar(
          backgroundColor: AppColors.backgroundLight,
          elevation: 0,
          scrolledUnderElevation: 0,

          leading: IconButton(
            icon: const Icon(
              Icons.arrow_back_ios_rounded,
              color: AppColors.textPrimary,
            ),
            onPressed: () async {
              if (_isSaving) {
                await _handleBackDuringSave();
              } else if (mounted) {
                Navigator.of(context).pop();
              }
            },
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                children: [
                  _sectionTitle('예약 정책 설정'),

                  const SizedBox(height: 20),
                  if (_hasReservations) ...[
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.backgroundWhite,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.info_outline_rounded,
                            color: AppColors.primaryGreen,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '정책을 변경하면 새로 예약되는 건에만 적용됩니다.\n기존 예약은 그대로 유지됩니다.',
                              style: TextStyle(
                                fontSize: 14,
                                height: 1.35,
                                color: AppColors.textSecondary.withOpacity(0.9),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  _segmented(
                    value: _type,
                    onChanged: (v) => setState(() => _type = v),
                    activeColor: courseColor,
                  ),

                  const SizedBox(height: 6),

                  if (_type == BookingOpenStrategyType.rollingWindow) ...[
                    _card(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 6),
                          Text(
                            '오늘부터 며칠 뒤까지 예약을 받을지 정합니다',
                            style: TextStyle(
                              fontSize: 14,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              const Text(
                                '오늘부터 ',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 80,
                                child: _styledNumberTextField(
                                  controller: _windowDaysController,
                                  suffix: '일',
                                  onChanged: (value) {
                                    final days = int.tryParse(value) ?? 0;
                                    if (days >= 1) {
                                      setState(() => _windowDays = days);
                                    }
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                '까지',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          if (_windowDaysController.text.isNotEmpty &&
                              (int.tryParse(_windowDaysController.text) ?? 0) <
                                  1)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                '1일 이상 입력해주세요',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.red,
                                ),
                              ),
                            ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                  ] else ...[
                    _card(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 6),
                          Text(
                            '매주 정해진 요일과 시간에 예약을 오픈합니다',
                            style: TextStyle(
                              fontSize: 14,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              const Text(
                                '매주',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: AppColors.textSecondary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              _styledDropdown<int>(
                                value: _releaseDayOfWeek,
                                items: const [
                                  DropdownMenuItem(value: 1, child: Text('월')),
                                  DropdownMenuItem(value: 2, child: Text('화')),
                                  DropdownMenuItem(value: 3, child: Text('수')),
                                  DropdownMenuItem(value: 4, child: Text('목')),
                                  DropdownMenuItem(value: 5, child: Text('금')),
                                  DropdownMenuItem(value: 6, child: Text('토')),
                                  DropdownMenuItem(value: 7, child: Text('일')),
                                ],
                                onChanged: (v) {
                                  if (v == null) return;
                                  setState(() => _releaseDayOfWeek = v);
                                },
                              ),
                              _styledButton(
                                onPressed: _pickReleaseTime,
                                child: Text(
                                  _toHHmm(_releaseTime),
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                              ),
                              const Text(
                                '에',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: AppColors.textSecondary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              _styledDropdown<int>(
                                value: _weeksAhead,
                                items: List.generate(
                                  8,
                                  (i) => DropdownMenuItem(
                                    value: i + 1,
                                    child: Text(
                                      '${i + 1}주 뒤',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                                onChanged: (v) {
                                  if (v == null) return;
                                  setState(() => _weeksAhead = v);
                                },
                              ),
                              const Text(
                                '까지',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: AppColors.textSecondary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                        ],
                      ),
                    ),
                  ],

                  const SizedBox(height: 30),

                  Text(
                    '시작 얼마 전까지 예약/취소 가능할까요?',
                    style: TextStyle(
                      fontSize: 16,
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              '세션 시작',
                              style: TextStyle(
                                fontSize: 16,
                                color: AppColors.textSecondary,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            SizedBox(width: 12),

                            SizedBox(
                              width: 80,
                              child: _styledNumberTextField(
                                controller: _closeBeforeHoursController,
                                suffix: '시간',
                                onChanged: (value) {
                                  final hours = int.tryParse(value) ?? 0;
                                  if (hours >= 0) {
                                    setState(
                                      () => _closeBeforeMinutes = hours * 60,
                                    );
                                  }
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              ' 전까지 예약/취소 가능',
                              style: TextStyle(
                                fontSize: 16,
                                color: AppColors.textSecondary,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        if (_closeBeforeHoursController.text.isNotEmpty &&
                            (int.tryParse(_closeBeforeHoursController.text) ??
                                    -1) <
                                0)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              '0시간 이상 입력해주세요',
                              style: TextStyle(fontSize: 12, color: Colors.red),
                            ),
                          ),
                      ],
                    ),
                  ),

                ],
              ),
            ),
            // 하단 고정 버튼
            Container(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 10),
              decoration: BoxDecoration(color: AppColors.backgroundLight),
              child: SafeArea(
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed:
                        (_isLoading || _isSaving || !_isValidInput())
                            ? null
                            : (widget.requireSave || _hasChanges)
                            ? (widget.requireSave
                                ? _saveAndRegisterCourse
                                : () => _savePolicy(popAfterSave: true))
                            : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryGreen,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor:
                          _isSaving
                              ? AppColors.primaryGreen
                              : AppColors.borderLight,
                      disabledForegroundColor:
                          _isSaving ? Colors.white : AppColors.textSecondary,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      elevation: 0,
                    ),
                    child:
                        _isSaving
                            ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white,
                                ),
                              ),
                            )
                            : Text(
                              widget.requireSave ? '저장 및 코스 등록' : '정책 수정',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
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

  Widget _segmented({
    required BookingOpenStrategyType value,
    required ValueChanged<BookingOpenStrategyType> onChanged,
    Color? activeColor,
  }) {
    final color = AppColors.primaryGreen;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: _segButton(
              text: '주차 기준',
              selected: value == BookingOpenStrategyType.weeklyRelease,
              onTap: () => onChanged(BookingOpenStrategyType.weeklyRelease),
              activeColor: color,
            ),
          ),
          Expanded(
            child: _segButton(
              text: '기간 기준',
              selected: value == BookingOpenStrategyType.rollingWindow,
              onTap: () => onChanged(BookingOpenStrategyType.rollingWindow),
              activeColor: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _segButton({
    required String text,
    required bool selected,
    required VoidCallback onTap,
    Color? activeColor,
  }) {
    final color = activeColor ?? AppColors.primaryGreen;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: selected ? color : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 16,
              color: selected ? Colors.white : AppColors.textPrimary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w800,
        color: AppColors.textPrimary,
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }

  Widget _styledDropdown<T>({
    required T? value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          items: items,
          onChanged: onChanged,
          isExpanded: false,
          icon: Icon(
            Icons.keyboard_arrow_down_rounded,
            color: AppColors.textSecondary,
            size: 20,
          ),
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
          dropdownColor: AppColors.backgroundWhite,
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  Widget _styledButton({
    required VoidCallback? onPressed,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: child,
      ),
    );
  }

  Widget _styledNumberTextField({
    required TextEditingController controller,
    required String suffix,
    required ValueChanged<String> onChanged,
  }) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                isDense: true,
              ),
              onChanged: onChanged,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            suffix,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
