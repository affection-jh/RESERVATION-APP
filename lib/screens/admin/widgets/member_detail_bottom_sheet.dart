import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
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
import '../../../services/firestore_service.dart';
import '../../../services/enrollment_service.dart';
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
      builder: (context) => MemberDetailBottomSheet(member: member),
    );
  }

  @override
  State<MemberDetailBottomSheet> createState() =>
      _MemberDetailBottomSheetState();
}

class _MemberDetailBottomSheetState extends State<MemberDetailBottomSheet> {
  bool _isLoading = true;
  Set<int> _expandedRequestIndices = {};
  List<CourseEnrollment> _enrollments = [];
  List<CourseEnrollment> _extensionRequests = [];
  Set<String> _processedCourseIds = {}; // 재등록 또는 삭제 처리된 코스 ID들
  StreamSubscription<List<CourseEnrollment>>? _enrollmentSubscription;
  List<String> _allPendingCourseIds = []; // pendingMembers에서 가져온 원본 코스 ID들
  List<String> _pendingCourseIds = []; // enrollments에 없는 pending 코스 ID들 (계산된 값)
  PendingMember? _pendingMember; // pendingMember 전체 정보 저장
  bool _enrollmentsLoaded = false;
  bool _pendingMembersLoaded = false;
  TextEditingController? _nameController;
  bool _isEditingName = false;

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  @override
  void dispose() {
    _enrollmentSubscription?.cancel();
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

      final enrollmentService = EnrollmentService();
      final normalizedPhone = widget.member.phoneNumber.replaceAll(
        RegExp(r'[^\d]'),
        '',
      );

      // userId가 'pending_'로 시작하면 아직 가입하지 않은 사용자
      final isPendingUser = widget.member.userId.startsWith('pending_');

      // 기존 subscription이 있으면 취소 (중복 구독 방지)
      _enrollmentSubscription?.cancel();

      // 실제 enrollments 데이터 가져오기 (이미 가입한 사용자만)
      if (!isPendingUser) {
        _enrollmentSubscription = enrollmentService
            .watchUserEnrollments(
              widget.member.userId,
              placeId: placeId, // 서버 사이드 필터링
            )
            .listen((enrollments) {
              if (mounted) {
                setState(() {
                  // 서버에서 이미 필터링된 enrollments 사용
                  _enrollments = enrollments;

                  // 연장 요청 목록 추출
                  _extensionRequests = _enrollments
                      .where((e) => e.hasPendingExtensionRequest)
                      .toList();

                  // enrollments 업데이트 시 pendingCourseIds 재계산
                  _updatePendingCourseIds();

                  _enrollmentsLoaded = true;
                  _isLoading = !(_enrollmentsLoaded && _pendingMembersLoaded);
                });
              }
            });
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

          // pendingMember가 존재하고 courseIds가 있으면 원본 저장
          if (foundPendingMember != null &&
              foundPendingMember.courseIds != null &&
              foundPendingMember.courseIds!.isNotEmpty) {
            _allPendingCourseIds = foundPendingMember.courseIds!;
          } else {
            _allPendingCourseIds = [];
          }

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
    _pendingCourseIds = _allPendingCourseIds
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
          // 바텀시트 컨텐츠
          Align(
            alignment: Alignment.bottomCenter,
            child: GestureDetector(
              onTap: () {},
              child: Container(
                constraints: BoxConstraints(
                  maxHeight:
                      MediaQuery.of(context).size.height * 0.9 -
                      MediaQuery.of(context).viewInsets.bottom,
                ),
                decoration: BoxDecoration(
                  color: AppColors.backgroundWhite,
                  borderRadius: BorderRadius.circular(30),
                ),
                padding: EdgeInsets.only(
                  left: 20,
                  right: 24,
                  top: 24,
                  bottom: 40 + MediaQuery.of(context).viewInsets.bottom,
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
                            child: CircularProgressIndicator(),
                          ),
                        )
                      else ...[
                        // 연장 요청 섹션
                        if (_extensionRequests.isNotEmpty)
                          _buildExtensionRequestsSection(),
                        if (_extensionRequests.isNotEmpty)
                          const SizedBox(height: 24),

                        // 재등록 필요 알림 (재등록이 필요한 경우)
                        if (_hasExpiredCourses()) _buildReenrollmentAlert(),
                        if (_hasExpiredCourses()) _buildCourseSelectionList(),
                        if (_hasExpiredCourses()) const SizedBox(height: 24),

                        // 등록된 코스 목록
                        _buildEnrollmentsSection(),
                      ],
                    ],
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
                  ),
                  autofocus: true,
                  onSubmitted: (_) => _saveName(),
                )
              else
                Text(
                  widget.member.name,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
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
              color: Colors.red,
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
      _nameController = TextEditingController(text: widget.member.name);
    });
  }

  Future<void> _saveName() async {
    final newName = _nameController?.text.trim() ?? '';
    if (newName.isEmpty || newName == widget.member.name) {
      setState(() {
        _isEditingName = false;
        _nameController?.dispose();
        _nameController = null;
      });
      return;
    }

    try {
      final memberService = MemberService();
      final updatedUser = await memberService.updateMemberName(
        phoneNumber: widget.member.phoneNumber,
        newName: newName,
      );

      if (updatedUser == null) {
        SnackbarUtil.showError(context, '멤버를 찾을 수 없습니다.');
        return;
      }

      // MemberProvider 새로고침
      final memberProvider = Provider.of<MemberProvider>(
        context,
        listen: false,
      );
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final placeId = placeProvider.currentPlace?.id;
      if (placeId != null) {
        await memberProvider.loadMembers(placeId);
      }

      setState(() {
        _isEditingName = false;
        _nameController?.dispose();
        _nameController = null;
      });

      SnackbarUtil.showSuccess(context, '이름이 수정되었습니다.');
    } catch (e) {
      SnackbarUtil.showError(context, '이름 수정 중 오류가 발생했습니다: $e');
    }
  }

  Future<void> _handleDeleteMember() async {
    final shouldDelete = await CommonDialog.show(
      context: context,
      title: '멤버 삭제',
      message: '이 멤버는 더이상 접속할 수 없어요',
      secondaryMessage: '이 사용자를 추방하시겠습니까?',
      cancelText: '취소',
      confirmText: '삭제',
      confirmButtonColor: Colors.red,
    );

    if (shouldDelete != true) return;

    try {
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final placeId = placeProvider.currentPlace?.id;
      if (placeId == null) {
        SnackbarUtil.showError(context, '플레이스를 찾을 수 없습니다.');
        return;
      }

      final firestore = FirestoreService().firestore;
      final normalizedPhone = widget.member.phoneNumber.replaceAll(
        RegExp(r'[^\d]'),
        '',
      );

      // 1. placeMembership 찾기 및 삭제
      final membershipQuery = await firestore
          .collection('placeMemberships')
          .where('userId', isEqualTo: widget.member.userId)
          .where('placeId', isEqualTo: placeId)
          .limit(1)
          .get();

      if (membershipQuery.docs.isNotEmpty) {
        await membershipQuery.docs.first.reference.delete();
      }

      // 2. pendingMembers도 삭제 또는 상태 업데이트
      final pendingId = '${placeId}_$normalizedPhone';
      final pendingRef = firestore.collection('pendingMembers').doc(pendingId);
      final pendingDoc = await pendingRef.get();

      if (pendingDoc.exists) {
        // pendingMembers 삭제 (또는 status를 'rejected'로 업데이트)
        await pendingRef.delete();
      }

      // 3. User의 placeIds에서 제거 (User가 존재하는 경우)
      try {
        final userRef = firestore.collection('users').doc(widget.member.userId);
        final userDoc = await userRef.get();
        if (userDoc.exists) {
          await userRef.update({
            'placeIds': FieldValue.arrayRemove([placeId]),
          });
        }
      } catch (e) {
        // User가 없거나 업데이트 실패해도 계속 진행
        debugPrint('User placeIds 업데이트 실패: $e');
      }

      // MemberProvider 새로고침
      final memberProvider = Provider.of<MemberProvider>(
        context,
        listen: false,
      );
      await memberProvider.loadMembers(placeId);

      if (mounted) {
        Navigator.of(context).pop();
        SnackbarUtil.showSuccess(context, '멤버가 삭제되었습니다.');
      }
    } catch (e) {
      SnackbarUtil.showError(context, '멤버 삭제 중 오류가 발생했습니다: $e');
    }
  }

  bool _hasExpiredCourses() {
    return _enrollments.any(
      (e) => e.isExpired && !_processedCourseIds.contains(e.courseId),
    );
  }

  Widget _buildReenrollmentAlert() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red, size: 20),
            const SizedBox(width: 8),
            Text(
              '재등록처리가 필요해요',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.red,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // 만료된 코스 목록 가져오기 (0회 남은 코스 = 재등록 필요 코스)
  List<CourseEnrollment> _getExpiredCourses() {
    return _enrollments
        .where((e) => e.isExpired && !_processedCourseIds.contains(e.courseId))
        .toList();
  }

  Widget _buildCourseSelectionList() {
    final expiredEnrollments = _getExpiredCourses();
    if (expiredEnrollments.isEmpty) {
      return const SizedBox.shrink();
    }

    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final allCourses = courseProvider.courses;

    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        child: SizedBox(
          height: 250,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
            itemCount: expiredEnrollments.length,
            itemBuilder: (context, index) {
              final enrollment = expiredEnrollments[index];
              final course = allCourses.firstWhere(
                (c) => c.id == enrollment.courseId,
                orElse: () => allCourses.first,
              );

              // 해당 코스에 대한 연장 요청이 있는지 확인
              final hasExtensionRequest = _extensionRequests.any(
                (e) => e.courseId == enrollment.courseId,
              );

              return Container(
                width: 200,
                margin: const EdgeInsets.only(right: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.borderLight),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 20),
                    Text(
                      course.name,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Spacer(),
                    // 코스에서 삭제 버튼
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () =>
                            _handleRemoveFromCourse(enrollment, course),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          side: BorderSide(
                            color: AppColors.textSecondary.withValues(
                              alpha: 0.5,
                            ),
                          ),
                        ),
                        child: Text(
                          '코스에서 삭제',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                    // 연장 요청이 있으면 "연장 승인하기", 없으면 "재등록" 버튼
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          if (hasExtensionRequest) {
                            final extensionEnrollment = _extensionRequests
                                .firstWhere(
                                  (e) => e.courseId == enrollment.courseId,
                                );
                            _showApprovalDialog(extensionEnrollment, course);
                          } else {
                            _showReenrollmentDialog(enrollment, course);
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primaryGreen,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Text(
                          hasExtensionRequest ? '연장 승인하기' : '재등록',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildExtensionRequestsSection() {
    if (_extensionRequests.isEmpty) {
      return const SizedBox.shrink();
    }

    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final allCourses = courseProvider.courses;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '연장 요청',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.primaryGreen,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${_extensionRequests.length}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // 연장 요청 목록
        ..._extensionRequests.asMap().entries.map((entry) {
          final index = entry.key;
          final enrollment = entry.value;
          final course = allCourses.firstWhere(
            (c) => c.id == enrollment.courseId,
            orElse: () => allCourses.first,
          );
          final isExpanded = _expandedRequestIndices.contains(index);
          final extensionRequest = enrollment.extensionRequest!;

          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: AppColors.backgroundLight,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 기본 정보 (항상 표시)
                InkWell(
                  onTap: () {
                    setState(() {
                      if (isExpanded) {
                        _expandedRequestIndices.remove(index);
                      } else {
                        _expandedRequestIndices.add(index);
                      }
                    });
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(height: 2),
                              Text(
                                course.name,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Text(
                                    '${_calculateExtensionDays(enrollment)}일 연장 요청',
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: AppColors.primaryGreen,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        AnimatedRotation(
                          turns: isExpanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 300),
                          child: Icon(
                            Icons.keyboard_arrow_down,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // 확장된 내용
                AnimatedSize(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  child: ClipRect(
                    child: isExpanded
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                child: Divider(
                                  height: 1,
                                  color: AppColors.borderLight.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      extensionRequest.reason,
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: AppColors.textPrimary,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    // 승인/거절 버튼
                                    Row(
                                      children: [
                                        Expanded(
                                          child: ElevatedButton(
                                            onPressed: () {
                                              _showApprovalDialog(
                                                enrollment,
                                                course,
                                              );
                                            },
                                            style: ElevatedButton.styleFrom(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 12,
                                                  ),
                                              backgroundColor:
                                                  AppColors.primaryGreen,
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(14),
                                              ),
                                              elevation: 0,
                                            ),
                                            child: Text(
                                              '승인하기',
                                              style: TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                                color:
                                                    AppColors.backgroundWhite,
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 5),
                                        OutlinedButton(
                                          onPressed: () {
                                            _showRejectionDialog(
                                              enrollment,
                                              course,
                                            );
                                          },
                                          style: OutlinedButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 20,
                                              vertical: 12,
                                            ),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                            ),
                                            side: BorderSide(
                                              color: AppColors.textSecondary,
                                            ),
                                          ),
                                          child: Text(
                                            '거절',
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: AppColors.textSecondary,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ],
    );
  }

  int _calculateExtensionDays(CourseEnrollment enrollment) {
    // 연장 요청이 있으면 기본 30일로 설정 (실제로는 요청에서 가져와야 함)
    return 30;
  }

  Widget _buildEnrollmentsSection() {
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final allCourses = courseProvider.courses;

    // 만료되었거나 횟수가 0인 enrollments (회색 배경, 앞쪽에 배치)
    final expiredOrEmptyEnrollments = _enrollments
        .where(
          (e) =>
              !_processedCourseIds.contains(e.courseId) &&
              (e.isExpired || e.remainingReservations == 0),
        )
        .toList();

    // 유효한 enrollments (만료되지 않고 횟수가 남은 것)
    final validEnrollments = _enrollments
        .where(
          (e) =>
              !e.isExpired &&
              e.remainingReservations > 0 &&
              !_processedCourseIds.contains(e.courseId),
        )
        .toList();

    // pending 상태인 코스들 (enrollments에 없는 것만)
    final pendingCourses = _pendingCourseIds
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
          height: totalCourses > 2 ? 350 : 300,
          child: GridView.builder(
            padding: const EdgeInsets.all(0),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 4,
              mainAxisSpacing: 4,
              childAspectRatio: 1.2,
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

                    final result = await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => EnrollmentDetailScreen(
                          member: widget.member,
                          enrollment: enrollment,
                          course: course,
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
                        await memberProvider.loadMembers(placeId);
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

                    final result = await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => EnrollmentDetailScreen(
                          member: widget.member,
                          enrollment: enrollment,
                          course: course,
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
                        await memberProvider.loadMembers(placeId);
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
                      validFrom = courseEnrollmentData['validFrom'] != null
                          ? DateTime.parse(courseEnrollmentData['validFrom'])
                          : now;
                      validUntil = courseEnrollmentData['validUntil'] != null
                          ? DateTime.parse(courseEnrollmentData['validUntil'])
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
                        builder: (context) => EnrollmentDetailScreen(
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
                        builder: (context) =>
                            MemberCourseEnrollmentScreen(member: widget.member),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.textPrimary,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
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
          const SizedBox(height: 4),
          Text(
            '${enrollment.remainingReservations}회 남음',
            style: TextStyle(
              fontSize: 24,
              color: AppColors.backgroundWhite,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // 만료되었거나 횟수가 0인 코스 카드 (회색 배경)
  Widget _buildExpiredOrEmptyCourseCard(
    Course course,
    CourseEnrollment enrollment,
  ) {
    final isExpired = enrollment.isExpired;
    final statusText = isExpired ? '만료됨' : '횟수 소진';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.textSecondary.withOpacity(0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderLight, width: 1),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            course.name,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: AppColors.textPrimary,
            ),
            textAlign: TextAlign.left,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.textSecondary.withOpacity(0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              statusText,
              style: TextStyle(
                fontSize: 14,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
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

  Future<void> _handleRemoveFromCourse(
    CourseEnrollment enrollment,
    Course course,
  ) async {
    final confirmed = await CommonDialog.show(
      context: context,
      title: '코스에서 삭제',
      message: '${course.name}에서 ${widget.member.name}님을 삭제하시겠습니까?',
      cancelText: '취소',
      confirmText: '삭제',
      confirmButtonColor: AppColors.textSecondary,
    );

    if (confirmed != true) return;

    try {
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      final placeId = placeProvider.currentPlace?.id;
      if (placeId == null) {
        SnackbarUtil.showError(context, '플레이스를 찾을 수 없습니다.');
        return;
      }

      final fs = FirestoreService();

      // 1) 먼저 서버에 "미래 예약 존재 여부"를 확인 (cascade=false)
      try {
        await fs.cancelEnrollment(
          placeId: placeId,
          userId: widget.member.userId,
          courseId: enrollment.courseId,
          cascade: false,
        );
      } on FirebaseFunctionsException catch (e) {
        final details = e.details;
        final detailsMap = details is Map
            ? Map<String, dynamic>.from(details)
            : null;
        final requiresCascade = detailsMap?['requiresCascade'] == true;
        if (requiresCascade) {
          final reservationCount = detailsMap?['reservationCount'];
          final serverCourseName =
              (detailsMap?['courseName'] as String?) ?? course.name;

          final confirmedCascade = await CommonDialog.show(
            context: context,
            title: '수강 취소',
            message:
                '$serverCourseName\n\n미래 예약 $reservationCount건이 남아있습니다.\n예약 전부 취소 후 수강을 취소할까요?\n\n모든 예약자에게 알림이 발송됩니다.',
            cancelText: '취소',
            confirmText: '예약 전부 취소 후 수강 취소',
            confirmButtonColor: Colors.red,
          );

          if (confirmedCascade != true) return;

          await fs.cancelEnrollment(
            placeId: placeId,
            userId: widget.member.userId,
            courseId: enrollment.courseId,
            cascade: true,
          );
        } else {
          // 다른 에러는 그대로 노출
          rethrow;
        }
      }

      final enrollmentService = EnrollmentService();
      final now = TimezoneUtils.getSeoulDateTime();

      // 현재 등록 정보를 히스토리에 추가 (취소 기록)
      final currentHistory = List<ReenrollmentRecord>.from(
        enrollment.reenrollmentHistory,
      );
      currentHistory.add(
        ReenrollmentRecord(
          enrollmentNumber: enrollment.totalEnrollmentCount,
          totalReservations: enrollment.totalReservations,
          enrolledAt: enrollment.enrolledAt,
          validFrom: enrollment.validFrom,
          validUntil: enrollment.validUntil,
          cancelledAt: now, // 취소일 기록
        ),
      );

      // 유효 기간을 과거로 설정하여 만료 처리 (히스토리는 유지)
      final expiredEnrollment = enrollment.copyWith(
        validUntil: now.subtract(const Duration(days: 1)),
        reenrollmentHistory: currentHistory,
      );
      // 서버에서 이미 validUntil 만료 처리를 했으므로, 여기서는 "히스토리 기록/로컬 모델" 목적 업데이트만 수행
      await enrollmentService.updateEnrollment(expiredEnrollment);

      setState(() {
        _processedCourseIds.add(enrollment.courseId);
      });

      SnackbarUtil.showSuccess(context, '${course.name}에서 삭제되었습니다.');
    } catch (e) {
      SnackbarUtil.showError(context, '코스 삭제 중 오류가 발생했습니다: $e');
    }
  }

  Future<void> _showReenrollmentDialog(
    CourseEnrollment enrollment,
    Course course,
  ) async {
    final confirmed = await CommonDialog.show(
      context: context,
      title: '재등록',
      message: course.name,
      secondaryMessage: '재등록을 진행하시겠습니까?',
      cancelText: '취소',
      confirmText: '재등록',
      confirmButtonColor: AppColors.primaryGreen,
    );

    if (confirmed != true) return;

    try {
      final courseProvider = Provider.of<CourseProvider>(
        context,
        listen: false,
      );
      final now = TimezoneUtils.getSeoulDateTime();

      // Course의 defaultTotalReservations 가져오기
      final course = courseProvider.courses.firstWhere(
        (c) => c.id == enrollment.courseId,
        orElse: () => throw Exception('코스를 찾을 수 없습니다: ${enrollment.courseId}'),
      );
      final totalReservations = course.defaultTotalReservations;

      // 유효 기간 연장 및 횟수 초기화
      final renewedEnrollment = enrollment.copyWith(
        validFrom: now,
        validUntil: now.add(const Duration(days: 365)),
        totalReservations: totalReservations,
        remainingReservations: totalReservations,
      );
      final enrollmentService = EnrollmentService();
      await enrollmentService.updateEnrollment(renewedEnrollment);

      setState(() {
        _processedCourseIds.add(enrollment.courseId);
      });

      SnackbarUtil.showSuccess(context, '${course.name} 재등록이 완료되었습니다.');
    } catch (e) {
      SnackbarUtil.showError(context, '재등록 중 오류가 발생했습니다: $e');
    }
  }

  Future<void> _showApprovalDialog(
    CourseEnrollment enrollment,
    Course course,
  ) async {
    final confirmed = await CommonDialog.show(
      context: context,
      title: '연장 요청 승인',
      message: course.name,
      secondaryMessage: '연장 요청을 승인하시겠습니까?',
      cancelText: '취소',
      confirmText: '승인',
      confirmButtonColor: AppColors.primaryGreen,
    );

    if (confirmed != true) return;

    try {
      final enrollmentService = EnrollmentService();

      // 연장 승인 (30일 연장)
      final newValidUntil = enrollment.validUntil.add(const Duration(days: 30));
      final approvedEnrollment = enrollment.approveExtension(newValidUntil);
      await enrollmentService.updateEnrollment(approvedEnrollment);

      setState(() {
        _processedCourseIds.add(enrollment.courseId);
        _expandedRequestIndices.clear();
      });

      SnackbarUtil.showSuccess(context, '${course.name} 연장 요청이 승인되었습니다.');
    } catch (e) {
      SnackbarUtil.showError(context, '연장 승인 중 오류가 발생했습니다: $e');
    }
  }

  void _showRejectionDialog(CourseEnrollment enrollment, Course course) {
    CommonDialogWithTextField.show(
      context: context,
      title: '연장 요청 거절',
      message: course.name,
      secondaryMessage: '연장 요청을 거절하시겠습니까?',
      hintText: '거절 사유를 입력하세요',
      cancelText: '취소',
      confirmText: '거절',
      confirmButtonColor: AppColors.primaryGreen,
      onConfirm: (reason) async {
        try {
          final enrollmentService = EnrollmentService();

          // 연장 거절
          final rejectedEnrollment = enrollment.rejectExtension(reason);
          await enrollmentService.updateEnrollment(rejectedEnrollment);

          setState(() {
            _expandedRequestIndices.clear();
          });

          SnackbarUtil.showError(context, '${course.name} 연장 요청이 거절되었습니다.');
        } catch (e) {
          SnackbarUtil.showError(context, '연장 거절 중 오류가 발생했습니다: $e');
        }
      },
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
          onPressed: _isFormValid()
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
