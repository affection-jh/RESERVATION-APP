import 'package:flutter/material.dart';
import 'dart:ui';
import '../theme/app_colors.dart';
import '../widgets/cached_image_widget.dart' show CachedImageWidget;

/// 플레이스 이미지 상세 화면 (Hero 애니메이션 + 블러 배경)
class PlaceImageDetailScreen extends StatelessWidget {
  final String? imageUrl;
  final String placeName;
  final String heroTag;

  const PlaceImageDetailScreen({
    super.key,
    required this.imageUrl,
    required this.placeName,
    required this.heroTag,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // 블러 배경
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(color: Colors.black.withOpacity(0.5)),
            ),
          ),
          // 닫기 버튼
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 28),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ),
          // 가운데 이미지
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Hero 애니메이션으로 이미지
                Hero(
                  tag: heroTag,
                  child: Material(
                    color: Colors.transparent,
                    child: Container(
                      width: MediaQuery.of(context).size.width * 0.8,
                      height: MediaQuery.of(context).size.width * 0.8,
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
                            imageUrl != null && imageUrl!.isNotEmpty
                                ? CachedImageWidget(
                                  imageUrl: imageUrl!,
                                  width:
                                      MediaQuery.of(context).size.width * 0.8,
                                  height:
                                      MediaQuery.of(context).size.width * 0.8,
                                  fit: BoxFit.cover,
                                  borderRadius: BorderRadius.circular(24),
                                  placeholderColor: AppColors.textSecondary
                                      .withOpacity(0.1),
                                  errorColor: AppColors.textSecondary
                                      .withOpacity(0.1),
                                )
                                : Container(
                                  color: AppColors.textSecondary.withOpacity(
                                    0.1,
                                  ),
                                  child: Icon(
                                    Icons.image_outlined,
                                    size: 80,
                                    color: AppColors.textSecondary.withOpacity(
                                      0.5,
                                    ),
                                  ),
                                ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                // 플레이스 이름
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    placeName,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: -0.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
