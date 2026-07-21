import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:provider/provider.dart';
import 'package:reservation/theme/app_colors.dart';
import '../providers/notification_provider.dart';

/// 알림 아이콘 위젯 (공통)
class NotificationIconWidget extends StatelessWidget {
  final double size;
  final Color? color;

  const NotificationIconWidget({super.key, this.size = 26, this.color});

  @override
  Widget build(BuildContext context) {
    return Consumer<NotificationProvider>(
      builder: (context, notificationProvider, _) {
        final showBadge =
            notificationProvider.showUnreadBadge;
        return GestureDetector(
          onTap: () {
            Navigator.of(context).pushNamed('/notifications');
          },
          child: SizedBox(
            width: size,
            height: size,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                SvgPicture.asset(
                  'assets/icons/notifiction-icon.svg',
                  width: 24,
                  height: 24,
                  colorFilter: const ColorFilter.mode(
                    AppColors.textPrimary,
                    BlendMode.srcIn,
                  ),
                ),
                // Firestore 조회 후 미읽음이 있을 때만 빨간 점
                if (showBadge)
                  Positioned(
                    right: -2,
                    top: -2,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
