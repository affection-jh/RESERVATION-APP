import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:reservation/utils/text_field_decoration_util.dart';
import '../../../models/course.dart';
import '../../../models/member_view.dart';
import '../../../models/course_enrollment.dart';
import '../../../theme/app_colors.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/member_provider.dart';
import '../../../utils/format_utils.dart';
import '../../../utils/snackbar_util.dart';
import '../../../utils/navigator_key.dart';
import '../../../services/member_service.dart';

/// 멤버 선택 바텀시트 (예약 추가용)
///
/// 【데이터 소스】
/// - totalCapacity, reservedCount: ReservationSummaryProvider (reservationSummary 구독)
/// - existingReservationUserIds: watchSessionReservations (reservations 구독) → 이미 예약한 유저 제외
/// - 멤버 목록: MemberProvider (places/{placeId}/members)
///
/// SessionDetailScreen에서 호출. N/M은 reservationSummary, 예약자 목록(누가)은 reservations.
enum MemberSelectionMode {
  /// 예약 추가용 (이미 예약한 유저 제외, 남은 횟수 표시)
  justMemberAdd,

  /// 부매니저 추가용 (이미 이 코스 부매니저인 유저 제외)
  forSubManagerAdd,
}

class MemberSelectionSidePanel extends StatefulWidget {
  final String placeId;
  final Course course;
  final MemberSelectionMode mode;
  final int totalCapacity;
  final int reservedCount;
  final List<String> existingReservationUserIds;
  final Function(List<MemberView> members) onMembersSelected;

  const MemberSelectionSidePanel({
    super.key,
    required this.placeId,
    required this.course,
    this.mode = MemberSelectionMode.justMemberAdd,
    this.totalCapacity = 0,
    this.reservedCount = 0,
    this.existingReservationUserIds = const [],
    required this.onMembersSelected,
  });

  /// 예약 추가용 (세션 상세에서 호출)
  static void showForReservation({
    required BuildContext context,
    required String placeId,
    required Course course,
    required int totalCapacity,
    required int reservedCount,
    required List<String> existingReservationUserIds,
    required Function(List<MemberView> members) onMembersSelected,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.7),
      isDismissible: true,
      enableDrag: true,
      useSafeArea: true,
      builder:
          (context) => MemberSelectionSidePanel(
            placeId: placeId,
            course: course,
            mode: MemberSelectionMode.justMemberAdd,
            totalCapacity: totalCapacity,
            reservedCount: reservedCount,
            existingReservationUserIds: existingReservationUserIds,
            onMembersSelected: onMembersSelected,
          ),
    );
  }

  /// 부매니저 추가용 (코스 편집에서 호출)
  static void showForSubManagerAdd({
    required BuildContext context,
    required String placeId,
    required Course course,
    required Function(List<MemberView> members) onMembersSelected,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.7),
      isDismissible: true,
      enableDrag: true,
      useSafeArea: true,
      builder:
          (context) => MemberSelectionSidePanel(
            placeId: placeId,
            course: course,
            mode: MemberSelectionMode.forSubManagerAdd,
            onMembersSelected: onMembersSelected,
          ),
    );
  }

  static void show({
    required BuildContext context,
    required String placeId,
    required Course course,
    required int totalCapacity,
    required int reservedCount,
    required List<String> existingReservationUserIds,
    required Function(List<MemberView> members) onMembersSelected,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.7),
      isDismissible: true,
      enableDrag: true,
      useSafeArea: true,
      builder:
          (context) => MemberSelectionSidePanel(
            placeId: placeId,
            course: course,
            mode: MemberSelectionMode.justMemberAdd,
            totalCapacity: totalCapacity,
            reservedCount: reservedCount,
            existingReservationUserIds: existingReservationUserIds,
            onMembersSelected: onMembersSelected,
          ),
    );
  }

  @override
  State<MemberSelectionSidePanel> createState() =>
      _MemberSelectionSidePanelState();
}

class _MemberSelectionSidePanelState extends State<MemberSelectionSidePanel> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  Set<String> _selectedUserIds = {};

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text);
    });
    // Provider 업데이트는 빌드 완료 후로 미룸 (setState during build 방지)
    // 부매니저일 때는 코스별 멤버만 구독(전체 멤버 미로드)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final memberProvider = Provider.of<MemberProvider>(
        context,
        listen: false,
      );
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final isSubManager = authProvider.isSubManagerForPlace(widget.placeId);
      memberProvider.setPlaceId(
        widget.placeId,
        isSubManagerForPlace: isSubManager,
      );
      memberProvider.setSelectedCourseId(widget.course.id);
      if (isSubManager) {
        memberProvider.selectSingleCourseForCourseTab(
          widget.course.id,
          save: false,
        );
      }
      memberProvider.setShowPending(true);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<MemberView> _getDisplayMembers(MemberProvider memberProvider) {
    final courseId = widget.course.id;
    final List<MemberView> list;
    if (widget.mode == MemberSelectionMode.forSubManagerAdd) {
      list = memberProvider.allMembers.where((v) {
        if (v.isManager) return false;
        if (v.manageableCourseIds.contains(courseId)) return false;
        return true;
      }).toList();
    } else {
      list = memberProvider.allMembers
          .where((v) => !widget.existingReservationUserIds.contains(v.userId))
          .toList();
    }
    // 등록됨(이 코스 수강 중) 멤버를 상단에 정렬
    list.sort((a, b) {
      final aEnrolled = a.enrolledCourseIds.contains(courseId);
      final bEnrolled = b.enrolledCourseIds.contains(courseId);
      if (aEnrolled == bEnrolled) return 0;
      return aEnrolled ? -1 : 1;
    });
    return list;
  }

  List<MemberView> _filterBySearch(List<MemberView> members, String query) {
    if (query.isEmpty) return members;
    final q = query.trim().toLowerCase();
    final digitsOnly = q.replaceAll(RegExp(r'[^\d]'), '');
    return members.where((v) {
      final name = (v.adminDisplayName).trim().toLowerCase();
      final phone = v.phoneNumber.replaceAll(RegExp(r'[^\d]'), '');
      final nameMatch = name.contains(q);
      final phoneMatch = digitsOnly.isNotEmpty && phone.contains(digitsOnly);
      return nameMatch || phoneMatch;
    }).toList();
  }

  /// 코스별 남은 횟수 (MemberProvider.enrollments 단일 소스 — 멤버관리 등과 동일)
  int _getRemainingForCourse(MemberView v, List<CourseEnrollment> enrollments) {
    final matches =
        enrollments
            .where(
              (e) => e.userId == v.userId && e.courseId == widget.course.id,
            )
            .toList();
    if (matches.isEmpty) return 0;
    return matches.first.remainingReservations;
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final viewInsetsBottom = mq.viewInsets.bottom;
    final paddingBottom = mq.padding.bottom;
    final screenHeight = mq.size.height;

    // 처음 올라온 높이 85% 유지 (키보드 여부와 관계없이 동일)
    final panelHeight = screenHeight * 0.85;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsetsBottom),
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          // 배경 탭 시 닫기
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
          ),
          // 패널: 정석 Column(헤더 | 본문(Expanded) | 푸터), 높이 85% 고정
          Material(
            color: Colors.transparent,
            child: Container(
              height: panelHeight,
              decoration: BoxDecoration(
                color: AppColors.backgroundWhite,
                borderRadius: BorderRadius.circular(30),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  _buildHeader(),
                  _buildBody(),
                  _buildFooter(paddingBottom),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 상단: 검색창 + (코스매니저 추가 모드일 때) 직접 전화번호 입력 버튼
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _searchController,
            decoration: TextFieldDecorationUtil.standardDecoration(
              hintText: '추가할 멤버 검색하기',
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 10,
              ),
            ).copyWith(
              prefixIcon: Icon(
                Icons.search,
                color: AppColors.textSecondary,
                size: 20,
              ),
              suffixIcon: IconButton(
                icon: Icon(
                  Icons.close,
                  color: AppColors.textSecondary,
                  size: 20,
                ),
                onPressed: () {
                  if (_searchQuery.isNotEmpty) {
                    _searchController.clear();
                  } else {
                    Navigator.of(context).pop();
                  }
                },
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showDirectPhoneInputDialog() {
    final placeId = widget.placeId;
    final courseId = widget.course.id;
    // 사이드 패널 먼저 닫기
    Navigator.of(context).pop();
    // 닫힌 뒤 바텀시트로 직접 입력 화면 표시
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = navigatorKey.currentContext;
      if (ctx == null) return;
      showModalBottomSheet<void>(
        context: ctx,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder:
            (sheetContext) => _DirectPhoneInputBottomSheet(
              placeId: placeId,
              courseId: courseId,
              onSuccess: () {
                Navigator.of(sheetContext).pop();
                SnackbarUtil.showSuccess(ctx, '코스매니저로 초대했습니다.');
                final memberProvider = Provider.of<MemberProvider>(
                  ctx,
                  listen: false,
                );
                memberProvider.setPlaceId(placeId, force: true);
              },
              onError: (String message) {
                Navigator.of(sheetContext).pop();
                SnackbarUtil.showInfo(ctx, message);
              },
            ),
      );
    });
  }

  /// 중간: 리스트 영역 (Expanded로 남는 공간 전부)
  Widget _buildBody() {
    return Expanded(
      child: Consumer<MemberProvider>(
        builder: (context, memberProvider, _) {
          final displayList = _getDisplayMembers(memberProvider);
          final filtered = _filterBySearch(displayList, _searchQuery);

          if (memberProvider.isLoading) {
            return Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: AppColors.primaryGreen,
                ),
              ),
            );
          }
          if (filtered.isEmpty) {
            final emptyText =
                widget.mode == MemberSelectionMode.forSubManagerAdd
                    ? (_searchQuery.isEmpty
                        ? '추가할 수 있는 멤버가 없어요'
                        : '검색 결과가 없습니다')
                    : (_searchQuery.isEmpty
                        ? '추가할 수 있는 멤버가 없어요'
                        : '검색 결과가 없습니다');
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(40),
                child: Text(
                  emptyText,
                  style: TextStyle(
                    fontSize: 16,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: filtered.length,
            separatorBuilder:
                (_, __) => Divider(
                  height: 1,
                  color: AppColors.borderLight.withOpacity(0.5),
                ),
            itemBuilder: (context, index) {
              final member = filtered[index];
              return _buildMemberItem(member, memberProvider);
            },
          );
        },
      ),
    );
  }

  /// 하단: 추가하기 버튼 (고정)
  Widget _buildFooter(double paddingBottom) {
    return Consumer<MemberProvider>(
      builder: (context, memberProvider, _) {
        if (memberProvider.isLoading) return const SizedBox.shrink();
        final displayList = _getDisplayMembers(memberProvider);
        return Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + paddingBottom),
          decoration: BoxDecoration(
            color: AppColors.backgroundWhite,
            border: Border(
              top: BorderSide(
                color: AppColors.borderLight.withOpacity(0.5),
                width: 1,
              ),
            ),
          ),
          child: SizedBox(
            width: double.infinity,
            child: Builder(
              builder: (context) {
                final isSubManagerMode =
                    widget.mode == MemberSelectionMode.forSubManagerAdd;
                final hasSelection = _selectedUserIds.isNotEmpty;
                // 코스매니저 추가 모드: 선택 없음 → 직접 전화번호 입력, 선택 있음 → 코스매니저로 추가
                final String buttonText;
                final VoidCallback? onPressed;
                if (isSubManagerMode) {
                  if (hasSelection) {
                    buttonText = '코스매니저로 추가';
                    onPressed = () {
                      final selected =
                          displayList
                              .where((v) => _selectedUserIds.contains(v.userId))
                              .toList();
                      if (context.mounted) Navigator.of(context).pop();
                      widget.onMembersSelected(selected);
                    };
                  } else {
                    buttonText = '직접 전화번호 입력';
                    onPressed = () => _showDirectPhoneInputDialog();
                  }
                } else {
                  buttonText = '추가하기';
                  onPressed =
                      hasSelection
                          ? () {
                            final selected =
                                displayList
                                    .where(
                                      (v) =>
                                          _selectedUserIds.contains(v.userId),
                                    )
                                    .toList();
                            if (context.mounted) Navigator.of(context).pop();
                            widget.onMembersSelected(selected);
                          }
                          : null;
                }
                return ElevatedButton(
                  onPressed: onPressed,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryGreen,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: AppColors.backgroundLight,
                    disabledForegroundColor: AppColors.textSecondary,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    elevation: 0,
                  ),
                  child: Text(
                    buttonText,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildMemberItem(MemberView member, MemberProvider memberProvider) {
    final isSelected = _selectedUserIds.contains(member.userId);
    final isForSubManager = widget.mode == MemberSelectionMode.forSubManagerAdd;
    final isEnrolled =
        !isForSubManager && member.enrolledCourseIds.contains(widget.course.id);
    final remaining =
        isEnrolled
            ? _getRemainingForCourse(member, memberProvider.enrollments)
            : 0;

    return InkWell(
      onTap: () {
        setState(() {
          if (isSelected) {
            _selectedUserIds.remove(member.userId);
          } else {
            _selectedUserIds.add(member.userId);
          }
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
        child: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color:
                      isSelected
                          ? AppColors.primaryGreen
                          : AppColors.borderLight,
                  width: 2,
                ),
                color: isSelected ? AppColors.primaryGreen : Colors.transparent,
              ),
              child:
                  isSelected
                      ? Icon(Icons.check, size: 16, color: Colors.white)
                      : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        member.adminDisplayName,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      if (member.isPending) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.textSecondary.withOpacity(0.4),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '가입 대기중',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                      if (isEnrolled) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.primaryGreen,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '등록됨',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    FormatUtils.formatPhoneNumber(member.phoneNumber),
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.textSecondary.withOpacity(0.8),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (!isForSubManager) ...[
                    const SizedBox(height: 6),
                    Text(
                      isEnrolled ? '남은 횟수: $remaining' : '이 코스에 등록되지 않음',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.textSecondary.withOpacity(0.8),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 직접 전화번호·이름 입력 바텀시트 (코스매니저 초대)
class _DirectPhoneInputBottomSheet extends StatefulWidget {
  final String placeId;
  final String courseId;
  final VoidCallback onSuccess;
  final void Function(String message) onError;

  const _DirectPhoneInputBottomSheet({
    required this.placeId,
    required this.courseId,
    required this.onSuccess,
    required this.onError,
  });

  @override
  State<_DirectPhoneInputBottomSheet> createState() =>
      _DirectPhoneInputBottomSheetState();
}

class _DirectPhoneInputBottomSheetState
    extends State<_DirectPhoneInputBottomSheet> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isSubmitting = false;

  /// 전화번호 중복만 실시간 표시 (나머지 에러는 버튼 클릭 시에만)
  String? _phoneDuplicateError;

  void _onFieldChanged() => setState(() {});

  /// 두 텍스트 필드가 모두 채워지고 에러가 없을 때만 true
  bool get _canSubmit {
    if (_isSubmitting) return false;
    final nameFilled = _nameController.text.trim().isNotEmpty;
    final phoneNorm = _normalizePhoneForCompare(_phoneController.text.trim());
    final phoneFilled = phoneNorm.length == 11;
    final noError = _phoneDuplicateError == null;
    return nameFilled && phoneFilled && noError;
  }

  String _normalizePhoneForCompare(String phoneNumber) {
    var digits = phoneNumber.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.startsWith('82')) {
      digits = '0${digits.substring(2)}';
    }
    if (digits.isNotEmpty && !digits.startsWith('0')) {
      digits = '0$digits';
    }
    return digits;
  }

  bool _existsInMemberProviderByPhone(String normalizedPhone) {
    if (normalizedPhone.isEmpty) return false;
    final memberProvider = Provider.of<MemberProvider>(context, listen: false);
    for (final v in memberProvider.allMembers) {
      final pn = (v.phoneNumber).trim();
      if (pn.isEmpty) continue;
      if (_normalizePhoneForCompare(pn) == normalizedPhone) return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _nameController.addListener(_onFieldChanged);
    _phoneController.addListener(_onFieldChanged);
  }

  @override
  void dispose() {
    _nameController.removeListener(_onFieldChanged);
    _phoneController.removeListener(_onFieldChanged);
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_formKey.currentState?.validate() != true) return;
    final phone = _phoneController.text.trim();
    final name = _nameController.text.trim();
    setState(() => _isSubmitting = true);
    try {
      final ok = await MemberService().inviteSubManagerForCourse(
        placeId: widget.placeId,
        courseId: widget.courseId,
        phoneNumber: phone,
        adminDisplayName: name,
      );
      if (!mounted) return;
      if (ok) {
        widget.onSuccess();
      } else {
        widget.onError('초대에 실패했습니다.');
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        widget.onError(
          (e.message ?? '').trim().isNotEmpty ? e.message! : '초대 중 오류가 발생했습니다.',
        );
      }
    } catch (e) {
      if (mounted) widget.onError('초대 중 오류가 발생했습니다.');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final paddingBottom = mq.padding.bottom;
    final viewInsetsBottom = mq.viewInsets.bottom;

    // 키보드 올라올 때 시트 전체를 viewInsets만큼 위로 밀어 입력란 가림 방지
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsetsBottom),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.backgroundWhite,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 24,
          bottom: 24 + paddingBottom,
        ),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Text(
                      '코스매니저로 초대',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _nameController,
                  decoration: TextFieldDecorationUtil.defaultDecoration(
                    hintText: '이름',
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                  textInputAction: TextInputAction.next,
                  validator: (v) {
                    if ((v ?? '').trim().isEmpty) {
                      return '이름을 입력해주세요';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _phoneController,
                  decoration: TextFieldDecorationUtil.defaultDecoration(
                    hintText: '전화번호',
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    errorText: _phoneDuplicateError,
                  ),
                  keyboardType: TextInputType.number,
                  autofillHints: const [AutofillHints.telephoneNumber],
                  textInputAction: TextInputAction.done,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(13),
                  ],
                  onChanged: (value) {
                    // 자동 포맷팅: 010-0000-0000 형식
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

                    if (_phoneController.text != result) {
                      _phoneController.value = TextEditingValue(
                        text: result,
                        selection: TextSelection.collapsed(
                          offset: result.length,
                        ),
                      );
                    }

                    // 중복 체크 (실시간)
                    final normalized = _normalizePhoneForCompare(result);
                    final String? next =
                        normalized.length == 11 &&
                                _existsInMemberProviderByPhone(normalized)
                            ? '이미 등록된 멤버입니다. 목록에서 선택해주세요'
                            : null;
                    if (_phoneDuplicateError != next) {
                      setState(() => _phoneDuplicateError = next);
                    }
                  },
                  validator: (v) {
                    final raw = (v ?? '').trim();
                    if (raw.isEmpty) return '전화번호를 입력해주세요';
                    final normalized = _normalizePhoneForCompare(raw);
                    if (normalized.length != 11) {
                      return '올바른 전화번호를 입력해주세요';
                    }
                    if (_phoneDuplicateError != null)
                      return _phoneDuplicateError;
                    return null;
                  },
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _canSubmit ? _submit : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primaryGreen,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: AppColors.backgroundLight,
                      disabledForegroundColor: AppColors.textSecondary,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                    child:
                        _isSubmitting
                            ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.primaryGreen,
                              ),
                            )
                            : const Text(
                              '코스매니저로 초대',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
