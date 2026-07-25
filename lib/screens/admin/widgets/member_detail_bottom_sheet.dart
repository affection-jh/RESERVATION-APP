import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../../../theme/app_colors.dart';
import '../../../models/course.dart';
import '../../../models/member_view.dart';
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
import 'course_edit_screen.dart';
import 'dart:async';

class MemberDetailBottomSheet extends StatefulWidget {
  final MemberView member;

  const MemberDetailBottomSheet({super.key, required this.member});

  static void show({
    required BuildContext context,
    required MemberView member,
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
  StreamSubscription<DocumentSnapshot>? _pendingMemberSubscription;

  /// pending 문서의 courseEnrollments에만 있는 코스 ID (관리만 하는 allowedCourseIds 제외)
  List<String> _allPendingCourseIds = [];
  List<String> _pendingCourseIds =
      []; // enrollments에 없는 pending 수강 코스 ID들 (계산된 값)
  List<CourseEnrollment> _pendingEnrollments =
      []; // pendingMembers의 courseEnrollments 파싱
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

    _enrollmentSubscription?.cancel();
    _enrollmentSubscription = null;
    _pendingMemberSubscription?.cancel();
    _pendingMemberSubscription = null;

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

      if (isPendingUser) {
        // 대기중 멤버: pendingMembers 경로 구독 (수강취소/횟수편집/휴쵸기간 변경 시 즉시 반영)
        final pendingId = '${placeId}_$normalizedPhone';
        final pendingRef = FirestoreService().firestore
            .collection('places')
            .doc(placeId)
            .collection('pendingMembers')
            .doc(pendingId);
        _pendingMemberSubscription = pendingRef.snapshots().listen(
          (snapshot) {
            if (!mounted) return;
            _applyPendingMemberSnapshot(placeId, snapshot);
          },
          onError: (e) {
            debugPrint(
              '[MemberDetailBottomSheet] pendingMembers stream error: $e',
            );
            if (mounted) {
              setState(() {
                _pendingMembersLoaded = true;
                _isLoading = !(_enrollmentsLoaded && _pendingMembersLoaded);
              });
            }
          },
        );
      } else {
        await _loadPendingMembers(placeId, normalizedPhone);
      }
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

  /// pendingMembers 스냅샷 적용 (스트림 리스너 및 일회성 로드 공통)
  void _applyPendingMemberSnapshot(
    String placeId,
    DocumentSnapshot? pendingDoc,
  ) {
    if (!mounted) return;

    PendingMember? foundPendingMember;
    final data = pendingDoc?.data();
    if (pendingDoc != null && pendingDoc.exists && data != null) {
      try {
        foundPendingMember = PendingMember.fromJson(
          Map<String, dynamic>.from(data as Map),
          docId: pendingDoc.id,
          placeId: placeId,
        );
      } catch (e) {
        debugPrint('PendingMember 파싱 오류: $e');
        foundPendingMember = null;
      }
    }

    List<CourseEnrollment> pendingEnrollments = [];
    if (pendingDoc != null && pendingDoc.exists && data != null) {
      final dataMap = Map<String, dynamic>.from(data as Map);
      final raw = dataMap['courseEnrollments'];
      if (raw is List && raw.isNotEmpty) {
        final now = TimezoneUtils.getSeoulDateTime();
        final adminName = widget.member.adminDisplayName;
        for (final item in raw) {
          if (item is! Map) continue;
          final map = Map<String, dynamic>.from(item);
          final courseId = map['courseId'] as String?;
          if (courseId == null || courseId.isEmpty) continue;
          final total =
              (map['totalReservations'] is int)
                  ? map['totalReservations'] as int
                  : (int.tryParse('${map['totalReservations']}') ?? 10);
          final remaining =
              (map['remainingReservations'] is int)
                  ? map['remainingReservations'] as int
                  : (int.tryParse('${map['remainingReservations']}') ?? total);
          DateTime validFrom = now;
          DateTime validUntil = now.add(const Duration(days: 365));
          DateTime enrolledAt = now;
          final vf = map['validFrom'];
          if (vf != null) {
            if (vf is Timestamp)
              validFrom = vf.toDate();
            else if (vf is String)
              validFrom = DateTime.parse(vf);
          }
          final vu = map['validUntil'];
          if (vu != null) {
            if (vu is Timestamp)
              validUntil = vu.toDate();
            else if (vu is String)
              validUntil = DateTime.parse(vu);
          }
          final ca = map['createdAt'];
          if (ca != null) {
            if (ca is Timestamp)
              enrolledAt = ca.toDate();
            else if (ca is String)
              enrolledAt = DateTime.parse(ca);
          }
          pendingEnrollments.add(
            CourseEnrollment(
              id: '',
              userId: widget.member.userId,
              courseId: courseId,
              userName: adminName,
              adminDisplayName: adminName,
              placeId: placeId,
              enrolledAt: enrolledAt,
              validFrom: validFrom,
              validUntil: validUntil,
              totalReservations: total,
              remainingReservations: remaining,
            ),
          );
        }
      }
    }

    setState(() {
      _pendingEnrollments = pendingEnrollments;
      // 등록 그리드/코스 등록 제외에는 실제 수강(courseEnrollments)만 사용. 관리만 하는 코스(allowedCourseIds) 제외
      _allPendingCourseIds = foundPendingMember?.courseIdsFromEnrollments ?? [];
      _updatePendingCourseIds();
      _pendingMembersLoaded = true;
      _isLoading = !(_enrollmentsLoaded && _pendingMembersLoaded);
    });
  }

  /// pendingMembers만 다시 조회 (일반 멤버용 일회성, places/{placeId}/pendingMembers)
  Future<void> _loadPendingMembers(
    String placeId,
    String normalizedPhone,
  ) async {
    final firestoreService = FirestoreService();
    final pendingId = '${placeId}_$normalizedPhone';
    final pendingRef = firestoreService.firestore
        .collection('places')
        .doc(placeId)
        .collection('pendingMembers')
        .doc(pendingId);

    try {
      final pendingDoc = await pendingRef.get();
      if (!mounted) return;
      _applyPendingMemberSnapshot(placeId, pendingDoc);
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
                          // 코스매니저일 때: 관리중인 코스 섹션 (탭 시 코스 편집 화면으로)
                          if (widget.member.isSubManager &&
                              widget.member.manageableCourseIds.isNotEmpty)
                            _buildManagedCoursesSection(),
                          if (widget.member.isSubManager &&
                              widget.member.manageableCourseIds.isNotEmpty)
                            const SizedBox(height: 6),
                          // 등록된 코스 목록: 코스매니저만(수강 등록 없음)이면 섹션 자체를 숨김
                          if (_shouldShowEnrollmentsSection())
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
    final memoPreview = _detailMemoPreview();
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
              if (memoPreview != null) ...[
                const SizedBox(height: 12),
                _MemoTwoLineScroller(text: memoPreview),
              ],
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
            // 삭제 버튼: 일반 멤버만 제거 가능 (매니저·부매니저·소유자 차단)
            if (_canRemoveFromPlace(context))
              _buildSvgIconButton(
                svgPath: 'assets/icons/delete.svg',
                color: AppColors.textPrimary,
                onTap: _handleDeleteMember,
              ),
            if (_canRemoveFromPlace(context)) const SizedBox(width: 8),
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

  /// 플레이스 메모 우선, 없으면 수강별 메모 중 첫 번째
  String? _detailMemoPreview() {
    MemberView? live;
    try {
      live = Provider.of<MemberProvider>(
        context,
        listen: false,
      ).getMemberView(widget.member.userId);
    } catch (_) {
      live = null;
    }
    final placeMemo =
        (live?.inactiveMemo ?? widget.member.inactiveMemo)?.trim();
    if (placeMemo != null && placeMemo.isNotEmpty) return placeMemo;
    for (final e in _enrollments) {
      final m = e.inactiveMemo?.trim();
      if (m != null && m.isNotEmpty) return m;
    }
    for (final e in _pendingEnrollments) {
      final m = e.inactiveMemo?.trim();
      if (m != null && m.isNotEmpty) return m;
    }
    return null;
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
          SnackbarUtil.showInfo(context, '이름 수정에 실패했습니다.');
        }
        return;
      }

      // MemberProvider 새로고침 (백그라운드)
      final memberProvider = Provider.of<MemberProvider>(
        context,
        listen: false,
      );
      memberProvider.setPlaceId(placeId);
      Future.delayed(const Duration(milliseconds: 600), () {
        if (!mounted) return;
        final list =
            memberProvider.allMembers
                .where((v) => v.phoneNumber == widget.member.phoneNumber)
                .toList();
        if (list.isNotEmpty &&
            list.first.adminDisplayName != _currentMemberName) {
          setState(() => _currentMemberName = list.first.adminDisplayName);
        }
      });

      SnackbarUtil.showSuccess(context, '이름이 수정되었습니다.');
    } catch (e) {
      // 실패 시 원래 이름으로 복구
      if (mounted) {
        setState(() {
          _currentMemberName = currentName;
        });
        SnackbarUtil.showInfo(context, '이름 수정 중 오류가 발생했습니다: $e');
      }
    }
  }

  /// 일반 멤버만 플레이스에서 제거 가능. 매니저·부매니저·플레이스 소유자는 제거 불가.
  /// 멤버 제거 실행은 매니저만 가능 (부매니저는 버튼 숨김).
  bool _canRemoveFromPlace(BuildContext context) {
    if (!widget.member.isMember) return false;
    final place =
        Provider.of<PlaceProvider>(context, listen: false).currentPlace;
    if (place == null) return false;
    if (place.adminIds.contains(widget.member.userId)) return false;
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    if (authProvider.isSubManagerForPlace(place.id)) return false;
    return true;
  }

  Future<void> _handleDeleteMember() async {
    if (!_canRemoveFromPlace(context)) {
      SnackbarUtil.showInfo(context, '매니저·코스매니저·소유자는 제거할 수 없어요.');
      return;
    }
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    final rootContext = rootNavigator.context;

    // 바텀시트 먼저 닫기
    Navigator.of(context).pop();

    // 카드에 로딩 표시 (다이얼로그 전에 호출해 삭제 확인 중에도 카드에 스피너 노출)
    final memberProvider = Provider.of<MemberProvider>(
      rootContext,
      listen: false,
    );
    memberProvider.startDeletingMember(widget.member.userId);

    // 다이얼로그 띄우기
    final shouldDelete = await CommonDialog.show(
      context: rootContext,
      title: '멤버 삭제',
      message: '이 멤버는 더이상 접속할 수 없어요\n이 멤버를 플레이스에서 제거할까요?',
      cancelText: '취소',
      confirmText: '삭제',
      confirmButtonColor: Colors.red,
    );

    // 취소 시 로딩 해제 후 바텀시트 다시 열기
    if (shouldDelete != true) {
      memberProvider.finishDeletingMember(widget.member.userId);
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
      memberProvider.finishDeletingMember(widget.member.userId);
      MemberDetailBottomSheet.show(context: rootContext, member: widget.member);
      return;
    }

    final normalizedPhone = widget.member.phoneNumber.replaceAll(
      RegExp(r'[^\d]'),
      '',
    );
    final authProvider = Provider.of<AuthProvider>(rootContext, listen: false);
    final adminUserId = authProvider.currentUser?.userId;

    try {
      await memberProvider.removeMemberFromPlace(
        placeId: placeId,
        userId: widget.member.userId,
        phoneNumber: normalizedPhone,
        adminUserId: adminUserId,
      );

      memberProvider.setPlaceId(placeId);
    } on FirebaseFunctionsException catch (e) {
      debugPrint(
        '[MemberDetailBottomSheet] removeMemberFromPlace HttpsError: ${e.code} ${e.message}',
      );
      if (rootContext.mounted) {
        final msg =
            (e.message ?? '').trim().isNotEmpty
                ? e.message!
                : _fallbackMessage(e.code);
        SnackbarUtil.showInfo(rootContext, msg);
        // 에러 시 바텀시트 다시 열지 않음 — 닫고 메시지만 표시
        if (Navigator.of(rootContext).canPop()) {
          Navigator.of(rootContext).pop();
        }
      }
    } catch (e, stack) {
      debugPrint(
        '[MemberDetailBottomSheet] removeMemberFromPlace error: $e\n$stack',
      );
      if (rootContext.mounted) {
        SnackbarUtil.showInfo(rootContext, '멤버를 제거하지 못했어요. 다시 시도해 주세요.');
        // 에러 시 바텀시트 다시 열지 않음 — 닫고 메시지만 표시
        if (Navigator.of(rootContext).canPop()) {
          Navigator.of(rootContext).pop();
        }
      }
    }
  }

  String _fallbackMessage(String? code) {
    switch (code) {
      case 'unauthenticated':
        return '로그인이 필요해요.';
      case 'permission-denied':
        return '권한이 없어요.';
      case 'invalid-argument':
        return '잘못된 요청이에요.';
      case 'failed-precondition':
        return '서버 설정 문제로 제거에 실패했어요. 잠시 후 다시 시도해 주세요.';
      case 'internal':
        return '멤버를 제거하지 못했어요. 다시 시도해 주세요.';
      default:
        return '멤버를 제거하지 못했어요. 다시 시도해 주세요.';
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

    return false;
  }

  /// 코스매니저일 때만 표시: 관리중인 코스 셀들. 탭 시 코스 편집 화면으로 이동.
  Widget _buildManagedCoursesSection() {
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final managedCourses =
        widget.member.manageableCourseIds
            .map(
              (id) =>
                  courseProvider.courses.where((c) => c.id == id).firstOrNull,
            )
            .whereType<Course>()
            .toList();
    if (managedCourses.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 1.15,
          ),
          itemCount: managedCourses.length,
          itemBuilder: (context, index) {
            final course = managedCourses[index];
            return GestureDetector(
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (context) => CourseEditScreen(course: course),
                  ),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Color(course.color),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        '코스매니저',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: AppColors.backgroundLight,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        course.name,
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: AppColors.backgroundWhite,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  /// 등록된 코스 섹션 표시 여부.
  /// - 일반 멤버: 항상 표시.
  /// - 코스매니저: 수강 등록 유무와 관계없이 항상 표시 (하단 "코스 추가" 셀 노출용).
  bool _shouldShowEnrollmentsSection() {
    return true;
  }

  Widget _buildEnrollmentsSection() {
    final courseProvider = Provider.of<CourseProvider>(context, listen: false);
    final allCourses = courseProvider.courses;

    // pending 멤버는 _pendingEnrollments 사용, 일반 멤버는 _enrollments 사용
    final sourceEnrollments =
        widget.member.isPending ? _pendingEnrollments : _enrollments;

    // 만료되었거나 횟수가 0인 enrollments (회색 배경, 앞쪽에 배치)
    final expiredOrEmptyEnrollments =
        sourceEnrollments
            .where(
              (e) =>
                  !_processedCourseIds.contains(e.courseId) &&
                  (e.isExpired || e.remainingReservations == 0),
            )
            .toList();

    // 유효한 enrollments (만료되지 않고 횟수가 남은 것)
    final validEnrollments =
        sourceEnrollments
            .where(
              (e) =>
                  !e.isExpired &&
                  e.remainingReservations > 0 &&
                  !_processedCourseIds.contains(e.courseId),
            )
            .toList();

    // pending 상태인 코스들 (courseEnrollments/enrollments에 없는 것만, 새로 추가용)
    final enrolledCourseIds = sourceEnrollments.map((e) => e.courseId).toSet();
    final pendingCourseIdsOnly =
        _pendingCourseIds
            .where(
              (id) =>
                  !enrolledCourseIds.contains(id) &&
                  !_processedCourseIds.contains(id),
            )
            .toList();
    final pendingCourses =
        pendingCourseIdsOnly.map((courseId) {
          final course = allCourses.firstWhere(
            (c) => c.id == courseId,
            orElse: () => allCourses.first,
          );
          return course;
        }).toList();

    final totalCourses =
        expiredOrEmptyEnrollments.length +
        validEnrollments.length +
        pendingCourses.length;

    // 그리드: 코스 카드들 + 항상 맨 마지막에 "코스 추가" 셀 1개 (회색 + 버튼)
    final gridItemCount = totalCourses + 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 코스 그리드 (+ 코스 추가 카드 항상 1개 포함)
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
            itemCount: gridItemCount,
            itemBuilder: (context, index) {
              // 마지막 셀: 항상 "코스 추가" 회색 카드
              if (index == totalCourses) {
                return _buildAddCourseCard();
              }
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

                    final hasRemainingReservations =
                        enrollment.remainingReservations > 0;
                    final initialTabIndex =
                        hasRemainingReservations
                            ? 2 // 재등록/취소 탭
                            : 1; // 재등록/취소 탭 (기간 연장 탭 없음)

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
                        memberProvider.setPlaceId(placeId);
                        if (widget.member.isPending) {
                          final normalizedPhone = widget.member.phoneNumber
                              .replaceAll(RegExp(r'[^\d]'), '');
                          await _loadPendingMembers(placeId, normalizedPhone);
                        }
                        setState(() {});
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

                    const initialTabIndex = null; // 기본값 (횟수 조정 탭)

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
                        memberProvider.setPlaceId(placeId);
                        if (widget.member.isPending) {
                          final normalizedPhone = widget.member.phoneNumber
                              .replaceAll(RegExp(r'[^\d]'), '');
                          await _loadPendingMembers(placeId, normalizedPhone);
                        }
                        setState(() {});
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
                      SnackbarUtil.showInfo(context, '플레이스를 찾을 수 없습니다.');
                      return;
                    }

                    final now = TimezoneUtils.getSeoulDateTime();
                    // 초대 토큰에는 enrollment 설정 미저장 → 기본값 사용
                    final validFrom = now;
                    final validUntil = now.add(const Duration(days: 365));
                    final totalReservations = course.defaultTotalReservations;
                    final remainingReservations =
                        course.defaultTotalReservations;

                    final tempEnrollment = CourseEnrollment(
                      id: '', // 빈 ID는 새로 생성할 enrollment를 의미
                      userId: widget.member.userId,
                      userName: widget.member.adminDisplayName,
                      adminDisplayName: widget.member.adminDisplayName,
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
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: AppColors.backgroundLight,
                  ),
                  textAlign: TextAlign.left,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '${enrollment.remainingReservations}회 남음',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: AppColors.backgroundLight,
                  ),
                ),
              ),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  _formatValidPeriod(
                    enrollment.validFrom,
                    enrollment.validUntil,
                  ),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: AppColors.backgroundLight,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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

  static String _formatValidPeriod(DateTime validFrom, DateTime validUntil) {
    ;
    final until = TimezoneUtils.formatDateToSeoul(
      validUntil,
    ).replaceAll('-', '.');
    return '$until까지';
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

  /// 그리드 맨 마지막에 항상 표시되는 "코스 추가" 회색 카드 (+ 버튼)
  Widget _buildAddCourseCard() {
    return GestureDetector(
      onTap: () async {
        // 이미 등록된(또는 초대된) 코스는 등록 화면에서 숨김
        final enrolledIds = _enrollments.map((e) => e.courseId).toSet();
        final pendingIds = _allPendingCourseIds.toSet();
        final excludeCourseIds = [...enrolledIds, ...pendingIds];

        final result = await Navigator.of(context).push(
          MaterialPageRoute(
            builder:
                (context) => MemberCourseEnrollmentScreen(
                  member: widget.member,
                  excludeCourseIds: excludeCourseIds,
                ),
          ),
        );
        if (result == true && mounted) {
          final placeProvider = Provider.of<PlaceProvider>(
            context,
            listen: false,
          );
          final placeId = placeProvider.currentPlace?.id;
          if (placeId != null) {
            final normalizedPhone = widget.member.phoneNumber.replaceAll(
              RegExp(r'[^\d]'),
              '',
            );
            await _loadPendingMembers(placeId, normalizedPhone);
          }
          final enrollmentProvider = _enrollmentProvider;
          if (enrollmentProvider != null) {
            _updateEnrollmentsFromProvider(enrollmentProvider);
          }
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.textSecondary.withOpacity(0.07),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add, size: 32, color: AppColors.textSecondary),
            const SizedBox(height: 4),
            Text(
              '코스 등록',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
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

/// 메모를 2줄 높이로만 보여주고, 스크롤로 나머지 확인
class _MemoTwoLineScroller extends StatelessWidget {
  final String text;

  const _MemoTwoLineScroller({required this.text});

  static const double _fontSize = 13;
  static const double _lineHeight = 1.35;
  static const double _viewportLines = 2.5;

  @override
  Widget build(BuildContext context) {
    final viewportHeight = _fontSize * _lineHeight * _viewportLines;
    return SizedBox(
      height: viewportHeight,
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Text(
          text,
          style: TextStyle(
            fontSize: _fontSize,
            height: _lineHeight,
            color: AppColors.textSecondary.withOpacity(0.9),
          ),
        ),
      ),
    );
  }
}
