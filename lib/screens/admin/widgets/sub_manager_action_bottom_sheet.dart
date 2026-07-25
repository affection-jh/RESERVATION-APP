import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/svg.dart';
import 'package:provider/provider.dart';
import '../../../theme/app_colors.dart';
import '../../../models/member_view.dart';
import '../../../utils/format_utils.dart';
import '../../../utils/snackbar_util.dart';
import '../../../widgets/common_dialog.dart';
import '../../../services/member_service.dart';
import '../../../providers/member_provider.dart';
import '../../../utils/navigator_key.dart';
import '../../../widgets/keyboard_bleed_fill.dart';

/// 코스 편집 화면에서 부매니저 카드 탭 시: 이름 변경 + 부매니저 지정 취소만 제공
/// 이름 변경은 MemberDetailBottomSheet와 동일하게 인라인 편집(연필 탭 → TextField → 완료 시 저장)
class SubManagerActionBottomSheet extends StatefulWidget {
  final String placeId;
  final String courseId;
  final MemberView member;

  const SubManagerActionBottomSheet({
    super.key,
    required this.placeId,
    required this.courseId,
    required this.member,
  });

  static void show({
    required BuildContext context,
    required String placeId,
    required String courseId,
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
      builder:
          (context) => SubManagerActionBottomSheet(
            placeId: placeId,
            courseId: courseId,
            member: member,
          ),
    );
  }

  @override
  State<SubManagerActionBottomSheet> createState() =>
      _SubManagerActionBottomSheetState();
}

class _SubManagerActionBottomSheetState
    extends State<SubManagerActionBottomSheet> {
  String? _currentMemberName;
  bool _isEditingName = false;
  TextEditingController? _nameController;

  @override
  void initState() {
    super.initState();
    _currentMemberName = widget.member.adminDisplayName;
  }

  @override
  void dispose() {
    _nameController?.dispose();
    super.dispose();
  }

  void _handleEditName() {
    setState(() {
      _isEditingName = true;
      _nameController = TextEditingController(
        text: _currentMemberName ?? widget.member.adminDisplayName,
      );
    });
  }

  Future<void> _saveName() async {
    final newName = _nameController?.text.trim() ?? '';
    final currentName = _currentMemberName ?? widget.member.adminDisplayName;
    if (newName.isEmpty || newName == currentName) {
      setState(() {
        _isEditingName = false;
        _nameController?.dispose();
        _nameController = null;
      });
      return;
    }

    try {
      setState(() {
        _currentMemberName = newName;
        _isEditingName = false;
        _nameController?.dispose();
        _nameController = null;
      });

      final memberService = MemberService();
      final ok = await memberService.updateMemberName(
        placeId: widget.placeId,
        phoneNumber: widget.member.phoneNumber,
        newName: newName,
      );

      if (!ok) {
        if (mounted) {
          setState(() => _currentMemberName = currentName);
          SnackbarUtil.showInfo(context, '이름 수정에 실패했습니다.');
        }
        return;
      }

      final memberProvider = Provider.of<MemberProvider>(
        context,
        listen: false,
      );
      memberProvider.setPlaceId(widget.placeId, force: true);
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

      if (mounted) SnackbarUtil.showSuccess(context, '이름이 수정되었습니다.');
    } catch (e) {
      if (mounted) {
        setState(() => _currentMemberName = currentName);
        SnackbarUtil.showInfo(context, '이름 수정 중 오류가 발생했습니다: $e');
      }
    }
  }

  Future<void> _confirmRemoveSubManager() async {
    final placeId = widget.placeId;
    final courseId = widget.courseId;
    final targetUserId = widget.member.userId;
    final displayName = _currentMemberName ?? widget.member.adminDisplayName;

    Navigator.of(context).pop();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ctx = navigatorKey.currentContext;
      if (ctx == null) return;
      final memberProvider = Provider.of<MemberProvider>(ctx, listen: false);
      memberProvider.startProcessingMember(targetUserId);

      try {
        final confirmed = await CommonDialog.show(
          context: ctx,
          title: '코스매니저 지정 취소',
          message: '$displayName\n코스매니저 권한을 취소하시겠습니까?',
          cancelText: '취소',
          confirmText: '취소하기',
          confirmButtonColor: Colors.red,
        );
        if (confirmed != true) return;

        final memberService = MemberService();
        final success = await memberService.removeSubManagerFromCourse(
          placeId: placeId,
          courseId: courseId,
          targetUserId: targetUserId,
        );
        if (ctx.mounted) {
          if (success) {
            SnackbarUtil.showSuccess(ctx, '코스매니저에서 삭제되었습니다.');
          } else {
            SnackbarUtil.showInfo(ctx, '처리할 수 없습니다. 잠시 후 다시 시도해주세요.');
          }
        }
      } finally {
        if (ctx.mounted) {
          memberProvider.finishProcessingMember(targetUserId);
          memberProvider.setPlaceId(placeId, force: true);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final viewInsetsBottom = mq.viewInsets.bottom;

    // 키보드 올라올 때 시트 전체를 viewInsets만큼 위로 밀어 입력란 가림 방지 (member_detail과 동일)
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsetsBottom),
      child: KeyboardBleedFill(
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.backgroundWhite,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 헤더: 이름(또는 인라인 TextField) + 전화번호 | 연필 | 닫기
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 12, 20),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
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
                                contentPadding: EdgeInsets.zero,
                                isDense: true,
                              ),
                              autofocus: true,
                              maxLines: 1,
                              textInputAction: TextInputAction.done,
                              inputFormatters: [
                                LengthLimitingTextInputFormatter(20),
                              ],
                              onSubmitted: (_) => _saveName(),
                              scrollPadding: EdgeInsets.zero,
                            )
                          else
                            Text(
                              _currentMemberName ??
                                  widget.member.adminDisplayName,
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: AppColors.textPrimary,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          const SizedBox(height: 4),
                          Text(
                            FormatUtils.formatPhoneNumber(
                              widget.member.phoneNumber,
                            ),
                            style: TextStyle(
                              fontSize: 15,
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.normal,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _buildSvgIconButton(
                      svgPath: 'assets/icons/edit.svg',
                      color: AppColors.primaryGreen,
                      onTap: _handleEditName,
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: AppColors.textPrimary.withOpacity(0.08),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Icon(
                            Icons.close,
                            size: 20,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: AppColors.borderLight.withOpacity(0.5)),
              // 하단: 부매니저 지정 취소 (플랫 레드 텍스트 버튼, 세션 취소하기 스타일)
              Padding(
                padding: EdgeInsets.fromLTRB(24, 0, 24, 10),
                child: SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: _confirmRemoveSubManager,
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.red,
                      backgroundColor: Colors.transparent,
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      minimumSize: const Size(double.infinity, 56),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(0),
                      ),
                    ),
                    child: const Text(
                      '코스매니저 지정 취소',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
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
}
