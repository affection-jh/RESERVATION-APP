import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:provider/provider.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../../models/course.dart';
import '../../../models/course_enrollment.dart';
import '../../../models/enrollment_action.dart';
import '../../../models/member_view.dart';
import '../../../models/enrollment_timeline_item.dart';
import '../../../models/session_reservation.dart';
import '../../../providers/member_provider.dart';
import '../../../providers/place_provider.dart';
import '../../../providers/enrollment_provider.dart';
import '../../../providers/enrollment_timeline_provider.dart';
import '../../../providers/course_provider.dart';
import '../../../services/enrollment_service.dart';
import '../../../services/member_service.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/text_field_decoration_util.dart';
import '../../../utils/timezone_utils.dart';
import '../../../utils/snackbar_util.dart';
import '../../../utils/navigator_key.dart';
import '../../../utils/format_utils.dart';
import '../../../utils/date_range_picker_util.dart';
import '../../../utils/enrollment_valid_until_util.dart';
import '../../../utils/firestore_utils.dart';
import '../../../widgets/defualt_tapbar.dart';
import '../../../widgets/valid_period_input_widget.dart';
import '../../../widgets/reservations_input_widget.dart';
import '../../../widgets/common_dialog.dart';
import 'shared_components.dart' as admin_shared;

/// 코스 등록 상세 화면
/// 탭 기반으로 횟수 조정, 기간 조정, 재등록/취소 처리
class EnrollmentDetailScreen extends StatefulWidget {
  final MemberView member;
  final CourseEnrollment enrollment;
  final Course course;
  final bool isNewEnrollment; // 새 enrollment 생성 모드
  final int? initialTabIndex; // 초기 탭 인덱스 (0: 횟수 조정, 1: 기간 조정, 2: 재등록/취소)

  const EnrollmentDetailScreen({
    super.key,
    required this.member,
    required this.enrollment,
    required this.course,
    this.isNewEnrollment = false,
    this.initialTabIndex,
  });

  @override
  State<EnrollmentDetailScreen> createState() => _EnrollmentDetailScreenState();
}

class _EnrollmentDetailScreenState extends State<EnrollmentDetailScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  bool get _isPendingEnrollment {
    // pending 멤버(등록 생성 전) 또는 id 미할당 enrollment는 Firestore enrollments 문서가 없음
    return widget.isNewEnrollment ||
        widget.enrollment.id.isEmpty ||
        widget.enrollment.userId.startsWith('pending_');
  }

  // 탭 1: 횟수 조정
  late TextEditingController _remainingReservationsController;
  late int _originalRemainingReservations; // 초기값 추적

  // 탭 2: 기간 조정
  late DateTime _extendedValidUntil;
  late DateTime _originalValidUntil; // 초기값 추적
  late DateTime _extensionBaseValidUntil; // 기간 조정 기준 종료일(서울 날짜-only): 원래 종료일
  late DateTime
  _extensionMinValidUntil; // 선택 가능한 최소 종료일(서울 날짜-only): max(오늘, validFrom)
  ValidPeriodMode _extensionMode = ValidPeriodMode.period;
  PeriodType _extensionPeriodType = PeriodType.weeks;
  int _extensionPeriodValue = 0;
  late TextEditingController _extensionPeriodController;

  // 탭 3: 재등록/취소
  late TextEditingController _reEnrollTotalReservationsController;
  late DateTime _reEnrollValidFrom;
  late DateTime _reEnrollValidUntil;
  late int _originalReEnrollTotalReservations; // 초기값 추적
  late DateTime _originalReEnrollValidFrom; // 초기값 추적
  late DateTime _originalReEnrollValidUntil; // 초기값 추적
  ValidPeriodMode _reEnrollMode = ValidPeriodMode.period;
  PeriodType _reEnrollPeriodType = PeriodType.days;
  late int _reEnrollPeriodValue;
  late TextEditingController _reEnrollPeriodController;

  bool _isSaving = false; // 횟수 조정/기간 조정용
  BuildContext? _providerContext; // Provider 아래 context (Builder에서 설정)
  bool _isCancelling = false; // 수강 취소용
  bool _isReenrolling = false; // 재등록용
  bool _leaveRequested = false;
  bool _isDetailExpanded = false; // 자세히 보기 펼침 상태
  String? _selectedTimelineFilter; // 타임라인 필터 (null이면 전체)
  int _timelineDisplayLimit = 20; // 타임라인 표시 개수 제한
  bool _enrollmentSubscriptionStarted = false;

  // 타임라인 프로바이더가 관리 (loadTimelineOnce / invalidate)

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_enrollmentSubscriptionStarted &&
        !_isPendingEnrollment &&
        widget.enrollment.id.isNotEmpty &&
        widget.enrollment.placeId.isNotEmpty) {
      _enrollmentSubscriptionStarted = true;
      final enrollmentProvider = Provider.of<EnrollmentProvider>(
        context,
        listen: false,
      );
      enrollmentProvider.loadUserEnrollments(
        userId: widget.member.userId,
        placeId: widget.enrollment.placeId,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    // 남은 횟수가 0이면 기간 조정 탭 제외
    final hasRemainingReservations =
        widget.enrollment.remainingReservations > 0;
    final tabCount = hasRemainingReservations ? 3 : 2;
    final initialIndex = widget.initialTabIndex?.clamp(0, tabCount - 1) ?? 0;
    _tabController = TabController(
      length: tabCount,
      vsync: this,
      initialIndex: initialIndex,
    );
    _tabController.addListener(() {
      if (hasRemainingReservations &&
          _tabController.index == 1 &&
          _extensionPeriodValue == 0) {
        setState(() {
          _extendedValidUntil = _clampValidUntil(_extensionBaseValidUntil);
        });
      }
      setState(() {}); // 탭 변경 시 UI 업데이트
    });

    // 탭 1: 횟수 조정 초기화
    _originalRemainingReservations = widget.enrollment.remainingReservations;
    _remainingReservationsController = TextEditingController(
      text: widget.enrollment.remainingReservations.toString(),
    );

    // 탭 2: 기간 조정 초기화
    _originalValidUntil = widget.enrollment.validUntil;
    // 최소 종료일 = max(오늘, validFrom) (서울 날짜-only)
    final seoulToday = TimezoneUtils.getSeoulToday();
    final validFromDateOnly = EnrollmentValidUntilUtil.toSeoulDateOnly(
      widget.enrollment.validFrom,
    );
    _extensionMinValidUntil = EnrollmentValidUntilUtil.maxDateOnly(
      seoulToday,
      validFromDateOnly,
    );

    // 기간 조절 기준 종료일 = "원래 종료일"(서울 날짜-only)
    // (단축도 가능해야 하므로 base를 today로 올려버리면 단축이 막힘)
    _extensionBaseValidUntil = EnrollmentValidUntilUtil.toSeoulDateOnly(
      _originalValidUntil,
    );

    // 초기 종료일은 "원래 종료일"을 보여주되, 최소 종료일(오늘/시작일)보다 과거면 클램핑
    _extendedValidUntil = _clampValidUntil(_extensionBaseValidUntil);

    _extensionPeriodController = TextEditingController(text: '0');
    // 초기화 시 주/달/일 모드에서도 동기화 보장
    _updateExtensionValidUntil();

    // 탭 3: 재등록/취소 초기화
    _originalReEnrollTotalReservations = widget.enrollment.totalReservations;
    _originalReEnrollValidFrom = widget.enrollment.validFrom;
    _originalReEnrollValidUntil = widget.enrollment.validUntil;

    final initialTotalReservations = widget.enrollment.totalReservations;

    _reEnrollTotalReservationsController = TextEditingController(
      text: initialTotalReservations.toString(),
    );
    _reEnrollPeriodController = TextEditingController();

    // 재등록 가능 여부 확인
    if (_canReEnroll()) {
      // 재등록 가능: 시작일 = 오늘
      final seoulToday = TimezoneUtils.getSeoulToday();

      // 일괄 적용 모드면 일괄 적용 유효기간 사용, 아니면 기존 유효기간 길이 상속
      DateTime initialValidUntil;
      PeriodType initialPeriodType;
      int initialPeriodValue;

      if (widget.course.defaultPeriodType != null &&
          widget.course.defaultPeriodValue != null) {
        final pt = widget.course.defaultPeriodType!;
        final pv = widget.course.defaultPeriodValue!;
        Duration duration;
        switch (pt) {
          case PeriodType.weeks:
            duration = Duration(days: pv * 7);
            break;
          case PeriodType.days:
            duration = Duration(days: pv);
            break;
          case PeriodType.months:
            duration = Duration(days: pv * 30);
            break;
        }
        initialValidUntil = seoulToday.add(duration);
        initialPeriodType = pt;
        initialPeriodValue = pv;
      } else {
        // 기존 유효기간 길이 상속
        final originalValidFromDateOnly =
            EnrollmentValidUntilUtil.toSeoulDateOnly(
              widget.enrollment.validFrom,
            );
        final originalValidUntilDateOnly =
            EnrollmentValidUntilUtil.toSeoulDateOnly(
              widget.enrollment.validUntil,
            );
        final originalDurationDays =
            originalValidUntilDateOnly
                .difference(originalValidFromDateOnly)
                .inDays;

        initialValidUntil = seoulToday.add(
          Duration(days: originalDurationDays.clamp(1, 36500)),
        );
        initialPeriodType = PeriodType.days;
        initialPeriodValue = originalDurationDays.clamp(1, 36500);
      }

      _reEnrollValidFrom = seoulToday;
      _reEnrollValidUntil = initialValidUntil;
      _reEnrollMode = ValidPeriodMode.period;
      _reEnrollPeriodType = initialPeriodType;
      _reEnrollPeriodValue = initialPeriodValue;
      _reEnrollPeriodController.text = initialPeriodValue.toString();
    } else {
      // 재등록 불가능: 기존 유효기간 표시 (회색 처리용)
      _reEnrollValidFrom = widget.enrollment.validFrom;
      _reEnrollValidUntil = widget.enrollment.validUntil;
      _reEnrollMode = ValidPeriodMode.period;
      _reEnrollPeriodType = PeriodType.days;
      _reEnrollPeriodValue = 0;
      _reEnrollPeriodController.text = '0';
    }

    // 히스토리는 "자세히 보기" 펼칠 때만 1회 조회 (구독 없음, 200개씩 페이지네이션)
  }

  void _invalidateTimelineAndReloadIfExpanded() {
    final ctx = _providerContext;
    if (ctx == null || !mounted) return;
    final provider = Provider.of<EnrollmentTimelineProvider>(
      ctx,
      listen: false,
    );
    provider.invalidate();
    if (_isDetailExpanded &&
        !_isPendingEnrollment &&
        widget.enrollment.id.isNotEmpty) {
      provider.loadTimelineOnce(widget.enrollment);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _remainingReservationsController.dispose();
    _extensionPeriodController.dispose();
    _reEnrollTotalReservationsController.dispose();
    _reEnrollPeriodController.dispose();
    super.dispose();
  }

  // 탭 1: 횟수 조정 저장
  bool _hasRemainingReservationsChanges() {
    final remaining = int.tryParse(_remainingReservationsController.text);
    if (remaining == null) return false;
    // 초기값과 비교하여 실제 변경이 있는지 확인
    return remaining != _originalRemainingReservations;
  }

  bool _isRemainingReservationsValid() {
    final remaining = int.tryParse(_remainingReservationsController.text);
    return remaining != null && remaining >= 0;
  }

  Future<void> _saveRemainingReservations() async {
    // 키보드 숨기기
    FocusScope.of(context).unfocus();

    if (!_isRemainingReservationsValid()) {
      SnackbarUtil.showInfo(context, '입력값을 확인해주세요.');
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      if (_leaveRequested) return;
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final placeId = placeProvider.currentPlace?.id;
      if (placeId == null || placeId.isEmpty) {
        if (mounted) {
          setState(() => _isSaving = false);
          SnackbarUtil.showInfo(context, '플레이스를 찾을 수 없습니다.');
        }
        return;
      }
      if (!await FirestoreUtils.canReachFirestoreForSave(
        probeCollection: 'places',
        probeDocId: placeId,
      )) {
        if (mounted) {
          setState(() => _isSaving = false);
          SnackbarUtil.showInfo(context, '네트워크 연결을 확인해주세요. ');
        }
        return;
      }
      final loadCtx = navigatorKey.currentContext;
      if (loadCtx != null) SnackbarUtil.showLoading(loadCtx, '저장 중…');

      final enrollmentService = EnrollmentService();
      final remaining = int.parse(_remainingReservationsController.text);

      if (_isPendingEnrollment) {
        // pending 상태: enrollments 생성이 아니라 pendingMembers 설정만 업데이트

        final memberService = MemberService();
        final success = await memberService.updatePendingCourseEnrollmentConfig(
          placeId: placeId,
          phoneNumber: widget.member.phoneNumber,
          courseId: widget.course.id,
          totalReservations: remaining,
          remainingReservations: remaining,
          validFrom: widget.enrollment.validFrom,
          validUntil: widget.enrollment.validUntil,
        );
        if (!success) throw Exception('pendingMembers 업데이트 실패');

        // 저장 성공 후 변경사항 추적 기준 업데이트
        setState(() {
          _originalRemainingReservations = remaining;
        });

        final memberProvider = Provider.of<MemberProvider>(
          context,
          listen: false,
        );
        memberProvider.setPlaceId(placeId);
        // 나갔어도 로딩 스낵바를 닫고 결과 표시
        final resultCtxPending = mounted ? context : navigatorKey.currentContext;
        if (resultCtxPending != null) {
          SnackbarUtil.showSuccess(resultCtxPending, '대기 등록 정보가 변경되었습니다.');
        }
        if (_leaveRequested) return;
      } else {
        // ✅ remainingReservations 변경 시 totalReservations도 함께 업데이트
        // remainingReservations가 totalReservations보다 크면 totalReservations도 증가
        final currentTotal = widget.enrollment.totalReservations;
        final newTotal = remaining > currentTotal ? remaining : currentTotal;

        final CourseEnrollment updatedEnrollment = widget.enrollment.copyWith(
          remainingReservations: remaining,
          totalReservations: newTotal,
        );

        await enrollmentService.updateEnrollmentWithAdminAction(
          updatedEnrollment: updatedEnrollment,
          action: EnrollmentAction(
            id: 'action_${DateTime.now().millisecondsSinceEpoch}',
            actionType: EnrollmentActionType.adjustCount,
            performedAt: TimezoneUtils.getSeoulDateTime(),
            performedBy: 'admin', // TODO: 실제 admin ID로 변경
            details:
                '남은 횟수를 $_originalRemainingReservations회에서 $remaining회로 조정',
            oldValue: {
              'remainingReservations': _originalRemainingReservations,
              'totalReservations': currentTotal,
            },
            newValue: {
              'remainingReservations': remaining,
              'totalReservations': newTotal,
            },
          ),
        );

        // 저장 성공 후 변경사항 추적 기준 업데이트
        setState(() {
          _originalRemainingReservations = remaining;
        });
        _invalidateTimelineAndReloadIfExpanded();

        final placeProvider = Provider.of<PlaceProvider>(
          context,
          listen: false,
        );
        final placeIdForRefresh = placeProvider.currentPlace?.id;
        if (placeIdForRefresh != null) {
          Provider.of<MemberProvider>(
            context,
            listen: false,
          ).setPlaceId(placeIdForRefresh);
        }

        // 나갔어도 로딩 스낵바를 닫고 결과 표시
        final resultCtx = mounted ? context : navigatorKey.currentContext;
        if (resultCtx != null) {
          SnackbarUtil.showSuccess(resultCtx, '남은 횟수가 변경되었습니다.');
        }
        if (_leaveRequested) return;
      }
    } catch (e) {
      final resultCtx = mounted ? context : navigatorKey.currentContext;
      if (resultCtx != null) {
        SnackbarUtil.showInfoFromError(
          resultCtx,
          e,
          fallback: '저장 중 오류가 발생했습니다.',
        );
      }
    } finally {
      SnackbarUtil.dismissLoading();
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  // 탭 2: 기간 조정 저장
  bool _hasPeriodExtensionChanges() {
    // 날짜만 비교 (시간 제외)
    final extendedDateOnly = EnrollmentValidUntilUtil.toSeoulDateOnly(
      _extendedValidUntil,
    );
    final baseDateOnly = DateTime(
      _extensionBaseValidUntil.year,
      _extensionBaseValidUntil.month,
      _extensionBaseValidUntil.day,
    );
    return extendedDateOnly != baseDateOnly;
  }

  // 최소 종료일 가져오기 (기간 조정 시 선택 가능 최소일)
  DateTime _getMinValidUntil() {
    return _extensionMinValidUntil;
  }

  // 종료일이 유효 범위 내에 있는지 확인 (최소값만 체크)
  bool _isValidUntilInRange(DateTime date) {
    final minDate = _getMinValidUntil();
    final dateOnly = EnrollmentValidUntilUtil.toSeoulDateOnly(date);
    final minDateOnly = DateTime(minDate.year, minDate.month, minDate.day);
    return EnrollmentValidUntilUtil.isBeforeOrSameDateOnly(
      minDateOnly,
      dateOnly,
    );
  }

  // 종료일을 유효 범위 내로 클램핑 (최소값만 체크)
  DateTime _clampValidUntil(DateTime date) {
    final minDate = _getMinValidUntil();
    final dateOnly = EnrollmentValidUntilUtil.toSeoulDateOnly(date);
    final minDateOnly = DateTime(minDate.year, minDate.month, minDate.day);
    if (dateOnly.isBefore(minDateOnly)) return minDateOnly;
    return EnrollmentValidUntilUtil.clampToMaxDateOnly(dateOnly);
  }

  // validUntil 자동 계산 함수
  void _updateExtensionValidUntil() {
    final computed = EnrollmentValidUntilUtil.computeExtendedEndDateOnly(
      baseEndDateOnly: _extensionBaseValidUntil,
      periodType: _extensionPeriodType,
      periodValue: _extensionPeriodValue,
    );
    // 최소값/최대값 통제 (date-only)
    final clamped = _clampValidUntil(computed);
    setState(() {
      _extendedValidUntil = clamped;
    });
  }

  // 주/일/달 모드에서 - 버튼을 누를 수 있는지 확인
  bool _canDecreasePeriod() {
    // 종료일이 최소 종료일과 같으면 더 줄일 수 없음
    final currentEnd = EnrollmentValidUntilUtil.toSeoulDateOnly(
      _extendedValidUntil,
    );
    final minEnd = DateTime(
      _extensionMinValidUntil.year,
      _extensionMinValidUntil.month,
      _extensionMinValidUntil.day,
    );
    return currentEnd.isAfter(minEnd);
  }

  // 주/일/달 모드에서 + 버튼을 누를 수 있는지 확인 (최대값 제한 없음)
  bool _canIncreasePeriod() {
    // 최대값 제한 없음 (999까지 가능)
    return _extensionPeriodValue < _getMaxPeriodValue();
  }

  // 주/일/달 모드에서 입력값이 유효한지 확인 (최소값만 체크)
  bool _isPeriodValueValid(int value) {
    final computed = EnrollmentValidUntilUtil.computeExtendedEndDateOnly(
      baseEndDateOnly: _extensionBaseValidUntil,
      periodType: _extensionPeriodType,
      periodValue: value,
    );
    return _isValidUntilInRange(computed);
  }

  int _getMaxPeriodValue() {
    // UI 입력 제한은 넉넉하게 두고, 실제 날짜는 2100-12-31로 clamp
    return 36500; // ~100년
  }

  String _getPeriodUnitText() {
    switch (_extensionPeriodType) {
      case PeriodType.weeks:
        return '주';
      case PeriodType.days:
        return '일';
      case PeriodType.months:
        return '개월';
    }
  }

  String _formatDate(DateTime date) {
    return TimezoneUtils.formatDateToSeoul(date).replaceAll('-', '.');
  }

  Future<void> _savePeriodExtension() async {
    // 키보드 숨기기
    FocusScope.of(context).unfocus();

    if (!_hasPeriodExtensionChanges()) {
      SnackbarUtil.showInfo(context, '변경사항이 없습니다.');
      return;
    }

    // 클라이언트 검증: 종료일이 유효 범위 내에 있는지 확인
    if (!_isValidUntilInRange(_extendedValidUntil)) {
      SnackbarUtil.showInfo(context, '종료일은 오늘 날짜 이후로만 선택할 수 있습니다.');
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      if (_leaveRequested) return;
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final placeId = placeProvider.currentPlace?.id;
      if (placeId == null || placeId.isEmpty) {
        if (mounted) {
          setState(() => _isSaving = false);
          SnackbarUtil.showInfo(context, '플레이스를 찾을 수 없습니다.');
        }
        return;
      }
      if (!await FirestoreUtils.canReachFirestoreForSave(
        probeCollection: 'places',
        probeDocId: placeId,
      )) {
        if (mounted) {
          setState(() => _isSaving = false);
          SnackbarUtil.showInfo(context, '네트워크 연결을 확인해주세요. ');
        }
        return;
      }
      final loadCtxPeriod = navigatorKey.currentContext;
      if (loadCtxPeriod != null) SnackbarUtil.showLoading(loadCtxPeriod, '저장 중…');

      final enrollmentService = EnrollmentService();

      if (_isPendingEnrollment) {
        // pending 상태: enrollments 생성이 아니라 pendingMembers 설정만 업데이트
        final memberService = MemberService();
        final success = await memberService.updatePendingCourseEnrollmentConfig(
          placeId: placeId,
          phoneNumber: widget.member.phoneNumber,
          courseId: widget.course.id,
          validFrom: widget.enrollment.validFrom,
          validUntil: _extendedValidUntil,
        );
        if (!success) throw Exception('pendingMembers 업데이트 실패');

        // 저장 성공 후 변경사항 추적 기준 업데이트
        setState(() {
          _originalValidUntil = _extendedValidUntil;
          _extensionBaseValidUntil = EnrollmentValidUntilUtil.toSeoulDateOnly(
            _extendedValidUntil,
          );
          _extensionPeriodValue = 0;
          _extensionPeriodController.text = '0';
          _updateExtensionValidUntil();
        });

        Provider.of<MemberProvider>(context, listen: false).setPlaceId(placeId);
        // 나갔어도 로딩 스낵바를 닫고 결과 표시
        final resultCtxPendingPeriod = mounted ? context : navigatorKey.currentContext;
        if (resultCtxPendingPeriod != null) {
          SnackbarUtil.showSuccess(resultCtxPendingPeriod, '대기 등록 정보가 변경되었습니다.');
        }
        if (_leaveRequested) return;
      } else {
        final CourseEnrollment updatedEnrollment = widget.enrollment.copyWith(
          validUntil: _extendedValidUntil,
        );

        await enrollmentService.updateEnrollmentWithAdminAction(
          updatedEnrollment: updatedEnrollment,
          action: EnrollmentAction(
            id: 'action_${DateTime.now().millisecondsSinceEpoch}',
            actionType: EnrollmentActionType.periodAdjust,
            performedAt: TimezoneUtils.getSeoulDateTime(),
            performedBy: 'admin', // TODO: 실제 admin ID로 변경
            details:
                '유효기간 ${TimezoneUtils.formatDateToSeoul(_originalValidUntil)} → ${TimezoneUtils.formatDateToSeoul(_extendedValidUntil)}',
            oldValue: {'validUntil': _originalValidUntil.toIso8601String()},
            newValue: {'validUntil': _extendedValidUntil.toIso8601String()},
          ),
        );

        // 저장 성공 후 변경사항 추적 기준 업데이트
        setState(() {
          _originalValidUntil = _extendedValidUntil;
          _extensionBaseValidUntil = EnrollmentValidUntilUtil.toSeoulDateOnly(
            _extendedValidUntil,
          );
          _extensionPeriodValue = 0;
          _extensionPeriodController.text = '0';
          _updateExtensionValidUntil();
        });
        _invalidateTimelineAndReloadIfExpanded();

        final placeProvider = Provider.of<PlaceProvider>(
          context,
          listen: false,
        );
        final placeIdForRefresh = placeProvider.currentPlace?.id;
        if (placeIdForRefresh != null) {
          Provider.of<MemberProvider>(
            context,
            listen: false,
          ).setPlaceId(placeIdForRefresh);
        }

        final resultCtxPeriod = mounted ? context : navigatorKey.currentContext;
        if (resultCtxPeriod != null) {
          SnackbarUtil.showSuccess(resultCtxPeriod, '유효기간이 변경되었습니다.');
        }
      }
    } catch (e) {
      final resultCtxPeriodErr = mounted ? context : navigatorKey.currentContext;
      if (resultCtxPeriodErr != null) {
        SnackbarUtil.showInfoFromError(
          resultCtxPeriodErr,
          e,
          fallback: '저장 중 오류가 발생했습니다.',
        );
      }
    } finally {
      SnackbarUtil.dismissLoading();
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  // 재등록 가능 여부 확인 (잔여 횟수 0 또는 유효기간 만료)
  bool _canReEnroll() {
    // pending(신규 생성 모드)에서는 재등록 불가
    if (_isPendingEnrollment) return false;

    final seoulToday = TimezoneUtils.getSeoulToday();
    final validUntilDateOnly = EnrollmentValidUntilUtil.toSeoulDateOnly(
      widget.enrollment.validUntil,
    );
    final todayDateOnly = DateTime(
      seoulToday.year,
      seoulToday.month,
      seoulToday.day,
    );
    final validUntilDateOnlyOnly = DateTime(
      validUntilDateOnly.year,
      validUntilDateOnly.month,
      validUntilDateOnly.day,
    );

    // 재등록 조건: 잔여 횟수 0 OR 유효기간 만료(오늘 이전)
    return widget.enrollment.remainingReservations == 0 ||
        validUntilDateOnlyOnly.isBefore(todayDateOnly);
  }

  // 탭 3: 재등록 저장
  bool _isReEnrollValid() {
    // 재등록 불가능하면 항상 false
    if (!_canReEnroll()) {
      return false;
    }
    final total = int.tryParse(_reEnrollTotalReservationsController.text);
    return total != null &&
        total > 0 &&
        _reEnrollValidUntil.isAfter(_reEnrollValidFrom);
  }

  bool _hasReEnrollChanges() {
    if (_isPendingEnrollment) return false;
    final total = int.tryParse(_reEnrollTotalReservationsController.text);
    if (total == null) return false;
    // 초기값과 비교하여 실제 변경이 있는지 확인
    return total != _originalReEnrollTotalReservations ||
        _reEnrollValidFrom != _originalReEnrollValidFrom ||
        _reEnrollValidUntil != _originalReEnrollValidUntil;
  }

  void _updateReEnrollValidUntilFromPeriod() {
    final startDateOnly = EnrollmentValidUntilUtil.toSeoulDateOnly(
      _reEnrollValidFrom,
    );
    final computed = EnrollmentValidUntilUtil.computeExtendedEndDateOnly(
      baseEndDateOnly: startDateOnly,
      periodType: _reEnrollPeriodType,
      periodValue: _reEnrollPeriodValue,
    );
    setState(() {
      // 최소: 시작일 다음날 이상은 아니고, "시작일보다 뒤"만 강제
      final minEnd = startDateOnly.add(const Duration(days: 1));
      final end = computed.isAfter(minEnd) ? computed : minEnd;
      _reEnrollValidUntil = end;
    });
  }

  Future<void> _saveReEnrollment() async {
    // 키보드 숨기기
    FocusScope.of(context).unfocus();

    // 버튼이 비활성인데도 호출되는 케이스 방지
    if (!_canReEnroll()) {
      SnackbarUtil.showInfo(context, '재등록은 잔여 횟수가 0이거나 유효기간이 만료된 경우에만 가능합니다.');
      return;
    }
    if (!_isReEnrollValid()) {
      SnackbarUtil.showInfo(context, '입력값을 확인해주세요.');
      return;
    }

    // 재등록 확인 다이얼로그
    final confirmed = await CommonDialog.show(
      context: context,
      title: '재등록',
      message: '재등록하시겠습니까?',
      cancelText: '취소',
      confirmText: '확인',
      confirmButtonColor: AppColors.primaryGreen,
    );

    if (confirmed != true) return;

    setState(() {
      _isReenrolling = true;
    });

    try {
      if (_leaveRequested) return;
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final placeId = placeProvider.currentPlace?.id;
      if (placeId == null || placeId.isEmpty) {
        throw Exception('플레이스를 찾을 수 없습니다.');
      }
      if (!await FirestoreUtils.canReachFirestoreForSave(
        probeCollection: 'places',
        probeDocId: placeId,
      )) {
        if (mounted) {
          setState(() => _isReenrolling = false);
          SnackbarUtil.showInfo(context, '네트워크 연결을 확인해주세요. ');
        }
        return;
      }

      final enrollmentService = EnrollmentService();
      final enrollmentProvider = Provider.of<EnrollmentProvider>(
        context,
        listen: false,
      );
      final enrollmentId = widget.enrollment.id;
      final now = TimezoneUtils.getSeoulDateTime();
      final totalReservations = int.parse(
        _reEnrollTotalReservationsController.text,
      );

      // ⚠️ 중요: pending 멤버인 경우 enrollments 생성 금지, pendingMembers만 업데이트
      if (_isPendingEnrollment) {
        // pending 멤버: pendingMembers의 courseEnrollments만 업데이트

        final memberService = MemberService();
        final success = await memberService.updatePendingCourseEnrollmentConfig(
          placeId: placeId,
          phoneNumber: widget.member.phoneNumber,
          courseId: widget.course.id,
          totalReservations: totalReservations,
          remainingReservations: totalReservations,
          validFrom: _reEnrollValidFrom,
          validUntil: _reEnrollValidUntil,
        );
        if (!success) throw Exception('pendingMembers 업데이트 실패');

        Provider.of<MemberProvider>(context, listen: false).setPlaceId(placeId);

        if (_leaveRequested) return;
        // 완료 후 화면 닫기
        if (mounted) {
          SnackbarUtil.showSuccess(context, '대기 등록 정보가 업데이트되었습니다.');
          Navigator.of(context).pop(true);
        }
        return; // pending 멤버 처리는 여기서 종료
      }

      if (widget.isNewEnrollment) {
        // ⚠️ 중앙 로직: pending/일반 멤버 자동 분기 처리
        final placeProvider = Provider.of<PlaceProvider>(
          context,
          listen: false,
        );
        final placeId = placeProvider.currentPlace?.id;
        if (placeId == null) {
          throw Exception('플레이스를 찾을 수 없습니다.');
        }

        final courseProvider = Provider.of<CourseProvider>(
          context,
          listen: false,
        );

        // courseEnrollments 데이터 준비
        final courseEnrollments = [
          {
            'courseId': widget.course.id,
            'totalReservations': totalReservations,
            'validFrom': _reEnrollValidFrom.toIso8601String(),
            'validUntil': _reEnrollValidUntil.toIso8601String(),
          },
        ];

        // ⚠️ 공통 로직 사용: enrollMemberToCourseOrUpdatePending
        final memberService = MemberService();
        final success = await memberService.enrollMemberToCourseOrUpdatePending(
          userId: widget.member.userId,
          placeId: placeId,
          phoneNumber: widget.member.phoneNumber,
          courseEnrollments: courseEnrollments,
          courses: courseProvider.courses,
          adminDisplayName: widget.member.adminDisplayName,
        );

        if (!success) {
          throw Exception('코스 등록에 실패했습니다.');
        }

        // 일반 멤버인 경우에만 액션 히스토리에 추가 (pending 멤버는 pendingMembers만 업데이트됨)
        if (!_isPendingEnrollment &&
            widget.member.userId.isNotEmpty &&
            !widget.member.userId.startsWith('pending_')) {
          final enrollmentId =
              '${widget.member.userId}_${placeId}_${widget.course.id}';
          try {
            await enrollmentService.addActionToHistory(
              enrollmentId,
              EnrollmentAction(
                id: 'action_${DateTime.now().millisecondsSinceEpoch}',
                actionType: EnrollmentActionType.reenroll,
                performedAt: now,
                performedBy: 'admin', // TODO: 실제 admin ID로 변경
                details: '재등록 처리 완료',
              ),
            );
            _invalidateTimelineAndReloadIfExpanded();
          } catch (e) {
            debugPrint('⚠️ 액션 히스토리 추가 실패 (무시): $e');
          }
        }

        // pendingMembers에서 해당 코스 제거 (일반 멤버가 pendingMembers에 있을 수 있음)
        await memberService.removeCourseFromPendingMembers(
          placeId: placeId,
          phoneNumber: widget.member.phoneNumber,
          courseId: widget.course.id,
        );

        Provider.of<MemberProvider>(context, listen: false).setPlaceId(placeId);
        if (_leaveRequested) return;

        // 재등록 후에는 enrollment 상태가 크게 변경되므로 화면을 닫음
        if (mounted) {
          SnackbarUtil.showSuccess(context, '코스가 등록되었습니다.');
          Navigator.of(context).pop(true);
        }
      } else {
        // 기존 enrollment 재등록 (validFrom = 등록 시점(enrolledAt)과 동일)
        final CourseEnrollment updatedEnrollment = widget.enrollment.copyWith(
          totalEnrollmentCount: widget.enrollment.totalEnrollmentCount + 1,
          enrolledAt: now,
          totalReservations: totalReservations,
          remainingReservations: totalReservations,
          validFrom: now,
          validUntil: _reEnrollValidUntil,
        );

        await enrollmentProvider.reenrollEnrollment(
          enrollmentId: enrollmentId,
          reenrollAction: () async {
            await enrollmentService.reenrollWithHistory(
              updatedEnrollment: updatedEnrollment,
              action: EnrollmentAction(
                id: 'action_${DateTime.now().millisecondsSinceEpoch}',
                actionType: EnrollmentActionType.reenroll,
                performedAt: now,
                performedBy: 'admin', // TODO: 실제 admin ID로 변경
                details: '재등록 처리 완료',
                oldValue: {
                  'enrollmentNumber': widget.enrollment.totalEnrollmentCount,
                  'totalReservations': widget.enrollment.totalReservations,
                  'validFrom': widget.enrollment.validFrom.toIso8601String(),
                  'validUntil': widget.enrollment.validUntil.toIso8601String(),
                },
                newValue: {
                  'enrollmentNumber':
                      widget.enrollment.totalEnrollmentCount + 1,
                  'totalReservations': totalReservations,
                  'validFrom': now.toIso8601String(),
                  'validUntil': _reEnrollValidUntil.toIso8601String(),
                },
              ),
            );
          },
        );
        if (_leaveRequested) return;
        _invalidateTimelineAndReloadIfExpanded();

        // 저장 성공 후 변경사항 추적 기준 업데이트 (validFrom=등록 시점으로 저장됨)
        setState(() {
          _originalReEnrollTotalReservations = totalReservations;
          _originalReEnrollValidFrom = now;
          _originalReEnrollValidUntil = _reEnrollValidUntil;
        });

        final placeProvider = Provider.of<PlaceProvider>(
          context,
          listen: false,
        );
        final placeId = placeProvider.currentPlace?.id;
        if (placeId != null) {
          Provider.of<MemberProvider>(
            context,
            listen: false,
          ).setPlaceId(placeId);
        }

        // 재등록 후에는 enrollment 상태가 크게 변경되므로 화면을 닫음
        if (mounted) {
          SnackbarUtil.showSuccess(context, '재등록이 완료되었습니다.');
          Navigator.of(context).pop(true);
        }
      }
    } catch (e) {
      if (_leaveRequested) return;
      if (mounted) {
        SnackbarUtil.showInfoFromError(
          context,
          e,
          fallback: '저장 중 오류가 발생했습니다.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isReenrolling = false;
        });
      }
    }
  }

  // 탭 3: 수강 취소
  Future<void> _cancelEnrollment() async {
    final confirmed = await CommonDialog.show(
      context: context,
      title: '수강 취소 처리',
      message: '해당 사용자를 수강 취소 하시겠습니까?\n모든 히스토리가 지워져요.',
      cancelText: '취소',
      confirmText: '수강 취소',
      confirmButtonColor: Colors.red,
    );

    if (confirmed != true) return;

    setState(() {
      _isCancelling = true;
    });

    try {
      if (_leaveRequested) return;
      // ⚠️ pending 멤버 체크 및 디버그 로그
      final isPending = _isPendingEnrollment;
      debugPrint(
        '[EnrollmentDetailScreen] _cancelEnrollment: isPending=$isPending',
      );
      debugPrint(
        '[EnrollmentDetailScreen] enrollment.userId=${widget.enrollment.userId}',
      );
      debugPrint(
        '[EnrollmentDetailScreen] enrollment.id=${widget.enrollment.id}',
      );
      debugPrint(
        '[EnrollmentDetailScreen] isNewEnrollment=${widget.isNewEnrollment}',
      );

      // pending 멤버(등록 전)면 Firestore enrollments 업데이트 없이 pendingMembers에서만 제거
      if (isPending) {
        debugPrint('[EnrollmentDetailScreen] pending 멤버 취소 처리 시작');
        final placeProvider = Provider.of<PlaceProvider>(
          context,
          listen: false,
        );
        final placeId = placeProvider.currentPlace?.id;
        if (placeId != null) {
          if (!await FirestoreUtils.canReachFirestoreForSave(
            probeCollection: 'places',
            probeDocId: placeId,
          )) {
            if (mounted) {
              setState(() => _isCancelling = false);
              SnackbarUtil.showInfo(context, '네트워크 연결을 확인해주세요. ');
            }
            return;
          }
          debugPrint(
            '[EnrollmentDetailScreen] removeCourseFromPendingMembers 호출: placeId=$placeId, phoneNumber=${widget.member.phoneNumber}, courseId=${widget.course.id}',
          );
          final memberService = MemberService();
          await memberService.removeCourseFromPendingMembers(
            placeId: placeId,
            phoneNumber: widget.member.phoneNumber,
            courseId: widget.course.id,
            keepPendingMember: true, // pending일 때는 코스만 제거하고 멤버는 유지
          );
          debugPrint(
            '[EnrollmentDetailScreen] removeCourseFromPendingMembers 완료',
          );
        } else {
          debugPrint('[EnrollmentDetailScreen] placeId가 null입니다.');
        }
        if (_leaveRequested) return;
        if (mounted) {
          SnackbarUtil.showSuccess(context, '수강 리스트에서 제외했습니다.');
          Navigator.of(context).pop(true);
        }
        return;
      }

      debugPrint('[EnrollmentDetailScreen] 일반 멤버 취소 처리 시작');

      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final placeId = placeProvider.currentPlace?.id;
      if (placeId == null) {
        throw Exception('플레이스를 찾을 수 없습니다.');
      }
      if (!await FirestoreUtils.canReachFirestoreForSave(
        probeCollection: 'places',
        probeDocId: placeId,
      )) {
        if (mounted) {
          setState(() => _isCancelling = false);
          SnackbarUtil.showInfo(context, '네트워크 연결을 확인해주세요. ');
        }
        return;
      }

      // ✅ Provider를 통해 취소 처리 (화면을 나가도 진행 상태 유지)
      final enrollmentProvider = Provider.of<EnrollmentProvider>(
        context,
        listen: false,
      );
      final enrollmentId = widget.enrollment.id;

      // 1) 서버에 미래 예약 존재 여부 확인 (cascade=false)
      try {
        await enrollmentProvider.cancelEnrollment(
          placeId: placeId,
          userId: widget.member.userId,
          courseId: widget.course.id,
          enrollmentId: enrollmentId,
          cascade: false,
        );
      } on FirebaseFunctionsException catch (e) {
        final details = e.details;
        final detailsMap =
            details is Map ? Map<String, dynamic>.from(details) : null;
        final requiresCascade = detailsMap?['requiresCascade'] == true;
        if (requiresCascade) {
          final reservationCount = detailsMap?['reservationCount'];

          final confirmedCascade = await CommonDialog.show(
            context: context,
            title: '수강 취소 처리',
            message: '수강자의 예약 $reservationCount건이 남아있습니다.\n수강취소 처리하시겠습니까?',
            cancelText: '취소',
            confirmText: '수강 취소',
            confirmButtonColor: Colors.red,
          );
          if (confirmedCascade != true) return;
          if (_leaveRequested) return;

          await enrollmentProvider.cancelEnrollment(
            placeId: placeId,
            userId: widget.member.userId,
            courseId: widget.course.id,
            enrollmentId: enrollmentId,
            cascade: true,
          );
        } else {
          rethrow;
        }
      }
      if (_leaveRequested) return;

      final memberProvider = Provider.of<MemberProvider>(
        context,
        listen: false,
      );
      memberProvider.setPlaceId(placeId);

      if (mounted) {
        SnackbarUtil.showSuccess(context, '수강취소 처리가 완료되었습니다.');
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (_leaveRequested) return;
      if (mounted) {
        SnackbarUtil.showInfoFromError(
          context,
          e,
          fallback: '취소 중 오류가 발생했습니다.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCancelling = false;
        });
      }
    }
  }

  Future<void> _handleBackDuringSave() async {
    if (!_isSaving && !_isReenrolling && !_isCancelling) return;
    final leave = await CommonDialog.showSavingLeaveConfirm(
      context: context,
      title: _isCancelling ? '취소 처리 중입니다' : '저장 중입니다',
      onLeave: () => _leaveRequested = true,
    );
    if (leave && mounted) {
      setState(() {
        _isSaving = false;
        _isReenrolling = false;
        _isCancelling = false;
      });
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<EnrollmentTimelineProvider>(
      create: (_) => EnrollmentTimelineProvider(),
      child: Builder(
        builder: (providerContext) {
          _providerContext = providerContext;
          final isLoading = _isSaving || _isReenrolling || _isCancelling;
          return PopScope(
            canPop: !isLoading,
            onPopInvokedWithResult: (bool didPop, dynamic result) async {
              if (didPop) return;
              if (isLoading)
                await _handleBackDuringSave();
              else if (mounted)
                Navigator.of(context).pop();
            },
            child: Scaffold(
              backgroundColor: AppColors.backgroundWhite,
              appBar: AppBar(
                scrolledUnderElevation: 0,
                backgroundColor: AppColors.backgroundWhite,
                elevation: 0,
                toolbarHeight: 100,
                centerTitle: false,
                leading: IconButton(
                  icon: Icon(
                    Icons.arrow_back_ios,
                    color: AppColors.textPrimary,
                  ),
                  onPressed: () async {
                    if (_isSaving || _isReenrolling || _isCancelling) {
                      await _handleBackDuringSave();
                    } else {
                      if (mounted) Navigator.of(context).pop();
                    }
                  },
                ),
                title: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${widget.course.name}',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${widget.member.name} · ${FormatUtils.formatPhoneNumber(widget.member.phoneNumber)}',
                      style: TextStyle(
                        fontSize: 16,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
                actions: [
                  if (_isPendingEnrollment)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: admin_shared.Chip(text: '가입 대기중'),
                      ),
                    ),
                ],
              ),
              body: SafeArea(
                child: SingleChildScrollView(
                  child: Consumer<EnrollmentProvider>(
                    builder: (context, enrollmentProvider, _) {
                      CourseEnrollment displayEnrollment = widget.enrollment;
                      if (!_isPendingEnrollment &&
                          widget.enrollment.id.isNotEmpty) {
                        final list =
                            enrollmentProvider.enrollments
                                .where((e) => e.id == widget.enrollment.id)
                                .toList();
                        if (list.isNotEmpty) {
                          displayEnrollment = list.first;
                        }
                      }
                      return Column(
                        children: [
                          const SizedBox(height: 10),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: DefaultTapbar(
                              labels:
                                  displayEnrollment.remainingReservations > 0
                                      ? const ['횟수 조정', '기간 조정', '재등록/취소']
                                      : const ['횟수 조정', '재등록/취소'],
                              selectedIndex: _tabController.index,
                              onTabChanged: (index) {
                                _tabController.animateTo(index);
                              },
                            ),
                          ),
                          AnimatedBuilder(
                            animation: _tabController,
                            builder: (context, child) {
                              return _buildCurrentTabContent(
                                _tabController.index,
                              );
                            },
                          ),
                          const SizedBox(height: 30),
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.start,
                                  children: [
                                    const SizedBox(width: 10),
                                    Text(
                                      '등록 정보',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.textPrimary,
                                      ),
                                    ),
                                    const Spacer(),
                                    if (!_isPendingEnrollment)
                                      TextButton.icon(
                                        onPressed: () {
                                          final willExpand = !_isDetailExpanded;
                                          setState(
                                            () =>
                                                _isDetailExpanded = willExpand,
                                          );
                                          if (willExpand &&
                                              widget.enrollment.id.isNotEmpty) {
                                            final provider =
                                                providerContext
                                                    .read<
                                                      EnrollmentTimelineProvider
                                                    >();
                                            if (provider
                                                .timelineItems
                                                .isEmpty) {
                                              provider.loadTimelineOnce(
                                                widget.enrollment,
                                              );
                                            }
                                          }
                                        },
                                        icon: Icon(
                                          _isDetailExpanded
                                              ? Icons.expand_less
                                              : Icons.expand_more,
                                          size: 20,
                                          color: AppColors.primaryGreen,
                                        ),
                                        label: Text(
                                          '자세히 보기',
                                          style: TextStyle(
                                            fontSize: 15,
                                            color: AppColors.textSecondary,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: AppColors.backgroundLight
                                        .withOpacity(0.7),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const SizedBox(height: 10),
                                      _buildInfoRow(
                                        '남은 예약 횟수',
                                        '${displayEnrollment.remainingReservations}회',
                                      ),
                                      _buildDivider(),
                                      _buildInfoRow(
                                        '현재 유효기간',
                                        TimezoneUtils.formatDateToSeoul(
                                          displayEnrollment.validUntil,
                                        ),
                                      ),
                                      _buildDivider(),
                                      _buildInfoRow(
                                        '최근 등록일',
                                        TimezoneUtils.formatDateToSeoul(
                                          displayEnrollment.enrolledAt,
                                        ),
                                      ),
                                      _buildDivider(),
                                      _buildInfoRow(
                                        '최초 등록일',
                                        TimezoneUtils.formatDateToSeoul(
                                          displayEnrollment.firstEnrolledAt,
                                        ),
                                      ),
                                      _buildDivider(),
                                      _buildInfoRow(
                                        '총 등록 횟수',
                                        '${displayEnrollment.totalEnrollmentCount}회',
                                      ),
                                      if (!_isPendingEnrollment &&
                                          _isDetailExpanded) ...[
                                        _buildDivider(),
                                        _buildDetailExpandedContent(),
                                      ],
                                      const SizedBox(height: 10),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 30),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildDivider() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Divider(height: 1, thickness: 0.5, color: AppColors.borderLight),
    );
  }

  // 현재 선택된 탭 내용 표시
  Widget _buildCurrentTabContent(int index) {
    final hasRemainingReservations =
        widget.enrollment.remainingReservations > 0;

    if (hasRemainingReservations) {
      // 기간 조정 탭 포함 (3개 탭)
      switch (index) {
        case 0:
          return _buildRemainingReservationsTabContent();
        case 1:
          return _buildPeriodExtensionTabContent();
        case 2:
          return _buildReEnrollCancelTabContent();
        default:
          return _buildRemainingReservationsTabContent();
      }
    } else {
      // 기간 조정 탭 제외 (2개 탭)
      switch (index) {
        case 0:
          return _buildRemainingReservationsTabContent();
        case 1:
          return _buildReEnrollCancelTabContent();
        default:
          return _buildRemainingReservationsTabContent();
      }
    }
  }

  // 탭 1: 횟수 조정 내용
  Widget _buildRemainingReservationsTabContent() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '남은 예약 횟수 조정',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 14),

            Text(
              '유효기간 중 남은 횟수',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _remainingReservationsController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: TextStyle(
                fontSize: 16,
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
              decoration: TextFieldDecorationUtil.defaultDecoration(
                hintText: '0 이상',
                hasFocus: false,
                floatingLabelBehavior: FloatingLabelBehavior.always,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 24),
            Text(
              '현재까지 총 예약 횟수: ${widget.enrollment.totalReservations - widget.enrollment.remainingReservations}회',
              style: TextStyle(fontSize: 15, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 32),
            // 저장 버튼 (바깥에 padding 4)
            Padding(
              padding: const EdgeInsets.all(4),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed:
                      (_isRemainingReservationsValid() &&
                              _hasRemainingReservationsChanges() &&
                              !_isSaving)
                          ? _saveRemainingReservations
                          : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        (_isRemainingReservationsValid() &&
                                _hasRemainingReservationsChanges() &&
                                !_isSaving)
                            ? AppColors.primaryGreen
                            : AppColors.borderLight,
                    disabledBackgroundColor: AppColors.borderLight,
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
                              color: AppColors.primaryGreen,
                            ),
                          )
                          : Text(
                            '저장',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color:
                                  (_isRemainingReservationsValid() &&
                                          _hasRemainingReservationsChanges() &&
                                          !_isSaving)
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

  // 탭 2: 기간 조정 내용
  Widget _buildPeriodExtensionTabContent() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: Text(
                '유효기간 조정',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Text(
                  '유효기간',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textSecondary,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () {
                    setState(() {
                      // 캘린더 모드 토글
                      if (_extensionMode == ValidPeriodMode.calendar) {
                        // 캘린더 모드에서 주/달/일 모드로 전환
                        _extensionMode = ValidPeriodMode.period;
                        _updateExtensionValidUntil();
                      } else {
                        // 주/달/일 모드에서 캘린더 모드로 전환
                        _extensionMode = ValidPeriodMode.calendar;
                      }
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color:
                          _extensionMode == ValidPeriodMode.calendar
                              ? AppColors.primaryGreen
                              : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SvgPicture.asset(
                      'assets/icons/calendar-icon.svg',
                      width: 20,
                      height: 20,
                      colorFilter: ColorFilter.mode(
                        _extensionMode == ValidPeriodMode.calendar
                            ? AppColors.brandWhite
                            : AppColors.textSecondary,
                        BlendMode.srcIn,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 캘린더 모드: 종료일만 지정 버튼 (시작일은 이미 지정되어 있음)
            if (_extensionMode == ValidPeriodMode.calendar) ...[
              Column(
                children: [
                  SizedBox(height: 5),
                  // 시작일 표시 (읽기 전용)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      vertical: 16,
                      horizontal: 16,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.backgroundLight,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Text(
                          '시작일',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          _formatDate(widget.enrollment.validFrom),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 종료일 선택 버튼
                  GestureDetector(
                    onTap: () async {
                      final currentValidUntil = _extendedValidUntil;
                      final minDate = _getMinValidUntil();

                      // 단일 날짜 선택 다이얼로그 사용 (최대값 제한 없음)
                      final picked =
                          await DateRangePickerUtil.showSingleDatePicker(
                            context: context,
                            initialDate: currentValidUntil,
                            firstDate: minDate,
                            lastDate: DateTime(2100, 12, 31), // 최대값 제한 없음
                            title: '종료일 선택',
                          );

                      if (picked != null) {
                        // 최소값만 체크하여 클램핑
                        final clampedDate = _clampValidUntil(picked);
                        setState(() {
                          _extendedValidUntil = clampedDate;
                        });
                      }
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        vertical: 16,
                        horizontal: 16,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.backgroundLight,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Text(
                            '종료일 지정',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            _formatDate(_extendedValidUntil),
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          SizedBox(width: 4),
                          Icon(
                            Icons.keyboard_arrow_right_rounded,
                            size: 24,
                            color: AppColors.textLight,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              // 탭바 (주/달/일)
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: AppColors.backgroundLight,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _buildPeriodTab(
                        label: '주',
                        isSelected: _extensionPeriodType == PeriodType.weeks,
                        onTap: () {
                          setState(() {
                            _extensionMode = ValidPeriodMode.period;
                            _extensionPeriodType = PeriodType.weeks;
                            _extensionPeriodValue = 0;
                            _extensionPeriodController.text = '0';
                            _updateExtensionValidUntil();
                          });
                        },
                      ),
                    ),
                    Expanded(
                      child: _buildPeriodTab(
                        label: '달',
                        isSelected: _extensionPeriodType == PeriodType.months,
                        onTap: () {
                          setState(() {
                            _extensionMode = ValidPeriodMode.period;
                            _extensionPeriodType = PeriodType.months;
                            _extensionPeriodValue = 0;
                            _extensionPeriodController.text = '0';
                            _updateExtensionValidUntil();
                          });
                        },
                      ),
                    ),
                    Expanded(
                      child: _buildPeriodTab(
                        label: '일',
                        isSelected: _extensionPeriodType == PeriodType.days,
                        onTap: () {
                          setState(() {
                            _extensionMode = ValidPeriodMode.period;
                            _extensionPeriodType = PeriodType.days;
                            _extensionPeriodValue = 0;
                            _extensionPeriodController.text = '0';
                            _updateExtensionValidUntil();
                          });
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
                  color: AppColors.backgroundLight,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // - 버튼
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap:
                            _canDecreasePeriod()
                                ? () {
                                  setState(() {
                                    _extensionMode = ValidPeriodMode.period;
                                    final newValue = _extensionPeriodValue - 1;
                                    _extensionPeriodValue = newValue;
                                    _extensionPeriodController.text =
                                        newValue.toString();
                                    _updateExtensionValidUntil();
                                  });
                                }
                                : null,
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          child: Icon(
                            Icons.remove_rounded,
                            size: 20,
                            color:
                                _canDecreasePeriod()
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
                        controller: _extensionPeriodController,
                        keyboardType: TextInputType.number,
                        // 단축도 가능해야 하므로 음수 입력 허용
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'^-?\d*$')),
                        ],
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color:
                              _extensionPeriodValue == 0
                                  ? AppColors.textSecondary.withOpacity(0.4)
                                  : AppColors.textPrimary,
                        ),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText: '0',
                          contentPadding: EdgeInsets.zero,
                          isDense: true,
                          suffixText: _getPeriodUnitText(),
                          suffixStyle: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        onChanged: (value) {
                          if (value.isEmpty) {
                            setState(() {
                              _extensionMode = ValidPeriodMode.period;
                              _extensionPeriodValue = 0;
                              _updateExtensionValidUntil();
                            });
                          } else {
                            final intValue = int.tryParse(value);
                            if (intValue != null &&
                                intValue.abs() <= _getMaxPeriodValue()) {
                              // 범위 검증
                              if (_isPeriodValueValid(intValue)) {
                                setState(() {
                                  _extensionMode = ValidPeriodMode.period;
                                  _extensionPeriodValue = intValue;
                                  _updateExtensionValidUntil();
                                });
                              } else {
                                // 범위를 벗어나면 클램핑
                                setState(() {
                                  _extensionMode = ValidPeriodMode.period;
                                  _extensionPeriodValue = intValue;
                                  _updateExtensionValidUntil();
                                  // 클램핑된 값으로 다시 설정
                                  _extensionPeriodController.text =
                                      _extensionPeriodValue.toString();
                                });
                              }
                            }
                          }
                        },
                        onSubmitted: (value) {
                          if (value.isEmpty) {
                            setState(() {
                              _extensionMode = ValidPeriodMode.period;
                              _extensionPeriodValue = 0;
                              _extensionPeriodController.text = '0';
                              _updateExtensionValidUntil();
                            });
                          } else {
                            final intValue = int.tryParse(value);
                            if (intValue == null) {
                              setState(() {
                                _extensionMode = ValidPeriodMode.period;
                                _extensionPeriodValue = 0;
                                _extensionPeriodController.text = '0';
                                _updateExtensionValidUntil();
                              });
                            } else if (intValue.abs() > _getMaxPeriodValue()) {
                              final capped =
                                  intValue.isNegative
                                      ? -_getMaxPeriodValue()
                                      : _getMaxPeriodValue();
                              setState(() {
                                _extensionMode = ValidPeriodMode.period;
                                _extensionPeriodValue = capped;
                                _extensionPeriodController.text =
                                    capped.toString();
                                _updateExtensionValidUntil();
                              });
                            } else {
                              // 범위 검증
                              if (_isPeriodValueValid(intValue)) {
                                setState(() {
                                  _extensionMode = ValidPeriodMode.period;
                                  _extensionPeriodValue = intValue;
                                  _updateExtensionValidUntil();
                                });
                              } else {
                                // 범위를 벗어나면 클램핑
                                setState(() {
                                  _extensionMode = ValidPeriodMode.period;
                                  _extensionPeriodValue = intValue;
                                  _updateExtensionValidUntil();
                                  // 클램핑된 값으로 다시 설정
                                  _extensionPeriodController.text =
                                      _extensionPeriodValue.toString();
                                });
                              }
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
                        onTap:
                            _canIncreasePeriod() &&
                                    _extensionPeriodValue.abs() <
                                        _getMaxPeriodValue()
                                ? () {
                                  setState(() {
                                    _extensionMode = ValidPeriodMode.period;
                                    final newValue = _extensionPeriodValue + 1;
                                    _extensionPeriodValue = newValue;
                                    _extensionPeriodController.text =
                                        newValue.toString();
                                    _updateExtensionValidUntil();
                                  });
                                }
                                : null,
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          child: Icon(
                            Icons.add_rounded,
                            size: 20,
                            color:
                                _canIncreasePeriod() &&
                                        _extensionPeriodValue <
                                            _getMaxPeriodValue()
                                    ? AppColors.primaryGreen
                                    : AppColors.textLight.withOpacity(0.3),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 주/달/일 모드에서 종료날짜 작게 표시
              if (_extensionMode == ValidPeriodMode.period) ...[
                const SizedBox(height: 8),
                Text(
                  '종료일: ${_formatDate(_extendedValidUntil)}',
                  style: TextStyle(
                    fontSize: 14,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ],
            const SizedBox(height: 32),
            // 저장 버튼 (바깥에 padding 4)
            Padding(
              padding: const EdgeInsets.all(4),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed:
                      (_hasPeriodExtensionChanges() && !_isSaving)
                          ? _savePeriodExtension
                          : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        (_hasPeriodExtensionChanges() && !_isSaving)
                            ? AppColors.primaryGreen
                            : AppColors.borderLight,
                    disabledBackgroundColor: AppColors.borderLight,
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
                              color: AppColors.primaryGreen,
                            ),
                          )
                          : Text(
                            '저장',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color:
                                  (_hasPeriodExtensionChanges() && !_isSaving)
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

  /// 유효기간 탭 위젯
  Widget _buildPeriodTab({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.backgroundWhite : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color:
                  isSelected ? AppColors.textPrimary : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  // 탭 3: 재등록/취소 내용
  Widget _buildReEnrollCancelTabContent() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.borderLight),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 수업 횟수 지정 UI (공통 위젯 사용)
            ReservationsInputWidget(
              controller: _reEnrollTotalReservationsController,
              currentValue:
                  int.tryParse(_reEnrollTotalReservationsController.text) ?? 0,
              defaultValue: widget.course.defaultTotalReservations,
              enabled: _canReEnroll(),
              onChanged: (value) {
                setState(() {});
              },
            ),
            const SizedBox(height: 24),

            // 유효기간 UI (공통 위젯 사용)
            // 재등록에서는 시작일을 변경할 수 없으므로 onValidFromChanged는 null
            ValidPeriodInputWidget(
              validFrom: _reEnrollValidFrom,
              validUntil: _reEnrollValidUntil,
              periodType: _reEnrollPeriodType,
              periodValue: _reEnrollPeriodValue,
              mode: _reEnrollMode,
              enabled: _canReEnroll(),
              minValidUntil: EnrollmentValidUntilUtil.maxDateOnly(
                TimezoneUtils.getSeoulToday(),
                EnrollmentValidUntilUtil.toSeoulDateOnly(_reEnrollValidFrom),
              ),
              maxPeriodValue: 999,
              minPeriodValue: 0,
              onModeChanged: (mode) {
                setState(() {
                  _reEnrollMode = mode;
                  if (mode == ValidPeriodMode.period) {
                    _updateReEnrollValidUntilFromPeriod();
                  }
                });
              },
              onValidFromChanged: null, // 재등록에서는 시작일 변경 불가
              onValidUntilChanged: (date) {
                setState(() {
                  _reEnrollValidUntil = date;
                });
              },
              onPeriodTypeChanged: (type) {
                setState(() {
                  _reEnrollPeriodType = type;
                  _reEnrollPeriodValue = type == PeriodType.days ? 7 : 1;
                  _reEnrollPeriodController.text =
                      _reEnrollPeriodValue.toString();
                  _updateReEnrollValidUntilFromPeriod();
                });
              },
              onPeriodValueChanged: (value) {
                setState(() {
                  _reEnrollPeriodValue = value.clamp(0, 999);
                  _reEnrollPeriodController.text =
                      _reEnrollPeriodValue.toString();
                  _updateReEnrollValidUntilFromPeriod();
                });
              },
            ),
            const SizedBox(height: 32),
            // 재등록 버튼
            Padding(
              padding: const EdgeInsets.all(4),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    if (_isReenrolling || _isCancelling) return;
                    if (_canReEnroll() &&
                        _isReEnrollValid() &&
                        _hasReEnrollChanges()) {
                      _saveReEnrollment();
                      return;
                    }
                    if (!_canReEnroll() &&
                        widget.enrollment.remainingReservations > 0) {
                      SnackbarUtil.showInfo(context, '아직 예약 가능 횟수가 남았어요.');
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        (_canReEnroll() &&
                                _isReEnrollValid() &&
                                _hasReEnrollChanges() &&
                                !_isReenrolling &&
                                !_isCancelling)
                            ? AppColors.primaryGreen
                            : AppColors.borderLight,
                    disabledBackgroundColor: AppColors.borderLight,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    elevation: 0,
                  ),
                  child:
                      _isReenrolling
                          ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.primaryGreen,
                            ),
                          )
                          : Text(
                            '재등록',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color:
                                  (_canReEnroll() &&
                                          _isReEnrollValid() &&
                                          _hasReEnrollChanges() &&
                                          !_isReenrolling &&
                                          !_isCancelling)
                                      ? Colors.white
                                      : AppColors.textSecondary,
                            ),
                          ),
                ),
              ),
            ),

            // 수강 취소 버튼 (바깥에 padding 4)
            Padding(
              padding: const EdgeInsets.all(4),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed:
                      (_isCancelling || _isReenrolling)
                          ? null
                          : _cancelEnrollment,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    side: BorderSide(
                      color: Colors.red.withOpacity(0.8),
                      width: 1,
                    ),
                  ),
                  child:
                      _isCancelling
                          ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.red,
                            ),
                          )
                          : Text(
                            '수강 취소 처리',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.red,
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

  Widget _buildInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 15, color: AppColors.textSecondary),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
      ],
    );
  }

  // 자세히 보기 펼쳐진 내용 (EnrollmentTimelineProvider 사용)
  Widget _buildDetailExpandedContent() {
    return Consumer<EnrollmentTimelineProvider>(
      builder: (context, provider, _) {
        if (provider.isLoading) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.primaryGreen,
                ),
              ),
            ),
          );
        }
        if (provider.error != null) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              '히스토리를 불러오지 못했어요. 다시 펼쳐 보세요.',
              style: TextStyle(fontSize: 15, color: AppColors.textSecondary),
            ),
          );
        }

        final allItems = provider.timelineItems;
        final availableFilters = <String>{};
        for (final item in allItems) {
          availableFilters.add(_getTimelineFilterCategory(item));
        }

        List<EnrollmentTimelineItem> filteredItems = allItems;
        if (_selectedTimelineFilter != null) {
          filteredItems =
              allItems
                  .where(
                    (item) =>
                        _getTimelineFilterCategory(item) ==
                        _selectedTimelineFilter,
                  )
                  .toList();
        }

        if (filteredItems.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              '히스토리가 아직 없어요.',
              style: TextStyle(fontSize: 15, color: AppColors.textSecondary),
            ),
          );
        }

        final totalCount = filteredItems.length;
        final displayItems = filteredItems.take(_timelineDisplayLimit).toList();
        final hasMore = totalCount > _timelineDisplayLimit;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 16),
            Text(
              '히스토리',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            if (availableFilters.length > 1) ...[
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildTimelineFilterChip(
                      label: '전체',
                      isSelected: _selectedTimelineFilter == null,
                      onTap:
                          () => setState(() => _selectedTimelineFilter = null),
                    ),
                    const SizedBox(width: 4),
                    ...availableFilters.map((filter) {
                      return Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: _buildTimelineFilterChip(
                          label: filter,
                          isSelected: _selectedTimelineFilter == filter,
                          onTap:
                              () => setState(
                                () => _selectedTimelineFilter = filter,
                              ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 22),
            ],
            _buildTimelineContainer(displayItems, hasMore),
            if (hasMore) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _timelineDisplayLimit += 20),
                  child: Text(
                    '더 보기 (${totalCount - _timelineDisplayLimit}개 남음)',
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.primaryGreen,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
            if (provider.hasMoreActions) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed:
                      provider.isLoadingMore
                          ? null
                          : () => provider.loadMoreActions(),
                  icon:
                      provider.isLoadingMore
                          ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.primaryGreen,
                            ),
                          )
                          : Icon(
                            Icons.add_circle_outline,
                            size: 20,
                            color: AppColors.primaryGreen,
                          ),
                  label: Text(
                    provider.isLoadingMore ? '불러오는 중…' : '다음 200개 불러오기',
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.primaryGreen,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  String _getTimelineFilterCategory(EnrollmentTimelineItem item) {
    return switch (item) {
      ReservationTimelineItem() => '예약',
      ActionTimelineItem(:final action) => switch (action.actionType) {
        EnrollmentActionType.adjustCount => '횟수조정',
        EnrollmentActionType.periodAdjust => '기간조정',
        EnrollmentActionType.reenroll => '재등록',
        EnrollmentActionType.reservationMove ||
        EnrollmentActionType.reservationCancel => '예약',
        EnrollmentActionType.cancel || EnrollmentActionType.other => '기타',
      },
    };
  }

  Widget _buildTimelineFilterChip({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color:
              isSelected
                  ? AppColors.primaryGreen
                  : const Color.fromARGB(255, 238, 238, 238),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: isSelected ? Colors.white : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildTimelineContainer(
    List<EnrollmentTimelineItem> items,
    bool hasMore,
  ) {
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 5,
          top: 0,
          bottom: 0,
          child: Container(width: 2, color: AppColors.borderLight),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children:
                items.asMap().entries.map((entry) {
                  final index = entry.key;
                  final item = entry.value;
                  final isLast = index == items.length - 1 && !hasMore;
                  return _buildTimelineItem(item, isLast);
                }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildTimelineItem(EnrollmentTimelineItem item, bool isLast) {
    final Widget content = switch (item) {
      ReservationTimelineItem(:final reservation) =>
        _buildReservationTimelineItem(reservation),
      ActionTimelineItem(:final action) => _buildActionTimelineItem(action),
    };
    final color = switch (item) {
      ReservationTimelineItem() => AppColors.primaryGreen,
      ActionTimelineItem(:final action) => _getTimelineItemColor(
        action.actionType,
      ),
    };

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
          child: content,
        ),
        Positioned(
          left: -18,
          top: 1,
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
        // 점에서 카드로 이어지는 가로선 (점의 오른쪽에서 카드 왼쪽까지)
        Positioned(
          left: -9, // 점의 오른쪽 가장자리 (left: -15 + 6 = -9, 점의 중심에서 오른쪽으로)
          top: 5, // 점의 중앙 높이 (12/2 - 2/2 = 5)
          child: Container(
            width: 9, // 점의 중심(left: -9)에서 카드 왼쪽(left: 0)까지
            height: 2,
            color: AppColors.borderLight,
          ),
        ),
      ],
    );
  }

  Widget _buildReservationTimelineItem(SessionReservation r) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '예약',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '일시: ${TimezoneUtils.formatDateToSeoul(r.reservedDate)} ${r.startTime}',
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Color _getTimelineItemColor(EnrollmentActionType type) {
    switch (type) {
      case EnrollmentActionType.cancel:
        return const Color.fromARGB(255, 253, 115, 105);
      case EnrollmentActionType.adjustCount:
      case EnrollmentActionType.periodAdjust:
      case EnrollmentActionType.reenroll:
      case EnrollmentActionType.reservationMove:
      case EnrollmentActionType.reservationCancel:
        return const Color.fromARGB(255, 59, 59, 59);
      default:
        return AppColors.textSecondary;
    }
  }

  Widget _buildActionTimelineItem(EnrollmentAction action) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _getActionTypeLabel(action.actionType),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '일시: ${TimezoneUtils.formatDateToSeoul(action.performedAt)}',
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
          ),
          if (action.details != null && action.details!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '내용: ${action.details}',
              style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }

  String _getActionTypeLabel(EnrollmentActionType type) {
    switch (type) {
      case EnrollmentActionType.adjustCount:
        return '횟수 조정';
      case EnrollmentActionType.periodAdjust:
        return '유효기간 조정';
      case EnrollmentActionType.reenroll:
        return '재등록';
      case EnrollmentActionType.cancel:
        return '수강 취소';
      case EnrollmentActionType.reservationMove:
        return '예약 이동';
      case EnrollmentActionType.reservationCancel:
        return '예약 취소';
      case EnrollmentActionType.other:
        return '기타';
    }
  }
}
