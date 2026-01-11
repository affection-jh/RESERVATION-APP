import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:reservation/services/user_service.dart';
import 'package:reservation/utils/text_field_decoration_util.dart';
import '../theme/app_colors.dart';
import '../utils/snackbar_util.dart';
import '../providers/auth_provider.dart';

/// 이름 변경 바텀시트
class NameEditBottomSheet extends StatefulWidget {
  final String initialName;

  const NameEditBottomSheet({super.key, required this.initialName});

  static void show({
    required BuildContext context,
    required String initialName,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.7),
      isDismissible: true,
      enableDrag: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: NameEditBottomSheet(initialName: initialName),
      ),
    );
  }

  @override
  State<NameEditBottomSheet> createState() => _NameEditBottomSheetState();
}

class _NameEditBottomSheetState extends State<NameEditBottomSheet> {
  final TextEditingController _nameController = TextEditingController();
  final FocusNode _nameFocusNode = FocusNode();
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _nameController.text = widget.initialName;
    // 화면 진입 시 자동으로 키보드 포커스
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _nameFocusNode.requestFocus();
      // 커서를 끝으로 이동
      _nameController.selection = TextSelection.fromPosition(
        TextPosition(offset: _nameController.text.length),
      );
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nameFocusNode.dispose();
    super.dispose();
  }

  bool _isFormValid() {
    return _nameController.text.trim().isNotEmpty &&
        _nameController.text.trim() != widget.initialName;
  }

  Future<void> _onSubmit() async {
    if (!_isFormValid() || _isSubmitting) return;

    final newName = _nameController.text.trim();
    if (newName == widget.initialName) {
      Navigator.of(context).pop();
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final currentAdmin = authProvider.currentAdmin;
      final currentUser = authProvider.currentUser;

      if (currentAdmin != null) {
        // 관리자 정보 업데이트
        final updatedAdmin = currentAdmin.updateProfile(name: newName);
        final userService = UserService();
        await userService.updateAdmin(updatedAdmin);

        // AuthProvider 업데이트
        authProvider.setCurrentAdmin(updatedAdmin);
      } else if (currentUser != null) {
        // 일반 사용자 정보 업데이트
        final updatedUser = currentUser.updateProfile(name: newName);
        final userService = UserService();
        await userService.updateUser(updatedUser);

        // AuthProvider 업데이트
        authProvider.setCurrentUser(updatedUser);
      } else {
        SnackbarUtil.showError(context, '사용자 정보를 찾을 수 없습니다.');
        Navigator.of(context).pop();
        return;
      }

      if (mounted) {
        SnackbarUtil.showSuccess(context, '이름이 변경되었습니다.');
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showError(context, '이름 변경에 실패했습니다.');
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
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
                  maxHeight: MediaQuery.of(context).size.height * 0.9,
                ),
                decoration: BoxDecoration(
                  color: AppColors.backgroundWhite,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 제목과 닫기 버튼
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            '이름 변경',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.of(context).pop(),
                            icon: Icon(
                              Icons.close,
                              color: AppColors.textSecondary,
                              size: 24,
                            ),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // 이름 입력 필드
                      TextField(
                        controller: _nameController,
                        focusNode: _nameFocusNode,
                        decoration: TextFieldDecorationUtil.defaultDecoration(
                          hintText: '이름을 입력하세요',

                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 16,
                          ),
                        ),
                        style: TextStyle(
                          fontSize: 16,
                          color: AppColors.textPrimary,
                        ),
                        textInputAction: TextInputAction.done,
                        onChanged: (_) =>
                            setState(() {}), // 텍스트 변경 시 버튼 상태 업데이트
                        onSubmitted: (_) => _onSubmit(),
                        inputFormatters: [LengthLimitingTextInputFormatter(20)],
                      ),
                      const SizedBox(height: 24),

                      // 저장 버튼
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _isFormValid() && !_isSubmitting
                              ? _onSubmit
                              : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primaryGreen,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: AppColors.textSecondary
                                .withOpacity(0.3),
                            disabledForegroundColor: AppColors.textSecondary
                                .withOpacity(0.5),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                            elevation: 0,
                          ),
                          child: _isSubmitting
                              ? SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      AppColors.primaryGreen,
                                    ),
                                  ),
                                )
                              : const Text(
                                  '저장',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 12),
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
}
