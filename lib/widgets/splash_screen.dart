import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shimmer/shimmer.dart';
import '../theme/app_colors.dart';

/// 스플래시 스크린 위젯 (캘린더 아이콘 쉬머 애니메이션)
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late AnimationController _shimmerController;
  late AnimationController _colorController;
  late Animation<Color?> _colorAnimation;

  @override
  void initState() {
    super.initState();

    // 쉬머 효과용 컨트롤러
    _shimmerController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );

    // 색상 전환용 컨트롤러
    _colorController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );

    // 회색에서 검정색으로 부드럽게 전환
    _colorAnimation = ColorTween(begin: Colors.grey[400], end: Colors.black)
        .animate(
          CurvedAnimation(parent: _colorController, curve: Curves.easeInOut),
        );

    // 쉬머 효과 후 색상 전환 시작
    _shimmerController.forward().then((_) {
      if (mounted) {
        _colorController.forward();
      }
    });
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    _colorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      body: Center(
        child: AnimatedBuilder(
          animation: _colorAnimation,
          builder: (context, child) {
            // 쉬머 효과가 진행 중이면 쉬머 표시
            if (_shimmerController.isAnimating) {
              return Shimmer.fromColors(
                baseColor: Colors.grey[300]!,
                highlightColor: Colors.grey[100]!,
                period: const Duration(milliseconds: 800),
                child: SvgPicture.asset(
                  'assets/icons/calendar-icon.svg',
                  width: 80,
                  height: 80,
                  colorFilter: ColorFilter.mode(
                    Colors.grey[400]!,
                    BlendMode.srcIn,
                  ),
                ),
              );
            }

            // 색상 전환 애니메이션
            return SvgPicture.asset(
              'assets/icons/calendar-icon.svg',
              width: 80,
              height: 80,
              colorFilter: ColorFilter.mode(
                _colorAnimation.value ?? Colors.black,
                BlendMode.srcIn,
              ),
            );
          },
        ),
      ),
    );
  }
}
