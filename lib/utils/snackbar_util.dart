import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:top_snackbar_flutter/top_snack_bar.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme/app_colors.dart';
import 'error_message_util.dart';
import 'navigator_key.dart';

class SnackbarUtil {
  static const _reverseDuration = Duration(milliseconds: 250);

  /// 로딩 스낵바( persistent: true )
  static AnimationController? _loadingController;
  /// 일반 메시지 스낵바
  static AnimationController? _messageController;

  static Future<void> _reverseController(AnimationController? controller) async {
    if (controller == null) return;
    try {
      if (controller.status != AnimationStatus.dismissed &&
          controller.status != AnimationStatus.reverse) {
        await controller.reverse();
      }
    } catch (_) {}
  }

  /// 기존 스낵바를 닫고 애니메이션이 끝날 때까지 대기 (겹침 방지).
  static Future<void> _dismissCurrent() async {
    final message = _messageController;
    final loading = _loadingController;
    _messageController = null;
    _loadingController = null;
    await Future.wait([
      _reverseController(message),
      _reverseController(loading),
    ]);
  }

  /// 로딩 스낵바를 강제로 닫을 때 사용.
  static void dismissLoading() {
    final loading = _loadingController;
    _loadingController = null;
    unawaited(_reverseController(loading));
  }

  static OverlayState? _resolveOverlay(BuildContext? context, {bool preferRoot = false}) {
    // 0) 로딩 스낵바와 동일 오버레이 쓰기 위해 루트(네비게이터) 오버레이 우선
    if (preferRoot) {
      final rootOverlay = navigatorKey.currentState?.overlay;
      if (rootOverlay != null) return rootOverlay;
    }
    // 1) navigatorKey 기준으로 먼저 시도 (pop 직후/비활성 context에서도 안전)
    final navCtx = navigatorKey.currentContext;
    if (navCtx != null) {
      try {
        final overlay = Overlay.maybeOf(navCtx);
        if (overlay != null) return overlay;
      } catch (_) {}
    }
    final overlayFromNavigator = navigatorKey.currentState?.overlay;
    if (overlayFromNavigator != null) return overlayFromNavigator;

    // 2) 전달된 context 사용 (비활성화된 context면 예외 방지)
    if (context != null) {
      try {
        final overlay = Overlay.maybeOf(context);
        if (overlay != null) return overlay;
      } catch (_) {}
    }

    // 3) rootOverlay 시도 (하단 fallback 대신 상단 동일 디자인 유지)
    final ctx = context ?? navCtx;
    if (ctx != null) {
      try {
        return Overlay.of(ctx, rootOverlay: true);
      } catch (_) {}
    }
    return null;
  }

  static void _fallbackSnackBar(
    BuildContext? context,
    String message, {
    bool isError = false,
    String? actionLabel,
    VoidCallback? onActionPressed,
  }) {
    final overlay = _resolveOverlay(context);
    if (overlay != null && actionLabel == null) {
      showTopSnackBar(
        overlay,
        _SimpleSnackBar(message: message, isError: isError),
        animationDuration: const Duration(milliseconds: 300),
        reverseAnimationDuration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
      return;
    }
    // 비활성 context 대신 navigatorKey context 사용
    final safeCtx = context ?? navigatorKey.currentContext;
    if (safeCtx == null) return;
    try {
      final messenger = ScaffoldMessenger.maybeOf(safeCtx);
      if (messenger == null) return;
      messenger.hideCurrentSnackBar();
      final hasAction = actionLabel != null && onActionPressed != null;
      messenger.showSnackBar(
        SnackBar(
          content: hasAction
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(message),
                    const SizedBox(width: 16),
                    TextButton(
                      onPressed: onActionPressed,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(actionLabel),
                    ),
                  ],
                )
              : Text(message),
          backgroundColor: AppColors.primaryGreen,
          behavior: SnackBarBehavior.floating,
          action: null,
        ),
      );
    } catch (_) {}
  }

  static void _showTopMessage({
    required BuildContext context,
    required Widget child,
    required void Function(AnimationController) onControllerInit,
  }) {
    final overlay =
        _resolveOverlay(context, preferRoot: true) ?? _resolveOverlay(context);
    if (overlay == null) {
      final message = child is _SimpleSnackBar ? child.message : '';
      if (message.isNotEmpty) {
        _fallbackSnackBar(context, message, isError: false);
      }
      return;
    }
    showTopSnackBar(
      overlay,
      child,
      animationDuration: const Duration(milliseconds: 300),
      reverseAnimationDuration: _reverseDuration,
      curve: Curves.easeOut,
      onAnimationControllerInit: onControllerInit,
    );
  }

  /// 상단에 성공 스낵바 표시
  static void showSuccess(
    BuildContext context,
    String message, {
    String? imageUrl,
  }) {
    unawaited(() async {
      await _dismissCurrent();
      _showTopMessage(
        context: context,
        child: _SimpleSnackBar(message: message, isError: false, imageUrl: imageUrl),
        onControllerInit: (c) => _messageController = c,
      );
    }());
  }

  /// 상단에 성공 스낵바 + 액션 버튼 표시
  static void showSuccessWithAction(
    BuildContext context,
    String message, {
    required String actionLabel,
    required VoidCallback onActionPressed,
  }) {
    unawaited(() async {
      await _dismissCurrent();
      final overlay = _resolveOverlay(context);
      if (overlay == null) {
        _fallbackSnackBar(
          context,
          message,
          isError: false,
          actionLabel: actionLabel,
          onActionPressed: onActionPressed,
        );
        return;
      }
      showTopSnackBar(
        overlay,
        _SimpleSnackBarWithAction(
          message: message,
          actionLabel: actionLabel,
          onActionPressed: onActionPressed,
        ),
        animationDuration: const Duration(milliseconds: 300),
        reverseAnimationDuration: _reverseDuration,
        curve: Curves.easeOut,
        onAnimationControllerInit: (c) => _messageController = c,
      );
    }());
  }

  /// 상단에 정보 스낵바 표시
  static void showInfo(
    BuildContext context,
    String message, {
    String? imageUrl,
  }) {
    unawaited(() async {
      await _dismissCurrent();
      _showTopMessage(
        context: context,
        child: _SimpleSnackBar(message: message, isError: false, imageUrl: imageUrl),
        onControllerInit: (c) => _messageController = c,
      );
    }());
  }

  /// 서버/네트워크 에러를 한국어로 변환해 정보 스낵바 표시
  /// (예: "The internet connection appears to be offline" → "인터넷 연결이 끊어졌습니다.")
  /// internal 코드는 그대로 "INTERNAL" 노출하지 않고 fallback 사용.
  static void showInfoFromError(
    BuildContext context,
    dynamic error, {
    String fallback = '오류가 발생했습니다. 잠시 후 다시 시도해주세요.',
  }) {
    String raw;
    if (error is FirebaseFunctionsException) {
      if (error.code == 'internal') {
        raw = '';
      } else {
        raw = (error.message ?? '').trim();
      }
    } else {
      raw = error is String ? error : error.toString();
    }
    final message =
        raw.trim().isEmpty ? fallback : ErrorMessageUtil.toUserFriendlyMessage(raw);
    showInfo(context, message);
  }

  /// 상단에 로딩 스낵바 표시 (스피너 + 메시지). 작업이 끝날 때까지 유지됨.
  static void showLoading(BuildContext context, String message) {
    unawaited(() async {
      await _dismissCurrent();
      final overlay =
          _resolveOverlay(context, preferRoot: true) ?? _resolveOverlay(context);
      if (overlay == null) {
        _fallbackSnackBar(context, message, isError: false);
        return;
      }
      showTopSnackBar(
        overlay,
        _LoadingSnackBar(message: message),
        animationDuration: const Duration(milliseconds: 300),
        reverseAnimationDuration: _reverseDuration,
        curve: Curves.easeOut,
        persistent: true,
        onAnimationControllerInit: (c) {
          _loadingController = c;
        },
      );
    }());
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

/// _SimpleSnackBar와 동일 디자인 + 액션 버튼
class _SimpleSnackBarWithAction extends StatelessWidget {
  final String message;
  final String actionLabel;
  final VoidCallback onActionPressed;

  const _SimpleSnackBarWithAction({
    required this.message,
    required this.actionLabel,
    required this.onActionPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Dismissible(
        key: UniqueKey(),
        direction: DismissDirection.up,
        movementDuration: const Duration(milliseconds: 300),
        resizeDuration: const Duration(milliseconds: 300),
        dismissThresholds: const {DismissDirection.up: 0.3},
        onDismissed: (_) {},
        child: Container(
          margin: const EdgeInsets.only(left: 16, right: 16, top: 0, bottom: 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                padding: const EdgeInsets.only(left: 16, right: 10, top: 14, bottom: 14),
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
                    const SizedBox(width: 16),
                    Container(
                      width: 1,
                      height: 18,
                      margin: const EdgeInsets.only(right: 12),
                      color: Colors.white.withOpacity(0.4),
                    ),
                    TextButton(
                      onPressed: onActionPressed,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        actionLabel,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
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
