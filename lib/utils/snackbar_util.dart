import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:top_snackbar_flutter/top_snack_bar.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme/app_colors.dart';
import 'navigator_key.dart';

class SnackbarUtil {
  static OverlayState? _resolveOverlay(BuildContext? context) {
    // 1) context에서 Overlay 찾기
    if (context != null) {
      final overlay = Overlay.maybeOf(context);
      if (overlay != null) return overlay;
    }
    // 2) navigatorKey.currentContext에서 찾기
    final navCtx = navigatorKey.currentContext;
    if (navCtx != null) {
      final overlay = Overlay.maybeOf(navCtx);
      if (overlay != null) return overlay;
    }
    // 3) pop 직후 등 context 불안정 시 Navigator의 overlay 직접 사용
    return navigatorKey.currentState?.overlay;
  }

  static void _fallbackSnackBar(
    BuildContext context,
    String message, {
    bool isError = false,
  }) {
    final overlay = _resolveOverlay(context);
    if (overlay != null) {
      showTopSnackBar(
        overlay,
        _SimpleSnackBar(message: message, isError: isError),
        animationDuration: const Duration(milliseconds: 300),
        reverseAnimationDuration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.primaryGreen,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 상단에 성공 스낵바 표시
  /// [imageUrl]이 제공되면 코스 이미지를 표시합니다.
  static void showSuccess(
    BuildContext context,
    String message, {
    String? imageUrl,
  }) {
    final overlay = _resolveOverlay(context);
    if (overlay == null) {
      _fallbackSnackBar(context, message, isError: false);
      return;
    }
    showTopSnackBar(
      overlay,
      _SimpleSnackBar(message: message, isError: false, imageUrl: imageUrl),
      animationDuration: const Duration(milliseconds: 300),
      reverseAnimationDuration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  /// 상단에 정보 스낵바 표시
  /// [imageUrl]이 제공되면 코스 이미지를 표시합니다.
  static void showInfo(
    BuildContext context,
    String message, {
    String? imageUrl,
  }) {
    final overlay = _resolveOverlay(context);
    if (overlay == null) {
      _fallbackSnackBar(context, message, isError: false);
      return;
    }
    showTopSnackBar(
      overlay,
      _SimpleSnackBar(message: message, isError: false, imageUrl: imageUrl),
      animationDuration: const Duration(milliseconds: 300),
      reverseAnimationDuration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  /// 상단에 로딩 스낵바 표시 (스피너 + 메시지). 작업이 끝날 때까지 유지됨.
  /// 완료 후 showSuccess / showInfo 호출 시 로딩이 자동으로 해당 스낵바로 대체됨.
  static void showLoading(BuildContext context, String message) {
    final overlay = _resolveOverlay(context);
    if (overlay == null) {
      _fallbackSnackBar(context, message, isError: false);
      return;
    }
    showTopSnackBar(
      overlay,
      _LoadingSnackBar(message: message),
      animationDuration: const Duration(milliseconds: 300),
      reverseAnimationDuration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      persistent: true, // 3초 자동 숨김 없이, 다음 스낵바(showSuccess/showInfo)가 뜰 때까지 유지
    );
  }
}

/// iOS 스타일 스낵바 위젯 (반투명 배경, blur 효과)
class _SimpleSnackBar extends StatelessWidget {
  final String message;
  final bool isError;
  final String? imageUrl;

  const _SimpleSnackBar({
    required this.message,
    this.isError = false,
    this.imageUrl,
  });

  @override
  Widget build(BuildContext context) {
    final hasImage = imageUrl != null && imageUrl!.isNotEmpty;

    return Material(
      color: Colors.transparent,
      child: Dismissible(
        key: UniqueKey(),
        direction: DismissDirection.up,
        movementDuration: const Duration(milliseconds: 300),
        resizeDuration: const Duration(milliseconds: 300),
        dismissThresholds: const {DismissDirection.up: 0.3},
        onDismissed: (direction) {
          // 스와이프로 닫힘
        },
        child: Container(
          margin: const EdgeInsets.only(left: 16, right: 16, top: 0, bottom: 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color:
                      isError
                          ? Colors.red.withOpacity(0.85)
                          : AppColors.primaryGreen.withOpacity(0.85),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.2),
                    width: 0.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.15),
                      blurRadius: 20,
                      offset: const Offset(0, 4),
                    ),
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 이미지가 있으면 이미지 표시
                    if (hasImage) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CachedNetworkImage(
                          imageUrl: imageUrl!,
                          width: 36,
                          height: 36,
                          fit: BoxFit.cover,
                          placeholder:
                              (context, url) => Container(
                                width: 36,
                                height: 36,
                                color: Colors.white.withOpacity(0.2),
                              ),
                          errorWidget:
                              (context, url, error) => Container(
                                width: 36,
                                height: 36,
                                color: Colors.white.withOpacity(0.2),
                              ),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Flexible(
                      child: Text(
                        message,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: Colors.white.withOpacity(0.95),
                          letterSpacing: -0.2,
                        ),
                        textAlign: TextAlign.left,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 로딩 중 스낵바 (스피너 + 메시지)
class _LoadingSnackBar extends StatelessWidget {
  final String message;

  const _LoadingSnackBar({required this.message});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        margin: const EdgeInsets.only(left: 16, right: 16, top: 0, bottom: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.primaryGreen.withOpacity(0.85),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Colors.white.withOpacity(0.2),
                  width: 0.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 20,
                    offset: const Offset(0, 4),
                  ),
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Colors.white.withOpacity(0.95),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      message,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: Colors.white.withOpacity(0.95),
                        letterSpacing: -0.2,
                      ),
                      textAlign: TextAlign.left,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
