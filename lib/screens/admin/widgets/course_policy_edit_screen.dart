import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:convert';
import '../../../models/course.dart' as reservation_models;
import '../../../policies/course_policy.dart';
import '../../../providers/course_provider.dart';
import '../../../providers/place_provider.dart';
import '../../../services/firestore_service.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/snackbar_util.dart';
import '../../../utils/timezone_utils.dart';
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

  // effectiveFrom scheduling
  bool _scheduleForFuture = false;
  DateTime _effectiveFrom = TimezoneUtils.getSeoulToday();

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

      _scheduleForFuture = false;
      _effectiveFrom = TimezoneUtils.getSeoulToday();
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
      _scheduleForFuture = false;
      _effectiveFrom = TimezoneUtils.getSeoulToday();
    }

    try {
      final hasReservations = await _firestoreService
          .hasAnyReservationsForCourse(widget.courseId);
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

    // effectiveFrom 변경 체크 (나중에 적용하기가 켜져있고 실제로 날짜가 변경되었을 때만)
    // 시간은 항상 00:00이므로 날짜만 비교
    final seoulToday = TimezoneUtils.getSeoulToday();
    if (_scheduleForFuture) {
      // 오늘 날짜와 같으면 변경사항 없음 (즉시 적용과 동일)
      if (_effectiveFrom.year == seoulToday.year &&
          _effectiveFrom.month == seoulToday.month &&
          _effectiveFrom.day == seoulToday.day) {
        // 오늘 날짜면 변경사항 없음
      } else {
        // 원본 정책의 effectiveFrom과 비교 (날짜만)
        final originalEffectiveFrom = original.effectiveFrom;
        if (_effectiveFrom.year != originalEffectiveFrom.year ||
            _effectiveFrom.month != originalEffectiveFrom.month ||
            _effectiveFrom.day != originalEffectiveFrom.day) {
          return true;
        }
      }
    } else {
      // 나중에 적용하기가 꺼져있는데 원본은 미래 적용이었던 경우
      final seoulNow = TimezoneUtils.getSeoulDateTime();
      if (original.effectiveFrom.isAfter(seoulNow)) {
        return true;
      }
    }

    if (_type == BookingOpenStrategyType.rollingWindow) {
      return _windowDays !=
          (original.openStrategy.rollingWindow?.windowDays ?? 21);
    }

    final w = original.openStrategy.weeklyRelease;
    final oldTime = w?.releaseTime ?? '10:00';
    final newTime = _releaseTime.format(context);
    final normalizedNewTime = _toHHmm(_releaseTime);

    return _releaseDayOfWeek != (w?.releaseDayOfWeek ?? 1) ||
        normalizedNewTime != oldTime ||
        _weeksAhead != (w?.weeksAhead ?? 1) ||
        newTime.isEmpty; // for analyzer
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

  Future<bool> _savePolicy({required bool popAfterSave}) async {
    if (_isSaving) return false;
    final placeId =
        Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id;
    if (placeId == null) return false;

    // 유효값 체크 및 값 업데이트
    final windowDaysValue = int.tryParse(_windowDaysController.text);
    if (_type == BookingOpenStrategyType.rollingWindow) {
      if (windowDaysValue == null || windowDaysValue < 1) {
        SnackbarUtil.showError(context, '기간 기준 일수는 1일 이상 입력해주세요.');
        return false;
      }
      _windowDays = windowDaysValue;
    }

    final closeBeforeHoursValue = int.tryParse(
      _closeBeforeHoursController.text,
    );
    if (closeBeforeHoursValue == null || closeBeforeHoursValue < 0) {
      SnackbarUtil.showError(context, '세션 시작 전 시간은 0시간 이상 입력해주세요.');
      return false;
    }
    _closeBeforeMinutes = closeBeforeHoursValue * 60;

    setState(() => _isSaving = true);
    try {
      final original = _original;
      final nextVersion = (original?.version ?? 0) + 1;

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
        courseId: widget.courseId,
        placeId: placeId,
        closeBeforeMinutes: _closeBeforeMinutes,
        openStrategy: openStrategy,
        allowAdminForceMoveWithinCourse: true, // 관리자는 항상 활성화
        version: nextVersion,
        effectiveFrom:
            _scheduleForFuture
            ? _effectiveFrom
            : TimezoneUtils.getSeoulDateTime(),
      );

      // 디버그: 실제 저장 payload 확인 (릴리즈 빌드에서는 실행되지 않음)
      assert(() {
        debugPrint('[CoursePolicyEditScreen] upsertCoursePolicy request');
        debugPrint('  courseId=${policy.courseId}');
        debugPrint('  placeId=${policy.placeId}');
        debugPrint('  type=${policy.openStrategy.type}');
        debugPrint('  effectiveFrom=${policy.effectiveFrom.toIso8601String()}');
        debugPrint('  version=${policy.version}');
        debugPrint('  payload=${jsonEncode(policy.toJson())}');
        return true;
      }());

      await _firestoreService.upsertCoursePolicy(policy);
      if (!mounted) return false;

      // 정책 저장 후 CourseProvider에서 정책 재로드
      final courseProvider = Provider.of<CourseProvider>(
        context,
        listen: false,
      );
      await courseProvider.reloadCoursePolicy(policy.courseId, policy.placeId);

      // 코스 등록 플로우(requireSave=true)에서는 스낵바를 띄우지 않음 (조용히 진행)
      if (!widget.requireSave) {
        SnackbarUtil.showSuccess(context, '예약 정책이 저장되었습니다.');
      }

      // 정책 저장 후 콜백 호출
      widget.onPolicySaved?.call();

      if (popAfterSave) {
        Navigator.of(context).pop();
      }
      return true;
    } catch (e) {
      if (mounted) {
        debugPrint('저장 중 오류가 발생했습니다: $e');
        SnackbarUtil.showError(context, '저장 중 오류가 발생했습니다');
      }
      return false;
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _saveAndRegisterCourse() async {
    // 1) 정책 저장 (pop 하지 않음)
    final ok = await _savePolicy(popAfterSave: false);
    if (!ok || !mounted) return;

    final course = widget.courseToRegister;
    if (course == null) {
      // 코스 데이터가 없으면 정책만 저장하고 돌아가기
      Navigator.of(context).pop();
      return;
    }

    // 2) 정책 저장 후 코스 등록까지 진행
    final confirmed = await CommonDialog.show(
      context: context,
      title: '코스 등록',
      message: '코스를 등록하시겠습니까?',
      secondaryMessage: '등록 후에는 수정이 필요할 수 있습니다.',
      cancelText: '취소',
      confirmText: '등록',
      confirmButtonColor: AppColors.primaryGreen,
    );

    if (confirmed != true || !mounted) return;

    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final currentPlace = placeProvider.currentPlace;
    if (currentPlace == null) {
      SnackbarUtil.showError(context, '플레이스를 찾을 수 없습니다.');
      return;
    }

    try {
      await courseProvider.saveCourse(placeId: currentPlace.id, course: course);
      if (!mounted) return;
      // 코스 등록 플로우(requireSave=true)에서는 성공 스낵바를 띄우지 않음
      if (!widget.requireSave) {
        SnackbarUtil.showSuccess(context, '코스가 등록되었습니다.');
      }
      Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showError(context, '코스 저장에 실패했습니다: ${e.toString()}');
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
      canPop: true, // 뒤로가기 허용 (시간표나 코스 설정 수정 가능하도록)
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
            onPressed: () => Navigator.of(context).pop(),
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

                  // 적용 시점 옵션은 기존 코스 수정 시에만 표시 (새로 등록할 때는 숨김)
                  // 변경사항이 있을 때만 표시
                  // 맨 아래로 이동
                  if (!widget.requireSave && _hasChanges) ...[
                    const SizedBox(height: 30),
                    Text(
                      '이 정책을 언제부터 적용할까요?',
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
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      '나중에 적용하기',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Switch(
                                value: _scheduleForFuture,
                                activeColor: courseColor,
                                inactiveThumbColor: Colors.grey[600],
                                activeTrackColor: courseColor.withOpacity(0.3),
                                inactiveTrackColor: Colors.grey[100],
                                onChanged: (v) {
                                  setState(() {
                                    _scheduleForFuture = v;
                                    if (_scheduleForFuture) {
                                      // 내일 00:00으로 설정 (서울 타임존 기준)
                                      final seoulToday =
                                          TimezoneUtils.getSeoulToday();
                                      _effectiveFrom = seoulToday.add(
                                        const Duration(days: 1),
                                      );
                                    }
                                  });
                                },
                              ),
                            ],
                          ),
                          if (_scheduleForFuture) ...[
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${_effectiveFrom.year}-${_effectiveFrom.month.toString().padLeft(2, '0')}-${_effectiveFrom.day.toString().padLeft(2, '0')}부터',
                                    style: TextStyle(
                                      fontSize: 15,
                                      color: AppColors.textSecondary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                _styledButton(
                                  onPressed: () async {
                                    final seoulToday =
                                        TimezoneUtils.getSeoulToday();
                                    final pickedDate = await showDatePicker(
                                      context: context,
                                      initialDate: _effectiveFrom,
                                      firstDate: seoulToday,
                                      lastDate: seoulToday.add(
                                        const Duration(days: 365),
                                      ),
                                    );
                                    if (pickedDate == null) return;
                                    setState(() {
                                      // 날짜만 선택하고 시간은 항상 00:00으로 설정 (서울 타임존 기준)
                                      _effectiveFrom = DateTime(
                                        pickedDate.year,
                                        pickedDate.month,
                                        pickedDate.day,
                                        0,
                                        0,
                                      );
                                    });
                                  },
                                  child: const Text(
                                    '변경',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // 하단 고정 버튼
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
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
                      disabledBackgroundColor: AppColors.borderLight,
                      disabledForegroundColor: AppColors.textSecondary,
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      elevation: 0,
                    ),
                    child:
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
    final color = activeColor ?? AppColors.primaryGreen;
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
