import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/timezone_utils.dart';
import '../../../widgets/cached_image_widget.dart';
import '../../../models/member_view.dart';
import '../../../models/course.dart' as reservation_models;
import '../../../models/course_enrollment.dart';
import '../../../providers/member_provider.dart';
import '../../../providers/place_provider.dart';
import '../../../utils/snackbar_util.dart';
import 'enrollment_detail_screen.dart';
import 'member_detail_bottom_sheet.dart';
import 'shared_components.dart' as admin_shared;

// ---------------------------------------------------------------------------
// 모델
// ---------------------------------------------------------------------------

/// 연장 요청 정보 (멤버 카드 배지 등)
class ExtensionRequestInfo {
  final int count;
  final List<String> courseNames;

  ExtensionRequestInfo({required this.count, required this.courseNames});
}

// ---------------------------------------------------------------------------
// 코스 카드
// ---------------------------------------------------------------------------

/// 예약/관리 화면용 코스 카드 (이미지 + 이름 + 설명/수강생 수 + 자세히)
class ReservationCourseCard extends StatelessWidget {
  final reservation_models.Course course;
  final VoidCallback onTap;

  /// 수강생 수 (null이면 미표시)
  final int? studentCount;

  const ReservationCourseCard({
    super.key,
    required this.course,
    required this.onTap,
    this.studentCount,
  });

  @override
  Widget build(BuildContext context) {
    final hasDescription = course.description.isNotEmpty;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: AppColors.backgroundWhite,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Hero(
              tag: 'course_image_${course.id}',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: CourseImageWidget(
                  imageUrl: course.imageUrl,
                  width: 100,
                  height: 100,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: SizedBox(
                height: 110,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 12),
                        Text(
                          course.name,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        if (!hasDescription)
                          Text(
                            studentCount != null
                                ? '${studentCount!}명 수강'
                                : '수강',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        if (hasDescription)
                          Text(
                            course.description,
                            style: TextStyle(
                              fontSize: 14,
                              color: AppColors.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.primaryGreen,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  '자세히',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.backgroundWhite,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                Icons.arrow_forward_ios,
                                size: 14,
                                color: AppColors.backgroundWhite,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 멤버 카드
// ---------------------------------------------------------------------------

/// 멤버 목록용 카드 (이름, 전화번호, 복사, 상세 바텀시트)
class MemberCard extends StatefulWidget {
  final MemberView member;
  final VoidCallback? onMemberTapped;
  /// 롱프레스 시 카드의 전역 Rect와 함께 호출 (포커스 오버레이용)
  final void Function(Rect cardRect)? onMemberLongPressed;
  final Color? backgroundColor;
  final ExtensionRequestInfo? extensionRequestInfo;

  /// 코스별: 해당 코스 남은기간·횟수 표시
  final bool showCourseEnrollmentDetail;

  /// 코스별 보기에서 true면 탭 시 바텀시트 대신 EnrollmentDetailScreen으로 바로 이동
  final reservation_models.Course? courseForDirectDetail;

  /// 관리자 역할 칩 문구 오버라이드 (예: '코스매니저'). null이면 canManagePlace일 때 '매니저' 표시
  final String? roleChipLabel;

  /// false면 탭 시 MemberDetailBottomSheet를 열지 않고 onMemberTapped만 실행 (코스 편집 부매니저 카드 등)
  final bool openDetailSheetOnTap;

  final BorderRadius? borderRadius;

  const MemberCard({
    super.key,
    required this.member,
    this.onMemberTapped,
    this.onMemberLongPressed,
    this.backgroundColor,
    this.extensionRequestInfo,
    this.showCourseEnrollmentDetail = false,
    this.courseForDirectDetail,
    this.roleChipLabel,
    this.openDetailSheetOnTap = true,
    this.borderRadius,
  });

  @override
  State<MemberCard> createState() => _MemberCardState();
}

class _MemberCardState extends State<MemberCard> {
  bool _isCopied = false;

  void _openEnrollmentDetailDirect(BuildContext context) {
    final course = widget.courseForDirectDetail!;
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final placeId = placeProvider.currentPlace?.id;
    if (placeId == null) {
      SnackbarUtil.showInfo(context, '플레이스를 찾을 수 없습니다.');
      return;
    }

    CourseEnrollment enrollment;
    final isNewEnrollment = widget.member.enrollment == null;

    if (widget.member.enrollment != null) {
      enrollment = widget.member.enrollment!;
    } else {
      final now = TimezoneUtils.getSeoulDateTime();
      enrollment = CourseEnrollment(
        id: '',
        userId: widget.member.userId,
        userName: widget.member.adminDisplayName,
        adminDisplayName: widget.member.adminDisplayName,
        courseId: course.id,
        placeId: placeId,
        enrolledAt: now,
        validFrom: now,
        validUntil: now.add(const Duration(days: 365)),
        totalReservations: course.defaultTotalReservations,
        remainingReservations: course.defaultTotalReservations,
      );
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (context) => EnrollmentDetailScreen(
              member: widget.member,
              enrollment: enrollment,
              course: course,
              isNewEnrollment: isNewEnrollment,
            ),
      ),
    );
  }

  static String _formatPhoneNumber(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length <= 3) return digits;
    if (digits.length <= 7) {
      return '${digits.substring(0, 3)}-${digits.substring(3)}';
    }
    if (digits.length <= 11) {
      return '${digits.substring(0, 3)}-${digits.substring(3, 7)}-${digits.substring(7)}';
    }
    return '${digits.substring(0, 3)}-${digits.substring(3, 7)}-${digits.substring(7, 11)}';
  }

  @override
  Widget build(BuildContext context) {
    final hasRequests = widget.member.hasPendingRequests;
    final memberProvider = Provider.of<MemberProvider>(context);
    final isDeleting = memberProvider.isDeletingMember(widget.member.userId);
    final isCardLoading = memberProvider.isMemberCardLoading(
      widget.member.userId,
    );

    return GestureDetector(
      onTap:
          isDeleting
              ? null
              : () {
                widget.onMemberTapped?.call();
                if (widget.courseForDirectDetail != null) {
                  _openEnrollmentDetailDirect(context);
                  return;
                }
                if (!widget.openDetailSheetOnTap) return;
                MemberDetailBottomSheet.show(
                  context: context,
                  member: widget.member,
                );
              },
      onLongPress:
          isDeleting || widget.onMemberLongPressed == null
              ? null
              : () {
                final box = context.findRenderObject() as RenderBox?;
                if (box == null || !box.hasSize) return;
                final rect = box.localToGlobal(Offset.zero) & box.size;
                widget.onMemberLongPressed!(rect);
              },
      child: Stack(
        children: [
          Opacity(
            opacity: isDeleting ? 0.7 : 1.0,
            child: Container(
              padding: const EdgeInsets.only(
                left: 20,
                right: 20,
                top: 10,
                bottom: 10,
              ),
              decoration: BoxDecoration(
                color: widget.backgroundColor ?? AppColors.backgroundWhite,
                borderRadius:
                    widget.borderRadius ?? BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: Row(
                                children: [
                                  Flexible(
                                    child: Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        widget.member.adminDisplayName,
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: AppColors.textPrimary,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                  if (widget.member.canManagePlace) ...[
                                    const SizedBox(width: 8),
                                    admin_shared.Chip(
                                      text:
                                          widget.roleChipLabel ??
                                          (widget.member.isSubManager
                                              ? '코스매니저'
                                              : '매니저'),
                                      backgroundColor: AppColors.primaryGreen,
                                      textColor: Colors.white,
                                    ),
                                  ],
                                  if (widget.member.isPending) ...[
                                    const SizedBox(width: 8),
                                    const admin_shared.Chip(text: '가입 대기중'),
                                  ],

                                  if (widget.showCourseEnrollmentDetail) ...[
                                    const SizedBox(width: 8),
                                    Text(
                                      _formatPhoneNumber(
                                        widget.member.phoneNumber,
                                      ),
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: AppColors.textSecondary,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        if (!widget.showCourseEnrollmentDetail)
                          Row(
                            children: [
                              Text(
                                _formatPhoneNumber(widget.member.phoneNumber),
                                style: TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: () {
                                  Clipboard.setData(
                                    ClipboardData(
                                      text: widget.member.phoneNumber,
                                    ),
                                  );
                                  setState(() => _isCopied = true);
                                  SnackbarUtil.showSuccess(
                                    context,
                                    '클립보드에 복사되었습니다',
                                  );
                                  Future.delayed(
                                    const Duration(seconds: 2),
                                    () {
                                      if (mounted)
                                        setState(() => _isCopied = false);
                                    },
                                  );
                                },
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 200),
                                  child: Icon(
                                    _isCopied ? Icons.check : Icons.copy,
                                    key: ValueKey(_isCopied),
                                    size: 16,
                                    color:
                                        _isCopied
                                            ? AppColors.primaryGreen
                                            : AppColors.textSecondary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        if (widget.showCourseEnrollmentDetail &&
                            widget.member.enrollment != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.backgroundLight,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    '남은 횟수 ${widget.member.enrollment!.remainingReservations}회',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: AppColors.textPrimary,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.backgroundLight,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    '${TimezoneUtils.formatDateToSeoul(widget.member.enrollment!.validFrom).replaceAll('-', '.')} - ${TimezoneUtils.formatDateToSeoul(widget.member.enrollment!.validUntil).replaceAll('-', '.')}',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: AppColors.textPrimary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                  isCardLoading
                      ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.primaryGreen,
                        ),
                      )
                      : (!isDeleting &&
                              (widget.member.needsReenrollment == true ||
                                  hasRequests))
                          ? Container(
                              width: 16,
                              height: 16,
                              alignment: Alignment.center,
                              child: Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: Colors.red,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            )
                          : Icon(
                              Icons.arrow_forward_ios,
                              size: 16,
                              color: AppColors.textSecondary.withOpacity(0.5),
                            ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
