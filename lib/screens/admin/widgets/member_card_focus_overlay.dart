import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../models/member_view.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/snackbar_util.dart';
import '../../../utils/navigator_key.dart';

/// 오버레이에서 나온 결과
class MemberCardFocusResult {
  final bool isDeactivateOrReactivate;
  final String? memoText;

  const MemberCardFocusResult.deactivate()
    : isDeactivateOrReactivate = true,
      memoText = null;

  const MemberCardFocusResult.memo(this.memoText)
    : isDeactivateOrReactivate = false;
}

/// 멤버 롱프레스: 블러 배경 위에 회원 정보만 깔끔히 띄우고
/// 비활성·메모 액션을 제공한다. 메모는 오버레이 안에서 작성.
class MemberCardFocusOverlay {
  static Future<MemberCardFocusResult?> show({
    required BuildContext context,
    required Rect cardRect,
    required MemberView member,
    required bool showCourseDetail,
    required bool canDeactivate,
    required bool isCurrentlyInactive,
    String initialMemo = '',
    String? deactivateBlockedReason,
  }) {
    HapticFeedback.mediumImpact();
    // FadeTransition으로 BackdropFilter를 감싸면 블러가 나중에
    // 한꺼번에 채워지므로, 등장 애니메이션은 바디에서 sigma로 처리한다.
    return showGeneralDialog<MemberCardFocusResult>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '닫기',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (ctx, anim, secondary) {
        return _MemberCardFocusOverlayBody(
          member: member,
          canDeactivate: canDeactivate,
          isCurrentlyInactive: isCurrentlyInactive,
          initialMemo: initialMemo,
        );
      },
      transitionBuilder: (ctx, anim, secondary, child) => child,
    );
  }
}

class _MemberCardFocusOverlayBody extends StatefulWidget {
  final MemberView member;
  final bool canDeactivate;
  final bool isCurrentlyInactive;
  final String initialMemo;

  const _MemberCardFocusOverlayBody({
    required this.member,
    required this.canDeactivate,
    required this.isCurrentlyInactive,
    required this.initialMemo,
  });

  @override
  State<_MemberCardFocusOverlayBody> createState() =>
      _MemberCardFocusOverlayBodyState();
}

class _MemberCardFocusOverlayBodyState
    extends State<_MemberCardFocusOverlayBody>
    with SingleTickerProviderStateMixin {
  static const double _blurSigma = 8;
  static const double _dimOpacity = 0.52;

  bool _editingMemo = false;
  bool _phoneCopied = false;
  bool _closing = false;
  late final TextEditingController _memoController;
  late final FocusNode _memoFocus;
  late final AnimationController _enterCtrl;
  late final Animation<double> _enterAnim;

  @override
  void initState() {
    super.initState();
    _memoController = TextEditingController(text: widget.initialMemo);
    _memoFocus = FocusNode();
    _enterCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      reverseDuration: const Duration(milliseconds: 260),
    );
    _enterAnim = CurvedAnimation(
      parent: _enterCtrl,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _enterCtrl.forward();
  }

  @override
  void dispose() {
    _enterCtrl.dispose();
    _memoController.dispose();
    _memoFocus.dispose();
    super.dispose();
  }

  void _openMemoEditor() {
    setState(() => _editingMemo = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _memoFocus.requestFocus();
    });
  }

  void _closeMemoEditor() {
    _memoFocus.unfocus();
    setState(() => _editingMemo = false);
  }

  Future<void> _dismiss([MemberCardFocusResult? result]) async {
    if (_closing) return;
    _closing = true;
    _memoFocus.unfocus();
    try {
      await _enterCtrl.reverse();
    } catch (_) {
      // disposed during reverse
    }
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  void _saveMemo() {
    // 변경사항 없으면 서버 업로드 없이 그냥 닫는다.
    if (_memoController.text.trim() == widget.initialMemo.trim()) {
      _dismiss();
      return;
    }
    _dismiss(MemberCardFocusResult.memo(_memoController.text));
  }

  String _formatPhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length == 11) {
      return '${digits.substring(0, 3)}-${digits.substring(3, 7)}-${digits.substring(7)}';
    }
    if (digits.length == 10) {
      return '${digits.substring(0, 3)}-${digits.substring(3, 6)}-${digits.substring(6)}';
    }
    return raw;
  }

  String _digitsOnly(String raw) => raw.replaceAll(RegExp(r'[^0-9]'), '');

  Future<void> _callPhone() async {
    final digits = _digitsOnly(widget.member.phoneNumber);
    if (digits.isEmpty) return;
    final uri = Uri(scheme: 'tel', path: digits);
    try {
      final launched = await launchUrl(uri);
      if (!launched && mounted) {
        final ctx = navigatorKey.currentContext ?? context;
        SnackbarUtil.showInfo(ctx, '전화 앱을 열 수 없습니다.');
      }
    } catch (_) {
      if (!mounted) return;
      final ctx = navigatorKey.currentContext ?? context;
      SnackbarUtil.showInfo(ctx, '전화 앱을 열 수 없습니다.');
    }
  }

  Future<void> _copyPhone() async {
    final raw = widget.member.phoneNumber.trim();
    if (raw.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: raw));
    HapticFeedback.lightImpact();
    if (!mounted) return;
    setState(() => _phoneCopied = true);
    final ctx = navigatorKey.currentContext ?? context;
    SnackbarUtil.showSuccess(ctx, '클립보드에 복사되었습니다');
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _phoneCopied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    final panelBottom =
        keyboard > 0 ? keyboard + 12 : media.padding.bottom + 24;
    final memoPreview = widget.initialMemo.trim();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _closing) return;
        if (_editingMemo) {
          _closeMemoEditor();
          return;
        }
        await _dismiss();
      },
      child: Material(
        color: Colors.transparent,
        child: AnimatedBuilder(
          animation: _enterAnim,
          builder: (context, _) {
            final t = _enterAnim.value;
            final sigma = _blurSigma * t;
            return Stack(
              children: [
                // 블러: opacity fade가 아니라 sigma를 올려 부드럽게 등장
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () {
                      if (_editingMemo) {
                        _closeMemoEditor();
                      } else {
                        _dismiss();
                      }
                    },
                    behavior: HitTestBehavior.opaque,
                    child: BackdropFilter(
                      filter: ImageFilter.blur(
                        sigmaX: sigma.clamp(0.01, _blurSigma),
                        sigmaY: sigma.clamp(0.01, _blurSigma),
                      ),
                      child: Container(
                        color: Colors.black.withOpacity(_dimOpacity * t),
                      ),
                    ),
                  ),
                ),
                // 우상단 닫기
                Positioned(
                  top: media.padding.top + 12,
                  right: 16,
                  child: Opacity(
                    opacity: t,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => _dismiss(),
                        customBorder: const CircleBorder(),
                        child: Padding(
                          padding: const EdgeInsets.all(9),
                          child: Icon(
                            Icons.close_rounded,
                            size: 24,
                            color: Colors.white.withOpacity(0.9),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // 회원 정보 (메모 편집 중에는 숨김 — 패널에 작게 표시)
                if (!_editingMemo)
                  Positioned(
                    left: 28,
                    right: 28,
                    top: media.padding.top + 90,
                    child: Opacity(
                      opacity: t,
                      child: Transform.translate(
                        offset: Offset(0, 10 * (1 - t)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            IgnorePointer(
                              child: Text(
                                widget.member.adminDisplayName,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: -0.4,
                                  height: 1.2,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            if (widget.member.phoneNumber
                                .trim()
                                .isNotEmpty) ...[
                              const SizedBox(height: 4),
                              IgnorePointer(
                                child: Text(
                                  _formatPhone(widget.member.phoneNumber),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w400,
                                    letterSpacing: 0.2,
                                    color: Colors.white.withOpacity(0.72),
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 14),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (widget.member.phoneNumber
                                    .trim()
                                    .isNotEmpty) ...[
                                  _PhoneActionIcon(
                                    icon: Icons.phone_outlined,
                                    onTap: _callPhone,
                                  ),
                                  const SizedBox(width: 8),
                                  _PhoneActionIcon(
                                    icon:
                                        _phoneCopied
                                            ? Icons.check
                                            : Icons.copy_outlined,
                                    emphasized: _phoneCopied,
                                    onTap: _copyPhone,
                                  ),
                                ],
                                if (widget.isCurrentlyInactive) ...[
                                  if (widget.member.phoneNumber
                                      .trim()
                                      .isNotEmpty)
                                    const SizedBox(width: 10),
                                  IgnorePointer(
                                    child: _MetaChip(
                                      label: '비활성',
                                      emphasized: true,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            if (memoPreview.isNotEmpty) ...[
                              const SizedBox(height: 30),
                              _MemoPushBanner(
                                text: memoPreview,
                                onTap: _openMemoEditor,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                // 액션 / 메모 패널
                Positioned(
                  left: 40,
                  right: 40,
                  bottom: panelBottom,
                  child: Opacity(
                    opacity: t,
                    child: Transform.translate(
                      offset: Offset(0, 16 * (1 - t)),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 280),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, anim) {
                          final offset = Tween<Offset>(
                            begin: const Offset(0, 0.08),
                            end: Offset.zero,
                          ).animate(anim);
                          return FadeTransition(
                            opacity: anim,
                            child: SlideTransition(
                              position: offset,
                              child: child,
                            ),
                          );
                        },
                        child:
                            _editingMemo
                                ? _MemoEditorPanel(
                                  key: const ValueKey('memo'),
                                  controller: _memoController,
                                  focusNode: _memoFocus,
                                  memberName: widget.member.adminDisplayName,
                                  phoneLabel:
                                      widget.member.phoneNumber.trim().isEmpty
                                          ? null
                                          : _formatPhone(
                                            widget.member.phoneNumber,
                                          ),
                                  onSave: _saveMemo,
                                )
                                : _ActionsPanel(
                                  key: const ValueKey('actions'),
                                  isCurrentlyInactive:
                                      widget.isCurrentlyInactive,
                                  canDeactivate: widget.canDeactivate,
                                  onDeactivate:
                                      () => _dismiss(
                                        const MemberCardFocusResult.deactivate(),
                                      ),
                                  onWriteMemo: _openMemoEditor,
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
    );
  }
}

class _MemoPushBanner extends StatelessWidget {
  final String text;
  final VoidCallback onTap;

  const _MemoPushBanner({required this.text, required this.onTap});

  static const double _fontSize = 16;
  static const double _lineHeight = 1.45;
  static const double _viewportLines = 10.5;

  @override
  Widget build(BuildContext context) {
    final viewportHeight = _fontSize * _lineHeight * _viewportLines;
    return SizedBox(
      height: viewportHeight,
      width: double.infinity,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: _fontSize,
              height: _lineHeight,
              fontWeight: FontWeight.w400,
              color: Colors.white.withOpacity(0.9),
            ),
          ),
        ),
      ),
    );
  }
}

class _PhoneActionIcon extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool emphasized;

  const _PhoneActionIcon({
    required this.icon,
    required this.onTap,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withOpacity(0.32),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: 18,
            color:
                emphasized
                    ? const Color(0xFF8FE0B0)
                    : Colors.white.withOpacity(0.85),
          ),
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final String label;
  final bool emphasized;

  const _MetaChip({required this.label, this.emphasized = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(emphasized ? 0.22 : 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: Colors.white.withOpacity(emphasized ? 0.95 : 0.8),
        ),
      ),
    );
  }
}

class _ActionsPanel extends StatelessWidget {
  final bool isCurrentlyInactive;
  final bool canDeactivate;
  final VoidCallback onDeactivate;
  final VoidCallback onWriteMemo;

  const _ActionsPanel({
    super.key,
    required this.isCurrentlyInactive,
    required this.canDeactivate,
    required this.onDeactivate,
    required this.onWriteMemo,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ActionButton(
          label: isCurrentlyInactive ? '활성으로 복구' : '비활성 처리',
          icon:
              isCurrentlyInactive
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
          enabled: isCurrentlyInactive || canDeactivate,
          onTap: onDeactivate,
        ),
        const SizedBox(height: 12),
        _ActionButton(
          label: '메모 쓰기',
          icon: Icons.edit_note_outlined,
          enabled: true,
          onTap: onWriteMemo,
        ),
      ],
    );
  }
}

class _MemoEditorPanel extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String memberName;
  final String? phoneLabel;
  final VoidCallback onSave;

  const _MemoEditorPanel({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.memberName,
    required this.phoneLabel,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.92),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 8),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    memberName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                if (phoneLabel != null && phoneLabel!.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    phoneLabel!,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: AppColors.textSecondary.withOpacity(0.85),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  maxLines: 10,
                  minLines: 10,
                  textInputAction: TextInputAction.newline,
                  style: const TextStyle(
                    fontSize: 16,
                    height: 1.4,
                    fontWeight: FontWeight.w400,
                    color: AppColors.textPrimary,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '메모',
                    hintStyle: TextStyle(
                      color: AppColors.textSecondary.withOpacity(0.55),
                      fontSize: 16,
                      fontWeight: FontWeight.w400,
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: onSave,
                tooltip: '저장',
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.check_rounded,
                  size: 22,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Material(
          color: Colors.white.withOpacity(0.92),
          child: InkWell(
            onTap: enabled ? onTap : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: Row(
                children: [
                  Icon(icon, color: AppColors.textSecondary, size: 18),
                  const SizedBox(width: 12),
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
