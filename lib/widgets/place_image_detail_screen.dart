import 'package:flutter/material.dart';
import 'dart:ui';
import '../theme/app_colors.dart';
import '../widgets/cached_image_widget.dart' show CachedImageWidget;

/// 플레이스 이미지 상세 화면 (선택적 Hero 애니메이션 + 블러 배경)
/// [heroTag]가 null이거나 비어 있으면 Hero 미사용 (탭 전환 등에서 타겟 누락 방지)
/// 이미지를 아래로 당기면 닫힘 (인스타 스타일).
class PlaceImageDetailScreen extends StatefulWidget {
  final String? imageUrl;
  final String placeName;
  final String? placeDescription;
  final String? heroTag;

  const PlaceImageDetailScreen({
    super.key,
    required this.imageUrl,
    required this.placeName,
    this.placeDescription,
    this.heroTag,
  });

  @override
  State<PlaceImageDetailScreen> createState() => _PlaceImageDetailScreenState();
}

class _PlaceImageDetailScreenState extends State<PlaceImageDetailScreen> {
  double _dragOffset = 0;
  static const double _dismissThreshold = 120;
  static const double _opacityFactor = 400;

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (details.delta.dy <= 0) return; // 아래로만 허용
    setState(() {
      _dragOffset += details.delta.dy;
      if (_dragOffset < 0) _dragOffset = 0;
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final shouldDismiss = _dragOffset >= _dismissThreshold || velocity > 300;
    if (shouldDismiss) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _dragOffset = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bgOpacity = (1 - (_dragOffset / _opacityFactor)).clamp(0.0, 1.0);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // 블러 배경 (당길수록 흐려짐)
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                color: Colors.black.withOpacity(0.5 * bgOpacity),
              ),
            ),
          ),
          // 이미지 + 이름 + 설명 (아래로 당기면 따라 내려가며 닫기)
          Positioned.fill(
            child: SafeArea(
              child: GestureDetector(
                onVerticalDragUpdate: _onVerticalDragUpdate,
                onVerticalDragEnd: _onVerticalDragEnd,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.only(
                    top: 56,
                    left: 16,
                    right: 16,
                    bottom: 16,
                  ),
                  child: Transform.translate(
                    offset: Offset(0, _dragOffset),
                    child: Center(
                      child: SingleChildScrollView(
                        physics:
                            _dragOffset > 0
                                ? const NeverScrollableScrollPhysics()
                                : null,
                        child: Opacity(
                          opacity: bgOpacity,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _buildImage(context),
                              const SizedBox(height: 24),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                child: Text(
                                  widget.placeName,
                                  style: const TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                    letterSpacing: -0.5,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                              if (widget.placeDescription != null &&
                                  widget.placeDescription!
                                      .trim()
                                      .isNotEmpty) ...[
                                const SizedBox(height: 12),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  child: Text(
                                    widget.placeDescription!.trim(),
                                    style: TextStyle(
                                      fontSize: 16,
                                      height: 1.45,
                                      color: Colors.white.withOpacity(0.9),
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 닫기 버튼 (제스처 레이어 위에 두어 탭이 가려지지 않게)
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: IconButton(
                  icon: Icon(
                    Icons.close,
                    color: Colors.white.withOpacity(bgOpacity),
                    size: 28,
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImage(BuildContext context) {
    final side = MediaQuery.sizeOf(context).width * 0.3;
    final imageContent = Material(
      color: Colors.transparent,
      child: Container(
        width: side,
        height: side,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child:
              widget.imageUrl != null && widget.imageUrl!.isNotEmpty
                  ? CachedImageWidget(
                    imageUrl: widget.imageUrl!,
                    width: side,
                    height: side,
                    fit: BoxFit.cover,
                    borderRadius: BorderRadius.circular(24),
                    placeholderColor: AppColors.textSecondary.withOpacity(0.1),
                    errorColor: AppColors.textSecondary.withOpacity(0.1),
                  )
                  : Container(
                    color: AppColors.textSecondary.withOpacity(0.1),
                    child: Icon(
                      Icons.image_outlined,
                      size: 80,
                      color: AppColors.textSecondary.withOpacity(0.5),
                    ),
                  ),
        ),
      ),
    );
    final tag = widget.heroTag?.trim();
    return tag != null && tag.isNotEmpty
        ? Hero(tag: tag, child: imageContent)
        : imageContent;
  }
}
