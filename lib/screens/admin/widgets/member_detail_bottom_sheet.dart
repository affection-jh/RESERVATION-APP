import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../../theme/app_colors.dart';
import '../../../models/course.dart';
import '../../../models/admin_models.dart';
import '../../../models/course_enrollment.dart';
import '../../../models/pending_member.dart';
import '../../../widgets/common_dialog.dart';
import '../../../utils/snackbar_util.dart';
import '../../../utils/text_field_decoration_util.dart';
import '../../../providers/course_provider.dart';
import '../../../providers/place_provider.dart';
import '../../../providers/member_provider.dart';
import '../../../providers/enrollment_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../services/firestore_service.dart';
import '../../../services/member_service.dart';
import '../../../utils/timezone_utils.dart';
import '../../../utils/date_range_picker_util.dart';
import '../../../utils/format_utils.dart';
import 'enrollment_detail_screen.dart';
import 'member_course_enrollment_screen.dart';
import 'dart:async';

class MemberDetailBottomSheet extends StatefulWidget {
  final MemberData member;

  const MemberDetailBottomSheet({super.key, required this.member});

  static void show({
    required BuildContext context,
    required MemberData member,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.7),
      isDismissible: true,
      enableDrag: true,
      useSafeArea: true,
      builder: (context) => MemberDetailBottomSheet(member: member),
    );
  }

  @override
  State<MemberDetailBottomSheet> createState() =>
      _MemberDetailBottomSheetState();
}

class _MemberDetailBottomSheetState extends State<MemberDetailBottomSheet> {
  bool _isLoading = true;
  List<CourseEnrollment> _enrollments = [];
  Set<String> _processedCourseIds = {}; // 재등록 또는 삭제 처리된 코스 ID들
  StreamSubscription<List<CourseEnrollment>>? _enrollmentSubscription;
  List<String> _allPendingCourseIds = []; // pendingMembers에서 가져온 원본 코스 ID들
  List<String> _pendingCourseIds = []; // enrollments에 없는 pending 코스 ID들 (계산된 값)
  PendingMember? _pendingMember; // pendingMember 전체 정보 저장
  bool _enrollmentsLoaded = false;
  bool _pendingMembersLoaded = false;
  TextEditingController? _nameController;
  bool _isEditingName = false;
  EnrollmentProvider? _enrollmentProvider; // dispose에서 안전하게 사용하기 위한 참조
  String? _currentMemberName; // 로컬에서 관리하는 이름 (서버 업데이트 후 즉시 반영)

  @override
  void initState() {
    super.initState();
    _currentMemberName = widget.member.name; // 초기값 설정
    _loadUserData();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // dispose에서 안전하게 사용하기 위해 참조 저장
    _enrollmentProvider = Provider.of<EnrollmentProvider>(
      context,
      listen: false,
    );
  }

  @override
  void dispose() {
    // 저장된 참조 사용 (dispose에서는 context 접근 불가)
    _enrollmentProvider?.removeListener(_onEnrollmentsChanged);
    _enrollmentProvider = null;

    // 기존 subscription도 취소 (혹시 모를 경우 대비)
    _enrollmentSubscription?.cancel();
    _enrollmentSubscription = null;

    _nameController?.dispose();
    super.dispose();
  }

  Future<void> _loadUserData() async {
    try {
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final placeId = placeProvider.currentPlace?.id;
      if (placeId == null) {
        setState(() {
          _isLoading = false;
        });
        return;
      }

      final normalizedPhone = widget.member.phoneNumber.replaceAll(
        RegExp(r'[^\d]'),
        '',
      );

      // userId가 'pending_'로 시작하면 아직 가입하지 않은 사용자
      final isPendingUser = widget.member.userId.startsWith('pending_');

      // EnrollmentProvider 사용 (중복 구독 방지)
      if (!isPendingUser) {
        final enrollmentProvider = Provider.of<EnrollmentProvider>(
          context,
          listen: false,
        );

        // EnrollmentProvider에 구독 요청 (같은 userId/placeId면 재사용)
        await enrollmentProvider.loadUserEnrollments(
          userId: widget.member.userId,
          placeId: placeId,
        );

        // 초기 데이터 로드
        _updateEnrollmentsFromProvider(enrollmentProvider);

        // Provider 변경 감지 구독
        enrollmentProvider.addListener(_onEnrollmentsChanged);
      } else {
        // 아직 가입하지 않은 사용자는 enrollments 없음
        _enrollmentsLoaded = true;
        _isLoading = !(_enrollmentsLoaded && _pendingMembersLoaded);
      }

      // pendingMembers 조회
      await _loadPendingMembers(placeId, normalizedPhone);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _onEnrollmentsChanged() {
    if (!mounted) return;
    // 저장된 참조 사용 (dispose된 위젯에서 Provider.of 호출 방지)
    final enrollmentProvider = _enrollmentProvider;
    if (enrollmentProvider == null) return;
    _updateEnrollmentsFromProvider(enrollmentProvider);
  }

  void _updateEnrollmentsFromProvider(EnrollmentProvider enrollmentProvider) {
    if (!mounted) return;
    setState(() {
      // 서버에서 이미 필터링된 enrollments 사용
      _enrollments = enrollmentProvider.enrollments;

      // enrollments 업데이트 시 pendingCourseIds 재계산
      _updatePendingCourseIds();

      _enrollmentsLoaded = true;
      _isLoading = !(_enrollmentsLoaded && _pendingMembersLoaded);
    });
  }

  /// pendingMembers만 다시 조회 (코스 등록 후 갱신용)
  Future<void> _loadPendingMembers(
    String placeId,
    String normalizedPhone,
  ) async {
    final firestoreService = FirestoreService();
    final pendingId = '${placeId}_$normalizedPhone';
    final pendingRef = firestoreService.firestore
        .collection('pendingMembers')
        .doc(pendingId);

    try {
      final pendingDoc = await pendingRef.get();
      if (!mounted) return;

      PendingMember? foundPendingMember;
      if (pendingDoc.exists) {
        try {
          foundPendingMember = PendingMember.fromJson(
            pendingDoc.data()!..['id'] = pendingDoc.id,
          );
        } catch (e) {
          debugPrint('PendingMember 파싱 오류: $e');
          foundPendingMember = null;
        }
      }

      if (mounted) {
        setState(() {
          // pendingMember 전체 정보 저장
          _pendingMember = foundPendingMember;

          // pendingMembers는 courseIds(legacy) 또는 courseEnrollments(new) 둘 다 올 수 있음.
          // 항상 derivedCourseIds로 표준화해서 사용한다.
          _allPendingCourseIds = foundPendingMember?.derivedCourseIds ?? [];

          // enrollments에 없는 pending 코스만 필터링
          _updatePendingCourseIds();

          _pendingMembersLoaded = true;
          _isLoading = !(_enrollmentsLoaded && _pendingMembersLoaded);
        });
      }
    } catch (e) {
      debugPrint('PendingMember 조회 오류: $e');
      if (mounted) {
        setState(() {
          _allPendingCourseIds = [];
          _pendingCourseIds = [];
          _pendingMembersLoaded = true;
          _isLoading = !(_enrollmentsLoaded && _pendingMembersLoaded);
        });
      }
    }
  }

  /// enrollments에 없는 pending 코스만 필터링하여 _pendingCourseIds 업데이트
  void _updatePendingCourseIds() {
    final enrolledCourseIds = _enrollments.map((e) => e.courseId).toSet();
    _pendingCourseIds =
        _allPendingCourseIds
            .where((courseId) => !enrolledCourseIds.contains(courseId))
            .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
      decoration: const BoxDecoration(color: Colors.transparent),
      child: Stack(
        children: [
          // 배경 탭 시 닫기
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(color: Colors.transparent),
            ),
          ),
          // 바텀시트 컨텐츠 (키보드 올라올 때 시트 전체를 viewInsets만큼 위로 밀어 입력란 가림 방지)
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: GestureDetector(
                onTap: () {},
                child: Container(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.9,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.backgroundWhite,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(20),
                      topRight: Radius.circular(20),
                    ),
                  ),
                  padding: EdgeInsets.only(
                    left: 20,
                    right: 24,
                    top: 24,
                    bottom: 40 + MediaQuery.of(context).padding.bottom,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 헤더
                        Padding(
                          padding: const EdgeInsets.only(left: 4, top: 4),
                          child: _buildHeader(),
                        ),
                        const SizedBox(height: 24),

                        if (_isLoading)
                          const Center(
                            child: Padding(
                              padding: EdgeInsets.all(32.0),
                              child: CircularProgressIndicator(
                                color: AppColors.primaryGreen,
                              ),
                            ),
                          )
                        else ...[
                          // 등록된 코스 목록
                          _buildEnrollmentsSection(),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: 2),
              if (_isEditingName)
                TextField(
                  controller: _nameController,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    isDense: true,
                  ),
                  autofocus: true,
                  maxLines: 1,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _saveName(),
                  scrollPadding: EdgeInsets.zero,
                )
              else
                Text(
                  _currentMemberName ?? widget.member.name,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              Text(
                FormatUtils.formatPhoneNumber(widget.member.phoneNumber),
                style: TextStyle(fontSize: 16, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
        // 작은 동그란 아이콘 버튼들
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 이름 수정 버튼
            _buildSvgIconButton(
              svgPath: 'assets/icons/edit.svg',
              color: AppColors.primaryGreen,
              onTap: _handleEditName,
            ),
            const SizedBox(width: 8),
            // 삭제 버튼
            _buildSvgIconButton(
              svgPath: 'assets/icons/delete.svg',
              color: AppColors.textPrimary,
              onTap: _handleDeleteMember,
            ),
            const SizedBox(width: 8),
            // 닫기 버튼
            _buildIconButton(
              icon: Icons.close,
              color: AppColors.textPrimary,
              onTap: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildIconButton({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 18, color: color),
      ),
    );
  }

  Widget _buildSvgIconButton({
    required String svgPath,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          shape: BoxShape.circle,
        ),
        child: Center(
          child: SvgPicture.asset(
            svgPath,
            width: 20,
            height: 20,
            colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
          ),
        ),
      ),
    );
  }

  void _handleEditName() {
    setState(() {
      _isEditingName = true;
      _nameController = TextEditingController(
        text: _currentMemberName ?? widget.member.name,
      );
    });
  }

  Future<void> _saveName() async {
    final newName = _nameController?.text.trim() ?? '';
    final currentName = _currentMemberName ?? widget.member.name;
    if (newName.isEmpty || newName == currentName) {
      setState(() {
        _isEditingName = false;
        _nameController?.dispose();
        _nameController = null;
      });
      return;
    }

    try {
      // 즉시 로컬 상태 업데이트 (낙관적 업데이트)
      setState(() {
        _currentMemberName = newName;
        _isEditingName = false;
        _nameController?.dispose();
        _nameController = null;
      });

      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final placeId = placeProvider.currentPlace?.id;
      if (placeId == null) return;

      final memberService = MemberService();
      final ok = await memberService.updateMemberName(
        placeId: placeId,
        phoneNumber: widget.member.phoneNumber,
        newName: newName,
      );

      if (!ok) {
        // 실패 시 원래 이름으로 복구
        if (mounted) {
          setState(() {
            _currentMemberName = currentName;
          });
          SnackbarUtil.showError(context, '이름 수정에 실패했습니다.');
        }
        return;
      }

      // MemberProvider 새로고침 (백그라운드)
      final memberProvider = Provider.of<MemberProvider>(
        context,
        listen: false,
      );
      // 비동기로 새로고침 (UI 블로킹 방지)
      memberProvider.loadMembers(placeId, forceRefreshUsers: true).then((_) {
        // MemberProvider에서 업데이트된 member 찾기
        try {
          final updatedMember = memberProvider.members.firstWhere(
            (m) => m.phoneNumber == widget.member.phoneNumber,
          );
          if (mounted && updatedMember.name != _currentMemberName) {
            setState(() {
              _currentMemberName = updatedMember.name;
            });
          }
        } catch (e) {
          // member를 찾을 수 없으면 무시 (이미 로컬 상태 업데이트됨)
          debugPrint('업데이트된 member를 찾을 수 없음: $e');
        }
      });

      SnackbarUtil.showSuccess(context, '이름이 수정되었습니다.');
    } catch (e) {
      // 실패 시 원래 이름으로 복구
      if (mounted) {
        setState(() {
          _currentMemberName = currentName;
        });
        SnackbarUtil.showError(context, '이름 수정 중 오류가 발생했습니다: $e');
      }
    }
  }

  Future<void> _handleDeleteMember() async {
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    final rootContext = rootNavigator.context;

    // 바텀시트 먼저 닫기
    Navigator.of(context).pop();

    // 다이얼로그 띄우기
    final shouldDelete = await CommonDialog.show(
      context: rootContext,
      title: '멤버 삭제',
      message: '이 멤버는 더이상 접속할 수 없어요',
      secondaryMessage: '이 멤버를 플레이스에서 제거할까요?',
      cancelText: '취소',
      confirmText: '삭제',
      confirmButtonColor: Colors.red,
    );

    // 취소 시 바텀시트 다시 열기 (롤백)
    if (shouldDelete != true) {
      MemberDetailBottomSheet.show(context: rootContext, member: widget.member);
      return;
    }

    // 바텀시트를 닫은 후 context 사용을 위해 필요한 데이터 미리 저장
    final placeProvider = Provider.of<PlaceProvider>(
      rootContext,
      listen: false,
    );
    final placeId = placeProvider.currentPlace?.id;
    if (placeId == null) {
      // 바텀시트 다시 열기
      MemberDetailBottomSheet.show(context: rootContext, member: widget.member);
      return;
    }

    final normalizedPhone = widget.member.phoneNumber.replaceAll(
      RegExp(r'[^\d]'),
      '',
    );
    final authProvider = Provider.of<AuthProvider>(rootContext, listen: false);
    final adminUserId = authProvider.currentAdmin?.userId;

    try {
      // ✅ 로딩 오버레이는 제거하고, 멤버 카드에서 "삭제중" 오버레이로 표시한다.
      final memberProvider = Provider.of<MemberProvider>(
        rootContext,
        listen: false,
      );
      await memberProvider.removeMemberFromPlace(
        placeId: placeId,
        userId: widget.member.userId,
        phoneNumber: normalizedPhone,
        adminUserId: adminUserId,
      );

      // users.placeIds는 더 이상 사용하지 않음 (courseMembers 기반으로 조회)

      // 스트림으로 자동 반영되지만, 즉시 갱신이 필요하면 재로드
      await memberProvider.loadMembers(placeId, forceRefreshUsers: true);
    } catch (e) {
      // 에러 발생 시 바텀시트 다시 열기
      MemberDetailBottomSheet.show(context: rootContext, member: widget.member);
    }
  }

  /// 조치가 필요한 코스인지 판단 (재등록, 수강취소, 횟수증가, 유효기간 증가 필요)
  bool _needsAction(CourseEnrollment enrollment) {
    // 이미 처리된 코스는 제외
    if (_processedCourseIds.contains(enrollment.courseId)) {
      return false;
    }

    // 만료됨 (재등록 필요)
    if (enrollment.isExpired) {
      return true;
    }

    // 횟수 소진 (재등록 또는 횟수 증가 필요)
    if (enrollment.remainingReservations == 0) {
      return true;
    }

    // 연장 요청 있음 (유효기간 증가 필요)
    if (enrollment.hasPendingExtensionRequest) {
      return true;
    }

    return false;
  }

  Widget _buildEnrollmentsSection() {
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final allCourses = courseProvider.courses;

    // 만료되었거나 횟수가 0인 enrollments (회색 배경, 앞쪽에 배치)
    final expiredOrEmptyEnrollments =
        _enrollments
            .where(
              (e) =>
                  !_processedCourseIds.contains(e.courseId) &&
                  (e.isExpired || e.remainingReservations == 0),
            )
            .toList();

    // 유효한 enrollments (만료되지 않고 횟수가 남은 것)
    final validEnrollments =
        _enrollments
            .where(
              (e) =>
                  !e.isExpired &&
                  e.remainingReservations > 0 &&
                  !_processedCourseIds.contains(e.courseId),
            )
            .toList();

    // pending 상태인 코스들 (enrollments에 없는 것만)
    final pendingCourses =
        _pendingCourseIds
            .where((courseId) => !_processedCourseIds.contains(courseId))
            .map((courseId) {
              final course = allCourses.firstWhere(
                (c) => c.id == courseId,
                orElse: () => allCourses.first,
              );
              return course;
            })
            .toList();

    final totalCourses =
        expiredOrEmptyEnrollments.length +
        validEnrollments.length +
        pendingCourses.length;

    // 등록된 코스가 없을 때
    if (totalCourses == 0) {
      return _buildEmptyCoursesSection(allCourses);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 코스 그리드
        SizedBox(
          width: double.infinity,
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 1.15,
            ),
            itemCount: totalCourses,
            itemBuilder: (context, index) {
              // 순서: 만료/횟수 0 -> 유효한 enrollments -> pending 코스
              if (index < expiredOrEmptyEnrollments.length) {
                final enrollment = expiredOrEmptyEnrollments[index];
                final course = allCourses.firstWhere(
                  (c) => c.id == enrollment.courseId,
                  orElse: () => allCourses.first,
                );

                return GestureDetector(
                  onTap: () async {
                    // 바텀시트를 먼저 닫고 새로운 화면으로 이동
                    Navigator.of(context).pop();

                    // 재등록이 필요한 경우 재등록 탭으로 이동
                    // 단, 연장 요청이 있으면 기간 연장 탭이 표시되므로 탭 인덱스 계산 필요
                    final hasRemainingReservations =
                        enrollment.remainingReservations > 0;
                    final hasPendingExtensionRequest =
                        enrollment.hasPendingExtensionRequest;
                    final initialTabIndex =
                        hasPendingExtensionRequest
                            ? 1 // 연장 요청이 있으면 기간 연장 탭으로 이동
                            : (hasRemainingReservations
                                ? 2 // 재등록/취소 탭 (기간 연장 탭 포함)
                                : 1); // 재등록/취소 탭 (기간 연장 탭 없음)

                    final result = await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder:
                            (context) => EnrollmentDetailScreen(
                              member: widget.member,
                              enrollment: enrollment,
                              course: course,
                              initialTabIndex: initialTabIndex,
                            ),
                      ),
                    );
                    if (result == true && mounted) {
                      // 새로고침
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
                        await memberProvider.loadMembers(
                          placeId,
                          forceRefreshUsers: true,
                        );
                        setState(() {
                          // 상태 업데이트
                        });
                      }
                    }
                  },
                  child: _buildExpiredOrEmptyCourseCard(course, enrollment),
                );
              } else if (index <
                  expiredOrEmptyEnrollments.length + validEnrollments.length) {
                final enrollmentIndex =
                    index - expiredOrEmptyEnrollments.length;
                final enrollment = validEnrollments[enrollmentIndex];
                final course = allCourses.firstWhere(
                  (c) => c.id == enrollment.courseId,
                  orElse: () => allCourses.first,
                );

                return GestureDetector(
                  onTap: () async {
                    // 바텀시트를 먼저 닫고 새로운 화면으로 이동
                    Navigator.of(context).pop();

                    // 연장 요청이 있는 경우 기간 연장 탭으로 이동
                    // 연장 요청이 있으면 기간 연장 탭이 표시됨 (횟수가 0이어도)
                    final initialTabIndex =
                        enrollment.hasPendingExtensionRequest
                            ? 1 // 기간 연장 탭
                            : null; // 기본값 (횟수 조정 탭)

                    final result = await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder:
                            (context) => EnrollmentDetailScreen(
                              member: widget.member,
                              enrollment: enrollment,
                              course: course,
                              initialTabIndex: initialTabIndex,
                            ),
                      ),
                    );
                    if (result == true && mounted) {
                      // 새로고침
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
                        await memberProvider.loadMembers(
                          placeId,
                          forceRefreshUsers: true,
                        );
                        setState(() {
                          // 상태 업데이트
                        });
                      }
                    }
                  },
                  child: _buildCourseCard(course, enrollment),
                );
              } else {
                final pendingIndex =
                    index -
                    expiredOrEmptyEnrollments.length -
                    validEnrollments.length;
                final course = pendingCourses[pendingIndex];

                return GestureDetector(
                  onTap: () async {
                    // pending 코스의 경우 임시 enrollment 생성
                    final placeProvider = Provider.of<PlaceProvider>(
                      context,
                      listen: false,
                    );
                    final placeId = placeProvider.currentPlace?.id;
                    if (placeId == null) {
                      SnackbarUtil.showError(context, '플레이스를 찾을 수 없습니다.');
                      return;
                    }

                    final now = TimezoneUtils.getSeoulDateTime();

                    // pendingMember의 courseEnrollments에서 해당 코스 정보 찾기
                    Map<String, dynamic>? courseEnrollmentData;
                    if (_pendingMember?.courseEnrollments != null) {
                      courseEnrollmentData = _pendingMember!.courseEnrollments!
                          .firstWhere(
                            (e) => e['courseId'] == course.id,
                            orElse: () => <String, dynamic>{},
                          );
                    }

                    // courseEnrollments에서 정보가 있으면 사용, 없으면 기본값 사용
                    DateTime validFrom;
                    DateTime validUntil;
                    int totalReservations;
                    int remainingReservations;

                    if (courseEnrollmentData != null &&
                        courseEnrollmentData.isNotEmpty) {
                      // courseEnrollments에서 가져온 정보 사용
                      validFrom =
                          courseEnrollmentData['validFrom'] != null
                              ? DateTime.parse(
                                courseEnrollmentData['validFrom'],
                              )
                              : now;
                      validUntil =
                          courseEnrollmentData['validUntil'] != null
                              ? DateTime.parse(
                                courseEnrollmentData['validUntil'],
                              )
                              : now.add(const Duration(days: 365));
                      totalReservations =
                          courseEnrollmentData['totalReservations'] != null
                              ? courseEnrollmentData['totalReservations'] as int
                              : course.defaultTotalReservations;
                      remainingReservations = totalReservations;
                    } else {
                      // 기본값 사용
                      validFrom = now;
                      validUntil = now.add(const Duration(days: 365));
                      totalReservations = course.defaultTotalReservations;
                      remainingReservations = course.defaultTotalReservations;
                    }

                    final tempEnrollment = CourseEnrollment(
                      id: '', // 빈 ID는 새로 생성할 enrollment를 의미
                      userId: widget.member.userId,
                      courseId: course.id,
                      placeId: placeId,
                      enrolledAt: now,
                      validFrom: validFrom,
                      validUntil: validUntil,
                      totalReservations: totalReservations,
                      remainingReservations: remainingReservations,
                    );

                    // 바텀시트를 먼저 닫고 새로운 화면으로 이동
                    Navigator.of(context).pop();

                    final result = await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder:
                            (context) => EnrollmentDetailScreen(
                              member: widget.member,
                              enrollment: tempEnrollment,
                              course: course,
                              isNewEnrollment: true, // 새 enrollment 생성 모드
                            ),
                      ),
                    );
                    // 코스 등록이 성공적으로 완료되면 pendingMembers만 갱신
                    // enrollments는 스트림으로 자동 갱신됨
                    if (result == true && mounted) {
                      final normalizedPhone = widget.member.phoneNumber
                          .replaceAll(RegExp(r'[^\d]'), '');
                      await _loadPendingMembers(placeId, normalizedPhone);
                    }
                  },
                  child: _buildPendingCourseCard(course),
                );
              }
            },
          ),
        ),
      ],
    );
  }

  // 등록된 코스가 없을 때 안내 메시지와 버튼
  Widget _buildEmptyCoursesSection(List<Course> allCourses) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 0),

          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '등록된 코스가 없어요',
                style: TextStyle(
                  fontSize: 16,
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () async {
                    final result = await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder:
                            (context) => MemberCourseEnrollmentScreen(
                              member: widget.member,
                            ),
                      ),
                    );
                    // 코스 등록이 성공적으로 완료되면 pendingMembers만 갱신
                    // enrollments는 스트림으로 자동 갱신됨
                    if (result == true && mounted) {
                      final placeProvider = Provider.of<PlaceProvider>(
                        context,
                        listen: false,
                      );
                      final placeId = placeProvider.currentPlace?.id;
                      if (placeId != null) {
                        final normalizedPhone = widget.member.phoneNumber
                            .replaceAll(RegExp(r'[^\d]'), '');
                        await _loadPendingMembers(placeId, normalizedPhone);
                      }
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryGreen,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    elevation: 0,
                  ),
                  child: Text(
                    '코스 등록 하기',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCourseCard(Course course, CourseEnrollment enrollment) {
    final needsAction = _needsAction(enrollment);

    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          width: double.infinity,
          height: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.textPrimary,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  course.name,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: AppColors.backgroundLight,
                  ),
                  textAlign: TextAlign.left,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '${enrollment.remainingReservations}회 남음',
                  style: TextStyle(
                    fontSize: 24,
                    color: AppColors.backgroundWhite,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        // 빨간 점 표시 (조치 필요 시)
        if (needsAction)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: Colors.red,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }

  // 만료되었거나 횟수가 0인 코스 카드 (회색 배경)
  Widget _buildExpiredOrEmptyCourseCard(
    Course course,
    CourseEnrollment enrollment,
  ) {
    final isExpired = enrollment.isExpired;
    final statusText = isExpired ? '만료됨' : '재등록 필요';
    final needsAction = _needsAction(enrollment);

    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          width: double.infinity,
          height: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.backgroundLight,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  course.name,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                  textAlign: TextAlign.left,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.textSecondary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  statusText,
                  style: TextStyle(
                    fontSize: 14,
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
        // 빨간 점 표시 (조치 필요 시)
        if (needsAction)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: Colors.red,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPendingCourseCard(Course course) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.textSecondary.withOpacity(0.07),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            course.name,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
            textAlign: TextAlign.left,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// 재등록 설정 다이얼로그
class _ReEnrollDialog extends StatefulWidget {
  final Course course;
  final CourseEnrollment currentEnrollment;

  const _ReEnrollDialog({
    required this.course,
    required this.currentEnrollment,
  });

  @override
  State<_ReEnrollDialog> createState() => _ReEnrollDialogState();
}

class _ReEnrollDialogState extends State<_ReEnrollDialog> {
  late TextEditingController _totalReservationsController;
  late DateTime _validFrom;
  late DateTime _validUntil;

  @override
  void initState() {
    super.initState();
    final now = TimezoneUtils.getSeoulDateTime();
    // 기존 값 또는 기본값 사용
    _totalReservationsController = TextEditingController(
      text: widget.currentEnrollment.totalReservations.toString(),
    );
    _validFrom = now;
    _validUntil = now.add(const Duration(days: 365));
  }

  @override
  void dispose() {
    _totalReservationsController.dispose();
    super.dispose();
  }

  bool _isFormValid() {
    final total = int.tryParse(_totalReservationsController.text);
    return total != null && total > 0 && _validUntil.isAfter(_validFrom);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        '재등록 설정',
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: AppColors.textPrimary,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.course.name,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 24),
            // 등록당 수업 횟수
            Text(
              '등록당 수업 횟수',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _totalReservationsController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: TextStyle(
                fontSize: 16,
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
              decoration: TextFieldDecorationUtil.defaultDecoration(
                hintText: '기본값: ${widget.course.defaultTotalReservations}',
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
            // 유효기간
            Text(
              '유효기간',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () async {
                final picked =
                    await DateRangePickerUtil.showCustomDateRangePicker(
                      context: context,
                      initialStartDate: _validFrom,
                      initialEndDate: _validUntil,
                    );
                if (picked != null) {
                  setState(() {
                    _validFrom = picked.start;
                    _validUntil = picked.end;
                  });
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  color: AppColors.backgroundWhite,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.borderLight, width: 1),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${TimezoneUtils.formatDateToSeoul(_validFrom)} ~ ${TimezoneUtils.formatDateToSeoul(_validUntil)}',
                        style: TextStyle(
                          fontSize: 16,
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.calendar_today,
                      size: 18,
                      color: AppColors.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            '취소',
            style: TextStyle(fontSize: 16, color: AppColors.textSecondary),
          ),
        ),
        ElevatedButton(
          onPressed:
              _isFormValid()
                  ? () {
                    final totalReservations = int.parse(
                      _totalReservationsController.text,
                    );
                    Navigator.of(context).pop({
                      'totalReservations': totalReservations,
                      'validFrom': _validFrom,
                      'validUntil': _validUntil,
                    });
                  }
                  : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primaryGreen,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            elevation: 0,
          ),
          child: Text(
            '재등록',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
