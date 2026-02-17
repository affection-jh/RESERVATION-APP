import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../models/course.dart';
import '../../../models/course_policy.dart';
import '../../../providers/course_provider.dart';
import '../../../providers/place_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/compact_calendar_widget.dart';
import '../../../widgets/cached_image_widget.dart';
import '../../../services/member_service.dart';
import '../../../utils/snackbar_util.dart';
import 'course_schedule_edit_screen.dart';
import 'course_edit_screen.dart';
import 'course_member_registration_screen.dart';
import 'course_member_list_content.dart';
import '../../../providers/member_provider.dart';

/// 코스 상세 페이지
///
/// 1. 상단: CompactCalendarWidget (세션 탭 시 편집 화면으로 이동)
/// 2. 하단: 수강생 리스트
class CourseDetailScreen extends StatefulWidget {
  final Course course;

  const CourseDetailScreen({super.key, required this.course});

  @override
  State<CourseDetailScreen> createState() => _CourseDetailScreenState();
}

class _CourseDetailScreenState extends State<CourseDetailScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,

      body: SafeArea(
        child: Consumer<CourseProvider>(
          builder: (context, courseProvider, child) {
            // 최신 코스 정보 가져오기
            final currentCourse =
                courseProvider.getCourse(widget.course.id) ?? widget.course;

            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(height: MediaQuery.of(context).padding.top),
                  _buildCourseHeader(currentCourse),

                  const SizedBox(height: 22),

                  // 코스 정보 섹션 (이미지, 제목, 설명)
                  _buildCourseInfoSection(currentCourse),
                  Container(height: 12, color: AppColors.backgroundLight),
                  // 캘린더: 정책 변경 시에도 갱신되도록 (course, policy) 구독
                  Selector<CourseProvider, (Course, CoursePolicy)>(
                    selector: (_, p) {
                      final c = p.getCourse(widget.course.id) ?? widget.course;
                      return (c, c.policy);
                    },
                    builder:
                        (_, data, __) => _buildCalendarSection(
                          data.$1,
                          policyUpdatedAt: data.$2.updatedAt,
                        ),
                  ),
                  Container(height: 12, color: AppColors.backgroundLight),
                  const SizedBox(height: 8),

                  _buildStudentListSection(
                    context,
                    currentCourse,
                    placeId: courseProvider.currentPlaceId,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  // 코스 헤더 섹션
  Widget _buildCourseHeader(Course course) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
      decoration: BoxDecoration(color: AppColors.backgroundWhite),
      child: Row(
        children: [
          SizedBox(width: 14),
          IconButton(
            icon: Icon(Icons.arrow_back_ios),
            onPressed: () {
              Navigator.of(context).pop();
            },
          ),
          const Spacer(),
          // 정보 편집 버튼 (검정 배경)
          ElevatedButton(
            onPressed: () async {
              final result = await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => CourseEditScreen(course: course),
                ),
              );
              // 수정 화면에서 돌아왔을 때 새로고침
              // Consumer가 자동으로 갱신되지만, 확실하게 하기 위해 setState 호출
              if (result == true) {
                setState(() {});
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              elevation: 0,
            ),
            child: Text(
              '정보 편집',
              style: TextStyle(
                fontSize: 15,
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 일정 편집 버튼 (테두리만)
          OutlinedButton(
            onPressed: () async {
              final result = await Navigator.of(context).push(
                MaterialPageRoute(
                  builder:
                      (context) => CourseScheduleEditScreen(course: course),
                ),
              );
              // 일정 편집 후 돌아왔을 때 새로고침
              // Consumer가 자동으로 갱신되지만, 확실하게 하기 위해 setState 호출
              if (result == true) {
                setState(() {});
              }
            },
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              side: BorderSide(color: AppColors.borderLight, width: 1),
            ),
            child: Text(
              '일정 편집',
              style: TextStyle(
                fontSize: 15,
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 14),
        ],
      ),
    );
  }

  // 코스 정보 섹션 (이미지, 제목, 설명)
  Widget _buildCourseInfoSection(Course course) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(color: AppColors.backgroundWhite),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 코스 이미지
          if (course.imageUrl != null)
            Padding(
              padding: const EdgeInsets.only(right: 20),
              child: CourseImageWidget(
                imageUrl: course.imageUrl,
                width: 60,
                height: 60,
                borderRadius: BorderRadius.circular(12),
              ),
            ),

          // 제목과 설명
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 제목
                Text(
                  course.name,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                // 설명
                if (course.description.isNotEmpty)
                  Text(
                    course.description,
                    style: TextStyle(
                      fontSize: 16,
                      color: AppColors.textSecondary,
                      height: 1.5,
                    ),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 캘린더 섹션 (policyUpdatedAt: 정책 변경 시 key에 포함해 캘린더 재생성)
  Widget _buildCalendarSection(Course course, {DateTime? policyUpdatedAt}) {
    return Container(
      margin: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: AppColors.backgroundLight),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // key에 정책 updatedAt 포함 → 예약 정책 수정 후 돌아오면 캘린더 재생성되어 최신 정책 반영
          CompactCalendarWidget(
            key: ValueKey(
              '${course.id}_${course.sessions.length}_${course.sessions.map((s) => '${s.dayOfWeek}_${s.startTime}').join('_')}_${policyUpdatedAt?.millisecondsSinceEpoch ?? course.policy.updatedAt.millisecondsSinceEpoch}',
            ),
            backgroundColor: AppColors.backgroundWhite,
            courses: [course],
            weekOffset: 0,
            height: 450,
            hideCourseSelector: true,
            usage: CompactCalendarUsage.courseDetailView,
            onSessionTap: (course, session, date) {
              // 세션 탭 시 편집 화면으로 이동
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder:
                      (context) => CourseScheduleEditScreen(course: course),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // 수강생 리스트 섹션 (코스별 보기와 동일: enrollments + pendingMembers)
  // ⚠️ 코스 상세에서는 PlaceProvider.currentPlace와 코스 목록(placeId)이 일시적으로 어긋날 수 있어,
  // CourseProvider가 로드한 placeId를 우선 사용합니다.
  Widget _buildStudentListSection(
    BuildContext context,
    Course course, {
    required String? placeId,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: CourseMemberListContent(
        logLabel: 'CourseDetail',
        courseId: course.id,
        placeId: placeId,
        emptyMessage: '등록된 멤버가 없어요.',
        shrinkWrap: true,
        showHeaderWithCount: true,
        headerTitleBuilder: (count) => '멤버($count명)',
        onAddTap: () => _showMemberRegistration(course),
        listPadding: EdgeInsets.zero,
        cardBackgroundColor: AppColors.backgroundLight,
      ),
    );
  }

  // 멤버 등록 화면 표시
  Future<void> _showMemberRegistration(Course course) async {
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final placeId = placeProvider.currentPlace?.id;

    if (placeId == null) {
      SnackbarUtil.showInfo(context, '플레이스 정보를 불러올 수 없습니다.');
      return;
    }

    if (!authProvider.isAuthenticated || authProvider.currentUser == null) {
      SnackbarUtil.showInfo(context, '로그인이 필요합니다.');
      return;
    }

    await Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder:
            (context, animation, secondaryAnimation) =>
                CourseMemberRegistrationScreen(
                  onSave: (memberList) async {
                    await _registerMembers(
                      context,
                      memberList,
                      placeId,
                      authProvider,
                    );
                  },
                  courseId: course.id, // 특정 코스만 등록
                  placeId: placeId,
                ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          const curve = Curves.easeInOut;

          var tween = Tween(
            begin: begin,
            end: end,
          ).chain(CurveTween(curve: curve));

          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  // 멤버 등록 처리
  Future<void> _registerMembers(
    BuildContext context,
    List<Map<String, dynamic>> memberList,
    String placeId,
    AuthProvider authProvider,
  ) async {
    try {
      final adminId = authProvider.currentUser!.userId;
      final courseProvider = Provider.of<CourseProvider>(
        context,
        listen: false,
      );
      final memberService = MemberService();

      int successCount = 0;
      int failCount = 0;

      for (final memberData in memberList) {
        try {
          final name = (memberData['name'] as String).trim();
          final phoneNumber = (memberData['phoneNumber'] as String).trim();

          if (name.isEmpty || phoneNumber.isEmpty) {
            failCount++;
            continue;
          }

          final courseEnrollments =
              memberData['courseEnrollments'] as List<Map<String, dynamic>>?;

          await memberService.registerMember(
            placeId: placeId,
            adminId: adminId,
            name: name,
            phoneNumber: phoneNumber,
            courseEnrollments: courseEnrollments,
            courses: courseProvider.courses,
          );

          successCount++;
        } catch (e) {
          failCount++;
          // 에러 메시지를 클라이언트 친화적으로 변환
          final errorStr = e.toString();
          if (errorStr.contains('이미 등록되어 있습니다') ||
              errorStr.contains('이미 등록된')) {
            // 이미 등록된 멤버는 실패로 카운트하되, 메시지는 나중에 통합 표시
          }
        }
      }

      if (!mounted) return;
      if (failCount == 0) {
        SnackbarUtil.showSuccess(context, '${successCount}명의 멤버가 등록되었습니다.');
      } else {
        final failMessage =
            failCount == memberList.length
                ? '이미 등록되어 있습니다.'
                : '$successCount명 성공, $failCount명 실패';
        SnackbarUtil.showInfo(context, failMessage);
      }

      if (!mounted) return;
      final memberProvider = Provider.of<MemberProvider>(
        context,
        listen: false,
      );
      memberProvider.setPlaceId(placeId);
    } catch (e) {
      if (mounted) {
        String errorMessage = '멤버 등록 중 오류가 발생했습니다.';
        final errorStr = e.toString();
        if (errorStr.contains('이미 등록되어 있습니다') || errorStr.contains('이미 등록된')) {
          errorMessage = '이미 등록되어 있습니다.';
        }
        SnackbarUtil.showInfo(context, errorMessage);
      }
    }
  }
}
