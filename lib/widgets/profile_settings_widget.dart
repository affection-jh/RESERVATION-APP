import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_colors.dart';
import '../widgets/common_dialog.dart';
import '../screens/admin/widgets/admin_shared_widgets.dart' show SectionHeader;
import '../constants/app_constants.dart';
import '../screens/admin/widgets/admin_pin_verify_for_place_screen.dart';
import '../screens/admin/admin_pin_register_screen.dart';
import '../providers/auth_provider.dart';

/// 프로필 섹션 위젯 (공통)
class ProfileSection extends StatelessWidget {
  final String name;
  final String phoneNumber;
  final VoidCallback? onTap; // 이름 또는 전화번호 클릭 시 (프로필 편집 바텀시트 열기)
  final Widget? bottomWidget; // 이름/전화번호 아래에 표시할 위젯 (예: PlaceSwitchWidget)

  const ProfileSection({
    super.key,
    required this.name,
    required this.phoneNumber,
    this.onTap,
    this.bottomWidget,
  });

  /// 전화번호 포맷팅 (010-1234-5678 형식)
  String _formatPhoneNumber(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length <= 3) {
      return digits;
    } else if (digits.length <= 7) {
      return '${digits.substring(0, 3)}-${digits.substring(3)}';
    } else if (digits.length <= 11) {
      return '${digits.substring(0, 3)}-${digits.substring(3, 7)}-${digits.substring(7)}';
    } else {
      return '${digits.substring(0, 3)}-${digits.substring(3, 7)}-${digits.substring(7, 11)}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                // 프로필 정보
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              name,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Text(
                        // 로그인 안 된 경우 메시지는 포맷팅하지 않음
                        phoneNumber.contains('로그인하고')
                            ? phoneNumber
                            : _formatPhoneNumber(phoneNumber),
                        style: TextStyle(
                          fontSize: 14,
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
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

/// 설정 항목 위젯 (공통)
class SettingItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final Widget? trailing;
  final bool showArrow;
  final Color? textColor;

  const SettingItem({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.trailing,
    this.showArrow = true,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        child: Row(
          children: [
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  color: textColor ?? AppColors.textSecondary,
                ),
              ),
            ),
            if (trailing != null) ...[trailing!, const SizedBox(width: 12)],
            if (showArrow)
              Icon(
                Icons.chevron_right,
                color: AppColors.textSecondary,
                size: 24,
              ),
          ],
        ),
      ),
    );
  }
}

/// 설정 섹션 위젯 (공통)
class SettingsSection extends StatelessWidget {
  final List<SettingItem> items;

  const SettingsSection({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          ...items,
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// 설정 항목 리스트 생성 (공통)
class SettingsItemsBuilder {
  /// 플레이스 탭 처리
  static void _handlePlaceTap(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final admin = authProvider.currentAdmin;
    final currentUser = authProvider.currentUser;

    // 관리자로 등록되어 있으면 핀 확인 화면으로
    if (admin != null) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => const AdminPinVerifyForPlaceScreen(),
        ),
      );
      return;
    }

    // 관리자로 등록되지 않았으면 핀 등록 화면으로 바로 이동
    // 전화번호는 현재 로그인된 사용자 또는 관리자의 전화번호 사용
    final phoneNumber = currentUser?.phoneNumber ?? '';
    if (phoneNumber.isEmpty) {
      // 전화번호가 없으면 전화번호 인증부터 시작
      Navigator.of(context).pushNamed(
        '/phone-number',
        arguments: {'isPlaceRegistrationFlow': true},
      );
      return;
    }

    // 전화번호가 있으면 핀 등록 화면으로 바로 이동 (인증 없이)
    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (context) => AdminPinRegisterScreen(
              phoneNumber: phoneNumber,
              verificationCode: '', // 인증 코드 불필요
            ),
      ),
    );
  }

  /// 일반 설정 항목 리스트 생성
  ///
  /// [context] - BuildContext
  /// [isNotificationEnabled] - 알림 설정 상태 (null이면 하드코딩된 'ON' 표시)
  /// [onNotificationTap] - 알림 설정 탭 콜백 (null이면 TODO 처리)
  /// [onLogout] - 로그아웃 콜백 (null이면 로그아웃 항목 표시 안 함)
  /// [onWithdraw] - 회원탈퇴 콜백 (선택적, null이면 회원탈퇴 항목 표시 안 함)
  static List<SettingItem> buildSettingsItems({
    required BuildContext context,
    bool? isNotificationEnabled,
    VoidCallback? onNotificationTap,
    Future<void> Function()? onLogout,
    Future<void> Function()? onWithdraw,
  }) {
    return [
      // 알림 설정
      SettingItem(
        icon: Icons.notifications_outlined,
        title: '알림 설정',
        trailing: Text(
          isNotificationEnabled != null
              ? (isNotificationEnabled ? 'ON' : 'OFF')
              : 'ON',
          style: TextStyle(
            fontSize: 15,
            color:
                isNotificationEnabled != null
                    ? (isNotificationEnabled
                        ? AppColors.primaryGreen
                        : AppColors.textSecondary)
                    : AppColors.primaryGreen,
            fontWeight: FontWeight.w500,
          ),
        ),
        showArrow: false,
        onTap:
            onNotificationTap ??
            () {
              // TODO: 알림 설정 토글
            },
      ),

      // 앱 정보
      SettingItem(
        icon: Icons.info_outline,
        title: '앱 버전',
        trailing: Text(
          '1.0.0',
          style: TextStyle(
            fontSize: 16,
            color: AppColors.primaryGreen,
            fontWeight: FontWeight.w500,
          ),
        ),
        showArrow: false,
        onTap: () {},
      ),

      SettingItem(
        icon: Icons.description_outlined,
        title: '이용약관',
        onTap: () {
          Navigator.of(context).pushNamed(
            '/webview',
            arguments: {
              'url': AppConstants.termsAndPrivacyUrl,
              'title': '이용약관',
            },
          );
        },
      ),

      SettingItem(
        icon: Icons.article_outlined,
        title: '개인정보 처리방침',
        onTap: () {
          Navigator.of(context).pushNamed(
            '/webview',
            arguments: {
              'url': AppConstants.termsAndPrivacyUrl,
              'title': '개인정보 처리방침',
            },
          );
        },
      ),

      // 플레이스 추가
      SettingItem(
        icon: Icons.add_business,
        title: '플레이스 추가',
        onTap: () {
          _handlePlaceTap(context);
        },
      ),

      // 로그아웃 (onLogout이 제공된 경우에만 표시)
      if (onLogout != null)
        SettingItem(
          icon: Icons.logout,
          title: '로그아웃',
          onTap: () async {
            final confirmed = await CommonDialog.show(
              context: context,
              title: '로그아웃',
              message: '로그아웃 하시겠습니까?',
              confirmText: '로그아웃',
              cancelText: '취소',
            );

            if (confirmed == true && context.mounted) {
              await onLogout();
              if (context.mounted) {
                Navigator.pushNamedAndRemoveUntil(
                  context,
                  '/',
                  (route) => false,
                );
              }
            }
          },
          textColor: Colors.red,
        ),

      // 회원탈퇴 (onWithdraw가 제공된 경우에만 표시)
      if (onWithdraw != null)
        SettingItem(
          icon: Icons.person_remove_outlined,
          title: '회원탈퇴',
          onTap: () async {
            final confirmed = await CommonDialog.show(
              context: context,
              title: '회원탈퇴',
              message: '정말 회원탈퇴를 하시겠습니까?\n탈퇴 후 모든 데이터가 삭제되며\n복구할 수 없습니다.',
              confirmText: '탈퇴하기',
              cancelText: '취소',
              confirmButtonColor: Colors.red,
            );

            if (confirmed == true && context.mounted) {
              await onWithdraw();
            }
          },
          textColor: Colors.red,
        ),
    ];
  }
}

/// 사용자 프로필 정보 섹션 (공통 위젯)
///
/// 헤더, 프로필, 설정, 회원탈퇴 버튼을 포함한 전체 섹션
class UserProfileInfoSection extends StatelessWidget {
  /// 섹션 헤더 타이틀
  final String headerTitle;

  /// 프로필 이름
  final String profileName;

  /// 프로필 전화번호
  final String profilePhoneNumber;

  /// 프로필 탭 콜백 (null이면 편집 불가)
  final VoidCallback? onProfileTap;

  /// 프로필 하단 위젯 (예: PlaceSwitchWidget)
  final Widget? profileBottomWidget;

  /// 설정 항목 리스트
  final List<SettingItem> settingsItems;

  /// 회원탈퇴 버튼 표시 여부
  final bool showWithdrawButton;

  /// 회원탈퇴 콜백
  final Future<void> Function()? onWithdraw;

  const UserProfileInfoSection({
    super.key,
    required this.headerTitle,
    required this.profileName,
    required this.profilePhoneNumber,
    this.onProfileTap,
    this.profileBottomWidget,
    required this.settingsItems,
    this.showWithdrawButton = false,
    this.onWithdraw,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: headerTitle,
          onIconTap: () {},
          icon: null,
          horizontalPadding: 20,
          fontSize: 19,
        ),
        const SizedBox(height: 12),

        // 프로필 섹션
        ProfileSection(
          name: profileName,
          phoneNumber: profilePhoneNumber,
          onTap: onProfileTap,
          bottomWidget: profileBottomWidget,
        ),

        const SizedBox(height: 6),

        // 설정 섹션
        SettingsSection(items: settingsItems),

        // 회원탈퇴 버튼 (선택적)
        if (showWithdrawButton && onWithdraw != null) ...[
          const SizedBox(height: 10),
          _buildWithdrawButton(context),
        ],
      ],
    );
  }

  Widget _buildWithdrawButton(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: TextButton(
        onPressed: () async {
          final confirmed = await CommonDialog.show(
            context: context,
            title: '회원탈퇴',
            message: '정말 회원탈퇴를 하시겠습니까?\n탈퇴 후 모든 데이터가 삭제되며\n복구할 수 없습니다.',
            confirmText: '탈퇴하기',
            cancelText: '취소',
            confirmButtonColor: Colors.red,
          );

          if (confirmed == true && context.mounted) {
            await onWithdraw!();
          }
        },
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 0),
        ),
        child: Text(
          '회원탈퇴',
          style: TextStyle(
            fontSize: 16,
            color: AppColors.textSecondary,
            decoration: TextDecoration.underline,
            decorationColor: AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}
