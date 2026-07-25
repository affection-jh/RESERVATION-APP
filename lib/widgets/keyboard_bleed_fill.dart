import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// iOS 26+ 둥근·반투명 키보드 모서리로 배리어/딤이 비치는 갭을
/// 시트와 같은 색으로 메우는 래퍼.
///
/// `Padding(bottom: viewInsets)` 등으로 키보드 위로 올린 **시트 본체**를 감싼다.
///
/// 키보드 on/off 때 위젯 트리 구조가 바뀌면 TextField가 재생성되어
/// 포커스가 끊기므로, 항상 동일한 [Stack] 구조를 유지한다.
///
/// 참고: https://docs.flutter.dev/go/ios-26-keyboard-bleed
class KeyboardBleedFill extends StatelessWidget {
  final Widget child;
  final Color color;

  const KeyboardBleedFill({
    super.key,
    required this.child,
    this.color = AppColors.backgroundWhite,
  });

  @override
  Widget build(BuildContext context) {
    final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          left: 0,
          right: 0,
          bottom: -keyboardHeight,
          height: keyboardHeight,
          child: IgnorePointer(child: ColoredBox(color: color)),
        ),
      ],
    );
  }
}
