import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../theme/app_colors.dart';
import '../../models/course.dart' as reservation_models;
import '../../providers/course_provider.dart';
import 'widgets/admin_shared_widgets.dart';
import 'widgets/course_add_flow.dart';

class AdminCourseScreen extends StatefulWidget {
  const AdminCourseScreen({super.key});

  @override
  State<AdminCourseScreen> createState() => _AdminCourseScreenState();
}

class _AdminCourseScreenState extends State<AdminCourseScreen> {
  @override
  Widget build(BuildContext context) {
    return Consumer<CourseProvider>(
      builder: (context, courseProvider, child) {
        final courses = courseProvider.courses;

        return ListView(
          padding: const EdgeInsets.all(0),
          children: [
            SectionHeader(
              title: '예약 코스',
              icon: Icon(Icons.add, size: 30, color: AppColors.primaryGreen),
              onIconTap: () => _showCourseAddFlow(context),
              horizontalPadding: 20,
            ),
            const SizedBox(height: 12),
            if (courses.isEmpty) const EmptyHint(text: '등록된 코스가 없습니다.'),
            for (final c in courses) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: ReservationCourseCard(
                  course: c,
                  onTap: () => _showCourseAddFlow(context, existing: c),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ],
        );
      },
    );
  }

  void _showCourseAddFlow(
    BuildContext context, {
    reservation_models.Course? existing,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => CourseAddFlow(
          existingCourse: existing,
          onComplete: (course) {
            // CourseAddFlow 내부에서 정책 설정 및 최종 등록 처리
            // 여기서는 아무것도 하지 않음
          },
        ),
      ),
    );
  }
}
