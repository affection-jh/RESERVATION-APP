import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import 'cached_image_widget.dart';

class CourseCard extends StatelessWidget {
  final String title;
  final String instructor;
  final String description;
  final String? imageUrl;
  final String? price;
  final double? rating;
  final int? studentCount;
  final VoidCallback? onTap;

  const CourseCard({
    super.key,
    required this.title,
    required this.instructor,
    required this.description,
    this.imageUrl,
    this.price,
    this.rating,
    this.studentCount,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.backgroundWhite,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 이미지 (있을 경우)
            if (imageUrl != null) ...[
              CourseImageWidget(
                imageUrl: imageUrl,
                width: double.infinity,
                height: 150,
                borderRadius: BorderRadius.circular(12),
              ),
              const SizedBox(height: 16),
            ],

            // 제목
            Text(
              title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),

            // 강사명
            Text(
              instructor,
              style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 8),

            // 설명
            Text(
              description,
              style: TextStyle(
                fontSize: 14,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),

            // 하단 정보 (평점, 수강생 수, 가격)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // 평점과 수강생 수
                Row(
                  children: [
                    if (rating != null) ...[
                      Icon(Icons.star, size: 16, color: Colors.amber),
                      const SizedBox(width: 4),
                      Text(
                        rating!.toStringAsFixed(1),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    if (studentCount != null) ...[
                      Icon(
                        Icons.people_outline,
                        size: 16,
                        color: AppColors.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '$studentCount명',
                        style: TextStyle(
                          fontSize: 14,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
                // 가격
                if (price != null)
                  Text(
                    price!,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primaryGreen,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
