import 'dart:async';
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
import '../../../services/enrollment_service.dart';
import '../../../utils/local_storage_util.dart';
import '../../../providers/place_provider.dart';
import '../../../widgets/direct_phone_input_bottom_sheet.dart';
import '../../../widgets/admin_send_notification_checkbox.dart';
import '../../../widgets/keyboard_bleed_fill.dart';

/// 멤버 선택 바텀시트 (예약 추가용)
///
/// 【데이터 소스】
/// - totalCapacity, reservedCount: ReservationSummaryProvider (reservationSummary 구독)
/// - existingReservationUserIds: watchSessionReservations (reservations 구독) → 이미 예약한 유저 제외
/// - 멤버 목록: MemberProvider (places/{placeId}/members)
/// - 남은 횟수: enrollments(placeId+courseId) 실시간 구독
///
/// SessionDetailScreen에서 호출. N/M은 reservationSummary, 예약자 목록(누가)은 reservations.
///
/// [sendNotification]은 예약 추가(justMemberAdd)에서만 의미가 있다. 그 외 모드는 무시해도 된다.
typedef MembersSelectedCallback =
    void Function(List<MemberView> members, {bool sendNotification});

enum MemberSelectionMode {
  /// 예약 추가용 (이미 예약한 유저 제외, 남은 횟수 표시)
  justMemberAdd,

  /// 부매니저(코스매니저) 추가용 (이미 이 코스 부매니저인 유저 제외)
  forSubManagerAdd,

  /// 전체 매니저 추가용 (이미 전체 매니저인 유저 제외)
  forFullManagerAdd,
}

class MemberSelectionSidePanel extends StatefulWidget {
  final String placeId;

  /// null when mode == forFullManagerAdd
  final Course? course;
  final MemberSelectionMode mode;

  /// used when mode == forFullManagerAdd (현재 전체 매니저 userId 목록, 제외용)
  final List<String>? currentAdminIds;
  final int totalCapacity;
  final int reservedCount;
  final List<String> existingReservationUserIds;
  final MembersSelectedCallback onMembersSelected;

  const MemberSelectionSidePanel({
    super.key,
    required this.placeId,
    this.course,
    this.mode = MemberSelectionMode.justMemberAdd,
    this.currentAdminIds,
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
    required MembersSelectedCallback onMembersSelected,
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
    required MembersSelectedCallback onMembersSelected,
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

  /// 전체 매니저 추가용 (플레이스 편집에서 호출)
  static void showForFullManagerAdd({
    required BuildContext context,
    required String placeId,
    required List<String> currentAdminIds,
    required MembersSelectedCallback onMembersSelected,
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
            course: null,
            mode: MemberSelectionMode.forFullManagerAdd,
            currentAdminIds: currentAdminIds,
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
    required MembersSelectedCallback onMembersSelected,
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

  /// 코스 enrollment 실시간 구독 (남은 횟수 표시용)
  StreamSubscription<List<CourseEnrollment>>? _courseEnrollmentsSub;
  final Map<String, int> _liveRemainingByUserId = {};

  /// 예약 추가 시 예약자에게 알림 전송 여부 (마지막 선택값 로컬 저장)
  bool _sendReservationNotification = true;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text);
    });
    if (widget.mode == MemberSelectionMode.justMemberAdd) {
      _restoreSendNotificationPref();
    }
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
      final course = widget.course;
      if (course != null) {
        memberProvider.setSelectedCourseId(course.id);
        if (isSubManager) {
          memberProvider.selectSingleCourseForCourseTab(course.id, save: false);
        }
        _startCourseEnrollmentWatch(course.id);
      }
      memberProvider.setShowPending(true);
    });
  }

  void _startCourseEnrollmentWatch(String courseId) {
    _courseEnrollmentsSub?.cancel();
    _courseEnrollmentsSub = EnrollmentService()
        .watchCourseEnrollments(widget.placeId, courseId)
        .listen(
          (list) {
            if (!mounted) return;
            setState(() {
              _liveRemainingByUserId
                ..clear()
                ..addEntries(
                  list.map(
                    (e) => MapEntry(e.userId, e.remainingReservations),
                  ),
                );
            });
          },
          onError: (e) {
            debugPrint(
              '[MemberSelectionSidePanel] course enrollments watch error: $e',
            );
          },
        );
  }

  @override
  void dispose() {
    _courseEnrollmentsSub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  List<MemberView> _getDisplayMembers(MemberProvider memberProvider) {
    final course = widget.course;
    final courseId = course?.id ?? '';
    final List<MemberView> list;
    if (widget.mode == MemberSelectionMode.forFullManagerAdd) {
      final adminIds = widget.currentAdminIds ?? [];
      // 이미 전체 매니저(adminIds)만 제외. 코스매니저·일반 멤버·pending 모두 후보에 표시
      list =
          memberProvider.allMembers
              .where((v) => !adminIds.contains(v.userId))
              .toList();
    } else if (widget.mode == MemberSelectionMode.forSubManagerAdd) {
      list =
          memberProvider.allMembers.where((v) {
            if (v.isManager) return false;
            if (v.manageableCourseIds.contains(courseId)) return false;
            return true;
          }).toList();
    } else {
      list =
          memberProvider.allMembers
              .where(
                (v) => !widget.existingReservationUserIds.contains(v.userId),
              )
              .toList();
    }
    if (course != null) {
      // 등록됨(이 코스 수강 중) 멤버를 상단에 정렬
      list.sort((a, b) {
        final aEnrolled = a.enrolledCourseIds.contains(courseId);
        final bEnrolled = b.enrolledCourseIds.contains(courseId);
        if (aEnrolled == bEnrolled) return 0;
        return aEnrolled ? -1 : 1;
      });
    }
    return _uniqueByUserId(list);
  }

  List<MemberView> _uniqueByUserId(List<MemberView> members) {
    final seen = <String>{};
    final out = <MemberView>[];
    for (final m in members) {
      if (m.userId.isEmpty || seen.contains(m.userId)) continue;
      seen.add(m.userId);
      out.add(m);
    }
    return out;
  }

  List<MemberView> _selectedMembersFrom(
    List<MemberView> displayList,
    Set<String> selectedUserIds,
  ) {
    return _uniqueByUserId(
      displayList.where((v) => selectedUserIds.contains(v.userId)).toList(),
    );
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

  Future<void> _restoreSendNotificationPref() async {
    final saved = await StorageService().getAdminReservationSendNotification();
    if (!mounted || saved == null) return;
    if (_sendReservationNotification == saved) return;
    setState(() => _sendReservationNotification = saved);
  }

  void _setSendReservationNotification(bool value) {
    if (_sendReservationNotification == value) return;
    setState(() => _sendReservationNotification = value);
    StorageService().saveAdminReservationSendNotification(value).ignore();
  }

  void _emitSelection(List<MemberView> selected) {
    if (context.mounted) Navigator.of(context).pop();
    widget.onMembersSelected(
      selected,
      sendNotification: _sendReservationNotification,
    );
  }

  /// 코스별 남은 횟수 — enrollments(placeId+courseId) 실시간 구독 우선
  int _getRemainingForCourse(MemberView v, List<CourseEnrollment> enrollments) {
    final live = _liveRemainingByUserId[v.userId];
    if (live != null) return live;

    // 구독 첫 emit 전 fallback (MemberProvider 캐시)
    final cid = widget.course?.id;
    if (cid == null || cid.isEmpty) return 0;
    final matches =
        enrollments
            .where((e) => e.userId == v.userId && e.courseId == cid)
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
        clipBehavior: Clip.none,
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
            child: KeyboardBleedFill(
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
    final isFullManagerMode =
        widget.mode == MemberSelectionMode.forFullManagerAdd;
    final course = widget.course;
    Navigator.of(context).pop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = navigatorKey.currentContext;
      if (ctx == null) return;
      if (isFullManagerMode) {
        DirectPhoneInputBottomSheet.show(
          context: ctx,
          title: '전화번호로 전체 매니저 추가',
          submitButtonText: '전체 매니저로 추가',
          showNameField: true,
          onSubmit: (submitCtx, normalizedPhone, name) async {
            try {
              final phone = FormatUtils.formatPhoneNumber(normalizedPhone);
              final ok = await MemberService().inviteFullManager(
                placeId: placeId,
                phoneNumber: phone,
                adminDisplayName:
                    (name != null && name.trim().isNotEmpty)
                        ? name.trim()
                        : null,
              );
              if (!submitCtx.mounted) return null;
              if (ok) return null;
              return '전체 매니저 추가에 실패했습니다.';
            } on FirebaseFunctionsException catch (e) {
              if (e.code == 'internal') {
                return '서버 오류가 발생했습니다. 잠시 후 다시 시도해 주세요.';
              }
              return (e.message ?? '').trim().isNotEmpty
                  ? e.message!
                  : '전체 매니저 추가 중 오류가 발생했습니다.';
            } catch (e) {
              return '전체 매니저 추가 중 오류가 발생했습니다.';
            }
          },
          onSuccess: () {
            final c = navigatorKey.currentContext;
            if (c != null) {
              Provider.of<PlaceProvider>(c, listen: false).loadPlace(placeId);
              SnackbarUtil.showSuccess(c, '전체 매니저로 추가했습니다.');
            }
          },
        );
        return;
      }
      final courseId = course!.id;
      DirectPhoneInputBottomSheet.show(
        context: ctx,
        title: '코스매니저로 초대',
        submitButtonText: '코스매니저로 초대',
        showNameField: true,
        checkPhoneError: (normalizedPhone) {
          final c = navigatorKey.currentContext;
          if (c == null) return null;
          final memberProvider = Provider.of<MemberProvider>(c, listen: false);
          for (final v in memberProvider.allMembers) {
            final pn = (v.phoneNumber).trim();
            if (pn.isEmpty) continue;
            if (FormatUtils.normalizePhoneForCompare(pn) == normalizedPhone) {
              if (v.isManager) {
                return '이미 이 플레이스의 전체 매니저입니다.';
              }
              return '이미 등록된 멤버입니다. 목록에서 선택해주세요';
            }
          }
          return null;
        },
        onSubmit: (context, normalizedPhone, name) async {
          final phone = FormatUtils.formatPhoneNumber(normalizedPhone);
          try {
            final ok = await MemberService().inviteSubManagerForCourse(
              placeId: placeId,
              courseId: courseId,
              phoneNumber: phone,
              adminDisplayName: name,
            );
            if (!context.mounted) return null;
            if (ok) return null;
            return '초대에 실패했습니다.';
          } on FirebaseFunctionsException catch (e) {
            if (e.code == 'internal') {
              return '서버 오류가 발생했습니다. 잠시 후 다시 시도해 주세요.';
            }
            return (e.message ?? '').trim().isNotEmpty
                ? e.message!
                : '초대 중 오류가 발생했습니다.';
          } catch (e) {
            return '초대 중 오류가 발생했습니다.';
          }
        },
        onSuccess: () {
          final c = navigatorKey.currentContext;
          if (c != null) {
            SnackbarUtil.showSuccess(c, '코스매니저로 초대했습니다.');
            Provider.of<MemberProvider>(
              c,
              listen: false,
            ).setPlaceId(placeId, force: true);
          }
        },
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
            final isAddMode =
                widget.mode == MemberSelectionMode.forSubManagerAdd ||
                widget.mode == MemberSelectionMode.forFullManagerAdd;
            final emptyText =
                isAddMode
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
        final isReservationMode =
            widget.mode == MemberSelectionMode.justMemberAdd;
        final hasSelection = _selectedUserIds.isNotEmpty;
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isReservationMode && hasSelection) ...[
                AdminSendNotificationCheckbox(
                  value: _sendReservationNotification,
                  onChanged: _setSendReservationNotification,
                  label: '예약 알림 보내기',
                  offHint: '알림 없이 추가',
                ),
                const SizedBox(height: 10),
              ],
              SizedBox(
                width: double.infinity,
                child: Builder(
                  builder: (context) {
                    final isSubManagerMode =
                        widget.mode == MemberSelectionMode.forSubManagerAdd;
                    final isFullManagerMode =
                        widget.mode == MemberSelectionMode.forFullManagerAdd;
                    final String buttonText;
                    final VoidCallback? onPressed;
                    if (isFullManagerMode) {
                      if (hasSelection) {
                        buttonText = '추가 (${_selectedUserIds.length}명)';
                        onPressed = () {
                          _emitSelection(
                            _selectedMembersFrom(displayList, _selectedUserIds),
                          );
                        };
                      } else {
                        buttonText = '직접 전화번호 입력';
                        onPressed = () => _showDirectPhoneInputDialog();
                      }
                    } else if (isSubManagerMode) {
                      if (hasSelection) {
                        buttonText = '코스매니저로 추가';
                        onPressed = () {
                          _emitSelection(
                            _selectedMembersFrom(displayList, _selectedUserIds),
                          );
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
                                _emitSelection(
                                  _selectedMembersFrom(
                                    displayList,
                                    _selectedUserIds,
                                  ),
                                );
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
            ],
          ),
        );
      },
    );
  }

  Widget _buildMemberItem(MemberView member, MemberProvider memberProvider) {
    final isSelected = _selectedUserIds.contains(member.userId);
    final isForSubManager = widget.mode == MemberSelectionMode.forSubManagerAdd;
    final isFullManagerMode =
        widget.mode == MemberSelectionMode.forFullManagerAdd;
    final courseId = widget.course?.id ?? '';
    final isEnrolled =
        !isForSubManager &&
        !isFullManagerMode &&
        courseId.isNotEmpty &&
        member.enrolledCourseIds.contains(courseId);
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
                  if (isFullManagerMode && member.isSubManager)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '코스매니저 → 전체 매니저로 승격됩니다',
                        style: TextStyle(
                          fontSize: 14,
                          color: AppColors.primaryGreen,
                        ),
                      ),
                    ),
                  if (!isForSubManager && !isFullManagerMode) ...[
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
