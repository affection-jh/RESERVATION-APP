import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../theme/app_colors.dart';
import '../constants/app_constants.dart';
import '../providers/auth_provider.dart';
import '../providers/enrollment_provider.dart';
import '../providers/member_provider.dart';
import '../providers/reservation_provider.dart';
import '../providers/reservation_summary_provider.dart';
import '../services/auth_service.dart';
import '../widgets/common_dialog.dart';
import '../utils/format_utils.dart';
import '../widgets/notification_settings_dialog.dart';
import '../widgets/name_edit_bottom_sheet.dart';
import '../widgets/place_switch_widget.dart' show navigateToPlaceWaitingScreen;
import '../utils/snackbar_util.dart';
import 'admin/widgets/place_registration_screen.dart';

/// 통합 설정 화면 (어드민 모드 / 일반 유저 모드 공통)
/// [embedded] true면 Scaffold/AppBar 없이 본문만 위젯으로 붙일 때 사용
class SettingScreen extends StatelessWidget {
  const SettingScreen({
    super.key,
    this.isAdminMode = false,
    this.embedded = false,
  });

  final bool isAdminMode;
  final bool embedded;

  static Widget _buildBody(bool isAdminMode) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _headerTitle('내 설정'),
          const SizedBox(height: 12),
          _ProfileSection(isAdminMode: isAdminMode),
          const SizedBox(height: 6),
          _AllTilesList(isAdminMode: isAdminMode),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (embedded) {
      return _buildBody(isAdminMode);
    }
    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            color: AppColors.textPrimary.withValues(alpha: 0.75),
            size: 24,
          ),
        ),
        title: Text(
          '설정',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _headerTitle('내 설정'),
          const SizedBox(height: 12),
          _ProfileSection(isAdminMode: isAdminMode),
          const SizedBox(height: 12),
          _AllTilesList(isAdminMode: isAdminMode),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

Widget _headerTitle(String title) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
    child: Text(
      title,
      style: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
    ),
  );
}

class _ProfileSection extends StatelessWidget {
  const _ProfileSection({required this.isAdminMode});

  final bool isAdminMode;

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);
    final user =
        isAdminMode ? authProvider.currentAdmin : authProvider.currentUser;
    if (user == null) return const SizedBox.shrink();

    return _ProfileCard(
      name: user.username,
      phoneNumber: user.phoneNumber,
      onTap: () {
        NameEditBottomSheet.show(context: context, initialName: user.username);
      },
    );
  }
}

/// 섹션 없이 모든 설정 타일을 한 카드에 나열
class _AllTilesList extends StatelessWidget {
  const _AllTilesList({required this.isAdminMode});

  final bool isAdminMode;

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);
    final isNotificationEnabled =
        (authProvider.currentUser?.notificationsEnabled ??
            authProvider.currentAdmin?.notificationsEnabled ??
            true);
    final hasFirebaseUser = AuthService().currentFirebaseUser != null;
    final hasUser =
        isAdminMode
            ? authProvider.currentAdmin != null
            : authProvider.currentUser != null;
    final isLoggedIn = hasUser && hasFirebaseUser;

    final tiles = <Widget>[
      _SettingTile(
        icon: Icons.notifications_outlined,
        label: '알림 설정',
        trailing: Text(
          isNotificationEnabled ? 'ON' : 'OFF',
          style: const TextStyle(
            fontSize: 15,
            color: AppColors.primaryGreen,
            fontWeight: FontWeight.w500,
          ),
        ),
        showArrow: false,
        onTap: () async {
          final result = await NotificationSettingsDialog.show(
            context: context,
            initialValue: isNotificationEnabled,
          );
          if (result == true && context.mounted) {}
        },
      ),

      _SettingTile(
        icon: Icons.info_outline,
        label: '앱 버전',
        trailing: Text(
          AppConfig.appVersion,
          style: const TextStyle(
            fontSize: 15,
            color: AppColors.primaryGreen,
            fontWeight: FontWeight.w500,
          ),
        ),
        showArrow: false,
        onTap: () {},
      ),
      _SettingTile(
        icon: Icons.storefront_outlined,
        label: '초대된 플레이스',
        onTap: () {
          final authProvider = Provider.of<AuthProvider>(
            context,
            listen: false,
          );
          navigateToPlaceWaitingScreen(
            context,
            authProvider,
            skipAutoEnter: true,
          );
        },
      ),

      _SettingTile(
        icon: Icons.description_outlined,
        label: '이용약관',
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
      _SettingTile(
        icon: Icons.article_outlined,
        label: '개인정보 처리방침',
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
    ];

    if (isAdminMode) {
      tiles.add(
        _SettingTile(
          icon: Icons.add_circle_outline,
          label: '플레이스 추가',
          onTap: () => _handlePlaceTap(context),
        ),
      );
    }

    if (isLoggedIn) {
      tiles.add(
        _SettingTile(
          icon: Icons.logout,
          label: '로그아웃',
          textColor: Colors.red,
          onTap: () => _logout(context),
        ),
      );
      tiles.add(
        _SettingTile(
          icon: Icons.person_remove_outlined,
          label: '회원탈퇴',
          textColor: Colors.red,
          onTap: () => _withdraw(context, isAdminMode),
        ),
      );
    } else {
      tiles.add(
        _SettingTile(
          icon: Icons.login,
          label: '로그인하기',
          textColor: AppColors.primaryGreen,
          onTap: () {
            Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
          },
        ),
      );
    }

    final withDividers = <Widget>[];
    for (var i = 0; i < tiles.length; i++) {
      withDividers.add(tiles[i]);
      if (i < tiles.length - 1) {
        withDividers.add(
          Padding(
            padding: const EdgeInsets.only(left: 58),
            child: Divider(
              height: 1,
              thickness: 1,
              color: AppColors.borderLight,
            ),
          ),
        );
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: withDividers,
      ),
    );
  }
}

/// 프로필 카드 위젯 (이름, 전화번호, 하단 위젯)
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.name,
    required this.phoneNumber,
    required this.onTap,
  });

  final String name;
  final String phoneNumber;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.backgroundWhite,
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    FormatUtils.formatPhoneNumber(phoneNumber),
                    style: TextStyle(
                      fontSize: 16,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Icon(
                Icons.chevron_right,
                color: AppColors.textSecondary.withValues(alpha: 0.3),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 설정 액션 (최상위 함수 - _AllTilesList에서 호출)
// ---------------------------------------------------------------------------

void _handlePlaceTap(BuildContext context) {
  final authProvider = Provider.of<AuthProvider>(context, listen: false);
  final currentUser = authProvider.currentUser;
  final phoneNumber = currentUser?.phoneNumber ?? '';

  if (phoneNumber.isEmpty) {
    Navigator.of(
      context,
    ).pushNamed('/phone-number', arguments: {'isPlaceRegistrationFlow': true});
    return;
  }

  final isAlreadyAdmin = authProvider.currentAdmin != null;
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder:
          (context) => AdminPlaceRegistrationScreen(
            phoneNumber: phoneNumber,
            isFromLogin: !isAlreadyAdmin,
          ),
    ),
  );
}

Future<void> _logout(BuildContext context) async {
  final confirmed = await CommonDialog.show(
    context: context,
    title: '로그아웃',
    message: '로그아웃 하시겠습니까?',
    confirmText: '로그아웃',
    cancelText: '취소',
  );
  if (confirmed != true || !context.mounted) return;

  final authProvider = Provider.of<AuthProvider>(context, listen: false);
  final memberProvider = Provider.of<MemberProvider>(context, listen: false);
  final reservationProvider = Provider.of<ReservationProvider>(
    context,
    listen: false,
  );
  final enrollmentProvider = Provider.of<EnrollmentProvider>(
    context,
    listen: false,
  );
  final summaryProvider = Provider.of<ReservationSummaryProvider>(
    context,
    listen: false,
  );

  final phoneNumber = authProvider.currentUser?.phoneNumber ?? '';
  await authProvider.logout();
  memberProvider.clear();
  summaryProvider.clear();
  await reservationProvider.clear();
  await enrollmentProvider.clear();

  if (context.mounted) {
    Navigator.of(context).pushNamedAndRemoveUntil(
      '/place-waiting',
      (route) => false,
      arguments: phoneNumber,
    );
  }
}

Future<void> _withdraw(BuildContext context, bool isAdminMode) async {
  final confirmed = await CommonDialog.show(
    context: context,
    title: '회원탈퇴',
    message: '정말 탈퇴 하시겠습니까?\n모든 데이터가 삭제됩니다.',
    confirmText: '탈퇴하기',
    cancelText: '취소',
    confirmButtonColor: Colors.red,
  );
  if (confirmed != true || !context.mounted) return;

  final authProvider = Provider.of<AuthProvider>(context, listen: false);
  final user =
      isAdminMode ? authProvider.currentAdmin : authProvider.currentUser;

  if (user == null) {
    SnackbarUtil.showInfo(context, '사용자 정보를 찾을 수 없습니다.');
    return;
  }

  SnackbarUtil.showLoading(context, '탈퇴중');

  try {
    final callable = FirebaseFunctions.instance.httpsCallable(
      'deleteUserAccount',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 60)),
    );
    await callable.call({'userId': user.userId});
    await authProvider.logout();
    final reservationProvider = Provider.of<ReservationProvider>(
      context,
      listen: false,
    );
    final enrollmentProvider = Provider.of<EnrollmentProvider>(
      context,
      listen: false,
    );
    final summaryProvider = Provider.of<ReservationSummaryProvider>(
      context,
      listen: false,
    );
    summaryProvider.clear();
    await reservationProvider.clear();
    await enrollmentProvider.clear();

    if (context.mounted) {
      SnackbarUtil.showSuccess(context, '회원탈퇴가 완료되었습니다.');
      Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
    }
  } catch (e) {
    if (context.mounted) {
      String message = '회원탈퇴 중 오류가 발생했습니다.';
      if (e is FirebaseFunctionsException &&
          (e.message ?? '').trim().isNotEmpty) {
        message = e.message!.trim();
      } else {
        try {
          final msg = (e as dynamic).message?.toString();
          if (msg != null && msg.trim().isNotEmpty) {
            message = msg.trim();
          }
        } catch (_) {}
      }
      SnackbarUtil.showInfo(context, message);
    }
  } finally {
    SnackbarUtil.dismissLoading();
  }
}

// ---------------------------------------------------------------------------
// Shared UI
// ---------------------------------------------------------------------------

class _SettingTile extends StatelessWidget {
  const _SettingTile({
    required this.icon,
    required this.label,
    this.onTap,
    this.trailing,
    this.showArrow = true,
    this.textColor,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool showArrow;
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    final tileColor = textColor ?? AppColors.textPrimary;

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
                color: tileColor.withValues(alpha: 0.75),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: tileColor,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            if (trailing != null) ...[trailing!, const SizedBox(width: 12)],
            if (showArrow)
              Icon(
                Icons.chevron_right,
                color: AppColors.textSecondary.withValues(alpha: 0.3),
                size: 20,
              ),
          ],
        ),
      ),
    );
  }
}
