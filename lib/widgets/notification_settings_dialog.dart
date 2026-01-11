import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_colors.dart';
import '../utils/snackbar_util.dart';
import '../services/user_service.dart';
import '../providers/auth_provider.dart';

/// 알림 설정 다이얼로그
class NotificationSettingsDialog extends StatefulWidget {
  final bool initialValue;

  const NotificationSettingsDialog({super.key, required this.initialValue});

  static Future<bool?> show({
    required BuildContext context,
    required bool initialValue,
  }) {
    return showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.7),
      builder: (context) =>
          NotificationSettingsDialog(initialValue: initialValue),
    );
  }

  @override
  State<NotificationSettingsDialog> createState() =>
      _NotificationSettingsDialogState();
}

class _NotificationSettingsDialogState
    extends State<NotificationSettingsDialog> {
  late bool _currentValue;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _currentValue = widget.initialValue;
  }

  bool get _hasChanges => _currentValue != widget.initialValue;

  Future<void> _onConfirm() async {
    if (!_hasChanges || _isSaving) return;

    setState(() => _isSaving = true);

    try {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final userService = UserService();

      // 관리자인지 일반 사용자인지 확인
      final currentAdmin = authProvider.currentAdmin;
      final currentUser = authProvider.currentUser;

      if (currentAdmin != null) {
        // 관리자 정보 업데이트
        final updatedAdmin = currentAdmin.updateProfile(
          notificationsEnabled: _currentValue,
        );
        await userService.updateAdmin(updatedAdmin);

        // AuthProvider 업데이트
        authProvider.setCurrentAdmin(updatedAdmin);
      } else if (currentUser != null) {
        // 일반 사용자 정보 업데이트
        final updatedUser = currentUser.updateProfile(
          notificationsEnabled: _currentValue,
        );
        await userService.updateUser(updatedUser);

        // AuthProvider 업데이트
        authProvider.setCurrentUser(updatedUser);
      } else {
        SnackbarUtil.showError(context, '사용자 정보를 찾을 수 없습니다.');
        return;
      }

      if (mounted) {
        SnackbarUtil.showSuccess(
          context,
          _currentValue ? '알림이 켜졌습니다.' : '알림이 꺼졌습니다.',
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showError(context, '알림 설정 변경에 실패했습니다.');
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 알림 상태에 따라 배경색 변경
    // 켜져있을 때: 흰색 계열, 꺼져있을 때: 회색조
    final backgroundColor = _currentValue
        ? AppColors.backgroundWhite
        : AppColors.backgroundLight;

    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(24),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 토글 스위치
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    '알림 받기',
                    style: TextStyle(
                      fontSize: 18,
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Switch(
                  value: _currentValue,
                  onChanged: _isSaving
                      ? null
                      : (value) {
                          setState(() => _currentValue = value);
                        },
                  activeColor: AppColors.primaryGreen,
                ),
              ],
            ),
            const SizedBox(height: 16),

            // 설명 문구
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.textSecondary.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 18,
                    color: AppColors.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '알림을 해제하면 예약 및 중요 일람을 받지 못할 수 있어요',
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // 확인 버튼
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _hasChanges && !_isSaving ? _onConfirm : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryGreen,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppColors.textSecondary.withOpacity(
                    0.1,
                  ),
                  disabledForegroundColor: AppColors.textSecondary.withOpacity(
                    0.5,
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  elevation: 0,
                ),
                child: _isSaving
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
                        '확인',
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
    );
  }
}
