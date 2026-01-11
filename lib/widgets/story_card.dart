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
    return AspectRatio(
      aspectRatio: 1.3,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 0),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 배경 이미지
                if (widget.backgroundImageUrl != null &&
                    widget.backgroundImageUrl!.isNotEmpty)
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
                  )
                else
                  Container(color: AppColors.backgroundLight),

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
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withOpacity(0.8),
                          ),
                        ),
                      ),
                    ),
                  ),

                // 텍스트 오버레이
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
                          Colors.black.withOpacity(0.65),
                          Colors.black.withOpacity(0.75),
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
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.content,
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.white.withOpacity(0.9),
                            height: 1.5,
                          ),
                          maxLines: 2,
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
