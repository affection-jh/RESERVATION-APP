import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reservation/screens/admin/widgets/admin_shared_widgets.dart'
    show SectionHeader, ReservationCourseCard;
import 'package:reservation/screens/admin/widgets/course_add_flow.dart';
import 'package:reservation/screens/admin/widgets/course_detail_screen.dart';
import '../../theme/app_colors.dart';
import '../../services/auth_service.dart';
import '../../widgets/profile_settings_widget.dart'
    show UserProfileInfoSection, SettingsItemsBuilder;
import '../../widgets/notification_settings_dialog.dart';
import '../../widgets/name_edit_bottom_sheet.dart';
import '../../widgets/place_switch_widget.dart';
import '../../providers/place_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/course_provider.dart';
import '../../utils/snackbar_util.dart';
import 'widgets/admin_place_edit_screen.dart';

/// 관리자 마이페이지 화면
class AdminMyPageScreen extends StatefulWidget {
  const AdminMyPageScreen({super.key});

  @override
  State<AdminMyPageScreen> createState() => _AdminMyPageScreenState();
}

class _AdminMyPageScreenState extends State<AdminMyPageScreen> {
  // AdminPlaceSelector 제거로 인해 더 이상 필요 없음

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

              // 관리자 정보 섹션
              Builder(
                builder: (context) {
                  final authProvider = Provider.of<AuthProvider>(context);
                  final admin = authProvider.currentAdmin;
                  final isNotificationEnabled =
                      admin?.notificationsEnabled ?? true;

                  return UserProfileInfoSection(
                    headerTitle: '관리자 계정',
                    profileName: admin?.name ?? '관리자',
                    profilePhoneNumber: admin?.phoneNumber ?? '',
                    onProfileTap: () {
                      if (admin == null) return;
                      NameEditBottomSheet.show(
                        context: context,
                        initialName: admin.name,
                      );
                    },
                    profileBottomWidget: const PlaceSwitchWidget(
                      heroTagSuffix: 'admin_my_page_profile',
                    ),
                    settingsItems: SettingsItemsBuilder.buildSettingsItems(
                      context: context,
                      isNotificationEnabled: isNotificationEnabled,
                      onNotificationTap: () async {
                        final result = await NotificationSettingsDialog.show(
                          context: context,
                          initialValue: isNotificationEnabled,
                        );
                        if (result == true && context.mounted) {
                          // 다이얼로그에서 설정이 변경되었으면 화면 새로고침
                          setState(() {});
                        }
                      },
                      onLogout: () async {
                        final authService = AuthService();
                        await authService.logout();
                      },
                      onWithdraw: () async {
                        final authProvider = Provider.of<AuthProvider>(
                          context,
                          listen: false,
                        );
                        final admin = authProvider.currentAdmin;

                        if (admin == null) {
                          SnackbarUtil.showError(
                            context,
                            '관리자 정보를 찾을 수 없습니다.',
                          );
                          return;
                        }

                        SnackbarUtil.showLoading(context, '탈퇴중');

                        try {
                          // 서버 deleteUserAccount 호출 (관리자 소속 플레이스 있으면 탈퇴 불가 검사 포함)
                          final callable = FirebaseFunctions.instance
                              .httpsCallable('deleteUserAccount');
                          await callable.call({'userId': admin.userId});

                          await authProvider.logout();

                          if (context.mounted) {
                            SnackbarUtil.showSuccess(
                                context, '회원탈퇴가 완료되었습니다.');
                            Navigator.pushNamedAndRemoveUntil(
                              context,
                              '/',
                              (route) => false,
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            String message = '회원탈퇴 중 오류가 발생했습니다.';
                            if (e is FirebaseFunctionsException &&
                                (e.message ?? '').trim().isNotEmpty) {
                              message = e.message!.trim();
                            } else {
                              try {
                                final msg =
                                    (e as dynamic).message?.toString();
                                if (msg != null && msg.trim().isNotEmpty) {
                                  message = msg.trim();
                                }
                              } catch (_) {}
                            }
                            SnackbarUtil.showError(context, message);
                          }
                        }
                      },
                    ),
                    showWithdrawButton: false, // 설정 항목에만 회원탈퇴 표시
                  );
                },
              ),
              SizedBox(height: 20),
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

        return Row(
          children: [
            // PlaceSwitchWidget
            Expanded(
              child: PlaceSwitchWidget(
                enabled: authProvider.currentAdmin != null,
                showDescription: true,
                padding: EdgeInsets.zero,
                heroTagSuffix: 'admin_my_page',
              ),
            ),

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
                      // 편집 화면에서 돌아왔을 때 화면 새로고침
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
            // 편집 아이콘 (관리자 마이페이지에서만)
            const SizedBox(width: 12),
          ],
        );
      },
    );
  }

  Widget _buildCoursesSection(BuildContext context) {
    return Consumer<CourseProvider>(
      builder: (context, courseProvider, child) {
        final courses = courseProvider.courses;

        if (courses.isEmpty) {
          return const SizedBox.shrink();
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: 22),
            SectionHeader(
              title: '개설한 코스',
              onIconTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder:
                        (context) => CourseAddFlow(
                          onComplete: (course) {
                            if (context.mounted) {
                              setState(() {});
                            }
                          },
                        ),
                  ),
                );
              },
              icon: Icon(
                Icons.add_circle,
                size: 30,
                color: AppColors.primaryGreen,
              ),
              horizontalPadding: 20,
              fontSize: 20,
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children:
                    courses.map((course) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: ReservationCourseCard(
                          course: course,
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder:
                                    (context) =>
                                        CourseDetailScreen(course: course),
                              ),
                            );
                          },
                        ),
                      );
                    }).toList(),
              ),
            ),
          ],
        );
      },
    );
  }
}
