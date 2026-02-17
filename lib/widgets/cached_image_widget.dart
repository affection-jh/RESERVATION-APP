import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import '../theme/app_colors.dart';

/// 플레이스 및 코스 이미지를 디스크 캐시로 관리하는 공통 위젯
class CachedImageWidget extends StatelessWidget {
  final String imageUrl;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final Color? placeholderColor;
  final Color? errorColor;
  final Widget? placeholder;
  final Widget? errorWidget;

  const CachedImageWidget({
    super.key,
    required this.imageUrl,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.placeholderColor,
    this.errorColor,
    this.placeholder,
    this.errorWidget,
  });

  @override
  Widget build(BuildContext context) {
    Widget imageWidget = CachedNetworkImage(
      imageUrl: imageUrl,
      width: width,
      height: height,
      fit: fit,
      placeholder:
          (context, url) =>
              placeholder ??
              Shimmer.fromColors(
                baseColor: (placeholderColor ?? AppColors.backgroundLight)
                    .withOpacity(0.6),
                highlightColor: (placeholderColor ?? AppColors.backgroundLight)
                    .withOpacity(0.8),
                period: const Duration(milliseconds: 1200),
                child: Container(
                  width: width,
                  height: height,
                  color: placeholderColor ?? AppColors.backgroundLight,
                ),
              ),
      errorWidget:
          (context, url, error) =>
              errorWidget ??
              Container(
                width: width,
                height: height,
                color: errorColor ?? AppColors.backgroundLight,
                child: Icon(
                  Icons.image,
                  color: AppColors.textSecondary.withOpacity(0.5),
                  size:
                      (width != null && height != null)
                          ? (width! < height! ? width! * 0.3 : height! * 0.3)
                          : 40,
                ),
              ),
      fadeInDuration: const Duration(milliseconds: 300),
      fadeOutDuration: const Duration(milliseconds: 100),
    );

    if (borderRadius != null) {
      return ClipRRect(borderRadius: borderRadius!, child: imageWidget);
    }

    return imageWidget;
  }
}

/// 플레이스 이미지 전용 위젯 (작은 썸네일용)
class PlaceImageWidget extends StatelessWidget {
  final String? imageUrl;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;

  const PlaceImageWidget({
    super.key,
    this.imageUrl,
    this.width = 46,
    this.height = 46,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    if (imageUrl == null || imageUrl!.isEmpty) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: AppColors.textSecondary.withOpacity(0.1),
          borderRadius: borderRadius ?? BorderRadius.circular(16),
        ),
      );
    }

    return CachedImageWidget(
      imageUrl: imageUrl!,
      width: width,
      height: height,
      fit: BoxFit.cover,
      borderRadius: borderRadius ?? BorderRadius.circular(16),
      placeholderColor: AppColors.textSecondary.withOpacity(0.1),
      errorColor: AppColors.textSecondary.withOpacity(0.1),
    );
  }
}

/// 코스 이미지 전용 위젯
class CourseImageWidget extends StatelessWidget {
  final String? imageUrl;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final File? localImageFile; // 로컬 이미지 파일 (네트워크 로딩 중 placeholder로 사용)

  const CourseImageWidget({
    super.key,
    this.imageUrl,
    this.width,
    this.height,
    this.borderRadius,
    this.localImageFile,
  });

  @override
  Widget build(BuildContext context) {
    if (imageUrl == null || imageUrl!.isEmpty) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: AppColors.backgroundLight,
          borderRadius: borderRadius ?? BorderRadius.circular(12),
        ),
      );
    }

    // 로컬 이미지가 있으면 placeholder로 사용
    Widget? localPlaceholder;
    if (localImageFile != null) {
      localPlaceholder = ClipRRect(
        borderRadius: borderRadius ?? BorderRadius.circular(12),
        child: Image.file(
          localImageFile!,
          width: width,
          height: height,
          fit: BoxFit.cover,
        ),
      );
    }

    return CachedImageWidget(
      imageUrl: imageUrl!,
      width: width,
      height: height,
      fit: BoxFit.cover,
      borderRadius: borderRadius ?? BorderRadius.circular(12),

      placeholderColor: AppColors.backgroundLight,
      errorColor: AppColors.backgroundLight,
      placeholder: localPlaceholder,
    );
  }
}
