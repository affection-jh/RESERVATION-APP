import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../utils/snackbar_util.dart';

/// 일반 확인 다이얼로그
class CommonDialog extends StatelessWidget {
  final String title;
  final String message;
  final String? secondaryMessage;
  final String cancelText;
  final String confirmText;
  final VoidCallback? onCancel;
  final VoidCallback? onConfirm;
  final Color? confirmButtonColor;

  const CommonDialog({
    super.key,
    required this.title,
    required this.message,
    this.secondaryMessage,
    this.cancelText = '취소',
    this.confirmText = '확인',
    this.onCancel,
    this.onConfirm,
    this.confirmButtonColor,
  });

  /// 저장/로딩 중 뒤로가기 시 "저장 중입니다. 나가시겠습니까?" 다이얼로그
  /// 취소 → 다이얼로그만 닫음. 나가기 → onLeave 호출 후 true 반환 (호출측에서 pop)
  static Future<bool> showSavingLeaveConfirm({
    required BuildContext context,
    String title = '저장 중입니다',
    String message = '변경사항이 저장되지 않을 수 있습니다.\n정말 나가시겠습니까?',
    String cancelText = '취소',
    String leaveText = '나가기',
    VoidCallback? onLeave,
  }) async {
    final result = await show(
      context: context,
      title: title,
      message: message,
      cancelText: cancelText,
      confirmText: leaveText,
      confirmButtonColor: Colors.red,
      onCancel: () {},
      onConfirm: () {
        onLeave?.call();
      },
    );
    return result == true;
  }

  static Future<bool?> show({
    required BuildContext context,
    required String title,
    required String message,
    String? secondaryMessage,
    String cancelText = '취소',
    String confirmText = '확인',
    VoidCallback? onCancel,
    VoidCallback? onConfirm,
    Color? confirmButtonColor,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => CommonDialog(
            title: title,
            message: message,
            secondaryMessage: secondaryMessage,
            cancelText: cancelText,
            confirmText: confirmText,
            onCancel: onCancel,
            onConfirm: onConfirm,
            confirmButtonColor: confirmButtonColor,
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 제목
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          // 메시지
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                Text(
                  message,
                  style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
                  textAlign: TextAlign.center,
                ),
                if (secondaryMessage != null) ...[
                  Text(
                    secondaryMessage!,
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.textSecondary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 32),
          // 버튼
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () {
                    Navigator.of(context).pop(false);
                    onCancel?.call();
                  },
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(20),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color: AppColors.backgroundLight,
                      borderRadius: const BorderRadius.only(
                        bottomLeft: Radius.circular(20),
                      ),
                    ),
                    child: Text(
                      cancelText,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: InkWell(
                  onTap: () {
                    Navigator.of(context).pop(true);
                    onConfirm?.call();
                  },
                  borderRadius: const BorderRadius.only(
                    bottomRight: Radius.circular(20),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color: confirmButtonColor ?? AppColors.textPrimary,
                      borderRadius: const BorderRadius.only(
                        bottomRight: Radius.circular(20),
                      ),
                    ),
                    child: Text(
                      confirmText,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.backgroundWhite,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 제한되는 멤버만 "이름: 사유"로 명시. 취소 / 한 번에 모두 추가 2버튼. 공통 다이얼로그 스타일.
/// [restrictedEntries] 각 항목: { displayName, reason }
/// 반환: 'cancel' | 'forceAll'
class BatchAddConfirmDialog extends StatelessWidget {
  final String title;
  final List<MapEntry<String, String>> restrictedEntries;
  final String cancelText;
  final String forceAllText;

  const BatchAddConfirmDialog({
    super.key,
    required this.title,
    required this.restrictedEntries,
    this.cancelText = '취소',
    this.forceAllText = '한 번에 모두 추가',
  });

  static Future<String?> show({
    required BuildContext context,
    required String title,
    required List<MapEntry<String, String>> restrictedEntries,
    String cancelText = '취소',
    String forceAllText = '한 번에 모두 추가',
  }) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => BatchAddConfirmDialog(
            title: title,
            restrictedEntries: restrictedEntries,
            cancelText: cancelText,
            forceAllText: forceAllText,
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 12),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              '아래 멤버는 다음과 같은 사유로 제한됩니다.',
              style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children:
                    restrictedEntries
                        .map(
                          (e) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Text(
                              '· ${e.key}: ${e.value}',
                              style: TextStyle(
                                fontSize: 14,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                        )
                        .toList(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              '관리자 권한으로 한 번에 추가하시겠습니까?',
              style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => Navigator.of(context).pop('cancel'),
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(20),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color: AppColors.backgroundLight,
                      borderRadius: const BorderRadius.only(
                        bottomLeft: Radius.circular(20),
                      ),
                    ),
                    child: Text(
                      cancelText,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: InkWell(
                  onTap: () => Navigator.of(context).pop('forceAll'),
                  borderRadius: const BorderRadius.only(
                    bottomRight: Radius.circular(20),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color: AppColors.primaryGreen,
                      borderRadius: const BorderRadius.only(
                        bottomRight: Radius.circular(20),
                      ),
                    ),
                    child: Text(
                      forceAllText,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.backgroundWhite,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 텍스트 필드가 있는 확인 다이얼로그
class CommonDialogWithTextField extends StatefulWidget {
  final String title;
  final String message;
  final String? secondaryMessage;
  final String hintText;
  final String cancelText;
  final String confirmText;
  final VoidCallback? onCancel;
  final Function(String)? onConfirm;
  final Color? confirmButtonColor;
  final int maxLines;
  final String? expectedText; // 삭제 확인용: 입력값이 이 값과 정확히 일치해야 함

  const CommonDialogWithTextField({
    super.key,
    required this.title,
    required this.message,
    this.secondaryMessage,
    required this.hintText,
    this.cancelText = '취소',
    this.confirmText = '확인',
    this.onCancel,
    this.onConfirm,
    this.confirmButtonColor,
    this.maxLines = 3,
    this.expectedText,
  });

  static Future<String?> show({
    required BuildContext context,
    required String title,
    required String message,
    String? secondaryMessage,
    required String hintText,
    String cancelText = '취소',
    String confirmText = '확인',
    VoidCallback? onCancel,
    Function(String)? onConfirm,
    Color? confirmButtonColor,
    int maxLines = 3,
    String? expectedText,
  }) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => CommonDialogWithTextField(
            title: title,
            message: message,
            secondaryMessage: secondaryMessage,
            hintText: hintText,
            cancelText: cancelText,
            confirmText: confirmText,
            onCancel: onCancel,
            onConfirm: onConfirm,
            confirmButtonColor: confirmButtonColor,
            maxLines: maxLines,
            expectedText: expectedText,
          ),
    );
  }

  @override
  State<CommonDialogWithTextField> createState() =>
      _CommonDialogWithTextFieldState();
}

class _CommonDialogWithTextFieldState extends State<CommonDialogWithTextField> {
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      setState(() {}); // 입력값 변경 시 UI 업데이트
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isConfirmEnabled {
    final text = _controller.text.trim();
    if (widget.expectedText != null) {
      // expectedText가 있으면 정확히 일치해야 함
      return text == widget.expectedText;
    }
    // expectedText가 없으면 기존 로직 (비어있지 않으면 활성화)
    return text.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 제목
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
            child: Text(
              widget.title,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          // 메시지
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                Text(
                  widget.message,
                  style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
                  textAlign: TextAlign.center,
                ),
                if (widget.secondaryMessage != null) ...[
                  Text(
                    widget.secondaryMessage!,
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.textSecondary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          // 텍스트 필드
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              hintText: widget.hintText,
              hintStyle: TextStyle(
                fontSize: 14,
                color: AppColors.textSecondary,
              ),
              filled: true,
              fillColor: AppColors.backgroundLight,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.zero,
                borderSide: BorderSide(color: AppColors.borderLight),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.zero,
                borderSide: BorderSide(color: Colors.transparent),
              ),

              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.zero,
                borderSide: BorderSide(color: Colors.transparent),
              ),

              contentPadding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 12,
              ),
            ),
            style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
            maxLines: widget.maxLines,
          ),

          // 버튼
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.onCancel?.call();
                  },
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(20),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color: AppColors.backgroundLight,
                      borderRadius: const BorderRadius.only(
                        bottomLeft: Radius.circular(20),
                      ),
                    ),
                    child: Text(
                      widget.cancelText,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: InkWell(
                  onTap:
                      _isConfirmEnabled
                          ? () {
                            final text = _controller.text.trim();
                            if (text.isEmpty) {
                              SnackbarUtil.showInfo(
                                context,
                                '${widget.hintText}을(를) 입력해주세요.',
                              );
                              return;
                            }
                            Navigator.of(context).pop(text);
                            widget.onConfirm?.call(text);
                          }
                          : null,
                  borderRadius: const BorderRadius.only(
                    bottomRight: Radius.circular(20),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color:
                          _isConfirmEnabled
                              ? (widget.confirmButtonColor ??
                                  AppColors.textPrimary)
                              : AppColors.borderLight,
                      borderRadius: const BorderRadius.only(
                        bottomRight: Radius.circular(20),
                      ),
                    ),
                    child: Text(
                      widget.confirmText,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color:
                            _isConfirmEnabled
                                ? AppColors.backgroundWhite
                                : AppColors.textSecondary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
