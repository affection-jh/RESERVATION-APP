import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../providers/course_provider.dart';
import '../../../providers/member_provider.dart';
import '../../../providers/place_provider.dart';
import '../../../services/firestore_service.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/text_field_decoration_util.dart';
import '../../../utils/timezone_utils.dart';
import '../../../widgets/common_dialog.dart';
import '../../../widgets/valid_period_input_widget.dart';
import '../../../widgets/reservations_input_widget.dart';
import '../../../models/course.dart' as reservation_models;

/// 멤버 등록 모드
enum MemberRegistrationMode {
  list, // 리스트 모드 (추가된 멤버 리스트 표시)
  input, // 입력 모드 (멤버 정보 입력)
}

/// 멤버 등록 화면 (사이드 패널)
class MemberRegistrationScreen extends StatefulWidget {
  /// 저장 완료(DB 반영 포함) 후에만 pop 되도록 반드시 Future를 반환해야 합니다.
  final Future<void> Function(List<Map<String, dynamic>>) onSave;
  final String? initialName;
  final String? initialPhone;
  final List<String>? initialCourseIds;
  final bool isEditMode;
  final String? restrictedCourseId; // 특정 코스만 선택 가능하도록 제한

  const MemberRegistrationScreen({
    super.key,
    required this.onSave,
    this.initialName,
    this.initialPhone,
    this.initialCourseIds,
    this.isEditMode = false,
    this.restrictedCourseId,
  });

  @override
  State<MemberRegistrationScreen> createState() =>
      _MemberRegistrationScreenState();
}

/// 유효기간 단위 타입 (Course 모델의 PeriodType 사용)
typedef PeriodType = reservation_models.PeriodType;

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
    this.periodType = PeriodType.weeks,
    this.periodValue = 1,
    this.validPeriodMode = ValidPeriodMode.period,
  });

  Map<String, dynamic> toJson() {
    return {
      'courseId': courseId,
      'totalReservations': totalReservations,
      'validFrom': validFrom?.toIso8601String(),
      'validUntil': validUntil?.toIso8601String(),
      'periodType': periodType.name,
      'periodValue': periodValue,
    };
  }
}

class _MemberRegistrationScreenState extends State<MemberRegistrationScreen> {
  MemberRegistrationMode _mode = MemberRegistrationMode.input; // 초기 모드는 입력 모드
  final List<Map<String, dynamic>> _memberList = [];
  late TextEditingController _nameCtrl;
  late TextEditingController _phoneCtrl;
  final FocusNode _nameFocusNode = FocusNode();
  final FocusNode _phoneFocusNode = FocusNode();
  final Set<String> _selectedCourseIds = {};
  final Map<String, CourseEnrollmentConfig> _courseConfigs =
      {}; // courseId -> config
  final Map<String, TextEditingController> _periodControllers =
      {}; // courseId_period -> controller
  final Map<String, TextEditingController> _totalReservationsControllers =
      {}; // courseId_total -> controller
  final Map<String, FocusNode> _totalReservationsFocusNodes =
      {}; // courseId_total -> focusNode
  final Map<String, FocusNode> _totalReservationsPinFocusNodes =
      {}; // courseId_total -> pin focusNode
  final Map<String, ValidPeriodMode> _validPeriodModes = {}; // 코스별 모드 관리
  bool _nameHasFocus = false;
  bool _phoneHasFocus = false;
  String? _phoneErrorText;
  String? _courseErrorText;
  bool _isCheckingPhone = false;
  bool _isSaving = false; // 저장 중 상태

  @override
  void initState() {
    super.initState();
    // 편집 모드인 경우 초기값 설정
    _nameCtrl = TextEditingController(text: widget.initialName ?? '');
    _phoneCtrl = TextEditingController(text: widget.initialPhone ?? '');
    if (widget.initialCourseIds != null) {
      _selectedCourseIds.addAll(widget.initialCourseIds!);
    }
    // restrictedCourseId가 있으면 자동 선택 및 설정 초기화
    if (widget.restrictedCourseId != null) {
      _selectedCourseIds.add(widget.restrictedCourseId!);
      // 코스 설정은 build에서 Provider를 통해 초기화
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _initializeRestrictedCourseConfig();
      });
    }

    _nameFocusNode.addListener(() {
      setState(() {
        _nameHasFocus = _nameFocusNode.hasFocus;
      });
    });
    _phoneFocusNode.addListener(() {
      setState(() {
        _phoneHasFocus = _phoneFocusNode.hasFocus;
      });
    });
  }

  // restrictedCourseId가 있을 때 코스 설정 초기화
  void _initializeRestrictedCourseConfig() {
    if (widget.restrictedCourseId == null) return;
    if (!mounted) return;

    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final course = courseProvider.courses.firstWhere(
      (c) => c.id == widget.restrictedCourseId,
      orElse: () => throw Exception('Course not found'),
    );

    final now = TimezoneUtils.getSeoulDateTime();
    final useUniform = course.useUniformSettings;
    final uniformTotal =
        course.uniformTotalReservations ?? course.defaultTotalReservations;
    final uniformPeriodType = course.uniformPeriodType ?? PeriodType.weeks;
    final uniformPeriodValue = course.uniformPeriodValue ?? 1;

    // 유효기간 계산
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

    setState(() {
      _courseConfigs[course.id] = CourseEnrollmentConfig(
        courseId: course.id,
        totalReservations: totalReservations,
        validFrom: now,
        validUntil: useUniform
            ? now.add(duration)
            : now.add(const Duration(days: 7)),
        periodType: useUniform ? uniformPeriodType : PeriodType.weeks,
        periodValue: useUniform ? uniformPeriodValue : 1,
        validPeriodMode: ValidPeriodMode.period,
      );
      _validPeriodModes[course.id] = ValidPeriodMode.period;

      // controller도 업데이트 (이미 존재하는 경우)
      final controllerKey = '${course.id}_total';
      if (_totalReservationsControllers.containsKey(controllerKey)) {
        _totalReservationsControllers[controllerKey]!.text =
            totalReservations == 0 ? '' : totalReservations.toString();
      }
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _nameFocusNode.dispose();
    _phoneFocusNode.dispose();
    // period controllers 정리
    for (final controller in _periodControllers.values) {
      controller.dispose();
    }
    _periodControllers.clear();
    // totalReservations controllers 정리
    for (final controller in _totalReservationsControllers.values) {
      controller.dispose();
    }
    _totalReservationsControllers.clear();
    // totalReservations focus nodes 정리
    for (final focusNode in _totalReservationsFocusNodes.values) {
      focusNode.dispose();
    }
    _totalReservationsFocusNodes.clear();
    // totalReservations pin focus nodes 정리
    for (final focusNode in _totalReservationsPinFocusNodes.values) {
      focusNode.dispose();
    }
    _totalReservationsPinFocusNodes.clear();
    super.dispose();
  }

  void _switchToInputMode() {
    setState(() {
      _mode = MemberRegistrationMode.input;
      if (!widget.isEditMode) {
        _nameCtrl.clear();
        _phoneCtrl.text = '010';
        _selectedCourseIds.clear();
      }
      _courseConfigs.clear();
      _courseErrorText = null;

      // restrictedCourseId가 있으면 코스를 다시 선택하고 설정 초기화
      if (widget.restrictedCourseId != null) {
        _selectedCourseIds.add(widget.restrictedCourseId!);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _initializeRestrictedCourseConfig();
        });
      }
    });
  }

  String _normalizePhone(String phoneNumber) {
    return phoneNumber.replaceAll(RegExp(r'[^\d]'), '');
  }

  bool _isPhoneDuplicateInLocalList(String phoneNumber) {
    final normalizedPhone = _normalizePhone(phoneNumber);
    if (normalizedPhone.length != 11) return false;

    for (final member in _memberList) {
      final memberPhone = _normalizePhone(member['phoneNumber'] as String);
      if (memberPhone == normalizedPhone) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _isPhoneDuplicateInFirebase(String phoneNumber) async {
    final normalizedPhone = _normalizePhone(phoneNumber);
    if (normalizedPhone.length != 11) return false;

    try {
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final memberProvider = Provider.of<MemberProvider>(
        context,
        listen: false,
      );
      final firestoreService = FirestoreService();
      final placeId = placeProvider.currentPlace?.id;

      if (placeId == null) return false;

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

  Future<void> _addMember() async {
    final name = _nameCtrl.text.trim();
    final phoneNumber = _phoneCtrl.text.trim();
    final phoneDigitsOnly = _normalizePhone(phoneNumber);
    final isPhoneValid = phoneDigitsOnly.length == 11;

    // 편집 모드가 아닐 때만 코스 선택 필수 체크
    if (!widget.isEditMode && _selectedCourseIds.isEmpty) {
      setState(() {
        _courseErrorText = '최소 1개 이상의 코스를 선택해주세요.';
      });
      return;
    }

    if (name.isEmpty || phoneNumber.isEmpty || !isPhoneValid) {
      return;
    }

    // 편집 모드가 아닐 때만 중복 체크
    if (!widget.isEditMode) {
      // 로컬 리스트 중복 체크
      if (_isPhoneDuplicateInLocalList(phoneNumber)) {
        setState(() {
          _phoneErrorText = '이미 추가된 전화번호입니다';
        });
        return;
      }

      // Firebase 중복 체크
      setState(() {
        _isCheckingPhone = true;
        _phoneErrorText = null;
      });

      final isDuplicate = await _isPhoneDuplicateInFirebase(phoneNumber);

      if (!mounted) return;

      if (isDuplicate) {
        setState(() {
          _phoneErrorText = '이미 등록된 멤버입니다';
          _isCheckingPhone = false;
        });
        return;
      }
    }

    // 코스별 등록 설정 데이터 생성
    final courseEnrollments = _selectedCourseIds.map((courseId) {
      final config = _courseConfigs[courseId];
      return {
        'courseId': courseId,
        'totalReservations': config?.totalReservations,
        'validFrom': config?.validFrom?.toIso8601String(),
        'validUntil': config?.validUntil?.toIso8601String(),
      };
    }).toList();

    setState(() {
      _memberList.add({
        'name': name,
        'phoneNumber': phoneNumber,
        'courseEnrollments': courseEnrollments, // 새로운 구조
      });
      _nameCtrl.clear();
      _phoneCtrl.text = '010';
      _selectedCourseIds.clear();
      _courseConfigs.clear();
      _phoneErrorText = null;
      _courseErrorText = null;
      _isCheckingPhone = false;
      _mode = MemberRegistrationMode.list; // 추가 후 리스트 모드로 전환
    });
  }

  void _removeMember(int index) {
    setState(() {
      _memberList.removeAt(index);
    });
  }

  Future<void> _checkPhoneInFirebase(String phoneNumber) async {
    if (_isCheckingPhone) return;

    setState(() {
      _isCheckingPhone = true;
      _phoneErrorText = null;
    });

    final isDuplicate = await _isPhoneDuplicateInFirebase(phoneNumber);

    if (!mounted) return;

    if (isDuplicate) {
      setState(() {
        _phoneErrorText = '이미 등록된 멤버입니다';
        _isCheckingPhone = false;
      });
    } else {
      setState(() {
        _phoneErrorText = null;
        _isCheckingPhone = false;
      });
    }
  }

  /// 등록한 멤버가 구독(members/pendingMembers)에 실제로 반영될 때까지 대기
  Future<void> _waitUntilMembersVisibleInList() async {
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final memberProvider = Provider.of<MemberProvider>(context, listen: false);
    final placeId = placeProvider.currentPlace?.id;
    if (placeId == null) return;

    final phonesWeAdded = _memberList
        .map((m) => _normalizePhone(m['phoneNumber'] as String))
        .toSet()
        .toList();
    if (phonesWeAdded.isEmpty) return;

    const maxWait = Duration(seconds: 15);
    const interval = Duration(milliseconds: 300);
    final deadline = DateTime.now().add(maxWait);

    while (DateTime.now().isBefore(deadline)) {
      if (!mounted) return;
      final members = memberProvider.members;
      final pending = memberProvider.pendingMembers;
      final foundPhones = <String>{};
      for (final m in members) {
        foundPhones.add(_normalizePhone(m.phoneNumber));
      }
      for (final p in pending) {
        foundPhones.add(_normalizePhone(p.phoneNumber));
      }
      final allFound = phonesWeAdded.every((phone) => foundPhones.contains(phone));
      if (allFound) return;
      await Future.delayed(interval);
    }
  }

  Future<void> _handleSave() async {
    if (_memberList.isEmpty || _isSaving) return;

    setState(() {
      _isSaving = true;
    });

    try {
      await widget.onSave(_memberList);
      if (!mounted) return;
      // 구독에서 새 멤버가 실제로 감지될 때까지 로딩 유지
      await _waitUntilMembersVisibleInList();
      if (mounted) {
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  /// 입력 내용이 있는지 확인
  bool _hasInput() {
    // 리스트에 멤버가 있으면 입력 내용 있음
    if (_memberList.isNotEmpty) {
      return true;
    }

    // 입력 모드에서 이름이나 전화번호가 입력되었거나 코스가 선택되었으면 입력 내용 있음
    if (_mode == MemberRegistrationMode.input || widget.isEditMode) {
      final name = _nameCtrl.text.trim();
      final phoneNumber = _phoneCtrl.text.trim();
      if (name.isNotEmpty ||
          (phoneNumber.isNotEmpty && phoneNumber != '010') ||
          _selectedCourseIds.isNotEmpty) {
        return true;
      }
    }

    return false;
  }

  Future<bool> _onWillPop() async {
    // 입력 내용이 있으면 확인 다이얼로그 표시
    if (_hasInput()) {
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
    return true;
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
              // 입력 모드일 때
              if (widget.isEditMode || _mode == MemberRegistrationMode.input) {
                // 리스트에 멤버가 있으면 리스트 화면으로 전환
                if (_memberList.isNotEmpty) {
                  setState(() {
                    _mode = MemberRegistrationMode.list;
                  });
                  return;
                }
                // 리스트에 멤버가 없으면 바로 나가기 (확인 다이얼로그 없이)
                if (context.mounted) {
                  Navigator.of(context).pop();
                }
                return;
              }

              // 리스트 모드일 때는 확인 다이얼로그 표시 후 나가기
              final shouldPop = await _onWillPop();
              if (shouldPop && context.mounted) {
                Navigator.of(context).pop();
              }
            },
          ),
          centerTitle: false,
          title: Text(
            widget.isEditMode
                ? '멤버 수정'
                : (_memberList.isEmpty
                      ? '멤버 등록하기'
                      : '${_memberList.length}명 추가됨'),
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          actions: [
            /*
            if (_memberList.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(
                  child: ElevatedButton(
                    onPressed: _handleSave,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.textPrimary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(
                          color: AppColors.primaryGreen,
                          width: 1,
                        ),
                      ),
                      elevation: 0,
                    ),
                    child: Text(
                      '일괄등록',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),*/
          ],
        ),
        body: SafeArea(
          child: (widget.isEditMode || _mode == MemberRegistrationMode.input)
              ? _buildInputMode()
              : _buildListMode(),
        ),
      ),
    );
  }

  /// 리스트 모드 UI
  Widget _buildListMode() {
    return Column(
      children: [
        // 추가된 멤버 리스트
        Expanded(
          child: _memberList.isEmpty
              ? Center(
                  child: Text(
                    '추가된 멤버가 없습니다',
                    style: TextStyle(
                      fontSize: 16,
                      color: AppColors.textSecondary,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 20,
                  ),
                  itemCount: _memberList.length,
                  itemBuilder: (context, index) {
                    final member = _memberList[index];
                    // 새로운 구조: courseEnrollments 우선 사용
                    final courseEnrollments =
                        member['courseEnrollments'] as List<dynamic>?;
                    final courseIds = courseEnrollments != null
                        ? courseEnrollments
                              .map((e) => e['courseId'] as String)
                              .toList()
                        : (member['courseIds'] as Set<String>?)?.toList() ?? [];
                    return Builder(
                      builder: (context) {
                        final courseProvider = Provider.of<CourseProvider>(
                          context,
                          listen: false,
                        );
                        final selectedCourses = courseProvider.courses
                            .where((course) => courseIds.contains(course.id))
                            .toList();

                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: AppColors.backgroundLight,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      member['name'] as String,
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.textPrimary,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      member['phoneNumber'] as String,
                                      style: TextStyle(
                                        fontSize: 16,
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                    if (selectedCourses.isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 6,
                                        children: selectedCourses.map((course) {
                                          return Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 6,
                                            ),
                                            decoration: BoxDecoration(
                                              color: AppColors.backgroundWhite,
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            child: Text(
                                              course.name,
                                              style: TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w500,
                                                color: AppColors.textSecondary,
                                              ),
                                            ),
                                          );
                                        }).toList(),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: Icon(
                                  Icons.close,
                                  size: 20,
                                  color: AppColors.textSecondary,
                                ),
                                onPressed: () => _removeMember(index),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
        ),

        // 하단 버튼 영역 (리스트 모드)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(color: AppColors.backgroundWhite),
          child: Row(
            children: [
              // 멤버 등록 버튼 (더 길게)
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _switchToInputMode,
                  icon: Icon(Icons.add, color: AppColors.primaryGreen),
                  label: Text(
                    '추가 등록',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryGreen,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primaryGreen,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    side: BorderSide(
                      color: AppColors.primaryGreen.withValues(alpha: 0.2),
                      width: 1,
                    ),
                  ),
                ),
              ),

              // 저장 버튼 (멤버가 추가된 경우에만 표시)
              if (_memberList.isNotEmpty) ...[
                const SizedBox(width: 10),
                SizedBox(
                  width: 120,
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
                    ),
                    child: _isSaving
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          )
                        : Text(
                            _memberList.length == 1
                                ? '저장'
                                : '일괄 저장 (${_memberList.length})',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 입력 모드 UI
  Widget _buildInputMode() {
    return Column(
      children: [
        // 입력 폼
        Expanded(
          child: GestureDetector(
            onTap: () {
              // 여백을 누르면 키보드 내리기
              FocusScope.of(context).unfocus();
            },
            behavior: HitTestBehavior.translucent,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 이름 입력
                  TextField(
                    controller: _nameCtrl,
                    focusNode: _nameFocusNode,
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) {
                      _phoneFocusNode.requestFocus();
                    },
                    style: TextStyle(
                      fontSize: 18,
                      color: AppColors.textPrimary,
                    ),
                    decoration: TextFieldDecorationUtil.defaultDecoration(
                      hintText: '이름을 입력하세요',
                      hasFocus: _nameHasFocus,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 전화번호 입력
                  TextField(
                    controller: _phoneCtrl,
                    focusNode: _phoneFocusNode,
                    textInputAction: TextInputAction.done,
                    onChanged: (value) {
                      final digitsOnly = value.replaceAll(RegExp(r'[^\d]'), '');
                      String formatted = digitsOnly;
                      if (formatted.isEmpty) {
                        formatted = '010';
                      }

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

                      // 로컬 리스트 중복 체크
                      final normalizedPhone = _normalizePhone(result);
                      if (normalizedPhone.length == 11) {
                        if (_isPhoneDuplicateInLocalList(result)) {
                          setState(() {
                            _phoneErrorText = '이미 추가된 전화번호입니다';
                          });
                        } else {
                          // Firebase 중복 체크 (비동기)
                          _checkPhoneInFirebase(result);
                        }
                      } else {
                        setState(() {
                          _phoneErrorText = null;
                        });
                      }
                    },
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(13),
                    ],
                    style: TextStyle(
                      fontSize: 18,
                      color: AppColors.textPrimary,
                    ),
                    decoration:
                        TextFieldDecorationUtil.defaultDecoration(
                          hintText: '전화번호를 입력하세요',
                          hasFocus:
                              _phoneHasFocus || _phoneCtrl.text.isNotEmpty,
                          hasError: _phoneErrorText != null,
                        ).copyWith(
                          errorText: _phoneErrorText,
                          labelStyle: _phoneErrorText != null
                              ? TextFieldDecorationUtil.errorLabelStyle()
                              : TextFieldDecorationUtil.defaultLabelStyle(),
                        ),
                  ),
                  const SizedBox(height: 24),

                  // 코스 선택 섹션 (restrictedCourseId가 없을 때만 표시)
                  if (widget.restrictedCourseId == null)
                    Builder(
                      builder: (context) {
                        final courseProvider = Provider.of<CourseProvider>(
                          context,
                          listen: false,
                        );
                        if (courseProvider.courses.isEmpty) {
                          return const SizedBox.shrink();
                        }

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  '코스 선택',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '*',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.red,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: courseProvider.courses.map((course) {
                                final isSelected = _selectedCourseIds.contains(
                                  course.id,
                                );
                                // restrictedCourseId가 있으면 선택/해제 불가 (항상 선택된 상태)
                                final isRestricted =
                                    widget.restrictedCourseId != null &&
                                    course.id == widget.restrictedCourseId;

                                return GestureDetector(
                                  onTap: isRestricted
                                      ? null // 제한된 코스는 탭 불가
                                      : () {
                                          setState(() {
                                            if (isSelected) {
                                              _selectedCourseIds.remove(
                                                course.id,
                                              );
                                              _courseConfigs.remove(course.id);
                                              _validPeriodModes.remove(
                                                course.id,
                                              );
                                            } else {
                                              _selectedCourseIds.add(course.id);
                                              // 일괄 적용 모드 확인
                                              final now =
                                                  TimezoneUtils.getSeoulDateTime();
                                              final useUniform =
                                                  course.useUniformSettings;
                                              final uniformTotal =
                                                  course
                                                      .uniformTotalReservations ??
                                                  course
                                                      .defaultTotalReservations;
                                              final uniformPeriodType =
                                                  course.uniformPeriodType ??
                                                  PeriodType.weeks;
                                              final uniformPeriodValue =
                                                  course.uniformPeriodValue ??
                                                  1;

                                              // 유효기간 계산
                                              final Duration duration;
                                              switch (uniformPeriodType) {
                                                case reservation_models
                                                    .PeriodType
                                                    .weeks:
                                                  duration = Duration(
                                                    days:
                                                        uniformPeriodValue * 7,
                                                  );
                                                  break;
                                                case reservation_models
                                                    .PeriodType
                                                    .days:
                                                  duration = Duration(
                                                    days: uniformPeriodValue,
                                                  );
                                                  break;
                                                case reservation_models
                                                    .PeriodType
                                                    .months:
                                                  duration = Duration(
                                                    days:
                                                        uniformPeriodValue * 30,
                                                  );
                                                  break;
                                              }

                                              _courseConfigs[course
                                                  .id] = CourseEnrollmentConfig(
                                                courseId: course.id,
                                                totalReservations: useUniform
                                                    ? uniformTotal
                                                    : 0,
                                                validFrom: now,
                                                validUntil: useUniform
                                                    ? now.add(duration)
                                                    : now.add(
                                                        const Duration(days: 7),
                                                      ),
                                                periodType: useUniform
                                                    ? uniformPeriodType
                                                    : PeriodType.weeks,
                                                periodValue: useUniform
                                                    ? uniformPeriodValue
                                                    : 1,
                                                validPeriodMode:
                                                    ValidPeriodMode.period,
                                              );
                                              _validPeriodModes[course.id] =
                                                  ValidPeriodMode.period;
                                            }
                                            _courseErrorText = null;
                                          });
                                        },
                                  child: Opacity(
                                    opacity: isRestricted ? 0.6 : 1.0,
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
                                        color: isSelected
                                            ? AppColors.textPrimary
                                            : AppColors.backgroundWhite,
                                        borderRadius: BorderRadius.circular(16),
                                        border: isSelected
                                            ? null
                                            : Border.all(
                                                color: AppColors.borderLight,
                                                width: 1,
                                              ),
                                      ),
                                      child: Text(
                                        course.name,
                                        style: TextStyle(
                                          fontSize: 16,
                                          color: isSelected
                                              ? AppColors.backgroundWhite
                                              : AppColors.textPrimary,
                                        ),
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
                          ],
                        );
                      },
                    ),
                  if (widget.restrictedCourseId == null)
                    const SizedBox(height: 24),
                  // 선택된 코스별 설정 UI (restrictedCourseId가 있어도 표시)
                  if (_selectedCourseIds.isNotEmpty)
                    Builder(
                      builder: (context) {
                        final courseProvider = Provider.of<CourseProvider>(
                          context,
                          listen: false,
                        );
                        return Column(
                          children: [
                            ..._selectedCourseIds.map((courseId) {
                              final course = courseProvider.courses.firstWhere(
                                (c) => c.id == courseId,
                              );
                              return _buildCourseConfigCard(course);
                            }).toList(),
                          ],
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
        ),

        // 하단 버튼 영역 (입력 모드)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
          decoration: BoxDecoration(color: AppColors.backgroundWhite),
          child: Column(
            children: [
              // 추가 버튼
              Builder(
                builder: (context) {
                  final name = _nameCtrl.text.trim();
                  final phoneNumber = _phoneCtrl.text.trim();
                  final phoneDigitsOnly = _normalizePhone(phoneNumber);
                  final isPhoneValid = phoneDigitsOnly.length == 11;
                  final isLocalDuplicate = _isPhoneDuplicateInLocalList(
                    phoneNumber,
                  );

                  // 모든 선택된 코스의 예약 가능 횟수가 0보다 큰지 확인
                  final allReservationsValid = _selectedCourseIds.every((
                    courseId,
                  ) {
                    final config = _courseConfigs[courseId];
                    final reservations = config?.totalReservations ?? 0;
                    return reservations > 0;
                  });

                  // 모든 선택된 코스의 유효기간이 0보다 큰지 확인
                  final allPeriodsValid = _selectedCourseIds.every((courseId) {
                    final config = _courseConfigs[courseId];
                    final periodValue = config?.periodValue ?? 0;
                    return periodValue > 0;
                  });

                  final canAdd =
                      name.isNotEmpty &&
                      phoneNumber.isNotEmpty &&
                      isPhoneValid &&
                      !isLocalDuplicate &&
                      _phoneErrorText == null &&
                      !_isCheckingPhone &&
                      _selectedCourseIds.isNotEmpty && // 코스 선택 필수
                      allReservationsValid && // 모든 코스의 예약 가능 횟수가 0보다 커야 함
                      allPeriodsValid; // 모든 코스의 유효기간이 0보다 커야 함

                  return SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: canAdd ? _addMember : null,
                      icon: Icon(
                        Icons.add,
                        color: canAdd ? Colors.white : AppColors.textSecondary,
                      ),
                      label: Text(
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
                        disabledBackgroundColor: AppColors.textPrimary
                            .withOpacity(0.1),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 코스별 설정 카드
  Widget _buildCourseConfigCard(reservation_models.Course course) {
    // 코스별 totalReservations controller 및 focusNode 관리
    final controllerKey = '${course.id}_total';
    if (!_totalReservationsControllers.containsKey(controllerKey)) {
      final config = _courseConfigs[course.id];
      final initialValue = config?.totalReservations ?? 0;
      _totalReservationsControllers[controllerKey] = TextEditingController(
        text: initialValue.toString(),
      );
      _totalReservationsFocusNodes[controllerKey] = FocusNode()
        ..addListener(() {
          setState(() {}); // 포커스 상태 변경 시 UI 업데이트
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
        border: Border.all(
          color: AppColors.borderLight.withOpacity(0.5),
          width: 1,
        ),
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
  Widget _buildValidPeriodField(reservation_models.Course course) {
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
          _courseConfigs[course.id]?.periodValue = type == PeriodType.days
              ? 7
              : 1;
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
