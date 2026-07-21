import 'package:flutter/cupertino.dart';
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

enum _CloseBeforePickerKind { none, reserve, cancel }

enum _WeeklyFieldPicker { none, day, time, weeks }

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
  static const int _maxCloseBeforeHours = 72;

  final FirestoreService _firestoreService = FirestoreService();
  bool _isLoading = true;
  bool _isSaving = false;
  bool _leaveRequested = false;
  bool _hasReservations = false;

  CoursePolicy? _original;
  BookingOpenStrategyType _type = BookingOpenStrategyType.weeklyRelease;

  // 공통 — 예약/취소 마감(시작 N분 전)
  int _reserveCloseBeforeMinutes = 60;
  int _cancelCloseBeforeMinutes = 60;
  _CloseBeforePickerKind _expandedCloseBefore = _CloseBeforePickerKind.none;
  FixedExtentScrollController? _reserveHourCtrl;
  FixedExtentScrollController? _reserveMinuteCtrl;
  FixedExtentScrollController? _cancelHourCtrl;
  FixedExtentScrollController? _cancelMinuteCtrl;

  // rolling window
  int _windowDays = 21;
  final TextEditingController _windowDaysController = TextEditingController();

  // weekly release
  int _releaseDayOfWeek = 1;
  TimeOfDay _releaseTime = const TimeOfDay(hour: 9, minute: 0);
  int _weeksAhead = 1;
  _WeeklyFieldPicker _expandedWeeklyPicker = _WeeklyFieldPicker.none;
  FixedExtentScrollController? _releaseDayCtrl;
  FixedExtentScrollController? _releaseHourCtrl;
  FixedExtentScrollController? _releaseMinuteCtrl;
  FixedExtentScrollController? _weeksAheadCtrl;

  static const _dayLabels = ['월', '화', '수', '목', '금', '토', '일'];

  @override
  void initState() {
    super.initState();
    _windowDaysController.text = _windowDays.toString();
    _load();
  }

  @override
  void dispose() {
    _windowDaysController.dispose();
    _disposeCloseBeforeControllers();
    _disposeWeeklyControllers();
    super.dispose();
  }

  void _disposeCloseBeforeControllers() {
    _reserveHourCtrl?.dispose();
    _reserveMinuteCtrl?.dispose();
    _cancelHourCtrl?.dispose();
    _cancelMinuteCtrl?.dispose();
    _reserveHourCtrl = null;
    _reserveMinuteCtrl = null;
    _cancelHourCtrl = null;
    _cancelMinuteCtrl = null;
  }

  void _disposeWeeklyControllers() {
    _releaseDayCtrl?.dispose();
    _releaseHourCtrl?.dispose();
    _releaseMinuteCtrl?.dispose();
    _weeksAheadCtrl?.dispose();
    _releaseDayCtrl = null;
    _releaseHourCtrl = null;
    _releaseMinuteCtrl = null;
    _weeksAheadCtrl = null;
  }

  int _clampHours(int totalMinutes) =>
      (totalMinutes ~/ 60).clamp(0, _maxCloseBeforeHours);

  int _clampMinutesPart(int totalMinutes) => (totalMinutes % 60).clamp(0, 59);

  void _toggleCloseBeforePicker(_CloseBeforePickerKind kind) {
    setState(() {
      if (_expandedCloseBefore == kind) {
        _expandedCloseBefore = _CloseBeforePickerKind.none;
        _disposeCloseBeforeControllers();
        return;
      }

      // 다른 펼침 피커 닫기
      _expandedWeeklyPicker = _WeeklyFieldPicker.none;
      _disposeWeeklyControllers();

      _disposeCloseBeforeControllers();
      _expandedCloseBefore = kind;
      final total =
          kind == _CloseBeforePickerKind.reserve
              ? _reserveCloseBeforeMinutes
              : _cancelCloseBeforeMinutes;
      final hourCtrl = FixedExtentScrollController(
        initialItem: _clampHours(total),
      );
      final minuteCtrl = FixedExtentScrollController(
        initialItem: _clampMinutesPart(total),
      );
      if (kind == _CloseBeforePickerKind.reserve) {
        _reserveHourCtrl = hourCtrl;
        _reserveMinuteCtrl = minuteCtrl;
      } else {
        _cancelHourCtrl = hourCtrl;
        _cancelMinuteCtrl = minuteCtrl;
      }
    });
  }

  void _toggleWeeklyFieldPicker(_WeeklyFieldPicker field) {
    setState(() {
      if (_expandedWeeklyPicker == field) {
        _expandedWeeklyPicker = _WeeklyFieldPicker.none;
        _disposeWeeklyControllers();
        return;
      }

      _expandedCloseBefore = _CloseBeforePickerKind.none;
      _disposeCloseBeforeControllers();
      _disposeWeeklyControllers();
      _expandedWeeklyPicker = field;

      switch (field) {
        case _WeeklyFieldPicker.day:
          _releaseDayCtrl = FixedExtentScrollController(
            initialItem: (_releaseDayOfWeek - 1).clamp(0, 6),
          );
        case _WeeklyFieldPicker.time:
          _releaseHourCtrl = FixedExtentScrollController(
            initialItem: _releaseTime.hour.clamp(0, 23),
          );
          _releaseMinuteCtrl = FixedExtentScrollController(
            initialItem: _releaseTime.minute.clamp(0, 59),
          );
        case _WeeklyFieldPicker.weeks:
          _weeksAheadCtrl = FixedExtentScrollController(
            initialItem: (_weeksAhead - 1).clamp(0, 7),
          );
        case _WeeklyFieldPicker.none:
          break;
      }
    });
  }

  void _setCloseBeforeFromPickers({
    required _CloseBeforePickerKind kind,
    int? hour,
    int? minute,
  }) {
    final current =
        kind == _CloseBeforePickerKind.reserve
            ? _reserveCloseBeforeMinutes
            : _cancelCloseBeforeMinutes;
    final nextHours = hour ?? _clampHours(current);
    final nextMinutes = minute ?? _clampMinutesPart(current);
    final nextTotal = nextHours * 60 + nextMinutes;
    setState(() {
      if (kind == _CloseBeforePickerKind.reserve) {
        _reserveCloseBeforeMinutes = nextTotal;
      } else {
        _cancelCloseBeforeMinutes = nextTotal;
      }
    });
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
      _reserveCloseBeforeMinutes = policy.reserveCloseBeforeMinutes;
      _cancelCloseBeforeMinutes = policy.cancelCloseBeforeMinutes;

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
      _reserveCloseBeforeMinutes = 60;
      _cancelCloseBeforeMinutes = 60;
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
    if (_reserveCloseBeforeMinutes != original.reserveCloseBeforeMinutes) {
      return true;
    }
    if (_cancelCloseBeforeMinutes != original.cancelCloseBeforeMinutes) {
      return true;
    }

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

    if (_reserveCloseBeforeMinutes < 0 || _cancelCloseBeforeMinutes < 0) {
      return false;
    }

    return true;
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
        reserveCloseBeforeMinutes: _reserveCloseBeforeMinutes,
        cancelCloseBeforeMinutes: _cancelCloseBeforeMinutes,
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
            ' 예약 정책 설정',
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
          title: const Text(
            ' 예약 정책 설정',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
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
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  children: [
                    const SizedBox(height: 20),
                    _buildCloseBeforeDurationCard(
                      title: '얼마 전까지 예약 가능하게 할까요?',
                      valueLabel: '전까지 예약 가능',
                      kind: _CloseBeforePickerKind.reserve,
                      totalMinutes: _reserveCloseBeforeMinutes,
                      hourController: _reserveHourCtrl,
                      minuteController: _reserveMinuteCtrl,
                      accentColor: courseColor,
                    ),

                    const SizedBox(height: 40),

                    _buildCloseBeforeDurationCard(
                      title: '얼마 전까지 취소 가능하게 할까요?',
                      valueLabel: '전까지 취소 가능',
                      kind: _CloseBeforePickerKind.cancel,
                      totalMinutes: _cancelCloseBeforeMinutes,
                      hourController: _cancelHourCtrl,
                      minuteController: _cancelMinuteCtrl,
                      accentColor: courseColor,
                    ),

                    const SizedBox(height: 40),
                    Text(
                      '언제 다음 예약을 오픈할까요?',
                      style: const TextStyle(
                        fontSize: 16,
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
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
                                  color: AppColors.textSecondary.withOpacity(
                                    0.9,
                                  ),
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
                      onChanged: (v) {
                        setState(() {
                          _type = v;
                          if (v != BookingOpenStrategyType.weeklyRelease) {
                            _expandedWeeklyPicker = _WeeklyFieldPicker.none;
                            _disposeWeeklyControllers();
                          }
                        });
                      },
                      activeColor: courseColor,
                    ),

                    const SizedBox(height: 6),

                    if (_type == BookingOpenStrategyType.rollingWindow) ...[
                      _card(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                const Text(
                                  '오늘부터 ',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SizedBox(
                                  width: 80,
                                  child: _styledNumberTextField(
                                    controller: _windowDaysController,
                                    suffix: '일 뒤',
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
                                  '예약까지 오픈할게요',
                                  style: TextStyle(
                                    fontSize: 16,
                                    color: AppColors.textSecondary,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                            if (_windowDaysController.text.isNotEmpty &&
                                (int.tryParse(_windowDaysController.text) ??
                                        0) <
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
                      _buildWeeklyReleaseCard(courseColor: courseColor),
                    ],

                    const SizedBox(height: 40),
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
                                widget.requireSave ? '저장 및 코스 등록' : '정책 수정하기',
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
      ),
    );
  }

  Widget _valueChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    Color accentColor = AppColors.primaryGreen,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color:
                selected
                    ? accentColor.withOpacity(0.12)
                    : AppColors.backgroundLight,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: selected ? accentColor : AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _sentenceLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 16,
        color: AppColors.textSecondary,
        fontWeight: FontWeight.w500,
      ),
    );
  }

  Widget _buildExpandableWheel({
    required bool isExpanded,
    required Widget? child,
  }) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeInOut,
        height: isExpanded ? 180 : 0,
        child: isExpanded && child != null ? child : const SizedBox.shrink(),
      ),
    );
  }

  Widget _cupertinoWheel({
    required FixedExtentScrollController controller,
    required int itemCount,
    required ValueChanged<int> onSelectedItemChanged,
    required String Function(int index) labelBuilder,
  }) {
    return CupertinoPicker(
      scrollController: controller,
      itemExtent: 40,
      diameterRatio: 1.15,
      squeeze: 1.05,
      useMagnifier: true,
      magnification: 1.12,
      onSelectedItemChanged: onSelectedItemChanged,
      children: List.generate(
        itemCount,
        (index) => Center(
          child: Text(
            labelBuilder(index),
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w500,
              color: AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWeeklyReleaseCard({required Color courseColor}) {
    final dayLabel = _dayLabels[(_releaseDayOfWeek - 1).clamp(0, 6)];
    final daySelected = _expandedWeeklyPicker == _WeeklyFieldPicker.day;
    final timeSelected = _expandedWeeklyPicker == _WeeklyFieldPicker.time;
    final weeksSelected = _expandedWeeklyPicker == _WeeklyFieldPicker.weeks;
    final isExpanded = _expandedWeeklyPicker != _WeeklyFieldPicker.none;

    Widget? wheel;
    if (daySelected && _releaseDayCtrl != null) {
      wheel = _cupertinoWheel(
        controller: _releaseDayCtrl!,
        itemCount: _dayLabels.length,
        onSelectedItemChanged: (index) {
          setState(() => _releaseDayOfWeek = index + 1);
        },
        labelBuilder: (index) => '${_dayLabels[index]}요일',
      );
    } else if (timeSelected &&
        _releaseHourCtrl != null &&
        _releaseMinuteCtrl != null) {
      wheel = Row(
        children: [
          Expanded(
            child: _cupertinoWheel(
              controller: _releaseHourCtrl!,
              itemCount: 24,
              onSelectedItemChanged: (index) {
                setState(() {
                  _releaseTime = TimeOfDay(
                    hour: index,
                    minute: _releaseTime.minute,
                  );
                });
              },
              labelBuilder: (index) => '${index.toString().padLeft(2, '0')}시',
            ),
          ),
          Expanded(
            child: _cupertinoWheel(
              controller: _releaseMinuteCtrl!,
              itemCount: 60,
              onSelectedItemChanged: (index) {
                setState(() {
                  _releaseTime = TimeOfDay(
                    hour: _releaseTime.hour,
                    minute: index,
                  );
                });
              },
              labelBuilder: (index) => '${index.toString().padLeft(2, '0')}분',
            ),
          ),
        ],
      );
    } else if (weeksSelected && _weeksAheadCtrl != null) {
      wheel = _cupertinoWheel(
        controller: _weeksAheadCtrl!,
        itemCount: 8,
        onSelectedItemChanged: (index) {
          setState(() => _weeksAhead = index + 1);
        },
        labelBuilder: (index) => '${index + 1}주 뒤',
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 10,
              children: [
                _sentenceLabel('매주'),
                _valueChip(
                  label: dayLabel,
                  selected: daySelected,
                  onTap: () => _toggleWeeklyFieldPicker(_WeeklyFieldPicker.day),
                  accentColor: courseColor,
                ),
                _valueChip(
                  label: _toHHmm(_releaseTime),
                  selected: timeSelected,
                  onTap:
                      () => _toggleWeeklyFieldPicker(_WeeklyFieldPicker.time),
                  accentColor: courseColor,
                ),
                _sentenceLabel('에'),
                _valueChip(
                  label: '$_weeksAhead주 뒤',
                  selected: weeksSelected,
                  onTap:
                      () => _toggleWeeklyFieldPicker(_WeeklyFieldPicker.weeks),
                  accentColor: courseColor,
                ),
                _sentenceLabel('예약까지 오픈할게요'),
              ],
            ),
          ),
          _buildExpandableWheel(isExpanded: isExpanded, child: wheel),
        ],
      ),
    );
  }

  Widget _buildCloseBeforeDurationCard({
    required String title,
    required String valueLabel,
    required _CloseBeforePickerKind kind,
    required int totalMinutes,
    required FixedExtentScrollController? hourController,
    required FixedExtentScrollController? minuteController,
    required Color accentColor,
  }) {
    final isExpanded = _expandedCloseBefore == kind;
    final hours = _clampHours(totalMinutes);
    final minutes = _clampMinutesPart(totalMinutes);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: AppColors.backgroundWhite,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 10,
                  children: [
                    _sentenceLabel('세션 시작'),
                    _valueChip(
                      label: '$hours시간',
                      selected: isExpanded,
                      onTap: () => _toggleCloseBeforePicker(kind),
                      accentColor: accentColor,
                    ),
                    _valueChip(
                      label: '$minutes분',
                      selected: isExpanded,
                      onTap: () => _toggleCloseBeforePicker(kind),
                      accentColor: accentColor,
                    ),
                    _sentenceLabel(valueLabel),
                  ],
                ),
              ),
              _buildExpandableWheel(
                isExpanded: isExpanded,
                child:
                    hourController != null && minuteController != null
                        ? Row(
                          children: [
                            Expanded(
                              child: _cupertinoWheel(
                                controller: hourController,
                                itemCount: _maxCloseBeforeHours + 1,
                                onSelectedItemChanged:
                                    (index) => _setCloseBeforeFromPickers(
                                      kind: kind,
                                      hour: index,
                                    ),
                                labelBuilder: (index) => '$index시간',
                              ),
                            ),
                            Expanded(
                              child: _cupertinoWheel(
                                controller: minuteController,
                                itemCount: 60,
                                onSelectedItemChanged:
                                    (index) => _setCloseBeforeFromPickers(
                                      kind: kind,
                                      minute: index,
                                    ),
                                labelBuilder: (index) => '$index분',
                              ),
                            ),
                          ],
                        )
                        : null,
              ),
            ],
          ),
        ),
      ],
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
