import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reservation/screens/admin/widgets/shared_widgets.dart'
    show SectionHeader, ReservationCourseCard;
import 'package:reservation/screens/admin/widgets/course_add_flow.dart';
import 'package:reservation/screens/admin/widgets/empty_state_card.dart';
import 'package:reservation/screens/admin/widgets/course_edit_screen.dart';
import '../../theme/app_colors.dart';
import '../../widgets/place_switch_widget.dart';
import '../../providers/place_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/course_provider.dart';
import '../../screens/setting_screen.dart';
import 'widgets/admin_place_edit_screen.dart';

/// 관리자 마이페이지 화면
class AdminMyPageScreen extends StatefulWidget {
  const AdminMyPageScreen({super.key});

  @override
  State<AdminMyPageScreen> createState() => _AdminMyPageScreenState();
}

class _AdminMyPageScreenState extends State<AdminMyPageScreen> {
  // PlaceSelector 제거로 인해 더 이상 필요 없음

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 관리중인 플레이스 정보
              _buildPlacesSection(context),

              const SizedBox(height: 16),

              // 개설된 코스 목록
              _buildCoursesSection(context),

              const SizedBox(height: 24),

              // 설정 (위젯 직접 붙임)
              const SettingScreen(isAdminMode: true, embedded: true),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlacesSection(BuildContext context) {
    return Consumer2<PlaceProvider, AuthProvider>(
      builder: (context, placeProvider, authProvider, child) {
        final currentPlace = placeProvider.currentPlace;
        if (currentPlace == null) {
          return const SizedBox.shrink();
        }
        final isSubManager = authProvider.isSubManagerForPlace(currentPlace.id);

        return Row(
          children: [
            // PlaceSwitchWidget (부매니저는 플레이스 수정·more_vert 숨김)
            Expanded(
              child: PlaceSwitchWidget(
                enabled: authProvider.currentAdmin != null,
                showDescription: true,
                padding: EdgeInsets.zero,
                heroTagSuffix: 'admin_my_page',
                isAdminContext: true,
              ),
            ),
            if (!isSubManager)
              GestureDetector(
                onTap: () {
                  Navigator.of(context)
                      .push(
                        MaterialPageRoute(
                          builder:
                              (context) =>
                                  AdminPlaceEditScreen(place: currentPlace),
                        ),
                      )
                      .then((_) {
                        if (mounted) {
                          setState(() {});
                        }
                      });
                },
                child: Container(
                  padding: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: AppColors.backgroundLight,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.more_vert,
                    size: 22,
                    color: AppColors.textPrimary.withOpacity(0.8),
                  ),
                ),
              ),
            const SizedBox(width: 12),
          ],
        );
      },
    );
  }

  Widget _buildCoursesSection(BuildContext context) {
    return Consumer2<CourseProvider, AuthProvider>(
      builder: (context, courseProvider, authProvider, child) {
        final placeId = Provider.of<PlaceProvider>(context, listen: false).currentPlace?.id;
        final isSubManager = placeId != null && authProvider.isSubManagerForPlace(placeId);
        final placeMember = placeId != null ? authProvider.getPlaceMemberForPlace(placeId) : null;
        final courses = isSubManager && placeMember != null
            ? courseProvider.courses
                .where((c) => placeMember.manageableCourseIds.contains(c.id))
                .toList()
            : courseProvider.courses;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 22),
            SectionHeader(
              title: isSubManager ? '관리중인 코스' : '개설한 코스',
              onIconTap: isSubManager ? null : () => _openCourseAddFlow(context),
              icon: isSubManager ? null : Icon(Icons.add_circle, size: 30, color: AppColors.primaryGreen),
              horizontalPadding: 20,
              fontSize: 20,
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: courses.isEmpty
                  ? EmptyStateCard(
                      title: isSubManager ? '관리 중인 코스가 없어요' : '아직 코스가 없어요',
                      buttonText: isSubManager ? null : '코스 추가하기',
                      onPressed: isSubManager ? null : () => _openCourseAddFlow(context),
                    )
                  : Column(
                      children: courses
                          .map(
                            (course) => Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: ReservationCourseCard(
                                course: course,
                                onTap: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (context) =>
                                          CourseEditScreen(course: course),
                                    ),
                                  );
                                },
                              ),
                            ),
                          )
                          .toList(),
                    ),
            ),
          ],
        );
      },
    );
  }

  void _openCourseAddFlow(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => CourseAddFlow(
          onComplete: (course) {
            if (mounted) setState(() {});
          },
        ),
      ),
    );
  }
}
