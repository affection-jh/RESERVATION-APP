import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme/app_colors.dart';

class AdminBottomNavBar extends StatelessWidget {
  final int currentIndex;
  final Function(int) onTap;

  const AdminBottomNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final selectedColor = AppColors.primaryGreen;
    final unselectedColor = AppColors.textLight;

    return BottomNavigationBar(
      currentIndex: currentIndex,
      onTap: onTap,
      type: BottomNavigationBarType.fixed,
      selectedItemColor: selectedColor,
      unselectedItemColor: unselectedColor,
      items: [
        BottomNavigationBarItem(
          icon: SvgPicture.asset(
            'assets/icons/home-icon.svg',
            colorFilter: ColorFilter.mode(
              currentIndex == 0 ? selectedColor : unselectedColor,
              BlendMode.srcIn,
            ),
            width: 24,
            height: 24,
          ),
          label: '홈',
        ),
        BottomNavigationBarItem(
          icon: SvgPicture.asset(
            'assets/icons/member-icon.svg',
            colorFilter: ColorFilter.mode(
              currentIndex == 1 ? selectedColor : unselectedColor,
              BlendMode.srcIn,
            ),
            width: 20,
            height: 20,
          ),
          label: '회원',
        ),
        BottomNavigationBarItem(
          icon: SvgPicture.asset(
            'assets/icons/profile-icon.svg',
            colorFilter: ColorFilter.mode(
              currentIndex == 2 ? selectedColor : unselectedColor,
              BlendMode.srcIn,
            ),
            width: 24,
            height: 24,
          ),
          label: '마이페이지',
        ),
      ],
    );
  }
}
