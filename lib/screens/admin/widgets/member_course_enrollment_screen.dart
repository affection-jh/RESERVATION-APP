import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../providers/course_provider.dart';
import '../../../providers/member_provider.dart';
import '../../../providers/place_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../services/member_service.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/timezone_utils.dart';
import '../../../utils/snackbar_util.dart';
import '../../../utils/format_utils.dart';
import '../../../widgets/common_dialog.dart';
import '../../../widgets/valid_period_input_widget.dart';
import '../../../widgets/reservations_input_widget.dart';
import '../../../models/course.dart' as course_models;
import '../../../models/member_view.dart';

/// 유효기간 단위 타입 (Course 모델의 PeriodType 사용)
typedef PeriodType = course_models.PeriodType;

/// 코스별 등록 설정 데이터
class CourseEnrollmentConfig {
  final String courseId;
  int? totalReservations; // null이면 course.defaultTotalReservations 사용
  DateTime? validFrom; // null이면 현재 시간
  DateTime? validUntil; // null이면 계산된 값
  PeriodType periodType; // 주/일/달 단위
  int periodValue; // 주/일/달 값
  ValidPeriodMode validPeriodMode; // 유효기간 설정 모드

  CourseEnrollmentConfig({
    required this.courseId,
    this.totalReservations,
    this.validFrom,
    this.validUntil,
    this.periodType = course_models.PeriodType.weeks,
    this.periodValue = 1,
    this.validPeriodMode = ValidPeriodMode.period,
  });
}

/// 멤버 코스 등록 화면
class MemberCourseEnrollmentScreen extends StatefulWidget {
  final MemberView member;

  /// 이미 등록된(또는 초대된) 코스 ID 목록. 이 코스들은 목록에서 숨김.
  final List<String>? excludeCourseIds;

  const MemberCourseEnrollmentScreen({
    super.key,
    required this.member,
    this.excludeCourseIds,
  });

  @override
  State<MemberCourseEnrollmentScreen> createState() =>
      _MemberCourseEnrollmentScreenState();
}

class _MemberCourseEnrollmentScreenState
    extends State<MemberCourseEnrollmentScreen> {
  final Set<String> _selectedCourseIds = {};
  final Map<String, CourseEnrollmentConfig> _courseConfigs = {};
  final Map<String, TextEditingController> _periodControllers = {};
  final Map<String, TextEditingController> _totalReservationsControllers = {};
  final Map<String, FocusNode> _totalReservationsFocusNodes = {};
  final Map<String, FocusNode> _totalReservationsPinFocusNodes = {};
  final Map<String, ValidPeriodMode> _validPeriodModes = {}; // 코스별 모드 관리
  String? _courseErrorText;
  bool _isSaving = false;
  bool _leaveRequested = false;

  @override
  void dispose() {
    for (var controller in _periodControllers.values) {
      controller.dispose();
    }
    for (var controller in _totalReservationsControllers.values) {
      controller.dispose();
    }
    for (var focusNode in _totalReservationsFocusNodes.values) {
      focusNode.dispose();
    }
    for (var focusNode in _totalReservationsPinFocusNodes.values) {
      focusNode.dispose();
    }
    super.dispose();
  }

  /// 유효성 검사
  bool _isValid() {
    if (_selectedCourseIds.isEmpty) {
      return false;
    }

    final now = TimezoneUtils.getSeoulDateTime();

    for (final courseId in _selectedCourseIds) {
      final config = _courseConfigs[courseId];
      if (config == null) return false;

      // 예약 가능 횟수 검사 (0이면 유효하지 않음)
      if (config.totalReservations == null || config.totalReservations! <= 0) {
        return false;
      }

      // 유효기간 값 검사
      if (config.periodValue < 0) {
        return false;
      }

      // 유효기간 날짜 검사
      final validFrom = config.validFrom ?? now;
      final validUntil = config.validUntil;
      if (validUntil == null || validUntil.isBefore(validFrom)) {
        return false;
      }
    }

    return true;
  }

  /// 확인 다이얼로그 표시
  Future<void> _showConfirmationDialog() async {
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final now = TimezoneUtils.getSeoulDateTime();

    // 다이얼로그에 표시할 정보 구성
    final List<String> courseInfoList = [];
    for (final courseId in _selectedCourseIds) {
      final config = _courseConfigs[courseId];
      if (config == null) continue;

      final course = courseProvider.courses.firstWhere(
        (c) => c.id == courseId,
        orElse: () => courseProvider.courses.first,
      );

      final totalReservations =
          config.totalReservations ?? course.defaultTotalReservations;
      final validFrom = config.validFrom ?? now;
      final validUntil =
          config.validUntil ?? now.add(const Duration(days: 365));

      final validFromText =
          '${validFrom.year}.${validFrom.month.toString().padLeft(2, '0')}.${validFrom.day.toString().padLeft(2, '0')}';
      final validUntilText =
          '${validUntil.year}.${validUntil.month.toString().padLeft(2, '0')}.${validUntil.day.toString().padLeft(2, '0')}';

      courseInfoList.add(
        '${course.name} ${totalReservations}회\n($validFromText ~ $validUntilText)',
      );
    }

    final message = courseInfoList.join('\n\n━━━━━━━━━━\n\n');

    final confirmed = await CommonDialog.show(
      context: context,
      title: '등록 정보 확인',
      message: message,
      secondaryMessage: '위 정보로 등록하시겠습니까?',
      confirmText: '등록',
      cancelText: '취소',
      confirmButtonColor: AppColors.primaryGreen,
    );

    if (confirmed == true) {
      await _processEnrollment();
    }
  }

  /// 실제 등록 처리
  Future<void> _processEnrollment() async {
    setState(() {
      _isSaving = true;
      _courseErrorText = null;
    });
    if (_leaveRequested) return;

    try {
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final placeId = placeProvider.currentPlace?.id;
      if (placeId == null) {
        if (mounted) {
          SnackbarUtil.showInfo(context, '플레이스를 찾을 수 없습니다.');
        }
        return;
      }

      final courseProvider = Provider.of<CourseProvider>(
        context,
        listen: false,
      );

      // courseEnrollments 데이터 준비
      final now = TimezoneUtils.getSeoulDateTime();
      final courseEnrollments =
          _selectedCourseIds
              .map((courseId) {
                final config = _courseConfigs[courseId];
                if (config == null) return null;

                return {
                  'courseId': courseId,
                  'totalReservations': config.totalReservations,
                  'validFrom': (config.validFrom ?? now).toIso8601String(),
                  'validUntil':
                      (config.validUntil ?? now.add(const Duration(days: 365)))
                          .toIso8601String(),
                };
              })
              .where((e) => e != null)
              .cast<Map<String, dynamic>>()
              .toList();

      // ⚠️ 중앙 로직: pending/일반 멤버 자동 분기 처리
      final memberService = MemberService();
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final adminId = authProvider.currentUser?.userId;

      final success = await memberService.enrollMemberToCourseOrUpdatePending(
        userId: widget.member.userId,
        placeId: placeId,
        phoneNumber: widget.member.phoneNumber,
        courseEnrollments: courseEnrollments,
        courses: courseProvider.courses,
        adminId: adminId,
        adminDisplayName: widget.member.adminDisplayName,
      );
      if (_leaveRequested) return;

      if (!success) {
        throw Exception('코스 등록에 실패했습니다.');
      }

      // MemberProvider 새로고침
      final memberProvider = Provider.of<MemberProvider>(
        context,
        listen: false,
      );
      memberProvider.setPlaceId(placeId);

      if (mounted) {
        SnackbarUtil.showSuccess(
          context,
          '${_selectedCourseIds.length}개의 코스가 등록되었습니다.',
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showInfoFromError(
          context,
          e,
          fallback: '코스 등록 중 오류가 발생했습니다.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _handleSave() async {
    if (_selectedCourseIds.isEmpty) {
      SnackbarUtil.showInfo(context, '코스를 먼저 선택해주세요.');
      return;
    }
    if (!_isValid()) {
      setState(() {
        _courseErrorText = '모든 설정을 올바르게 입력해주세요.';
      });
      return;
    }

    await _showConfirmationDialog();
  }

  /// 입력 내용이 있는지 확인
  bool _hasInput() {
    return _selectedCourseIds.isNotEmpty;
  }

  /// 뒤로가기 확인 다이얼로그
  Future<bool> _onWillPop() async {
    if (_isSaving) return _handleBackDuringSave();
    if (!_hasInput()) {
      return true;
    }

    final confirmed = await CommonDialog.show(
      context: context,
      title: '나가시겠습니까?',
      message: '입력한 내용이 저장되지 않습니다.',
      confirmText: '나가기',
      cancelText: '취소',
    );

    return confirmed == true;
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
      onPopInvoked: (didPop) async {
        if (!didPop) {
          final shouldPop = await _onWillPop();
          if (shouldPop && mounted) {
            Navigator.of(context).pop();
          }
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.backgroundLight,
        appBar: AppBar(
          backgroundColor: AppColors.backgroundLight,
          elevation: 0,
          toolbarHeight: 100,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_ios, color: AppColors.textPrimary),
            onPressed: () async {
              final shouldPop = await _onWillPop();
              if (shouldPop && mounted) {
                Navigator.of(context).pop();
              }
            },
          ),
          flexibleSpace: SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(
                left: 56,
                right: 16,
                top: 16,
                bottom: 16,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.member.name,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),

                  Text(
                    FormatUtils.formatPhoneNumber(widget.member.phoneNumber),
                    style: TextStyle(
                      fontSize: 16,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        body: SafeArea(
          child: Consumer3<CourseProvider, PlaceProvider, AuthProvider>(
            builder: (context, courseProvider, placeProvider, authProvider, _) {
              final placeId = placeProvider.currentPlace?.id;
              final isSubManager =
                  placeId != null && authProvider.isSubManagerForPlace(placeId);
              final placeMember =
                  placeId != null
                      ? authProvider.getPlaceMemberForPlace(placeId)
                      : null;
              final allCourses =
                  isSubManager && placeMember != null
                      ? courseProvider.courses
                          .where(
                            (c) =>
                                placeMember.manageableCourseIds.contains(c.id),
                          )
                          .toList()
                      : courseProvider.courses;
              final excludeSet =
                  widget.excludeCourseIds != null &&
                          widget.excludeCourseIds!.isNotEmpty
                      ? Set<String>.from(widget.excludeCourseIds!)
                      : null;
              final displayCourses =
                  excludeSet != null
                      ? allCourses
                          .where((c) => !excludeSet.contains(c.id))
                          .toList()
                      : allCourses;

              return Column(
                children: [
                  // 코스 선택 및 설정
                  Expanded(
                    child: GestureDetector(
                      onTap: () => FocusScope.of(context).unfocus(),
                      behavior: HitTestBehavior.translucent,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 코스 선택
                            Row(
                              children: [
                                Text(
                                  '등록 처리할 코스를 선택해주세요.',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '*',
                                  style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.red,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            if (displayCourses.isEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 24,
                                  horizontal: 0,
                                ),
                                child: Text(
                                  '추가 등록할 코스가 없어요.\n이미 모든 코스에 등록되어 있습니다.',
                                  style: TextStyle(
                                    fontSize: 15,
                                    color: AppColors.textSecondary,
                                    height: 1.4,
                                  ),
                                  textAlign: TextAlign.start,
                                ),
                              )
                            else
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children:
                                    displayCourses.map((course) {
                                      final isSelected = _selectedCourseIds
                                          .contains(course.id);
                                      return GestureDetector(
                                        onTap: () {
                                          setState(() {
                                            if (isSelected) {
                                              _selectedCourseIds.remove(
                                                course.id,
                                              );
                                              _courseConfigs.remove(course.id);
                                              _validPeriodModes.remove(
                                                course.id,
                                              );
                                              _periodControllers[course.id]
                                                  ?.dispose();
                                              _periodControllers.remove(
                                                course.id,
                                              );
                                              _totalReservationsControllers['${course.id}_total']
                                                  ?.dispose();
                                              _totalReservationsControllers
                                                  .remove('${course.id}_total');
                                              _totalReservationsFocusNodes['${course.id}_total']
                                                  ?.dispose();
                                              _totalReservationsFocusNodes
                                                  .remove('${course.id}_total');
                                              _totalReservationsPinFocusNodes['${course.id}_total']
                                                  ?.dispose();
                                              _totalReservationsPinFocusNodes
                                                  .remove('${course.id}_total');
                                            } else {
                                              _selectedCourseIds.add(course.id);
                                              // 일괄 적용 모드 확인
                                              final now =
                                                  TimezoneUtils.getSeoulDateTime();
                                              final defaultTotal =
                                                  course
                                                      .defaultTotalReservations;
                                              final defaultPeriodType =
                                                  course.defaultPeriodType ??
                                                  PeriodType.weeks;
                                              final defaultPeriodValue =
                                                  course.defaultPeriodValue ??
                                                  1;

                                              final Duration duration;
                                              switch (defaultPeriodType) {
                                                case PeriodType.weeks:
                                                  duration = Duration(
                                                    days:
                                                        defaultPeriodValue * 7,
                                                  );
                                                  break;
                                                case PeriodType.days:
                                                  duration = Duration(
                                                    days: defaultPeriodValue,
                                                  );
                                                  break;
                                                case PeriodType.months:
                                                  duration = Duration(
                                                    days:
                                                        defaultPeriodValue * 30,
                                                  );
                                                  break;
                                              }

                                              _courseConfigs[course
                                                  .id] = CourseEnrollmentConfig(
                                                courseId: course.id,
                                                totalReservations: defaultTotal,
                                                validFrom: now,
                                                validUntil: now.add(duration),
                                                periodType: defaultPeriodType,
                                                periodValue: defaultPeriodValue,
                                                validPeriodMode:
                                                    ValidPeriodMode.period,
                                              );
                                              _validPeriodModes[course.id] =
                                                  ValidPeriodMode.period;
                                            }
                                            _courseErrorText = null;
                                          });
                                        },
                                        child: AnimatedContainer(
                                          duration: const Duration(
                                            milliseconds: 200,
                                          ),
                                          curve: Curves.easeInOut,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 18,
                                            vertical: 10,
                                          ),
                                          decoration: BoxDecoration(
                                            color:
                                                isSelected
                                                    ? AppColors.textPrimary
                                                    : AppColors.backgroundWhite,
                                            borderRadius: BorderRadius.circular(
                                              16,
                                            ),
                                            border:
                                                isSelected
                                                    ? null
                                                    : Border.all(
                                                      color:
                                                          AppColors.borderLight,
                                                      width: 1,
                                                    ),
                                          ),
                                          child: Text(
                                            course.name,
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w500,
                                              color:
                                                  isSelected
                                                      ? AppColors
                                                          .backgroundWhite
                                                      : AppColors.textPrimary,
                                            ),
                                          ),
                                        ),
                                      );
                                    }).toList(),
                              ),
                            if (_courseErrorText != null) ...[
                              const SizedBox(height: 8),
                              Padding(
                                padding: const EdgeInsets.only(left: 16),
                                child: Text(
                                  _courseErrorText!,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.red,
                                  ),
                                ),
                              ),
                            ],
                            // 선택된 코스별 설정 UI
                            if (_selectedCourseIds.isNotEmpty) ...[
                              const SizedBox(height: 24),
                              ..._selectedCourseIds.map((courseId) {
                                final course = courseProvider.courses
                                    .firstWhere((c) => c.id == courseId);
                                return _buildCourseConfigCard(course);
                              }).toList(),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),

                  // 하단 버튼
                  Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 4,
                      horizontal: 20,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.backgroundLight,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 10,
                          offset: const Offset(0, -2),
                        ),
                      ],
                    ),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _isSaving ? null : _handleSave,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primaryGreen,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                          elevation: 0,
                          disabledBackgroundColor: AppColors.textPrimary
                              .withOpacity(0.1),
                        ),
                        child:
                            _isSaving
                                ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      AppColors.primaryGreen,
                                    ),
                                  ),
                                )
                                : Text(
                                  '등록',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 코스별 설정 카드
  Widget _buildCourseConfigCard(course_models.Course course) {
    // 코스별 totalReservations controller 및 focusNode 관리
    final controllerKey = '${course.id}_total';
    if (!_totalReservationsControllers.containsKey(controllerKey)) {
      final config = _courseConfigs[course.id];
      final initialValue = config?.totalReservations ?? 0;
      _totalReservationsControllers[controllerKey] = TextEditingController(
        text: initialValue.toString(),
      );
      _totalReservationsFocusNodes[controllerKey] =
          FocusNode()..addListener(() {
            setState(() {});
          });
      _totalReservationsPinFocusNodes[controllerKey] = FocusNode();
    }
    final totalReservationsController =
        _totalReservationsControllers[controllerKey]!;

    final config = _courseConfigs[course.id];
    final currentValue = config?.totalReservations ?? 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 코스명
          Text(
            course.name,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 20),

          // 예약 가능 횟수
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 12),
              ReservationsInputWidget(
                controller: totalReservationsController,
                currentValue: currentValue,
                defaultValue: course.defaultTotalReservations,
                enabled: true,
                onChanged: (value) {
                  setState(() {
                    _courseConfigs[course.id]?.totalReservations = value;
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 20),

          // 유효기간
          _buildValidPeriodField(course),
        ],
      ),
    );
  }

  /// 유효기간 설정 위젯 (주/일/달 탭바 또는 날짜 선택)
  Widget _buildValidPeriodField(course_models.Course course) {
    final now = TimezoneUtils.getSeoulDateTime();
    final config =
        _courseConfigs[course.id] ??
        CourseEnrollmentConfig(
          courseId: course.id,
          totalReservations: course.defaultTotalReservations,
          validFrom: now,
          validUntil: now.add(const Duration(days: 7)),
          periodType: PeriodType.weeks,
          periodValue: 1,
          validPeriodMode: ValidPeriodMode.period,
        );

    // 현재 모드 확인 (기본값은 period)
    final currentMode = _validPeriodModes[course.id] ?? ValidPeriodMode.period;

    // validUntil 자동 계산 함수
    void _updateValidUntil() {
      final now = TimezoneUtils.getSeoulDateTime();
      final currentValidFrom = _courseConfigs[course.id]?.validFrom ?? now;
      _courseConfigs[course.id]?.validFrom = currentValidFrom;

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

      _courseConfigs[course.id]?.validUntil = currentValidFrom.add(duration);
    }

    return ValidPeriodInputWidget(
      validFrom: config.validFrom ?? now,
      validUntil: config.validUntil ?? now.add(const Duration(days: 7)),
      periodType: config.periodType,
      periodValue: config.periodValue,
      mode: currentMode,
      enabled: true,
      minValidUntil: now,
      maxPeriodValue: 999,
      minPeriodValue: 0,
      onModeChanged: (mode) {
        setState(() {
          _validPeriodModes[course.id] = mode;
          _courseConfigs[course.id]?.validPeriodMode = mode;
          if (mode == ValidPeriodMode.period) {
            // period 모드로 전환 시 validFrom을 오늘로 리셋
            final currentValidFrom = now;
            _courseConfigs[course.id]?.validFrom = currentValidFrom;
            _updateValidUntil();
          }
        });
      },
      onValidFromChanged: (date) {
        setState(() {
          _courseConfigs[course.id]?.validFrom = date;
          // 종료일이 시작일보다 이전이면 종료일도 조정
          if (config.validUntil != null && config.validUntil!.isBefore(date)) {
            _courseConfigs[course.id]?.validUntil = date.add(
              const Duration(days: 30),
            );
          }
        });
      },
      onValidUntilChanged: (date) {
        setState(() {
          _courseConfigs[course.id]?.validUntil = date;
        });
      },
      onPeriodTypeChanged: (type) {
        setState(() {
          _validPeriodModes[course.id] = ValidPeriodMode.period;
          _courseConfigs[course.id]?.validPeriodMode = ValidPeriodMode.period;
          _courseConfigs[course.id]?.periodType = type;
          _courseConfigs[course.id]?.periodValue =
              type == PeriodType.days ? 7 : 1;
          _updateValidUntil();
        });
      },
      onPeriodValueChanged: (value) {
        setState(() {
          _validPeriodModes[course.id] = ValidPeriodMode.period;
          _courseConfigs[course.id]?.validPeriodMode = ValidPeriodMode.period;
          _courseConfigs[course.id]?.periodValue = value;
          _updateValidUntil();
        });
      },
    );
  }
}
