import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../models/place.dart';
import '../../providers/story_provider.dart' show Story;
import '../../theme/app_colors.dart';

class StoryDetailScreen extends StatefulWidget {
  final Story story;
  final Place? place;

  const StoryDetailScreen({super.key, required this.story, this.place});

  @override
  State<StoryDetailScreen> createState() => _StoryDetailScreenState();
}

class _StoryDetailScreenState extends State<StoryDetailScreen> {
  //final Map<int, bool> _downloadingStates = {};

  /*Future<void> _downloadImage(String imageUrl, int index) async {
    if (_downloadingStates[index] == true) return;

    setState(() => _downloadingStates[index] = true);
    try {
      final ok = await _downloadService.saveToGallery(
        imageUrl: imageUrl,
        fileName: 'story_${DateTime.now().millisecondsSinceEpoch}_$index',
      );
      if (!mounted) return;
      if (ok) {
        SnackbarUtil.showSuccess(context, '이미지를 저장했어요');
      } else {
        SnackbarUtil.showInfo(context, '이미지 저장에 실패했습니다');
      }
    } catch (e) {
      if (!mounted) return;
      SnackbarUtil.showInfo(context, '이미지 저장에 실패했습니다');
    } finally {
      if (mounted) {
        setState(() => _downloadingStates[index] = false);
      }
    }
  }*/

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        scrolledUnderElevation: 0,
        backgroundColor: AppColors.backgroundLight,
        elevation: 0,

        iconTheme: IconThemeData(color: AppColors.textPrimary),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: 10),
              Text(
                widget.story.title,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 10),
              _StoryExpandableText(
                text: widget.story.content,
                maxLines: 5,
                style: TextStyle(
                  fontSize: 17,
                  height: 1.75,
                  color: AppColors.textPrimary.withOpacity(0.9),
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 22),

              // 이미지들: 원본비율로 세로 나열
              if (widget.story.imageUrls.isNotEmpty)
                Column(
                  children: List.generate(widget.story.imageUrls.length, (
                    index,
                  ) {
                    final url = widget.story.imageUrls[index];
                    final heroTag = 'story_image_${url.hashCode}';
                    //final isDownloading = _downloadingStates[index] == true;
                    return Padding(
                      padding: EdgeInsets.only(
                        bottom:
                            index == widget.story.imageUrls.length - 1 ? 0 : 6,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Stack(
                          children: [
                            Hero(
                              tag: heroTag,
                              child: CachedNetworkImage(
                                imageUrl: url,
                                cacheKey: url,
                                width: double.infinity,
                                fit: BoxFit.fitWidth,
                                maxWidthDiskCache: 1000,
                                maxHeightDiskCache: 1000,
                                memCacheWidth: 1000,
                                memCacheHeight: 1000,
                                fadeInDuration: const Duration(milliseconds: 0),
                                fadeOutDuration: const Duration(
                                  milliseconds: 0,
                                ),
                                placeholder:
                                    (context, _) => Container(
                                      height: 220,
                                      color: AppColors.backgroundWhite,
                                      child: Center(
                                        child: CircularProgressIndicator(
                                          color: AppColors.primaryGreen,
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    ),
                                errorWidget:
                                    (context, _, __) => Container(
                                      height: 220,
                                      color: AppColors.backgroundWhite,
                                      child: Icon(
                                        Icons.broken_image_outlined,
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                              ),
                            ),
                            // 다운로드 버튼
                            /*
                            Positioned(
                              top: 12,
                              right: 12,
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap:
                                      isDownloading
                                          ? null
                                          : () => _downloadImage(url, index),
                                  borderRadius: BorderRadius.circular(20),
                                  child: Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: Colors.black.withOpacity(0.5),
                                      shape: BoxShape.circle,
                                    ),
                                    child:
                                        isDownloading
                                            ? const Padding(
                                              padding: EdgeInsets.all(10),
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                valueColor:
                                                    AlwaysStoppedAnimation<
                                                      Color
                                                    >(Colors.white),
                                              ),
                                            )
                                            : Padding(
                                              padding: const EdgeInsets.all(8),
                                              child: SvgPicture.asset(
                                                'assets/icons/download.svg',
                                                width: 24,
                                                height: 24,
                                                colorFilter:
                                                    const ColorFilter.mode(
                                                      Colors.white,
                                                      BlendMode.srcIn,
                                                    ),
                                              ),
                                            ),
                                  ),
                                ),
                              ),
                            ),*/
                          ],
                        ),
                      ),
                    );
                  }),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StoryExpandableText extends StatefulWidget {
  final String text;
  final int maxLines;
  final TextStyle style;

  const _StoryExpandableText({
    required this.text,
    required this.maxLines,
    required this.style,
  });

  @override
  State<_StoryExpandableText> createState() => _StoryExpandableTextState();
}

class _StoryExpandableTextState extends State<_StoryExpandableText> {
  bool _expanded = false;
  bool _overflow = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: widget.maxLines,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: constraints.maxWidth);
        _overflow = painter.didExceedMaxLines;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: widget.style,
              maxLines: _expanded ? null : widget.maxLines,
              overflow:
                  _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            ),
            if (_overflow) ...[
              const SizedBox(height: 6),
              GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Text(
                  _expanded ? '접기' : '더보기',
                  style: TextStyle(
                    color: AppColors.primaryGreen,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
