import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:provider/provider.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../../models/course.dart';
import '../../../models/course_enrollment.dart';
import '../../../models/admin_models.dart';
import '../../../providers/member_provider.dart';
import '../../../providers/place_provider.dart';
import '../../../providers/enrollment_provider.dart';
import '../../../providers/course_provider.dart';
import '../../../services/enrollment_service.dart';
import '../../../services/member_service.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/text_field_decoration_util.dart';
import '../../../utils/timezone_utils.dart';
import '../../../utils/snackbar_util.dart';
import '../../../utils/format_utils.dart';
import '../../../utils/date_range_picker_util.dart';
import '../../../utils/enrollment_valid_until_util.dart';
import '../../../utils/member_utils.dart';
import '../../../widgets/defualt_tapbar.dart';
import '../../../widgets/valid_period_input_widget.dart';
import '../../../widgets/reservations_input_widget.dart';
import '../../../widgets/common_dialog.dart';

/// 코스 등록 상세 화면
/// 탭 기반으로 횟수 조정, 기간 연장, 재등록/취소 처리
class EnrollmentDetailScreen extends StatefulWidget {
  final MemberData member;
  final CourseEnrollment enrollment;
  final Course course;
  final bool isNewEnrollment; // 새 enrollment 생성 모드
  final int? initialTabIndex; // 초기 탭 인덱스 (0: 횟수 조정, 1: 기간 연장, 2: 재등록/취소)

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
        MemberUtils.isPendingMember(widget.enrollment.userId);
  }

  // 탭 1: 횟수 조정
  late TextEditingController _remainingReservationsController;
  late int _originalRemainingReservations; // 초기값 추적

  // 탭 2: 기간 연장
  late DateTime _extendedValidUntil;
  late DateTime _originalValidUntil; // 초기값 추적
  late DateTime
  _extensionBaseValidUntil; // 기간 연장 기준 종료일(서울 날짜-only): max(원래 종료일, 오늘)
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

  bool _isSaving = false; // 횟수 조정/기간 연장용
  bool _isCancelling = false; // 수강 취소용
  bool _isReenrolling = false; // 재등록용
  bool _isDetailExpanded = false; // 자세히 보기 펼침 상태
  String? _selectedTimelineFilter; // 타임라인 필터 (null이면 전체)
  int _timelineDisplayLimit = 20; // 타임라인 표시 개수 제한

  // 서브컬렉션 데이터
  List<ReenrollmentRecord> _loadedReenrollmentHistory = [];
  List<AdminAction> _loadedAdminActions = [];
  List<ExtensionRequest> _loadedExtensionRequests = [];
  StreamSubscription<List<ReenrollmentRecord>>?
  _reenrollmentHistorySubscription;
  StreamSubscription<List<AdminAction>>? _adminActionsSubscription;
  StreamSubscription<List<ExtensionRequest>>? _extensionRequestsSubscription;

  @override
  void initState() {
    super.initState();
    // 남은 횟수가 0이면 기간 연장 탭 제외
    // 단, 연장 요청이 있으면 기간 연장 탭을 표시 (연장 요청 처리 가능하도록)
    final hasRemainingReservations =
        widget.enrollment.remainingReservations > 0;
    final hasPendingExtensionRequest =
        widget.enrollment.hasPendingExtensionRequest;
    final tabCount =
        (hasRemainingReservations || hasPendingExtensionRequest) ? 3 : 2;
    final initialIndex = widget.initialTabIndex?.clamp(0, tabCount - 1) ?? 0;
    _tabController = TabController(
      length: tabCount,
      vsync: this,
      initialIndex: initialIndex,
    );
    _tabController.addListener(() {
      // 탭 변경 시 기간 연장 탭으로 돌아오면 원래 종료일로 동기화
      // 남은 횟수가 있거나 연장 요청이 있으면 기간 연장 탭이 존재 (인덱스 1)
      final hasRemainingReservations =
          widget.enrollment.remainingReservations > 0;
      final hasPendingExtensionRequest =
          widget.enrollment.hasPendingExtensionRequest;
      if ((hasRemainingReservations || hasPendingExtensionRequest) &&
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

    // 탭 2: 기간 연장 초기화
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

    // 일괄 적용 모드 확인: 코스에 일괄 적용 설정이 있으면 그것을 사용
    final useUniform = widget.course.useUniformSettings;
    final initialTotalReservations =
        useUniform && widget.course.uniformTotalReservations != null
            ? widget.course.uniformTotalReservations!
            : widget.enrollment.totalReservations;

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

      if (useUniform &&
          widget.course.uniformPeriodType != null &&
          widget.course.uniformPeriodValue != null) {
        // 일괄 적용 모드: 일괄 적용 유효기간 사용
        final uniformPeriodType = widget.course.uniformPeriodType!;
        final uniformPeriodValue = widget.course.uniformPeriodValue!;

        Duration duration;
        switch (uniformPeriodType) {
          case PeriodType.weeks:
            duration = Duration(days: uniformPeriodValue * 7);
            break;
          case PeriodType.days:
            duration = Duration(days: uniformPeriodValue);
            break;
          case PeriodType.months:
            duration = Duration(days: uniformPeriodValue * 30);
            break;
        }

        initialValidUntil = seoulToday.add(duration);
        initialPeriodType = uniformPeriodType;
        initialPeriodValue = uniformPeriodValue;
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

    // 서브컬렉션에서 히스토리 데이터 로드
    if (!_isPendingEnrollment && widget.enrollment.id.isNotEmpty) {
      _loadHistoryData();
    }
  }

  void _loadHistoryData() {
    final enrollmentService = EnrollmentService();

    // 기존 구독 취소 (중복 구독 방지)
    _reenrollmentHistorySubscription?.cancel();
    _adminActionsSubscription?.cancel();
    _extensionRequestsSubscription?.cancel();

    // 재등록 이력 구독
    _reenrollmentHistorySubscription = enrollmentService
        .watchReenrollmentHistory(
          enrollmentId: widget.enrollment.id,
          limit: 100, // 충분히 많이 로드
        )
        .listen((history) {
          if (mounted) {
            setState(() {
              _loadedReenrollmentHistory = history;
            });
          }
        });

    // 관리자 액션 구독
    _adminActionsSubscription = enrollmentService
        .watchAdminActions(enrollmentId: widget.enrollment.id, limit: 100)
        .listen((actions) {
          if (mounted) {
            setState(() {
              _loadedAdminActions = actions;
            });
          }
        });

    // 연장 요청 구독
    _extensionRequestsSubscription = enrollmentService
        .watchEnrollmentExtensionRequests(
          enrollmentId: widget.enrollment.id,
          limit: 100,
        )
        .listen((requests) {
          if (mounted) {
            setState(() {
              _loadedExtensionRequests = requests;
            });
          }
        });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _remainingReservationsController.dispose();
    _extensionPeriodController.dispose();
    _reEnrollTotalReservationsController.dispose();
    _reEnrollPeriodController.dispose();
    _reenrollmentHistorySubscription?.cancel();
    _adminActionsSubscription?.cancel();
    _extensionRequestsSubscription?.cancel();
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
      SnackbarUtil.showError(context, '입력값을 확인해주세요.');
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final enrollmentService = EnrollmentService();
      final remaining = int.parse(_remainingReservationsController.text);

      if (_isPendingEnrollment) {
        // pending 상태: enrollments 생성이 아니라 pendingMembers 설정만 업데이트
        final placeProvider = Provider.of<PlaceProvider>(
          context,
          listen: false,
        );
        final placeId = placeProvider.currentPlace?.id;
        if (placeId == null) {
          if (mounted) {
            SnackbarUtil.showError(context, '플레이스를 찾을 수 없습니다.');
          }
          return;
        }

        final memberService = MemberService();
        final success = await memberService.updatePendingCourseEnrollmentConfig(
          placeId: placeId,
          phoneNumber: widget.member.phoneNumber,
          courseId: widget.course.id,
          totalReservations: remaining, // pending에서는 총 횟수로 취급
          validFrom: widget.enrollment.validFrom,
          validUntil: widget.enrollment.validUntil,
        );

        if (!success) {
          throw Exception('pendingMembers 업데이트 실패');
        }

        // 저장 성공 후 변경사항 추적 기준 업데이트
        setState(() {
          _originalRemainingReservations = remaining;
        });

        if (mounted) {
          SnackbarUtil.showSuccess(context, '대기 등록 정보가 변경되었습니다.');
        }
      } else {
        // ✅ remainingReservations 변경 시 totalReservations도 함께 업데이트
        // remainingReservations가 totalReservations보다 크면 totalReservations도 증가
        final currentTotal = widget.enrollment.totalReservations;
        final newTotal = remaining > currentTotal ? remaining : currentTotal;

        // ⚠️ 엣지 케이스: 횟수를 0으로 줄이면 연장 요청이 의미 없어짐
        // pending 연장 요청을 자동으로 거부
        CourseEnrollment updatedEnrollment = widget.enrollment.copyWith(
          remainingReservations: remaining,
          totalReservations: newTotal,
        );

        // 연장 요청 상태 업데이트 정보 준비 (횟수가 0이 되고 연장 요청이 있는 경우)
        ExtensionRequestUpdate? extensionRequestUpdate;
        if (remaining == 0 && widget.enrollment.hasPendingExtensionRequest) {
          final pendingRequest = widget.enrollment.extensionRequest;
          if (pendingRequest != null) {
            updatedEnrollment = updatedEnrollment.rejectExtension(
              '횟수가 0이 되어 연장 요청이 자동으로 거부되었습니다.',
            );
            extensionRequestUpdate = ExtensionRequestUpdate(
              requestId: pendingRequest.id,
              status: ExtensionRequestStatus.rejected,
              rejectionReason: '횟수가 0이 되어 연장 요청이 자동으로 거부되었습니다.',
            );
          }
        }

        // ✅ 트랜잭션으로 원자적 저장 (enrollment 업데이트 + 관리자 액션 + 연장 요청 상태 업데이트)
        await enrollmentService.updateEnrollmentWithAdminAction(
          updatedEnrollment: updatedEnrollment,
          adminAction: AdminAction(
            id: 'action_${DateTime.now().millisecondsSinceEpoch}',
            actionType: AdminActionType.adjustCount,
            performedAt: TimezoneUtils.getSeoulDateTime(),
            performedBy: 'admin', // TODO: 실제 admin ID로 변경
            details:
                newTotal != currentTotal
                    ? '남은 횟수를 $_originalRemainingReservations회에서 ${remaining}회로 조정 (총 횟수: ${currentTotal}회 → ${newTotal}회)'
                    : '남은 횟수를 $_originalRemainingReservations회에서 ${remaining}회로 조정',
            oldValue: {
              'remainingReservations': _originalRemainingReservations,
              'totalReservations': currentTotal,
            },
            newValue: {
              'remainingReservations': remaining,
              'totalReservations': newTotal,
            },
          ),
          extensionRequestUpdate: extensionRequestUpdate,
        );

        // 저장 성공 후 변경사항 추적 기준 업데이트
        setState(() {
          _originalRemainingReservations = remaining;
        });

        final placeProvider = Provider.of<PlaceProvider>(
          context,
          listen: false,
        );
        final placeId = placeProvider.currentPlace?.id;
        if (placeId != null) {
          final memberProvider = Provider.of<MemberProvider>(
            context,
            listen: false,
          );
          await memberProvider.loadMembers(placeId);
        }

        if (mounted) {
          SnackbarUtil.showSuccess(context, '남은 횟수가 변경되었습니다.');
        }
      }
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showError(context, '저장 중 오류가 발생했습니다: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  // 탭 2: 기간 연장 저장
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

  // 최소 종료일 가져오기 (기간 연장 기준 종료일)
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
      SnackbarUtil.showError(context, '변경사항이 없습니다.');
      return;
    }

    // 클라이언트 검증: 종료일이 유효 범위 내에 있는지 확인
    if (!_isValidUntilInRange(_extendedValidUntil)) {
      SnackbarUtil.showError(context, '종료일은 오늘 날짜 이후로만 선택할 수 있습니다.');
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final enrollmentService = EnrollmentService();

      if (_isPendingEnrollment) {
        // pending 상태: enrollments 생성이 아니라 pendingMembers 설정만 업데이트
        final placeProvider = Provider.of<PlaceProvider>(
          context,
          listen: false,
        );
        final placeId = placeProvider.currentPlace?.id;
        if (placeId == null) {
          if (mounted) {
            SnackbarUtil.showError(context, '플레이스를 찾을 수 없습니다.');
          }
          return;
        }

        final memberService = MemberService();
        final success = await memberService.updatePendingCourseEnrollmentConfig(
          placeId: placeId,
          phoneNumber: widget.member.phoneNumber,
          courseId: widget.course.id,
          // validFrom은 유지, validUntil만 변경
          validFrom: widget.enrollment.validFrom,
          validUntil: _extendedValidUntil,
        );

        if (!success) {
          throw Exception('pendingMembers 업데이트 실패');
        }

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

        if (mounted) {
          SnackbarUtil.showSuccess(context, '대기 등록 정보가 변경되었습니다.');
        }
      } else {
        // ⚠️ 엣지 케이스: 기간 연장을 직접 저장하면 연장 요청과 중복됨
        // pending 연장 요청이 있으면 자동으로 승인 처리
        CourseEnrollment updatedEnrollment = widget.enrollment.copyWith(
          validUntil: _extendedValidUntil,
        );

        // 연장 요청이 있으면 자동으로 승인
        final pendingRequest =
            widget.enrollment.hasPendingExtensionRequest
                ? widget.enrollment.extensionRequest
                : null;
        ExtensionRequestUpdate? extensionRequestUpdate;
        if (pendingRequest != null) {
          updatedEnrollment = updatedEnrollment.approveExtension(
            _extendedValidUntil,
          );
          extensionRequestUpdate = ExtensionRequestUpdate(
            requestId: pendingRequest.id,
            status: ExtensionRequestStatus.approved,
          );
        }

        // ✅ 트랜잭션으로 원자적 저장 (enrollment 업데이트 + 관리자 액션 + 연장 요청 상태 업데이트)
        await enrollmentService.updateEnrollmentWithAdminAction(
          updatedEnrollment: updatedEnrollment,
          adminAction: AdminAction(
            id: 'action_${DateTime.now().millisecondsSinceEpoch}',
            actionType: AdminActionType.extendPeriod,
            performedAt: TimezoneUtils.getSeoulDateTime(),
            performedBy: 'admin', // TODO: 실제 admin ID로 변경
            details:
                pendingRequest != null
                    ? '유효기간을 ${TimezoneUtils.formatDateToSeoul(_originalValidUntil)}에서 ${TimezoneUtils.formatDateToSeoul(_extendedValidUntil)}로 연장 (연장 요청 자동 승인)'
                    : '유효기간을 ${TimezoneUtils.formatDateToSeoul(_originalValidUntil)}에서 ${TimezoneUtils.formatDateToSeoul(_extendedValidUntil)}로 연장',
            oldValue: {'validUntil': _originalValidUntil.toIso8601String()},
            newValue: {'validUntil': _extendedValidUntil.toIso8601String()},
          ),
          extensionRequestUpdate: extensionRequestUpdate,
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

        final placeProvider = Provider.of<PlaceProvider>(
          context,
          listen: false,
        );
        final placeId = placeProvider.currentPlace?.id;
        if (placeId != null) {
          final memberProvider = Provider.of<MemberProvider>(
            context,
            listen: false,
          );
          await memberProvider.loadMembers(placeId);
        }

        if (mounted) {
          SnackbarUtil.showSuccess(context, '유효기간이 연장되었습니다.');
        }
      }
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showError(context, '저장 중 오류가 발생했습니다: $e');
      }
    } finally {
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
      SnackbarUtil.showError(context, '재등록은 잔여 횟수가 0이거나 유효기간이 만료된 경우에만 가능합니다.');
      return;
    }
    if (!_isReEnrollValid()) {
      SnackbarUtil.showError(context, '입력값을 확인해주세요.');
      return;
    }

    // 재등록 확인 다이얼로그
    final confirmed = await CommonDialog.show(
      context: context,
      title: '재등록',
      message: '정말 재등록하시겠습니까?',
      cancelText: '취소',
      confirmText: '확인',
      confirmButtonColor: AppColors.primaryGreen,
    );

    if (confirmed != true) return;

    setState(() {
      _isReenrolling = true;
    });

    try {
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
        final placeProvider = Provider.of<PlaceProvider>(
          context,
          listen: false,
        );
        final placeId = placeProvider.currentPlace?.id;
        if (placeId == null) {
          throw Exception('플레이스를 찾을 수 없습니다.');
        }

        final memberService = MemberService();
        final success = await memberService.updatePendingCourseEnrollmentConfig(
          placeId: placeId,
          phoneNumber: widget.member.phoneNumber,
          courseId: widget.course.id,
          totalReservations: totalReservations,
          validFrom: _reEnrollValidFrom,
          validUntil: _reEnrollValidUntil,
        );

        if (!success) {
          throw Exception('pendingMembers 업데이트 실패');
        }

        // MemberProvider 새로고침
        final memberProvider = Provider.of<MemberProvider>(
          context,
          listen: false,
        );
        await memberProvider.loadMembers(placeId);

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
        );

        if (!success) {
          throw Exception('코스 등록에 실패했습니다.');
        }

        // 일반 멤버인 경우에만 관리자 액션 추가 (pending 멤버는 pendingMembers만 업데이트됨)
        if (!_isPendingEnrollment &&
            widget.member.userId.isNotEmpty &&
            !widget.member.userId.startsWith('pending_')) {
          final enrollmentId =
              '${widget.member.userId}_${placeId}_${widget.course.id}';
          try {
            await enrollmentService.addAdminAction(
              enrollmentId: enrollmentId,
              action: AdminAction(
                id: 'action_${DateTime.now().millisecondsSinceEpoch}',
                actionType: AdminActionType.reenroll,
                performedAt: now,
                performedBy: 'admin', // TODO: 실제 admin ID로 변경
                details: '재등록 처리 완료',
              ),
            );
          } catch (e) {
            // 관리자 액션 추가 실패는 무시 (등록은 성공했으므로)
            debugPrint('⚠️ 관리자 액션 추가 실패 (무시): $e');
          }
        }

        // pendingMembers에서 해당 코스 제거 (일반 멤버가 pendingMembers에 있을 수 있음)
        await memberService.removeCourseFromPendingMembers(
          placeId: placeId,
          phoneNumber: widget.member.phoneNumber,
          courseId: widget.course.id,
        );

        final memberProvider = Provider.of<MemberProvider>(
          context,
          listen: false,
        );
        await memberProvider.loadMembers(placeId);

        // 재등록 후에는 enrollment 상태가 크게 변경되므로 화면을 닫음
        if (mounted) {
          SnackbarUtil.showSuccess(context, '코스가 등록되었습니다.');
          Navigator.of(context).pop(true);
        }
      } else {
        // 기존 enrollment 재등록
        // 기존 등록 정보를 히스토리에 추가
        final currentHistory = List<ReenrollmentRecord>.from(
          widget.enrollment.reenrollmentHistory,
        );
        currentHistory.add(
          ReenrollmentRecord(
            enrollmentNumber: widget.enrollment.totalEnrollmentCount,
            totalReservations: widget.enrollment.totalReservations,
            enrolledAt: widget.enrollment.enrolledAt,
            validFrom: widget.enrollment.validFrom,
            validUntil: widget.enrollment.validUntil,
          ),
        );

        // ⚠️ 엣지 케이스: 재등록 시 기존 연장 요청은 의미 없어짐
        // pending 연장 요청을 자동으로 거부
        CourseEnrollment updatedEnrollment = widget.enrollment.copyWith(
          totalEnrollmentCount: widget.enrollment.totalEnrollmentCount + 1,
          enrolledAt: now, // 재등록일로 업데이트
          totalReservations: totalReservations,
          remainingReservations: totalReservations,
          validFrom: _reEnrollValidFrom,
          validUntil: _reEnrollValidUntil,
        );

        // 재등록 시 기존 연장 요청 자동 거부
        final pendingRequest =
            widget.enrollment.hasPendingExtensionRequest
                ? widget.enrollment.extensionRequest
                : null;
        ExtensionRequestUpdate? extensionRequestUpdate;
        if (pendingRequest != null) {
          updatedEnrollment = updatedEnrollment.rejectExtension(
            '재등록으로 인해 연장 요청이 자동으로 거부되었습니다.',
          );
          extensionRequestUpdate = ExtensionRequestUpdate(
            requestId: pendingRequest.id,
            status: ExtensionRequestStatus.rejected,
            rejectionReason: '재등록으로 인해 연장 요청이 자동으로 거부되었습니다.',
          );
        }

        // ✅ Provider를 통해 재등록 처리 (화면을 나가도 진행 상태 유지)
        // ⚠️ 중요: reenrollWithHistory 트랜잭션 내에서 연장 요청 상태도 함께 업데이트 (원자적 처리)
        await enrollmentProvider.reenrollEnrollment(
          enrollmentId: enrollmentId,
          reenrollAction: () async {
            await enrollmentService.reenrollWithHistory(
              updatedEnrollment: updatedEnrollment,
              oldRecord: ReenrollmentRecord(
                enrollmentNumber: widget.enrollment.totalEnrollmentCount,
                totalReservations: widget.enrollment.totalReservations,
                enrolledAt: widget.enrollment.enrolledAt,
                validFrom: widget.enrollment.validFrom,
                validUntil: widget.enrollment.validUntil,
              ),
              newRecord: ReenrollmentRecord(
                enrollmentNumber: widget.enrollment.totalEnrollmentCount + 1,
                totalReservations: totalReservations,
                enrolledAt: now,
                validFrom: _reEnrollValidFrom,
                validUntil: _reEnrollValidUntil,
              ),
              adminAction: AdminAction(
                id: 'action_${DateTime.now().millisecondsSinceEpoch}',
                actionType: AdminActionType.reenroll,
                performedAt: now,
                performedBy: 'admin', // TODO: 실제 admin ID로 변경
                details: '재등록 처리 완료',
              ),
              extensionRequestUpdate: extensionRequestUpdate,
            );
          },
        );

        // 저장 성공 후 변경사항 추적 기준 업데이트
        setState(() {
          _originalReEnrollTotalReservations = totalReservations;
          _originalReEnrollValidFrom = _reEnrollValidFrom;
          _originalReEnrollValidUntil = _reEnrollValidUntil;
        });

        final placeProvider = Provider.of<PlaceProvider>(
          context,
          listen: false,
        );
        final placeId = placeProvider.currentPlace?.id;
        if (placeId != null) {
          final memberProvider = Provider.of<MemberProvider>(
            context,
            listen: false,
          );
          await memberProvider.loadMembers(placeId);
        }

        // 재등록 후에는 enrollment 상태가 크게 변경되므로 화면을 닫음
        if (mounted) {
          SnackbarUtil.showSuccess(context, '재등록이 완료되었습니다.');
          Navigator.of(context).pop(true);
        }
      }
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showError(context, '저장 중 오류가 발생했습니다: $e');
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
      title: '수강 취소',
      message: '정말 수강을 취소하시겠습니까?',
      cancelText: '취소',
      confirmText: '확인',
      confirmButtonColor: Colors.red,
    );

    if (confirmed != true) return;

    setState(() {
      _isCancelling = true;
    });

    try {
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
          debugPrint(
            '[EnrollmentDetailScreen] removeCourseFromPendingMembers 호출: placeId=$placeId, phoneNumber=${widget.member.phoneNumber}, courseId=${widget.course.id}',
          );
          final memberService = MemberService();
          final success = await memberService.removeCourseFromPendingMembers(
            placeId: placeId,
            phoneNumber: widget.member.phoneNumber,
            courseId: widget.course.id,
            keepPendingMember: true, // pending일 때는 코스만 제거하고 멤버는 유지
          );
          debugPrint(
            '[EnrollmentDetailScreen] removeCourseFromPendingMembers 결과: success=$success',
          );
        } else {
          debugPrint('[EnrollmentDetailScreen] placeId가 null입니다.');
        }
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
          final courseName =
              (detailsMap?['courseName'] as String?) ?? widget.course.name;

          final confirmedCascade = await CommonDialog.show(
            context: context,
            title: '수강 취소',
            message:
                '$courseName\n\n수강자의 예약 $reservationCount건이 남아있습니다.\n수강취소 처리하시겠습니까?',
            cancelText: '취소',
            confirmText: '예약 전부 취소 후 수강 취소',
            confirmButtonColor: Colors.red,
          );
          if (confirmedCascade != true) return;

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

      final memberProvider = Provider.of<MemberProvider>(
        context,
        listen: false,
      );
      await memberProvider.loadMembers(placeId);

      if (mounted) {
        SnackbarUtil.showSuccess(context, '수강이 취소되었습니다.');
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showError(context, '취소 중 오류가 발생했습니다: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCancelling = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        scrolledUnderElevation: 0,
        backgroundColor: AppColors.backgroundWhite,
        elevation: 0,
        toolbarHeight: 100,
        centerTitle: false,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios, color: AppColors.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.course.name} · ${widget.member.name}',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              FormatUtils.formatPhoneNumber(widget.member.phoneNumber),
              style: TextStyle(fontSize: 16, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              const SizedBox(height: 10),
              // 탭바
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: DefaultTapbar(
                  labels:
                      (widget.enrollment.remainingReservations > 0 ||
                              widget.enrollment.hasPendingExtensionRequest)
                          ? const ['횟수 조정', '기간 연장', '재등록/취소']
                          : const ['횟수 조정', '재등록/취소'],
                  selectedIndex: _tabController.index,
                  onTabChanged: (index) {
                    _tabController.animateTo(index);
                  },
                ),
              ),
              // 탭 내용 (현재 선택된 탭에 따라 표시)
              AnimatedBuilder(
                animation: _tabController,
                builder: (context, child) {
                  return _buildCurrentTabContent(_tabController.index);
                },
              ),
              const SizedBox(height: 30),
              // 등록 정보
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.start,

                      children: [
                        SizedBox(width: 10),
                        Text(
                          '등록 정보',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Spacer(),
                        TextButton.icon(
                          onPressed: () {
                            setState(() {
                              _isDetailExpanded = !_isDetailExpanded;
                            });
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
                        color: AppColors.backgroundLight.withOpacity(0.7),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        children: [
                          SizedBox(height: 10),
                          _buildInfoRow(
                            '남은 예약 횟수',
                            '${widget.enrollment.remainingReservations}회',
                          ),
                          _buildDivider(),
                          _buildInfoRow(
                            '현재 유효기간',
                            TimezoneUtils.formatDateToSeoul(
                              widget.enrollment.validUntil,
                            ),
                          ),
                          _buildDivider(),
                          _buildInfoRow(
                            '최근 등록일',
                            TimezoneUtils.formatDateToSeoul(
                              widget.enrollment.enrolledAt,
                            ),
                          ),

                          _buildDivider(),
                          _buildInfoRow(
                            '최초 등록일',
                            widget.enrollment.firstEnrolledAt != null
                                ? TimezoneUtils.formatDateToSeoul(
                                  widget.enrollment.firstEnrolledAt!,
                                )
                                : TimezoneUtils.formatDateToSeoul(
                                  widget.enrollment.enrolledAt,
                                ),
                          ),
                          _buildDivider(),

                          _buildInfoRow(
                            '총 등록 횟수',
                            '${widget.enrollment.totalEnrollmentCount}회',
                          ),

                          if (widget.enrollment.memo != null &&
                              widget.enrollment.memo!.isNotEmpty) ...[
                            _buildDivider(),
                            _buildInfoRow('메모', widget.enrollment.memo!),
                          ],
                          // 자세히 보기 펼쳐진 내용
                          if (_isDetailExpanded) ...[
                            _buildDivider(),
                            _buildDetailExpandedContent(),
                          ],
                          SizedBox(height: 10),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 30),
            ],
          ),
        ),
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
    // 남은 횟수가 0이면 기간 연장 탭 제외
    // 단, 연장 요청이 있으면 기간 연장 탭을 표시 (연장 요청 처리 가능하도록)
    final hasRemainingReservations =
        widget.enrollment.remainingReservations > 0;
    final hasPendingExtensionRequest =
        widget.enrollment.hasPendingExtensionRequest;

    if (hasRemainingReservations || hasPendingExtensionRequest) {
      // 기간 연장 탭 포함 (3개 탭)
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
      // 기간 연장 탭 제외 (2개 탭)
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

  // 탭 2: 기간 연장 내용
  Widget _buildPeriodExtensionTabContent() {
    final hasPendingExtensionRequest =
        widget.enrollment.hasPendingExtensionRequest;
    final extensionRequest = widget.enrollment.extensionRequest;

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
                '유효기간 연장',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            // 연장 요청이 있을 때 알림 표시
            if (hasPendingExtensionRequest && extensionRequest != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: AppColors.textLight.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '연장 요청이 있습니다',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: AppColors.primaryGreen,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            extensionRequest.reason,
                            style: TextStyle(
                              fontSize: 14,
                              color: AppColors.textSecondary,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
                  onPressed:
                      (_canReEnroll() &&
                              _isReEnrollValid() &&
                              _hasReEnrollChanges() &&
                              !_isReenrolling &&
                              !_isCancelling)
                          ? _saveReEnrollment
                          : null,
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

  // 자세히 보기 펼쳐진 내용
  Widget _buildDetailExpandedContent() {
    // 서브컬렉션에서 로드한 데이터 사용
    final reenrollmentHistory = _loadedReenrollmentHistory;
    final adminActions = _loadedAdminActions;
    final extensionRequests = _loadedExtensionRequests;

    // 타임라인 아이템을 위한 Map 구조
    // 모든 이벤트를 타임라인 아이템으로 변환
    final List<Map<String, dynamic>> timelineItems = [];

    // 재등록 이력 추가
    for (final record in reenrollmentHistory) {
      timelineItems.add({
        'date': record.enrolledAt,
        'type': 'reenrollment',
        'data': record,
      });
      if (record.cancelledAt != null) {
        timelineItems.add({
          'date': record.cancelledAt!,
          'type': 'reenrollmentCancelled',
          'data': record,
        });
      }
    }

    // 관리자 액션 추가 (기간 연장은 제외 - 연장 요청과 중복되므로)
    for (final action in adminActions) {
      // 기간 연장 액션은 연장 요청과 중복되므로 제외
      if (action.actionType != AdminActionType.extendPeriod) {
        timelineItems.add({
          'date': action.performedAt,
          'type': 'adminAction',
          'data': action,
        });
      }
    }

    // 연장 요청 추가 (요청일만 추가, 결과는 칩으로 표시)
    for (final request in extensionRequests) {
      timelineItems.add({
        'date': request.requestedAt,
        'type': 'extensionRequest',
        'data': request,
      });
    }

    // 시간순으로 정렬 (최신순)
    timelineItems.sort(
      (a, b) => (b['date'] as DateTime).compareTo(a['date'] as DateTime),
    );

    // 사용 가능한 필터 타입 확인
    final availableFilters = <String>{};
    for (final item in timelineItems) {
      final type = item['type'] as String;
      if (type == 'reenrollment' || type == 'reenrollmentCancelled') {
        availableFilters.add('재등록');
      } else if (type == 'extensionRequest') {
        availableFilters.add('연장');
      } else if (type == 'adminAction') {
        final action = item['data'] as AdminAction;
        if (action.actionType == AdminActionType.adjustCount) {
          availableFilters.add('횟수조정');
        } else if (action.actionType == AdminActionType.reenroll) {
          availableFilters.add('재등록');
        } else {
          availableFilters.add('기타');
        }
      }
    }

    // 필터링된 아이템
    List<Map<String, dynamic>> filteredItems = timelineItems;
    if (_selectedTimelineFilter != null) {
      filteredItems =
          timelineItems.where((item) {
            final type = item['type'] as String;
            switch (_selectedTimelineFilter) {
              case '재등록':
                return type == 'reenrollment' ||
                    type == 'reenrollmentCancelled' ||
                    (type == 'adminAction' &&
                        (item['data'] as AdminAction).actionType ==
                            AdminActionType.reenroll);
              case '연장':
                return type == 'extensionRequest';
              case '횟수조정':
                return type == 'adminAction' &&
                    (item['data'] as AdminAction).actionType ==
                        AdminActionType.adjustCount;
              case '기타':
                return type == 'adminAction' &&
                    (item['data'] as AdminAction).actionType !=
                        AdminActionType.adjustCount &&
                    (item['data'] as AdminAction).actionType !=
                        AdminActionType.reenroll;
              default:
                return true;
            }
          }).toList();
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

    // 표시할 아이템 개수 제한
    final totalCount = filteredItems.length;
    final displayItems = filteredItems.take(_timelineDisplayLimit).toList();
    final hasMore = totalCount > _timelineDisplayLimit;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '히스토리',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // 필터 탭바
        if (availableFilters.length > 1) ...[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                // 전체 버튼
                _buildTimelineFilterChip(
                  label: '전체',
                  isSelected: _selectedTimelineFilter == null,
                  onTap: () {
                    setState(() {
                      _selectedTimelineFilter = null;
                    });
                  },
                ),
                const SizedBox(width: 4),
                // 필터 버튼들
                ...availableFilters.map((filter) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: _buildTimelineFilterChip(
                      label: filter,
                      isSelected: _selectedTimelineFilter == filter,
                      onTap: () {
                        setState(() {
                          _selectedTimelineFilter = filter;
                        });
                      },
                    ),
                  );
                }).toList(),
              ],
            ),
          ),
          const SizedBox(height: 22),
        ],
        // 타임라인 아이템들
        _buildTimelineContainer(displayItems, hasMore),
        // 더 보기 버튼
        if (hasMore) ...[
          const SizedBox(height: 12),
          Center(
            child: TextButton(
              onPressed: () {
                setState(() {
                  _timelineDisplayLimit += 20; // 20개씩 더 표시
                });
              },
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
      ],
    );
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
    List<Map<String, dynamic>> items,
    bool hasMore,
  ) {
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // 왼쪽 세로선
        Positioned(
          left: 5,
          top: 0,
          bottom: 0,
          child: Container(width: 2, color: AppColors.borderLight),
        ),
        // 타임라인 아이템들
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

  Widget _buildTimelineItem(Map<String, dynamic> item, bool isLast) {
    final type = item['type'] as String;
    Widget content;

    switch (type) {
      case 'reenrollment':
        final record = item['data'] as ReenrollmentRecord;
        content = _buildReenrollmentTimelineItem(record, false);
        break;
      case 'reenrollmentCancelled':
        final record = item['data'] as ReenrollmentRecord;
        content = _buildReenrollmentTimelineItem(record, true);
        break;
      case 'adminAction':
        final action = item['data'] as AdminAction;
        content = _buildAdminActionTimelineItem(action);
        break;
      default:
        content = const SizedBox.shrink();
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // 컨텐츠
        Padding(
          padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
          child: content,
        ),
        // 왼쪽 점
        Positioned(
          left: -18,
          top: 1,
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: _getTimelineItemColor(item['type'] as String),
              shape: BoxShape.circle,
            ),
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

  Color _getTimelineItemColor(String type) {
    switch (type) {
      case 'reenrollment':
        return const Color.fromARGB(255, 59, 59, 59);
      case 'reenrollmentCancelled':
        return const Color.fromARGB(255, 253, 115, 105);
      case 'adminAction':
        return const Color.fromARGB(255, 59, 59, 59);
      case 'extensionRequest':
        return const Color.fromARGB(255, 248, 180, 116);
      default:
        return AppColors.textSecondary;
    }
  }

  Widget _buildReenrollmentTimelineItem(
    ReenrollmentRecord record,
    bool isCancelled,
  ) {
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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                isCancelled
                    ? '${record.enrollmentNumber}차 등록 취소'
                    : '${record.enrollmentNumber}차 등록',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              if (isCancelled)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '취소됨',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.red,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '일시: ${TimezoneUtils.formatDateToSeoul(isCancelled ? record.cancelledAt! : record.enrolledAt)}',
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
          ),
          if (!isCancelled) ...[
            const SizedBox(height: 4),

            Text(
              '유효기간: ${TimezoneUtils.formatDateToSeoul(record.validFrom)} ~ ${TimezoneUtils.formatDateToSeoul(record.validUntil)}',
              style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAdminActionTimelineItem(AdminAction action) {
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

  String _getActionTypeLabel(AdminActionType type) {
    switch (type) {
      case AdminActionType.adjustCount:
        return '횟수 조정';
      case AdminActionType.extendPeriod:
        return '기간 연장';
      case AdminActionType.reenroll:
        return '재등록';
      case AdminActionType.cancel:
        return '취소';
      case AdminActionType.memoUpdated:
        return '메모 업데이트';
      case AdminActionType.other:
        return '기타';
    }
  }
}
