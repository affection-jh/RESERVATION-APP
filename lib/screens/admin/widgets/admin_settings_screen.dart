import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../theme/app_colors.dart';
import '../../../services/auth_service.dart';
import '../../../widgets/common_dialog.dart';
import '../../../providers/auth_provider.dart';

/// 관리자 설정 화면
class AdminSettingsScreen extends StatelessWidget {
  const AdminSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        leading: IconButton(
          onPressed: () {
            Navigator.pop(context);
          },
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            color: AppColors.textPrimary.withOpacity(0.75),
            size: 24,
          ),
        ),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 1. 일반 설정
          _buildSection(
            context,
            title: '일반',
            children: [
              _SettingTile(
                icon: Icons.notifications_outlined,
                label: '알림 설정',
                trailing: Text(
                  'ON',
                  style: TextStyle(
                    fontSize: 15,
                    color: AppColors.primaryGreen,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onTap: () {
                  // TODO: 알림 설정 토글
                },
              ),
              _SettingTile(
                icon: Icons.brightness_6_outlined,
                label: '테마 설정',
                trailing: Text(
                  '라이트',
                  style: TextStyle(
                    fontSize: 15,
                    color: AppColors.primaryGreen,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onTap: () {
                  // TODO: 테마 설정 토글
                },
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 2. 앱 정보
          _buildSection(
            context,
            title: '앱 정보',
            children: [
              _SettingTile(
                icon: Icons.info_outline,
                label: '앱 버전',
                trailing: Text(
                  '1.0.0',
                  style: TextStyle(
                    fontSize: 16,
                    color: AppColors.textSecondary,
                  ),
                ),
                showArrow: false,
                onTap: () {},
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 3. 기타
          _buildSection(
            context,
            title: '기타',
            children: [
              _SettingTile(
                icon: Icons.help_outline,
                label: '도움말',
                onTap: () {
                  // TODO: 도움말 화면으로 이동
                },
              ),
              _SettingTile(
                icon: Icons.description_outlined,
                label: '이용약관',
                onTap: () {
                  // TODO: 이용약관 화면으로 이동
                },
              ),
              _SettingTile(
                icon: Icons.article_outlined,
                label: '개인정보 처리방침',
                onTap: () {
                  // TODO: 개인정보 처리방침 화면으로 이동
                },
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 4. 계정 관리 (로그인 시: 로그아웃 / 비로그인 시: 로그인하기)
          _buildSection(
            context,
            title: '계정 관리',
            children: [
              Builder(
                builder: (context) {
                  final isLoggedIn =
                      Provider.of<AuthProvider>(context).isAuthenticated;
                  if (isLoggedIn) {
                    return _SettingTile(
                      icon: Icons.logout,
                      label: '로그아웃',
                      textColor: Colors.red,
                      onTap: () async {
                        final confirmed = await CommonDialog.show(
                          context: context,
                          title: '로그아웃',
                          message: '로그아웃 하시겠습니까?',
                          confirmText: '로그아웃',
                          cancelText: '취소',
                        );

                        if (confirmed == true && context.mounted) {
                          final authService = AuthService();
                          await authService.logout();
                          if (context.mounted) {
                            Navigator.pushNamedAndRemoveUntil(
                              context,
                              '/',
                              (route) => false,
                            );
                          }
                        }
                      },
                    );
                  }
                  return _SettingTile(
                    icon: Icons.login,
                    label: '로그인하기',
                    textColor: AppColors.primaryGreen,
                    onTap: () {
                      Navigator.pushNamedAndRemoveUntil(
                        context,
                        '/',
                        (route) => false,
                      );
                    },
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildSection(
    BuildContext context, {
    required String title,
    required List<Widget> children,
  }) {
    final dividerColor = AppColors.borderLight;

    // 타일 사이에 구분선 추가
    final childrenWithDividers = <Widget>[];
    for (int i = 0; i < children.length; i++) {
      childrenWithDividers.add(children[i]);
      if (i < children.length - 1) {
        childrenWithDividers.add(
          Padding(
            padding: const EdgeInsets.only(left: 58),
            child: Divider(height: 1, thickness: 1, color: dividerColor),
          ),
        );
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
                letterSpacing: 0.5,
              ),
            ),
          ),
          ...childrenWithDividers,
        ],
      ),
    );
  }
}

class _SettingTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool showArrow;
  final Color? textColor;

  const _SettingTile({
    required this.icon,
    required this.label,
    this.onTap,
    this.trailing,
    this.showArrow = true,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final tileTextColor = textColor ?? AppColors.textPrimary;

    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                size: 20,
                color: tileTextColor.withOpacity(0.75),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: tileTextColor,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            if (trailing != null) ...[trailing!, const SizedBox(width: 12)],
            if (showArrow)
              Icon(
                Icons.chevron_right,
                color: AppColors.textSecondary.withOpacity(0.3),
                size: 20,
              ),
          ],
        ),
      ),
    );
  }
}
