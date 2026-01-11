import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme/app_colors.dart';

class StoryCard extends StatefulWidget {
  final String title;
  final String content;
  final String? date;
  final List<String> imageUrls;
  final String? placeName;
  final String? backgroundImageUrl; // 배경 이미지 URL
  final VoidCallback? onTap;

  const StoryCard({
    super.key,
    required this.title,
    required this.content,
    this.date,
    this.imageUrls = const [],
    this.placeName,
    this.backgroundImageUrl,
    this.onTap,
  });

  @override
  State<StoryCard> createState() => _StoryCardState();
}

class _StoryCardState extends State<StoryCard> {
  @override
  Widget build(BuildContext context) {
    final hasBackgroundImage =
        widget.backgroundImageUrl != null &&
        widget.backgroundImageUrl!.isNotEmpty;

    return AspectRatio(
      aspectRatio: 1.3,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 0),
          decoration: BoxDecoration(
            color: hasBackgroundImage
                ? Colors.transparent
                : AppColors.backgroundWhite,
            borderRadius: BorderRadius.circular(16),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 배경 이미지가 있으면 배경으로 사용
                if (hasBackgroundImage)
                  Stack(
                    fit: StackFit.expand,
                    children: [
                      CachedNetworkImage(
                        imageUrl: widget.backgroundImageUrl!,
                        fit: BoxFit.cover,
                        cacheKey: widget.backgroundImageUrl,
                        maxWidthDiskCache: 1000,
                        maxHeightDiskCache: 1000,
                        memCacheWidth: 1000,
                        memCacheHeight: 1000,
                        fadeInDuration: const Duration(milliseconds: 0),
                        fadeOutDuration: const Duration(milliseconds: 0),
                        placeholder: (context, url) =>
                            Container(color: AppColors.backgroundLight),
                        errorWidget: (context, url, error) =>
                            Container(color: AppColors.backgroundLight),
                      ),
                      // 일반 이미지가 여러 장일 때 닷 인디케이터 (오른쪽 위)
                      if (widget.imageUrls.length > 1)
                        Positioned(
                          top: 12,
                          right: 12,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: List.generate(
                              widget.imageUrls.length,
                              (index) => Container(
                                width: 6,
                                height: 6,
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 3,
                                ),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white.withOpacity(0.8),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),

                // 배경 이미지가 없고 일반 이미지가 있으면 큰 이미지 표시
                if (!hasBackgroundImage && widget.imageUrls.isNotEmpty)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: 200,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipRRect(
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                          ),
                          child: CachedNetworkImage(
                            imageUrl: widget.imageUrls[0],
                            fit: BoxFit.cover,
                            cacheKey: widget.imageUrls[0],
                            maxWidthDiskCache: 1000,
                            maxHeightDiskCache: 1000,
                            memCacheWidth: 1000,
                            memCacheHeight: 1000,
                            fadeInDuration: const Duration(milliseconds: 0),
                            fadeOutDuration: const Duration(milliseconds: 0),
                            placeholder: (context, url) =>
                                Container(color: AppColors.backgroundLight),
                            errorWidget: (context, url, error) =>
                                Container(color: AppColors.backgroundLight),
                          ),
                        ),
                        // 이미지가 여러 장일 때 닷 인디케이터 (오른쪽 위)
                        if (widget.imageUrls.length > 1)
                          Positioned(
                            top: 12,
                            right: 12,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: List.generate(
                                widget.imageUrls.length,
                                (index) => Container(
                                  width: 6,
                                  height: 6,
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: index == 0
                                        ? Colors.white
                                        : Colors.white.withOpacity(0.4),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),

                // 텍스트 오버레이 (배경 이미지가 있을 때)
                if (hasBackgroundImage)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withOpacity(0.7),
                            Colors.black.withOpacity(0.85),
                          ],
                        ),
                      ),
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.title,
                            style: const TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            widget.content,
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.white.withOpacity(0.9),
                              height: 1.5,
                            ),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),

                // 텍스트 영역 (배경 이미지가 없을 때)
                if (!hasBackgroundImage)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: AppColors.backgroundWhite,
                        borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(16),
                          bottomRight: Radius.circular(16),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.title,
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textPrimary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            widget.content,
                            style: TextStyle(
                              fontSize: 16,
                              color: AppColors.textSecondary,
                              height: 1.5,
                            ),
                            maxLines: widget.imageUrls.isEmpty ? 5 : 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
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
