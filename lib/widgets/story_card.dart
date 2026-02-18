import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
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
  bool _backgroundImageLoaded = false;

  @override
  void didUpdateWidget(StoryCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backgroundImageUrl != widget.backgroundImageUrl) {
      _backgroundImageLoaded = false;
    }
  }

  bool get _hasBackgroundImage =>
      widget.backgroundImageUrl != null &&
      widget.backgroundImageUrl!.isNotEmpty;

  bool get _showGradient => _hasBackgroundImage && _backgroundImageLoaded;

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
                if (_hasBackgroundImage)
                  CachedNetworkImage(
                    imageUrl: widget.backgroundImageUrl!,
                    fit: BoxFit.cover,
                    cacheKey: widget.backgroundImageUrl,
                    maxWidthDiskCache: 1000,
                    maxHeightDiskCache: 1000,
                    memCacheWidth: 1000,
                    memCacheHeight: 1000,
                    fadeInDuration: const Duration(milliseconds: 150),
                    fadeOutDuration: const Duration(milliseconds: 0),
                    imageBuilder: (context, imageProvider) {
                      if (!_backgroundImageLoaded && mounted) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) {
                            setState(() => _backgroundImageLoaded = true);
                          }
                        });
                      }
                      return Image(
                        image: imageProvider,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      );
                    },
                    placeholder:
                        (context, url) =>
                            Container(color: AppColors.backgroundWhite),
                    errorWidget:
                        (context, url, error) =>
                            Container(color: AppColors.backgroundWhite),
                  )
                else
                  Container(color: AppColors.backgroundWhite),

                // 좌상단 캘린더 아이콘
                Positioned(
                  top: 12,
                  left: 12,
                  child: SvgPicture.asset(
                    'assets/icons/calendar-icon.svg',
                    width: 24,
                    height: 24,
                    colorFilter: ColorFilter.mode(
                      _showGradient
                          ? Colors.white.withOpacity(0.9)
                          : AppColors.textPrimary,
                      BlendMode.srcIn,
                    ),
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
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withOpacity(0.8),
                          ),
                        ),
                      ),
                    ),
                  ),

                // 텍스트 오버레이 (이미지 로드 완료 시 그라데이션+흰글씨 200ms 페이드인)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child:
                      _showGradient
                          ? TweenAnimationBuilder<double>(
                            key: const ValueKey('gradient_fade'),
                            tween: Tween(begin: 0, end: 1),
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                            builder: (context, value, child) {
                              return Opacity(opacity: value, child: child);
                            },
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.transparent,
                                    Colors.black.withOpacity(0.4),
                                    Colors.black.withOpacity(0.6),
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
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  if (widget.content.isNotEmpty)
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
                          )
                          : Container(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  widget.title,
                                  style: TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.textPrimary,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                if (widget.content.isNotEmpty)
                                  Text(
                                    widget.content,
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: AppColors.textPrimary,
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
